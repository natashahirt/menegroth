# Hooks every lateral system and demand assignment must provide.
#
# The defaults refuse and name the hook, so a partly built approach stops at
# the step it lacks. Approaches call the wall and member building blocks
# (cuts, combinations, checkers). The building blocks never call an approach.

"""
    prepare_lateral_model!(struc, system) -> struc

Set what the analysis model needs for `system` (releases, which members are in
the model). Runs before `to_asap!`.
"""
prepare_lateral_model!(struc, system::LateralSystem) = _missing_hook(system, :prepare_lateral_model!)

"""
    seismic_members(struc, system) -> NamedTuple

Indices of the members in the seismic force-resisting system:
`(walls, beams, columns)`.
"""
seismic_members(struc, system::LateralSystem) = _missing_hook(system, :seismic_members)

"""
    system_checks(struc, system; seismic_design_category) -> Vector

Checks that belong to the system rather than to one member, such as
deformation compatibility. Throws for a check that applies but is not built.
"""
system_checks(struc, system::LateralSystem; seismic_design_category::Symbol) =
    _missing_hook(system, :system_checks)

"""
    assign_lateral_demands(assignment, wall, pier, u) -> WallAction

Lateral action on one pier from the displacement `u` of one lateral case.
"""
assign_lateral_demands(assignment::DemandAssignment, wall, pier, u) =
    _missing_hook(assignment, :assign_lateral_demands)

function _missing_hook(approach, hook::Symbol)
    name = nameof(typeof(approach))
    extra = approach isa IsolatedWallShare ? " (share $(approach.share))" : ""
    throw(ArgumentError(
        "$name$extra does not implement `$hook`. It is a socket; selecting it " *
        "does not fall back to another approach."))
end

const _SEISMIC_DESIGN_CATEGORIES = (:A, :B, :C, :D, :E, :F)

function _require_sdc(sdc::Symbol)
    sdc in _SEISMIC_DESIGN_CATEGORIES || throw(ArgumentError(
        "seismic_design_category must be one of $(_SEISMIC_DESIGN_CATEGORIES), got :$sdc."))
    return sdc
end
