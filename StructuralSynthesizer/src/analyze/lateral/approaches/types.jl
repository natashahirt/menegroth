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

Walls are the seismic force-resisting system. `row` is Table 12.2-1 `:A1` or
`:A3` (bearing wall, special or ordinary) or `:B4` or `:B6` (building frame,
special or ordinary). There is no default: the rows do not carry the same `R`
and `Cd`. Categories D, E, and F are accepted. Induced moments are not
calculated, so the gravity frame is detailed to ACI 318-19 §18.14.3.3.

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
        row in (:A1, :A3, :B4, :B6) || throw(ArgumentError(
            "WallsSeismicSystem: :$row is not a walls-only row of Table 12.2-1. " *
            "Use :A1 or :A3 (bearing wall, special or ordinary reinforced concrete " *
            "shear walls) or :B4 or :B6 (building frame, special or ordinary). " *
            ":F is InteractiveShearWallFrameSystem. ASCE 7-22 Table 12.2-1 " *
            "(corpus: asce-7-22, PDF page 173)."))
        return new(row)
    end
end

WallsSeismicSystem() = throw(ArgumentError(
    "WallsSeismicSystem needs a Table 12.2-1 row, :A1, :A3, :B4, or :B6. " *
    "There is no default. ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF page 173)."))

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

"""True when two systems are the same Table 12.2-1 choice."""
function _systems_agree(a::LateralSystem, b::LateralSystem)
    typeof(a) === typeof(b) || return false
    a isa WallsSeismicSystem && return a.row === b.row
    return true
end

"""
    LateralDesign(; system, assignment, plan_axis=(1.0, 0.0))
    LateralDesign(; system_x, system_y, assignment, plan_axis=(1.0, 0.0))

One demand assignment, and the seismic system in each horizontal direction.

`system` puts the same system on both axes. `system_x` and `system_y` are
the two axes when they differ. `.system` is the shared system, and throws
when the axes differ.

`plan_axis` is the first principal plan axis of the seismic force-resisting
system, as a plan vector. It is normalized here. The second axis is that
vector turned 90° counterclockwise. "X" and "Y" in the lateral stage mean
these two axes. The default is global X and Y. A rotated building passes its
own axis so the ELF forces, accidental eccentricity, and drift are measured
along the building.

# Citation
ASCE 7-22 §12.2.2 (corpus: asce-7-22, PDF page 176): different seismic
force-resisting systems are permitted along the two orthogonal axes, and
the respective R, Cd, and Ω0 apply to each, including that row's limits.
Table 12.3-1 Type 5 (PDF page 180) measures nonparallel elements against
"the major orthogonal axes of the seismic force-resisting system".
"""
struct LateralDesign{SX<:LateralSystem, SY<:LateralSystem, A<:DemandAssignment}
    system_x::SX
    system_y::SY
    assignment::A
    "Unit vector of the first principal plan axis."
    plan_axis::NTuple{2, Float64}
end

function LateralDesign(; system::Union{LateralSystem, Nothing}=nothing,
                       system_x::Union{LateralSystem, Nothing}=nothing,
                       system_y::Union{LateralSystem, Nothing}=nothing,
                       assignment::DemandAssignment,
                       plan_axis::Tuple{Real, Real}=(1.0, 0.0))
    axis = unit_plan_axis(plan_axis)
    if system !== nothing
        (system_x === nothing && system_y === nothing) || throw(ArgumentError(
            "LateralDesign: pass system, or system_x and system_y. Not both."))
        return LateralDesign(system, system, assignment, axis)
    end
    (system_x === nothing || system_y === nothing) && throw(ArgumentError(
        "LateralDesign: system_x and system_y are both required when system is " *
        "omitted. ASCE 7-22 §12.2.2 (corpus: asce-7-22, PDF page 176)."))
    _refuse_bearing_and_building_frame(system_x, system_y)
    return LateralDesign(system_x, system_y, assignment, axis)
end

"""
    unit_plan_axis(v) -> NTuple{2, Float64}

`v` normalized. A zero or non-finite vector throws.
"""
function unit_plan_axis(v::Tuple{Real, Real})
    x, y = Float64(v[1]), Float64(v[2])
    n = hypot(x, y)
    (isfinite(n) && n > 1e-12) || throw(ArgumentError(
        "plan axis must be a nonzero finite plan vector; got $v."))
    return (x / n, y / n)
end

"""
    plan_axes(axis) -> (e1, e2)

The two principal plan axes. `e2` is `e1` turned 90° counterclockwise, so
`(e1, e2, z)` is right-handed and a positive torsional moment about `z`
has the same sign it has in global axes.
"""
function plan_axes(axis::NTuple{2, Float64})
    e1 = unit_plan_axis(axis)
    return e1, (-e1[2], e1[1])
end

"""Unit vector of `:x` (first axis) or `:y` (second axis)."""
function plan_axis_vector(axis::NTuple{2, Float64}, direction::Symbol)
    e1, e2 = plan_axes(axis)
    direction === :x && return e1
    direction === :y && return e2
    throw(ArgumentError("plan direction must be :x or :y, got :$direction."))
end

"""
A bearing-wall row and a building-frame row are two statements about gravity.
One building does not carry both. `:A1` and `:A3` are bearing walls. `:B4`
and `:B6` are building frames. Two bearing rows, or two building-frame rows,
may be the two directions.
"""
function _refuse_bearing_and_building_frame(x::LateralSystem, y::LateralSystem)
    rows = Symbol[]
    x isa WallsSeismicSystem && push!(rows, x.row)
    y isa WallsSeismicSystem && push!(rows, y.row)
    bearing = (:A1, :A3)
    frame = (:B4, :B6)
    (any(r -> r in bearing, rows) && any(r -> r in frame, rows)) || return nothing
    throw(ArgumentError(
        "LateralDesign: a bearing-wall row (:A1 or :A3) and a building-frame " *
        "row (:B4 or :B6) are different statements about which elements carry " *
        "the vertical load, so they are not the two directions of one building. " *
        "ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF page 173) and C12.2.1 " *
        "(PDF page 708)."))
end

function Base.getproperty(design::LateralDesign, name::Symbol)
    name === :system || return getfield(design, name)
    x = getfield(design, :system_x)
    y = getfield(design, :system_y)
    _systems_agree(x, y) && return x
    throw(ArgumentError(
        "LateralDesign.system: the X and Y systems differ. Read system_x and " *
        "system_y. ASCE 7-22 §12.2.2 (corpus: asce-7-22, PDF page 176)."))
end
