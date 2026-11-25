
"""
    build_design_graph(struc::BuildingStructure, params::DesignParameters; tc=nothing)
        -> DesignGraph

Build the design pipeline as a [`DesignGraph`](@ref) of [`StageNode`](@ref)s.

**Fine per-slab topology (Run 3).** The coarse `:slab_sizing` stage is decomposed
into one node PER slab index — `slab_node_key(idx)` = `:slab_sizing_s{idx}`, each
running `size_slab!(struc, idx)` + that slab's volume update. The nodes are emitted
as ROOTS (no inter-slab edges) in ASCENDING `slab_idx` order, so
[`topological_levels`](@ref) places them ALL in ONE level listed in insertion
(== `eachindex`) order, and both [`execute_graph!`](@ref) and the incremental
scheduler ([`run_target!`](@ref)) process them SEQUENTIALLY in that order. The
level barrier then flushes `sync_asap!` exactly ONCE after the whole slab level.

This is byte-identical to the single-threaded coarse `size_slabs!` reference
(`StructuralSizer/src/slabs/sizing.jl` §`size_slabs!`, which iterates
`eachindex(struc.slabs)` when `Threads.nthreads() == 1`) because (a) the fine
nodes are processed in the SAME `eachindex` order — the decisive property, since
flat-plate slab sizing reads LIVE shared supporting-column `c1`/`c2` (DDM clear
span `ln = l1 - c1`, punching perimeter, deflection) and columns grow
MONOTONICALLY across slabs, so per-slab output is ORDER-DEPENDENT (an earlier
batch-coloring order broke this — Finding 1 P0); (b) the single post-level
`sync_asap!` matches the coarse pipeline's single post-slab-stage sync
(`size_slabs!` performs NO inter-slab sync — slab sizing never reads solved
`el.forces`, so there is no intermediate sync to reproduce and the barrier fires
once after the last slab node); (c) `_col_cache` is a pure, read-only memoization
after `precompute_capacities!` — recomputing per slab (passing `nothing`) yields
identical P-M capacities (see Finding 5 note in `slabs/sizing.jl`). The exact-first
gate (`verify_design_graph.jl`) verifies this end-to-end.

ENGINEERING JUDGMENT / KNOWN ISSUE — this PINS `design_building`'s slab order to
`eachindex` for determinism regardless of thread count, deliberately trading away
intra-run slab parallelism (`struc.slab_parallel_batches` no longer shapes the
graph). The pre-existing coarse thread-count non-determinism (single-thread
`eachindex` vs multithread batch order inside `size_slabs!`) is a SEPARATE known
issue not addressed here. A floor whose flat-plate slabs share a column uses
the order-independent two-pass instead: propose each slab on a private copy,
adopt the governing column, then commit every slab against that column.
A floor with no shared column keeps this single level, so its result stays
the eachindex sequence.

**Coarse global nodes.** Member sizing stays a single `:members` node
(flat-plate `_reconcile_columns!` OR the ITERATIVE, beam↔column COUPLED
`_size_beams_columns!` loop — see the deferral note below), depending on
every per-slab node. Ordinary walls are one node after `:members`.
Foundations are one `:foundations` node after ordinary walls: a thickness
jump remeshes inside the wall stage, and the footing is sized on that model.

Each node carries the provenance from `PIPELINE_PROVENANCE` (per-slab nodes inherit
`NODE_SLAB_SIZING`'s record via [`pipeline_provenance`](@ref)). `struc` is read for
its (fixed, prepare-time) slab count only (slab nodes are ordered by `eachindex`,
NOT by `slab_parallel_batches` — see the per-slab topology note above); the
member/foundation closures still come from [`build_pipeline`](@ref) so the graph
and the legacy stage loop stay in lock-step.

ENGINEERING JUDGMENT — columns stay coarse. `size_columns!` is a single global MIP
with no per-group API; splitting it would change the optimization semantics. And
`size_beams!` is batched across all groups while `size_member_group!` sizes one
steel group via a different solver path — plus for beam-based floors beams and
columns are sized in an ITERATIVE CONVERGENCE loop (`_size_beams_columns!`) whose
coupling cannot be reproduced by independent per-group nodes without breaking
byte-identity. Per-beam-group / per-column-group splitting is therefore DEFERRED to
a follow-up run (see NOTES). This is not a code requirement — it is a
byte-identity-preserving scope decision under `code-accuracy.mdc`.
"""
function build_design_graph(struc::BuildingStructure, params::DesignParameters;
                            tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    stages = build_pipeline(params; tc=tc)

    has_foundations = !isnothing(params.foundation_options)
    has_ordinary_walls = true
    expected_stages = 2 + (has_foundations ? 1 : 0) + (has_ordinary_walls ? 1 : 0)
    length(stages) == expected_stages || error(
        "build_design_graph: stage count mismatch " *
        "($(length(stages)) stages vs $expected_stages expected)")

    slab_stage   = stages[1]
    member_stage = _member_stage_after_floor_resolution(struc, params, stages[2], tc)
    # `build_pipeline` emits walls, then foundations. The footing reads the
    # model the wall jump left.
    wall_stage = has_ordinary_walls ? stages[3] : nothing
    fdn_stage = has_foundations ? stages[has_ordinary_walls ? 4 : 3] : nothing

    graph_nodes = DesignNode[]
    slab_prov   = pipeline_provenance(NODE_SLAB_SIZING)

    # ── Fine per-slab nodes, emitted as ROOTS in ONE topological level ───────
    # (all slab nodes are edgeless roots ordered by `eachindex`, so
    # `topological_levels` places them in a SINGLE level with ONE barrier sync —
    # NOT one level per `slab_parallel_batches` batch; see the topology note above)
    n_slabs = length(struc.slabs)
    slab_keys_all = NodeKey[]
    member_upstream = NodeKey[]
    if n_slabs == 0
        # No slabs: keep the coarse `:slab_sizing` node (its stage closure is a
        # no-op loop) so `:members` still has a stable slab-stage dependency and
        # the semantic identity is preserved.
        push!(graph_nodes, StageNode(NODE_SLAB_SIZING, NodeKey[], slab_stage.fn,
                                     slab_stage.needs_sync, slab_prov.param_slice,
                                     slab_prov.reads, slab_prov.writes,
                                     slab_prov.code_version))
        push!(slab_keys_all, NODE_SLAB_SIZING)
        member_upstream = copy(slab_keys_all)
    else
        floor_opts      = resolve_floor_options(params)
        column_opts     = _get_column_opts(params)
        slab_floor_type = _infer_floor_type(floor_opts)
        # A scoped override stores that slab's own options. The building-wide
        # options stay the fallback, and the trace envelope still reports them.
        slab_opts = [
            _floor_options_for_slab(struc, sidx, params, floor_opts)
            for sidx in 1:n_slabs
        ]
        # One read-only P-M cache for every slab node. `_precompute` returns
        # nothing for NLP and for non-concrete columns, which is the same
        # cache the coarse `size_slabs!` would share. FINDING 5: the cache is
        # not written after `precompute_capacities!`. A leading vault must not
        # be the cache source: only a flat plate or flat slab has a column diagram.
        cache_idx = findfirst(
            i -> struc.slabs[i].floor_type in (:flat_plate, :flat_slab),
            1:n_slabs,
        )
        shared_col_cache = if cache_idx === nothing
            nothing
        else
            cache_request = floor_design_request(
                struc,
                cache_idx;
                options = slab_opts[cache_idx],
                column_options = column_opts,
                max_iterations = params.max_iterations,
                fire_rating = params.fire_rating,
            )
            StructuralSizer.prepare_floor_design_workspace(cache_request).column_cache
        end

        # No shared column: one root per slab, in index order. A shared column
        # takes propose → envelope → commit → lock instead.
        member_upstream = if _flat_plate_slabs_share_columns(struc)
            _push_two_level_slab_nodes!(
                graph_nodes, struc, slab_opts, column_opts, params, tc,
                shared_col_cache, slab_prov, slab_floor_type)
            NodeKey[NODE_SLAB_LOCK]
        else
        for sidx in 1:n_slabs
            key      = slab_node_key(sidx)
            this_opts   = slab_opts[sidx]
            base_fn     = _make_slab_node_fn(sidx, this_opts, column_opts, params, tc,
                                             shared_col_cache)
            base_fn_ctx = _make_slab_node_fn_ctx(sidx, this_opts, column_opts, params, tc,
                                                 shared_col_cache)
            is_first = sidx == 1
            is_last  = sidx == n_slabs
            # Finding 2: reproduce the legacy `stage_1_slabs` + `size_slabs!` trace
            # envelope around the per-slab `size_slab!` events (which `base_fn`
            # emits nested) so a traced `design_building` is byte-identical to the
            # pre-Run-3 sequence. The envelope is emitted at the slab-level
            # boundary: open on the first node, close on the last. `_emit_envelope`
            # keeps the cold (`fn`) and warm (`fn_ctx`) variants trace-identical.
            _emit_slab_envelope_open(struc) = begin
                if is_first
                    StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :enter;
                                          floor_type=string(slab_floor_type))
                    StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :enter;
                                          n_slabs=length(struc.slabs),
                                          options_type=string(typeof(floor_opts)),
                                          has_column_opts=!isnothing(column_opts),
                                          max_iterations=params.max_iterations)
                    # Fine graph pins slab processing to `eachindex` order regardless
                    # of thread count (Finding 1), so the coarse single-threaded
                    # `parallel=false` decision is the invariant reference event.
                    StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :decision; parallel=false)
                end
            end
            _emit_slab_envelope_close() = begin
                if is_last
                    StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :exit)
                    StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :exit)
                end
            end
            fn = function (struc)
                _emit_slab_envelope_open(struc)
                base_fn(struc)
                _emit_slab_envelope_close()
                return nothing
            end
            # Warm variant: identical trace envelope + `_update_one_slab_volume!`,
            # only the internal `_col_cache` is reused from `ctx` (result-neutral).
            fn_ctx = function (struc, ctx)
                _emit_slab_envelope_open(struc)
                base_fn_ctx(struc, ctx)
                _emit_slab_envelope_close()
                return nothing
            end
            push!(graph_nodes, StageNode(key, NodeKey[], fn,
                                         slab_stage.needs_sync, slab_prov.param_slice,
                                         slab_prov.reads, slab_prov.writes,
                                         slab_prov.code_version, fn_ctx))
            push!(slab_keys_all, key)
        end
        copy(slab_keys_all)
        end
    end

    # ── Coarse member node depends on ALL slab nodes ────────────────────────
    # A two-level floor depends on the lock, which itself depends on every
    # commit. The transitive closure still contains every slab node.
    mem_prov = pipeline_provenance(NODE_MEMBERS)
    push!(graph_nodes, StageNode(NODE_MEMBERS, member_upstream, member_stage.fn,
                                 member_stage.needs_sync, mem_prov.param_slice,
                                 mem_prov.reads, mem_prov.writes, mem_prov.code_version))

    # Ordinary walls after members. A thickness jump remeshes inside the
    # stage (`needs_sync` stays false). Foundations follow that stage.
    if has_ordinary_walls
        wall_prov = pipeline_provenance(NODE_ORDINARY_WALLS)
        push!(graph_nodes, StageNode(NODE_ORDINARY_WALLS, NodeKey[NODE_MEMBERS], wall_stage.fn,
                                     wall_stage.needs_sync, wall_prov.param_slice,
                                     wall_prov.reads, wall_prov.writes, wall_prov.code_version))
    end

    # Foundations read the reactions on the thickness the wall stage accepted.
    # They also read the frame forces the member stage publishes. The wall
    # output hash is the thickness list, so a load-combination edit can change
    # those forces without changing a thickness. Foundations would then stay
    # clean, and the all-clean restore would put the old solved model back
    # (old column forces, old bearing). The member node writes `:asap_model`,
    # whose fingerprint is the frame forces, so foundations depend on it
    # directly. The wall node stays a dependency, and it still runs first.
    if has_foundations
        fdn_prov = pipeline_provenance(NODE_FOUNDATIONS)
        fdn_upstream = has_ordinary_walls ?
            NodeKey[NODE_MEMBERS, NODE_ORDINARY_WALLS] :
            NodeKey[NODE_MEMBERS]
        push!(graph_nodes, StageNode(NODE_FOUNDATIONS, fdn_upstream, fdn_stage.fn,
                                     fdn_stage.needs_sync, fdn_prov.param_slice,
                                     fdn_prov.reads, fdn_prov.writes, fdn_prov.code_version))
    end

    return DesignGraph(graph_nodes)
end

"""
    _floor_options_for_slab(struc, slab_idx, params, global_opts) -> AbstractFloorOptions

Options for one slab. A scoped override that covers the slab's cells supplies
its own options, with the same concrete and column-cracking factor the
initializer applies; the last matching override wins. Otherwise a slab whose
floor type matches the building-wide options uses those options.
"""
function _floor_options_for_slab(
    struc::BuildingStructure,
    slab_idx::Int,
    params::DesignParameters,
    global_opts::StructuralSizer.AbstractFloorOptions,
)
    slab = struc.slabs[slab_idx]
    chosen = nothing
    for ov in params.scoped_floor_overrides
        ov.floor_type == slab.floor_type || continue
        isdisjoint(_match_override_cells(struc, ov), slab.cell_indices) && continue
        opts = _scoped_override_floor_opts(ov)
        opts === nothing && continue
        concrete = something(ov.concrete, _primary_material(global_opts))
        chosen = _apply_flat_plate_analysis(_apply_col_I_factor(
            _with_concrete_material(opts, concrete),
            params.column_I_factor,
        ), params)
    end
    chosen === nothing || return chosen
    StructuralSizer.floor_symbol(global_opts) == slab.floor_type && return global_opts
    # A beamless :two_way panel was redesigned as a flat plate. The request
    # options are still TwoWayOptions; the flat-plate kernel needs its own.
    if slab.floor_type === :flat_plate && global_opts isa StructuralSizer.TwoWayOptions
        return _apply_flat_plate_analysis(_apply_col_I_factor(
            _flat_plate_options_from(_options_covering_slab(struc, slab, params, global_opts)),
            params.column_I_factor), params)
    end
    throw(ArgumentError(
        "slab $slab_idx is a $(slab.floor_type) floor, which $(typeof(global_opts)) " *
        "does not describe, and no scoped override covers its cells"))
end

"""Options that cover this slab, preferring the last matching scoped override."""
function _options_covering_slab(
    struc::BuildingStructure,
    slab,
    params::DesignParameters,
    global_opts::StructuralSizer.AbstractFloorOptions,
)
    chosen = global_opts
    for ov in params.scoped_floor_overrides
        ov.floor_type in (slab.floor_type, :two_way) || continue
        isdisjoint(_match_override_cells(struc, ov), slab.cell_indices) && continue
        opts = _scoped_override_floor_opts(ov)
        opts === nothing && continue
        concrete = something(ov.concrete, _primary_material(global_opts))
        chosen = _with_concrete_material(opts, concrete)
    end
    return chosen
end

"""
    _member_stage_after_floor_resolution(struc, params, member_stage, tc)

A `:two_way` request whose every panel was redesigned as a flat plate uses
the flat-plate column reconciliation, not the beam-and-column loop. There
is no beam grid left to size. Any other request keeps the stage
`build_pipeline` chose.
"""
function _member_stage_after_floor_resolution(
    struc::BuildingStructure,
    params::DesignParameters,
    member_stage::PipelineStage,
    tc::Union{Nothing, StructuralSizer.TraceCollector},
)
    _infer_floor_type(resolve_floor_options(params)) === :two_way || return member_stage
    isempty(struc.slabs) && return member_stage
    all(s -> s.floor_type in (:flat_plate, :flat_slab), struc.slabs) || return member_stage
    column_opts = _get_column_opts(params)
    if column_opts isa StructuralSizer.PixelFrameColumnOptions
        throw(ArgumentError(
            "Flat plate/slab requires reinforced concrete columns. " *
            "PixelFrame columns are not supported for beamless slab systems."))
    end
    return PipelineStage(struc -> begin
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_reconcile", :enter)
        _design_flat_plate_members!(struc, params; tc=tc)
        StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_2_reconcile", :exit)
    end, false)
end

"""Uniform column sizing, when `params` asks for it. Returns the columns enlarged."""
_harmonize_columns!(struc::BuildingStructure, params::DesignParameters) =
    params.uniform_column_sizing === :off ? 0 : harmonize_uniform_column_sizes!(struc, params)

"""Flat-plate and flat-slab slabs whose stored checks used a smaller column than is installed."""
_stale_flat_plate_slabs(struc::BuildingStructure) =
    [s for s in eachindex(struc.slabs)
     if struc.slabs[s].floor_type in (:flat_plate, :flat_slab) &&
        !_slab_checked_at_installed_columns(struc, s)]

StructuralSizer.TRACE_REGISTRY[(:_design_flat_plate_members!, :workflow)] =
    StructuralSizer.TracedFunctionMeta(
        :_design_flat_plate_members!,
        :workflow,
        [:enter, :exit, :decision],
        nothing,
        @__FILE__,
        @__LINE__,
    )

# --- Debug helpers for SS_DEBUG_MEMBER_SETTLE (no behavior change) ---
"""Compact `idx=>c1xc2 in` signature of a column plan-size dict, sorted by idx."""
function _fp_plan_sig(d)
    inch(x) = x === nothing ? "-" : string(round(ustrip(u"inch", x); digits = 1))
    return join(("$i=$(inch(v[1]))x$(inch(v[2]))" for (i, v) in sort(collect(d); by = first)), " ")
end

"""Why slab `sidx` is stale: which supports/aboves differ from installed."""
function _fp_stale_reason(struc, sidx)
    dd = struc.slabs[sidx].design_details
    dd isa NamedTuple && hasproperty(dd, :designed_supports) || return "no-stamp"
    inch(x) = x === nothing ? "-" : string(round(ustrip(u"inch", x); digits = 1))
    diffs = String[]
    for (cidx, (c1, c2, shape)) in dd.designed_supports
        col = struc.columns[cidx]
        (col.c1 == c1 && col.c2 == c2 && col.shape == shape) && continue
        push!(diffs, "sup$cidx $(inch(c1))x$(inch(c2))->$(inch(col.c1))x$(inch(col.c2))")
    end
    if hasproperty(dd, :designed_above)
        for (cidx, rec) in dd.designed_above
            a = struc.columns[cidx].column_above
            now = a === nothing ? nothing : (a.c1, a.c2, a.shape)
            isequal(now, rec) && continue
            push!(diffs, "above$cidx " * (rec === nothing ? "-" : "$(inch(rec[1]))x$(inch(rec[2]))") *
                         "->" * (now === nothing ? "-" : "$(inch(now[1]))x$(inch(now[2]))"))
        end
    end
    return isempty(diffs) ? "match?" : join(diffs, ", ")
end

"""
    _design_flat_plate_members!(struc, params; tc=nothing) -> NamedTuple

Member stage of a flat-plate or flat-slab building.

[`_reconcile_columns!`](@ref) gives each column the lightest section that
passes its full-load strength and punching, then uniform column sizing
promotes each group to its largest member when that option is on. A column
whose plan size changed was not the column the slab was checked at
([`_slab_checked_at_installed_columns`](@ref)), so that slab is designed
again. The slab commit may grow a column, and the section search may grow
one too. Either growth is a floor under the next search
([`_raise_column_floors!`](@ref)), so a column that failed at a smaller
plan size is not selected again. Rounds repeat until every slab was checked
at its installed columns.

After that grow-only settle converges, [`_trim_flat_plate_members!`](@ref)
tries one lighter design. It is kept only when that second settle converges,
every column found a section, the column objective is strictly smaller, and
no slab got thicker.

Returns `(passes, redesigned)`: the rounds of the design that was kept,
including the last one that found nothing stale, and the slabs designed again.
"""
function _design_flat_plate_members!(struc::BuildingStructure, params::DesignParameters;
                                     tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    StructuralSizer.emit!(tc, :workflow, "_design_flat_plate_members!", "", :enter;
                          n_slabs = length(struc.slabs))
    # Plan size a slab commit or the section search grew a column to.
    # The next search does not go under it.
    floors = Dict{Int, Tuple}()
    opened_at = _column_plan_sizes(struc)
    _reconcile_columns!(struc, params; tc, floors)
    _harmonize_columns!(struc, params)
    _raise_column_floors!(floors, opened_at, struc)
    # Grow-only from the first round on: the initial reconcile above may right-size
    # (shrink) columns once, but after that every column is pinned at its installed
    # size so the two-sided fit cannot shrink/regrow against the slab checks and
    # oscillate. See `_floor_columns_at_installed!`.
    _floor_columns_at_installed!(floors, struc)
    floor_opts = resolve_floor_options(params)
    column_opts = _get_column_opts(params)
    redesigned = Set{Int}()
    run = _settle_flat_plate_members!(
        struc, params, floors, floor_opts, column_opts, redesigned; tc)
    trim = "skipped"
    if run.converged
        run, trim = _trim_flat_plate_members!(
            struc, params, floor_opts, column_opts, redesigned, run; tc)
    end
    StructuralSizer.emit!(tc, :workflow, "_design_flat_plate_members!", "", :decision;
                          passes = run.steps, stop = string(run.stop),
                          n_redesigned = length(redesigned), trim = trim)
    run.converged || _flat_plate_members_unsettled(struc, run)
    StructuralSizer.emit!(tc, :workflow, "_design_flat_plate_members!", "", :exit;
                          n_redesigned = length(redesigned))
    return (passes = run.steps, redesigned = sort!(collect(redesigned)))
end

"""Grow-only slab and column rounds. `floors` is pinned at the sizes already reached."""
function _settle_flat_plate_members!(struc, params, floors, floor_opts, column_opts, redesigned;
                                     tc = nothing)
    dbg = haskey(ENV, "SS_DEBUG_MEMBER_SETTLE")
    return StructuralSizer.settle!(;
            budget = StructuralSizer.monotone_budget(params.max_iterations, 48)) do step
        stale = _stale_flat_plate_slabs(struc)
        if dbg
            @info "member-settle round" step n_stale = length(stale) floors = _fp_plan_sig(floors) cols = _fp_plan_sig(_column_plan_sizes(struc)) reasons = join(("s$s[$(_fp_stale_reason(struc, s))]" for s in stale), " | ")
            flush(stderr)
        end
        isempty(stale) && return false
        before = _column_plan_sizes(struc)
        # Pin round-start sizes so this round's two-sided fit cannot shrink a
        # column below where the slabs were last checked (monotone / grow-only).
        _floor_columns_at_installed!(floors, struc)
        outcomes = Any[nothing for _ in eachindex(struc.slabs)]
        for sidx in stale
            opts = _floor_options_for_slab(struc, sidx, params, floor_opts)
            outcome = _isolated_floor_outcome(struc, sidx, opts, column_opts, params, tc, nothing)
            outcomes[sidx] = _commit_floor!(struc, sidx, outcome, opts, column_opts, params)
        end
        union!(redesigned, stale)
        _apply_support_envelope!(struc, outcomes)
        _raise_column_floors!(floors, before, struc)
        refresh_flat_plate_analysis!(struc, params)
        # #18: `refresh_flat_plate_analysis!` just solved the current state, and
        # nothing mutates the model before the reconcile below, so its column-frame
        # install may skip its re-solve when it changes no section. The ENV gate
        # exists only for the equivalence harness (default: optimization on).
        _reconcile_columns!(struc, params; tc, floors,
                            model_current = !haskey(ENV, "SS_DISABLE_MEMBER_RESOLVE_SKIP"))
        _harmonize_columns!(struc, params)
        # The search can grow a column the slab commit did not. That size
        # failed at the smaller plan, so the next round does not go under it.
        _raise_column_floors!(floors, before, struc)
        if dbg
            @info "member-settle round end" step cols_after = _fp_plan_sig(_column_plan_sizes(struc))
            flush(stderr)
        end
        return true
    end
end

_flat_plate_members_unsettled(struc, run) = error(
    "flat-plate member stage did not settle: after $(run.steps) rounds, slabs " *
    "$(_stale_flat_plate_slabs(struc)) were still checked at smaller columns " *
    "than are installed")

"""
    _trim_flat_plate_members!(struc, params, floor_opts, column_opts, redesigned, kept_run; tc) -> (run, outcome)

One lighter attempt after the grow-only flat-plate settle has converged.

A free column pick runs with no plan floor. If any section moves, the same
grow-only settle runs from those sizes. The attempt is kept when it
converges, no column is left without a passing section, the column sizing
objective is strictly smaller, and no slab thickness increased. Otherwise
the converged design is restored and re-solved.

Returns the run of the design that stands, and `"unchanged"`, `"kept"`, or
`"dropped"`.
"""
function _trim_flat_plate_members!(struc, params, floor_opts, column_opts, redesigned, kept_run;
                                   tc = nothing)
    shapes = [deepcopy(col.shape) for col in struc.columns]
    sections = [section(col) for col in struc.columns]
    plans = _column_plan_sizes(struc)
    counts = (length(struc.beams), length(struc.columns), length(struc.slabs))
    obj_kept = _columns_only_objective(struc, column_opts)
    thick = _flat_plate_thicknesses(struc)
    snapshot!(struc, :flat_plate_trim_kept)
    tracing = get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1"
    tracing && println("—— flat-plate trim: free pick on the converged model ——")
    full = check_flat_plate_columns!(struc, params; tc, floors = Dict{Int, Tuple}())
    if _flat_plate_columns_held(struc, plans, sections)
        tracing && println("—— flat-plate trim unchanged ——")
        delete!(struc._snapshots, :flat_plate_trim_kept)
        return (kept_run, "unchanged")
    end
    floors = Dict{Int, Tuple}()
    _floor_columns_at_installed!(floors, struc)
    trim_redesigned = Set{Int}()
    run = _settle_flat_plate_members!(
        struc, params, floors, floor_opts, column_opts, trim_redesigned; tc)
    counts_ok = (length(struc.beams), length(struc.columns), length(struc.slabs)) == counts
    obj_trim = _columns_only_objective(struc, column_opts)
    keep = full.converged && isempty(full.unresolved) && run.converged &&
           !haskey(struc.stage_diagnostics, :flat_plate_columns) &&
           obj_trim < obj_kept && !_flat_plate_slab_thickened(thick, struc)
    if keep
        tracing && println("—— flat-plate trim kept: objective $(obj_trim) < $(obj_kept) ——")
        union!(redesigned, trim_redesigned)
        delete!(struc._snapshots, :flat_plate_trim_kept)
        return (run, "kept")
    end
    tracing && println("—— flat-plate trim dropped (converged=$(run.converged), " *
                       "objective $(obj_trim) vs $(obj_kept)) ——")
    # A head that grew during the trim changed the member lists, so the saved
    # sections have nowhere to go. A converged trim is still a finished design.
    if !counts_ok
        delete!(struc._snapshots, :flat_plate_trim_kept)
        run.converged || _flat_plate_members_unsettled(struc, run)
        union!(redesigned, trim_redesigned)
        return (run, "dropped")
    end
    _restore_flat_plate_trim!(struc, params, shapes)
    return (kept_run, "dropped")
end

"""Put back the design saved at the start of the flat-plate trim and re-solve it."""
function _restore_flat_plate_trim!(struc, params, shapes)
    restore!(struc, :flat_plate_trim_kept;
             geometry_is_centerline = params.geometry_is_centerline)
    for (col, shape) in zip(struc.columns, shapes)
        col.shape = shape
    end
    concrete_fallback = column_concrete(params)
    rebar = column_rebar(params)
    for col in struc.columns
        section(col) === nothing && continue
        _set_rc_column_volumes!(col, something(col.concrete, concrete_fallback), rebar)
        _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
    end
    refresh_flat_plate_analysis!(struc, params)
    delete!(struc._snapshots, :flat_plate_trim_kept)
    return struc
end

"""True when every column still has the plan size and section from before the free pick."""
function _flat_plate_columns_held(struc, plans, sections)
    length(struc.columns) == length(sections) || return false
    tol = 0.05u"inch"
    for (i, col) in enumerate(struc.columns)
        _sections_identical(section(col), sections[i]) || return false
        haskey(plans, i) || continue
        (col.c1 === nothing || col.c2 === nothing) && return false
        b1, b2 = plans[i]
        (abs(col.c1 - b1) <= tol && abs(col.c2 - b2) <= tol) || return false
    end
    return true
end

"""Column sizing objective: section objective per length times length."""
function _columns_only_objective(struc, column_opts)
    total = 0.0
    for col in struc.columns
        sec = section(col)
        sec === nothing && continue
        total += _member_section_objective(column_opts, sec, col)
    end
    return total
end

"""Installed slab thickness, or `nothing` when the slab has no result yet."""
function _flat_plate_thickness(slab)
    result = slab.result
    result === nothing && return nothing
    hasproperty(result, :thickness) && return result.thickness
    return StructuralSizer.total_depth(result)
end

_flat_plate_thicknesses(struc) = [_flat_plate_thickness(slab) for slab in struc.slabs]

"""True when any slab is more than 0.05 in thicker than `before`."""
function _flat_plate_slab_thickened(before, struc)
    length(before) == length(struc.slabs) || return true
    tol = 0.05u"inch"
    for (h0, slab) in zip(before, struc.slabs)
        h1 = _flat_plate_thickness(slab)
        (h0 === nothing || h1 === nothing) && continue
        h1 > h0 + tol && return true
    end
    return false
end

"""Plan size `(c1, c2)` of each column that already has one."""
function _column_plan_sizes(struc)
    return Dict{Int, Tuple}(
        i => (col.c1, col.c2)
        for (i, col) in enumerate(struc.columns) if col.c1 !== nothing)
end

"""
Record a plan floor where a column came out larger than `before`.

`before` is the plan size at the start of the step. The slab commit and the
section search both call this. A column that came out larger failed at the
smaller size, and the next section search will not go back under it.
"""
function _raise_column_floors!(floors, before, struc)
    tol = 0.05u"inch"
    for (i, col) in enumerate(struc.columns)
        haskey(before, i) || continue
        (col.c1 === nothing || col.c2 === nothing) && continue
        b1, b2 = before[i]
        (col.c1 > b1 + tol || col.c2 > b2 + tol) || continue
        f1, f2 = get(floors, i, (zero(col.c1), zero(col.c2)))
        floors[i] = (max(f1, col.c1), max(f2, col.c2))
    end
    return floors
end

"""
    _floor_columns_at_installed!(floors, struc) -> floors

Pin every installed column at its current plan size, making the member stage
**grow-only** (monotone).

`_raise_column_floors!` only floors a column that *grew*, so a column left out of
`floors` can still shrink. The two-sided column fit
([`_fit_flat_plate_columns!`](@ref)) does shrink when a stiffening frame sheds
demand off a column — but that shrink re-stales the slab the column supports,
which regrows the column, which the fit shrinks again: an undamped oscillation
that exhausts the settle budget and throws (observed on the core office, where
upper-story columns bounced 12 in → 10 in while the lower columns grew
16 in → 20 in). Flooring every column at the largest size it has reached removes
the shrink direction, so the coupled slab/column iteration is monotone and
terminates (finite catalog, bounded by the column cap). The only cost is that a
column may finish one catalog step larger than its lightest passing section —
conservative, never unsafe.
"""
function _floor_columns_at_installed!(floors, struc)
    for (i, col) in enumerate(struc.columns)
        (col.c1 === nothing || col.c2 === nothing) && continue
        f1, f2 = get(floors, i, (zero(col.c1), zero(col.c2)))
        floors[i] = (max(f1, col.c1), max(f2, col.c2))
    end
    return floors
end

"""
True when two flat-plate or flat-slab panels share a supporting column.

Those panels read the column size while they size (`ln = l1 − c1`, and the
punching perimeter) and they grow it. Sizing them in index order makes the
floor depend on which panel runs first.
"""
function _flat_plate_slabs_share_columns(struc::BuildingStructure)
    owner = Dict{Int, Int}()
    for sidx in eachindex(struc.slabs)
        ft = struc.slabs[sidx].floor_type
        ft in (:flat_plate, :flat_slab) || continue
        for cidx in _slab_supporting_columns(struc, sidx)
            prev = get(owner, cidx, sidx)
            prev != sidx && return true
            owner[cidx] = sidx
        end
    end
    return false
end

_support_area(c1, c2) = (isnothing(c1) || isnothing(c2)) ? -Inf :
    float(ustrip(u"m^2", c1 * c2))

"""Longitudinal-steel score used only to break a same-footprint tie.

ACI 318-11 §10.3.6.2 (corpus: aci-318-11, page 143): at a fixed gross area,
φPn,max does not decrease as Ast increases, because fy > 0.85 f′c. A missing
area sorts below any reported area.
"""
function _ast_score(section)
    area = _column_section_steel_area(section)
    area === nothing && return -1.0
    return float(ustrip(u"m^2", area))
end

"""An update may replace the column when neither side gets smaller."""
function _support_beats(c1, c2, update)
    (isnothing(update.c1) || isnothing(update.c2)) && return false
    (isnothing(c1) || isnothing(c2)) && return true
    return update.c1 >= c1 && update.c2 >= c2
end

"""
    _governing_support_update(c1, c2, section, labeled) -> update or nothing

`labeled` is `(slab_index, support_update)` pairs for one column. The winner
is the largest footprint that does not shrink either side of the current
column. Equal footprints keep the larger longitudinal steel area. The same
score keeps the earlier slab, so the choice does not depend on proposal order.
Returns `nothing` when the current column already matches that winner.
"""
function _governing_support_update(c1, c2, section, labeled)
    best = nothing
    best_key = (-Inf, -1.0, 0)
    for (sidx, update) in labeled
        _support_beats(c1, c2, update) || continue
        key = (_support_area(update.c1, update.c2), _ast_score(update.section), -sidx)
        if best === nothing || key > best_key
            best = update
            best_key = key
        end
    end
    best === nothing && return nothing
    current_key = (_support_area(c1, c2), _ast_score(section))
    (best_key[1], best_key[2]) > current_key || return nothing
    return best
end

"""
Write `update` onto `col`. A missing section does not replace a real one.
Returns `true` when the column was written.
"""
function _install_governing_support!(col, update)
    if update.section === nothing && col.base.section !== nothing &&
            (update.c1 != col.c1 || update.c2 != col.c2)
        return false
    end
    col.c1 = deepcopy(update.c1)
    col.c2 = deepcopy(update.c2)
    col.shape = update.shape
    update.section === nothing || (col.base.section = deepcopy(update.section))
    update.volumes === nothing || (col.base.volumes = deepcopy(update.volumes))
    return true
end

"""
True when every column slab `slab_idx` was designed against still has the
plan size and shape it had then (`designed_supports`), and so does the
column directly above each one (`designed_above`; both written by
[`install_floor_design!`](@ref)). Stored design details without that record
are treated as stale, since the columns they were checked at are unknown. A
slab with no stored design details has no checks to be stale.
"""
function _slab_checked_at_installed_columns(struc::BuildingStructure, slab_idx::Int)::Bool
    dd = struc.slabs[slab_idx].design_details
    dd isa NamedTuple || return true
    (hasproperty(dd, :designed_supports) && hasproperty(dd, :designed_above)) || return false
    # `designed_supports` is stamped from the slab's own design workspace, which
    # sizes each column to that slab's punching minimum (ACI 318-11 §11.11). Axial
    # / uniform column sizing can then grow a shared column past that minimum, and
    # `_support_beats` refuses to shrink it — so the stamp (the punching minimum)
    # can never equal the larger installed column, and strict equality would redesign
    # the slab forever (observed on the core office: a slab stamped at 20 in beside a
    # column grown to 24 in). A *larger* supporting column is conservative for a flat
    # PLATE: §11.11.2 two-way shear capacity Vc ∝ b0·d rises, the critical perimeter
    # moves outward so the direct shear Vu falls, and the clear span ln = l1 − c1
    # shortens so the transferred moment falls — a plate checked at a smaller column
    # stays adequate at a larger one, so no redesign is needed (and none is spent).
    # Flat SLABS are excluded: a larger column can push the critical section past the
    # drop panel (§13.2.5), so they keep strict equality.
    plate = struc.slabs[slab_idx].floor_type === :flat_plate
    for (cidx, (c1, c2, shape)) in dd.designed_supports
        col = struc.columns[cidx]
        if plate && col.c1 !== nothing && col.c2 !== nothing &&
           col.shape == shape && col.c1 >= c1 && col.c2 >= c2
            continue  # column grew (or is unchanged): conservative, still valid
        end
        (col.c1 == c1 && col.c2 == c2 && col.shape == shape) || return false
    end
    for (cidx, rec) in dd.designed_above
        a = struc.columns[cidx].column_above
        now = a === nothing ? nothing : (a.c1, a.c2, a.shape)
        isequal(now, rec) || return false
    end
    return true
end

"""
True when `update` is the column already on the building.

A proposal computed against these dimensions does not need another solve
after the envelope. A larger installed column does.
"""
function _support_update_installed(c1, c2, shape, section, update)::Bool
    c1 == update.c1 && c2 == update.c2 && shape == update.shape || return false
    update.section === nothing && return true
    return section == update.section
end

"""
True when every column this proposal sized is the column now on `struc`.

`outcome` that is missing or not installable does not match.
"""
function _supports_still_match(struc::BuildingStructure, outcome)::Bool
    outcome === nothing && return false
    StructuralSizer.is_installable(outcome) || return false
    for update in outcome.proposal.support_updates
        idx = update.source_index
        1 <= idx <= length(struc.columns) || return false
        col = struc.columns[idx]
        _support_update_installed(col.c1, col.c2, col.shape, col.base.section, update) ||
            return false
    end
    return true
end

"""
Adopt each column's governing proposal. Columns with no proposal stay put.
Returns the number of columns written.
"""
function _apply_support_envelope!(struc::BuildingStructure, proposals)
    by_col = Dict{Int, Vector{Tuple{Int, Any}}}()
    for (sidx, outcome) in enumerate(proposals)
        outcome === nothing && continue
        StructuralSizer.is_installable(outcome) || continue
        for update in outcome.proposal.support_updates
            push!(get!(by_col, update.source_index, Tuple{Int, Any}[]), (sidx, update))
        end
    end
    n = 0
    for cidx in sort!(collect(keys(by_col)))
        cidx in eachindex(struc.columns) || continue
        col = struc.columns[cidx]
        chosen = _governing_support_update(col.c1, col.c2, col.base.section, by_col[cidx])
        chosen === nothing && continue
        _install_governing_support!(col, chosen) && (n += 1)
    end
    return n
end

"""
    _commit_floor!(struc, slab_idx, outcome, floor_opts, column_opts, params) -> outcome

Install `outcome` on slab `slab_idx` without writing its columns, and
refresh that slab's volumes.
"""
function _commit_floor!(struc, slab_idx, outcome, floor_opts, column_opts, params)
    _require_installable_floor(outcome, slab_idx)
    request = floor_design_request(
        struc, slab_idx;
        options = floor_opts,
        column_options = column_opts,
        max_iterations = params.max_iterations,
        fire_rating = params.fire_rating,
    )
    install_floor_design!(struc, request, outcome; install_supports = false)
    _update_one_slab_volume!(struc, slab_idx, floor_opts)
    return outcome
end

function _isolated_floor_outcome(struc, slab_idx, floor_opts, column_opts, params, tc, col_cache)
    request = floor_design_request(
        struc, slab_idx;
        options = floor_opts,
        column_options = column_opts,
        max_iterations = params.max_iterations,
        fire_rating = params.fire_rating,
    )
    return design_floor(
        struc, request;
        verbose = false,
        workspace = StructuralSizer.FloorDesignWorkspace(col_cache),
        tc = tc,
    )
end

"""
Propose, envelope, commit, and lock for a floor whose slabs share columns.

Propose and commit do not write columns. The envelope and the lock do, after
every slab in that level has reported. Commit nodes keep [`slab_node_key`](@ref).
"""
function _push_two_level_slab_nodes!(
    graph_nodes, struc, slab_opts, column_opts, params, tc, col_cache, slab_prov, slab_floor_type,
)
    n = length(struc.slabs)
    proposed = Any[nothing for _ in 1:n]
    committed = Any[nothing for _ in 1:n]
    propose_keys = NodeKey[slab_propose_key(sidx) for sidx in 1:n]
    commit_keys = NodeKey[slab_node_key(sidx) for sidx in 1:n]

    for sidx in 1:n
        floor_opts = slab_opts[sidx]
        is_first = sidx == 1
        node_cache = col_cache
        fn = function (struc)
            if is_first
                StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :enter;
                                      floor_type=string(slab_floor_type), two_level=true)
                StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :enter;
                                      n_slabs=n, options_type=string(typeof(floor_opts)),
                                      has_column_opts=!isnothing(column_opts),
                                      max_iterations=params.max_iterations, two_level=true)
            end
            outcome = _isolated_floor_outcome(
                struc, sidx, floor_opts, column_opts, params, tc, node_cache)
            _require_installable_floor(outcome, sidx)
            proposed[sidx] = outcome
            return nothing
        end
        push!(graph_nodes, StageNode(
            propose_keys[sidx], NodeKey[], fn, false,
            slab_prov.param_slice, slab_prov.reads, slab_prov.writes,
            :slab_propose_v1))
    end

    push!(graph_nodes, StageNode(
        NODE_SLAB_ENVELOPE, propose_keys,
        function (struc)
            _apply_support_envelope!(struc, proposed)
            return nothing
        end,
        false, slab_prov.param_slice, slab_prov.reads, Symbol[:columns],
        :slab_column_envelope_v1))

    for sidx in 1:n
        floor_opts = slab_opts[sidx]
        node_cache = col_cache
        fn = function (struc)
            # The envelope writes the governing column once. A slab whose
            # proposal already used that column keeps its result.
            outcome = _supports_still_match(struc, proposed[sidx]) ? proposed[sidx] :
                _isolated_floor_outcome(
                    struc, sidx, floor_opts, column_opts, params, tc, node_cache)
            committed[sidx] = _commit_floor!(
                struc, sidx, outcome, floor_opts, column_opts, params)
            return nothing
        end
        push!(graph_nodes, StageNode(
            commit_keys[sidx], NodeKey[NODE_SLAB_ENVELOPE], fn, false,
            slab_prov.param_slice, slab_prov.reads, slab_prov.writes,
            :slab_commit_v1))
    end

    # The lock adopts the committed envelope. A slab committed against a
    # column that the envelope then enlarged is designed again against it,
    # until a round enlarges nothing. Columns only grow, so the rounds end;
    # the budget is the default growth ceiling.
    budget = StructuralSizer.monotone_budget(params.max_iterations, 48)
    push!(graph_nodes, StageNode(
        NODE_SLAB_LOCK, commit_keys,
        function (struc)
            run = StructuralSizer.settle!(; budget) do _
                _apply_support_envelope!(struc, committed) > 0 || return false
                for sidx in 1:n
                    _supports_still_match(struc, committed[sidx]) && continue
                    outcome = _isolated_floor_outcome(
                        struc, sidx, slab_opts[sidx], column_opts, params, tc, col_cache)
                    committed[sidx] = _commit_floor!(
                        struc, sidx, outcome, slab_opts[sidx], column_opts, params)
                end
                return true
            end
            StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :decision;
                                  lock_rounds = run.steps, lock_stop = string(run.stop))
            run.converged || error(
                "shared-column floor did not settle: columns were still growing after " *
                "$(run.steps) lock rounds, so some slabs were checked against smaller " *
                "columns than are installed")
            StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :exit)
            StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :exit)
            return nothing
        end,
        true, slab_prov.param_slice, slab_prov.reads, Symbol[:columns, :slabs],
        :slab_column_lock_v2))
    return graph_nodes
end

"""
    _make_slab_node_fn(slab_idx, floor_opts, column_opts, params, tc, col_cache=nothing) -> Function

Closure for a fine per-slab [`StageNode`](@ref): size exactly `slab_idx` and update
its volume. Byte-identical to the coarse `size_slabs!` per-slab body — same
`size_slab!` arguments (`max_iterations`, `fire_rating`, `column_opts`) and the
same shared `_col_cache` — followed by [`_update_one_slab_volume!`](@ref) (the
per-slab body of `update_slab_volumes!`).

FINDING 5 — `_col_cache` purity. The coarse `size_slabs!` builds ONE
`_col_cache` (an `ACIColumnCapacityCache`) and shares it across every slab.
The fine nodes close over that same object (`shared_col_cache`), which is
`nothing` for NLP and for non-concrete columns. This is result-neutral because
the cache is READ-ONLY after `precompute_capacities!`: its mutable fields
(`diagrams`, `diagrams_y`, `depths`, `is_square`, `obj_coeffs`, `fc_ksi`, …) are
written ONLY in `precompute_capacities!` / `_precompute_diagrams!`
(`StructuralSizer/src/members/codes/aci/columns/checker.jl`), and the discrete
MIP consumes a PROVIDED cache exclusively through read accessors —
`is_feasible`, `check_capacity`, `get_objective_coeff`, `explain_feasibility`
(`StructuralSizer/src/optimize/solvers/discrete_mip.jl`; the sole write path is
its `cache === nothing` precompute branch). Sharing therefore yields the same
P-M capacities as rebuilding. `verify_design_graph.jl` is the exact-first check.
"""
function _make_slab_node_fn(slab_idx::Int, floor_opts, column_opts,
                            params::DesignParameters,
                            tc::Union{Nothing, StructuralSizer.TraceCollector},
                            col_cache = nothing)
    return function (struc)
        request = floor_design_request(
            struc,
            slab_idx;
            options = floor_opts,
            column_options = column_opts,
            max_iterations = params.max_iterations,
            fire_rating = params.fire_rating,
        )
        outcome = design_floor!(
            struc,
            request;
            verbose = false,
            workspace = StructuralSizer.FloorDesignWorkspace(col_cache),
            tc = tc,
        )
        _require_installable_floor(outcome, slab_idx)
        _update_one_slab_volume!(struc, slab_idx, floor_opts)
        return nothing
    end
end

"""
    _make_slab_node_fn_ctx(slab_idx, floor_opts, column_opts, params, tc, col_cache=nothing) -> Function

Warm-state (Run 6) counterpart to [`_make_slab_node_fn`](@ref): a `(struc, ctx)`
closure that passes the shared read-only column P-M cache from the warm context
([`warm_col_cache`](@ref)) as `_col_cache`. When the context carries no cache,
the cold graph cache is used. Both are read-only after `precompute_capacities!`
(FINDING 5).
"""
function _make_slab_node_fn_ctx(slab_idx::Int, floor_opts, column_opts,
                                params::DesignParameters,
                                tc::Union{Nothing, StructuralSizer.TraceCollector},
                                col_cache = nothing)
    return function (struc, ctx)
        warm = warm_col_cache(ctx)
        request = floor_design_request(
            struc,
            slab_idx;
            options = floor_opts,
            column_options = column_opts,
            max_iterations = params.max_iterations,
            fire_rating = params.fire_rating,
        )
        outcome = design_floor!(
            struc,
            request;
            verbose = false,
            workspace = StructuralSizer.FloorDesignWorkspace(
                warm === nothing ? col_cache : warm,
            ),
            tc = tc,
        )
        _require_installable_floor(outcome, slab_idx)
        _update_one_slab_volume!(struc, slab_idx, floor_opts)
        return nothing
    end
end

_accessory_stud_material(opts::StructuralSizer.FlatPlateOptions) = opts.stud_material
_accessory_stud_material(opts::StructuralSizer.FlatSlabOptions) = opts.base.stud_material
_accessory_stud_material(::StructuralSizer.AbstractFloorOptions) = StructuralSizer.Stud_51

"""
Column plan size a shear cap or capital was built around, or `nothing`.

A round column under a rectangular head (edge or corner) is its equivalent
square, as in the punching check; under a round head it is the diameter.
"""
function _head_base_dims(col, head_shape::Symbol)
    (col === nothing || isnothing(col.c1) || isnothing(col.c2)) && return nothing
    if col.shape === :circular
        head_shape === :circular && return (col.c1, col.c1)
        c = StructuralSizer.equivalent_square_column(col.c1)
        return (c, c)
    end
    return (col.c1, col.c2)
end

"""Add `dv` onto the existing `mat` entry of a volume dict."""
function _bump_volume!(vols::MaterialVolumes, mat, dv)
    v = uconvert(u"m^3", dv)
    v > 0.0u"m^3" || return vols
    vols[mat] = get(vols, mat, 0.0u"m^3") + v
    return vols
end

function _concrete_volume_key(vols, fallback)
    for k in keys(vols)
        if k isa StructuralSizer.Concrete || k isa StructuralSizer.FiberReinforcedConcrete
            return k
        end
    end
    return fallback
end

"""
    _add_slab_accessory_volumes!(struc, slab, options)

Add drop-panel, shear-cap, and capital concrete, and shear-stud steel, to
`slab.volumes`. These are the same volume functions the summary used to add
beside the element volumes, so the takeoff and the carbon split see them.
Stud steel uses the floor options' stud material, not a generic density.
"""
function _add_slab_accessory_volumes!(struc, slab, options)
    concrete = _concrete_volume_key(slab.volumes, _primary_material(options))
    stud = _accessory_stud_material(options)
    r = slab.result
    if r isa StructuralSizer.FlatPlatePanelResult && hasproperty(r, :punching_check)
        pc = r.punching_check
        if hasproperty(pc, :details)
            for (col_idx, detail) in pc.details
                if hasproperty(detail, :studs) && !isnothing(detail.studs)
                    _bump_volume!(slab.volumes, stud, StructuralSizer.stud_steel_volume(detail.studs))
                end
                col = (col_idx isa Integer && 1 <= col_idx <= length(struc.columns)) ?
                      struc.columns[col_idx] : nothing
                dims(head) = _head_base_dims(col, head.shape)
                if hasproperty(detail, :shear_cap) && !isnothing(detail.shear_cap)
                    cd = dims(detail.shear_cap)
                    cd === nothing ||
                        _bump_volume!(slab.volumes, concrete, StructuralSizer.shear_cap_concrete_volume(
                            detail.shear_cap, cd...))
                end
                if hasproperty(detail, :capital) && !isnothing(detail.capital)
                    cd = dims(detail.capital)
                    _bump_volume!(slab.volumes, concrete, cd === nothing ?
                        StructuralSizer.capital_concrete_volume(detail.capital) :
                        StructuralSizer.capital_concrete_volume(detail.capital, cd...))
                end
            end
        end
    end
    for (_, V) in drop_panel_column_volumes(struc, slab)
        _bump_volume!(slab.volumes, concrete, V)
    end
    return slab
end

"""Concrete, rebar, structural steel, and timber in one volume dict.

Rebar and structural steel use that material's density. A reinforced-concrete
lump with no separate rebar volume stays concrete: no reinforcement ratio is assumed.
"""
function _quantity_increments(vols)
    t = material_takeoff(vols)
    timber = 0.0u"m^3"
    for (mat, vol) in vols
        mat isa StructuralSizer.Timber || continue
        timber += uconvert(u"m^3", vol)
    end
    return (concrete = t.concrete_volume, rebar = t.rebar_mass,
            steel = t.structural_steel_mass, timber = timber)
end

"""
    _update_one_slab_volume!(struc, slab_idx, options; primary_material=nothing)

Recompute `struc.slabs[slab_idx].volumes` from its current result — the single-slab
body of [`update_slab_volumes!`](@ref) (same `_primary_material` / floor-area /
`_compute_slab_volumes` derivation), then add drop panels, shear caps, capitals,
and shear studs. No-op for a non-converged (`nothing`-result) slab.
"""
function _update_one_slab_volume!(struc::BuildingStructure, slab_idx::Int, options;
                                  primary_material=nothing)
    slab = struc.slabs[slab_idx]
    isnothing(slab.result) && return struc
    mat = isnothing(primary_material) ? _primary_material(options) : primary_material
    floor_area = sum(struc.cells[idx].area for idx in slab.cell_indices)
    slab.volumes = _compute_slab_volumes(slab.result, floor_area, mat, options)
    _add_slab_accessory_volumes!(struc, slab, options)
    return struc
end

"""
    _slab_supporting_columns(struc, slab_idx) -> Vector{Int}

The 1-based `struc.columns` indices whose tributary overlaps slab `slab_idx`'s
cells — the columns a per-slab node may grow. Mirrors the slab→column overlap in
[`compute_slab_parallel_batches!`](@ref); used by the scheduler's partial
per-slab restore ([`restore_slab_node_writes!`](@ref)) — a path now made
UNREACHABLE end-to-end by the partial-slab-target guard in `run_target!`
(scheduler.jl) and exercised only by direct unit tests.
"""
function _slab_supporting_columns(struc::BuildingStructure, slab_idx::Int)
    slab_cells = Set(struc.slabs[slab_idx].cell_indices)
    cols = Int[]
    for (c_idx, col) in enumerate(struc.columns)
        if !isempty(col.tributary_cell_indices) &&
           !isempty(intersect(col.tributary_cell_indices, slab_cells))
            push!(cols, c_idx)
        end
    end
    return cols
end

