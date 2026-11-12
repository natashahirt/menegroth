# Plan and linear pressure for a wall strip. The footing file integrates
# these rectangles; this file builds them.
#
# Area from unfactored force and allowable pressure: ACI 318-11 §15.2.2
# (corpus: aci-318-11, page 271).
# Full-contact linear pressure: ACI 336.2R §3.2.1 Eq. (3-1) and §4.2
# (corpus: aci-336-combined-footings-mats, pages 6–7).

"""Axis-aligned footing rectangle, metres, `x0 < x1` and `y0 < y1`."""
struct _Aabb
    x0::Float64
    x1::Float64
    y0::Float64
    y1::Float64
end

_n(x) = Float64(ustrip(u"N", x))
_m(x) = Float64(ustrip(u"m", x))

function _leg_length_m(leg)
    dx = _m(leg.p2[1] - leg.p1[1])
    dy = _m(leg.p2[2] - leg.p1[2])
    return hypot(dx, dy)
end

"""Plan point of station `s`, measured from `p1` toward `p2`."""
function _station_xy_m(leg, s)
    L = _leg_length_m(leg)
    t = L <= 1e-9 ? 0.0 : _m(s) / L
    x = _m(leg.p1[1]) + t * _m(leg.p2[1] - leg.p1[1])
    y = _m(leg.p1[2]) + t * _m(leg.p2[2] - leg.p1[2])
    return (x, y)
end

"""Area moments of one rectangle about the origin."""
function _rect_raw(r::_Aabb)
    w = r.x1 - r.x0
    h = r.y1 - r.y0
    (w <= 0 || h <= 0) && return (
        A = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0)
    A = w * h
    sx = 0.5 * (r.x0 + r.x1) * A
    sy = 0.5 * (r.y0 + r.y1) * A
    sxx = h * (r.x1^3 - r.x0^3) / 3
    syy = w * (r.y1^3 - r.y0^3) / 3
    sxy = 0.25 * (r.x1^2 - r.x0^2) * (r.y1^2 - r.y0^2)
    return (A = A, sx = sx, sy = sy, sxx = sxx, syy = syy, sxy = sxy)
end

function _aabb_intersect(a::_Aabb, b::_Aabb)
    x0 = max(a.x0, b.x0)
    x1 = min(a.x1, b.x1)
    y0 = max(a.y0, b.y0)
    y1 = min(a.y1, b.y1)
    (x0 >= x1 - 1e-12 || y0 >= y1 - 1e-12) && return nothing
    return _Aabb(x0, x1, y0, y1)
end

"""
Signed rectangles whose areas add to the union.

Inclusion-exclusion: add each rectangle, subtract each pairwise overlap,
add each triple overlap. A wall footing has two or three legs, so the
power set stays small.
"""
function _ie_terms(rects)
    n = length(rects)
    out = Tuple{Int, _Aabb}[]
    n == 0 && return out
    for mask in 1:(2^n - 1)
        acc = nothing
        k = 0
        empty = false
        for i in 1:n
            (mask & (1 << (i - 1))) == 0 && continue
            k += 1
            acc = acc === nothing ? rects[i] : _aabb_intersect(acc, rects[i])
            if acc === nothing
                empty = true
                break
            end
        end
        empty && continue
        push!(out, (isodd(k) ? 1 : -1, acc))
    end
    return out
end

function _union_vertices(rects)
    pts = Tuple{Float64, Float64}[]
    for r in rects
        for x in (r.x0, r.x1), y in (r.y0, r.y1)
            push!(pts, (x, y))
        end
    end
    return pts
end

"""
`q = a + b (x − cx) + c (y − cy)`, newtons per square metre.

`b` and `c` place the resultant of `P` at `(x, y)`. On a rectangle this
is ACI 336.2R Eq. (3-1): `q = (P/A) (1 ± 6e/Z)`.
"""
function _q_at(coeff, x, y)
    return coeff.a + coeff.b * (x - coeff.cx) + coeff.c * (y - coeff.cy)
end

function _linear_pressure(P, x, y, section)
    A = section.A
    A > 0 || throw(ArgumentError("wall footing has no contact area"))
    a = P / A
    b = section.Iyy > 0 ? P * (x - section.cx) / section.Iyy : 0.0
    c = section.Ixx > 0 ? P * (y - section.cy) / section.Ixx : 0.0
    return (a = a, b = b, c = c, cx = section.cx, cy = section.cy)
end

function _section_of(rects)
    A = sx = sy = sxx = syy = 0.0
    for (sgn, r) in _ie_terms(rects)
        m = _rect_raw(r)
        A += sgn * m.A
        sx += sgn * m.sx
        sy += sgn * m.sy
        sxx += sgn * m.sxx
        syy += sgn * m.syy
    end
    A > 1e-8 || throw(ArgumentError("wall footing rectangles do not cover the ground"))
    cx = sx / A
    cy = sy / A
    return (
        A = A, cx = cx, cy = cy,
        Ixx = syy - A * cy^2,
        Iyy = sxx - A * cx^2,
    )
end

function _resultant_m(legs; service::Bool)
    P = x = y = 0.0
    for leg in legs
        for smp in leg.samples
            p = service ? _n(smp.Ps) : _n(smp.Pu)
            xy = _station_xy_m(leg, smp.s)
            P += p
            x += p * xy[1]
            y += p * xy[2]
        end
    end
    abs(P) > 0 || throw(ArgumentError("wall footing has no vertical load"))
    return (P = P, x = x / P, y = y / P)
end

function _factored_resultant_m(legs)
    r = _resultant_m(legs; service = false)
    return (Pu = r.P, x = r.x, y = r.y)
end

function _endpoint_key(x, y)
    return (round(x, digits = 4), round(y, digits = 4))
end

function _leg_axis(leg)
    dx = _m(leg.p2[1] - leg.p1[1])
    dy = _m(leg.p2[2] - leg.p1[2])
    if abs(dy) <= 1e-4 && abs(dx) > 1e-4
        return :x
    elseif abs(dx) <= 1e-4 && abs(dy) > 1e-4
        return :y
    else
        throw(ArgumentError(
            "A wall footing of more than one leg must lie on the plan axes."))
    end
end

function _validate_wall_legs(legs)
    isempty(legs) && throw(ArgumentError("a wall footing needs a wall line"))
    ends = Dict{NTuple{2, Float64}, Int}()
    for leg in legs
        length(legs) == 1 || _leg_axis(leg)
        for (x, y) in (_station_xy_m(leg, 0.0u"m"),
                       _station_xy_m(leg, _leg_length_m(leg) * u"m"))
            k = _endpoint_key(x, y)
            ends[k] = get(ends, k, 0) + 1
        end
    end
    # A closed cell is a mat, not this strip. A connected line, L, or T
    # has more corners than legs.
    length(ends) <= length(legs) && length(legs) > 1 && throw(ArgumentError(
        "These wall legs close a cell. A closed cell is a mat, not a wall strip."))
    # Every leg after the first must share a corner with one already counted.
    seen = Set{NTuple{2, Float64}}()
    push!(seen, _endpoint_key(_m(legs[1].p1[1]), _m(legs[1].p1[2])))
    push!(seen, _endpoint_key(_m(legs[1].p2[1]), _m(legs[1].p2[2])))
    for leg in legs[2:end]
        a = _endpoint_key(_m(leg.p1[1]), _m(leg.p1[2]))
        b = _endpoint_key(_m(leg.p2[1]), _m(leg.p2[2]))
        (a in seen || b in seen) || throw(ArgumentError(
            "Wall legs of one footing must meet at a corner."))
        push!(seen, a)
        push!(seen, b)
    end
    return nothing
end

function _shared_end(leg, at_p1, legs)
    x, y = at_p1 ? (_m(leg.p1[1]), _m(leg.p1[2])) :
                   (_m(leg.p2[1]), _m(leg.p2[2]))
    key = _endpoint_key(x, y)
    n = 0
    for other in legs
        other === leg && continue
        for (ox, oy) in ((_m(other.p1[1]), _m(other.p1[2])),
                         (_m(other.p2[1]), _m(other.p2[2])))
            _endpoint_key(ox, oy) == key && (n += 1)
        end
    end
    return n > 0
end

"""
Rectangle of width `B` on one leg.

A free end projects `oh`. A shared corner projects `B/2` so the two
rectangles overlap in the corner square and the union counts it once.
"""
function _leg_rect(leg, legs, B, oh)
    ax = _leg_axis(leg)
    x1 = _m(leg.p1[1])
    y1 = _m(leg.p1[2])
    x2 = _m(leg.p2[1])
    y2 = _m(leg.p2[2])
    e1 = _shared_end(leg, true, legs) ? B / 2 : oh
    e2 = _shared_end(leg, false, legs) ? B / 2 : oh
    if ax === :x
        lo = min(x1, x2)
        hi = max(x1, x2)
        ext_lo = x1 <= x2 ? e1 : e2
        ext_hi = x1 <= x2 ? e2 : e1
        yc = 0.5 * (y1 + y2)
        return _Aabb(lo - ext_lo, hi + ext_hi, yc - B / 2, yc + B / 2)
    else
        lo = min(y1, y2)
        hi = max(y1, y2)
        ext_lo = y1 <= y2 ? e1 : e2
        ext_hi = y1 <= y2 ? e2 : e1
        xc = 0.5 * (x1 + x2)
        return _Aabb(xc - B / 2, xc + B / 2, lo - ext_lo, hi + ext_hi)
    end
end

function _ceil_step(x, step)
    step <= 1e-9 && return x
    return ceil(x / step - 1e-9) * step
end

function _pressure_span(plan, P, x, y)
    coeff = _linear_pressure(P, x, y, plan.section)
    return _q_bounds(coeff, plan.rects)
end

"""
    _size_wall_plan(legs, soil; step) → plan

Contact area from the unfactored resultant and `soil.qa` (ACI 318-11
§15.2.2, page 271). The plan is grown until service pressure stays inside
`qa` and both service and factored resultants stay in full contact
(ACI 336.2R §3.2.1, page 6).

# ENGINEERING JUDGMENT
§15.2.2 fixes the area, not the split between width and length. The
footing is first centered on the service resultant. Width then rounds up
to `step`. Length grows in equal end projections when the factored
resultant would otherwise leave the kern.
"""
function _size_wall_plan(legs, soil; step)
    _validate_wall_legs(legs)
    qa = ustrip(u"Pa", soil.qa)
    qa > 0 || throw(ArgumentError("soil.qa must be positive"))
    step_m = _m(step)
    step_m > 0 || throw(ArgumentError("width increment must be positive"))
    Ps = _resultant_m(legs; service = true).P
    Ps > 0 || throw(ArgumentError(
        "wall footing service resultant is not downward compression"))
    if length(legs) == 1
        return _size_straight_plan(legs, soil, qa, step_m, Ps)
    end
    return _size_corner_plan(legs, soil, qa, step_m, Ps)
end

function _straight_plan(leg, B, oh_left, oh_right)
    Lw = _leg_length_m(leg)
    L = Lw + oh_left + oh_right
    rects = [_Aabb(0.0, L, -B / 2, B / 2)]
    section = _section_of(rects)
    return (
        B = B,
        straight = true,
        section = section,
        rects = rects,
        x0 = oh_left,
        along = L,
        area = section.A,
    )
end

function _size_straight_plan(legs, soil, qa, step_m, Ps)
    leg = legs[1]
    Lw = _leg_length_m(leg)
    Lw > 1e-6 || throw(ArgumentError("wall line has no length"))
    svc = _resultant_m(legs; service = true)
    # Station of the service resultant, measured from p1 along the leg.
    ux = _m(leg.p2[1] - leg.p1[1]) / Lw
    uy = _m(leg.p2[2] - leg.p1[2]) / Lw
    sbar = (svc.x - _m(leg.p1[1])) * ux + (svc.y - _m(leg.p1[2])) * uy
    if sbar <= Lw / 2
        oh_left = max(Lw - 2 * sbar, 0.0)
        oh_right = 0.0
    else
        oh_left = 0.0
        oh_right = max(2 * sbar - Lw, 0.0)
    end
    L = Lw + oh_left + oh_right
    tw = maximum(_m(leg.tw) for leg in legs)
    B = max(_ceil_step(Ps / (qa * L), step_m), _ceil_step(tw, step_m))
    for _ in 1:80
        plan = _straight_plan(leg, B, oh_left, oh_right)
        qmin_s, qmax_s = _pressure_span(plan, Ps, plan.x0 + sbar, 0.0)
        fac = _resultant_m(legs; service = false)
        fx = plan.x0 + (fac.x - _m(leg.p1[1])) * ux +
             (fac.y - _m(leg.p1[2])) * uy
        qmin_u, _ = _pressure_span(plan, fac.P, fx, 0.0)
        if qmin_s >= -1.0 && qmax_s <= qa * (1 + 1e-6) && qmin_u >= -1.0
            return plan
        end
        if qmin_s < -1.0 || qmin_u < -1.0
            oh_left += step_m / 2
            oh_right += step_m / 2
        else
            B = _ceil_step(B + step_m, step_m)
        end
    end
    throw(ArgumentError(
        "Wall strip plan did not reach full contact and q ≤ qa in 80 " *
        "increments (ACI 318-11 §15.2.2, page 271; ACI 336.2R §3.2.1, page 6)."))
end

function _corner_plan(legs, B, oh)
    rects = [_leg_rect(leg, legs, B, oh) for leg in legs]
    section = _section_of(rects)
    return (
        B = B,
        straight = false,
        section = section,
        rects = rects,
        x0 = 0.0,
        along = section.A / B,
        area = section.A,
    )
end

function _size_corner_plan(legs, soil, qa, step_m, Ps)
    tw = maximum(_m(leg.tw) for leg in legs)
    reach = sum(_leg_length_m(leg) for leg in legs)
    B = max(_ceil_step(tw, step_m), step_m)
    oh = 0.0
    # Width first, from the leg length. The corner square is inside both
    # rectangles and is counted once by the union.
    B = max(B, _ceil_step(Ps / (qa * max(reach, B)), step_m))
    for _ in 1:80
        plan = _corner_plan(legs, B, oh)
        svc = _resultant_m(legs; service = true)
        qmin_s, qmax_s = _pressure_span(plan, svc.P, svc.x, svc.y)
        fac = _resultant_m(legs; service = false)
        qmin_u, _ = _pressure_span(plan, fac.P, fac.x, fac.y)
        if qmin_s >= -1.0 && qmax_s <= qa * (1 + 1e-6) && qmin_u >= -1.0
            return plan
        end
        if qmin_s < -1.0 || qmin_u < -1.0
            oh += step_m
        else
            B = _ceil_step(B + step_m, step_m)
        end
    end
    throw(ArgumentError(
        "Corner wall footing plan did not reach full contact and q ≤ qa " *
        "in 80 increments (ACI 318-11 §15.2.2, page 271; ACI 336.2R §4.2, page 7)."))
end
