# Plan geometry for a wall footing.
#
# A straight wall is one rectangle. An L or a T is the union of one rectangle
# per leg, overlap counted once. Soil pressure on that shape is linear, from
# statics (ACI 336.2R §3.2 and §4.2, corpus: aci-336-combined-footings-mats,
# pages 6–7):
#
#     q = P/A + P·e_x·(x − c_x)/I_yy + P·e_y·(y − c_y)/I_xx
#
# which is Eq. (3-1) when the shape is a rectangle and the eccentricity is
# along one axis. The kernel below strips to metres and newtons.

const _WALL_JOIN_M = 1e-3

struct _Aabb
    x0::Float64
    x1::Float64
    y0::Float64
    y1::Float64
end

_m(x) = ustrip(u"m", x)
_n(x) = ustrip(u"N", x)

"""Centerline length of one wall leg."""
function _leg_length_m(leg::WallLineDemand)
    dx = _m(leg.p2[1]) - _m(leg.p1[1])
    dy = _m(leg.p2[2]) - _m(leg.p1[2])
    return hypot(dx, dy)
end

"""Plan position of a station on a leg, in metres."""
function _station_xy_m(leg::WallLineDemand, s)
    L = _leg_length_m(leg)
    L > 0 || return (_m(leg.p1[1]), _m(leg.p1[2]))
    t = _m(s) / L
    x = _m(leg.p1[1]) + t * (_m(leg.p2[1]) - _m(leg.p1[1]))
    y = _m(leg.p1[2]) + t * (_m(leg.p2[2]) - _m(leg.p1[2]))
    return (x, y)
end

function _on_segment(px, py, x1, y1, x2, y2; tol = _WALL_JOIN_M)
    dx, dy = x2 - x1, y2 - y1
    L2 = dx * dx + dy * dy
    L2 <= tol * tol && return hypot(px - x1, py - y1) <= tol
    t = ((px - x1) * dx + (py - y1) * dy) / L2
    span = tol / sqrt(L2)
    if t < -span || t > 1 + span
        return false
    end
    t = clamp(t, 0.0, 1.0)
    return hypot(px - (x1 + t * dx), py - (y1 + t * dy)) <= tol
end

"""
Throw unless the legs are one connected group, not a closed cell, and no
corner reaction is listed on two legs.
"""
function _validate_wall_legs(legs::Vector{<:WallLineDemand})
    isempty(legs) && throw(ArgumentError("A wall footing needs at least one leg"))
    for leg in legs
        isempty(leg.samples) && throw(ArgumentError(
            "Wall leg $(leg.idx) has no base reactions"))
        L = _leg_length_m(leg)
        L < _WALL_JOIN_M && throw(ArgumentError(
            "Wall leg $(leg.idx) is shorter than $(_WALL_JOIN_M) m"))
        _m(leg.tw) <= 0 && throw(ArgumentError("Wall leg $(leg.idx) has no thickness"))
        _m(leg.hw) < 0 && throw(ArgumentError("Wall leg $(leg.idx) has a negative height"))
        for smp in leg.samples
            s = _m(smp.s)
            (s < -_WALL_JOIN_M || s > L + _WALL_JOIN_M) && throw(ArgumentError(
                "Wall leg $(leg.idx) has a reaction at $(s) m, outside 0 to $(L) m"))
        end
    end
    Ps = sum(_n(smp.Ps) for leg in legs for smp in leg.samples)
    Ps <= 0 && throw(ArgumentError(
        "Wall footing service resultant is not compression " *
        "(ACI 318-11 §15.2.2, corpus: aci-318-11, page 271)"))

    # An endpoint that lands on another leg is a joint. Listing the reaction
    # there on both legs would count it twice.
    for (i, a) in enumerate(legs)
        ax1, ay1 = _m(a.p1[1]), _m(a.p1[2])
        ax2, ay2 = _m(a.p2[1]), _m(a.p2[2])
        for smp in a.samples
            sx, sy = _station_xy_m(a, smp.s)
            for (j, b) in enumerate(legs)
                j == i && continue
                bx1, by1 = _m(b.p1[1]), _m(b.p1[2])
                bx2, by2 = _m(b.p2[1]), _m(b.p2[2])
                _on_segment(sx, sy, bx1, by1, bx2, by2) || continue
                for other in b.samples
                    ox, oy = _station_xy_m(b, other.s)
                    hypot(sx - ox, sy - oy) <= _WALL_JOIN_M && throw(ArgumentError(
                        "The reaction at ($(sx), $(sy)) m is on legs $(a.idx) and " *
                        "$(b.idx). A shared corner belongs to one leg."))
                end
            end
        end
        if length(legs) > 1
            dx, dy = abs(ax2 - ax1), abs(ay2 - ay1)
            min(dx, dy) > _WALL_JOIN_M && throw(ArgumentError(
                "Wall leg $(a.idx) is not axis-aligned. A corner footing is the " *
                "union of axis-aligned legs (ACI 336.2R §4.2)."))
        end
    end

    # Graph: split every leg at the joints that land on it. A cycle is a cell.
    adj = Dict{NTuple{2, Int}, Vector{NTuple{2, Int}}}()
    _node(x, y) = (round(Int, x / _WALL_JOIN_M), round(Int, y / _WALL_JOIN_M))
    function _link(a, b)
        a == b && return
        push!(get!(adj, a, NTuple{2, Int}[]), b)
        push!(get!(adj, b, NTuple{2, Int}[]), a)
    end
    for (i, leg) in enumerate(legs)
        x1, y1 = _m(leg.p1[1]), _m(leg.p1[2])
        x2, y2 = _m(leg.p2[1]), _m(leg.p2[2])
        pts = [(0.0, x1, y1), (1.0, x2, y2)]
        for (j, other) in enumerate(legs)
            j == i && continue
            for ep in (other.p1, other.p2)
                ex, ey = _m(ep[1]), _m(ep[2])
                _on_segment(ex, ey, x1, y1, x2, y2) || continue
                dx, dy = x2 - x1, y2 - y1
                L2 = dx * dx + dy * dy
                t = ((ex - x1) * dx + (ey - y1) * dy) / L2
                push!(pts, (clamp(t, 0.0, 1.0), ex, ey))
            end
        end
        sort!(pts; by = first)
        for k in 1:length(pts) - 1
            _link(_node(pts[k][2], pts[k][3]), _node(pts[k + 1][2], pts[k + 1][3]))
        end
    end
    for k in keys(adj)
        adj[k] = unique(adj[k])
    end
    seen = Set{NTuple{2, Int}}()
    parent = Dict{NTuple{2, Int}, NTuple{2, Int}}()
    function _dfs(v)
        push!(seen, v)
        for w in get(adj, v, NTuple{2, Int}[])
            if w in seen
                # The edge back to the node we came from is not a cell.
                # A root has no parent; `get` returns `w` and the test passes.
                get(parent, v, w) == w || throw(ArgumentError(
                    "These grade walls close a cell. A closed cell is a mat, " *
                    "not a wall footing (ACI 318-11 §15.10.1, corpus: " *
                    "aci-318-11, page 277)."))
            else
                parent[w] = v
                _dfs(w)
            end
        end
    end
    roots = collect(keys(adj))
    isempty(roots) && return legs
    _dfs(first(roots))
    length(seen) == length(adj) || throw(ArgumentError(
        "Wall footing legs do not all meet. Each connected group is its own footing."))
    return legs
end

_aabb_intersect(a::_Aabb, b::_Aabb) = begin
    x0, x1 = max(a.x0, b.x0), min(a.x1, b.x1)
    y0, y1 = max(a.y0, b.y0), min(a.y1, b.y1)
    (x1 - x0) <= 1e-12 || (y1 - y0) <= 1e-12 ? nothing : _Aabb(x0, x1, y0, y1)
end

"""Signed rectangle pieces of a union, by inclusion-exclusion."""
function _ie_terms(rects::Vector{_Aabb})
    n = length(rects)
    terms = Tuple{Int, _Aabb}[]
    for mask in 1:(1 << n) - 1
        rect = nothing
        ok = true
        for i in 1:n
            (mask >> (i - 1)) & 1 == 0 && continue
            rect = rect === nothing ? rects[i] : _aabb_intersect(rect, rects[i])
            if rect === nothing
                ok = false
                break
            end
        end
        ok || continue
        push!(terms, (isodd(count_ones(mask)) ? 1 : -1, rect))
    end
    return terms
end

function _rect_raw(r::_Aabb)
    x0, x1, y0, y1 = r.x0, r.x1, r.y0, r.y1
    w, h = x1 - x0, y1 - y0
    A = w * h
    sx = A * (x0 + x1) / 2
    sy = A * (y0 + y1) / 2
    sxx = h * (x1^3 - x0^3) / 3
    syy = w * (y1^3 - y0^3) / 3
    sxy = (x1^2 - x0^2) * (y1^2 - y0^2) / 4
    return (A = A, sx = sx, sy = sy, sxx = sxx, syy = syy, sxy = sxy)
end

"""Area, centroid, and centroidal second moments of a union of rectangles."""
function _union_section(rects::Vector{_Aabb})
    A = sx = sy = sxx = syy = sxy = 0.0
    for (sgn, r) in _ie_terms(rects)
        m = _rect_raw(r)
        A += sgn * m.A
        sx += sgn * m.sx
        sy += sgn * m.sy
        sxx += sgn * m.sxx
        syy += sgn * m.syy
        sxy += sgn * m.sxy
    end
    A > 0 || error("Wall footing contact area is zero")
    cx, cy = sx / A, sy / A
    Ixx = syy - A * cy^2
    Iyy = sxx - A * cx^2
    return (A = A, cx = cx, cy = cy, Ixx = Ixx, Iyy = Iyy)
end

"""Corners of the union, dropping corners buried inside another rectangle."""
function _union_vertices(rects::Vector{_Aabb})
    pts = NTuple{2, Float64}[]
    for (i, r) in enumerate(rects)
        for (x, y) in ((r.x0, r.y0), (r.x0, r.y1), (r.x1, r.y0), (r.x1, r.y1))
            buried = false
            for (j, o) in enumerate(rects)
                j == i && continue
                if x > o.x0 + 1e-9 && x < o.x1 - 1e-9 && y > o.y0 + 1e-9 && y < o.y1 - 1e-9
                    buried = true
                    break
                end
            end
            buried || push!(pts, (x, y))
        end
    end
    return pts
end

"""
`q = a + b (x − cx) + c (y − cy)` from a vertical resultant `P` at
`(rx, ry)`. ACI 336.2R §3.2 (page 6) for a rectangle; the same statics on
the union for an L or a T (§4.2, page 7).
"""
function _linear_pressure(P, rx, ry, sec)
    ex, ey = rx - sec.cx, ry - sec.cy
    sec.Iyy > 0 || error("Wall footing has no inertia about y")
    sec.Ixx > 0 || error("Wall footing has no inertia about x")
    return (a = P / sec.A, b = P * ex / sec.Iyy, c = P * ey / sec.Ixx,
            cx = sec.cx, cy = sec.cy, ex = ex, ey = ey)
end

_q_at(coeff, x, y) = coeff.a + coeff.b * (x - coeff.cx) + coeff.c * (y - coeff.cy)

"""True when an endpoint of `leg` is not on any other leg."""
function _end_is_free(legs, i, which)
    leg = legs[i]
    p = which == 1 ? leg.p1 : leg.p2
    px, py = _m(p[1]), _m(p[2])
    for (j, other) in enumerate(legs)
        j == i && continue
        x1, y1 = _m(other.p1[1]), _m(other.p1[2])
        x2, y2 = _m(other.p2[1]), _m(other.p2[2])
        _on_segment(px, py, x1, y1, x2, y2) && return false
    end
    return true
end

"""Rectangle of one leg. `oh1` and `oh2` are overhangs past p1 and p2, metres."""
function _leg_rectangle(leg::WallLineDemand, B_m, oh1, oh2)
    x1, y1 = _m(leg.p1[1]), _m(leg.p1[2])
    x2, y2 = _m(leg.p2[1]), _m(leg.p2[2])
    half = B_m / 2
    if abs(y2 - y1) <= abs(x2 - x1)
        y = (y1 + y2) / 2
        left_oh = x1 <= x2 ? oh1 : oh2
        right_oh = x1 <= x2 ? oh2 : oh1
        return _Aabb(min(x1, x2) - left_oh, max(x1, x2) + right_oh, y - half, y + half)
    else
        x = (x1 + x2) / 2
        bot_oh = y1 <= y2 ? oh1 : oh2
        top_oh = y1 <= y2 ? oh2 : oh1
        return _Aabb(x - half, x + half, min(y1, y2) - bot_oh, max(y1, y2) + top_oh)
    end
end

function _service_resultant_m(legs)
    Ps = rx = ry = 0.0
    for leg in legs
        for smp in leg.samples
            p = _n(smp.Ps)
            x, y = _station_xy_m(leg, smp.s)
            Ps += p
            rx += p * x
            ry += p * y
        end
    end
    return (Ps = Ps, x = rx / Ps, y = ry / Ps)
end

function _factored_resultant_m(legs)
    Pu = rx = ry = 0.0
    for leg in legs
        for smp in leg.samples
            p = _n(smp.Pu)
            x, y = _station_xy_m(leg, smp.s)
            Pu += p
            rx += p * x
            ry += p * y
        end
    end
    abs(Pu) > 0 || return (Pu = 0.0, x = 0.0, y = 0.0)
    return (Pu = Pu, x = rx / Pu, y = ry / Pu)
end

"""
Moment per unit length at the face of a centered wall under uniform `qu`.

ACI 318-11 §15.4.1 and §15.4.2(a) (corpus: aci-318-11, page 272). Each
projection is `(B − tw) / 2`, so the moment is `qu (B − tw)^2 / 8`.
"""
function _wall_projection_moment(qu::Pressure, B::Length, tw::Length)
    m = (B - tw) / 2
    m <= zero(m) && return zero(qu) * m^2
    return qu * m^2 / 2
end

"""
One-way shear per unit length at `d` from the wall face, uniform `qu`.

ACI 318-11 §15.5.2 (corpus: aci-318-11, page 273) locates the section at
the face, and §11.1.3.1 (page 166) reads the shear a distance `d` out from
that face. Zero when the projection is shorter than `d`.
"""
function _wall_projection_shear(qu::Pressure, B::Length, tw::Length, d::Length)
    lip = (B - tw) / 2 - d
    lip <= zero(lip) && return zero(qu) * lip
    return qu * lip
end

function _ceil_step(x_m, step_m)
    step_m <= 0 && return x_m
    n = ceil(x_m / step_m - 1e-9)
    return max(n, 1) * step_m
end

"""
Size the contact shape so the service pressure stays inside `[0, qa]`
(ACI 318-11 §15.2.2, page 271; ACI 336.2R Eq. (3-1) when the shape is a
rectangle). Returns rectangles, width, section, and the service pressure
coefficients. Refuses a resultant that cannot be brought inside the kern
by extending the free ends.
"""
function _size_wall_plan(legs::Vector{<:WallLineDemand}, soil::Soil;
                          step::Length = 3.0u"inch", max_iter::Int = 80)
    svc = _service_resultant_m(legs)
    qa = ustrip(u"Pa", soil.qa)
    step_m = _m(step)
    tw_max = maximum(_m(leg.tw) for leg in legs)
    # A straight wall has a closed form: lengthen the light end until the
    # centroid sits on the resultant, then take the width from Ps / (qa L).
    if length(legs) == 1
        return _size_straight_plan(legs[1], svc, qa, tw_max, step_m)
    end
    Lsum = sum(_leg_length_m(leg) for leg in legs)
    B = _ceil_step(max(tw_max, svc.Ps / (qa * Lsum)), step_m)
    ohs = [(0.0, 0.0) for _ in legs]
    free = [(_end_is_free(legs, i, 1), _end_is_free(legs, i, 2)) for i in eachindex(legs)]
    for _ in 1:max_iter
        rects = [_leg_rectangle(legs[i], B, ohs[i]...) for i in eachindex(legs)]
        sec = _union_section(rects)
        coeff = _linear_pressure(svc.Ps, svc.x, svc.y, sec)
        qs = [_q_at(coeff, x, y) for (x, y) in _union_vertices(rects)]
        qmin, qmax = extrema(qs)
        qmin >= -1.0 && qmax <= qa * (1 + 1e-6) &&
            return (straight = false, B = B, area = sec.A, along = sec.A / B,
                    x0 = 0.0, rects = rects, section = sec, service = coeff)
        if qmin < -1.0
            grown = _grow_light_end!(ohs, free, legs, sec, svc, step_m)
            grown || throw(ArgumentError(
                "The service resultant lifts an edge of this wall footing, and " *
                "there is no free end left to extend. ACI 336.2R Eq. (3-2) to " *
                "(3-4) (page 6) are for a rectangle; partial contact on an L " *
                "or a T is refused."))
        else
            B = _ceil_step(B + step_m, step_m)
        end
    end
    throw(ArgumentError(
        "Wall footing plan did not reach a service pressure inside 0 and qa " *
        "in $(max_iter) steps (ACI 318-11 §15.2.2)."))
end

function _grow_light_end!(ohs, free, legs, sec, svc, step_m)
    # Extending the end that points toward the resultant moves the centroid
    # toward the load.
    best = nothing
    best_score = 0.0
    for (i, leg) in enumerate(legs)
        x1, y1 = _m(leg.p1[1]), _m(leg.p1[2])
        x2, y2 = _m(leg.p2[1]), _m(leg.p2[2])
        L = hypot(x2 - x1, y2 - y1)
        ux, uy = (x2 - x1) / L, (y2 - y1) / L
        for (which, outward) in ((1, (-ux, -uy)), (2, (ux, uy)))
            free[i][which] || continue
            score = outward[1] * (svc.x - sec.cx) + outward[2] * (svc.y - sec.cy)
            if score > best_score + 1e-9
                best_score = score
                best = (i, which)
            end
        end
    end
    best === nothing && return false
    i, which = best
    oh = ohs[i]
    ohs[i] = which == 1 ? (oh[1] + step_m, oh[2]) : (oh[1], oh[2] + step_m)
    return true
end

"""Closed-form plan for one straight leg. Centroid on the service resultant."""
function _size_straight_plan(leg, svc, qa, tw_max, step_m)
    L = _leg_length_m(leg)
    sbar = 0.0
    for smp in leg.samples
        sbar += _n(smp.Ps) * _m(smp.s)
    end
    sbar /= svc.Ps
    sbar = clamp(sbar, 0.0, L)
    Lf = 2 * max(sbar, L - sbar)
    Lf = max(Lf, L)
    B = _ceil_step(max(tw_max, svc.Ps / (qa * Lf)), step_m)
    # Wall station 0 sits this far from the light end of the footing.
    # The rectangle is in that local frame: x along the wall, y across it.
    x0 = Lf / 2 - sbar
    half = B / 2
    local_rect = _Aabb(0.0, Lf, -half, half)
    sec = _union_section([local_rect])
    # Service resultant in local coordinates is (x0 + sbar, 0) = (Lf/2, 0).
    coeff = _linear_pressure(svc.Ps, Lf / 2, 0.0, sec)
    return (straight = true, B = B, area = B * Lf, along = Lf, x0 = x0,
            rects = [local_rect], section = sec, service = coeff)
end
