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
