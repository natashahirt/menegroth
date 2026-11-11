# =============================================================================
# Wall openings — storage on the skeleton
# =============================================================================
# An opening is a rectangle in one wall's own coordinates. The skeleton keeps
# the record, because `initialize_members!` rebuilds every `Wall`. The copy
# onto the wall mirrors `s` when the wall runs from `v2` toward `v1`.

"Openings closer than this, in metres, are the same cut. Same 1 mm as a shared wall node."
const WALL_OPENING_GAP_M = 1e-3

"""Story height in metres: this story's elevation to the next higher elevation."""
function _opening_story_height_m(skel::BuildingSkeleton, story::Int)
    haskey(skel.stories, story) || throw(ArgumentError(
        "wall opening: story $story does not exist; stories are " *
        "$(sort(collect(keys(skel.stories))))."))
    z = _plan_coord_m(skel.stories[story].elevation)
    above = Inf
    for (k, st) in skel.stories
        k == story && continue
        zk = _plan_coord_m(st.elevation)
        zk > z + WALL_OPENING_GAP_M || continue
        above = min(above, zk)
    end
    isfinite(above) || throw(ArgumentError(
        "wall opening: story $story has no story above it, so the opening " *
        "height cannot be checked against the story height."))
    return above - z
end

"""Plan length in metres between two skeleton vertices."""
function _opening_edge_length_m(skel::BuildingSkeleton, v1::Int, v2::Int)
    n = skel.geometry === nothing ? length(skel.vertices) : size(skel.geometry.vertex_coords, 1)
    (1 <= v1 <= n && 1 <= v2 <= n) || throw(ArgumentError(
        "wall opening: vertices are $v1 and $v2, and the skeleton has $n."))
    v1 == v2 && throw(ArgumentError(
        "wall opening: both endpoints are vertex $v1."))
    a = vertex_coords(skel, v1)
    b = vertex_coords(skel, v2)
    abs(a.z - b.z) <= 1e-4 || throw(ArgumentError(
        "wall opening: vertices $v1 and $v2 are not a plan line " *
        "(|z2 − z1| = $(abs(a.z - b.z)) m)."))
    L = hypot(b.x - a.x, b.y - a.y)
    L > 1e-9 || throw(ArgumentError(
        "wall opening: vertices $v1 and $v2 have no plan length."))
    return L
end

"""
Throw unless `op` is a finite rectangle inside a wall of length `L` and
height `H`, and is neither the whole wall nor the whole story.

A door sill is the story base. A window sill is above it. `:other` may sit
on the base. Two openings closer than [`WALL_OPENING_GAP_M`](@ref) in both
directions are one cut and are refused.
"""
function check_wall_opening(op::WallOpening, L::Real, H::Real)
    L = Float64(L)
    H = Float64(H)
    (L > 0 && H > 0) || throw(ArgumentError(
        "wall opening: the wall length and story height must be positive " *
        "(got $L m by $H m)."))
    for (name, x) in (("s0", op.s0), ("z0", op.z0), ("width", op.width), ("height", op.height))
        isfinite(x) || throw(ArgumentError("wall opening: $name is not finite."))
    end
    (op.width > WALL_OPENING_GAP_M && op.height > WALL_OPENING_GAP_M) ||
        throw(ArgumentError(
            "wall opening: width $(op.width) m and height $(op.height) m must " *
            "each exceed $(WALL_OPENING_GAP_M) m."))
    (op.s0 >= -1e-9 && op.z0 >= -1e-9) || throw(ArgumentError(
        "wall opening: s0 $(op.s0) m and z0 $(op.z0) m must be at or above the " *
        "wall start and the story base."))
    (op.s0 + op.width <= L + 1e-6 && op.z0 + op.height <= H + 1e-6) ||
        throw(ArgumentError(
            "wall opening: the rectangle [$(op.s0), $(op.s0 + op.width)] m by " *
            "[$(op.z0), $(op.z0 + op.height)] m falls outside the wall " *
            "($(L) m by $(H) m)."))
    op.s0 <= WALL_OPENING_GAP_M && L - (op.s0 + op.width) <= WALL_OPENING_GAP_M &&
        throw(ArgumentError(
            "wall opening: the opening runs the full wall length. Split the wall."))
    op.z0 <= WALL_OPENING_GAP_M && H - (op.z0 + op.height) <= WALL_OPENING_GAP_M &&
        throw(ArgumentError(
            "wall opening: the opening runs the full story height. Split the wall."))
    if op.kind === :door && op.z0 > WALL_OPENING_GAP_M
        throw(ArgumentError(
            "wall opening: a door sill is the story base, and z0 is $(op.z0) m."))
    end
    if op.kind === :window && op.z0 <= WALL_OPENING_GAP_M
        throw(ArgumentError(
            "wall opening: a window sill is above the story base. A sill at " *
            "z0 = $(op.z0) m is a door."))
    end
    return nothing
end

"Separation of two intervals. Zero when they overlap or touch."
function _interval_separation(a0, a1, b0, b1)
    return max(a0, b0) <= min(a1, b1) ? 0.0 : max(a0, b0) - min(a1, b1)
end

"""True when the rectangles overlap or the gap between them is under `tol` in both directions."""
function wall_openings_conflict(a::WallOpening, b::WallOpening; tol::Real=WALL_OPENING_GAP_M)
    return _interval_separation(a.s0, a.s0 + a.width, b.s0, b.s0 + b.width) < tol &&
           _interval_separation(a.z0, a.z0 + a.height, b.z0, b.z0 + b.height) < tol
end

"""Throw when any pair of openings on one wall is the same cut."""
function check_wall_opening_gaps(openings::AbstractVector{WallOpening})
    for i in eachindex(openings), j in (i + 1):length(openings)
        wall_openings_conflict(openings[i], openings[j]) || continue
        throw(ArgumentError(
            "wall opening: openings $i and $j overlap or are closer than " *
            "$(WALL_OPENING_GAP_M) m. Draw them as one opening."))
    end
    return nothing
end

"""Opening with `s` measured from the other end of a wall of length `L`."""
function mirror_wall_opening(op::WallOpening, L::Real)
    return WallOpening(Float64(L) - op.s0 - op.width, op.z0, op.width, op.height, op.kind)
end

"""
Openings of `openings` that lie entirely in `[s_start, s_end]`, rewritten
from `s_start`.

A split that cuts an opening is the caller's error. An opening that only
touches the interval within [`WALL_OPENING_GAP_M`](@ref) is not included.
"""
function openings_on_segment(openings, s_start::Real, s_end::Real)
    out = WallOpening[]
    a0 = Float64(s_start)
    b0 = Float64(s_end)
    for op in openings
        a = op.s0
        b = op.s0 + op.width
        b <= a0 + WALL_OPENING_GAP_M && continue
        a >= b0 - WALL_OPENING_GAP_M && continue
        local0 = max(a - a0, 0.0)
        push!(out, WallOpening(local0, op.z0, op.width, op.height, op.kind))
    end
    return out
end

"""Opening in the frame that runs from the lower vertex index toward the higher one."""
function _opening_low_to_high(spec::WallOpeningSpec, L::Real)
    return spec.v1 < spec.v2 ? spec.opening : mirror_wall_opening(spec.opening, L)
end

"""
    add_wall_opening!(skel, v1, v2, stories, opening) -> skel

Record `opening` on the wall from vertex `v1` to vertex `v2` for each story
in `stories` (one index, or a collection such as `0:2`).

`opening.s0` is measured from `v1` toward `v2`. The wall length is the plan
distance between the vertices. The story height is the rise to the next
higher story elevation. A missing story, an opening outside the wall, a
full-length or full-height opening, a door with a raised sill, a window on
the base, or an opening that meets another opening on the same wall is
refused.
"""
function add_wall_opening!(skel::BuildingSkeleton, v1::Integer, v2::Integer,
                           stories, opening::WallOpening)
    v1 = Int(v1)
    v2 = Int(v2)
    L = _opening_edge_length_m(skel, v1, v2)
    levels = stories isa Integer ? (Int(stories),) : stories
    for level in levels
        level = Int(level)
        H = _opening_story_height_m(skel, level)
        check_wall_opening(opening, L, H)
        incoming = _opening_low_to_high(WallOpeningSpec(v1, v2, level, opening), L)
        for (k, other) in enumerate(skel.wall_openings)
            other.story == level || continue
            same = (other.v1 == v1 && other.v2 == v2) || (other.v1 == v2 && other.v2 == v1)
            same || continue
            placed = _opening_low_to_high(other, L)
            wall_openings_conflict(incoming, placed) || continue
            throw(ArgumentError(
                "wall opening: the new opening meets opening $k on story $level " *
                "between vertices $v1 and $v2. Draw them as one opening."))
        end
        push!(skel.wall_openings, WallOpeningSpec(v1, v2, level, opening))
    end
    return skel
end

"""
Openings stored for the wall from vertex `va` to vertex `vb` on `story`.

`s` is measured from `va`. A spec stored from `vb` toward `va` is mirrored.
Each opening is checked against `L` and `H` again, because the built wall
can be shorter than the vertex distance the spec was checked against.
"""
function wall_openings_for_edge(skel::BuildingSkeleton, va::Int, vb::Int,
                                story::Int, L::Real, H::Real)
    out = WallOpening[]
    for spec in skel.wall_openings
        spec.story == story || continue
        if spec.v1 == va && spec.v2 == vb
            op = spec.opening
        elseif spec.v1 == vb && spec.v2 == va
            op = mirror_wall_opening(spec.opening, L)
        else
            continue
        end
        check_wall_opening(op, L, H)
        push!(out, op)
    end
    check_wall_opening_gaps(out)
    return out
end

"""Check every opening on `wall` against its length and story height."""
function check_wall_openings(wall::Wall)
    isempty(wall.openings) && return nothing
    L = wall_length(wall)
    H = ustrip(u"m", wall.base.L)
    for op in wall.openings
        check_wall_opening(op, L, H)
    end
    check_wall_opening_gaps(wall.openings)
    return nothing
end
