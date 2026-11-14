# =============================================================================
# ACI 318-11 §11.11.6 — openings near a slab-column connection
# =============================================================================
#
# When an opening is closer to the reaction area than 10 times the slab
# thickness, or (for a flat slab) lies in a column strip, the part of the
# critical-section perimeter enclosed by the tangents from the column centroid
# to the opening is ineffective.
#
# ACI 318-11 §11.11.6, §11.11.6.1 (corpus: aci-318-11, page 209). Shearheads
# (§11.11.6.2, half of that perimeter) are not modelled.

"""Plan coordinates of a length pair, in metres."""
_opening_xy(p) = (Float64(ustrip(u"m", p[1])), Float64(ustrip(u"m", p[2])))

function _opening_inside(x, y, poly)
    inside = false
    n = length(poly)
    j = n
    for i in 1:n
        xi, yi = poly[i]
        xj, yj = poly[j]
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi + 1e-30) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

function _dist_point_seg(px, py, ax, ay, bx, by)
    ex, ey = bx - ax, by - ay
    L2 = ex * ex + ey * ey
    L2 <= 0 && return hypot(px - ax, py - ay)
    t = clamp(((px - ax) * ex + (py - ay) * ey) / L2, 0.0, 1.0)
    return hypot(px - (ax + t * ex), py - (ay + t * ey))
end

"""Minimum distance between two plan polygons. Zero when one meets or contains the other."""
function _polygon_gap(a, b)
    (isempty(a) || isempty(b)) && return Inf
    for (x, y) in a
        _opening_inside(x, y, b) && return 0.0
    end
    for (x, y) in b
        _opening_inside(x, y, a) && return 0.0
    end
    best = Inf
    for (px, py) in a, i in eachindex(b)
        q = b[i == length(b) ? 1 : i + 1]
        best = min(best, _dist_point_seg(px, py, b[i][1], b[i][2], q[1], q[2]))
    end
    for (px, py) in b, i in eachindex(a)
        q = a[i == length(a) ? 1 : i + 1]
        best = min(best, _dist_point_seg(px, py, a[i][1], a[i][2], q[1], q[2]))
    end
    return best
end

"""
    opening_reaches_column(opening, reaction, h; flat_slab=false, in_column_strip=false)

`opening` and `reaction` are plan polygons in metres. `h` is the slab thickness.

ACI 318-11 §11.11.6 (corpus: aci-318-11, page 209): the perimeter is reduced
when the opening is less than `10h` from the reaction area, and also when a
flat-slab opening lies in a column strip.
"""
function opening_reaches_column(opening, reaction, h::Length;
                               flat_slab::Bool = false,
                               in_column_strip::Bool = false)
    gap = _polygon_gap(opening, reaction)
    gap < 10.0 * ustrip(u"m", h) - 1e-9 && return true
    return flat_slab && in_column_strip
end

"""Smallest arc, as `(start, span)`, covering every angle."""
function _covering_arc(angles)
    a = sort(unique(mod.(angles, 2π)))
    length(a) == 1 && return (a[1], 0.0)
    gaps = [a[i + 1] - a[i] for i in 1:length(a)-1]
    push!(gaps, a[1] + 2π - a[end])
    k = argmax(gaps)
    start = k == length(a) ? a[1] : a[k + 1]
    return (start, 2π - gaps[k])
end

_in_arc(θ, start, span) = mod(θ - start, 2π) <= span + 1e-9

"""Parameter where the ray from `c` at `angle` crosses segment `a`–`b`, or `nothing`."""
function _ray_segment_t(c, angle, a, b)
    dx, dy = cos(angle), sin(angle)
    ex, ey = b[1] - a[1], b[2] - a[2]
    det = dx * ey - dy * ex
    abs(det) < 1e-14 && return nothing
    t = ((a[1] - c[1]) * ey - (a[2] - c[2]) * ex) / det
    s = ((a[1] - c[1]) * dy - (a[2] - c[2]) * dx) / det
    return (t > 1e-9 && 0.0 < s < 1.0) ? s : nothing
end

"""
    opening_reduced_perimeter(points, closed, openings, reaction, h; kwargs...)
        -> Union{Nothing, NamedTuple}

The critical-section perimeter with the §11.11.6.1 ineffective parts removed.
`points` are `(Length, Length)`. `openings` and `reaction` are plan polygons
in metres, in that same frame. `origin` is the centroid the tangents are drawn
from (ACI 318-11 §11.11.6.1, corpus: aci-318-11, page 209): the column centre,
or the drop centroid when the reaction area is the drop panel.

`strip_test(opening) -> Bool` decides the column-strip trigger one opening at
a time. `in_column_strip` is the same answer for every opening.

Returns `nothing` when no opening reaches the reaction area. Otherwise
`(points, segments)`: `segments` are index pairs into `points` and do not close
across a removed part.
"""
function opening_reduced_perimeter(points, closed, openings, reaction, h::Length;
                                  flat_slab::Bool = false,
                                  in_column_strip::Bool = false,
                                  origin::NTuple{2, Float64} = (0.0, 0.0),
                                  strip_test = nothing)
    reaches = []
    for op in openings
        in_strip = strip_test === nothing ? in_column_strip : strip_test(op)
        opening_reaches_column(op, reaction, h;
            flat_slab = flat_slab, in_column_strip = in_strip) && push!(reaches, op)
    end
    isempty(reaches) && return nothing

    c = origin
    arcs = Tuple{Float64, Float64}[]
    for op in reaches
        any(p -> hypot(p[1] - c[1], p[2] - c[2]) < 1e-9, op) && continue
        angs = [atan(p[2] - c[2], p[1] - c[1]) for p in op]
        push!(arcs, _covering_arc(angs))
    end
    isempty(arcs) && return nothing

    xy = [_opening_xy(p) for p in points]
    n = length(xy)
    edges = [(i, i == n ? 1 : i + 1) for i in 1:n]
    closed || pop!(edges)

    kept = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    for (i, j) in edges
        a, b = xy[i], xy[j]
        cuts = Float64[0.0, 1.0]
        for (start, span) in arcs
            for endang in (start, start + span)
                s = _ray_segment_t(c, endang, a, b)
                s === nothing || push!(cuts, s)
            end
        end
        sort!(cuts)
        uniq = Float64[cuts[1]]
        for s in cuts
            s - uniq[end] > 1e-8 && push!(uniq, s)
        end
        for k in 1:length(uniq)-1
            s0, s1 = uniq[k], uniq[k + 1]
            s1 - s0 < 1e-8 && continue
            mid = ((a[1] + (s0 + s1) / 2 * (b[1] - a[1])),
                   (a[2] + (s0 + s1) / 2 * (b[2] - a[2])))
            θ = atan(mid[2] - c[2], mid[1] - c[1])
            enclosed = any(arc -> _in_arc(θ, arc[1], arc[2]), arcs)
            enclosed && continue
            p0 = (a[1] + s0 * (b[1] - a[1]), a[2] + s0 * (b[2] - a[2]))
            p1 = (a[1] + s1 * (b[1] - a[1]), a[2] + s1 * (b[2] - a[2]))
            push!(kept, (p0, p1))
        end
    end
    isempty(kept) && throw(ArgumentError(
        "ACI 318-11 §11.11.6 removes the whole critical perimeter; the opening surrounds the column."))

    pts = Tuple{typeof(points[1][1]), typeof(points[1][2])}[]
    segs = Tuple{Int, Int}[]
    for (a, b) in kept
        push!(pts, (a[1] * u"m", a[2] * u"m"))
        ia = length(pts)
        push!(pts, (b[1] * u"m", b[2] * u"m"))
        push!(segs, (ia, length(pts)))
    end
    return (points = pts, segments = segs)
end

_rot2(x, y, ang) = (x * cos(ang) - y * sin(ang), x * sin(ang) + y * cos(ang))

"""Unit vector. A zero vector falls back to global +x."""
function _unit_axis(ax)
    L = hypot(ax[1], ax[2])
    return L < 1e-12 ? (1.0, 0.0) : (ax[1] / L, ax[2] / L)
end

"""Rotate length-pairs about the origin by `ang` (plan x, counterclockwise)."""
function _rotate_lengths(pts, ang)
    T = typeof(pts[1][1])
    out = Tuple{T, T}[]
    for p in pts
        xr, yr = _rot2(ustrip(u"m", p[1]), ustrip(u"m", p[2]), ang)
        push!(out, (xr * u"m", yr * u"m"))
    end
    return out
end

"""
    plan_unbalanced_moments(M_span, M_perp, span_axis) -> (Mux, Muy)

Moments for [`punching_stress_general`](@ref) in plan axes.

`M_span` drives stress along `span_axis` (the closed-form `Mux`). `M_perp`
drives stress along the left-hand normal (the closed-form `Muy`). The general
engine names moments by the axis they are about, so along global x the two
are swapped (ACI 421.1R-99 Eq. 3.2).
"""
function plan_unbalanced_moments(M_span, M_perp, span_axis)
    ux, uy = _unit_axis(span_axis)
    px, py = -uy, ux
    return (M_span * uy + M_perp * py, M_span * ux + M_perp * px)
end

"""Column rectangle, metres, centred on the origin and rotated by `ang`."""
function _column_rect_m(c1::Length, c2::Length, ang::Float64)
    hx, hy = ustrip(u"m", c1) / 2, ustrip(u"m", c2) / 2
    return [_rot2(x, y, ang) for (x, y) in ((-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy))]
end

"""
Critical section and column outline in plan axes, origin at the column centre.

`ang` is the plan angle of local +x (`c1` after an edge swap). A circular
column uses the ring of diameter `c1 + d`.
"""
function column_plan_section(c1::Length, c2::Length, d::Length, position::Symbol,
                             ang::Float64; circular::Bool = false)
    if circular
        pts = circular_critical_section(c1, d)
        r = ustrip(u"m", c1) / 2
        n = 32
        reaction = [_rot2(r, 0.0, 2π * k / n) for k in 0:(n - 1)]
        return pts, true, reaction
    end
    pts, closed = rectangular_critical_section(c1, c2, d; position = position)
    return _rotate_lengths(pts, ang), closed, _column_rect_m(c1, c2, ang)
end

"""True when `opening` meets the column-strip cross of half-width `half`."""
function opening_in_column_strip(opening, half::Length)
    w = ustrip(u"m", half)
    w <= 0 && return false
    band = [(-w, -1e6), (w, -1e6), (w, 1e6), (-w, 1e6)]
    _polygon_gap(opening, band) == 0.0 && return true
    band = [(-1e6, -w), (1e6, -w), (1e6, w), (-1e6, w)]
    return _polygon_gap(opening, band) == 0.0
end

"""
True when `opening` meets a column strip of one of the panels framing the column.

`strips` are `(half_width, panel)` in the same frame as `opening`. `panel` is
the panel polygon, or `nothing` for a cross that is not clipped to a panel.
The cross is aligned with `span_axis` (ACI 318-11 §13.2.1, page 244).
"""
function opening_meets_column_strips(opening, strips, span_axis)
    isempty(strips) && return false
    ux, uy = _unit_axis(span_axis)
    into(p) = (p[1] * ux + p[2] * uy, -p[1] * uy + p[2] * ux)
    op = [into(p) for p in opening]
    for (half, poly) in strips
        if poly !== nothing
            _polygon_gap(op, [into(p) for p in poly]) > 1e-8 && continue
        end
        opening_in_column_strip(op, half) && return true
    end
    return false
end

function _translate_openings(openings, xy)
    cx, cy = Float64(xy[1]), Float64(xy[2])
    out = Vector{NTuple{2, Float64}}[]
    for op in openings
        push!(out, [(Float64(p[1]) - cx, Float64(p[2]) - cy) for p in op])
    end
    return out
end

"""Floor `|M| − Vu·|e|` at zero. ACI 318-11 R11.11.7.2 (corpus: aci-318-11, page 210)."""
function _shift_moment(M, Vu, e)
    mag = abs(ustrip(u"N*m", M)) - abs(ustrip(u"N*m", Vu * e))
    return sign(ustrip(u"N*m", M)) * max(mag, 0.0) * u"N*m"
end

"""
Punching check on a section that may have had §11.11.6 applied.

`points` and `reaction` share an origin at the column centre. `openings` are
absolute plan polygons; `column_xy` is subtracted. `M_span` and `M_perp` are
the closed-form moments (stress along the span axis and its left normal).

Returns `nothing` when no opening reaches the reaction area.
"""
function punching_check_reduced(points, closed, reaction, openings, column_xy,
                               h::Length, fc::Pressure, Vu::Force,
                               M_span, M_perp, d::Length, c1::Length, c2::Length;
                               origin::NTuple{2, Float64} = (0.0, 0.0),
                               flat_slab::Bool = false,
                               column_strips = nothing,
                               column_strip_half::Union{Nothing, Length} = nothing,
                               span_axis = (1.0, 0.0),
                               αs::Int = 40,
                               shape::Symbol = :rectangular,
                               λ::Float64 = 1.0, λs::Float64 = 1.0, ϕ::Float64 = 0.75,
                               Mub_out = M_span)
    (openings === nothing || column_xy === nothing || isempty(openings)) && return nothing
    local_ops = _translate_openings(openings, column_xy)
    strips = column_strips === nothing ?
        (column_strip_half === nothing ? Any[] : Any[(column_strip_half, nothing)]) :
        column_strips
    # Strip polygons are stored in absolute plan metres.
    local_strips = Any[]
    cx, cy = Float64(column_xy[1]), Float64(column_xy[2])
    for (half, poly) in strips
        poly_l = poly === nothing ? nothing :
            [(Float64(p[1]) - cx, Float64(p[2]) - cy) for p in poly]
        push!(local_strips, (half, poly_l))
    end
    reduced = opening_reduced_perimeter(points, closed, local_ops, reaction, h;
        flat_slab = flat_slab, origin = origin,
        strip_test = op -> opening_meets_column_strips(op, local_strips, span_axis))
    reduced === nothing && return nothing

    props = critical_section_properties(reduced.points, d; segments = reduced.segments)
    Mux_g, Muy_g = plan_unbalanced_moments(M_span, M_perp, span_axis)
    # Mux is about x (stress in y) and shifts with the y-offset of the centroid.
    res = punching_check_general(Vu, _shift_moment(Mux_g, Vu, props.yc),
                                 _shift_moment(Muy_g, Vu, props.xc), d, fc, reduced.points;
                                 closed = false, segments = reduced.segments,
                                 β = punching_β(c1, c2; shape = shape),
                                 αs = αs, λ = λ, λs = λs, ϕ = ϕ)
    return (ok = res.ok, ratio = res.utilization, vu = res.vu, φvc = res.ϕvc,
            b0 = res.b0, Jc = res.J1, Mub = Mub_out)
end

# ── Drop-panel outline (the reaction area at the outer critical section) ──

function _clip_segment(a, b, point, normal)
    ga = (a[1] - point[1]) * normal[1] + (a[2] - point[2]) * normal[2]
    gb = (b[1] - point[1]) * normal[1] + (b[2] - point[2]) * normal[2]
    t = ga / (ga - gb)
    return (a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]))
end

"""Keep the part of `poly` on the inward side of one half-plane."""
function _clip_halfplane(poly, point, normal)
    out = NTuple{2, Float64}[]
    m = length(poly)
    for i in 1:m
        a = poly[i]
        b = poly[mod1(i + 1, m)]
        ga = (a[1] - point[1]) * normal[1] + (a[2] - point[2]) * normal[2]
        gb = (b[1] - point[1]) * normal[1] + (b[2] - point[2]) * normal[2]
        ain = ga >= -1e-9
        bin = gb >= -1e-9
        if ain && bin
            push!(out, b)
        elseif ain && !bin
            push!(out, _clip_segment(a, b, point, normal))
        elseif !ain && bin
            push!(out, _clip_segment(a, b, point, normal))
            push!(out, b)
        end
    end
    return out
end

_plane_value(p, plane) = (p[1] - plane[1][1]) * plane[2][1] + (p[2] - plane[1][2]) * plane[2][2]

function _on_plane(p, plane, tol)
    abs(_plane_value(p, plane)) <= tol
end

function _poly_centroid(poly)
    A = 0.0
    cx = 0.0
    cy = 0.0
    n = length(poly)
    for i in 1:n
        x1, y1 = poly[i]
        x2, y2 = poly[mod1(i + 1, n)]
        cross = x1 * y2 - x2 * y1
        A += cross
        cx += (x1 + x2) * cross
        cy += (y1 + y2) * cross
    end
    abs(A) < 1e-18 && return (sum(p[1] for p in poly) / n, sum(p[2] for p in poly) / n)
    return (cx / (3A), cy / (3A))
end

function _shoelace(poly)
    A = 0.0
    n = length(poly)
    for i in 1:n
        x1, y1 = poly[i]
        x2, y2 = poly[mod1(i + 1, n)]
        A += x1 * y2 - x2 * y1
    end
    return abs(A) / 2
end

"""Intersection of two free-edge lines. `nothing` when the lines are parallel."""
function _plane_meet(pl1, pl2)
    p1, n1 = pl1
    p2, n2 = pl2
    d1 = (-n1[2], n1[1])
    denom = d1[1] * n2[1] + d1[2] * n2[2]
    abs(denom) < 1e-14 && return nothing
    t = -((p1[1] - p2[1]) * n2[1] + (p1[2] - p2[2]) * n2[2]) / denom
    return (p1[1] + t * d1[1], p1[2] + t * d1[2])
end

"""
Area inside the critical section, in square metres.

A closed section is the offset rectangle. An open one is closed along the free
edges, inserting the slab corner where two free edges meet, so the area is the
`b1·b2` rectangle of ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200).
"""
function _drop_section_area(section, closed, planes)
    poly = collect(section)
    if !closed && length(poly) >= 2
        tol = 1e-6
        starts = [pl for pl in planes if _on_plane(poly[1], pl, tol)]
        ends = [pl for pl in planes if _on_plane(poly[end], pl, tol)]
        for pa in starts, pb in ends
            (pa[1] == pb[1] && pa[2] == pb[2]) && continue
            corner = _plane_meet(pa, pb)
            corner === nothing && continue
            any(p -> hypot(p[1] - corner[1], p[2] - corner[2]) < tol, poly) && continue
            push!(poly, corner)
            break
        end
    end
    return _shoelace(poly)
end

function _line_hit(p, dp, q, dq)
    det = dp[1] * dq[2] - dp[2] * dq[1]
    abs(det) < 1e-14 && return nothing
    t = ((q[1] - p[1]) * dq[2] - (q[2] - p[2]) * dq[1]) / det
    return (p[1] + t * dp[1], p[2] + t * dp[2])
end

"""
Critical section at `d/2` outside a convex drop outline.

Edges that lie on a slab free-edge plane are omitted. The kept edges are
moved out by `d/2` and run back to the free-edge plane, so the perimeter
stops where the slab stops (ACI 318-11 §11.11.1.2, corpus: aci-318-11, page 200).
"""
function _offset_drop_section(poly, d::Length, planes)
    dh = ustrip(u"m", d) / 2
    n = length(poly)
    n < 3 && throw(ArgumentError("drop outline needs at least 3 vertices"))
    tol = 1e-8
    free = Bool[]
    for i in 1:n
        a = poly[i]
        b = poly[mod1(i + 1, n)]
        push!(free, any(pl -> _on_plane(a, pl, tol) && _on_plane(b, pl, tol), planes))
    end
    # Outward normal of a CCW edge is the right-hand normal.
    function offset_line(i)
        a = poly[i]
        b = poly[mod1(i + 1, n)]
        ex, ey = b[1] - a[1], b[2] - a[2]
        L = hypot(ex, ey)
        L < 1e-12 && return nothing
        nx, ny = ey / L, -ex / L
        p = (a[1] + nx * dh, a[2] + ny * dh)
        return (p, (ex, ey))
    end
    if all(!, free)
        verts = NTuple{2, Float64}[]
        lines = [offset_line(i) for i in 1:n]
        for i in 1:n
            li = lines[i]
            lj = lines[mod1(i + 1, n)]
            (li === nothing || lj === nothing) && continue
            hit = _line_hit(li[1], li[2], lj[1], lj[2])
            hit === nothing || push!(verts, hit)
        end
        return verts, true
    end
    # One run of resisting edges, starting just after a free edge.
    i0 = findfirst(identity, free)
    i = i0
    while free[mod1(i, n)]
        i += 1
        i - i0 > n && break
    end
    start = mod1(i, n)
    kept = Int[]
    j = start
    while !free[j] && length(kept) < n
        push!(kept, j)
        j = mod1(j + 1, n)
    end
    verts = NTuple{2, Float64}[]
    # The free edge before the run supplies the plane the first leg meets.
    prev = mod1(start - 1, n)
    plane_of(edge) = begin
        a = poly[edge]
        for pl in planes
            _on_plane(a, pl, tol) && _on_plane(poly[mod1(edge + 1, n)], pl, tol) && return pl
        end
        return nothing
    end
    function meet_plane(line, plane)
        plane === nothing && return line[1]
        # Plane: (x - p)·n = 0, direction along the plane is (-n_y, n_x).
        p, nrm = plane
        dir = (-nrm[2], nrm[1])
        hit = _line_hit(line[1], line[2], p, dir)
        return hit === nothing ? line[1] : hit
    end
    first = offset_line(kept[1])
    first === nothing && throw(ArgumentError("drop edge has zero length"))
    push!(verts, meet_plane(first, plane_of(prev)))
    for k in 1:length(kept)-1
        li = offset_line(kept[k])
        lj = offset_line(kept[k + 1])
        (li === nothing || lj === nothing) && continue
        hit = _line_hit(li[1], li[2], lj[1], lj[2])
        hit === nothing || push!(verts, hit)
    end
    last = offset_line(kept[end])
    last === nothing && throw(ArgumentError("drop edge has zero length"))
    nxt = mod1(kept[end] + 1, n)
    push!(verts, meet_plane(last, plane_of(nxt)))
    return verts, false
end

"""
    drop_outline(c1, c2, a1, a2, position, column_θ, span_axis; swapped=false)
        -> NamedTuple

The drop panel in plan. `polygon` and `centroid` are metres with the column
centre at the origin.

The rectangle is `±a1` along `span_axis` and `±a2` along its left normal.
An edge or corner column is clipped at the free edge, which passes through
the column face, so the drop stops where the slab stops. That polygon is the
region the shell thickens, and the outline the critical section is offset
from (ACI 318-11 §11.11.1.2, corpus: aci-318-11, page 200; drop extents
ACI 318-11 §13.2.5).
"""
function drop_outline(c1::Length, c2::Length, a1::Length, a2::Length,
                     position::Symbol, column_θ::Float64, span_axis;
                     swapped::Bool = false)
    φ = atan(_unit_axis(span_axis)[2], _unit_axis(span_axis)[1])
    ax, ay = ustrip(u"m", a1), ustrip(u"m", a2)
    rect = [_rot2(x, y, φ) for (x, y) in ((-ax, -ay), (ax, -ay), (ax, ay), (-ax, ay))]
    # After a swap, local +x (perpendicular to the free edge) is the named c2.
    oc1 = swapped ? c2 : c1
    oc2 = swapped ? c1 : c2
    ang = column_θ + (swapped ? π / 2 : 0.0)
    hx, hy = ustrip(u"m", oc1) / 2, ustrip(u"m", oc2) / 2
    planes = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    if position === :edge || position === :corner
        push!(planes, (_rot2(hx, 0.0, ang), _rot2(-1.0, 0.0, ang)))
    end
    if position === :corner
        push!(planes, (_rot2(0.0, hy, ang), _rot2(0.0, -1.0, ang)))
    end
    polygon = rect
    for (pt, nrm) in planes
        polygon = _clip_halfplane(polygon, pt, nrm)
    end
    length(polygon) < 3 && throw(ArgumentError(
        "the drop panel lies outside the slab; the free edges remove it"))
    return (polygon = polygon, centroid = _poly_centroid(polygon), planes = planes)
end

"""
    drop_plan_section(c1, c2, a1, a2, d, position, column_θ, span_axis; swapped=false)
        -> NamedTuple

`area` is the area inside the critical section (the `b1·b2` used to remove
`qu·A` from the shear). It closes an open perimeter along the free edges.

The drop panel is [`drop_outline`](@ref). The critical section is `d/2`
outside that outline. `centroid` is the centroid of the clipped drop, in the
same frame (column centre at the origin).

An edge or corner column whose drop crosses a free edge has that centroid off
the column centre. `h` for the `10h` test at this section is the slab thickness
outside the drop.
"""
function drop_plan_section(c1::Length, c2::Length, a1::Length, a2::Length, d::Length,
                          position::Symbol, column_θ::Float64, span_axis;
                          swapped::Bool = false)
    outline = drop_outline(c1, c2, a1, a2, position, column_θ, span_axis; swapped = swapped)
    reaction = outline.polygon
    section, closed = _offset_drop_section(reaction, d, outline.planes)
    pts = [(p[1] * u"m", p[2] * u"m") for p in section]
    return (points = pts, closed = closed, reaction = reaction,
            centroid = outline.centroid,
            area = _drop_section_area(section, closed, outline.planes) * u"m^2")
end

"""
Direct-shear `b0` of a drop-edge section after §11.11.6, or `nothing` when no
opening reaches the drop.

`h` is the slab thickness outside the drop. The tangents are drawn from the
drop centroid (ACI 318-11 §11.11.6.1, corpus: aci-318-11, page 209).
"""
function drop_opening_b0(c1::Length, c2::Length, a1::Length, a2::Length, d::Length,
                        h::Length, position::Symbol, openings, column_xy;
                        column_θ::Float64 = 0.0, span_axis = (1.0, 0.0),
                        swapped::Bool = false, flat_slab::Bool = false,
                        column_strips = nothing,
                        column_strip_half::Union{Nothing, Length} = nothing)
    (openings === nothing || column_xy === nothing || isempty(openings)) && return nothing
    sec = drop_plan_section(c1, c2, a1, a2, d, position, column_θ, span_axis;
                           swapped = swapped)
    pts, closed, reaction, origin = sec.points, sec.closed, sec.reaction, sec.centroid
    local_ops = _translate_openings(openings, column_xy)
    strips = column_strips === nothing ?
        (column_strip_half === nothing ? Any[] : Any[(column_strip_half, nothing)]) :
        column_strips
    cx, cy = Float64(column_xy[1]), Float64(column_xy[2])
    local_strips = Any[]
    for (half, poly) in strips
        poly_l = poly === nothing ? nothing :
            [(Float64(p[1]) - cx, Float64(p[2]) - cy) for p in poly]
        push!(local_strips, (half, poly_l))
    end
    reduced = opening_reduced_perimeter(pts, closed, local_ops, reaction, h;
        flat_slab = flat_slab, origin = origin,
        strip_test = op -> opening_meets_column_strips(op, local_strips, span_axis))
    reduced === nothing && return nothing
    props = critical_section_properties(reduced.points, d; segments = reduced.segments)
    return props.b0
end
