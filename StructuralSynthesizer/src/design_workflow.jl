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

function build_pipeline(params::DesignParameters)
    stages = PipelineStage[]
    
    floor_opts = resolve_floor_options(params)
    floor_type = _infer_floor_type(floor_opts)
    
    # Extract column options for flat plate/slab sizing (needed for design_details)
    column_opts = _get_column_opts(params)
    
    # ─── Stage 1: Slab sizing (always) ─── needs sync to push slab self-weight
    push!(stages, PipelineStage(struc -> begin
        StructuralSizer.size_slabs!(struc; options=floor_opts, verbose=false,
                                    max_iterations=params.max_iterations,
                                    fire_rating=params.fire_rating,
                                    column_opts=column_opts)
        update_slab_volumes!(struc; options=floor_opts)
    end, true))
    
    # ─── Stage 2: Beam + column sizing ───
    if floor_type in (:flat_plate, :flat_slab)
        # Flat plate/slab: _reconcile_columns! self-syncs when columns grow
        push!(stages, PipelineStage(struc -> _reconcile_columns!(struc, params), false))
    else
        # Beam-based systems: iterative beam/column sizing — needs full sync
        push!(stages, PipelineStage(struc -> _size_beams_columns!(struc, params), true))
    end
    
    # ─── Stage 3: Foundations (if requested) ─── no Asap model changes
    if !isnothing(params.foundation_options)
        push!(stages, PipelineStage(struc -> _size_foundations!(struc, params.foundation_options), false))
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
function capture_design(struc::BuildingStructure, params::DesignParameters; t_start=nothing)
    design = BuildingDesign(struc, params)
    _populate_slab_results!(design, struc)
    _populate_column_results!(design, struc)
    _populate_beam_results!(design, struc)
    _populate_foundation_results!(design, struc)
    _compute_design_summary!(design, struc, params)
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
function design_building(struc::BuildingStructure, params::DesignParameters)
    t_start = time()
    
    prepare!(struc, params)

    # Pre-sizing validation: fail fast if DDM/EFM/FEA applicability checks fail
    ok, val_errors = run_pre_sizing_validation(struc, params)
    if !ok
        throw(PreSizingValidationError(val_errors))
    end
    
    for stage in build_pipeline(params)
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params=params)
    end
    
    design = capture_design(struc, params; t_start=t_start)
    
    # ─── Restore ───
    restore!(struc; geometry_is_centerline=params.geometry_is_centerline)
    sync_asap!(struc; params=params)
    
    return design
end

"""
    design_building(struc::BuildingStructure; kwargs...) -> BuildingDesign

Convenience method that creates DesignParameters from keyword arguments.
"""
function design_building(struc::BuildingStructure; kwargs...)
    params = DesignParameters(; kwargs...)
    return design_building(struc, params)
end

# =============================================================================
# Pipeline Stage Implementations
# =============================================================================

"""Extract ConcreteColumnOptions from DesignParameters, or `nothing` if steel/missing."""
function _get_column_opts(params::DesignParameters)
    opts = params.columns
    opts isa ConcreteColumnOptions ? opts : nothing
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
    fc = _get_design_fc(params)
    fc_Pa = ustrip(u"Pa", uconvert(u"Pa", fc))
    grew = 0

    # Material constants for Asap section rebuild
    conc = resolve_concrete(params)
    E_Pa = ustrip(u"Pa", conc.E)
    ν_c = conc.ν
    G_Pa = E_Pa / (2.0 * (1.0 + ν_c))
    ρ_kg = ustrip(u"kg/m^3", conc.ρ)
    I_factor = 0.70  # ACI 318-11 §10.10.4.1

    for col in struc.columns
        isnothing(col.c1) && continue
        
        # Extract max axial from Asap model
        Pu_N = _column_asap_Pu(struc, col)
        
        # Use shape-aware growth if column_opts are available in params
        _col_opts = _get_column_opts(params)
        _shape_con = !isnothing(_col_opts) ? _col_opts.shape_constraint : :square
        _max_ar   = !isnothing(_col_opts) ? _col_opts.max_aspect_ratio : 2.0
        _c_inc    = !isnothing(_col_opts) ? _col_opts.size_increment : 0.5u"inch"
        
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
function _size_beams_columns!(struc::BuildingStructure, params::DesignParameters)
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
        _run_p_delta_if_needed!(struc, column_opts; verbose=hasproperty(params, :verbose) ? params.verbose : false)
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
    verbose = hasproperty(params, :verbose) ? params.verbose : false

    n_cols_bc = length(struc.columns)
    prev_demands = Vector{Float64}(undef, n_cols_bc)
    curr_demands = Vector{Float64}(undef, n_cols_bc)
    first_iter = true
    
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

"""Size foundations using FoundationParameters."""
function _size_foundations!(struc::BuildingStructure, fp::FoundationParameters)
    initialize_supports!(struc)
    if isempty(struc.supports)
        @warn "Skipping foundation sizing: no supports found. Ensure support vertices are at grade."
        return
    end
    initialize_foundations!(struc)
    group_foundations_by_reaction!(struc; tolerance=fp.group_tolerance)
    size_foundations_grouped!(struc;
        soil = fp.soil,
        concrete = fp.concrete,
        rebar = fp.rebar,
        pier_width = fp.pier_width,
        min_depth = fp.min_depth,
    )
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
        # Non-converged slabs have result=nothing but still carry design_details
        if isnothing(slab.result)
            dd = hasproperty(slab, :design_details) ? slab.design_details : nothing
            if !isnothing(dd) && hasproperty(dd, :converged) && !dd.converged
                design.slabs[slab_idx] = SlabDesignResult(
                    thickness   = 0.0u"m",
                    self_weight = 0.0u"kPa",
                    converged       = false,
                    failure_reason  = hasproperty(dd, :failure_reason) ? dd.failure_reason : "unknown",
                    failing_check   = hasproperty(dd, :failing_check)  ? dd.failing_check  : "",
                    iterations      = hasproperty(dd, :iterations)     ? dd.iterations      : 0,
                    pattern_loading = hasproperty(dd, :pattern_loading) ? dd.pattern_loading : false,
                )
            end
            continue
        end
        r = slab.result   # FlatPlatePanelResult (or other AbstractFloorResult)
        
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
        if !isnothing(col.c1) && !isnothing(col.c2)
            c1_in = round(Int, ustrip(u"inch", col.c1))
            c2_in = round(Int, ustrip(u"inch", col.c2))
            result.section_size = "$(c1_in)×$(c2_in)"
            result.c1 = uconvert(u"m", col.c1)
            result.c2 = uconvert(u"m", col.c2)
        end
        result.shape = hasproperty(col, :shape) ? col.shape : :rectangular
        
        # ─── Material takeoff fields ───
        col_L = member_length(col)
        result.height = col_L isa Unitful.Quantity ? uconvert(u"m", col_L) : col_L * u"m"
        if !isnothing(col.c1) && !isnothing(col.c2)
            result.Ag = uconvert(u"m^2", col.c1 * col.c2)
        end
        col_sec = section(col)
        result.section_obj = col_sec
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
        # ACI 318-11 §10.3.6.2 — maximum axial capacity for tied columns:
        #   φPn(max) = 0.80 × φ × [0.85 × f'c × (Ag − Ast) + fy × Ast]
        # We use ρg = 1% (code minimum) for a lower-bound estimate.
        if !isnothing(col.c1) && !isnothing(col.c2)
            Ag = ustrip(u"m^2", col.c1 * col.c2)
            ρg = 0.01  # ACI 318 minimum
            Ast = ρg * Ag
            φ = 0.65  # tied column
            φPn0 = 0.80 * φ * (0.85 * fc′_Pa * (Ag - Ast) + fy_Pa * Ast)  # N
            
            Pu_N_val = ustrip(u"N", result.Pu)
            result.axial_ratio = φPn0 > 0 ? Pu_N_val / φPn0 : 0.0
            
            # Simple interaction: max(Pu/φPn0, Mu/φMn_est)
            # φMn ≈ 0.9 × fy × Ast × (d − a/2) — rough for rebar at mid-depth
            d_m = ustrip(u"m", max(col.c1, col.c2))
            a_est = fy_Pa * Ast / (0.85 * fc′_Pa * ustrip(u"m", min(col.c1, col.c2)))
            φMn_est = 0.90 * fy_Pa * Ast * (d_m * 0.4 - a_est / 2)  # N·m (very conservative)
            
            Mu_Nm_val = ustrip(u"N*m", result.Mu_x)
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
    for (fdn_idx, fdn) in enumerate(struc.foundations)
        isnothing(fdn.result) && continue
        
        total_reaction = 0.0u"kN"
        for sup_idx in fdn.support_indices
            sup = struc.supports[sup_idx]
            total_reaction += uconvert(u"kN", sup.forces[3])
        end
        
        gid = isnothing(fdn.group_id) ? 0 : Int(fdn.group_id % typemax(Int))
        
        result = FoundationDesignResult(
            length = uconvert(u"m", StructuralSizer.footing_length(fdn.result)),
            width = uconvert(u"m", StructuralSizer.footing_width(fdn.result)),
            depth = uconvert(u"m", fdn.result.D),
            reaction = total_reaction,
            bearing_ratio = StructuralSizer.utilization(fdn.result),
            ok = StructuralSizer.utilization(fdn.result) <= 1.0,
            concrete_volume = uconvert(u"m^3", StructuralSizer.concrete_volume(fdn.result)),
            steel_volume = uconvert(u"m^3", StructuralSizer.steel_volume(fdn.result)),
            group_id = gid,
        )
        
        design.foundations[fdn_idx] = result
    end
end

"""Compute summary metrics: critical element search + material quantity aggregation."""
function _compute_design_summary!(design::BuildingDesign, struc::BuildingStructure, params::DesignParameters)
    summary = design.summary

    # ── Critical element search ──────────────────────────────────────────
    max_ratio = 0.0
    critical_elem = ""
    all_ok = true

    for (idx, slab_result) in design.slabs
        if slab_result.deflection_ratio > max_ratio
            max_ratio = slab_result.deflection_ratio
            critical_elem = "Slab $idx (deflection)"
        end
        if !slab_result.deflection_ok
            all_ok = false
        end
    end

    for (idx, col_result) in design.columns
        r = col_result.interaction_ratio
        if r > max_ratio
            max_ratio = r
            critical_elem = "Column $idx (interaction)"
        end
        if !isnothing(col_result.punching) && col_result.punching.ratio > max_ratio
            max_ratio = col_result.punching.ratio
            critical_elem = "Column $idx (punching)"
        end
        if !col_result.ok
            all_ok = false
        end
    end

    for (idx, beam_result) in design.beams
        r = max(beam_result.flexure_ratio, beam_result.shear_ratio)
        if r > max_ratio
            max_ratio = r
            critical_elem = "Beam $idx (flexure/shear)"
        end
        if !beam_result.ok
            all_ok = false
        end
    end

    for (idx, fdn_result) in design.foundations
        if fdn_result.bearing_ratio > max_ratio
            max_ratio = fdn_result.bearing_ratio
            critical_elem = "Foundation $idx (bearing)"
        end
        if !fdn_result.ok
            all_ok = false
        end
    end

    summary.critical_ratio = max_ratio
    summary.critical_element = critical_elem
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
        # Drop panel concrete (additional thickness beyond the slab)
        if !isnothing(slab.drop_panel)
            dp = slab.drop_panel
            h_slab = r isa StructuralSizer.FlatPlatePanelResult ? r.thickness : 0.0u"m"
            if h_slab > 0.0u"m"
                a1_full = 2 * dp.a_drop_1  # full extent
                a2_full = 2 * dp.a_drop_2
                dv = StructuralSizer.drop_panel_concrete_volume(dp.h_drop, a1_full, a2_full, h_slab)
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
