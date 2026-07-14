# =============================================================================
# DesignGraph — Demand-Driven Incremental Scheduler (Run 2)
# =============================================================================
#
# NEW entry point layered on top of the Run-1 graph. `design_building` is left
# entirely untouched (it remains the exact behavioral reference); the incremental
# machinery here is opt-in.
#
# The scheduler recomputes only what a parameter change actually invalidates:
#
#   • For a target node it walks its transitive dependencies in topological order.
#   • A node is recomputed only when its INPUT hash differs from the memo.
#   • Early cutoff: when a recomputed node's OUTPUT hash matches the memoized one,
#     downstream nodes see unchanged inputs and stay CLEAN (restored, not re-run).
#   • Clean nodes are restored from a per-node whole-struc snapshot, so a clean
#     prefix is never recomputed — the restored state is exactly what a recompute
#     would have produced (see core/snapshot.jl).
#
# `sync_asap!` is honored via a LEVEL BARRIER: the scheduler walks the graph in
# dependency levels (Kahn waves) and flushes `sync_asap!` exactly ONCE after a
# completed level in which a RECOMPUTED node declares `needs_sync`, then snapshots
# that level's dirty nodes AFTER the sync — so a restored clean node still carries
# its post-sync state. For the current coarse linear chain every level holds one
# node, so this reduces to (and is byte-identical with) the per-node placement
# `design_building` uses. The barrier is the abstraction the next wave (fine
# per-group sizing nodes) builds on: a level of MULTIPLE sizing nodes syncs the
# whole model once, not once per node.
#
# SCOPE / SAFETY (Run 2): the engine caches the SIZING pipeline over a FIXED
# prepared baseline. Parameters that change the prepared state (geometry, loads,
# floor system, materials, columns, tributary, framing, analysis defaults) would
# invalidate that baseline, so changing any of them requires a NEW engine — the
# scheduler guards against this and errors rather than silently reusing a stale
# baseline. Re-preparing on such changes is deferred to the redesign()/
# DesignSession work in the next task.
# =============================================================================

"""
    NodeMemo

In-process memo entry for one node: its last `input_hash`, its resulting
`output_hash`, and the per-node whole-struc `state` snapshot used to restore the
node's post-state when it stays clean.
"""
struct NodeMemo
    input_hash::String
    output_hash::String
    state::BuildingStructure
end

# DesignParameters fields consumed by `prepare!` (initialize! / estimate columns
# / to_asap!). Changing any of these changes the prepared baseline, so the
# incremental engine (which fixes the baseline) cannot reuse snapshots across
# such a change. Kept conservative — over-inclusion only forces a new engine.
#
# `:pattern_loading` is prepare-affecting because it is a BUILD-TIME structural
# decision, not a magnitude that a later `sync_asap!` can retrofit. `to_asap!`
# (analyze/asap/utils.jl §`use_patterns = params.pattern_loading != :none`)
# decides AT MODEL-BUILD TIME whether the split `cell_dead_loads`/`cell_live_loads`
# load objects are populated (patterns) or only the combined `cell_tributary_loads`
# (`:none`). `sync_asap!` gates its multi-case pattern solve on those split
# vectors being non-empty (`!isempty(struc.cell_dead_loads)`), so over a `:none`
# baseline it can NEVER upgrade to a patterned solve — it would silently return an
# UNPATTERNED, unconservative design (and the reverse would double-count). The
# load-object COMPOSITION cannot be mutated after the build, so a fresh engine is
# the only correct response — hence the guard here rather than a sizing-slice
# entry.
#
# AUDIT — `:load_combinations` is deliberately NOT prepare-affecting. It, too, is
# read at model-build time (`to_asap!` → `envelope_pressure(params.load_combinations,…)`
# for the combined path and `governing_combo(params)` D/L factors for the pattern
# path), BUT unlike `:pattern_loading` it only sets the pressure MAGNITUDE on the
# already-existing load objects — it never changes which load objects exist.
# `sync_asap!` recomputes exactly those magnitudes from the current
# `params.load_combinations` on every sizing-node recompute (the combined-path
# `envelope_pressure` refresh, the pattern-path `governing_combo` D/L refresh,
# `_sync_shell_area_pressures!`, and `_sync_vault_thrust_line_loads!` — the last
# rebuilds the vault-thrust edge line loads `to_asap!` bakes from
# `governing_combo(params)`, which a floor emitting `structural_effects`
# (VaultResult → LateralThrust) would otherwise leave frozen at the base combo).
# Because every sizing node runs `sync_asap!` (`needs_sync == true`), a
# `:load_combinations` change over a fixed baseline IS genuinely refreshed. It
# therefore stays in the `:slab_sizing`/`:members` param slices (so those nodes
# recompute + resync), and must NOT be reclassified here.
const PREPARE_AFFECTING_FIELDS = Symbol[
    :loads, :floor, :materials, :columns, :tributary_axis, :scoped_floor_overrides,
    :geometry_is_centerline, :diaphragm_mode, :diaphragm_E, :diaphragm_ν,
    :default_frame_E, :default_frame_G, :default_frame_ρ,
    :pattern_loading,
]

"""
    IncrementalEngine

Stateful, in-process incremental design engine over a single prepared
`BuildingStructure`. Holds the design graph, the fixed prepared baseline, the
per-node memo (keyed by [`NodeKey`](@ref)), and the current working structure.

Construct with [`prepare_engine`](@ref); drive with [`run_target!`](@ref) /
[`redesign_incremental!`](@ref). The set of nodes recomputed vs restored on the
last run is observable via [`last_recomputed`](@ref) / [`last_restored`](@ref)
(consumed by the redesign()/invalidation-matrix work in the next task).
"""
mutable struct IncrementalEngine
    graph::DesignGraph
    params::DesignParameters
    baseline::BuildingStructure
    base_hash::String
    memo::Dict{NodeKey, NodeMemo}
    struc::BuildingStructure
    _recomputed::Vector{NodeKey}
    _restored::Vector{NodeKey}
end

"""
    _geometry_fingerprint(struc) -> Vector

Real geometry fingerprint of the PREPARED structure: the (x,y,z) endpoint
coordinates (in metres) of every frame element in the solved Asap model. Unlike a
bare element COUNT, this distinguishes geometries that share element counts but
differ in span/coordinates, so two different prepared baselines can never alias in
a shared memo. Returns an empty vector when the model has not been built yet.
"""
function _geometry_fingerprint(struc::BuildingStructure)
    model = struc.asap_model
    (model === nothing || isempty(model.elements)) && return Any[]
    coords = Any[]
    for el in model.elements
        p1 = el.nodeStart.position
        p2 = el.nodeEnd.position
        push!(coords, (ustrip(u"m", p1[1]), ustrip(u"m", p1[2]), ustrip(u"m", p1[3]),
                       ustrip(u"m", p2[1]), ustrip(u"m", p2[2]), ustrip(u"m", p2[3])))
    end
    return coords
end

"""
    engine_base_hash(struc, params) -> String

Baseline fingerprint for an engine: mixes the prepare-affecting parameter slice
with a REAL geometry fingerprint of the prepared structure (frame-element endpoint
coordinates via [`_geometry_fingerprint`](@ref)). Folded into every node's
[`input_hash`](@ref) so memo entries never alias across different prepared
baselines — including two baselines with equal element counts but different spans,
which a count-only proxy would have collided.
"""
function engine_base_hash(struc::BuildingStructure, params::DesignParameters)
    return content_hash((
        hash_param_slice(params, PREPARE_AFFECTING_FIELDS),
        _geometry_fingerprint(struc),
    ))
end

"""
    prepare_engine(struc, params; framing_opts=NamedTuple(), tc=nothing) -> IncrementalEngine

Prepare `struc` for incremental design and build the engine. Mirrors the
`prepare!` + pre-sizing-validation prefix of [`design_building`](@ref), then
captures the pristine, pre-sizing state as the engine's fixed baseline and builds
the design graph. Does not run any sizing — call [`run_target!`](@ref) or
[`redesign_incremental!`](@ref).

`struc` is mutated by `prepare!` exactly as `design_building` would; the engine
works on independent snapshots thereafter, so the caller's `struc` is not
mutated by subsequent scheduler runs.
"""
function prepare_engine(struc::BuildingStructure, params::DesignParameters;
                        framing_opts::NamedTuple = NamedTuple(),
                        tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    prepare!(struc, params; framing_opts = framing_opts)

    ok, val_errors = run_pre_sizing_validation(struc, params; tc = tc)
    ok || throw(PreSizingValidationError(val_errors))

    graph     = build_design_graph(struc, params; tc = tc)
    baseline  = capture_node_state(struc)          # prepared, pre-sizing
    base_hash = engine_base_hash(struc, params)
    working   = restore_node_state(baseline)

    return IncrementalEngine(graph, params, baseline, base_hash,
                             Dict{NodeKey, NodeMemo}(), working,
                             NodeKey[], NodeKey[])
end

"""
    last_recomputed(engine::IncrementalEngine) -> Vector{NodeKey}

Node keys that were RECOMPUTED (re-run) on the most recent [`run_target!`](@ref),
in execution order. Empty before the first run.
"""
last_recomputed(engine::IncrementalEngine) = copy(engine._recomputed)

"""
    last_restored(engine::IncrementalEngine) -> Vector{NodeKey}

Node keys that were served CLEAN from the memo (restored from snapshot, not
re-run) on the most recent [`run_target!`](@ref), in execution order.
"""
last_restored(engine::IncrementalEngine) = copy(engine._restored)

"""
    terminal_node(g::DesignGraph) -> NodeKey

The last node in the graph's [`topological_order`](@ref) — the default target
for a full design (foundations when present, else members).
"""
terminal_node(g::DesignGraph) = last(topological_order(g))

# -----------------------------------------------------------------------------
# Dirty-frontier resolver (observable, no execution).
# -----------------------------------------------------------------------------

"""
    changed_param_fields(old::DesignParameters, new::DesignParameters) -> Vector{Symbol}

Names of the `DesignParameters` fields whose (content-hashed) values differ
between `old` and `new`. Content-based, so semantically-equal values built by
different calls compare equal.
"""
function changed_param_fields(old::DesignParameters, new::DesignParameters)
    changed = Symbol[]
    for f in fieldnames(DesignParameters)
        if content_hash(getfield(old, f)) != content_hash(getfield(new, f))
            push!(changed, f)
        end
    end
    return changed
end

"""
    dirty_frontier(g::DesignGraph, changed_fields) -> Vector{NodeKey}

The conservative dirty set induced by a parameter change: every node whose
declared [`param_slice`](@ref) intersects `changed_fields`, plus all of their
[`descendants`](@ref) (forward dependency closure), in topological order. This is
the structural upper bound the scheduler may recompute — computable WITHOUT
running anything, so the redesign()/invalidation-matrix tests can assert
"changing param X marks nodes {…} dirty" directly. The scheduler's actual
recompute set may be smaller (early cutoff).
"""
function dirty_frontier(g::DesignGraph, changed_fields)
    cf = Set{Symbol}(changed_fields)
    seeds = NodeKey[node_key(nd) for nd in g.nodes
                    if !isdisjoint(Set{Symbol}(param_slice(nd)), cf)]
    isempty(seeds) && return NodeKey[]
    return descendants(g, seeds; include_seeds = true)
end

"""
    dirty_frontier(engine::IncrementalEngine, new_params::DesignParameters) -> Vector{NodeKey}

Dirty frontier for changing the engine's parameters to `new_params`, diffing
against the parameters the engine currently holds.
"""
dirty_frontier(engine::IncrementalEngine, new_params::DesignParameters) =
    dirty_frontier(engine.graph, changed_param_fields(engine.params, new_params))

# -----------------------------------------------------------------------------
# The scheduler.
# -----------------------------------------------------------------------------

"""
    run_target!(engine, params; target=terminal_node, framing_opts=NamedTuple(), tc=nothing)
        -> (recomputed::Vector{NodeKey}, restored::Vector{NodeKey})

Demand-driven incremental run of the design graph up to `target`.

Rebuilds the graph for `params` (identity/provenance are content-stable, only the
work closures change), then walks `target`'s transitive dependencies in
topological order. For each node it computes the [`input_hash`](@ref) from its
dependencies' output hashes and its param slice; a node is RECOMPUTED only when
that hash differs from the memo, otherwise it is restored CLEAN from its per-node
snapshot. Early cutoff falls out naturally: a recomputed node whose
[`output_hash`](@ref) is unchanged leaves its descendants' input hashes unchanged,
so they stay clean.

After the run, `engine.struc` holds the working structure at `target`'s
post-state, and the recomputed / restored node sets are queryable via
[`last_recomputed`](@ref) / [`last_restored`](@ref).

Throws if `params` differs from the engine's parameters on any
prepare-affecting field (`PREPARE_AFFECTING_FIELDS`) — such a change invalidates
the fixed baseline and requires a new engine (see module scope note).
"""
function run_target!(engine::IncrementalEngine, params::DesignParameters;
                     target::NodeKey = terminal_node(engine.graph),
                     framing_opts::NamedTuple = NamedTuple(),
                     tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    # Guard: the fixed baseline is only valid for params sharing the same
    # prepared state. Refuse (rather than silently reuse a stale baseline) if a
    # prepare-affecting field changed.
    changed = changed_param_fields(engine.params, params)
    bad = intersect(Set(changed), Set(PREPARE_AFFECTING_FIELDS))
    isempty(bad) || throw(ArgumentError(
        "IncrementalEngine: parameter(s) $(sort(collect(bad))) affect the prepared " *
        "baseline (geometry/loads/materials/columns/floor/analysis). Build a new " *
        "engine with prepare_engine(struc, params); Run-2 engines fix the baseline."))

    # Rebuild the work graph for the new params (semantic keys + provenance are
    # identical; only the closures differ). The prepared baseline carries the
    # fixed slab count, and the fine per-slab nodes are emitted as roots in
    # ascending `slab_idx` (eachindex) order (NOT `slab_parallel_batches`; see
    # build_design_graph — Finding 1), so the fine per-slab node topology is
    # stable across the rebuild. Then re-fingerprint the baseline.
    engine.graph  = build_design_graph(engine.baseline, params; tc = tc)
    engine.params = params

    haskey(engine.graph.index, target) ||
        throw(ArgumentError("run_target!: unknown target node :$target"))

    needed = Set(transitive_dependencies(engine.graph, target))   # target's closure

    # ── EXACT-FIRST GUARD (P1): forbid a PARTIALLY-covered slab level ──────────
    # Fine per-slab nodes are EDGELESS ROOTS (build_design_graph), so a `target`
    # whose transitive closure includes only a STRICT SUBSET of the slab-root
    # nodes (e.g. `target = slab_node_key(k)`) would memoize that subset ALONE.
    # Slab sizing reads LIVE shared supporting columns that siblings grow
    # MONOTONICALLY, so node k memoized in isolation was sized in the WRONG
    # column-growth context. A subsequent run-to-terminal would then classify a
    # MIXED clean/dirty slab level and take the partial-restore overlay (branch
    # 3b), silently DIVERGING from a from-scratch `design_building` — an
    # exact-first VIOLATION. We make that state UNREPRESENTABLE by construction:
    # if `target`'s closure touches any slab root it MUST contain ALL of them.
    # A full run (`target = terminal`, `:members`, `:foundations`, or no target)
    # always pulls in every slab root through `:members`' dependency on all slab
    # nodes, so it passes; only a bare single/partial slab target is rejected.
    # This guard is the enforcing mechanism that makes the mixed slab level
    # unreachable end-to-end (previously only ASSUMED unreachable). It equally
    # covers `DesignSession(target=…)` and `redesign(…, target=…)`, which route
    # their `target` through here.
    slab_roots = Set{NodeKey}(node_key(nd) for nd in engine.graph.nodes
                              if is_slab_node_key(node_key(nd)))
    needed_slab_roots = intersect(needed, slab_roots)
    if !isempty(needed_slab_roots) && needed_slab_roots != slab_roots
        missing_roots = sort!(collect(setdiff(slab_roots, needed_slab_roots)))
        throw(ArgumentError(
            "run_target!: target :$target would memoize only a STRICT SUBSET of the " *
            "slab-root nodes (uncovered: $(missing_roots)). Fine per-slab nodes share " *
            "MONOTONICALLY-grown supporting columns, so a partial slab level cannot be " *
            "memoized without diverging from a from-scratch design_building (exact-first). " *
            "Target the terminal node (a full design), :members, or :foundations instead; " *
            "per-slab INDEPENDENT targeting needs the deferred Option-A per-group override " *
            "parameters."))
    end

    # Reset the working structure to the prepared baseline. Each node then leaves
    # `engine.struc` at ITS post-state, so a dirty node always runs against its
    # (already-processed) predecessor's post-state, and a root dirty node runs
    # against the baseline. (Linear sizing chain — DAG fan-in is Run 3.)
    engine.struc = restore_node_state(engine.baseline)

    recomputed = NodeKey[]
    restored   = NodeKey[]
    pass_output = Dict{NodeKey, String}()   # this pass's output hash per processed node

    # Walk the graph in dependency LEVELS (Kahn waves), restricted to `target`'s
    # transitive-dependency closure. A level may now hold MULTIPLE fine per-slab
    # nodes, so the per-level protocol is (see core/snapshot.jl for the invariants):
    #
    #   1. CLASSIFY every needed node clean/dirty by input hash WITHOUT mutating
    #      `engine.struc` (a dependency always lives in a strictly earlier level,
    #      so `pass_output[d]` is populated).
    #   2. ALL-CLEAN level → whole-struc restore from ONE representative node's
    #      snapshot. Every clean snapshot in a level is byte-identical (taken after
    #      the same level barrier sync), so this restores the shared post-level
    #      state INCLUDING the global Asap model, with no clobbering.
    #   3. MIXED / ALL-DIRTY level → run the dirty nodes in place on the live
    #      struc, THEN overlay each clean node's per-group writes (partial restore
    #      — see `restore_slab_node_writes!`; max-merged for shared columns), THEN
    #      flush `sync_asap!` ONCE if a dirty node needs it (rebuilding the model
    #      from the combined slab state), THEN snapshot the dirty nodes AFTER the
    #      sync. This ordering (dirty-run → clean-overlay → single barrier sync) is
    #      the documented invariant that makes a multi-node level order-independent.
    #
    # For the coarse linear chain every level holds one node, so this reduces to
    # (and is byte-identical with) design_building's per-node run/sync/snapshot.
    # A slab level is never MIXED clean/dirty, now ENFORCED (not merely assumed)
    # by TWO independent mechanisms: (1) under the global-parameter model a
    # slab-affecting param dirties every slab node and a non-slab param dirties
    # none (all-or-nothing by params), and (2) the partial-slab-target guard above
    # rejects any run whose closure would memoize only a strict subset of the slab
    # roots, so the memo can never hold a partial slab level either. Consequently
    # the partial-restore overlay (the `clean_keys` branch at 3b) is UNREACHABLE
    # end-to-end; end-to-end runs hit only the all-clean and all-dirty paths, and a
    # defensive check below fails LOUD if a partial slab level ever slips through.
    # The overlay helpers (`restore_slab_node_writes!` / `_adopt_larger_column!`)
    # are covered by DIRECT unit tests instead (test_design_graph_incremental.jl,
    # the "partial per-slab restore (Findings 3 + 4)" testset). See NOTES on the
    # deferral of true per-slab INDEPENDENT variation (Option A).
    for level in topological_levels(engine.graph)
        level_keys = NodeKey[k for k in level if k in needed]
        isempty(level_keys) && continue

        # 1. Classify (no struc mutation).
        node_ih = Dict{NodeKey, String}()
        clean_keys = NodeKey[]
        dirty_keys = NodeKey[]
        for key in level_keys
            node = get_node(engine.graph, key)
            deps = sort(dependencies(node))
            upstream = String[pass_output[d] for d in deps]
            ih = input_hash(node, upstream, params; base_hash = engine.base_hash)
            node_ih[key] = ih
            prev = get(engine.memo, key, nothing)
            if prev !== nothing && prev.input_hash == ih
                push!(clean_keys, key)
            else
                push!(dirty_keys, key)
            end
        end

        if isempty(dirty_keys)
            # 2. ALL-CLEAN — whole-struc restore from a representative snapshot
            #    (identical across the level); this also restores the global model.
            rep = engine.memo[first(level_keys)]
            engine.struc = restore_node_state(rep.state)
            for key in level_keys
                pass_output[key] = engine.memo[key].output_hash
                push!(restored, key)
            end
            continue
        end

        # 3. MIXED / ALL-DIRTY.
        # Defensive (P1): only slab nodes ever share a multi-node level; members /
        # foundations are singletons (a singleton level is all-clean or all-dirty,
        # handled above). With the partial-slab-target guard, all slab roots are
        # co-memoized, so a slab level is never partially clean. If a clean slab
        # node appears alongside dirty siblings, a partial memo slipped through —
        # fail LOUD rather than take the divergent overlay (exact-first).
        if !isempty(clean_keys)
            mixed_clean_slabs = NodeKey[k for k in clean_keys if is_slab_node_key(k)]
            isempty(mixed_clean_slabs) || error(
                "run_target!: a slab level is unexpectedly MIXED (clean slab node(s) " *
                "$(sort(mixed_clean_slabs)) alongside dirty sibling(s)). The " *
                "partial-slab-target guard should make this unrepresentable; this " *
                "indicates a memoization-coverage bug, not a legitimate incremental run.")
        end
        # 3a. Run dirty nodes in place against the predecessor post-state.
        for key in dirty_keys
            run!(get_node(engine.graph, key), engine.struc, params, nothing)
        end
        # 3b. Overlay clean nodes' per-group writes (fine slab nodes → partial
        #     restore; a clean non-slab node can only appear in a singleton level,
        #     handled by the all-clean branch above, so this loop sees slab nodes).
        for key in clean_keys
            sidx = slab_node_index(key)
            if sidx === nothing
                engine.struc = restore_node_state(engine.memo[key].state)
            else
                restore_slab_node_writes!(engine.struc, engine.memo[key].state, sidx,
                                          _slab_supporting_columns(engine.struc, sidx))
            end
            pass_output[key] = engine.memo[key].output_hash
            push!(restored, key)
        end
        # 3c. Barrier sync once, only when a recomputed node needs it.
        level_needs_sync(engine.graph, dirty_keys) &&
            sync_asap!(engine.struc; params = params)
        # 3d. Snapshot + memoize recomputed nodes AFTER the sync.
        for key in dirty_keys
            node = get_node(engine.graph, key)
            oh = output_hash(node, engine.struc)
            engine.memo[key] = NodeMemo(node_ih[key], oh, capture_node_state(engine.struc))
            pass_output[key] = oh
            push!(recomputed, key)
        end
    end

    engine._recomputed = recomputed
    engine._restored   = restored
    return (recomputed, restored)
end

"""
    capture_incremental_design(engine, params; harmonize=true, tc=nothing, t_start=nothing)
        -> BuildingDesign

Capture a `BuildingDesign` from the engine's current working structure, mirroring
the post-pipeline tail of [`design_building`](@ref): optional uniform-column
harmonization (with a follow-up `sync_asap!` when it changes columns) then
`capture_design`. Visualization-model building and the final `restore!` are NOT
performed (the engine keeps its working structure); pass `skip_visualization` in
`params` accordingly.

Intended to be called after [`run_target!`](@ref) has run to the terminal node.
"""
function capture_incremental_design(engine::IncrementalEngine, params::DesignParameters;
                                    harmonize::Bool = true,
                                    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
                                    t_start = nothing)
    if harmonize && params.uniform_column_sizing !== :off
        n = harmonize_uniform_column_sizes!(engine.struc, params)
        n > 0 && sync_asap!(engine.struc; params = params)
    end
    return capture_design(engine.struc, params; t_start = t_start, tc = tc)
end

"""
    redesign_incremental!(engine, params; target=terminal_node, harmonize=true, kwargs...)
        -> BuildingDesign

Convenience wrapper: [`run_target!`](@ref) to `target`, then
[`capture_incremental_design`](@ref). Returns the resulting `BuildingDesign`;
the recomputed / restored node sets remain queryable via
[`last_recomputed`](@ref) / [`last_restored`](@ref).
"""
function redesign_incremental!(engine::IncrementalEngine, params::DesignParameters;
                               target::NodeKey = terminal_node(engine.graph),
                               harmonize::Bool = true,
                               framing_opts::NamedTuple = NamedTuple(),
                               tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    # Fail-loud (Run 4, Part 1): refuse an EFFECTIVE member_group_overrides on the
    # variation door. `params` here are the effective params for this run; the
    # engine graph never routes member sizing through size_member_group!, so an
    # effective override would be silently dropped (empty dirty frontier → an
    # UNCHANGED design). Same posture as design_building; NOT prepare-affecting.
    _assert_member_group_overrides_unsupported(params)
    run_target!(engine, params; target = target, framing_opts = framing_opts, tc = tc)
    return capture_incremental_design(engine, params; harmonize = harmonize, tc = tc)
end
