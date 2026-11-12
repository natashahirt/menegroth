# =============================================================================
# DesignGraph — Canonical NodeKeys + Pipeline Provenance (Run 2)
# =============================================================================
#
# The whole incremental engine keys off SEMANTIC node identities, never a
# stage's positional index. This file is the single source of truth for:
#
#   1. the canonical, content-stable `NodeKey` identity set (prepare sub-steps,
#      the sizing stages, and capture), and
#   2. the per-node provenance (`param_slice` / `struc_reads` / `struc_writes` /
#      `code_version`) that `build_design_graph` attaches to each executed node.
#
# Keeping the identities and their provenance here (rather than inline in
# `build_design_graph`) guarantees the key `:slab_sizing` always means "slab
# sizing" — regardless of params or the flat-plate vs beam/column branch — which
# is exactly the invariant the fingerprint/memo relies on.
# =============================================================================

# -----------------------------------------------------------------------------
# Canonical NodeKey identities
# -----------------------------------------------------------------------------
# Prepare sub-steps + capture are named here as stable identities even though
# Run 2's executed graph (`build_design_graph`) only materializes the three
# sizing stages as nodes. Naming them now (a) documents the full pipeline's
# stable key vocabulary and (b) lets later runs promote prepare/capture to real
# nodes without renaming anything the memo already keys off.

"Prepare sub-step: `initialize!` (cells, slabs, members, loads)."
const NODE_INITIALIZE       = :initialize
"Prepare sub-step: `populate_levels!` framing auto-generation."
const NODE_POPULATE_FRAMING = :populate_framing
"Prepare sub-step: `estimate_column_sizes!`."
const NODE_ESTIMATE_COLUMNS = :estimate_columns
"Prepare sub-step: `to_asap!` analysis-model build + pristine `snapshot!`."
const NODE_BUILD_ASAP       = :build_asap

"Sizing stage: slab sizing (`size_slabs!` + `update_slab_volumes!`)."
const NODE_SLAB_SIZING      = :slab_sizing
"Sizing stage: member sizing — flat-plate `_reconcile_columns!` OR beam/column `_size_beams_columns!` (same identity, either branch)."
const NODE_MEMBERS          = :members
"Sizing stage: foundation sizing (`_size_foundations!`)."
const NODE_FOUNDATIONS      = :foundations

"Ordinary concrete wall checks. Present when lateral design was requested."
const NODE_ORDINARY_WALLS   = :ordinary_walls

"Result capture (`capture_design`)."
const NODE_CAPTURE          = :capture

# -----------------------------------------------------------------------------
# Fine per-slab node identities (Run 3 — fine-node topology)
# -----------------------------------------------------------------------------
# `:slab_sizing` is split into one node PER slab index, keyed `:slab_sizing_s{idx}`
# (`slab_node_key(idx)`). The split changes the graph TOPOLOGY only — each per-slab
# node reads and writes exactly what the coarse `:slab_sizing` node did (same
# `param_slice` / `struc_reads` / `struc_writes` / `code_version`), so it inherits
# `NODE_SLAB_SIZING`'s provenance via `pipeline_provenance`. The coarse identity
# `NODE_SLAB_SIZING` remains the SEMANTIC name of "slab sizing" (used by
# `dirty_frontier`/tests that reason about the stage) and is still materialized as
# a real node when a structure has zero slabs.

"String prefix identifying a fine per-slab node key (`:slab_sizing_s3` → slab 3)."
const SLAB_NODE_PREFIX = "slab_sizing_s"

"""
    slab_node_key(slab_idx::Integer) -> NodeKey

Deterministic content-stable key for the fine node that sizes slab `slab_idx`
(`:slab_sizing_s{slab_idx}`). The 1-based `slab_idx` matches `struc.slabs`
indexing, so the key is stable across params and rebuilds.
"""
slab_node_key(slab_idx::Integer) = Symbol(SLAB_NODE_PREFIX, slab_idx)

"Prefix for a propose node (`:slab_propose_s3` sizes slab 3 on a private copy)."
const SLAB_PROPOSE_PREFIX = "slab_propose_s"

"""Propose-node key for slab `slab_idx`. Not a [`slab_node_key`](@ref): the
commit node keeps that key, because it is the one that writes the slab."""
slab_propose_key(slab_idx::Integer) = Symbol(SLAB_PROPOSE_PREFIX, slab_idx)

"One node. Adopts the governing column size from every propose result."
const NODE_SLAB_ENVELOPE = :slab_column_envelope

"One node after the commit level. Adopts any further column growth."
const NODE_SLAB_LOCK = :slab_column_lock

"""
    is_slab_node_key(key::NodeKey) -> Bool

Whether `key` is a fine per-slab node key produced by [`slab_node_key`](@ref).
"""
is_slab_node_key(key::NodeKey) = startswith(String(key), SLAB_NODE_PREFIX)

"""
    slab_node_index(key::NodeKey) -> Union{Int, Nothing}

The 1-based `struc.slabs` index a fine per-slab node owns, or `nothing` when
`key` is not a slab node key. Inverse of [`slab_node_key`](@ref).
"""
function slab_node_index(key::NodeKey)
    is_slab_node_key(key) || return nothing
    return parse(Int, String(key)[(length(SLAB_NODE_PREFIX) + 1):end])
end

"""
    canonical_node_keys() -> Vector{NodeKey}

The full, stable identity vocabulary of the design pipeline, in pipeline order:
prepare sub-steps, the sizing stages, ordinary walls, and capture. Content-stable —
these symbols never depend on stage position, params, or branch taken. The
incremental engine and the invalidation-matrix tests can enumerate the design's
work units from this list. Ordinary walls are listed even when a gravity-only
graph omits that node.
"""
canonical_node_keys() = NodeKey[
    NODE_INITIALIZE, NODE_POPULATE_FRAMING, NODE_ESTIMATE_COLUMNS, NODE_BUILD_ASAP,
    NODE_SLAB_SIZING, NODE_MEMBERS, NODE_FOUNDATIONS, NODE_ORDINARY_WALLS,
    NODE_CAPTURE,
]

# -----------------------------------------------------------------------------
# Per-node provenance for the executed sizing graph
# -----------------------------------------------------------------------------
# `param_slice`  — DesignParameters fields the stage reads (INCLUDING the fields
#                  read by the `sync_asap!` that runs when `needs_sync=true`, since
#                  that sync is part of the node's effect). Complete + conservative:
#                  over-listing only forces extra recompute; under-listing would
#                  allow stale reuse.
# `struc_writes` — BuildingStructure fields the stage mutates. The node OUTPUT
#                  hash is taken over exactly these, so this list gates early
#                  cutoff and must be complete.
# `struc_reads`  — BuildingStructure fields read (documentary).
#
# The param slices are derived by reading the stage closures in
# `build_pipeline` / `design_workflow.jl`:
#   • slab_sizing  — resolve_floor_options(params) (→ :floor, :materials),
#                    size_slabs!(max_iterations, fire_rating, column_opts=:columns),
#                    + sync_asap! (→ :load_combinations — the enveloped/governing
#                    load MAGNITUDE, which sync refreshes on every recompute).
#   • members      — union of both branches: _reconcile_columns! (columns,
#                    materials, geometry_is_centerline, load_combinations) and
#                    _size_beams_columns! (beams, columns, materials,
#                    max_iterations, fire_rating, fire_protection) + sync_asap!.
#   • foundations  — _size_foundations!(params.foundation_options), after
#                    ordinary walls so a thickness jump is already solved.
#
# NOTE — `:pattern_loading` is intentionally ABSENT from these slices: it is a
# prepare-affecting, build-time structural decision (it selects which load objects
# `to_asap!` populates, which `sync_asap!` cannot retrofit), so it lives in
# `PREPARE_AFFECTING_FIELDS` and the scheduler guard forces a fresh engine. See
# the audit comment on `PREPARE_AFFECTING_FIELDS` in scheduler.jl. `:load_combinations`
# stays here because it only sets the load MAGNITUDE and IS refreshed by sync.

"""
    PIPELINE_PROVENANCE :: Dict{NodeKey, NamedTuple}

Provenance for the executed sizing nodes, keyed by canonical [`NodeKey`](@ref).
Each entry is `(param_slice, reads, writes, code_version)`. `build_design_graph`
looks up this table to stamp provenance onto every `StageNode` it emits.
"""
const PIPELINE_PROVENANCE = Dict{NodeKey, @NamedTuple{
        param_slice::Vector{Symbol},
        reads::Vector{Symbol},
        writes::Vector{Symbol},
        code_version::Symbol,
    }}(
    NODE_SLAB_SIZING => (
        param_slice  = Symbol[:floor, :materials, :columns, :max_iterations,
                              :fire_rating, :load_combinations,
                              :scoped_floor_overrides],
        reads        = Symbol[:slabs, :cells, :columns, :asap_model],
        writes       = Symbol[:slabs, :columns, :cells, :asap_model],
        code_version = :slab_sizing_v1,
    ),
    NODE_MEMBERS => (
        # `:optimize_for` and `:collinear_grouping` future-proof the documented
        # wiring in analyze/members/utils.jl (size_beams!/size_columns! read
        # `struc.design_parameters.optimize_for` / `.collinear_grouping`). Those
        # reader paths are currently DEAD — `BuildingStructure` has no
        # `design_parameters` field, so `hasproperty(...)` is false — but the
        # docstring at members/utils.jl §size_columns! instructs wiring that field,
        # at which point these become live member-slice inputs. Listing them now is
        # superset-safe (only ever an unnecessary recompute, never a stale reuse).
        # `:member_group_overrides` (Run 4 / Phase B) is a member-slice input: the
        # batched steel-beam stage (`_size_beams_impl!` → `_beam_override_union_and_feasible`)
        # narrows a beam group's feasible set from `params.member_group_overrides`, so a
        # change to that dict must invalidate this node for the incremental engine to
        # honor it (from-scratch == incremental oracle).
        # :beam_I_factor — consumed only at member sizing (size_beams! reads params.beam_I_factor); a change must dirty the members node (from-scratch == incremental oracle). ACI 318-11 §10.10.4.1.
        param_slice  = Symbol[:columns, :beams, :materials, :max_iterations,
                              :fire_rating, :fire_protection, :geometry_is_centerline,
                              :load_combinations, :optimize_for, :collinear_grouping,
                              :member_group_overrides, :beam_I_factor],
        reads        = Symbol[:columns, :beams, :slabs, :asap_model,
                              :frame_section_floors, :frame_floor_demands],
        writes       = Symbol[:columns, :beams, :asap_model],
        # v5: perimeter curtain-wall dead load is on the analysis model, so
        # member forces change at an unchanged GravityLoads.
        code_version = :members_v5,
    ),
    NODE_FOUNDATIONS => (
        param_slice  = Symbol[:foundation_options],
        reads        = Symbol[:supports, :foundations, :columns, :asap_model],
        writes       = Symbol[:supports, :foundations],
        code_version = :foundations_v1,
    ),
    NODE_ORDINARY_WALLS => (
        param_slice  = Symbol[:lateral, :wall_inputs, :materials, :diaphragm_mode,
                              :columns, :beams, :uniform_column_sizing],
        reads        = Symbol[:walls, :wall_mesh, :asap_model, :asap_rigid_links,
                              :columns, :beams, :frame_section_floors,
                              :frame_floor_demands],
        writes       = Symbol[:ordinary_wall_result, :diaphragm_layout,
                              :frame_section_floors, :frame_floor_demands],
        # v5: seismic weight includes the curtain-wall dead load.
        code_version = :ordinary_walls_v5,
    ),
)

"""
    pipeline_provenance(key::NodeKey) -> NamedTuple

Provenance record for a canonical sizing node `key`, or an empty record
(`code_version = :v1`) for keys with no declared provenance.

Fine per-slab node keys ([`is_slab_node_key`](@ref)) inherit `NODE_SLAB_SIZING`'s
record verbatim: the split into per-slab nodes changes only the graph topology
(batch levels), not what a slab node reads or writes.
"""
function pipeline_provenance(key::NodeKey)
    is_slab_node_key(key) && return PIPELINE_PROVENANCE[NODE_SLAB_SIZING]
    return get(PIPELINE_PROVENANCE, key,
               (param_slice = Symbol[], reads = Symbol[],
                writes = Symbol[], code_version = :v1))
end
