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
function run_pre_sizing_validation(struc::BuildingStructure, params::DesignParameters)
    errors = String[]
    floor_opts = resolve_floor_options(params)
    fp_opts = floor_opts isa StructuralSizer.FlatSlabOptions ? floor_opts.base : floor_opts

    # Only FlatPlateOptions / FlatSlabOptions have method applicability checks
    if !(fp_opts isa StructuralSizer.FlatPlateOptions)
        return (true, String[])
    end

    method = fp_opts.method
    ρ_concrete = fp_opts.material.concrete.ρ

    for (slab_idx, slab) in enumerate(struc.slabs)
        slab.floor_type in (:flat_plate, :flat_slab) || continue

        slab_cell_indices = Set(slab.cell_indices)
        columns = StructuralSizer.find_supporting_columns(struc, slab_cell_indices)
        n_cols = length(columns)

        prefix = "Slab $slab_idx: "

        if method isa StructuralSizer.DDM
            result = StructuralSizer.check_ddm_applicability(
                struc, slab, columns; throw_on_failure=false, ρ_concrete=ρ_concrete)
            if !result.ok
                for v in result.violations
                    push!(errors, prefix * v)
                end
            end
        elseif method isa StructuralSizer.EFM
            result = StructuralSizer.check_efm_applicability(
                struc, slab, columns; throw_on_failure=false)
            if !result.ok
                for v in result.violations
                    push!(errors, prefix * v)
                end
            end
        elseif method isa StructuralSizer.FEA
            if n_cols < 2
                push!(errors, prefix * "FEA requires at least 2 supporting columns; found $n_cols")
            end
        end
        # RuleOfThumb has no applicability checks
    end

    return (isempty(errors), errors)
end

# =============================================================================
# Pipeline Construction
# =============================================================================

"""
    build_pipeline(params::DesignParameters) -> Vector{PipelineStage}

Compose the design pipeline from `DesignParameters`.

Returns a vector of `PipelineStage`s. Each stage has a `.fn` closure that
mutates the structure (sizing members, updating loads) and a `.needs_sync`
flag.  The outer loop calls `sync_asap!` only for stages that need it.

# Stages (by floor type)

**Flat plate** (:flat_plate)
1. Size slabs (DDM/EFM/FEA — includes column P-M design)
2. Reconcile columns (take max of slab-designed and Asap-found)
3. Size foundations (if requested)

**One-way slab / two-way slab** (:one_way, :two_way)
1. Size slabs
2. Size beams + columns (iterative convergence loop)
3. Size foundations (if requested)

**Vault** (:vault)
1. Size slabs (vault geometry)
2. Size beams + columns (iterative — beam must resist thrust)
3. Size foundations (if requested)
"""
function build_pipeline end  # forward declaration for docstring

"""
    PipelineStage

Tagged stage: pairs a mutating function with a flag indicating whether the
outer loop should call `sync_asap!` afterwards.

- `needs_sync=true`  → full load update + solve after the stage
- `needs_sync=false` → stage either self-syncs or doesn't touch the model
"""
struct PipelineStage
    fn::Function
    needs_sync::Bool
end

function build_pipeline(params::DesignParameters;
                        tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    stages = PipelineStage[]
    
    floor_opts = resolve_floor_options(params)
    floor_type = _infer_floor_type(floor_opts)
    
    # Extract column options for flat plate/slab sizing (needed for design_details)
    column_opts = _get_column_opts(params)
    if floor_type in (:flat_plate, :flat_slab) && column_opts isa StructuralSizer.PixelFrameColumnOptions
        throw(ArgumentError(
            "Flat plate/slab requires reinforced concrete columns. " *
            "PixelFrame columns are not supported for beamless slab systems."))
    end
    
    # ─── Stage 1: Slab sizing (always) ─── needs sync to push slab self-weight
    push!(stages, PipelineStage(struc -> begin
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :enter;
                              floor_type=string(floor_type))
        StructuralSizer.size_slabs!(struc; options=floor_opts, verbose=false,
                                    max_iterations=params.max_iterations,
                                    fire_rating=params.fire_rating,
                                    column_opts=column_opts, tc=tc)
        update_slab_volumes!(struc; options=floor_opts)
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :exit)
    end, true))
    
    # ─── Stage 2: Beam + column sizing ───
    if floor_type in (:flat_plate, :flat_slab)
        push!(stages, PipelineStage(struc -> begin
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_reconcile", :enter)
            _reconcile_columns!(struc, params)
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_reconcile", :exit)
        end, false))
    else
        push!(stages, PipelineStage(struc -> begin
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_beams_columns", :enter)
            _size_beams_columns!(struc, params; tc=tc)
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_beams_columns", :exit)
        end, true))
    end
    
    # ─── Stage 3: Foundations (if requested) ─── no Asap model changes
    if !isnothing(params.foundation_options)
        push!(stages, PipelineStage(struc -> begin
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_3_foundations", :enter)
            _size_foundations!(struc, params.foundation_options; tc=tc)
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_3_foundations", :exit)
        end, false))
    end
    
    return stages
end

# =============================================================================
# Main Entry Point
# =============================================================================

"""
    prepare!(struc::BuildingStructure, params::DesignParameters) -> struc

Initialize a structure for design: set up cells, slabs, members, estimate
column sizes, build the Asap analysis model, and snapshot the pristine state.

This is the geometry-only step — no member sizing. Call `design_building` or
run pipeline stages individually after `prepare!`.

# Example
```julia
prepare!(struc, params)
size_slabs!(struc, params)          # just slabs
snapshot!(struc, :post_slab)        # save intermediate state

# Try different column options on the same slab result
for col_opts in [ConcreteColumnOptions(), ConcreteColumnOptions(material = NWC_6000)]
    restore!(struc, :post_slab)
    size_columns!(struc, col_opts)
end
```
"""
function prepare!(struc::BuildingStructure, params::DesignParameters)
    floor_opts = resolve_floor_options(params)
    floor_type = _infer_floor_type(floor_opts)
    
    initialize!(struc; loads=params.loads, floor_type=floor_type,
                floor_opts=floor_opts,
                scoped_floor_overrides=params.scoped_floor_overrides,
                tributary_axis=params.tributary_axis)
    
    fc = _get_design_fc(params)
    estimate_column_sizes!(struc; fc=fc, input_is_centerline=params.geometry_is_centerline)

    # Set column shape for flat plate/slab when RC circular (punching, stiffness, output)
    if floor_type in (:flat_plate, :flat_slab)
        col_opts = params.columns
        if col_opts isa ConcreteColumnOptions && col_opts.section_shape == :circular
            for col in struc.columns
                col.shape = :circular
            end
        end
    end

    to_asap!(struc; params=params)
    
    snapshot!(struc)
    return struc
end

"""
    capture_design(struc::BuildingStructure, params::DesignParameters; t_start=nothing) -> BuildingDesign

Capture the current state of a sized structure into a `BuildingDesign`.

Called automatically by `design_building`, but also available for manual
pipeline workflows where you run stages independently.

# Example
```julia
prepare!(struc, params)
for stage in build_pipeline(params)
    stage.fn(struc)
    stage.needs_sync && sync_asap!(struc; params)
end
design = capture_design(struc, params)
```
"""
function capture_design(struc::BuildingStructure, params::DesignParameters;
                        t_start=nothing,
                        tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    design = BuildingDesign(struc, params)
    if tc !== nothing
        append!(design.solver_trace, tc.events)
    end
    _populate_slab_results!(design, struc)
    _populate_column_results!(design, struc)
    _populate_beam_results!(design, struc)
    _populate_foundation_results!(design, struc)
    _compute_design_summary!(design, struc, params)

    # Capture structural offsets before restore! wipes them.
    # Maps vertex_idx → (dx_m, dy_m) for edge/corner columns.
    skel = struc.skeleton
    for col in struc.columns
        off = col.structural_offset
        (off[1] == 0.0 && off[2] == 0.0) && continue
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            (edge_idx < 1 || edge_idx > length(skel.edge_indices)) && continue
            v1, v2 = skel.edge_indices[edge_idx]
            design.structural_offsets[v1] = off
            design.structural_offsets[v2] = off
        end
    end

    if !isnothing(t_start)
        design.compute_time_s = time() - t_start
    end
    return design
end

"""
    design_building(struc::BuildingStructure, params::DesignParameters) -> BuildingDesign

Run the complete design pipeline and return a `BuildingDesign` with all results.

Uses `snapshot!` / `restore!` to leave `struc` unchanged after design,
enabling multiple designs from the same structure:

```julia
d1 = design_building(struc, params_a)   # struc is restored after
d2 = design_building(struc, params_b)   # struc is restored after
compare_designs(d1, d2)
```

# Pipeline
1. `prepare!` — initialize structure, estimate columns, build Asap model, snapshot
2. Run stages from `build_pipeline(params)` with `sync_asap!` where needed
3. `capture_design` — populate BuildingDesign with all results
4. Restore to pristine state
"""
function design_building(struc::BuildingStructure, params::DesignParameters;
                         tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    t_start = time()
    
    StructuralSizer.emit!(tc, :pipeline, "design_building", "", :enter;
                          n_slabs=length(struc.slabs), n_columns=length(struc.columns))

    t0 = time()
    prepare!(struc, params)
    t_prepare = time() - t0

    # Pre-sizing validation: fail fast if DDM/EFM/FEA applicability checks fail
    ok, val_errors = run_pre_sizing_validation(struc, params)
    if !ok
        throw(PreSizingValidationError(val_errors))
    end
    
    t0 = time()
    for stage in build_pipeline(params; tc=tc)
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params=params)
    end
    t_pipeline = time() - t0
    
    t0 = time()
    design = capture_design(struc, params; t_start=t_start, tc=tc)
    t_capture = time() - t0

    # Build the visualization analysis model while struc still has sized
    # dimensions and structural offsets (restore! will wipe them).
    t0 = time()
    if !params.skip_visualization && isnothing(design.asap_model)
        target_edge = isnothing(params.visualization_target_edge_m) ? nothing : params.visualization_target_edge_m * u"m"
        try
            build_analysis_model!(design; target_edge_length=target_edge)
        catch e
            @warn "build_analysis_model! failed — visualization will use frame-only model" exception=(e, catch_backtrace())
        end
    end
    t_analysis = time() - t0
    
    # Restore pristine member dimensions so struc can be reused.
    # Skip sync_asap! — prepare! rebuilds the Asap model from scratch on the
    # next design_building call, and the API route never reads struc.asap_model
    # after this point (serialization uses design.asap_model).
    t0 = time()
    restore!(struc; geometry_is_centerline=params.geometry_is_centerline)
    t_restore = time() - t0

    design.phase_timings["prepare"] = round(t_prepare; digits=3)
    design.phase_timings["pipeline"] = round(t_pipeline; digits=3)
    design.phase_timings["capture"] = round(t_capture; digits=3)
    design.phase_timings["analysis_model"] = round(t_analysis; digits=3)
    design.phase_timings["restore"] = round(t_restore; digits=3)

    StructuralSizer.emit!(tc, :pipeline, "design_building", "", :exit;
                          t_total=round(time() - t_start; digits=3),
                          t_pipeline=round(t_pipeline; digits=3))

    @info "design_building timing" prepare=round(t_prepare; digits=2) pipeline=round(t_pipeline; digits=2) capture=round(t_capture; digits=2) analysis_model=round(t_analysis; digits=2) restore=round(t_restore; digits=2) total=round(time() - t_start; digits=2)
    
    return design
end

"""
    design_building(struc::BuildingStructure; kwargs...) -> BuildingDesign

Convenience method that creates DesignParameters from keyword arguments.
"""
function design_building(struc::BuildingStructure; tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing, kwargs...)
    params = DesignParameters(; kwargs...)
    return design_building(struc, params; tc=tc)
end

# =============================================================================
# Pipeline Stage Implementations
# =============================================================================

"""Extract column options from DesignParameters for flat plate/slab sizing.
Returns ConcreteColumnOptions or PixelFrameColumnOptions; `nothing` for steel (not supported).
Caller must reject PixelFrame for flat plate/slab before use."""
function _get_column_opts(params::DesignParameters)
    opts = params.columns
    (opts isa ConcreteColumnOptions || opts isa StructuralSizer.PixelFrameColumnOptions) ? opts : nothing
end

"""
    _reconcile_columns!(struc, params) -> (struc=struc, n_reconciled=Int)

Reconcile column sizes after flat-plate slab sizing.

The slab loop designs columns from tributary Pu (single-floor tributary).
For multi-story buildings, Asap model forces may be larger due to load
accumulation from upper floors.  This stage grows any column whose
Asap-model axial demand exceeds slab-design capacity, using pure
compression capacity: ϕPn = 0.65 × 0.80 × f′c × Ag  (ACI 318-11 §10.3.6.2).

Returns the mutated structure and the number of columns that grew.
"""
function _reconcile_columns!(struc::BuildingStructure, params::DesignParameters)
    _col_opts = _get_column_opts(params)
    conc = resolve_concrete(params)
    fc_Pa = ustrip(u"Pa", conc.fc′)
    E_Pa = ustrip(u"Pa", conc.E)
    ν_c = conc.ν
    G_Pa = E_Pa / (2.0 * (1.0 + ν_c))
    ρ_kg = ustrip(u"kg/m^3", conc.ρ)
    I_factor = 0.70  # ACI 318-11 §10.10.4.1
    grew = 0

    _shape_con = !isnothing(_col_opts) ? _col_opts.shape_constraint : :square
    _max_ar   = !isnothing(_col_opts) ? _col_opts.max_aspect_ratio : 2.0
    _c_inc    = !isnothing(_col_opts) ? _col_opts.size_increment : 0.5u"inch"

    for col in struc.columns
        isnothing(col.c1) && continue
        
        Pu_N = _column_asap_Pu(struc, col)
        
        # Check if column needs to grow for axial capacity
        needs_growth = false
        if Pu_N > 0
            # Required area: ϕ Pn = 0.65 × 0.80 × f'c × Ag  (ACI 318 pure compression)
            Ag_required_m2 = Pu_N / (0.65 * 0.80 * fc_Pa)
            Ag_required = Ag_required_m2 * u"m^2"
            c_required = sqrt(Ag_required_m2) * u"m"
            if c_required > col.c1 || c_required > col.c2
                grow_column_for_axial!(col, Ag_required;
                                        shape_constraint=_shape_con, max_ar=_max_ar,
                                        increment=_c_inc)
                grew += 1
                needs_growth = true
            end
        end

        # Always create an RC section for visualization (and update Asap section if grew)
        b_m = ustrip(u"m", col.c1)
        h_m = ustrip(u"m", col.c2)
        
        # Create RC section with minimum reinforcement for visualization serialization.
        # Branch on shape: rectangular → RCColumnSection, circular → RCCircularSection.
        # This ensures section_polygon is populated correctly in the API output.
        col_shape = hasproperty(col, :shape) ? col.shape : :rectangular
        if col_shape == :circular
            # For circular: c1 = c2 = D (diameter). RCCircularSection needs min 6 bars.
            rc_section = StructuralSizer.RCCircularSection(
                D = col.c1,
                bar_size = 8,
                n_bars = 6,  # Minimum for spiral per ACI
            )
        else
            rc_section = StructuralSizer.RCColumnSection(
                b = col.c1,
                h = col.c2,
                bar_size = 8,
                n_bars = 4,  # Minimum bars per ACI 10.7.3.1
            )
        end
        set_section!(col, rc_section)
        
        # Update Asap model elements if column grew
        if needs_growth
            if col_shape == :circular
                D_m = b_m  # c1 = c2 = D for circular
                A = π * D_m^2 / 4
                I = π * D_m^4 / 64  # Same for both axes
                J = π * D_m^4 / 32  # Torsional constant, solid circular
                asap_sec = Asap.Section(
                    A * u"m^2", E_Pa * u"Pa", G_Pa * u"Pa",
                    I_factor * I * u"m^4", I_factor * I * u"m^4",
                    I_factor * J * u"m^4",
                    ρ_kg * u"kg/m^3",
                )
            else
                A   = b_m * h_m
                Ig_x = b_m * h_m^3 / 12
                Ig_y = h_m * b_m^3 / 12
                a_dim = max(b_m, h_m); b_dim = min(b_m, h_m)
                β = 1/3 - 0.21 * (b_dim / a_dim) * (1 - (b_dim / a_dim)^4 / 12)
                asap_sec = Asap.Section(
                    A * u"m^2", E_Pa * u"Pa", G_Pa * u"Pa",
                    I_factor * Ig_x * u"m^4", I_factor * Ig_y * u"m^4",
                    I_factor * β * a_dim * b_dim^3 * u"m^4",
                    ρ_kg * u"kg/m^3",
                )
            end

            for seg_idx in segment_indices(col)
                edge_idx = struc.segments[seg_idx].edge_idx
                (edge_idx < 1 || edge_idx > length(struc.asap_model.elements)) && continue
                struc.asap_model.elements[edge_idx].section = asap_sec
            end
        end
    end
    
    grew > 0 && @info "Column reconciliation: $grew columns grew from Asap model forces"

    # Recompute structural offsets after column dimensions changed
    grew > 0 && update_structural_offsets!(struc; input_is_centerline=params.geometry_is_centerline)

    # Self-sync: if any columns grew, do a lightweight K+S update and re-solve
    # so the outer pipeline can skip the redundant full sync_asap!
    synced = false
    if grew > 0 && struc.asap_model.processed
        Asap.update!(struc.asap_model; values_only=true)
        Asap.solve!(struc.asap_model)
        synced = true
    end

    return (struc = struc, n_reconciled = grew, synced = synced)
end

"""
    _ensure_beam_sections_for_visualization!(struc, params)

Assign nominal RC beam sections to beams that have no section (e.g. when beam sizing
was skipped for flat plate/flat slab). Ensures section_polygon is populated in API output.
"""
function _ensure_beam_sections_for_visualization!(struc::BuildingStructure, params::DesignParameters)
    for beam in struc.beams
        !isnothing(section(beam)) && continue
        # Nominal rectangular section for visualization (12×18 in typical for spandrel)
        sec = StructuralSizer.RCBeamSection(
            b = 12.0u"inch",
            h = 18.0u"inch",
            bar_size = 8,
            n_bars = 4,
        )
        set_section!(beam, sec)
    end
end

"""Extract max axial force (N) for a column from the Asap model."""
function _column_asap_Pu(struc::BuildingStructure, col)
    Pu = 0.0
    for seg_idx in segment_indices(col)
        seg = struc.segments[seg_idx]
        edge_idx = seg.edge_idx
        (edge_idx < 1 || edge_idx > length(struc.asap_model.elements)) && continue
        el = struc.asap_model.elements[edge_idx]
        isempty(el.forces) && continue
        n_dof = length(el.forces)
        Pu_start = abs(el.forces[1])
        Pu_end = n_dof >= 7 ? abs(el.forces[7]) : Pu_start
        Pu = max(Pu, Pu_start, Pu_end)
    end
    return Pu
end

"""
Iterative beam + column sizing for beam-based floor systems.

Beams and columns are coupled: beam self-weight affects column demands, and
column stiffness affects beam moments. This loop converges their sizes.
"""
function _size_beams_columns!(struc::BuildingStructure, params::DesignParameters;
                              tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    # Defensive guard: slab-only systems should not run beam sizing.
    # This keeps flat-plate/flat-slab workflows resilient even if an upstream
    # caller accidentally routes into the beam+column stage.
    if !isempty(struc.slabs)
        floor_types = Set(s.floor_type for s in struc.slabs)
        if all(ft -> ft in (:flat_plate, :flat_slab, :grade, :roof), floor_types)
            @warn "Skipping beam sizing for slab-only floor system in beam+column stage" floor_types=collect(floor_types)
            _reconcile_columns!(struc, params)
            _ensure_beam_sections_for_visualization!(struc, params)
            return struc
        end
    end

    beam_opts   = something(params.beams,   StructuralSizer.SteelBeamOptions())
    column_opts = something(params.columns, StructuralSizer.SteelColumnOptions())
    skel = struc.skeleton
    beam_edge_ids = Set(get(skel.groups_edges, :beams, Int[]))

    # Skip beam sizing when no beam edges (e.g. beam-based floor type but geometry has no beams)
    if isempty(beam_edge_ids)
        @warn "Skipping beam sizing: no beam edges in geometry. Sizing columns only."
        size_columns!(struc, column_opts; reanalyze=false)
        if struc.asap_model.processed
            Asap.update!(struc.asap_model)
        else
            Asap.process!(struc.asap_model)
        end
        Asap.solve!(struc.asap_model)
        _run_p_delta_if_needed!(struc, column_opts; verbose=false)
        if has_fire_rating(params)
            n_col = add_coating_loads!(struc, params; member_edge_group=:columns, resolve=false)
            if n_col > 0
                Asap.process!(struc.asap_model)
                Asap.solve!(struc.asap_model)
            end
        end
        return struc
    end

    tol = 0.05
    max_iter = params.max_iterations
    verbose = false

    n_cols_bc = length(struc.columns)
    prev_demands = Vector{Float64}(undef, n_cols_bc)
    curr_demands = Vector{Float64}(undef, n_cols_bc)
    first_iter = true
    
    StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :enter;
                          n_beams=length(beam_edge_ids), n_columns=n_cols_bc,
                          beam_type=string(typeof(beam_opts)),
                          column_type=string(typeof(column_opts)))

    for iter in 1:max_iter
        size_beams!(struc, beam_opts; reanalyze=false)
        
        if struc.asap_model.processed
            Asap.update!(struc.asap_model)
        else
            Asap.process!(struc.asap_model)
        end
        Asap.solve!(struc.asap_model)
        
        size_columns!(struc, column_opts; reanalyze=false)
        
        if struc.asap_model.processed
            Asap.update!(struc.asap_model)
        else
            Asap.process!(struc.asap_model)
        end
        Asap.solve!(struc.asap_model)
        
        _extract_column_demands!(curr_demands, struc)
        if !first_iter && _max_demand_change(prev_demands, curr_demands) < tol
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                                  outcome="converged", iterations=iter)
            break
        end
        copyto!(prev_demands, curr_demands)
        first_iter = false
    end
    
    # ─── P-Δ second-order analysis (ACI 318-11 §10.10) ───
    # After first-order sizing converges, check if any story has δs > 1.5.
    # If so, run iterative P-Δ to capture second-order effects, then re-size
    # columns with the updated forces.
    _run_p_delta_if_needed!(struc, column_opts; verbose=verbose)
    
    # ─── Fire protection coating loads (steel members only) ───
    # After sizing, add SFRM/intumescent self-weight and re-solve.
    if has_fire_rating(params)
        n_beam = add_coating_loads!(struc, params; member_edge_group=:beams, resolve=false)
        n_col  = add_coating_loads!(struc, params; member_edge_group=:columns, resolve=false)
        if (n_beam + n_col) > 0
            Asap.process!(struc.asap_model)
            Asap.solve!(struc.asap_model)
        end
    end
    
    return struc
end

"""
    _run_p_delta_if_needed!(struc, column_opts; verbose=false)

Check whether any story requires P-Δ analysis (δs > 1.5 from both Q and ΣPc
methods).  If so, run `p_delta_iterate!` and re-size columns.
"""
function _run_p_delta_if_needed!(struc::BuildingStructure, column_opts; verbose::Bool = false)
    # Compute story properties with the current solved model
    compute_story_properties!(struc; verbose=false)
    
    # Check if any story needs P-Δ
    # story_properties fields are Float64 in (kip, inch) units
    needs_pdelta = false
    for col in struc.columns
        props = col.story_properties
        isnothing(props) && continue
        
        sp = StructuralSizer.SwayStoryProperties(
            props.ΣPu, props.ΣPc, props.Vus, props.Δo, props.lc
        )
        Q = StructuralSizer.stability_index(sp)
        δs_Q = Q < 1.0 ? 1.0 / (1.0 - Q) : Inf
        
        if δs_Q > 1.5
            needs_pdelta = true
            break
        end
    end
    
    if !needs_pdelta
        return
    end
    
    verbose && @info "δs > 1.5 detected — running P-Δ second-order analysis (ACI §6.7)"
    
    result = p_delta_iterate!(struc; verbose=verbose)
    
    if !isempty(result.stories_needing_attention)
        @warn "P-Δ drift ratio exceeds 1.4× first-order (ACI §6.6.4.6.2)" stories=result.stories_needing_attention ratio=round(result.max_drift_ratio, digits=2)
    end
    
    # Re-size columns with updated second-order forces
    size_columns!(struc, column_opts; reanalyze=false)
    
    return
end

# =============================================================================
# Internal Helpers
# =============================================================================

"""Infer floor type from floor options."""
_infer_floor_type(opts::StructuralSizer.AbstractFloorOptions) = StructuralSizer.floor_symbol(opts)

"""Get concrete f'c from design parameters (uses material cascade)."""
function _get_design_fc(params::DesignParameters)
    fc = resolve_concrete(params)
    return fc.fc′
end

"""Size foundations using FoundationParameters.

Uses the strategy-aware `size_foundations!` pipeline so that
`fp.options.strategy` (:mat, :all_spread, :all_strip, :auto, :auto_strip_spread) is respected.
"""
function _size_foundations!(
    struc::BuildingStructure,
    fp::FoundationParameters;
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    initialize_supports!(struc)
    if isempty(struc.supports)
        @warn "Skipping foundation sizing: no supports found. Ensure support vertices are at grade."
        return
    end
    StructuralSizer.emit!(tc, :workflow, "_size_foundations!", "", :enter;
                          strategy=string(fp.options.strategy),
                          code=string(fp.options.code))
    size_foundations!(struc;
        soil = fp.soil,
        opts = fp.options,
        group_tolerance = fp.group_tolerance,
        concrete = fp.concrete,
        rebar = fp.rebar,
        pier_width = fp.pier_width,
        min_depth = fp.min_depth,
        tc = tc,
    )
    StructuralSizer.emit!(tc, :workflow, "_size_foundations!", "", :exit;
                          n_foundations=length(struc.foundations),
                          n_groups=length(struc.foundation_groups))
end

"""Extract column axial demands into pre-allocated buffer (zero-alloc)."""
function _extract_column_demands!(demands::Vector{Float64}, struc::BuildingStructure)
    @inbounds for (i, col) in enumerate(struc.columns)
        demands[i] = _column_asap_Pu(struc, col)
    end
    return demands
end

"""Compute maximum relative change in column demands."""
function _max_demand_change(prev::Vector{Float64}, curr::Vector{Float64})
    length(prev) == length(curr) || return 1.0
    max_change = 0.0
    for (p, c) in zip(prev, curr)
        if p > 0
            change = abs(c - p) / p
            max_change = max(max_change, change)
        elseif c > 0
            max_change = 1.0
        end
    end
    return max_change
end

# =============================================================================
# Result Population Functions
# =============================================================================

"""Populate slab design results from struc.slabs (all values normalized to SI).

Uses `slab.design_details` (the full `size_flat_plate!` NamedTuple) when
available to capture column P-M, integrity, transfer, and punching detail
that `slab.result` (FlatPlatePanelResult) alone doesn't carry.
"""
function _populate_slab_results!(design::BuildingDesign, struc::BuildingStructure)
    # Handle case where slabs haven't been initialized yet
    if isnothing(struc.slabs) || isempty(struc.slabs)
        return
    end
    
    for (slab_idx, slab) in enumerate(struc.slabs)
        # Fallback: slab.result is nothing (shouldn't happen for properly initialized slabs,
        # but handle gracefully to avoid dropping the slab from visualization entirely).
        if isnothing(slab.result)
            dd = hasproperty(slab, :design_details) ? slab.design_details : nothing
            did_converge = isnothing(dd) || !hasproperty(dd, :converged) || dd.converged
            # Use initial slab thickness if available via spans (h ≈ ln/33 minimum)
            fallback_h = try
                h_init = slab.spans.primary / 33
                uconvert(u"m", h_init)
            catch
                0.2u"m"  # 200mm default
            end
            design.slabs[slab_idx] = SlabDesignResult(
                thickness   = fallback_h,
                self_weight = 0.0u"kPa",
                converged       = did_converge,
                failure_reason  = !did_converge && !isnothing(dd) && hasproperty(dd, :failure_reason) ? string(dd.failure_reason) : "",
                failing_check   = !did_converge && !isnothing(dd) && hasproperty(dd, :failing_check)  ? string(dd.failing_check)  : "",
                iterations      = !isnothing(dd) && hasproperty(dd, :iterations)     ? dd.iterations      : 0,
                pattern_loading = !isnothing(dd) && hasproperty(dd, :pattern_loading) ? dd.pattern_loading : false,
            )
            continue
        end
        r_raw = slab.result   # FlatPlatePanelResult (or other AbstractFloorResult)
        # Defensive unwrap: some flows can carry `Pair(idx => result)` payloads.
        r = r_raw isa Pair ? r_raw.second : r_raw
        
        result = SlabDesignResult(
            thickness   = uconvert(u"m",   StructuralSizer.total_depth(r)),
            self_weight = uconvert(u"kPa", StructuralSizer.self_weight(r)),
        )
        
        # ── Core analysis fields ─────────────────────────────────────────
        hasproperty(r, :M0) && (result.M0 = uconvert(u"kN*m", r.M0))
        hasproperty(r, :qu) && (result.qu = uconvert(u"kPa", r.qu))
        
        # ── Deflection ───────────────────────────────────────────────────
        if hasproperty(r, :deflection_check)
            dc = r.deflection_check
            result.deflection_ok    = dc.ok
            result.deflection_ratio = dc.ratio
            if hasproperty(dc, :Δ_check)          # flat plate / flat slab (Unitful)
                result.deflection_in       = ustrip(u"inch", dc.Δ_check)
                result.deflection_limit_in = ustrip(u"inch", dc.Δ_limit)
            elseif hasproperty(dc, :δ)             # vault (dimensionless metres)
                result.deflection_in       = ustrip(u"inch", dc.δ * u"m")
                result.deflection_limit_in = ustrip(u"inch", dc.limit * u"m")
            end
        end
        
        # ── Punching shear ───────────────────────────────────────────────
        if hasproperty(r, :punching_check)
            pc = r.punching_check
            result.punching_ok        = pc.ok
            result.punching_max_ratio = pc.max_ratio
            if hasproperty(pc, :details) && !isempty(pc.details)
                result.punching_vu_max_psi = maximum(
                    ustrip(u"psi", v.vu) for v in values(pc.details); init = 0.0)
                _has_stud(v) = hasproperty(v, :studs) && !isnothing(v.studs)
                result.has_studs   = any(_has_stud(v) for v in values(pc.details))
                result.n_stud_cols = count(_has_stud, values(pc.details))
                for v in values(pc.details)
                    _has_stud(v) || continue
                    s = v.studs
                    if s.n_rails > result.stud_rails_max
                        result.stud_rails_max    = s.n_rails
                        result.stud_per_rail_max = s.n_studs_per_rail
                    end
                end
            end
        end
        
        # ── Convergence / pattern loading (from size_flat_plate! NamedTuple) ──
        dd = hasproperty(slab, :design_details) ? slab.design_details : nothing
        if !isnothing(dd)
            hasproperty(dd, :converged)       && !isnothing(dd.converged)       && (result.converged       = dd.converged)
            hasproperty(dd, :failure_reason)  && !isnothing(dd.failure_reason)  && (result.failure_reason  = dd.failure_reason)
            hasproperty(dd, :failing_check)   && !isnothing(dd.failing_check)   && (result.failing_check   = dd.failing_check)
            hasproperty(dd, :iterations)      && !isnothing(dd.iterations)      && (result.iterations      = dd.iterations)
            hasproperty(dd, :pattern_loading) && !isnothing(dd.pattern_loading) && (result.pattern_loading = dd.pattern_loading)
        end
        
        # ── Rich design details (column ρg, integrity, transfer, etc.) ───
        if !isnothing(dd)
            # Column ρg
            if hasproperty(dd, :column_results) && !isnothing(dd.column_results)
                ρg_vals = [v.ρg for v in values(dd.column_results)]
                result.col_rho_max = isempty(ρg_vals) ? 0.0 : maximum(ρg_vals)
            end
            
            # Integrity check (ACI 8.7.4.2)
            if hasproperty(dd, :integrity_check) && !isnothing(dd.integrity_check)
                result.integrity_ok = dd.integrity_check.ok
            end
            
            # Transfer reinforcement (ACI 8.4.2.3)
            if hasproperty(dd, :transfer_results) && !isnothing(dd.transfer_results)
                result.n_transfer_bars_additional = sum(
                    isnothing(tr) ? 0 : tr.n_bars_additional
                    for tr in dd.transfer_results; init = 0)
            end
            
            # ρ′ for long-term deflection
            if hasproperty(dd, :ρ_prime) && !isnothing(dd.ρ_prime)
                result.ρ_prime = dd.ρ_prime
            end
            
            # Drop panel geometry
            dp = hasproperty(dd, :drop_panel) ? dd.drop_panel : nothing
            if !isnothing(dp)
                result.h_drop_in  = ustrip(u"inch", dp.h_drop)
                result.a_drop1_ft = ustrip(u"ft",   dp.a_drop_1)
                result.a_drop2_ft = ustrip(u"ft",   dp.a_drop_2)
            end
        end

        # Capture mutable slab fields that restore! will wipe.
        # The serializer and engineering report run after restore!, so they must
        # read these from the SlabDesignResult rather than from slab.* on the
        # live structure.
        result.drop_panel = slab.drop_panel
        result.is_vault = r isa StructuralSizer.VaultResult
        if result.is_vault
            result.vault_rise = uconvert(u"m", r.rise)
        end
        result.sizer_result = r
        
        design.slabs[slab_idx] = result
    end
end

"""Populate column design results from struc.columns.

Extracts axial and moment demands from the Asap model, merges punching shear
results from slab design, and computes approximate capacity ratios.
"""
function _populate_column_results!(design::BuildingDesign, struc::BuildingStructure)
    params = design.params
    
    # ─── Build column-to-punching lookup from slab results ───
    # slab.result.punching_check.details is a Dict{Int, NamedTuple} keyed by column idx
    punch_map = Dict{Int, NamedTuple}()  # col_idx → punching NamedTuple
    for slab in struc.slabs
        r = slab.result
        isnothing(r) && continue
        hasproperty(r, :punching_check) || continue
        pc = r.punching_check
        hasproperty(pc, :details) || continue
        for (cidx, pr) in pc.details
            # Keep the worst ratio if a column appears in multiple panels
            if !haskey(punch_map, cidx) || pr.ratio > punch_map[cidx].ratio
                punch_map[cidx] = pr
            end
        end
    end
    
    # ─── Material properties for capacity estimate ───
    conc = resolve_concrete(params)
    reb  = resolve_rebar(params)
    fc′_Pa = ustrip(u"Pa", conc.fc′)
    fy_Pa  = ustrip(u"Pa", reb.Fy)

    has_model = !isnothing(struc.asap_model) && !isempty(struc.asap_model.elements)
    
    for (col_idx, col) in enumerate(struc.columns)
        result = ColumnDesignResult()
        
        # ─── Section size & geometry ───
        col_sec = section(col)
        result.section_obj = col_sec
        result.shape = hasproperty(col, :shape) ? col.shape : :rectangular

        if !isnothing(col.c1) && !isnothing(col.c2)
            result.c1 = uconvert(u"m", col.c1)
            result.c2 = uconvert(u"m", col.c2)
        end

        # Section name: use the section object's name for steel/PixelFrame, else c1×c2
        if !isnothing(col_sec) && hasproperty(col_sec, :name) && !isnothing(col_sec.name)
            result.section_size = col_sec.name
        elseif result.shape == :circular && !isnothing(col.c1)
            D_in = round(ustrip(u"inch", col.c1); digits=1)
            result.section_size = "⌀$(D_in)\""
        elseif !isnothing(col.c1) && !isnothing(col.c2)
            c1_in = round(Int, ustrip(u"inch", col.c1))
            c2_in = round(Int, ustrip(u"inch", col.c2))
            result.section_size = "$(c1_in)×$(c2_in)"
        end
        
        # ─── Material takeoff fields ───
        col_L = member_length(col)
        result.height = col_L isa Unitful.Quantity ? uconvert(u"m", col_L) : col_L * u"m"
        if !isnothing(col.c1) && !isnothing(col.c2)
            if result.shape == :circular
                result.Ag = uconvert(u"m^2", π / 4 * col.c1^2)
            else
                result.Ag = uconvert(u"m^2", col.c1 * col.c2)
            end
        end
        if !isnothing(col_sec) && hasproperty(col_sec, :As_total)
            result.As_total = uconvert(u"m^2", col_sec.As_total)
            result.rho_g = hasproperty(col_sec, :ρg) ? col_sec.ρg : 0.0
        end
        
        # ─── Demands from Asap model ───
        # Extract peak axial force and moments from solved element forces.
        # el.forces layout (12-DOF 3D frame):
        #   [Fx1, Fy1, Fz1, Mx1, My1, Mz1, Fx2, Fy2, Fz2, Mx2, My2, Mz2]
        # Sign convention: compression is negative in Asap.
        if has_model
            Pu_N = 0.0; Mu_x_Nm = 0.0; Mu_y_Nm = 0.0
            for seg_idx in segment_indices(col)
                seg = struc.segments[seg_idx]
                eidx = seg.edge_idx
                (eidx < 1 || eidx > length(struc.asap_model.elements)) && continue
                el = struc.asap_model.elements[eidx]
                isempty(el.forces) && continue
                f = el.forces
                n = length(f)
                
                # Axial (max compression magnitude)
                Pu_N = max(Pu_N, abs(f[1]))
                if n >= 7; Pu_N = max(Pu_N, abs(f[7])); end
                
                # Strong-axis moment My (indices 5, 11)
                if n >= 5;  Mu_x_Nm = max(Mu_x_Nm, abs(f[5])); end
                if n >= 11; Mu_x_Nm = max(Mu_x_Nm, abs(f[11])); end
                
                # Weak-axis moment Mz (indices 6, 12)
                if n >= 6;  Mu_y_Nm = max(Mu_y_Nm, abs(f[6])); end
                if n >= 12; Mu_y_Nm = max(Mu_y_Nm, abs(f[12])); end
            end
            
            result.Pu   = Pu_N * u"N" |> u"kN"
            result.Mu_x = Mu_x_Nm * u"N*m" |> u"kN*m"
            result.Mu_y = Mu_y_Nm * u"N*m" |> u"kN*m"
        end
        
        # ─── Approximate capacity ratios ───
        is_steel = col_sec isa StructuralSizer.ISymmSection ||
                   col_sec isa StructuralSizer.HSSRectSection ||
                   col_sec isa StructuralSizer.HSSRoundSection

        Pu_N_val = ustrip(u"N", result.Pu)
        Mu_Nm_val = ustrip(u"N*m", result.Mu_x)

        if is_steel && hasproperty(col_sec, :A) && hasproperty(col_sec, :material) &&
           !isnothing(col_sec.material)
            # AISC 360-16 §E1 — φPn = 0.9 × Fcr × Ag  (using Fy as upper bound)
            Fy_Pa = ustrip(u"Pa", col_sec.material.Fy)
            A_m2 = ustrip(u"m^2", col_sec.A)
            φPn = 0.9 * Fy_Pa * A_m2  # N (conservative: ignores buckling reduction)
            result.axial_ratio = φPn > 0 ? Pu_N_val / φPn : 0.0

            # AISC 360-16 §F2-1 — φMn = 0.9 × Fy × Zx
            if hasproperty(col_sec, :Zx)
                Zx_m3 = ustrip(u"m^3", col_sec.Zx)
                φMn = 0.9 * Fy_Pa * Zx_m3  # N·m
            else
                φMn = 0.0
            end

            # AISC H1-1a/b P-M interaction
            Pr_Pc = φPn > 0 ? Pu_N_val / φPn : 0.0
            Mr_Mc = φMn > 0 ? Mu_Nm_val / φMn : 0.0
            if Pr_Pc >= 0.2
                result.interaction_ratio = Pr_Pc + (8.0 / 9.0) * Mr_Mc  # H1-1a
            else
                result.interaction_ratio = Pr_Pc / 2.0 + Mr_Mc          # H1-1b
            end

        elseif !is_steel && !isnothing(col.c1) && !isnothing(col.c2)
            # ACI 318-19 §22.4.2 — RC columns (rectangular or circular)
            Ag = result.shape == :circular ?
                 ustrip(u"m^2", π / 4 * col.c1^2) :
                 ustrip(u"m^2", col.c1 * col.c2)
            ρg = 0.01  # ACI 318 minimum
            Ast = ρg * Ag
            φ = 0.65  # tied column
            φPn0 = 0.80 * φ * (0.85 * fc′_Pa * (Ag - Ast) + fy_Pa * Ast)  # N

            result.axial_ratio = φPn0 > 0 ? Pu_N_val / φPn0 : 0.0

            # φMn ≈ 0.9 × fy × Ast × (d − a/2) — rough for rebar at mid-depth
            d_m = result.shape == :circular ?
                  ustrip(u"m", col.c1) :
                  ustrip(u"m", max(col.c1, col.c2))
            b_m = result.shape == :circular ?
                  ustrip(u"m", col.c1) :
                  ustrip(u"m", min(col.c1, col.c2))
            a_est = b_m > 0 ? fy_Pa * Ast / (0.85 * fc′_Pa * b_m) : 0.0
            φMn_est = 0.90 * fy_Pa * Ast * (d_m * 0.4 - a_est / 2)  # N·m

            if φMn_est > 0
                result.interaction_ratio = max(result.axial_ratio, Mu_Nm_val / φMn_est)
            else
                result.interaction_ratio = result.axial_ratio
            end
        end
        
        # ─── Punching shear from slab results ───
        trib_area = column_tributary_area(struc, col)
        trib_area_m2 = !isnothing(trib_area) ? uconvert(u"m^2", trib_area) : 0.0u"m^2"
        
        if haskey(punch_map, col_idx)
            pr = punch_map[col_idx]
            # Convert slab punching NamedTuple → PunchingDesignResult
            vu = ustrip(u"Pa", pr.vu)
            φvc = ustrip(u"Pa", pr.φvc)
            b0_m = ustrip(u"m", pr.b0)
            d_est = !isnothing(col.c1) ? 0.8 * ustrip(u"m", col.c1) : 0.15  # rough
            
            # Back-compute Vu = vu × b0 × d  (approximate, for display only)
            Vu_N = vu * b0_m * d_est
            φVc_N = φvc * b0_m * d_est
            
            result.punching = PunchingDesignResult(
                Vu = Vu_N * u"N" |> u"kN",
                φVc = φVc_N * u"N" |> u"kN",
                ratio = pr.ratio,
                ok = pr.ok,
                critical_perimeter = pr.b0 |> u"m",
                tributary_area = trib_area_m2,
            )
        elseif !isnothing(trib_area)
            result.punching = PunchingDesignResult(
                Vu = 0.0u"kN", φVc = 0.0u"kN",
                ratio = 0.0, ok = true,
                critical_perimeter = 0.0u"m",
                tributary_area = trib_area_m2,
            )
        end
        
        # ─── Overall ok ───
        result.ok = result.axial_ratio ≤ 1.0 &&
                    result.interaction_ratio ≤ 1.0 &&
                    (isnothing(result.punching) || result.punching.ok)
        
        design.columns[col_idx] = result
    end
end

"""Populate beam design results from struc.beams with forces from the Asap model."""
function _populate_beam_results!(design::BuildingDesign, struc::BuildingStructure)
    has_model = !isnothing(struc.asap_model) && !isempty(struc.asap_model.elements)
    el_loads_map = has_model ? Asap.get_elemental_loads(struc.asap_model) : nothing

    for (beam_idx, beam) in enumerate(struc.beams)
        result = BeamDesignResult()
        sec = section(beam)
        result.section_obj = sec
        if !isnothing(sec)
            result.section_size = string(sec)
        end

        # Member length for material takeoff
        L_total = member_length(beam)
        result.member_length = L_total isa Unitful.Quantity ? uconvert(u"m", L_total) : L_total * u"m"

        # Extract peak Mu, Vu from Asap internal forces
        if has_model
            Mu_Nm = 0.0; Vu_N = 0.0
            for seg_idx in segment_indices(beam)
                seg = struc.segments[seg_idx]
                eidx = seg.edge_idx
                (eidx < 1 || eidx > length(struc.asap_model.elements)) && continue
                el = struc.asap_model.elements[eidx]
                eid = el.elementID
                loads = (eid >= 1 && eid <= length(el_loads_map)) ? el_loads_map[eid] : Asap.AbstractLoad[]
                if !isempty(loads)
                    fd = Asap.ElementForceAndDisplacement(el, loads; resolution=20)
                    Mu_Nm = max(Mu_Nm, maximum(abs, fd.forces.My))
                    Vu_N  = max(Vu_N,  maximum(abs, fd.forces.Vz))
                elseif !isempty(el.forces)
                    f = el.forces; n = length(f)
                    if n >= 5;  Mu_Nm = max(Mu_Nm, abs(f[5])); end
                    if n >= 11; Mu_Nm = max(Mu_Nm, abs(f[11])); end
                    if n >= 3;  Vu_N  = max(Vu_N,  abs(f[3])); end
                    if n >= 9;  Vu_N  = max(Vu_N,  abs(f[9])); end
                end
            end
            result.Mu = Mu_Nm * u"N*m" |> u"kN*m"
            result.Vu = Vu_N  * u"N"   |> u"kN"
        end

        # Approximate capacity ratios and weight for steel sections
        vols = volumes(beam)
        mat = isempty(vols) ? nothing : first(keys(vols))
        if !isnothing(sec) && hasproperty(sec, :A) && !isnothing(mat) && mat isa StructuralSizer.Metal
            wpl = StructuralSizer.weight_per_length(sec, mat)
            result.weight = uconvert(u"kg", wpl * result.member_length)

            # Flexure capacity: φMn ≈ 0.9 × Fy × Zx (plastic moment, AISC F2-1)
            if hasproperty(sec, :Zx)
                Fy = mat.Fy
                φMn = 0.9 * Fy * sec.Zx
                φMn_kNm = ustrip(u"kN*m", φMn)
                Mu_kNm = ustrip(u"kN*m", result.Mu)
                result.flexure_ratio = φMn_kNm > 0 ? Mu_kNm / φMn_kNm : 0.0
            end

            # Shear capacity: φVn ≈ 1.0 × 0.6 × Fy × Aw (AISC G2, rolled I-shapes)
            if hasproperty(sec, :d) && hasproperty(sec, :tw)
                Aw = sec.d * sec.tw
                φVn = 1.0 * 0.6 * mat.Fy * Aw
                φVn_kN = ustrip(u"kN", φVn)
                Vu_kN = ustrip(u"kN", result.Vu)
                result.shear_ratio = φVn_kN > 0 ? Vu_kN / φVn_kN : 0.0
            end
        end

        result.ok = result.flexure_ratio ≤ 1.0 && result.shear_ratio ≤ 1.0
        design.beams[beam_idx] = result
    end
end

"""Populate foundation design results from struc.foundations (all values normalized to SI)."""
function _populate_foundation_results!(design::BuildingDesign, struc::BuildingStructure)
    fdn_params = design.params.foundation_options
    soil = isnothing(fdn_params) ? StructuralSizer.medium_sand : fdn_params.soil
    qa = uconvert(u"kPa", soil.qa)

    for (fdn_idx, fdn) in enumerate(struc.foundations)
        isnothing(fdn.result) && continue

        total_reaction = 0.0u"kN"
        for sup_idx in fdn.support_indices
            sup = struc.supports[sup_idx]
            total_reaction += uconvert(u"kN", sup.forces[3])
        end

        gid = isnothing(fdn.group_id) ? 0 : Int(fdn.group_id % typemax(Int))

        r = fdn.result
        fdn_L = uconvert(u"m", StructuralSizer.footing_length(r))
        fdn_W = uconvert(u"m", StructuralSizer.footing_width(r))
        gov_util = StructuralSizer.utilization(r)

        # Re-derive bearing ratio: service reaction / (qa × footprint)
        # The design routine uses service-level Ps, but we only have factored
        # reaction here. Use a 1.4 factor approximation to get service load.
        footprint = fdn_L * fdn_W
        Ps_approx = total_reaction / 1.4  # approximate service from factored
        bearing = if ustrip(u"kPa", qa) > 0 && ustrip(u"m^2", footprint) > 0
            ustrip(u"kPa", Ps_approx / footprint) / ustrip(u"kPa", qa)
        else
            0.0
        end
        bearing_ratio = clamp(bearing, 0.0, gov_util)

        # Punching ratio: if governing utilization exceeds bearing, the
        # difference is attributable to punching shear.
        punching_ratio = gov_util > bearing_ratio ? gov_util : 0.0

        result = FoundationDesignResult(
            length = fdn_L,
            width = fdn_W,
            depth = uconvert(u"m", r.D),
            reaction = total_reaction,
            bearing_ratio = bearing_ratio,
            punching_ratio = punching_ratio,
            ok = gov_util <= 1.0,
            concrete_volume = uconvert(u"m^3", StructuralSizer.concrete_volume(r)),
            steel_volume = uconvert(u"m^3", StructuralSizer.steel_volume(r)),
            group_id = gid,
        )

        design.foundations[fdn_idx] = result
    end
end

"""Axis-aligned bounding box of all slab cell vertices in meters: (xmin, xmax, ymin, ymax)."""
function _slab_bbox_m(struc::BuildingStructure, slab)
    skel = struc.skeleton
    xmin = ymin =  Inf
    xmax = ymax = -Inf
    for ci in slab.cell_indices
        cell = struc.cells[ci]
        for vi in skel.face_vertex_indices[cell.face_idx]
            c = Meshes.coords(skel.vertices[vi])
            x = ustrip(u"m", c.x)
            y = ustrip(u"m", c.y)
            x < xmin && (xmin = x)
            x > xmax && (xmax = x)
            y < ymin && (ymin = y)
            y > ymax && (ymax = y)
        end
    end
    return (xmin=xmin, xmax=xmax, ymin=ymin, ymax=ymax)
end

"""
Trimmed full plan extents (with units) of a drop panel at column center `(cx, cy)`,
clamped to the slab bounding box.  Returns `(a1_eff, a2_eff)` in meters.
"""
function _trimmed_drop_extents_m(dp::StructuralSizer.DropPanelGeometry, cx::Float64, cy::Float64, bbox)
    a1 = ustrip(u"m", dp.a_drop_1)
    a2 = ustrip(u"m", dp.a_drop_2)
    x0 = max(cx - a1, bbox.xmin)
    x1 = min(cx + a1, bbox.xmax)
    y0 = max(cy - a2, bbox.ymin)
    y1 = min(cy + a2, bbox.ymax)
    eff1 = max(x1 - x0, 0.0) * u"m"
    eff2 = max(y1 - y0, 0.0) * u"m"
    return (eff1, eff2)
end

# Must match `_serialize_slabs` / `agent_situation_card` slab failure predicate.
_slab_design_ok(sr::SlabDesignResult) = sr.converged && sr.deflection_ok && sr.punching_ok

function _slab_governing_ratio_label(idx::Int, sr::SlabDesignResult)
    rd = sr.deflection_ratio
    rp = sr.punching_max_ratio
    if rd >= rp
        return rd, "Slab $idx (deflection)"
    else
        return rp, "Slab $idx (punching)"
    end
end

"""Compute summary metrics: critical element search + material quantity aggregation."""
function _compute_design_summary!(design::BuildingDesign, struc::BuildingStructure, params::DesignParameters)
    summary = design.summary

    # ── Critical element search ──────────────────────────────────────────
    # `glob_*` = highest ratio anywhere (utilization narrative).
    # `fail_*` = worst among elements that fail API-style `ok` (matches chat / GET /result).
    glob_ratio = 0.0
    glob_elem = ""
    fail_ratio = 0.0
    fail_elem = ""
    all_ok = true

    for (idx, slab_result) in design.slabs
        r_glob, lab_glob = _slab_governing_ratio_label(idx, slab_result)
        if r_glob > glob_ratio
            glob_ratio = r_glob
            glob_elem = lab_glob
        end
        if !_slab_design_ok(slab_result)
            all_ok = false
            g = slab_diagnostic_governing_check(slab_result)
            rd = slab_result.deflection_ratio
            rp = slab_result.punching_max_ratio
            r_fail = max(rd, rp)
            if g in ("reinforcement_design", "reinforcement_design_secondary", "transfer_reinforcement", "non_convergence")
                r_fail = max(r_fail, 1.0)
            end
            lab_fail = "Slab $idx ($g)"
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab_fail
            end
        end
    end

    for (idx, col_result) in design.columns
        r_ax = col_result.axial_ratio
        r_int = col_result.interaction_ratio
        r_punch = (!isnothing(col_result.punching) ? col_result.punching.ratio : 0.0)
        r_glob = max(r_ax, r_int, r_punch)
        g_glob = if r_ax >= r_int && r_ax >= r_punch
            "axial_compression"
        elseif r_int >= r_punch
            "pm_interaction"
        else
            "punching_shear_col"
        end
        lab_glob = "Column $idx ($g_glob)"
        if r_glob > glob_ratio
            glob_ratio = r_glob
            glob_elem = lab_glob
        end
        if !col_result.ok
            all_ok = false
            r_fail = max(r_ax, r_int, r_punch)
            if r_fail < 1.0
                r_fail = 1.0
            end
            lab_fail = "Column $idx ($(column_diagnostic_governing_check(col_result)))"
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab_fail
            end
        end
    end

    for (idx, beam_result) in design.beams
        r_glob = max(beam_result.flexure_ratio, beam_result.shear_ratio)
        g_glob = beam_result.flexure_ratio >= beam_result.shear_ratio ? "flexure" : "shear"
        lab_glob = "Beam $idx ($g_glob)"
        if r_glob > glob_ratio
            glob_ratio = r_glob
            glob_elem = lab_glob
        end
        if !beam_result.ok
            all_ok = false
            r_fail = r_glob < 1.0 ? 1.0 : r_glob
            lab_fail = "Beam $idx ($(beam_diagnostic_governing_check(beam_result)))"
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab_fail
            end
        end
    end

    for (idx, fdn_result) in design.foundations
        fdn_ratios = (
            fdn_result.bearing_ratio  => "bearing",
            fdn_result.punching_ratio => "punching",
            fdn_result.flexure_ratio  => "flexure",
        )
        for (r, check_name) in fdn_ratios
            if r > glob_ratio
                glob_ratio = r
                glob_elem = "Foundation $idx ($check_name)"
            end
        end
        if !fdn_result.ok
            all_ok = false
            r_fail = max(fdn_result.bearing_ratio, fdn_result.punching_ratio, fdn_result.flexure_ratio)
            if r_fail < 1.0
                r_fail = 1.0
            end
            lab_fail = "Foundation $idx ($(foundation_diagnostic_governing_check(fdn_result)))"
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab_fail
            end
        end
    end

    if !all_ok && (!isempty(fail_elem) || fail_ratio > 0)
        summary.critical_ratio = fail_ratio > 0 ? fail_ratio : glob_ratio
        summary.critical_element = !isempty(fail_elem) ? fail_elem : glob_elem
    else
        summary.critical_ratio = glob_ratio
        summary.critical_element = glob_elem
    end
    summary.all_checks_pass = all_ok

    # ── Material quantity aggregation ────────────────────────────────────
    total_conc_vol = 0.0u"m^3"
    total_steel_wt = 0.0u"kg"
    total_rebar_wt = 0.0u"kg"
    total_timber_vol = 0.0u"m^3"

    ρ_conc = 2400.0u"kg/m^3"   # typical normal-weight concrete
    ρ_rebar = 7850.0u"kg/m^3"  # steel density

    # ── Slabs: aggregate from struc.slabs[].volumes (MaterialVolumes dict) ──
    for slab in struc.slabs
        for (mat, vol) in slab.volumes
            v = uconvert(u"m^3", vol)
            if mat isa StructuralSizer.Concrete
                total_conc_vol += v
            elseif mat isa StructuralSizer.RebarSteel
                total_rebar_wt += uconvert(u"kg", v * mat.ρ)
            elseif mat isa StructuralSizer.StructuralSteel
                total_steel_wt += uconvert(u"kg", v * mat.ρ)
            elseif mat isa StructuralSizer.Timber
                total_timber_vol += v
            end
        end
        # Punching reinforcement: studs, shear caps, capitals from slab result
        r = slab.result
        if r isa StructuralSizer.FlatPlatePanelResult && hasproperty(r, :punching_check)
            pc = r.punching_check
            if hasproperty(pc, :details)
                for (col_idx, detail) in pc.details
                    # Stud steel volume
                    if hasproperty(detail, :studs) && !isnothing(detail.studs)
                        sv = StructuralSizer.stud_steel_volume(detail.studs)
                        total_rebar_wt += uconvert(u"kg", sv * ρ_rebar)
                    end
                    # Shear cap concrete (needs column dims from struc.columns)
                    if hasproperty(detail, :shear_cap) && !isnothing(detail.shear_cap)
                        sc = detail.shear_cap
                        if col_idx >= 1 && col_idx <= length(struc.columns)
                            col = struc.columns[col_idx]
                            if !isnothing(col.c1) && !isnothing(col.c2)
                                cv = StructuralSizer.shear_cap_concrete_volume(sc, col.c1, col.c2)
                                total_conc_vol += uconvert(u"m^3", cv)
                            end
                        end
                    end
                    # Column capital concrete
                    if hasproperty(detail, :capital) && !isnothing(detail.capital)
                        cv = StructuralSizer.capital_concrete_volume(detail.capital)
                        total_conc_vol += uconvert(u"m^3", cv)
                    end
                end
            end
        end
        # Drop panel concrete — one panel per supporting column, trimmed to slab boundary
        if !isnothing(slab.drop_panel)
            dp = slab.drop_panel
            slab_cells = Set(slab.cell_indices)
            slab_bbox = _slab_bbox_m(struc, slab)
            for (col_idx, col) in enumerate(struc.columns)
                isempty(intersect(col.tributary_cell_indices, slab_cells)) && continue
                v_idx = col.vertex_idx
                (v_idx < 1 || v_idx > length(struc.skeleton.vertices)) && continue
                c = Meshes.coords(struc.skeleton.vertices[v_idx])
                cx = ustrip(u"m", c.x)
                cy = ustrip(u"m", c.y)
                a1_eff, a2_eff = _trimmed_drop_extents_m(dp, cx, cy, slab_bbox)
                dv = StructuralSizer.drop_panel_concrete_volume(dp, a1_eff, a2_eff)
                total_conc_vol += uconvert(u"m^3", dv)
            end
        end
    end

    # ── Columns: concrete + rebar from geometry ──
    for (_, col_result) in design.columns
        Ag = col_result.Ag
        As = col_result.As_total
        h = col_result.height
        if Ag > 0.0u"m^2" && h > 0.0u"m"
            total_conc_vol += (Ag - As) * h
            total_rebar_wt += uconvert(u"kg", As * h * ρ_rebar)
        end
    end

    # ── Beams: steel weight from beam results ──
    for (_, beam_result) in design.beams
        total_steel_wt += beam_result.weight
    end

    # ── Foundations: from Sizer-level volumes ──
    for (_, fdn_result) in design.foundations
        total_conc_vol += fdn_result.concrete_volume
        total_rebar_wt += uconvert(u"kg", fdn_result.steel_volume * ρ_rebar)
    end

    summary.concrete_volume = total_conc_vol
    summary.steel_weight = total_steel_wt
    summary.rebar_weight = total_rebar_wt
    summary.timber_volume = total_timber_vol

    # ── Embodied carbon ──
    try
        ec = compute_building_ec(struc, params)
        summary.embodied_carbon = ec.total_ec
    catch e
        @warn "Embodied carbon computation failed — defaulting to 0.0" exception=(e, catch_backtrace())
        summary.embodied_carbon = 0.0
    end
end

# =============================================================================
# Design Comparison Utilities
# =============================================================================

"""
    compare_designs(designs::Vector{BuildingDesign})

Create a comparison table of multiple designs.
"""
function compare_designs(designs::Vector{BuildingDesign})
    results = Dict{String, Dict{Symbol, Any}}()
    
    for d in designs
        results[d.params.name] = Dict(
            :concrete_volume => d.summary.concrete_volume,
            :steel_weight => d.summary.steel_weight,
            :embodied_carbon => d.summary.embodied_carbon,
            :all_ok => d.summary.all_checks_pass,
            :critical_ratio => d.summary.critical_ratio,
            :compute_time => d.compute_time_s
        )
    end
    
    return results
end

"""Two-design convenience: wraps into a vector and delegates."""
compare_designs(d1::BuildingDesign, d2::BuildingDesign) = compare_designs([d1, d2])
