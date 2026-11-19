# =============================================================================
# Design Snapshot — lightweight state capture for parametric studies
# =============================================================================
#
# During design, several BuildingStructure fields are mutated:
#   - Column c1, c2, section
#   - Beam section
#   - Cell self_weight, live_load
#   - Slab result, design_details, volumes, drop_panel
#
# DesignSnapshot captures this mutable state so it can be restored between
# parametric runs, avoiding expensive deep copies or full re-initializations.
#
# Named snapshots allow saving state at multiple pipeline stages:
#   snapshot!(struc)                  # default :prepare key
#   snapshot!(struc, :post_slab)      # after slab sizing
#   restore!(struc)                   # restore :prepare
#   restore!(struc, :post_slab)       # restore post-slab state
# =============================================================================

"""
    SlabSnapshot

Captured slab mutable state: result, design details, volumes, drop panel.
"""
struct SlabSnapshot
    result::AbstractFloorResult
    design_details::Union{Nothing, NamedTuple}
    volumes::MaterialVolumes
    drop_panel::Union{Nothing, DropPanelGeometry}
end

"""
    DesignSnapshot{T, P}

Lightweight capture of mutable `BuildingStructure` fields that change during
design.

Named snapshots are stored in `struc._snapshots::Dict{Symbol, DesignSnapshot}`
via `snapshot!(struc, key)`.  Restored via `restore!(struc, key)`.

# Captured fields
- Column dimensions (`c1`, `c2`) and sections
- Beam sections
- Cell self-weights and live loads
- Slab results, design details, volumes, and drop panels
- Stage diagnostics, row F section floors, and the demand rows stored with them
"""
struct DesignSnapshot{T, P}
    # ── Members ──
    column_c1::Vector{Union{T, Nothing}}
    column_c2::Vector{Union{T, Nothing}}
    column_sections::Vector{Union{AbstractSection, Nothing}}
    beam_sections::Vector{Union{AbstractSection, Nothing}}
    # ── Cells ──
    cell_self_weights::Vector{P}
    cell_live_loads::Vector{P}
    # ── Slabs ──
    slab_snapshots::Vector{SlabSnapshot}
    # ── Stage outcomes ──
    stage_diagnostics::Dict{Symbol, String}
    frame_section_floors::Dict{UInt64, Any}
    frame_floor_demands::Dict{UInt64, Vector{Tuple{String, Any}}}
end
