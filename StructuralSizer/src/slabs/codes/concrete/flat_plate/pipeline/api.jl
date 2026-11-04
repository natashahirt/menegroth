# =============================================================================
# Main Pipeline Function
# =============================================================================

# Register trace contract for size_flat_plate!
TRACE_REGISTRY[(:size_flat_plate!, :slab)] =
    TracedFunctionMeta(:size_flat_plate!, :slab,
                       [:enter, :exit, :decision, :iteration, :fallback, :failure], nothing,
                       @__FILE__, @__LINE__)

"""
    size_flat_plate!(struc, slab, column_opts; method, opts, max_iterations, verbose)

Design a flat plate slab with integrated column P-M design.

# Analysis Methods
- `DDM()` - Direct Design Method (ACI 318 coefficient-based) - default
- `DDM(:simplified)` - Modified DDM with simplified coefficients
- `EFM()` - Equivalent Frame Method (ASAP stiffness analysis)

# Two-Phase Design Workflow (mirrors engineering practice)
1. Setup: identify columns, compute Pu, initial h from ACI Table 8.3.1.1
2. **Phase A — Depth convergence** (iterate until stable):
   a. Moment analysis (DDM/EFM/FEA) → MomentAnalysisResult
   b. Column P-M design → update column sizes → re-analyse if changed
   c. Two-way deflection check → bump h if failed
   d. One-way shear check → bump h if failed
   e. Flexural adequacy check → bump h if failed
3. **Phase B — Punching resolution** (at converged h):
   a. Punching shear check at each column
   b. Resolve failures via strategy (:grow_columns / :reinforce_last / :reinforce_first)
   c. Re-analyse if columns grew; bump h only as last resort
4. **Phase C — Final design**: rebar detailing, transfer reinforcement, integrity steel

An outer loop ties A→B→C: if Phase B or C signals "need more depth",
h is bumped and Phase A restarts with the new floor.

# Arguments
- `struc::BuildingStructure`: Structure with skeleton, cells, columns
- `slab::Slab`: Slab to design (references cells via cell_indices)
- `column_opts::ConcreteColumnOptions`: Options for column P-M optimization

# Keyword Arguments
- `method::FlatPlateAnalysisMethod = DDM()`: Analysis method
- `opts::FlatPlateOptions = FlatPlateOptions()`: Design options
- `max_iterations::Int = 10`: Maximum iterations per phase (each phase gets full budget)
- `column_tol::Float64 = 0.05`: Column size change tolerance
- `h_increment::Length = 0.5u"inch"`: Thickness rounding increment
- `verbose::Bool = false`: Enable debug logging

# Returns
Named tuple with fields:
- `slab_result::FlatPlatePanelResult`: Panel design result (thickness, reinforcement, deflection)
- `column_results::Dict`: Column P-M results keyed by global column index
- `drop_panel::Union{Nothing, DropPanelGeometry}`: Drop panel geometry (if flat slab)
- `integrity`: Structural integrity reinforcement demand (ACI 8.7.4.2)
- `integrity_check`: Pass/fail for integrity reinforcement vs provided bottom steel
- `transfer_results::Vector{Union{Nothing, NamedTuple}}`: Moment transfer reinforcement at each column (ACI 8.4.2.3)
- `ρ_prime::Float64`: Estimated compression reinforcement ratio for long-term deflection
- `method_requested`: The `method` passed in
- `method_used`: The analysis method the design was actually run with (`FEA()` when
  the requested DDM/EFM is not permitted and `opts.on_inapplicable == :fallback`)
- `method_fallback_reasons::Vector{String}`: The ACI 318-11 §13.6.1 / §13.7
  applicability violations that caused the fallback (empty when none)

These three fields are present on every returned tuple, converged or not.

# Method Applicability
When DDM/EFM is not permitted for the layout, `opts.on_inapplicable` decides:
`:fallback` (default) designs with FEA, keeps a `@warn`, emits a `:fallback`
trace event (`resolve_analysis_method`, `reason = "method_not_applicable"`) and
records the switch in the fields above; `:error` rethrows the
`DDMApplicabilityError` / `EFMApplicabilityError`.  A `RuleOfThumb` wrapping
DDM/EFM follows the same rule for its inner method.

# Example
```julia
result = size_flat_plate!(struc, slab, ConcreteColumnOptions())
result = size_flat_plate!(struc, slab, col_opts; method=EFM(), verbose=true)
result.method_used isa FEA && @info "DDM/EFM not permitted" result.method_fallback_reasons
```
"""
function size_flat_plate!(struc, slab, column_opts;
                          method::FlatPlateAnalysisMethod = DDM(), kwargs...)
    record = Ref{NamedTuple}((method_requested = method, method_used = method,
                              method_fallback_reasons = String[]))
    result = _size_flat_plate!(struc, slab, column_opts;
                               method = method, _method_record = record, kwargs...)
    return merge(result, record[])
end

"""
    design_floor(request::FloorDesignRequest{FlatPlate}; workspace, ...) -> FloorDesignOutcome

Run flat-plate design from a normalized immutable input. All iterative mutation
is confined to a private `FlatPlateKernelState`; no building or Asap model is
accepted by this API.
"""
function design_floor(
    request::FloorDesignRequest{FlatPlate};
    workspace::FloorDesignWorkspace = prepare_floor_design_workspace(request),
    verbose::Bool = false,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    return _design_flat_plate_request(request, workspace; verbose=verbose, tc=tc)
end

"""Flat-slab counterpart of [`design_floor`](@ref)."""
function design_floor(
    request::FloorDesignRequest{FlatSlab};
    workspace::FloorDesignWorkspace = prepare_floor_design_workspace(request),
    verbose::Bool = false,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    return _design_flat_plate_request(request, workspace; verbose=verbose, tc=tc)
end

function _design_flat_plate_request(
    request::FloorDesignRequest,
    workspace::FloorDesignWorkspace;
    verbose::Bool,
    tc::Union{Nothing, TraceCollector},
)
    input = request.input
    input isa FlatPlateDesignInput || throw(ArgumentError(
        "flat-plate requests require FlatPlateDesignInput; got $(typeof(input))",
    ))
    input.floor_index == request.source.index || throw(ArgumentError(
        "flat-plate input floor $(input.floor_index) does not match source " *
        "$(request.source.index)",
    ))

    state = FlatPlateKernelState(input)
    slab = state.slabs[input.floor_index]
    opts = request.options isa FlatSlabOptions ? request.options.base : request.options
    drop_panel = request.system isa FlatSlab ?
        _build_drop_panel_geometry(request.options, slab) :
        nothing
    column_options = isnothing(request.column_options) ?
        ConcreteColumnOptions() :
        request.column_options

    raw = size_flat_plate!(
        state,
        slab,
        column_options;
        method = opts.method,
        opts = opts,
        max_iterations = request.max_iterations,
        verbose = verbose,
        _col_cache = workspace.column_cache,
        slab_idx = input.floor_index,
        drop_panel = drop_panel,
        fire_rating = request.fire_rating,
        defer_asap_process = true,
        update_analysis_model = false,
        tc = tc,
    )
    iterations = get(raw, :iterations, 0)
    if get(raw, :converged, false)
        cell_updates = FloorCellLoadUpdate[
            FloorCellLoadUpdate(
                cell_idx,
                state.cells[cell_idx].self_weight,
                state.cells[cell_idx].live_load,
            )
            for cell_idx in slab.cell_indices
        ]
        supports = find_supporting_columns(state, Set(slab.cell_indices))
        support_updates = FloorSupportUpdate[
            FloorSupportUpdate(
                support.source_index,
                support.c1,
                support.c2,
                support.shape,
                deepcopy(support.base.section),
                nothing,
            )
            for support in supports
        ]
        proposal = FloorDesignProposal(
            raw.slab_result,
            raw,
            raw.drop_panel,
            cell_updates,
            support_updates,
        )
        return FloorDesignOutcome(
            FLOOR_DESIGN_SUCCEEDED,
            proposal,
            raw,
            FloorDesignDiagnostic[],
            iterations,
        )
    end

    reason = String(get(raw, :failure_reason, "design_failed"))
    failing_check = String(get(raw, :failing_check, ""))
    status = reason == "non_convergence" ?
        FLOOR_DESIGN_NOT_CONVERGED :
        FLOOR_DESIGN_INFEASIBLE
    message = isempty(failing_check) ? reason : "$reason ($failing_check)"
    return FloorDesignOutcome{Nothing, typeof(raw)}(
        status,
        nothing,
        raw,
        [FloorDesignDiagnostic(Symbol(reason), message)],
        iterations,
    )
end

