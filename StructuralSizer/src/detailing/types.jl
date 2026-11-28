# ==============================================================================
# Placed bars: groups of identical bars, member details, takeoff, schedule
# ==============================================================================
#
# A member detail is a list of bar groups. Each group is `count` identical bars
# of one shape. Mass and carbon are a formula over the group, so a slab with
# thousands of bars is a few dozen groups. `path` is the bar centerline in the
# member's elevation plane for drawings; it does not enter any quantity.
# ==============================================================================

const _M = typeof(1.0u"m")

"""
    BarGroup

`count` identical bars of one shape.

- `mark`: schedule mark, unique within the member (`"T1"`, `"S1"`, …).
- `role`: `:top`, `:bottom`, `:integrity`, `:transfer`, `:stirrup`, `:tie`,
  `:crosstie`, `:spiral`, `:longitudinal`, `:dowel`, or `:hanger`.
- `direction`: `:along` (member axis), `:primary`, `:secondary`, `:long`,
  `:short`, or `:transverse`.
- `length`: centerline length of one bar, hooks and laps included.
- `shape`: `:straight`, `:hook_start`, `:hook_end`, `:hook_both`,
  `:closed_stirrup`, `:closed_tie`, `:crosstie`, or `:spiral`.
- `path`: centerline of one bar in the elevation plane `(x, z)`, meters.
  Bends are drawn as corners. Kept for the schedule drawings; the cage is
  `centerlines`.
- `centerlines`: one polyline per bar, `(x, y, z)` meters in the member frame.
  `x` runs along the member, `y` across it, `z` up. Empty only when a group
  was built without a location. Length equals `count` when present.
- `x_positions`: stations along the member, meters, for bars whose `path` is
  drawn at `x = 0` (stirrups, ties, wall verticals). Empty when `path` is
  already in place.
- `z_positions`: stations up the member, meters, for bars whose `path` is
  drawn at `z = 0` (wall horizontals). Empty otherwise.
- `laps`: lap splices in one bar run (stock-length splices included).
- `note`: free text for the schedule.
"""
struct BarGroup
    mark::String
    role::Symbol
    direction::Symbol
    bar_size::Int
    count::Int
    length::_M
    shape::Symbol
    path::Vector{NTuple{2, Float64}}
    x_positions::Vector{Float64}
    z_positions::Vector{Float64}
    laps::Int
    note::String
    centerlines::Vector{Vector{NTuple{3, Float64}}}
end

function BarGroup(; mark::AbstractString, role::Symbol, direction::Symbol, bar_size::Int,
                  count::Int, length, shape::Symbol = :straight,
                  path = NTuple{2, Float64}[], x_positions = Float64[],
                  z_positions = Float64[], laps::Int = 0,
                  note::AbstractString = "",
                  centerlines = Vector{NTuple{3, Float64}}[])
    count >= 0 || throw(ArgumentError("bar count must be ≥ 0 (got $count)"))
    L = uconvert(u"m", length)
    ustrip(u"m", L) >= 0 || throw(ArgumentError("bar length must be ≥ 0 (got $L)"))
    wires = Vector{Vector{NTuple{3, Float64}}}(centerlines)
    isempty(wires) || Base.length(wires) == count || throw(ArgumentError(
        "$mark: $(Base.length(wires)) centerlines for $count bars"))
    return BarGroup(String(mark), role, direction, bar_size, count, L, shape,
                    collect(NTuple{2, Float64}, path), collect(Float64, x_positions),
                    collect(Float64, z_positions), laps, String(note), wires)
end

"""The group as a [`BarSet`](@ref) for mass and carbon."""
bar_set(g::BarGroup) = BarSet(g.bar_size, g.count, g.length)

"""
    MemberDetail

Placed bars of one member. `warnings` are detailing checks that did not pass
(for example, a hook that does not fit its support). `notes` record choices the
code leaves to the detailer. `outline` is the concrete around the bars for
drawings, as `(x0, x1, z0, z1)` rectangles in meters in the same elevation
plane as the bar paths: the member itself first, then what it frames into
(supports, the slab above a column, the column on a footing). `voids` are
holes in that elevation (wall openings), same `(x0, x1, z0, z1)` order.
`section_dots` are bar centers cut by a plan section, `(x, y, diameter)` in
meters, `y` through the thickness. None of the three enters a quantity.
`areas` holds reported steel areas in square inches. Each quantity is a pair,
`"<name>_ideal_in2"` from the design and `"<name>_placed_in2"` from the bars.
`solid` is the member concrete in the same frame as `centerlines`,
`(x0, x1, y0, y1, z0, z1)` in meters, or `nothing` when the member was not located.
"""
mutable struct MemberDetail
    kind::Symbol
    groups::Vector{BarGroup}
    warnings::Vector{String}
    notes::Vector{String}
    outline::Vector{NTuple{4, Float64}}
    voids::Vector{NTuple{4, Float64}}
    section_dots::Vector{NTuple{3, Float64}}
    areas::Dict{String, Float64}
    solid::Union{Nothing, NTuple{6, Float64}}
end

MemberDetail(kind::Symbol) =
    MemberDetail(kind, BarGroup[], String[], String[],
                 NTuple{4, Float64}[], NTuple{4, Float64}[], NTuple{3, Float64}[],
                 Dict{String, Float64}(), nothing)

"""Replace `g` with the same group located on `wires`, one polyline per bar."""
function _with_centerlines(g::BarGroup, wires)
    return BarGroup(; mark = g.mark, role = g.role, direction = g.direction,
                    bar_size = g.bar_size, count = g.count, length = g.length,
                    shape = g.shape, path = g.path, x_positions = g.x_positions,
                    z_positions = g.z_positions, laps = g.laps, note = g.note,
                    centerlines = wires)
end

"""`n` centers from `a` to `b`. One bar sits in the middle."""
function _spread(n::Int, a::Float64, b::Float64)
    n <= 0 && return Float64[]
    n == 1 && return [(a + b) / 2]
    b + 1e-9 < a && return fill((a + b) / 2, n)
    return collect(range(a, b; length = n))
end

"""The elevation path `(x, z)` copied onto each across-width station `y`."""
function _wires_at_y(path, ys::Vector{Float64})
    return [[(p[1], y, p[2]) for p in path] for y in ys]
end

"""A section loop `(y, z)`, closed, placed at each station along the member."""
function _wires_at_x(loop, xs::Vector{Float64})
    pts = collect(NTuple{2, Float64}, loop)
    isempty(pts) && return Vector{NTuple{3, Float64}}[]
    pts[1] == pts[end] || push!(pts, pts[1])
    return [[(x, y, z) for (y, z) in pts] for x in xs]
end

# Words used to turn an area key such as `primary_column_pos` into a note.
const _AREA_WORDS = Dict(
    "vertical" => "Vertical steel",
    "horizontal" => "Horizontal steel",
    "bottom" => "Bottom steel",
    "top" => "Top steel",
    "stirrup" => "Stirrups",
    "longitudinal" => "Longitudinal steel",
    "long" => "Long bars",
    "short" => "Short bars",
    "dowel" => "Dowels",
    "primary" => "Primary",
    "secondary" => "Secondary",
    "column" => "column strip",
    "middle" => "middle strip",
    "extneg" => "exterior negative",
    "pos" => "positive",
    "intneg" => "interior negative",
)

"""Readable label for an area key. Unknown words are left as written."""
steel_area_label(key::AbstractString) =
    join((get(_AREA_WORDS, part, part) for part in split(key, "_")), " ")

"""
    record_steel_area!(md, key, ideal, placed; source)

Store one ideal/placed pair, in in², and note both numbers. `source` is the
short phrase that says where the ideal area came from. A placed area more than
0.01 in² under an ideal area above 0.05 in² is warned.
"""
function record_steel_area!(md::MemberDetail, key::AbstractString, ideal, placed;
                            source::AbstractString)
    iv, pv = Float64(ideal), Float64(placed)
    md.areas[key * "_ideal_in2"] = iv
    md.areas[key * "_placed_in2"] = pv
    label = steel_area_label(key)
    push!(md.notes, "$label: $(round(pv; digits = 2)) in² placed, " *
                    "$(round(iv; digits = 2)) in² from $source")
    if iv > 0.05 && pv + 0.01 < iv
        push!(md.warnings, "$label placed area $(round(pv; digits = 2)) in² is below " *
                           "$(round(iv; digits = 2)) in² from $source")
    end
    return nothing
end

"""
Rewrite one note per area pair already stored on `md`.

A plate summed from several frame lines uses this after adding the line areas,
so the note states the total rather than each line.
"""
function note_summed_areas!(md::MemberDetail; source::AbstractString)
    suffix = "_ideal_in2"
    names = String[]
    for key in keys(md.areas)
        endswith(key, suffix) || continue
        push!(names, key[1:(end - length(suffix))])
    end
    for name in sort!(names)
        record_steel_area!(md, name, md.areas[name * "_ideal_in2"],
                           get(md.areas, name * "_placed_in2", 0.0); source = source)
    end
    return nothing
end

"""
Placed area, in in², of groups with one of `roles`. `direction` limits the
sum to one bar direction when a member places the same role both ways.
"""
function _placed_area_in2(md::MemberDetail, roles::Symbol...;
                          direction::Union{Symbol, Nothing} = nothing,
                          mark::Union{Nothing, String} = nothing)
    total = 0.0
    for g in md.groups
        g.role in roles || continue
        mark === nothing || g.mark == mark || continue
        direction === nothing || g.direction === direction || continue
        total += g.count * ustrip(u"inch^2", bar_area(g.bar_size))
    end
    return total
end

"""
Extent along x of the longitudinal bar paths, `(xmin, xmax)`, or `nothing`.
Transverse groups are skipped: their path is a template at `x = 0` and their
stations are `x_positions`.
"""
function _path_extent(md::MemberDetail)
    xs = [p[1] for g in md.groups if isempty(g.x_positions) for p in g.path]
    return isempty(xs) ? nothing : extrema(xs)
end

"""Total bar mass of the member, kg."""
detail_mass(md::MemberDetail) =
    isempty(md.groups) ? 0.0u"kg" : sum(bar_set_mass(bar_set(g)) for g in md.groups)

"""Embodied carbon of the member's bars, `ecc` in kgCO₂e/kg."""
detail_ec(md::MemberDetail, ecc) = uconvert(u"kgCO2e", detail_mass(md) * ecc)

"""
    bar_schedule(md) -> Vector{NamedTuple}

One row per group: mark, role, size, count, shape, length of one bar, and
total mass.
"""
function bar_schedule(md::MemberDetail)
    return [(mark = g.mark, role = g.role, direction = g.direction, bar_size = g.bar_size,
             count = g.count, shape = g.shape, length = g.length, laps = g.laps,
             mass = bar_set_mass(bar_set(g)), note = g.note) for g in md.groups]
end

# ------------------------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------------------------

"""
Development λ from a concrete's λ. ACI 318-19 Table 25.4.2.5 (corpus:
aci-318-19, printed p. 474) has 0.75 for lightweight and 1.0 for normalweight
concrete, so any λ below 1 is taken as lightweight.
"""
_detailing_λ(λ::Real) = λ >= 1.0 - 1e-6 ? 1.0 : 0.75

"""Bar size from a catalog string such as `"#5"`."""
function bar_size_from_string(s::AbstractString)
    m = match(r"#?\s*(\d+)", s)
    m === nothing && throw(ArgumentError("cannot read a bar size from \"$s\""))
    return parse(Int, m.captures[1])
end

"""
    stock_splices(run, stock, lap) -> (n_splices, length)

A bar run longer than the stock length is made of several bars lapped
together. Each splice adds one lap. `run` is the run length without laps.
Throws when the lap is not shorter than the stock length.
"""
function stock_splices(run::Length, stock::Length, lap::Length)
    run_m, stock_m, lap_m = ustrip(u"m", run), ustrip(u"m", stock), ustrip(u"m", lap)
    run_m <= stock_m + 1e-9 && return (0, uconvert(u"m", run))
    stock_m > lap_m || throw(ArgumentError(
        "stock length $(stock) is not longer than the lap $(lap)"))
    n = ceil(Int, (run_m - stock_m) / (stock_m - lap_m) - 1e-9)
    return (n, (run_m + n * lap_m) * u"m")
end

"""
Outline of a 90-degree hook at the end of a bar, in the elevation plane.

The tail turns toward `toward` (`-1` down, `+1` up) from `(x, z)`. Where the
tail does not fit in `room`, it is rotated toward the bar so its vertical reach
is `room`; the length stays the code length. Returns the tail end point and
whether the tail had to be rotated.
"""
function _hook_tail(x::Float64, z::Float64, tail::Float64, room::Float64,
                    toward::Int, inward::Int)
    if tail <= room + 1e-9
        return (x, z + toward * tail), false
    end
    room = max(room, 0.0)
    run = sqrt(max(tail^2 - room^2, 0.0))
    return (x + inward * run, z + toward * room), true
end

"""Centerline length in meters of a closed rectangular loop with two hooks."""
function _closed_loop_length(width_m::Float64, depth_m::Float64, bar_size::Int;
                             hook_angle::Int = 135)
    perimeter = 2 * (width_m + depth_m)
    hook = ustrip(u"m", hook_centerline_length(bar_size; angle = hook_angle, role = :stirrup))
    return perimeter + 2 * hook
end

"""Evenly spaced positions from `a` to `b` at most `s` apart, both ends included."""
function _spaced_positions(a::Float64, b::Float64, s::Float64)
    b >= a || return Float64[]
    s > 0 || throw(ArgumentError("spacing must be positive"))
    n = max(ceil(Int, (b - a) / s - 1e-9), 0)
    n == 0 && return [a]
    return collect(range(a, b; length = n + 1))
end
