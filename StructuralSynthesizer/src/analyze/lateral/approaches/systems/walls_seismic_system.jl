# Walls as the seismic force-resisting system.
#
# Beam end releases come from the material defaults (`default_release`): steel
# and timber gravity framing is pinned, so it is not a moment frame; cast-in-place
# concrete stays monolithic (fixed) and shares lateral load with the walls in the
# whole-building analysis. Column base fixity is unchanged.

"""
    prepare_lateral_model!(struc, ::WallsSeismicSystem) -> struc

Refuse a building with no walls. Releases are left to the material defaults.
"""
function prepare_lateral_model!(struc, ::WallsSeismicSystem)
    isempty(struc.walls) && throw(ArgumentError(
        "WallsSeismicSystem: the building has no walls to be the seismic system."))
    return struc
end

"""Every wall is in the system. No beam or column is."""
seismic_members(struc, ::WallsSeismicSystem) =
    (walls=collect(eachindex(struc.walls)), beams=Int[], columns=Int[])

"""
    system_checks(struc, ::WallsSeismicSystem; seismic_design_category)

ASCE 7-22 §12.12.4 Deformation Compatibility for Seismic Design Categories D
through F (corpus: asce-7-22, PDF page 195). For A, B, or C it does not apply
and nothing is returned. For D, E, or F it throws: the check is not built.
"""
function system_checks(struc, ::WallsSeismicSystem; seismic_design_category::Symbol)
    sdc = _require_sdc(seismic_design_category)
    sdc in (:D, :E, :F) || return Any[]
    throw(ArgumentError(
        "WallsSeismicSystem does not yet check ASCE 7-22 §12.12.4 " *
        "(corpus: asce-7-22, PDF page 195). For Seismic Design Category D, E, " *
        "or F, a component outside the seismic force-resisting system must be " *
        "designed for its gravity effects and for the forces from the Design " *
        "Earthquake Displacements (δDE) of §12.8.6. A reinforced concrete frame " *
        "member outside the system follows ACI 318 §18.14."))
end
