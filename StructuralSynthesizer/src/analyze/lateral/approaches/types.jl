# Lateral design vocabulary.
#
# Two independent choices:
#
#   LateralSystem     what resists lateral load, and how it is connected and
#                     classified (walls as the seismic system, outriggers, ...)
#   DemandAssignment  how lateral force reaches those members (one model by
#                     stiffness, or a stated share given to the walls alone)
#
# `LateralDesign` pairs one of each and is the `DesignParameters.lateral` field.
# Only types live here, so `DesignParameters` can name them. Behavior is in
# `interface.jl` (the hooks) and one file per type under `systems/` and
# `assignment/`. A type with no methods refuses at the first hook it lacks.

"""What resists lateral load. Behavior: `prepare_lateral_model!`, `seismic_members`, `system_checks`."""
abstract type LateralSystem end

"""How lateral force reaches members. Behavior: `assign_lateral_demands`."""
abstract type DemandAssignment end

"""
Walls are the seismic force-resisting system. Column-to-column girders are
modeled without moment connections so the frame is not a moment frame.
"""
struct WallsSeismicSystem <: LateralSystem end

"""Core, outrigger or belt truss, and perimeter columns. Not implemented."""
struct OutriggerSystem <: LateralSystem end

"""One model of the whole building. Force follows stiffness."""
struct BuildingUnit <: DemandAssignment end

"""
Walls sized alone for `share` of the lateral load, for example `0.5`. Stored,
never defaulted. Not implemented.
"""
struct IsolatedWallShare <: DemandAssignment
    share::Float64
    function IsolatedWallShare(share::Real)
        s = Float64(share)
        0 < s <= 1 || throw(ArgumentError(
            "IsolatedWallShare: the wall share must be between 0 and 1, got $s."))
        return new(s)
    end
end

"""
    LateralDesign(; system, assignment)

One lateral system and one demand assignment. Both are required.
"""
struct LateralDesign{S<:LateralSystem, A<:DemandAssignment}
    system::S
    assignment::A
end

LateralDesign(; system::LateralSystem, assignment::DemandAssignment) =
    LateralDesign(system, assignment)
