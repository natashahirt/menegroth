"""
    set_slab_openings!(struc, polygons; stories=nothing)

Replace the skeleton's slab openings with `polygons`, each a list of `(x, y)`
points in plan meters, on every story in `stories` (default: all stories). Use
[`add_slab_opening!`](@ref) to add a single opening on chosen stories.

Cell spans and net areas read the openings when cells are created, so set them
before `initialize!`. A beam's effective width on a side stops at the first
opening on its story that the side's perpendicular ray hits.

AISC 360-22 Commentary I3.1, trenches (corpus: aisc-360-22, PDF pp. 512–513):
a trench that replaces the concrete is a complete discontinuity in the flange,
and a trench parallel to the beam sets the effective width from the trench position.
"""
function set_slab_openings!(struc::BuildingStructure, polygons; stories=nothing)
    skel = struc.skeleton
    levels = stories === nothing ? sort(collect(keys(skel.stories))) : stories
    empty!(skel.openings)
    for poly in polygons
        add_slab_opening!(skel, poly, levels)
    end
    isempty(struc.cells) ||
        @warn "Slab openings changed after cells were created; cell spans and areas keep the old geometry until `initialize!` runs again." maxlog=1
    return struc
end

function _point_in_polygon(x, y, poly)
    inside = false
    n = length(poly)
    j = n
    for i in 1:n
        xi, yi = poly[i]
        xj, yj = poly[j]
        if ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / ((yj - yi) + 1e-30) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

function _ray_segment_hit(ox, oy, dx, dy, ax, ay, bx, by)
    ex = bx - ax
    ey = by - ay
    det = dx * ey - dy * ex
    abs(det) < 1e-12 && return nothing
    t = ((ax - ox) * ey - (ay - oy) * ex) / det
    u = ((ax - ox) * dy - (ay - oy) * dx) / det
    return (t > 1e-8 && 0.0 <= u <= 1.0) ? t : nothing
end

"""Perpendicular distance from a point to the first opening boundary, or 0 inside one."""
function _side_clearance(px, py, nx, ny, openings)
    best = Inf
    for poly in openings
        _point_in_polygon(px, py, poly) && return 0.0
        n = length(poly)
        for i in 1:n
            j = i == n ? 1 : i + 1
            t = _ray_segment_hit(px, py, nx, ny, poly[i][1], poly[i][2],
                                 poly[j][1], poly[j][2])
            t === nothing || (best = min(best, t))
        end
    end
    return best
end

function _beam_plan_axis(struc, verts, seg_len_m)
    pts = NTuple{2, Float64}[]
    cum = Float64[0.0]
    for v in verts
        c = vertex_coords(struc.skeleton, v)
        push!(pts, (Float64(c.x), Float64(c.y)))
    end
    for L in seg_len_m
        push!(cum, cum[end] + L)
    end
    return (pts = pts, cum = cum, total = cum[end])
end

function _axis_project(axis, p)
    axis.total <= 0 && return nothing
    best_d = Inf
    best_s = 0.0
    for i in 1:(length(axis.pts) - 1)
        ax, ay = axis.pts[i]
        bx, by = axis.pts[i + 1]
        ex, ey = bx - ax, by - ay
        L2 = ex * ex + ey * ey
        L2 <= 0 && continue
        u = clamp(((p[1] - ax) * ex + (p[2] - ay) * ey) / L2, 0.0, 1.0)
        d = hypot(p[1] - (ax + u * ex), p[2] - (ay + u * ey))
        if d < best_d
            best_d = d
            best_s = (axis.cum[i] + u * (axis.cum[i + 1] - axis.cum[i])) / axis.total
        end
    end
    return best_s
end

function _axis_frame(axis, s, sign)
    target = clamp(float(s), 0.0, 1.0) * axis.total
    i = searchsortedlast(axis.cum, target)
    i = clamp(i, 1, length(axis.pts) - 1)
    ax, ay = axis.pts[i]
    bx, by = axis.pts[i + 1]
    seg = axis.cum[i + 1] - axis.cum[i]
    u = seg <= 0 ? 0.0 : (target - axis.cum[i]) / seg
    x = ax + u * (bx - ax)
    y = ay + u * (by - ay)
    tx, ty = bx - ax, by - ay
    L = hypot(tx, ty)
    if L <= 0
        return (x, y, 0.0, sign)
    end
    tx /= L
    ty /= L
    # Left of the beam direction is the counterclockwise normal.
    return (x, y, -sign * ty, sign * tx)
end

function _extent_at(profile::SideExtentProfile, s)
    pos = profile.positions
    ext = profile.extents_m
    s <= pos[1] && return ext[1]
    s >= pos[end] && return ext[end]
    i = searchsortedlast(pos, s)
    i >= length(pos) && return ext[end]
    denom = pos[i + 1] - pos[i]
    t = denom == 0 ? 0.0 : (s - pos[i]) / denom
    return ext[i] + t * (ext[i + 1] - ext[i])
end

function _clip_one_profile(profile, axis, sign, openings)
    profile === nothing && return nothing
    pos = copy(profile.positions)
    ext = [_extent_at(profile, s) for s in pos]
    for poly in openings
        for p in poly
            s = _axis_project(axis, p)
            s === nothing && continue
            s = clamp(s, 0.0, 1.0)
            push!(pos, s)
            push!(ext, _extent_at(profile, s))
        end
    end
    order = sortperm(pos)
    pos = pos[order]
    ext = ext[order]
    kept_pos = Float64[pos[1]]
    kept_ext = Float64[ext[1]]
    for i in 2:length(pos)
        if pos[i] - kept_pos[end] < 1e-6
            kept_ext[end] = min(kept_ext[end], ext[i])
        else
            push!(kept_pos, pos[i])
            push!(kept_ext, ext[i])
        end
    end
    for i in eachindex(kept_pos)
        x, y, nx, ny = _axis_frame(axis, kept_pos[i], sign)
        c = _side_clearance(x, y, nx, ny, openings)
        isfinite(c) && (kept_ext[i] = min(kept_ext[i], max(c, 0.0)))
    end
    kept_pos[1] = 0.0
    kept_pos[end] = 1.0
    return SideExtentProfile(kept_pos, kept_ext)
end

function _clip_profiles_at_openings(struc, verts, seg_len_m, left, right)
    skel = struc.skeleton
    (isempty(skel.openings) || isempty(verts)) && return (left, right)
    level = story_index_at(skel, vertex_coords(skel, first(verts)).z)
    level === nothing && return (left, right)
    openings = [op.loop for op in skel.openings if op.story == level]
    isempty(openings) && return (left, right)
    axis = _beam_plan_axis(struc, verts, seg_len_m)
    return (_clip_one_profile(left, axis, 1.0, openings),
            _clip_one_profile(right, axis, -1.0, openings))
end

