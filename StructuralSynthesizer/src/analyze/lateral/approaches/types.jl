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
    WallsSeismicSystem(row) -> WallsSeismicSystem

Walls are the seismic force-resisting system. `row` is Table 12.2-1 `:A3`
(bearing wall) or `:B6` (building frame). There is no default: the two rows
do not carry the same `R` and `Cd`.

A row that includes a moment frame is not this type. `:F` is
[`InteractiveShearWallFrameSystem`](@ref). `:C7` and `:E8` are not ordinary-wall
systems here.

Releases stay on the material defaults. Concrete framing remains monolithic in
the analysis model. This type does not treat those beams as the seismic system.

# Citation
ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF page 173).
"""
struct WallsSeismicSystem <: LateralSystem
    row::Symbol
    function WallsSeismicSystem(row::Symbol)
        row in (:A3, :B6) || throw(ArgumentError(
            "WallsSeismicSystem: :$row is not a walls-only row of Table 12.2-1. " *
            "Use :A3 (bearing wall, ordinary reinforced concrete shear walls) or " *
            ":B6 (building frame, ordinary reinforced concrete shear walls). " *
            ":F is InteractiveShearWallFrameSystem. ASCE 7-22 Table 12.2-1 " *
            "(corpus: asce-7-22, PDF page 173)."))
        return new(row)
    end
end

WallsSeismicSystem() = throw(ArgumentError(
    "WallsSeismicSystem needs a Table 12.2-1 row, :A3 or :B6. There is no default. " *
    "ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF page 173)."))

"""
Shear wall–frame interactive system, Table 12.2-1 row F.

Ordinary reinforced concrete moment frames and ordinary reinforced concrete
shear walls. The row is fixed: `R`, `Ω0`, and `Cd` come from that one row.
§12.2.5.8 is checked by the ordinary-wall stage, not by this type.

# Citation
ASCE 7-22 Table 12.2-1 row F (corpus: asce-7-22, PDF page 175) and §12.2.5.8
(PDF page 179).
"""
struct InteractiveShearWallFrameSystem <: LateralSystem end

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
