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
