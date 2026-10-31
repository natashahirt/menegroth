
"""
    projected_plan_width(points, direction) -> Float64

Width of `points` measured perpendicular to `direction`, in metres.

`direction` is a horizontal vector `(dx, dy)`. It need not be a unit vector,
and the components may be integers: `(1, 0)` returns the Y extent and `(0, 1)`
returns the X extent. An empty point list throws.
"""
function projected_plan_width(points, direction::Tuple{Real, Real})
    isempty(points) && throw(ArgumentError(
        "projected_plan_width: no points"))
    dx = Float64(direction[1])
    dy = Float64(direction[2])
    nrm = hypot(dx, dy)
    nrm > 0 || throw(ArgumentError(
        "projected_plan_width: direction must be nonzero; got $direction"))
    dx /= nrm
    dy /= nrm
    # In-plane normal. The sign does not change the extent.
    px, py = -dy, dx
    lo = Inf
    hi = -Inf
    for (x, y) in points
        t = px * x + py * y
        lo = min(lo, t)
        hi = max(hi, t)
    end
    return hi - lo
end

"""
    story_floor_outline(skeleton, story) -> Vector{Vector{NTuple{2,Float64}}}

Closed plan loops of one story's floor, in metres, from the skeleton vertices.

Each loop is the exterior of the story's slab faces (`story.faces` filtered by
[`slab_face_indices`](@ref)): an edge shared by two of those faces is interior
and is dropped. A detected face with no slab is a courtyard hole. Coordinates are `GeometryCache.vertex_coords`,
the same datum as [`story_plate_geometry`](@ref) and [`to_wall_line`](@ref).
A courtyard or a disconnected floor returns more than one loop. The loops are
open rings (the first vertex is not repeated at the end).

Each loop is oriented so the right-hand normal of a directed edge points out
of the floor. An exterior loop, and an island inside a courtyard, runs
counterclockwise (positive signed area). A courtyard hole runs clockwise
(negative signed area). The first vertex of each loop is the one with the
smallest `(x, y)`, and the loops are sorted by that vertex, so the result
does not depend on face order or on which boundary edge is walked first.

An edge that passes through another vertex of the story's faces is split
there. Pieces a second face covers are interior and are dropped, so a
T-junction in `face_vertex_indices` still yields the outer floor. Two slabs
that touch only at a corner are not one floor and throw. A joist landing
that was inserted into the member graph but not into `face_vertex_indices`
is not a split point.

The axis-aligned box from [`story_plate_geometry`](@ref) still encloses this
outline. It is not this outline. A re-entrant floor keeps the notch.

Throws if the story has no faces, if a face has fewer than three vertices, if
an edge belongs to more than two faces, if the boundary is not a set of closed
loops, or if the outline has no area.
"""
function story_floor_outline(skeleton::BuildingSkeleton, story::Story)
    geo = _geometry_cache_or_error(skeleton)
    isempty(story.faces) && throw(ArgumentError(
        "story_floor_outline: story has no faces — empty floor"))
    vc = geo.vertex_coords

    # A face with no slab (a courtyard left out of the face polygons) is a hole.
    slab_faces = slab_face_indices(skeleton)
    faces = slab_faces === nothing ? story.faces : filter(in(slab_faces), story.faces)
    isempty(faces) && throw(ArgumentError(
        "story_floor_outline: no face on this story carries a slab — empty floor"))
    counts = _atomic_edge_counts(vc, skeleton, faces)
    for (key, c) in counts
        c <= 2 || throw(ArgumentError(
            "story_floor_outline: edge $key belongs to $c faces — the floor is not a surface"))
    end
    boundary = [key for (key, c) in counts if c == 1]
    isempty(boundary) && throw(ArgumentError(
        "story_floor_outline: story faces have no exterior edge"))

    adj = Dict{Int, Vector{Int}}()
    for (a, b) in boundary
        push!(get!(adj, a, Int[]), b)
        push!(get!(adj, b, Int[]), a)
    end
    for (v, nbrs) in adj
        length(nbrs) == 2 || throw(ArgumentError(
            "story_floor_outline: vertex $v meets $(length(nbrs)) exterior edges — " *
            "two slabs touch only at a corner, or a vertex lies off the edge it " *
            "was meant to split. The floor boundary is not a set of closed loops"))
    end

    unused = Set(boundary)
    loops = Vector{NTuple{2,Float64}}[]
    while !isempty(unused)
        a0, b0 = first(unused)
        ring = Int[a0]
        prev = a0
        cur = b0
        delete!(unused, a0 < b0 ? (a0, b0) : (b0, a0))
        steps = 0
        while cur != a0
            push!(ring, cur)
            nbrs = adj[cur]
            prev in nbrs || throw(ArgumentError(
                "story_floor_outline: exterior walk reached vertex $cur without a way back"))
            nxt = nbrs[1] == prev ? nbrs[2] : nbrs[1]
            key = cur < nxt ? (cur, nxt) : (nxt, cur)
            key in unused || throw(ArgumentError(
                "story_floor_outline: exterior edge $key was visited twice"))
            delete!(unused, key)
            prev = cur
            cur = nxt
            steps += 1
            steps > length(boundary) && throw(ArgumentError(
                "story_floor_outline: exterior walk did not close"))
        end
        push!(loops, [(vc[i, 1], vc[i, 2]) for i in ring])
    end

    # A collinear ring has no floor area. Fail closed rather than hand wind
    # or the 5% eccentricity a line.
    for loop in loops
        _polygon_area_centroid(loop)
    end
    return _canonicalize_outline_loops(loops)
end

# Parameter of vertex `v` along a→b, or nothing when `v` is not strictly
# between the endpoints. The cross-track test uses `_WALLS_BRIDGE_DEGEN_TOL` metres.
function _strict_segment_parameter(vc, a::Int, b::Int, v::Int)
    x1 = vc[a, 1]
    y1 = vc[a, 2]
    x2 = vc[b, 1]
    y2 = vc[b, 2]
    px = vc[v, 1]
    py = vc[v, 2]
    dx = x2 - x1
    dy = y2 - y1
    len = hypot(dx, dy)
    len <= _WALLS_BRIDGE_DEGEN_TOL && return nothing
    cross = dx * (py - y1) - dy * (px - x1)
    abs(cross) / len > _WALLS_BRIDGE_DEGEN_TOL && return nothing
    t = ((px - x1) * dx + (py - y1) * dy) / (len * len)
    margin = _WALLS_BRIDGE_DEGEN_TOL / len
    return margin < t < 1 - margin ? t : nothing
end

_edge_key(a::Int, b::Int) = a < b ? (a, b) : (b, a)

# Split every face edge at other vertices of these faces that lie on it, then
# count the pieces. A piece covered by two faces is interior.
function _atomic_edge_counts(vc, skeleton::BuildingSkeleton, faces)
    used = Int[]
    seen = Set{Int}()
    raw = Tuple{Int,Int}[]
    nvc = size(vc, 1)
    for f in faces
        vids = skeleton.face_vertex_indices[f]
        n = length(vids)
        n >= 3 || throw(ArgumentError(
            "story_floor_outline: face $f has $n vertices (< 3)"))
        for i in 1:n
            a = vids[i]
            b = vids[mod1(i + 1, n)]
            a == b && throw(ArgumentError(
                "story_floor_outline: face $f has a zero-length edge at vertex $a"))
            (1 <= a <= nvc && 1 <= b <= nvc) || throw(ArgumentError(
                "story_floor_outline: face $f references a vertex outside the geometry cache"))
            push!(raw, (a, b))
            for v in (a, b)
                v in seen && continue
                push!(seen, v)
                push!(used, v)
            end
        end
    end
    counts = Dict{Tuple{Int,Int}, Int}()
    for (a, b) in raw
        splits = Tuple{Float64,Int}[]
        for v in used
            (v == a || v == b) && continue
            t = _strict_segment_parameter(vc, a, b, v)
            t === nothing && continue
            push!(splits, (t, v))
        end
        sort!(splits)
        chain = Int[a]
        for (_, v) in splits
            v == chain[end] && continue
            if hypot(vc[chain[end], 1] - vc[v, 1], vc[chain[end], 2] - vc[v, 2]) <=
               _WALLS_BRIDGE_DEGEN_TOL
                throw(ArgumentError(
                    "story_floor_outline: vertices $(chain[end]) and $v occupy the same point"))
            end
            push!(chain, v)
        end
        if chain[end] != b &&
           hypot(vc[chain[end], 1] - vc[b, 1], vc[chain[end], 2] - vc[b, 2]) <=
           _WALLS_BRIDGE_DEGEN_TOL
            throw(ArgumentError(
                "story_floor_outline: vertices $(chain[end]) and $b occupy the same point"))
        end
        push!(chain, b)
        for i in 1:(length(chain) - 1)
            key = _edge_key(chain[i], chain[i + 1])
            counts[key] = get(counts, key, 0) + 1
        end
    end
    return counts
end

# Signed area of an open ring. Positive is counterclockwise.
function _ring_signed_area(pts::AbstractVector{NTuple{2,Float64}})
    A2 = 0.0
    n = length(pts)
    @inbounds for i in 1:n
        x1, y1 = pts[i]
        x2, y2 = pts[mod1(i + 1, n)]
        A2 += x1 * y2 - x2 * y1
    end
    return A2 / 2
end

# `:inside`, `:outside`, or `:boundary` by the even-odd rule.
function _ring_location(x::Float64, y::Float64, ring::AbstractVector{NTuple{2,Float64}})
    tol = _WALLS_BRIDGE_DEGEN_TOL
    n = length(ring)
    @inbounds for i in 1:n
        x1, y1 = ring[i]
        x2, y2 = ring[mod1(i + 1, n)]
        dx = x2 - x1
        dy = y2 - y1
        len = hypot(dx, dy)
        if len <= tol
            hypot(x - x1, y - y1) <= tol && return :boundary
            continue
        end
        cross = dx * (y - y1) - dy * (x - x1)
        if abs(cross) / len <= tol
            t = ((x - x1) * dx + (y - y1) * dy) / (len * len)
            -tol <= t <= 1 + tol && return :boundary
        end
    end
    inside = false
    @inbounds for i in 1:n
        x1, y1 = ring[i]
        x2, y2 = ring[mod1(i + 1, n)]
        # Assign a vertex to the upper endpoint so a ray through it is counted once.
        if (y1 > y) != (y2 > y)
            xint = x1 + (y - y1) / (y2 - y1) * (x2 - x1)
            x < xint && (inside = !inside)
        end
    end
    return inside ? :inside : :outside
end

function _rotate_ring_to_min!(ring::Vector{NTuple{2,Float64}})
    i0 = 1
    best = ring[1]
    for i in 2:length(ring)
        p = ring[i]
        if (p[1], p[2]) < (best[1], best[2])
            best = p
            i0 = i
        end
    end
    i0 == 1 || circshift!(ring, 1 - i0)
    return ring
end

# Exterior and islands: counterclockwise. Courtyard holes: clockwise.
# A right-hand normal then points out of the floor, including into a courtyard.
function _canonicalize_outline_loops(loops::Vector{Vector{NTuple{2,Float64}}})
    n = length(loops)
    depth = zeros(Int, n)
    # A vertex is inside another loop, or it is not. The shoelace centroid is
    # the wrong probe: the centroid of an exterior ring falls inside a courtyard.
    for i in 1:n
        for j in 1:n
            i == j && continue
            inside = false
            outside = false
            for (x, y) in loops[i]
                hit = _ring_location(x, y, loops[j])
                hit == :inside && (inside = true)
                hit == :outside && (outside = true)
            end
            inside && !outside && (depth[i] += 1)
        end
    end
    for i in 1:n
        want_ccw = iseven(depth[i])
        if want_ccw != (_ring_signed_area(loops[i]) > 0)
            reverse!(loops[i])
        end
        _rotate_ring_to_min!(loops[i])
    end
    order = sortperm(loops, by = ring -> (ring[1][1], ring[1][2], -_ring_signed_area(ring)))
    return loops[order]
end
