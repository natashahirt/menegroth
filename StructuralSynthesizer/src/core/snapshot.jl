# =============================================================================
# Snapshot / Restore for Parametric Studies
# =============================================================================

"""
    snapshot!(struc::BuildingStructure)

Capture the current mutable state of `struc` for later restoration.

Call this **after** `initialize!` + `estimate_column_sizes!` + `to_asap!` but
**before** any sizing mutations. The snapshot is stored on `struc._snapshot`.

See also: [`restore!`](@ref), [`DesignSnapshot`](@ref)
"""
function snapshot!(struc::BuildingStructure{T, A, P}) where {T, A, P}
    struc._snapshot = DesignSnapshot{T, P}(
        Union{T, Nothing}[col.c1 for col in struc.columns],
        Union{T, Nothing}[col.c2 for col in struc.columns],
        Union{AbstractSection, Nothing}[col.base.section for col in struc.columns],
        Union{AbstractSection, Nothing}[beam.base.section for beam in struc.beams],
        P[cell.self_weight for cell in struc.cells],
        P[cell.live_load for cell in struc.cells],
    )
    return struc
end

"""
    restore!(struc::BuildingStructure)

Revert mutable fields to the state captured by the last `snapshot!` call.

This restores column dimensions/sections, beam sections, and cell loads
so the structure is ready for another design run without re-initialization.

See also: [`snapshot!`](@ref), [`sync_asap!`](@ref)
"""
function restore!(struc::BuildingStructure)
    snap = struc._snapshot
    isnothing(snap) && error("No snapshot — call snapshot!(struc) after initialization")
    
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
    
    # Clear slab design details (stale after restore)
    for slab in struc.slabs
        hasproperty(slab, :design_details) && (slab.design_details = nothing)
    end
    
    return struc
end

"""
    has_snapshot(struc::BuildingStructure) -> Bool

Check whether a design snapshot exists.
"""
has_snapshot(struc::BuildingStructure) = !isnothing(struc._snapshot)
