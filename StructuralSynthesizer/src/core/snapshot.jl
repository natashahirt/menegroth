# =============================================================================
# Snapshot / Restore for Parametric Studies
# =============================================================================

"""
    snapshot!(struc::BuildingStructure, key::Symbol = :prepare)

Capture the current mutable state of `struc` under `key`.

The default key `:prepare` is used by `prepare!` to save the pristine
post-initialization state.  Use other keys to save intermediate states
(e.g. `:post_slab` after slab sizing).

# Examples
```julia
prepare!(struc, params)          # automatically calls snapshot!(struc, :prepare)
size_slabs!(struc; ...)
snapshot!(struc, :post_slab)     # save post-slab state
reconcile_columns!(struc, ...)
snapshot!(struc, :post_columns)  # save post-column state

restore!(struc, :post_slab)     # back to post-slab state (re-run columns)
restore!(struc)                 # back to pristine prepare state
```

See also: [`restore!`](@ref), [`DesignSnapshot`](@ref), [`has_snapshot`](@ref)
"""
function snapshot!(struc::BuildingStructure{T, A, P}, key::Symbol = :prepare) where {T, A, P}
    slab_snaps = SlabSnapshot[
        SlabSnapshot(slab.result, slab.design_details, slab.volumes, slab.drop_panel)
        for slab in struc.slabs
    ]
    struc._snapshots[key] = DesignSnapshot{T, P}(
        Union{T, Nothing}[col.c1 for col in struc.columns],
        Union{T, Nothing}[col.c2 for col in struc.columns],
        Union{AbstractSection, Nothing}[col.base.section for col in struc.columns],
        Union{AbstractSection, Nothing}[beam.base.section for beam in struc.beams],
        P[cell.self_weight for cell in struc.cells],
        P[cell.live_load for cell in struc.cells],
        slab_snaps,
    )
    return struc
end

"""
    restore!(struc::BuildingStructure, key::Symbol = :prepare; geometry_is_centerline=false)

Revert mutable fields to the state captured by `snapshot!(struc, key)`.

Restores column dimensions/sections, beam sections, cell loads, and slab
results/design details so the structure is ready for another design run
without re-initialization.

`geometry_is_centerline` is forwarded to `update_structural_offsets!` so
restored column dimensions produce the correct structural centerline offsets.

See also: [`snapshot!`](@ref), [`sync_asap!`](@ref)
"""
function restore!(struc::BuildingStructure, key::Symbol = :prepare;
                   geometry_is_centerline::Bool = false)
    snap = get(struc._snapshots, key, nothing)
    isnothing(snap) && error("No snapshot for key :$key — call snapshot!(struc, :$key) first")

    # Columns
    for (i, col) in enumerate(struc.columns)
        col.c1 = snap.column_c1[i]
        col.c2 = snap.column_c2[i]
        col.base.section = snap.column_sections[i]
    end

    # Beams
    for (i, beam) in enumerate(struc.beams)
        beam.base.section = snap.beam_sections[i]
    end

    # Cells
    for (i, cell) in enumerate(struc.cells)
        cell.self_weight = snap.cell_self_weights[i]
        cell.live_load = snap.cell_live_loads[i]
    end

    # Slabs
    for (i, slab) in enumerate(struc.slabs)
        ss = snap.slab_snapshots[i]
        slab.result = ss.result
        slab.volumes = ss.volumes
        slab.drop_panel = ss.drop_panel
        # The whole `size_flat_plate!` NamedTuple, including
        # method_requested, method_used, and method_fallback_reasons.
        # `_populate_slab_results!` copies those onto SlabDesignResult;
        # restoring the tuple keeps the FEA-fallback notice on the slab.
        hasproperty(slab, :design_details) && (slab.design_details = ss.design_details)
    end

    # Recompute structural offsets for restored column dimensions
    !isnothing(struc.skeleton.geometry) && update_structural_offsets!(struc; input_is_centerline=geometry_is_centerline)

    return struc
end

"""
    has_snapshot(struc::BuildingStructure, key::Symbol = :prepare) -> Bool

Check whether a design snapshot exists for `key`.
"""
has_snapshot(struc::BuildingStructure, key::Symbol = :prepare) = haskey(struc._snapshots, key)

"""
    delete_snapshot!(struc::BuildingStructure, key::Symbol)

Remove a named snapshot to free memory.
"""
function delete_snapshot!(struc::BuildingStructure, key::Symbol)
    delete!(struc._snapshots, key)
    return struc
end

"""
    snapshot_keys(struc::BuildingStructure) -> Vector{Symbol}

Return all snapshot keys currently stored.
"""
snapshot_keys(struc::BuildingStructure) = collect(keys(struc._snapshots))

# =============================================================================
# Per-node whole-struc snapshots (Run 2 — incremental engine)
# =============================================================================
#
# `snapshot!`/`restore!` above capture the *design-mutable* fields (member sizes,
# cell loads, slab results) but leave the Asap analysis model stale — that is
# correct for `design_building`, which rebuilds the model from scratch on the
# next call. The incremental engine, however, must restore a clean node's
# post-state *exactly* — including the solved Asap model that downstream nodes
# read (`el.forces`, reactions) — so a member/cell/slab-only capture is not
# enough.
#
# Run 2 therefore captures a WHOLE-STRUC snapshot per node (memory-heavy is
# acceptable per the plan; Run 3 refines to fine/per-group state). The capture is
# an exact `deepcopy` so the restored state is byte-for-byte what a recompute
# would have produced — with ONE deliberate exception: the Asap model's
# `_factorization` (a SuiteSparse CHOLMOD factor holding a C pointer) and
# `_elemental_loads` are recomputable caches that must NOT be deepcopied. They
# are nulled on the copy and recomputed lazily on the next `update!`/`solve!`
# after restore, which the pipeline always performs before reading fresh forces.
#
# These are keyed by `NodeKey` (a `Symbol`) in a caller-owned store (the
# incremental engine's memo) rather than on `struc`, so the machinery is
# callable/observable from outside without growing the `BuildingStructure`
# struct.
#
# RUN 6 (warm-state) INVARIANT: the CHOLMOD factorization deliberately nulled
# here must NEVER re-enter these snapshots — it holds a non-copyable C pointer and
# is a recomputable cache. The live factor lives ONLY on the working
# `engine.struc.asap_model`, where `sync_asap!(...; loads_only=true)` may reuse it
# for a provably-K-unchanged loads-only re-solve. Any cross-run warm artifacts the
# engine reuses (e.g. the shared read-only column P-M cache) are held in the
# SEPARATE `engine.warm_memo` (`NodeWarmState`), not in this design-state snapshot,
# so this byte-identity capture/restore path is unchanged.

"""
    capture_node_state(struc::BuildingStructure) -> BuildingStructure

Capture an exact, independent copy of `struc`'s full state for later restoration
as a per-node snapshot. The returned structure is a `deepcopy` of `struc` with
the Asap model's recomputable caches (`_factorization`, `_elemental_loads`)
cleared — see the module note above for why the CHOLMOD factorization is never
deepcopied. The live `struc` is left unchanged (its caches are restored before
returning).
"""
function capture_node_state(struc::BuildingStructure)
    model = struc.asap_model
    saved_fact = model._factorization
    saved_eloads = model._elemental_loads
    # Null the recomputable caches on the LIVE model only for the duration of the
    # copy, so `deepcopy` never touches the CHOLMOD C pointer, then restore them.
    model._factorization = nothing
    model._elemental_loads = nothing
    snap = try
        deepcopy(struc)
    finally
        model._factorization = saved_fact
        model._elemental_loads = saved_eloads
    end
    return snap
end

"""
    restore_node_state(state::BuildingStructure) -> BuildingStructure

Produce a fresh, independent working structure from a snapshot previously taken
by [`capture_node_state`](@ref). Returns a `deepcopy` so the stored snapshot is
never aliased by (and therefore never corrupted by) subsequent in-place node
mutations. The Asap model's factorization is `nothing` on the result and is
recomputed on the next `update!`/`solve!`.
"""
restore_node_state(state::BuildingStructure) = deepcopy(state)

"""
    snapshot_node!(store::AbstractDict, key::Symbol, struc::BuildingStructure) -> store

Capture `struc`'s post-node state (see [`capture_node_state`](@ref)) into
`store[key]`. `store` is any dict keyed by a node key (`NodeKey === Symbol`; the
incremental engine's memo). Returns `store`. (Annotated `Symbol` rather than
`NodeKey` because this file loads before the `NodeKey` alias is defined.)
"""
function snapshot_node!(store::AbstractDict, key::Symbol, struc::BuildingStructure)
    store[key] = capture_node_state(struc)
    return store
end

"""
    restore_node(store::AbstractDict, key::Symbol) -> BuildingStructure

Return a fresh working structure restored from the per-node snapshot stored at
`store[key]` (see [`restore_node_state`](@ref)). Throws `KeyError` if absent.
"""
restore_node(store::AbstractDict, key::Symbol) = restore_node_state(store[key])

# =============================================================================
# Partial per-slab restore (Run 3 — fine per-slab nodes)
# =============================================================================
#
# `restore_node_state` above replaces the WHOLE working structure — the correct,
# clobber-free choice when every node in a topological level is clean (all the
# level's whole-struc snapshots are byte-identical, taken after the same level
# barrier `sync_asap!`, so restoring any one restores the shared post-level state
# INCLUDING the global Asap analysis model). The incremental scheduler uses that
# path for an all-clean slab level.
#
# `restore_slab_node_writes!` is the fine-grained counterpart used ONLY when a
# level holds BOTH clean and dirty per-slab nodes: it overlays a single clean
# slab node's DECLARED PER-GROUP OUTPUTS onto the live structure without touching
# the dirty siblings' fresh work or the global model. The clobbering hazard is
# solved by two invariants:
#
#   1. A fine per-slab node's owned outputs are DISJOINT per slab index —
#      `slab[idx].result/design_details/volumes/drop_panel` and the supported
#      cells' `self_weight`/`live_load`. Two different slab nodes never write the
#      same slab or (within a `slab_parallel_batches` batch) the same cell.
#   2. Supporting columns are shared across slabs, but column growth is MONOTONIC
#      (`col.c1 = max(col.c1, c_new)`, never-shrink — analyze/.../column_growth.jl),
#      so applying a clean slab's supporting-column sizes after the dirty siblings
#      already grew them can only RAISE to the recorded max — order-independent —
#      and we therefore take `max` here rather than blindly overwriting.
#
# GENUINELY-GLOBAL STATE THAT STAYS WHOLE-STRUC: the solved Asap model
# (`struc.asap_model`: element sections/forces, `u`, reactions) is NOT restored
# here — it cannot be isolated to one slab. The scheduler reconciles it once per
# level with the single barrier `sync_asap!` (which rebuilds the model from ALL
# current slab states, clean-restored + dirty-recomputed), exactly as the coarse
# stage did. Structural offsets are likewise recomputed globally by that sync's
# upstream (`update_structural_offsets!`), so they are not touched per slab here.
#
# ORDERING INVARIANT (documented + relied upon by the scheduler): in a mixed
# level, dirty nodes are RUN FIRST on the live struc, THEN clean nodes overlay
# their owned writes (max-merged for shared columns), THEN the single barrier
# `sync_asap!` reconciles the global model from the combined slab state. This
# yields the same final state regardless of intra-level node order.
#
# NOTE (reachability): a slab level is never mixed clean/dirty, now ENFORCED (not
# merely assumed) by TWO independent mechanisms: (1) under the global-parameter
# model a slab-affecting parameter dirties every slab node at once and a non-slab
# parameter dirties none (all-or-nothing by params); and (2) the partial-slab-
# target guard in `run_target!` (scheduler.jl) REJECTS any run whose target
# closure would memoize only a strict subset of the slab roots, so the memo can
# never hold a partial slab level either. This partial path is therefore
# UNREACHABLE end-to-end (a defensive check in `run_target!` fails loud if it ever
# is), and the merge helpers are covered instead by DIRECT unit tests
# (`StructuralSynthesizer/test/design_graph/test_design_graph_incremental.jl`, the
# "partial per-slab restore (Findings 3 + 4)" testset: overlay + monotonic
# max-merge + no-aliasing/no-sibling-clobber, plus `_adopt_larger_column!`'s
# dimensional-tie non-downgrade section adoption). True per-slab INDEPENDENT
# variation (dirtying exactly one sibling) needs per-group override params
# (Option A) and is deferred pending user sign-off; see NOTES. Option A will
# exercise this path end-to-end.

"""
    restore_slab_node_writes!(dst, src, slab_idx, supporting_columns) -> dst

Overlay the fine per-slab node for `slab_idx`'s DECLARED per-group outputs from
snapshot `src` onto the live structure `dst`, in place, without disturbing other
slabs, other cells, or the global Asap model (see the module note above for the
clobbering invariants and the whole-struc fallback for global state).

Restores, for `slab_idx`: `slab.result`, `slab.design_details`, `slab.volumes`,
`slab.drop_panel`; the supported cells' `self_weight`/`live_load`; and — max-merged
to honor monotonic column growth — the `supporting_columns`' `c1`/`c2`/`shape`/
section/volumes. `supporting_columns` are the 1-based `dst.columns` indices whose
tributary overlaps this slab (see `_slab_supporting_columns`).
"""
function restore_slab_node_writes!(dst::BuildingStructure, src::BuildingStructure,
                                   slab_idx::Int, supporting_columns)
    d_slab = dst.slabs[slab_idx]
    s_slab = src.slabs[slab_idx]

    d_slab.result = s_slab.result
    d_slab.volumes = s_slab.volumes
    d_slab.drop_panel = s_slab.drop_panel
    # Whole NamedTuple, so method_requested / method_used /
    # method_fallback_reasons survive a per-slab restore.
    hasproperty(d_slab, :design_details) && (d_slab.design_details = s_slab.design_details)

    # Supported cells: self_weight/live_load written during slab sizing + sync.
    # These are slab-owned (a cell belongs to exactly one slab), so a plain copy
    # cannot clobber a sibling.
    for ci in s_slab.cell_indices
        (ci >= 1 && ci <= length(dst.cells)) || continue
        dst.cells[ci].self_weight = src.cells[ci].self_weight
        dst.cells[ci].live_load   = src.cells[ci].live_load
    end

    # Supporting columns: shared across slabs, so MAX-MERGE (monotonic growth)
    # rather than overwrite. Only enlarge; adopt the snapshot's larger section.
    for ci in supporting_columns
        (ci >= 1 && ci <= length(dst.columns)) || continue
        dcol = dst.columns[ci]
        scol = src.columns[ci]
        _adopt_larger_column!(dcol, scol)
    end
    return dst
end

"""Longitudinal steel area of an RC column section (`RCColumnSection` /
`RCCircularSection` both expose `As_total`), or `nothing` when the section does
not report one. Used ONLY as a dimensional-TIE non-downgrade proxy — see
[`_adopt_larger_column!`](@ref)."""
_column_section_steel_area(sec) =
    (sec !== nothing && hasproperty(sec, :As_total)) ? sec.As_total : nothing

"""Adopt `scol`'s size onto `dcol` under a NEVER-SHRINK, NEVER-DOWNGRADE,
NEVER-MISMATCHED-SECTION merge (a monotonic-growth merge of two sizings of the
SAME shared column). Sizes are always DEEP-COPIED, never aliased into `scol`.

Cases (P2a):
1. `dcol` uninitialized (`c1`/`c2` is `nothing`) → adopt `scol` wholesale.
2. `scol` DOMINATES `dcol` (`scol.c1 ≥ dcol.c1` AND `scol.c2 ≥ dcol.c2`):
     • strictly larger in ≥1 dim → adopt `scol`'s dims + section + shape +
       volumes (the final dims equal `scol`'s, so `scol`'s section MATCHES them);
     • exact TIE (both dims equal) → dims unchanged; adopt `scol`'s section ONLY
       when it is a provable NON-DOWNGRADE, else KEEP `dcol` (Finding 4, corrected
       — the pre-fix rule downgraded a stronger section to a weaker one on a tie).
3. `dcol` dominates, OR the dims are INCOMPARABLE (e.g. `dst=(10,20)` vs
   `src=(12,18)`, whose component-wise max `(12,20)` matches NEITHER section) →
   keep `dcol`'s dims AND section unchanged. Growing one dim while shrinking the
   other is forbidden (never-shrink), and manufacturing a `(12,20)` footprint that
   no available section matches would create a dims/section MISMATCH, so we keep
   `dcol`'s own consistent `(dims, section)` pair.

Non-downgrade proxy (case 2 tie): at an EQUAL gross section (guaranteed by the
`c1==c1 && c2==c2` tie) and equal concrete, ACI 318-11 §10.3.6.2
`φPn,max = 0.80·φ·[0.85·f'c·(Ag − Ast) + fy·Ast]` is monotonically NON-DECREASING
in the longitudinal steel area `Ast` (because `fy > 0.85·f'c`), and the P-M
capacity is likewise non-decreasing in `Ast` — so the section's reported TOTAL
longitudinal steel area is a valid non-downgrade proxy on a tie. We compare that
reported area directly; NO capacity is recomputed here (the column checker /
`ACIColumnCapacityCache` needs material + demand context not available at this
merge site). When either section does not report a steel area, we conservatively
KEEP `dcol` (cannot prove non-downgrade)."""
function _adopt_larger_column!(dcol, scol)
    (isnothing(scol.c1) || isnothing(scol.c2)) && return dcol

    # Case 1: uninitialized dst → adopt scol wholesale.
    if isnothing(dcol.c1) || isnothing(dcol.c2)
        dcol.c1 = scol.c1
        dcol.c2 = scol.c2
        dcol.shape = scol.shape
        dcol.base.section = scol.base.section
        dcol.base.volumes = deepcopy(scol.base.volumes)
        return dcol
    end

    scol_dominates = scol.c1 >= dcol.c1 && scol.c2 >= dcol.c2
    dims_tie       = scol.c1 == dcol.c1 && scol.c2 == dcol.c2

    if scol_dominates && !dims_tie
        # Case 2 (strict dominance): final dims == scol's dims, so scol's section
        # matches → adopt scol wholesale (footprint-monotonic growth).
        dcol.c1 = scol.c1
        dcol.c2 = scol.c2
        dcol.shape = scol.shape
        dcol.base.section = scol.base.section
        dcol.base.volumes = deepcopy(scol.base.volumes)
    elseif dims_tie
        # Case 2 (tie): dims unchanged; adopt scol's section ONLY on a provable
        # non-downgrade (≥ steel at equal footprint), else keep dcol. Adopting an
        # identical section is a harmless no-op (skipped via the `!==` check).
        if dcol.base.section !== scol.base.section
            a_new = _column_section_steel_area(scol.base.section)
            a_old = _column_section_steel_area(dcol.base.section)
            if a_new !== nothing && a_old !== nothing && a_new >= a_old
                dcol.shape = scol.shape
                dcol.base.section = scol.base.section
                dcol.base.volumes = deepcopy(scol.base.volumes)
            end
        end
    end
    # Case 3 (dcol dominates OR incomparable dims): keep dcol entirely — no shrink,
    # no dims/section mismatch.
    return dcol
end
