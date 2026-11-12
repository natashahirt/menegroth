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
through F (corpus: asce-7-22, PDF page 195). For A, B, or C it does not apply.
For D, E, or F the induced moments are not calculated, so the gravity frame is
detailed to ACI 318-19 §18.14.3.3. Nothing is returned.
"""
function system_checks(struc, ::WallsSeismicSystem; seismic_design_category::Symbol)
    _require_sdc(seismic_design_category)
    return Any[]
end
