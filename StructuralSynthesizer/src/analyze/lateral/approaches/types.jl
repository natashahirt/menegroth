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
and `Cd`. Categories D, E, and F are accepted. The ordinary-wall stage
calculates the moments from δDE and details the gravity frame to ACI 318-19
§18.14.3.2 or §18.14.3.3 from that result.

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

# Dual system vocabulary. `moment_frame` is the frame material + detailing;
# `wall` is the shear-wall/core type. The pair fixes the Table 12.2-1 row.
const _DUAL_MOMENT_FRAMES = (:steel_smf, :composite_smf, :rc_smf,
                             :steel_imf, :composite_imf, :rc_imf)
const _DUAL_WALLS = (:special_rc, :composite_special, :composite_plate, :ordinary_rc)
const _DUAL_ROWS = (:D3, :D8, :D9, :E8)

"""
    _classify_dual_row(moment_frame, wall) -> Symbol

The ASCE 7-22 Table 12.2-1 row for a dual system, from the moment-frame
detailing and the wall type:

- special moment frame + composite plate shear walls → `:D8`
- special moment frame + composite special shear walls → `:D9`
- *concrete* special moment frame + special reinforced concrete shear walls →
  `:D3` (all-concrete dual, §14.2)
- *steel or composite* special moment frame + special RC shear walls → `:D9`:
  a steel frame sharing load with RC walls is a composite system, so it is the
  composite special shear-wall row (§14.3 / AISC 341 Part II), not the concrete
  row D.3
- intermediate moment frame + ordinary RC shear walls → `:E8`

An unrecognized pairing throws; use the `row` override for a combination not
classified here.

# Citation
ASCE 7-22 Table 12.2-1 Sections D and E (corpus: asce-7-22, PDF pages 174–175);
§14.3 and AISC 341 Part II govern steel-plus-RC (composite) systems.
"""
function _classify_dual_row(moment_frame::Symbol, wall::Symbol)
    is_smf = moment_frame in (:steel_smf, :composite_smf, :rc_smf)
    is_imf = moment_frame in (:steel_imf, :composite_imf, :rc_imf)
    if is_smf
        wall === :composite_plate && return :D8
        wall === :composite_special && return :D9
        if wall === :special_rc
            # A concrete SMF + special RC walls is the all-concrete row D.3; a
            # steel/composite SMF + RC walls is a composite system → D.9.
            return moment_frame === :rc_smf ? :D3 : :D9
        end
    elseif is_imf
        wall === :ordinary_rc && return :E8
    end
    throw(ArgumentError(
        "DualSystem: no Table 12.2-1 row is classified for moment_frame " *
        ":$moment_frame with wall :$wall. Supported: a special moment frame " *
        "(:steel_smf/:composite_smf/:rc_smf) with :special_rc, :composite_special, " *
        "or :composite_plate walls, or an intermediate moment frame " *
        "(:*_imf) with :ordinary_rc walls. Pass an explicit `row` to override. " *
        "ASCE 7-22 Table 12.2-1 Sections D–E (corpus: asce-7-22, PDF pages 174-175)."))
end

"""
    DualSystem(; moment_frame, wall, row=nothing) -> DualSystem

A dual seismic system (ASCE 7-22 §12.2.5.1): a moment frame and shear walls (or
a core) share the lateral load in one direction, and the moment frame alone is
detailed and proportioned to resist **at least 25%** of the design seismic
force. Covers Table 12.2-1 Section D (special moment frames) and the Section E
intermediate-moment-frame dual row E.8.

`moment_frame` is the frame material + detailing (`:steel_smf`, `:composite_smf`,
`:rc_smf`, `:steel_imf`, `:composite_imf`, `:rc_imf`); `wall` is the shear-wall /
core type (`:special_rc`, `:composite_special`, `:composite_plate`,
`:ordinary_rc`). The pair fixes the Table 12.2-1 row (see
[`_classify_dual_row`](@ref)); e.g. a steel SMF with an RC special-wall core is
the composite special shear-wall row `:D9`. `R`, `Ω₀`, and `Cd` come from that
row, resolved against the Seismic Design Category by the sizer's
`dual_seismic_system` lookup (which refuses a row that is NP in the SDC — e.g.
the intermediate-frame row `:E8` outside SDC B/C).

`row` overrides the classification with an explicit, validated Table 12.2-1 dual
row (`:D3`, `:D8`, `:D9`, `:E8`).

The ≥25% participation requirement (§12.2.5.1) is enforced by this system's
`system_checks` behavior against the analysis, not at construction.

# Citation
ASCE 7-22 §12.2.5.1 (corpus: asce-7-22, PDF page 177) and Table 12.2-1 Sections
D and E (corpus: asce-7-22, PDF pages 174–175).
"""
struct DualSystem <: LateralSystem
    moment_frame::Symbol
    wall::Symbol
    row::Symbol
    function DualSystem(; moment_frame::Symbol, wall::Symbol,
                        row::Union{Symbol, Nothing}=nothing)
        moment_frame in _DUAL_MOMENT_FRAMES || throw(ArgumentError(
            "DualSystem: moment_frame :$moment_frame is not recognized. Use one " *
            "of $(_DUAL_MOMENT_FRAMES)."))
        wall in _DUAL_WALLS || throw(ArgumentError(
            "DualSystem: wall :$wall is not recognized. Use one of $(_DUAL_WALLS)."))
        classified = _classify_dual_row(moment_frame, wall)
        if row === nothing
            resolved = classified
        else
            row in _DUAL_ROWS || throw(ArgumentError(
                "DualSystem: override row :$row is not a Table 12.2-1 dual row " *
                "$(_DUAL_ROWS). ASCE 7-22 Table 12.2-1 Sections D–E " *
                "(corpus: asce-7-22, PDF pages 174-175)."))
            resolved = row
        end
        return new(moment_frame, wall, resolved)
    end
end

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
    a isa DualSystem && return a.row === b.row &&
        a.moment_frame === b.moment_frame && a.wall === b.wall
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
