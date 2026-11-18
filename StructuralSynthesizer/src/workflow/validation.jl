# =============================================================================
# Design Workflow — Pipeline-Based Building Design
# =============================================================================
#
# The design pipeline is composable: `build_pipeline` returns a Vector of
# `PipelineStage`s (tagged closures) that are executed in sequence.
# Each stage declares whether the outer loop should call `sync_asap!`
# afterwards — stages that self-sync or don't touch the Asap model skip it.
#
#   for stage in build_pipeline(params)
#       stage.fn(struc)
#       stage.needs_sync && sync_asap!(struc; params)
#   end
#
# Adding a new stage (e.g., lateral design, connection design) requires only
# a new push! in build_pipeline — design_building itself never changes.
#
# Example:
#   skel = gen_medium_office(54u"ft", 42u"ft", 13u"ft", 3, 3, 3)
#   struc = BuildingStructure(skel)
#   
#   design1 = design_building(struc, DesignParameters(
#       name = "Option A - 4ksi concrete",
#       floor = FlatPlateOptions(material=RC_4000_60),
#       foundation_options = FoundationParameters(soil=medium_sand),
#   ))
#   
#   design2 = design_building(struc, DesignParameters(
#       name = "Option B - 6ksi concrete",
#       materials = MaterialOptions(concrete=NWC_6000),
#       floor = FlatPlateOptions(),
#   ))
#   
#   compare_designs(design1, design2)
# =============================================================================

using Dates

# =============================================================================
# Pre-Sizing Validation
# =============================================================================

# NOTE: `@traced` cannot be used on documented functions (Julia doc macro conflict).
# Register trace contracts manually before docstrings.
StructuralSizer.TRACE_REGISTRY[(:run_pre_sizing_validation, :workflow)] =
    StructuralSizer.TracedFunctionMeta(
        :run_pre_sizing_validation,
        :workflow,
        [:enter, :exit, :decision],
        nothing,
        @__FILE__,
        @__LINE__,
    )

"""
    PreSizingValidationError <: Exception

Thrown when method applicability checks (DDM, EFM, etc.) fail before sizing.
The `.errors` field contains human-readable violation messages.
"""
struct PreSizingValidationError <: Exception
    errors::Vector{String}
end

Base.showerror(io::IO, e::PreSizingValidationError) =
    print(io, "PreSizingValidationError: ", join(e.errors, "; "))

"""
    run_pre_sizing_validation(struc::BuildingStructure, params::DesignParameters)
        -> (ok::Bool, errors::Vector{String})

Run method applicability checks (DDM, EFM, FEA) for all flat-plate/flat-slab panels
*before* sizing. Returns `(false, errors)` if any slab fails its chosen method;
otherwise `(true, String[])`.

Used to fail fast with a 400 validation response instead of discovering
inapplicability mid-pipeline (or silently falling back to FEA).
"""
function run_pre_sizing_validation(
    struc::BuildingStructure,
    params::DesignParameters;
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    # Fail-loud guard (Run 4): refuse only UN-HONORABLE effective
    # member_group_overrides (covers both design_building methods, prepare_engine,
    # and DesignSession construction). `struc` is prepared here, so the struc-aware
    # overload also refuses column/strut-group targets — the earliest choke point
    # that can. Honorable steel-beam-group overrides pass and are threaded into
    # sizing. See `_assert_member_group_overrides_unsupported`.
    _assert_member_group_overrides_unsupported(params, struc)

    errors = String[]
    floor_opts = resolve_floor_options(params)
    fp_opts = floor_opts isa StructuralSizer.FlatSlabOptions ? floor_opts.base : floor_opts

    # Only FlatPlateOptions / FlatSlabOptions have method applicability checks.
    # A :two_way request can redesign beamless panels as flat plates; those
    # panels are checked against the options the slab node will actually use.
    any_plate = any(s -> s.floor_type in (:flat_plate, :flat_slab), struc.slabs)
    if !(fp_opts isa StructuralSizer.FlatPlateOptions) && !any_plate
        StructuralSizer.emit!(tc, :workflow, "run_pre_sizing_validation", "", :decision;
                              outcome="skipped", reason="non_flat_plate_floor_options",
                              floor_opts_type=string(typeof(floor_opts)))
        return (true, String[])
    end

    method = fp_opts isa StructuralSizer.FlatPlateOptions ? fp_opts.method : nothing
    ρ_concrete = fp_opts isa StructuralSizer.FlatPlateOptions ? fp_opts.material.concrete.ρ : nothing

    StructuralSizer.emit!(tc, :workflow, "run_pre_sizing_validation", "", :enter;
                          n_slabs=length(struc.slabs),
                          method=string(typeof(method)))

    n_checked = 0
    n_violations = 0

    for (slab_idx, slab) in enumerate(struc.slabs)
        slab.floor_type in (:flat_plate, :flat_slab) || continue
        slab_opts = _floor_options_for_slab(struc, slab_idx, params, floor_opts)
        slab_fp = slab_opts isa StructuralSizer.FlatSlabOptions ? slab_opts.base : slab_opts
        slab_fp isa StructuralSizer.FlatPlateOptions || continue
        method = slab_fp.method
        ρ_concrete = slab_fp.material.concrete.ρ
        n_checked += 1

        slab_cell_indices = Set(slab.cell_indices)
        columns = StructuralSizer.find_supporting_columns(struc, slab_cell_indices)
        n_cols = length(columns)
        n_walls = length(StructuralSizer.supporting_wall_segments(struc, slab))

        prefix = "Slab $slab_idx: "

        if method isa StructuralSizer.DDM
            result = StructuralSizer.check_ddm_applicability(
                struc, slab, columns; throw_on_failure=false, ρ_concrete=ρ_concrete)
            if !result.ok
                for v in result.violations
                    push!(errors, prefix * v)
                end
                n_violations += length(result.violations)
            end
        elseif method isa StructuralSizer.EFM
            result = StructuralSizer.check_efm_applicability(
                struc, slab, columns; throw_on_failure=false)
            if !result.ok
                for v in result.violations
                    push!(errors, prefix * v)
                end
                n_violations += length(result.violations)
            end
        elseif method isa StructuralSizer.FEA
            # A wall line is a support. Two columns, a column and a wall, or
            # two walls are enough; one support is a mechanism.
            n_supports = n_cols + n_walls
            if n_supports < 2
                push!(errors, prefix * "FEA requires at least 2 supports; found $n_cols columns and $n_walls wall lines")
                n_violations += 1
            end
        end
        # RuleOfThumb has no applicability checks
    end

    ok = isempty(errors)
    StructuralSizer.emit!(tc, :workflow, "run_pre_sizing_validation", "", :exit;
                          ok=ok, n_slabs_checked=n_checked, n_violations=n_violations)
    return (ok, errors)
end

