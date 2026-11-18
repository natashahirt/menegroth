# Plan geometries from the 2024 Slab Design Factors project.
#
# Each file is one floor framing plan: node positions in meters, beam lines,
# and the nodes that carry a column. Validation plans also carry a transcribed
# ETABS section list, one row per beam line, in the same order.

const SS = StructuralSynthesizer
const SR = StructuralSizer

"""Sibling checkout of the 2024 Slab Design Factors geometries."""
const SDF_ROOT = normpath(joinpath(@__DIR__, "..", "..", "..", "..", "..",
                                   "2024_Slab Design Factors", "Geometries"))

"""Story height for the lifted frame. The source plans are a single floor."""
const STORY_HEIGHT = 12.0u"ft"

"""One framing plan, with optional transcribed steel sections."""
struct SdfPlan
    name::String
    xy::Vector{NTuple{2, Float64}}          # meters
    lines::Vector{NTuple{2, Int}}           # 1-based node indices
    columns::Vector{Int}
    walls::Vector{Int}                      # node indices; not turned into wall edges
    holes::Vector{Vector{Int}}              # node loops
    perimeter::Vector{Int}                  # edge indices; the 500 plf facade is not applied
    sections::Vector{Union{Nothing, Tuple{Float64, Float64}}}  # (depth in, weight plf); empty if none
end

"""Read a geometry file. The files are a JSON string holding a JSON object."""
function load_plan(name::AbstractString)
    path = joinpath(SDF_ROOT, name * ".json")
    isfile(path) || throw(ArgumentError("No geometry at $path"))
    raw = JSON3.read(read(path, String))
    raw isa AbstractString && (raw = JSON3.read(raw))
    xy = NTuple{2, Float64}[(Float64(p.x), Float64(p.y)) for p in raw.positions]
    lines = NTuple{2, Int}[(Int(c.from), Int(c.to)) for c in raw.connectivities]
    columns = Int[Int(c) for c in raw.columns_i]
    walls = haskey(raw, :wall_i) ? Int[Int(c) for c in raw.wall_i] : Int[]
    holes = _hole_loops(raw)
    perimeter = haskey(raw, :perimeter_i) ? Int[Int(c) for c in raw.perimeter_i] : Int[]
    sections = _transcribed_sections(name, length(lines))
    return SdfPlan(String(name), xy, lines, columns, walls, holes, perimeter, sections)
end

"""
Hole loops stored as `{hole: [node, ...]}`. A bare list of numbers is not a
void: `special/school` stores its four corner nodes that way.
"""
function _hole_loops(raw)
    haskey(raw, :holes_i) || return Vector{Int}[]
    items = raw.holes_i
    isempty(items) && return Vector{Int}[]
    first(items) isa Real && return Vector{Int}[]
    loops = Vector{Int}[]
    for item in items
        haskey(item, :hole) || continue
        push!(loops, Int[Int(i) for i in item.hole])
    end
    return loops
end

"""Nodes strictly between the ends of line `a`–`b`, ordered along the line."""
function _nodes_along(xy, a::Int, b::Int; tol::Float64 = 1e-6)
    ax, ay = xy[a]
    bx, by = xy[b]
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    L2 < 1e-18 && return Int[]
    hits = Tuple{Int, Float64}[]
    for i in eachindex(xy)
        (i == a || i == b) && continue
        x, y = xy[i]
        t = ((x - ax) * dx + (y - ay) * dy) / L2
        (t <= 1e-5 || t >= 1 - 1e-5) && continue
        px, py = ax + t * dx, ay + t * dy
        (x - px)^2 + (y - py)^2 <= tol^2 && push!(hits, (i, t))
    end
    sort!(hits; by = last)
    return [i for (i, _) in hits]
end

"""`(depth, plf)` per beam line. `nothing` is a transcribed `0,0` row."""
function _transcribed_sections(name::AbstractString, n_lines::Int)
    path = joinpath(SDF_ROOT, name * "_original.csv")
    isfile(path) || return Tuple{Float64, Float64}[]
    rows = Tuple{Float64, Float64}[]
    for line in eachline(path)
        line = strip(replace(line, '\ufeff' => ""))
        isempty(line) && continue
        a, b = split(line, ',')
        push!(rows, (parse(Float64, a), parse(Float64, b)))
    end
    length(rows) == n_lines || throw(ArgumentError(
        "$name has $(length(rows)) transcribed sections and $n_lines beam lines. " *
        "The comparison uses one section per framing line, in file order."))
    return Union{Nothing, Tuple{Float64, Float64}}[
        (d == 0 && w == 0) ? nothing : (d, w) for (d, w) in rows]
end

"""AISC wide-flange name for a transcribed depth and weight, e.g. `(18, 35)` → `W18X35`."""
function w_name(depth::Real, weight::Real)
    w = weight == round(weight) ? string(Int(round(weight))) : string(weight)
    return "W$(Int(round(depth)))X$w"
end

"""Normalize a sized section name for comparison with [`w_name`](@ref)."""
function canonical_w(name::AbstractString)
    s = uppercase(replace(strip(name), "×" => "X", "x" => "X"))
    startswith(s, "W") || return s
    parts = split(s[2:end], 'X')
    length(parts) == 2 || return s
    depth = tryparse(Float64, String(parts[1]))
    weight = tryparse(Float64, String(parts[2]))
    (depth === nothing || weight === nothing) && return s
    return w_name(depth, weight)
end

"""
    plan_skeleton(plan) -> BuildingSkeleton

One story. Columns rise from supports at grade to the floor at
`STORY_HEIGHT`, and the framing plan is drawn only on that floor. Grade is
the support layer, so it does not get a second copy of the beams. The floor
faces take `floor_LL` and `floor_SDL`. Openings are the `holes` node loops
on that floor.

`walls` stay beam lines: the file stores wall nodes, not wall edges. The
500 plf perimeter facade from Tan's ETABS models is not applied.

A beam that stops on another beam is split there. The star plans `e10c2`
through `e10c8` draw that joint without a node on the long line, and an
unsplit line is one graph edge, so the face walk never sees the joint.
"""
function plan_skeleton(plan::SdfPlan)
    T = typeof(1.0u"m")
    skel = BuildingSkeleton{T}()
    H = uconvert(u"m", STORY_HEIGHT)
    push!(skel.stories_z, 0.0u"m", H)
    function pt(i, z)
        x, y = plan.xy[i]
        Meshes.Point(x * u"m", y * u"m", z)
    end
    for (a, b) in plan.lines
        chain = [a; _nodes_along(plan.xy, a, b); b]
        for s in 1:(length(chain) - 1)
            i, j = chain[s], chain[s + 1]
            add_element!(skel, Meshes.Segment(pt(i, H), pt(j, H)); group=:beams, level_idx=1)
        end
    end
    for c in plan.columns
        add_element!(skel, Meshes.Segment(pt(c, 0.0u"m"), pt(c, H)); group=:columns, level_idx=1)
        add_vertex!(skel, pt(c, 0.0u"m"); group=:support)
        add_vertex!(skel, pt(c, H); group=:roof)
    end
    find_faces!(skel)
    for (level_idx, story) in skel.stories
        grp = level_idx == 0 ? :grade : :floor
        append!(get!(skel.groups_faces, grp, Int[]), story.faces)
    end
    for loop in plan.holes
        pts = [(plan.xy[i][1], plan.xy[i][2]) for i in loop]
        add_slab_opening!(skel, pts, 1)
    end
    return skel
end
