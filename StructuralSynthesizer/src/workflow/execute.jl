
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
                        tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
                        context_hash::Union{Nothing, AbstractString} = nothing)
    # Fail-loud guard (Run 4) — UNIVERSAL choke point. Every BuildingDesign is
    # materialized here: the standard design_building tail, the primitive
    # build_design_graph -> execute_graph! -> capture_design path, and
    # capture_incremental_design (scheduler.jl) all route through this function.
    # Phase B HONORS effective steel-beam-group overrides; the struc-aware guard is
    # the backstop that refuses the un-honorable targets (flat-plate/flat-slab
    # floors, non-steel/coupled beam sizing, column/strut groups) so no primitive
    # path silently drops one. Empty / all-unset (vacuous) overrides pass unchanged
    # (byte-identical happy path). NOT prepare-affecting.
    _assert_member_group_overrides_unsupported(params, struc)
    # A published design must not alias either the mutable execution workspace
    # or caller-owned parameters. `capture_node_state` also omits non-copyable
    # solver-factorization caches while preserving finalized engineering state.
    owned_struc = capture_node_state(struc)
    owned_params = deepcopy(params)
    design = BuildingDesign(owned_struc, owned_params)
    if tc !== nothing
        append!(design.solver_trace, tc.events)
    end
    _populate_slab_results!(design, owned_struc)
    _populate_column_results!(design, owned_struc)
    _populate_beam_results!(design, owned_struc)
    _populate_foundation_results!(design, owned_struc)
    _capture_ordinary_walls!(design, owned_struc)
    _compute_design_summary!(design, owned_struc, owned_params)

    # Capture structural offsets before restore! wipes them.
    # Maps vertex_idx → (dx_m, dy_m) for edge/corner columns.
    skel = owned_struc.skeleton
    for col in owned_struc.columns
        off = col.structural_offset
        (off[1] == 0.0 && off[2] == 0.0) && continue
        for seg_idx in segment_indices(col)
            seg_idx > length(owned_struc.segments) && continue
            edge_idx = owned_struc.segments[seg_idx].edge_idx
            (edge_idx < 1 || edge_idx > length(skel.edge_indices)) && continue
            v1, v2 = skel.edge_indices[edge_idx]
            design.structural_offsets[v1] = off
            design.structural_offsets[v2] = off
        end
    end

    if !isnothing(t_start)
        design.compute_time_s = time() - t_start
    end
    checks_ok = all_ok(design)
    !checks_ok && push!(
        design.diagnostics, "One or more finalized design checks did not pass.")
    for stage in sort!(collect(keys(owned_struc.stage_diagnostics)))
        push!(design.diagnostics, owned_struc.stage_diagnostics[stage])
    end
    design.converged = checks_ok && isempty(owned_struc.stage_diagnostics)
    if owned_params.lateral === nothing
        push!(design.scope_notes,
            "Gravity-only design: no lateral system was given, so wind and " *
            "seismic demands, story drift, and lateral-frame checks were not run.")
    end
    design.context_hash = isnothing(context_hash) ?
        content_hash((owned_params, owned_params.framing_opts)) : String(context_hash)
    design.finalized = true
    return design
end

"""
Scene model when visualization is on, otherwise the solved analysis frame.

`design.asap_model` starts empty. The solved frame is
`design.structure.asap_model`. Visualization builds a separate scene from it.
When that build is skipped or throws, [`port_analysis_model!`](@ref) copies
the solved frame across so the design model is not left empty.
"""
function _finish_design_model!(design, params)
    if !params.skip_visualization && isnothing(design.asap_model)
        target_edge = isnothing(params.visualization_target_edge_m) ? nothing :
            params.visualization_target_edge_m * u"m"
        try
            build_analysis_model!(design; target_edge_length = target_edge)
        catch err
            push!(design.diagnostics,
                "Visualization analysis model failed: $(sprint(showerror, err))")
            @warn "build_analysis_model! failed — the design model is the solved analysis frame" exception = (err, catch_backtrace())
        end
    end
    isnothing(design.asap_model) && port_analysis_model!(design)
    return design
end

StructuralSizer.TRACE_REGISTRY[(:design_building, :pipeline)] =
    StructuralSizer.TracedFunctionMeta(
        :design_building,
        :pipeline,
        [:enter, :exit, :failure],
        nothing,
        @__FILE__,
        @__LINE__,
    )

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
2. Build the design graph (`build_design_graph`) and execute it
   (`execute_graph!`) — runs the pipeline stages in dependency order with
   `sync_asap!` where needed. Behaviorally identical to the legacy
   `build_pipeline` stage loop.
3. `capture_design` — populate BuildingDesign with all results
4. Restore to pristine state
"""
function _design_building_inplace(struc::BuildingStructure, params::DesignParameters;
                         tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
                         framing_opts::NamedTuple = NamedTuple(),
                         restore::Bool = true)
    t_start = time()
    
    StructuralSizer.emit!(tc, :pipeline, "design_building", "", :enter;
                          n_slabs=length(struc.slabs), n_columns=length(struc.columns))

    t0 = time()
    prepare!(struc, params; framing_opts=framing_opts)
    t_prepare = time() - t0

    # Pre-sizing validation: fail fast if DDM/EFM/FEA applicability checks fail
    ok, val_errors = run_pre_sizing_validation(struc, params; tc=tc)
    if !ok
        preview = isempty(val_errors) ? "" : join(val_errors[1:min(end, 3)], " | ")
        StructuralSizer.emit!(tc, :pipeline, "design_building", "", :failure;
                              error="PreSizingValidationError",
                              n_errors=length(val_errors),
                              preview=preview)
        throw(PreSizingValidationError(val_errors))
    end
    
    t0 = time()
    # Build and execute the design graph. The graph decomposes slab sizing into
    # fine per-slab nodes (batch levels) while keeping members/foundations coarse;
    # `execute_graph!` runs them in dependency levels, flushing `sync_asap!` once
    # per level. A floor with no shared column matches the legacy stage loop.
    # A flat plate whose slabs share a column proposes, adopts one column
    # envelope, then commits. See `build_design_graph`.
    graph = build_design_graph(struc, params; tc=tc)
    execute_graph!(graph, struc, params)
    t_pipeline = time() - t0
    
    t0 = time()
    design = capture_design(struc, params; t_start=t_start, tc=tc)
    t_capture = time() - t0

    # Build the visualization analysis model while struc still has sized
    # dimensions and structural offsets (restore! will wipe them).
    t0 = time()
    _finish_design_model!(design, params)
    t_analysis = time() - t0
    
    # Restore pristine member dimensions so struc can be reused.
    # Skip sync_asap! — prepare! rebuilds the Asap model from scratch on the
    # next design_building call, and the API route never reads struc.asap_model
    # after this point (serialization uses design.asap_model).
    # `restore = false` keeps the designed state (slab design details, sized
    # columns) on `struc` for callers that read it after the run.
    t0 = time()
    restore && restore!(struc; geometry_is_centerline=params.geometry_is_centerline)
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
    design_building(struc, params; tc=nothing, framing_opts=NamedTuple(), restore=true)

Run a fresh design through the canonical [`DesignSession`](@ref) lifecycle.
The normal `restore=true` path operates on an owned workspace and leaves
`struc` untouched. `restore=false` preserves the legacy, explicitly mutable
study workflow for callers that inspect the sized source structure.
"""
function design_building(
    struc::BuildingStructure,
    params::DesignParameters;
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    framing_opts::NamedTuple = NamedTuple(),
    restore::Bool = true,
)
    # `restore=false` is a compatibility mode for studies that intentionally
    # inspect the mutated workspace. Normal designs use the canonical session
    # lifecycle and never mutate caller-owned source state.
    if !restore
        return _design_building_inplace(
            struc, params; tc=tc, framing_opts=framing_opts, restore=false)
    end

    t_start = time()
    session = DesignSession(
        struc, params; framing_opts=framing_opts, tc=tc)
    design = session.base_design
    design.context_hash = session.context.content_hash

    t0 = time()
    _finish_design_model!(design, design.params)
    design.phase_timings["analysis_model"] = round(time() - t0; digits=3)
    design.phase_timings["total"] = round(time() - t_start; digits=3)
    design.compute_time_s = time() - t_start
    return design
end

StructuralSizer.TRACE_REGISTRY[(:design_building_kwargs, :pipeline)] =
    StructuralSizer.TracedFunctionMeta(
        :design_building_kwargs,
        :pipeline,
        [:enter, :exit],
        nothing,
        @__FILE__,
        @__LINE__,
    )

"""
    design_building(struc::BuildingStructure; kwargs...) -> BuildingDesign

Convenience method that creates DesignParameters from keyword arguments.
"""
function design_building(struc::BuildingStructure; tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing, framing_opts::NamedTuple = NamedTuple(), kwargs...)
    StructuralSizer.emit!(tc, :pipeline, "design_building_kwargs", "", :enter;
                          n_kwargs=length(kwargs))
    params = DesignParameters(; kwargs...)
    out = design_building(struc, params; tc=tc, framing_opts=framing_opts)
    StructuralSizer.emit!(tc, :pipeline, "design_building_kwargs", "", :exit)
    return out
end

