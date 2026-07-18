# ==============================================================================
# Iterative Structure Sizing
# ==============================================================================
# Top-level sizing function that handles load coupling between members.

"""
    size!(design::BuildingDesign; kwargs...)

Size all structural members iteratively until loads converge.

The sizing sequence handles load coupling:
1. Size beams (with estimated column loads)
2. Re-analyze (beam self-weight updates column demands)
3. Size columns
4. Check convergence (did column demands change significantly?)
5. Repeat steps 1-4 until stable
6. Size foundations (with final column reactions)

Uses `design.params` for all sizing options:
- `params.beams`: `SteelBeamOptions`, `ConcreteBeamOptions`, or `nothing`
- `params.columns`: `SteelColumnOptions`, `ConcreteColumnOptions`, or `nothing`

# Keyword Arguments
- `max_iterations::Int = 3`: Maximum beam/column sizing iterations
- `convergence_tol::Float64 = 0.05`: Stop when max demand change < 5%
- `size_foundations::Bool = true`: Size foundations after members converge
- `verbose::Bool = true`: Log iteration progress

# Example
```julia
design = BuildingDesign(struc, DesignParameters(
    columns = ConcreteColumnOptions(material = NWC_5000),
    beams = SteelBeamOptions(deflection_limit = 1/360),
))

size!(design)  # Iteratively sizes everything
```
"""
function size!(
    design::BuildingDesign;
    max_iterations::Int = 3,
    convergence_tol::Float64 = 0.05,
    size_foundations::Bool = true,
    verbose::Bool = true,
)
    struc = design.structure
    params = design.params

    # Front-door member_group_overrides guard (Phase B, PARITY with design_building /
    # capture_design / run_pre_sizing_validation). The struc-aware guard refuses every
    # EFFECTIVE override that no beam-sizing path can honor: a flat-plate/flat-slab
    # floor, NON-STEEL beam options (concrete / NLP / PixelFrame `_size_beams_impl!`
    # overloads accept `member_group_overrides` but neither honor nor throw — a silent
    # drop), n_max_sections>0 coupling, a MULTI-MATERIAL steel catalog (opts.materials —
    # the batched feasible mask is single-material-space and the multi-material solver
    # would silently collapse to material 1), and a LOOSER per-group
    # deflection_limit/max_depth. It MUST re-run here, not only in the constructor:
    # `design.params.member_group_overrides` is a live, mutable dict, so an override
    # added AFTER construction (when the dict was still empty and the constructor guard
    # short-circuited) would otherwise be silently dropped by `size!`. Honorable
    # single-material steel-beam overrides PASS this door and are honored (or refused
    # for a bad gid) at the size-time gate inside `_size_beams_impl!`. Same struc-aware
    # overload as design_types.jl:658. (Engineering-scope guard — no code citation.)
    _assert_member_group_overrides_unsupported(params, struc)

    # Resolve options from params (or use defaults)
    beam_opts   = something(params.beams,   StructuralSizer.SteelBeamOptions())
    column_opts = something(params.columns, StructuralSizer.SteelColumnOptions())

    # Universal size-time gate (Phase B): thread the per-design member_group_overrides
    # into every beam-sizing pass so the honor-or-throw gid gate inside
    # `_size_beams_impl!` fires on the exported `size!` path too — it is otherwise
    # SKIPPED (`size_beams!`'s kwarg defaults to `nothing`), silently dropping an
    # effective override. Empty overrides collapse to `nothing`, a strict
    # byte-identical no-op, mirroring `_size_beams_columns!` in design_workflow.jl.
    # `design.params` is authoritative here (a `BuildingStructure` has no
    # `design_parameters` field). (Engineering sizing knobs — no code citation.)
    mgo = isempty(params.member_group_overrides) ? nothing : params.member_group_overrides

    n_cols_sz = length(struc.columns)
    prev_demands = Vector{Float64}(undef, n_cols_sz)
    curr_demands = Vector{Float64}(undef, n_cols_sz)
    converged = false
    first_iter = true

    # =========================================================================
    # Iterative beam/column sizing
    # =========================================================================
    for iter in 1:max_iterations
        verbose && @info "Sizing iteration $iter/$max_iterations"

        # --- Size beams ---
        size_beams!(struc, beam_opts; reanalyze = false, member_group_overrides = mgo)

        # --- Re-analyze with updated beam self-weight ---
        # Topology unchanged; only sections/loads differ → lightweight reprocess
        if struc.asap_model.processed
            Asap.update!(struc.asap_model)
        else
            Asap.process!(struc.asap_model)
        end
        Asap.solve!(struc.asap_model)

        # --- Size columns with updated demands ---
        size_columns!(struc, column_opts; reanalyze = false)

        # --- Re-analyze with updated column sections ---
        if struc.asap_model.processed
            Asap.update!(struc.asap_model)
        else
            Asap.process!(struc.asap_model)
        end
        Asap.solve!(struc.asap_model)

        # --- Check convergence ---
        _extract_column_demands!(curr_demands, struc)

        if !first_iter
            change = _max_demand_change(prev_demands, curr_demands)
            verbose && @info "  Max demand change: $(round(change * 100, digits=1))%"

            if change < convergence_tol
                verbose && @info "  Converged!"
                converged = true
                break
            end
        end

        copyto!(prev_demands, curr_demands)
        first_iter = false
    end

    !converged && verbose && @warn "Did not converge within $max_iterations iterations"

    # =========================================================================
    # Final foundation sizing (after member convergence)
    # =========================================================================
    if size_foundations && !isnothing(params.foundation_options)
        verbose && @info "Sizing foundations..."
        fp = params.foundation_options
        initialize_supports!(struc)
        size_foundations!(struc;
            soil=fp.soil, opts=fp.options,
            group_tolerance=fp.group_tolerance,
            concrete=fp.concrete, rebar=fp.rebar, pier_width=fp.pier_width,
            verbose=verbose)
    end

    # =========================================================================
    # Update design results
    # =========================================================================
    _update_design_results!(design)

    return design
end

# ==============================================================================
# Internal Helpers
# ==============================================================================
# _extract_column_demands! and _max_demand_change are defined in design_workflow.jl

"""Update BuildingDesign results after sizing."""
function _update_design_results!(design::BuildingDesign)
    struc = design.structure
    
    # Update column results
    for (col_idx, col) in enumerate(struc.columns)
        if !isnothing(col.base.section)
            result = get(design.columns, col_idx, ColumnDesignResult())
            result.section_size = string(col.base.section)
            result.section_obj = col.base.section
            design.columns[col_idx] = result
        end
    end
    
    # Update beam results
    for (beam_idx, beam) in enumerate(struc.beams)
        if !isnothing(beam.base.section)
            result = get(design.beams, beam_idx, BeamDesignResult())
            result.section_size = string(beam.base.section)
            result.section_obj = beam.base.section
            design.beams[beam_idx] = result
        end
    end
    
    # Recompute summary
    _compute_design_summary!(design, struc, design.params)
end
