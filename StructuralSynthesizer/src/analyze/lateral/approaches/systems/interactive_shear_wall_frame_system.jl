# Table 12.2-1 row F. The 75% and 25% checks run in the ordinary-wall stage,
# because they need the story shears. This file only says which members are
# in the system and which categories still have no deformation check.

"""
    prepare_lateral_model!(struc, ::InteractiveShearWallFrameSystem) -> struc

Refuse a building with no walls or no beams. Releases stay on the material
defaults, so cast-in-place concrete remains a moment frame.
"""
function prepare_lateral_model!(struc, ::InteractiveShearWallFrameSystem)
    isempty(struc.walls) && throw(ArgumentError(
        "InteractiveShearWallFrameSystem: the building has no shear walls. " *
        "Table 12.2-1 row F is ordinary reinforced concrete shear walls and " *
        "ordinary reinforced concrete moment frames (corpus: asce-7-22, PDF page 175)."))
    isempty(struc.beams) && throw(ArgumentError(
        "InteractiveShearWallFrameSystem: the building has no beams. A flat " *
        "plate is not modeled as a moment frame, so row F is not checked."))
    return struc
end

"""Walls, beams, and columns are all in the seismic force-resisting system."""
seismic_members(struc, ::InteractiveShearWallFrameSystem) =
    (walls=collect(eachindex(struc.walls)),
     beams=collect(eachindex(struc.beams)),
     columns=collect(eachindex(struc.columns)))

"""
    system_checks(struc, ::InteractiveShearWallFrameSystem; seismic_design_category)

Same deformation-compatibility gate as [`WallsSeismicSystem`](@ref). Row F is
NP in Categories D, E, and F, so the table lookup refuses those before this
hook. The hook still refuses them if it is called on its own.

# Citation
ASCE 7-22 §12.12.4 (corpus: asce-7-22, PDF page 195).
"""
function system_checks(struc, ::InteractiveShearWallFrameSystem; seismic_design_category::Symbol)
    sdc = _require_sdc(seismic_design_category)
    sdc in (:D, :E, :F) || return Any[]
    throw(ArgumentError(
        "InteractiveShearWallFrameSystem does not yet check ASCE 7-22 §12.12.4 " *
        "(corpus: asce-7-22, PDF page 195). Table 12.2-1 row F is NP in " *
        "Seismic Design Category D, E, and F (PDF page 175)."))
end

"""Table 12.2-1 row carried by a lateral system the ordinary-wall stage accepts."""
table_12_2_1_row(system::WallsSeismicSystem) = system.row
table_12_2_1_row(::InteractiveShearWallFrameSystem) = :F
