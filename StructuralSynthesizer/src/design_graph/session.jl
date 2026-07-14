# =============================================================================
# DesignGraph — Stateful Variation API (Run 2)
# =============================================================================
#
# A thin, ergonomic layer on top of the incremental engine (scheduler.jl). It is
# purely ADDITIVE: `design_building` stays the untouched behavioral reference,
# and this session merely orchestrates the existing `prepare_engine` /
# `run_target!` / `capture_incremental_design` / `dirty_frontier` machinery — it
# never re-implements the scheduler.
#
# A `DesignSession` is built from `(struc, base_params)`. Construction runs the
# BASE design ONCE (capturing per-node fingerprints + snapshots in the engine's
# memo) and stashes the resulting `BuildingDesign`. Thereafter:
#
#   redesign(session; overrides...)  — apply a DesignParameters diff relative to
#     the BASE params, recompute ONLY the nodes the diff dirties (clean nodes are
#     restored from their captured snapshots), and return a `BuildingDesign`.
#   vary(session, overrides)         — same, taking the diff as a NamedTuple
#     (convenient for research sweeps).
#   dirty_frontier(session; …)       — answer "given this override, which nodes
#     recompute?" WITHOUT running anything (deliverable 2).
#   requires_new_engine(session; …)  — whether the override touches a
#     prepare-affecting field and therefore needs a fresh session/engine.
#
# All diffs are taken relative to the session's BASE params (the state the memo
# was seeded from), so `redesign` / `vary` / `dirty_frontier` / previews are
# order-independent: two successive redesigns from the same session both mean
# "base + these overrides", never "previous variant + these overrides".
#
# PREPARE-AFFECTING GUARD: a variation that changes any `PREPARE_AFFECTING_FIELDS`
# param (geometry/framing/loads/materials/floor/columns/analysis baseline) cannot
# be incrementally re-derived over the fixed prepared baseline — see the scope
# note in scheduler.jl. `redesign` / `vary` surface a clear `ArgumentError`
# telling the caller to build a fresh session; `requires_new_engine` /
# `dirty_frontier` answer the same question WITHOUT throwing so a caller can
# branch ahead of time.
# =============================================================================

"""
    DesignSession

Stateful variation handle over an [`IncrementalEngine`](@ref) prepared for a
single `(struc, base_params)`. Holds the engine (with its seeded memo), the
BASE `DesignParameters` all diffs are measured against, and the captured BASE
[`BuildingDesign`](@ref).

Construct with [`DesignSession`](@ref)`(struc, base_params; …)`; drive with
[`redesign`](@ref) / [`vary`](@ref). Preview the impact of an override without
running via [`dirty_frontier`](@ref)`(session; …)` / [`requires_new_engine`](@ref).
The recomputed / restored node sets from the most recent run are observable via
[`last_recomputed`](@ref) / [`last_restored`](@ref).
"""
mutable struct DesignSession
    engine::IncrementalEngine
    base_params::DesignParameters
    base_design::BuildingDesign
    framing_opts::NamedTuple
end

"""
    DesignSession(struc, base_params; framing_opts=NamedTuple(), harmonize=true,
                  target=nothing, tc=nothing) -> DesignSession

Prepare `struc` for incremental design and run the BASE design once.

Mirrors [`prepare_engine`](@ref) + a full [`run_target!`](@ref) +
[`capture_incremental_design`](@ref): it prepares the fixed baseline, seeds the
memo by recomputing every node for `base_params`, and captures the resulting
`BuildingDesign` (available as [`base_design`](@ref)). `struc` is mutated by
`prepare!` exactly as `design_building` would; the engine works on independent
snapshots thereafter.

`target` defaults to the graph's [`terminal_node`](@ref) (a full design).
`harmonize` mirrors the `design_building` post-pipeline uniform-column pass.
"""
function DesignSession(struc::BuildingStructure, base_params::DesignParameters;
                       framing_opts::NamedTuple = NamedTuple(),
                       harmonize::Bool = true,
                       target::Union{Nothing, NodeKey} = nothing,
                       tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    engine = prepare_engine(struc, base_params; framing_opts = framing_opts, tc = tc)
    tgt = target === nothing ? terminal_node(engine.graph) : target
    run_target!(engine, base_params; target = tgt, framing_opts = framing_opts, tc = tc)
    base_design = capture_incremental_design(engine, base_params; harmonize = harmonize, tc = tc)
    return DesignSession(engine, base_params, base_design, framing_opts)
end

"""
    base_design(session::DesignSession) -> BuildingDesign

The `BuildingDesign` captured from the BASE run at session construction.
"""
base_design(session::DesignSession) = session.base_design

"""
    base_params(session::DesignSession) -> DesignParameters

The BASE `DesignParameters` every variation diff is measured against.
"""
base_params(session::DesignSession) = session.base_params

# -----------------------------------------------------------------------------
# Preview: param-diff -> dirty-frontier resolver (no execution) — deliverable 2.
# -----------------------------------------------------------------------------

"""
    _variant_params(session::DesignSession; overrides...) -> DesignParameters

The BASE params with `overrides` applied (via [`with`](@ref)). Internal helper
shared by the preview and run paths so both interpret overrides identically
(always relative to the BASE).
"""
_variant_params(session::DesignSession; overrides...) =
    with(session.base_params; overrides...)

"""
    changed_param_fields(session::DesignSession; overrides...) -> Vector{Symbol}

The `DesignParameters` fields that `overrides` change relative to the session's
BASE params (content-based; see the graph-level [`changed_param_fields`](@ref)).
Computed WITHOUT running anything.
"""
changed_param_fields(session::DesignSession; overrides...) =
    changed_param_fields(session.base_params, _variant_params(session; overrides...))

"""
    dirty_frontier(session::DesignSession; overrides...) -> Vector{NodeKey}

The dirty frontier induced by applying `overrides` to the session's BASE params:
every node whose declared [`param_slice`](@ref) intersects the changed fields,
plus all descendants, in topological order (see the graph-level
[`dirty_frontier`](@ref)). This answers "given this override, which nodes would
recompute?" WITHOUT running the design.

Note this is the structural UPPER bound; the scheduler's actual recompute set
(observable via [`last_recomputed`](@ref) after a [`redesign`](@ref)) may be
smaller because of early cutoff.
"""
dirty_frontier(session::DesignSession; overrides...) =
    dirty_frontier(session.engine.graph, changed_param_fields(session; overrides...))

"""
    prepare_affecting_changes(session::DesignSession; overrides...) -> Vector{Symbol}

The subset of `overrides`' changed fields that are prepare-affecting
(`PREPARE_AFFECTING_FIELDS`) relative to the BASE — i.e. the fields that would
require a fresh session/engine rather than an incremental redesign.
"""
function prepare_affecting_changes(session::DesignSession; overrides...)
    changed = changed_param_fields(session; overrides...)
    return sort(collect(intersect(Set(changed), Set(PREPARE_AFFECTING_FIELDS))))
end

"""
    requires_new_engine(session::DesignSession; overrides...) -> Bool

Whether applying `overrides` would change a prepare-affecting param and thus
require a fresh session/engine (see [`prepare_affecting_changes`](@ref)).
Computed WITHOUT running anything, so a caller can branch (redesign in place vs
rebuild) ahead of time.
"""
requires_new_engine(session::DesignSession; overrides...) =
    !isempty(prepare_affecting_changes(session; overrides...))

# -----------------------------------------------------------------------------
# Variation runs.
# -----------------------------------------------------------------------------

"""
    redesign(session::DesignSession; harmonize=true, target=nothing, tc=nothing,
             overrides...) -> BuildingDesign

Apply `overrides` to the session's BASE params, recompute ONLY the nodes the
diff dirties (clean nodes are restored from their captured per-node snapshots
via the existing scheduler — this never re-implements it), and return the
resulting `BuildingDesign`.

Delegates the recompute to [`run_target!`](@ref) and the capture to
[`capture_incremental_design`](@ref). The recomputed / restored node sets are
observable afterwards via [`last_recomputed`](@ref) / [`last_restored`](@ref).

Throws `ArgumentError` if `overrides` change any prepare-affecting param
(`PREPARE_AFFECTING_FIELDS`) relative to the BASE: such a change invalidates the
fixed prepared baseline and requires a fresh `DesignSession` (see the scope note
in scheduler.jl). Use [`requires_new_engine`](@ref) to check first.

Also throws `ArgumentError` if the effective (merged) params carry an EFFECTIVE
`member_group_overrides` entry: the variation graph never routes member sizing
through `size_member_group!`, so the knob cannot be honored here and is refused
rather than silently dropped (see
[`_assert_member_group_overrides_unsupported`](@ref)). An all-unset override is a
documented no-op and does not throw.
"""
function redesign(session::DesignSession;
                  harmonize::Bool = true,
                  target::Union{Nothing, NodeKey} = nothing,
                  tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
                  overrides...)
    bad = prepare_affecting_changes(session; overrides...)
    isempty(bad) || throw(ArgumentError(
        "DesignSession.redesign: override(s) $bad affect the prepared baseline " *
        "(geometry/loads/materials/columns/floor/analysis) and cannot be " *
        "incrementally re-derived. Build a fresh DesignSession(struc, new_params) " *
        "for this variation."))

    variant = _variant_params(session; overrides...)
    # Fail-loud (Run 4, Part 1): path-complete the member_group_overrides refusal
    # to the variation door. The override can be injected here as a VARIATION kwarg
    # on an already-built engine, which never re-enters run_pre_sizing_validation;
    # the engine graph never routes member sizing through size_member_group!, so an
    # effective override would yield an empty dirty frontier and a silently-UNCHANGED
    # design. Refuse it on the EFFECTIVE (merged) params — identical posture to
    # design_building. This does NOT reclassify the field as prepare-affecting.
    _assert_member_group_overrides_unsupported(variant)
    tgt = target === nothing ? terminal_node(session.engine.graph) : target
    run_target!(session.engine, variant; target = tgt,
                framing_opts = session.framing_opts, tc = tc)
    return capture_incremental_design(session.engine, variant; harmonize = harmonize, tc = tc)
end

"""
    vary(session::DesignSession, overrides::NamedTuple; kwargs...) -> BuildingDesign

NamedTuple-diff form of [`redesign`](@ref): `vary(session, (; foundation_options=fp))`
is equivalent to `redesign(session; foundation_options=fp)`. Ergonomic for
research sweeps that carry a `param_diff` as data. `kwargs` (`harmonize`,
`target`, `tc`) are forwarded to [`redesign`](@ref).
"""
vary(session::DesignSession, overrides::NamedTuple; kwargs...) =
    redesign(session; kwargs..., overrides...)

# -----------------------------------------------------------------------------
# Observation accessors — thin session-level wrappers over the engine's.
# -----------------------------------------------------------------------------

"""
    last_recomputed(session::DesignSession) -> Vector{NodeKey}

Node keys RECOMPUTED on the session's most recent run (base construction or the
last [`redesign`](@ref) / [`vary`](@ref)), in execution order.
"""
last_recomputed(session::DesignSession) = last_recomputed(session.engine)

"""
    last_restored(session::DesignSession) -> Vector{NodeKey}

Node keys served CLEAN from the memo (restored from snapshot, not re-run) on the
session's most recent run, in execution order.
"""
last_restored(session::DesignSession) = last_restored(session.engine)
