import LinearAlgebra

# =============================================================================
# Column points and wall lines, one area split per cell
# =============================================================================
#
# A column keeps the larger of two regions, whole:
#   - the Voronoi cell of that corner among every cell corner
#   - the region closer to the column than to any other column or wall line
# The second boundary is a parabola where the neighbor is a wall. The wall's
# share is whatever the chosen column regions do not cover, so the areas add
# up to the cell. A cell with no wall has nothing to receive a leftover, and
# its columns use a Voronoi of the real columns only.

"""One column's share of a cell. `polygon` traces the boundary; parabolic
edges are sampled. `area` is the exact region area, in m²."""
struct ColumnSupportShare
    xy::NTuple{2, Float64}
    area::Float64
    polygon::Vector{NTuple{2, Float64}}
end

"""One wall edge's share of a cell. `pieces` are widths along the segment
from `a` toward `b`, in that segment's own coordinate (metres from `a`)."""
struct WallSupportShare
    a::NTuple{2, Float64}
    b::NTuple{2, Float64}
    area::Float64
    pieces::Vector{WallWidthPiece}
end

# -----------------------------------------------------------------------------
# Loop geometry
# -----------------------------------------------------------------------------

"""Parabola `v = ((u - u_c)² + h²) / (2h)` in a wall frame, traversed from
`u0` to `u1`. `normal` points to the column side of the wall."""
struct ParaArc
    origin::NTuple{2, Float64}
    dir::NTuple{2, Float64}
    normal::NTuple{2, Float64}
    u_c::Float64
    h::Float64
    u0::Float64
    u1::Float64
end

"""One directed edge of a region. `arc === nothing` is the straight segment
`p → q`."""
struct LoopEdge
    p::NTuple{2, Float64}
    q::NTuple{2, Float64}
    arc::Union{Nothing, ParaArc}
end

struct _WallFrame
    origin::NTuple{2, Float64}
    dir::NTuple{2, Float64}
    normal::NTuple{2, Float64}
    L::Float64
end

const _GEOM_TOL = 1e-8

_sub(a::NTuple{2, Float64}, b::NTuple{2, Float64}) = (a[1] - b[1], a[2] - b[2])
_add(a::NTuple{2, Float64}, b::NTuple{2, Float64}) = (a[1] + b[1], a[2] + b[2])
_mul(a::NTuple{2, Float64}, s::Float64) = (a[1] * s, a[2] * s)
_dot(a::NTuple{2, Float64}, b::NTuple{2, Float64}) = a[1] * b[1] + a[2] * b[2]
_hypot(a::NTuple{2, Float64}) = hypot(a[1], a[2])
_near(a::NTuple{2, Float64}, b::NTuple{2, Float64}, tol::Float64=_GEOM_TOL) = _hypot(_sub(a, b)) <= tol
_lerp(p::NTuple{2, Float64}, q::NTuple{2, Float64}, t::Float64) = _add(p, _mul(_sub(q, p), t))

function _shoelace(verts)
    n = length(verts)
    n < 3 && return 0.0
    a = 0.0
    @inbounds for i in 1:n
        p = verts[i]
        q = verts[i == n ? 1 : i + 1]
        a += p[1] * q[2] - q[1] * p[2]
    end
    return a / 2
end

"""Counterclockwise copy. A repeated closing point is dropped."""
function _ensure_ccw(raw)
    verts = NTuple{2, Float64}[raw[i] for i in eachindex(raw)]
    length(verts) > 1 && _near(verts[1], verts[end]) && pop!(verts)
    _shoelace(verts) < 0 && reverse!(verts)
    return verts
end

function _straight_edges(verts)
    n = length(verts)
    edges = LoopEdge[]
    @inbounds for i in 1:n
        p = verts[i]
        q = verts[i == n ? 1 : i + 1]
        _near(p, q) && continue
        push!(edges, LoopEdge(p, q, nothing))
    end
    return edges
end

"""Inward frame of segment `A → B` for a counterclockwise cell."""
function _inward_frame(A::NTuple{2, Float64}, B::NTuple{2, Float64}, cell)
    d = _sub(B, A)
    L = _hypot(d)
    L < _GEOM_TOL && throw(ArgumentError("Wall segment has zero length."))
    dir = _mul(d, 1 / L)
    normal = (-dir[2], dir[1])
    # Interior of a CCW cell lies to the left of each edge.
    c = (0.0, 0.0)
    for v in cell
        c = _add(c, v)
    end
    c = _mul(c, 1 / length(cell))
    if _dot(_sub(c, A), normal) < 0
        normal = _mul(normal, -1.0)
    end
    return _WallFrame(A, dir, normal, L)
end

_u_of(frame::_WallFrame, p) = _dot(_sub(p, frame.origin), frame.dir)
_v_of(frame::_WallFrame, p) = _dot(_sub(p, frame.origin), frame.normal)
_from_uv(frame::_WallFrame, u, v) = _add(_add(frame.origin, _mul(frame.dir, u)), _mul(frame.normal, v))

function _para_value(u, u_c, h)
    return ((u - u_c)^2 + h * h) / (2 * h)
end

function _para_point(frame::_WallFrame, u_c, h, u)
    return _from_uv(frame, u, _para_value(u, u_c, h))
end

function _solve_quadratic(a, b, c)
    if abs(a) < 1e-14
        abs(b) < 1e-14 && return Float64[]
        return [-c / b]
    end
    d = b * b - 4 * a * c
    d < -1e-12 && return Float64[]
    d = max(d, 0.0)
    s = sqrt(d)
    return [(-b - s) / (2 * a), (-b + s) / (2 * a)]
end

"""Real roots of `c[1] + c[2] t + ...`. Leading zeros are dropped."""
function _solve_poly(coeffs::Vector{Float64})
    c = copy(coeffs)
    while length(c) > 1 && abs(c[end]) < 1e-12
        pop!(c)
    end
    d = length(c) - 1
    d <= 0 && return Float64[]
    d == 1 && return [-c[1] / c[2]]
    d == 2 && return _solve_quadratic(c[3], c[2], c[1])
    lead = c[end]
    C = zeros(d, d)
    @inbounds for i in 1:(d - 1)
        C[i + 1, i] = 1.0
    end
    @inbounds for i in 1:d
        C[i, d] = -c[i] / lead
    end
    ev = LinearAlgebra.eigvals(C)
    return [real(z) for z in ev if abs(imag(z)) < 1e-7]
end

# -----------------------------------------------------------------------------
# Clipping
# -----------------------------------------------------------------------------

"""Keep the half-plane `dot(p - origin, normal) ≥ 0`."""
function _clip_halfplane(verts, origin, normal)
    n = length(verts)
    n < 3 && return NTuple{2, Float64}[]
    out = NTuple{2, Float64}[]
    @inbounds for i in 1:n
        s = verts[i]
        e = verts[i == n ? 1 : i + 1]
        ds = _dot(_sub(s, origin), normal)
        de = _dot(_sub(e, origin), normal)
        s_in = ds >= -_GEOM_TOL
        e_in = de >= -_GEOM_TOL
        if e_in
            if !s_in
                t = ds / (ds - de)
                push!(out, _lerp(s, e, t))
            end
            push!(out, e)
        elseif s_in
            t = ds / (ds - de)
            push!(out, _lerp(s, e, t))
        end
    end
    # Drop duplicates left by a vertex sitting on the line.
    cleaned = NTuple{2, Float64}[]
    for p in out
        (isempty(cleaned) || !_near(p, cleaned[end])) && push!(cleaned, p)
    end
    length(cleaned) > 1 && _near(cleaned[1], cleaned[end]) && pop!(cleaned)
    return cleaned
end

"""Voronoi cell of `site` inside a convex counterclockwise `cell`."""
function _voronoi_cell(cell, site, others)
    verts = cell
    for o in others
        _near(o, site) && continue
        mid = _mul(_add(site, o), 0.5)
        normal = _sub(site, o)
        verts = _clip_halfplane(verts, mid, normal)
        length(verts) < 3 && return NTuple{2, Float64}[]
    end
    return verts
end

function _on_column_side(frame::_WallFrame, u_c, h, p)
    u = _u_of(frame, p)
    v = _v_of(frame, p)
    return v >= _para_value(u, u_c, h) - 1e-7
end

"""Crossings of a straight edge with the column-side parabola, as `t` in `(0, 1)`."""
function _crossings_straight(p, q, frame::_WallFrame, u_c, h)
    u0 = _u_of(frame, p)
    v0 = _v_of(frame, p)
    u1 = _u_of(frame, q)
    v1 = _v_of(frame, q)
    du = u1 - u0
    dv = v1 - v0
    aa = du * du
    bb = 2 * (u0 - u_c) * du - 2 * h * dv
    cc = (u0 - u_c)^2 + h * h - 2 * h * v0
    ts = Float64[]
    for t in _solve_quadratic(aa, bb, cc)
        1e-8 < t < 1 - 1e-8 && push!(ts, t)
    end
    sort!(ts)
    return ts
end

"""Point `t` along `arc`, `t = 0` at `u0` and `t = 1` at `u1`."""
function _arc_point(arc::ParaArc, t::Float64)
    u = arc.u0 + t * (arc.u1 - arc.u0)
    v = _para_value(u, arc.u_c, arc.h)
    return _add(_add(arc.origin, _mul(arc.dir, u)), _mul(arc.normal, v))
end

"""`t` in `(0, 1)` where `arc` meets the parabola of another wall frame."""
function _crossings_arc(arc::ParaArc, frame::_WallFrame, u_c, h)
    Δ = arc.u1 - arc.u0
    # Target-frame coordinates of the arc are quadratic in t. Fit them from
    # three samples; the fit is exact because the arc is quadratic.
    function uv(t)
        r = _arc_point(arc, t)
        return (_u_of(frame, r), _v_of(frame, r))
    end
    s0, s5, s1 = uv(0.0), uv(0.5), uv(1.0)
    function quad_coeff(z0, z5, z1)
        a0 = z0
        a2 = 2 * ((z1 - a0) - 2 * (z5 - a0))
        a1 = (z1 - a0) - a2
        return a0, a1, a2
    end
    a0, a1, a2 = quad_coeff(s0[1], s5[1], s1[1])
    b0, b1, b2 = quad_coeff(s0[2], s5[2], s1[2])
    inv2h = 1 / (2 * h)
    uc_h = u_c / h
    cnst = (u_c * u_c + h * h) / (2 * h)
    # q(u2) coefficients in powers of t, then f = v2 - q.
    q0 = inv2h * a0 * a0 - uc_h * a0 + cnst
    q1 = inv2h * 2 * a0 * a1 - uc_h * a1
    q2 = inv2h * (2 * a0 * a2 + a1 * a1) - uc_h * a2
    q3 = inv2h * 2 * a1 * a2
    q4 = inv2h * a2 * a2
    coeffs = [b0 - q0, b1 - q1, b2 - q2, -q3, -q4]
    ts = Float64[]
    for t in _solve_poly(coeffs)
        1e-7 < t < 1 - 1e-7 && push!(ts, t)
    end
    sort!(ts)
    return _unique_tol(ts, 1e-8)
end

"""Drop values that round to the same multiple of `tol`, keeping order."""
function _unique_tol(xs::Vector{Float64}, tol::Float64)
    out = Float64[]
    for x in xs
        (isempty(out) || abs(x - out[end]) > tol) && push!(out, x)
    end
    return out
end

function _sub_arc(arc::ParaArc, t0::Float64, t1::Float64)
    Δ = arc.u1 - arc.u0
    u0 = arc.u0 + t0 * Δ
    u1 = arc.u0 + t1 * Δ
    sub = ParaArc(arc.origin, arc.dir, arc.normal, arc.u_c, arc.h, u0, u1)
    return LoopEdge(_arc_point(sub, 0.0), _arc_point(sub, 1.0), sub)
end

"""Inside portions of one edge, in traversal order."""
function _inside_portions(edge::LoopEdge, inside, frame::_WallFrame, u_c, h)
    if edge.arc === nothing
        ts = Float64[0.0]
        append!(ts, _crossings_straight(edge.p, edge.q, frame, u_c, h))
        push!(ts, 1.0)
        portions = LoopEdge[]
        flags = Bool[]
        for k in 1:(length(ts) - 1)
            t0, t1 = ts[k], ts[k + 1]
            t1 - t0 < 1e-10 && continue
            p = _lerp(edge.p, edge.q, t0)
            q = _lerp(edge.p, edge.q, t1)
            push!(portions, LoopEdge(p, q, nothing))
            push!(flags, inside(_lerp(edge.p, edge.q, (t0 + t1) / 2)))
        end
        return portions, flags
    end
    ts = Float64[0.0]
    append!(ts, _crossings_arc(edge.arc, frame, u_c, h))
    push!(ts, 1.0)
    portions = LoopEdge[]
    flags = Bool[]
    for k in 1:(length(ts) - 1)
        t0, t1 = ts[k], ts[k + 1]
        t1 - t0 < 1e-10 && continue
        sub = _sub_arc(edge.arc, t0, t1)
        push!(portions, sub)
        push!(flags, inside(_arc_point(edge.arc, (t0 + t1) / 2)))
    end
    return portions, flags
end

function _para_bridge(frame::_WallFrame, u_c, h, p_exit, p_entry)
    u0 = _u_of(frame, p_exit)
    u1 = _u_of(frame, p_entry)
    arc = ParaArc(frame.origin, frame.dir, frame.normal, u_c, h, u0, u1)
    return LoopEdge(_para_point(frame, u_c, h, u0), _para_point(frame, u_c, h, u1), arc)
end

"""Clip a loop to the column side of one wall line. The cell lies in the
wall's strip, so distance to the finite edge equals distance to the line."""
function _clip_parabola(edges::Vector{LoopEdge}, frame::_WallFrame, u_c, h)
    isempty(edges) && return LoopEdge[]
    inside(p) = _on_column_side(frame, u_c, h, p)
    atoms = LoopEdge[]
    flags = Bool[]
    for e in edges
        parts, part_flags = _inside_portions(e, inside, frame, u_c, h)
        append!(atoms, parts)
        append!(flags, part_flags)
    end
    isempty(atoms) && return LoopEdge[]
    all(flags) && return edges
    any(flags) || return LoopEdge[]
    n = length(atoms)
    start = findfirst(i -> flags[i] && !flags[mod1(i - 1, n)], 1:n)
    start === nothing && return LoopEdge[]
    out = LoopEdge[]
    i = start
    seen = 0
    while seen < n
        if flags[i]
            push!(out, atoms[i])
            i = mod1(i + 1, n)
            seen += 1
        else
            exit_pt = atoms[i].p
            while !flags[i]
                i = mod1(i + 1, n)
                seen += 1
                seen > n && break
            end
            push!(out, _para_bridge(frame, u_c, h, exit_pt, atoms[i].p))
        end
    end
    return out
end

function _column_frame_height(frame::_WallFrame, column)
    return _v_of(frame, column), _u_of(frame, column)
end

"""Region closer to `column` than to the other columns or the wall lines."""
function _curved_loop(cell, column, others, walls)
    verts = _voronoi_cell(cell, column, others)
    length(verts) < 3 && return LoopEdge[]
    edges = _straight_edges(verts)
    for (A, B) in walls
        frame = _inward_frame(A, B, cell)
        h, u_c = _column_frame_height(frame, column)
        # A column on the wall line is no farther from the wall than from
        # itself, so the curved region is empty and the corner region wins.
        h <= 1e-8 && return LoopEdge[]
        edges = _clip_parabola(edges, frame, u_c, h)
        isempty(edges) && return LoopEdge[]
    end
    return edges
end

# -----------------------------------------------------------------------------
# Area
# -----------------------------------------------------------------------------

const _Gξ = (-sqrt(0.6), 0.0, sqrt(0.6))
const _GW = (5 / 9, 8 / 9, 5 / 9)

function _green_arc(arc::ParaArc)
    u0, u1 = arc.u0, arc.u1
    half = 0.5 * (u1 - u0)
    mid = 0.5 * (u0 + u1)
    s = 0.0
    for k in 1:3
        u = mid + half * _Gξ[k]
        v = _para_value(u, arc.u_c, arc.h)
        vp = (u - arc.u_c) / arc.h
        x = arc.origin[1] + u * arc.dir[1] + v * arc.normal[1]
        y = arc.origin[2] + u * arc.dir[2] + v * arc.normal[2]
        dx = arc.dir[1] + vp * arc.normal[1]
        dy = arc.dir[2] + vp * arc.normal[2]
        s += _GW[k] * (x * dy - y * dx)
    end
    return s * half
end

function _loop_area(edges::Vector{LoopEdge})
    a = 0.0
    for e in edges
        if e.arc === nothing
            a += e.p[1] * e.q[2] - e.q[1] * e.p[2]
        else
            a += _green_arc(e.arc)
        end
    end
    return 0.5 * a
end

function _sample_loop(edges::Vector{LoopEdge}; chord::Float64=1e-3)
    pts = NTuple{2, Float64}[]
    for e in edges
        (isempty(pts) || !_near(pts[end], e.p)) && push!(pts, e.p)
        if e.arc !== nothing
            span = abs(e.arc.u1 - e.arc.u0)
            step = sqrt(max(chord * 16 * abs(e.arc.h), 1e-8))
            n = max(1, ceil(Int, span / step))
            for k in 1:(n - 1)
                push!(pts, _arc_point(e.arc, k / n))
            end
        end
    end
    length(pts) > 1 && _near(pts[1], pts[end]) && pop!(pts)
    return pts
end

function _piece_area(p::WallWidthPiece)
    Δ = p.u1 - p.u0
    return p.a * Δ^3 / 3 + p.b * Δ^2 / 2 + p.c * Δ
end

# -----------------------------------------------------------------------------
# Width of the complement along one wall
# -----------------------------------------------------------------------------

function _in_polygon(p, verts)
    length(verts) < 3 && return false
    # Boundary counts as inside.
    n = length(verts)
    @inbounds for i in 1:n
        a = verts[i]
        b = verts[i == n ? 1 : i + 1]
        ab = _sub(b, a)
        tden = _dot(ab, ab)
        tden < 1e-24 && continue
        t = clamp(_dot(_sub(p, a), ab) / tden, 0.0, 1.0)
        _hypot(_sub(p, _add(a, _mul(ab, t)))) <= 1e-7 && return true
    end
    c = false
    @inbounds for i in 1:n
        a = verts[i]
        b = verts[i == n ? 1 : i + 1]
        if (a[2] > p[2]) != (b[2] > p[2])
            x = a[1] + (b[1] - a[1]) * (p[2] - a[2]) / (b[2] - a[2])
            x > p[1] && (c = !c)
        end
    end
    return c
end

function _in_curved(p, column, others, walls, cell)
    _in_polygon(p, cell) || return false
    for o in others
        mid = _mul(_add(column, o), 0.5)
        _dot(_sub(p, mid), _sub(column, o)) < -1e-7 && return false
    end
    for (A, B) in walls
        frame = _inward_frame(A, B, cell)
        h, u_c = _column_frame_height(frame, column)
        h <= 1e-8 && return false
        u = _u_of(frame, p)
        v = _v_of(frame, p)
        v < _para_value(u, u_c, h) - 1e-7 && return false
    end
    return true
end

"""Solve `v` where the ray at fixed `u` meets a straight segment. `nothing`
when the ray misses the segment."""
function _ray_hit_straight(frame::_WallFrame, u, p, q)
    dx = q[1] - p[1]
    dy = q[2] - p[2]
    rhsx = p[1] - frame.origin[1] - u * frame.dir[1]
    rhsy = p[2] - frame.origin[2] - u * frame.dir[2]
    # v * normal - t * (q - p) = rhs
    det = frame.normal[1] * (-dy) - (-dx) * frame.normal[2]
    abs(det) < 1e-14 && return nothing
    v = ((-dy) * rhsx - (-dx) * rhsy) / det
    t = (frame.normal[1] * rhsy - frame.normal[2] * rhsx) / det
    (-1e-8 <= t <= 1 + 1e-8) || return nothing
    return v
end

"""Solve `v` where the ray meets a parabolic edge stored in any frame."""
function _ray_hit_arc(frame::_WallFrame, u, arc::ParaArc)
    # Same frame: the graph gives one v, if u lies on the arc.
    if _near(arc.origin, frame.origin) && abs(_dot(arc.dir, frame.dir) - 1) < 1e-8 &&
       abs(_dot(arc.normal, frame.normal) - 1) < 1e-8
        lo, hi = minmax(arc.u0, arc.u1)
        (lo - 1e-8 <= u <= hi + 1e-8) || return Float64[]
        return [_para_value(u, arc.u_c, arc.h)]
    end
    # point(v) = O + u D + v N lies on the other parabola.
    O = frame.origin
    D = frame.dir
    N = frame.normal
    function lin(axis_origin, axis)
        # coefficient of (const, v) in dot(point - axis_origin, axis)
        c0 = _dot(_sub(_add(O, _mul(D, u)), axis_origin), axis)
        c1 = _dot(N, axis)
        return c0, c1
    end
    u0, u1 = lin(arc.origin, arc.dir)
    v0, v1 = lin(arc.origin, arc.normal)
    # v_arc = ((u_arc - u_c)^2 + h^2) / (2h)
    # u_arc = u0 + u1 v, v_arc = v0 + v1 v
    h = arc.h
    uc = arc.u_c
    # (u0 + u1 v - uc)^2 + h^2 = 2 h (v0 + v1 v)
    # (u1 v + (u0-uc))^2 + h^2 - 2 h v0 - 2 h v1 v = 0
    k = u0 - uc
    aa = u1 * u1
    bb = 2 * u1 * k - 2 * h * v1
    cc = k * k + h * h - 2 * h * v0
    hits = Float64[]
    for v in _solve_quadratic(aa, bb, cc)
        v < -1e-7 && continue
        uu = u0 + u1 * v
        lo, hi = minmax(arc.u0, arc.u1)
        lo - 1e-6 <= uu <= hi + 1e-6 && push!(hits, v)
    end
    return hits
end

"""`v(u)` of the bisector between this inward frame and another wall, or
`nothing` when the walls are parallel and face the same way."""
function _bisector_v(frame::_WallFrame, u, other::_WallFrame)
    # v = dot(point - other.origin, other.normal)
    # point = origin + u dir + v normal
    c0 = _dot(_sub(_add(frame.origin, _mul(frame.dir, u)), other.origin), other.normal)
    c1 = _dot(frame.normal, other.normal)
    abs(1 - c1) < 1e-10 && return nothing
    return (c0) / (1 - c1)
end

function _bisector_coefficients(frame::_WallFrame, other::_WallFrame, u_ref)
    # v(u) = (k0 + u k1) / (1 - c1), linear.
    c1 = _dot(frame.normal, other.normal)
    abs(1 - c1) < 1e-10 && return nothing
    den = 1 - c1
    # c0(u) = dot(origin + u dir - other.origin, other.normal) = α + u β
    α = _dot(_sub(frame.origin, other.origin), other.normal)
    β = _dot(frame.dir, other.normal)
    # v = (α + β u) / den = (β/den) (u - u_ref) + (α + β u_ref) / den
    b = β / den
    c = (α + β * u_ref) / den
    return (a=0.0, b=b, c=c)
end

"""Straight edge as `v = b (u - u_ref) + c` in `frame`, or `nothing` if the
edge is parallel to the wall normal."""
function _straight_coefficients(frame::_WallFrame, p, q, u_ref)
    up, vp = _u_of(frame, p), _v_of(frame, p)
    uq, vq = _u_of(frame, q), _v_of(frame, q)
    du = uq - up
    abs(du) < 1e-10 && return nothing
    slope = (vq - vp) / du
    # v(u_ref) = vp + slope (u_ref - up)
    return (a=0.0, b=slope, c=vp + slope * (u_ref - up))
end

function _parabola_coefficients(u_c, h, u_ref)
    # q(u) = ((u-uc)^2 + h^2)/(2h)
    # t = u - u_ref, u - uc = t + (u_ref - uc)
    δ = u_ref - u_c
    return (a=1 / (2 * h), b=δ / h, c=(δ * δ + h * h) / (2 * h))
end

"""A blocking surface the width ray can meet."""
struct _Block
    v::Float64
    coeff::NamedTuple{(:a, :b, :c), Tuple{Float64, Float64, Float64}}
end

function _blocks_at(u, frame, cell, kept, walls, wall_index)
    blocks = _Block[]
    n = length(cell)
    for i in 1:n
        p = cell[i]
        q = cell[i == n ? 1 : i + 1]
        v = _ray_hit_straight(frame, u, p, q)
        v === nothing && continue
        v < -1e-7 && continue
        coeff = _straight_coefficients(frame, p, q, u)
        coeff === nothing && continue
        push!(blocks, _Block(v, coeff))
    end
    for (A, B) in walls
        A == walls[wall_index][1] && B == walls[wall_index][2] && continue
        other = _inward_frame(A, B, cell)
        v = _bisector_v(frame, u, other)
        v === nothing && continue
        v < -1e-7 && continue
        coeff = _bisector_coefficients(frame, other, u)
        coeff === nothing && continue
        push!(blocks, _Block(v, coeff))
    end
    for region in kept
        for e in region.edges
            if e.arc === nothing
                v = _ray_hit_straight(frame, u, e.p, e.q)
                v === nothing && continue
                v < -1e-7 && continue
                coeff = _straight_coefficients(frame, e.p, e.q, u)
                coeff === nothing && continue
                push!(blocks, _Block(v, coeff))
            else
                for v in _ray_hit_arc(frame, u, e.arc)
                    v < -1e-7 && continue
                    if _near(e.arc.origin, frame.origin) &&
                       abs(_dot(e.arc.dir, frame.dir) - 1) < 1e-8
                        coeff = _parabola_coefficients(e.arc.u_c, e.arc.h, u)
                    else
                        # Foreign arc: the local slope comes from the two
                        # nearby hits, stored as a linear piece. The caller
                        # splits `u` finely enough that this is the active law
                        # only on a straight bisector or this wall's own arc.
                        coeff = (a=0.0, b=0.0, c=v)
                    end
                    push!(blocks, _Block(v, coeff))
                end
            end
        end
    end
    return blocks
end

function _owned(p, cell, kept, walls, wall_index)
    _in_polygon(p, cell) || return false
    for region in kept
        if region.curved
            _in_curved(p, region.column, region.others, walls, cell) && return false
        else
            _in_polygon(p, region.polygon) && return false
        end
    end
    A, B = walls[wall_index]
    frame = _inward_frame(A, B, cell)
    v_here = _v_of(frame, p)
    for (k, (C, D)) in enumerate(walls)
        k == wall_index && continue
        other = _inward_frame(C, D, cell)
        _v_of(other, p) + 1e-7 < v_here && return false
    end
    return true
end

function _width_at(u, frame, cell, kept, walls, wall_index)
    p0 = _from_uv(frame, u, 0.0)
    _owned(p0, cell, kept, walls, wall_index) || return (v=0.0, coeff=(a=0.0, b=0.0, c=0.0))
    blocks = _blocks_at(u, frame, cell, kept, walls, wall_index)
    vs = Float64[b.v for b in blocks if b.v > 1e-8]
    sort!(vs)
    vs = _unique_tol(vs, 1e-8)
    exit_v = nothing
    exit_coeff = (a=0.0, b=0.0, c=0.0)
    prev = 0.0
    for v in vs
        mid = 0.5 * (prev + v)
        if _owned(_from_uv(frame, u, mid), cell, kept, walls, wall_index) &&
           !_owned(_from_uv(frame, u, v + 1e-5), cell, kept, walls, wall_index)
            exit_v = v
            # Coefficient of the block closest to this v.
            best = nothing
            bestd = Inf
            for b in blocks
                d = abs(b.v - v)
                if d < bestd
                    bestd = d
                    best = b.coeff
                end
            end
            best !== nothing && (exit_coeff = best)
            break
        end
        prev = v
    end
    exit_v === nothing && return (v=0.0, coeff=(a=0.0, b=0.0, c=0.0))
    return (v=exit_v, coeff=exit_coeff)
end

function _critical_u(frame, cell, kept)
    us = Float64[0.0, frame.L]
    for v in cell
        push!(us, clamp(_u_of(frame, v), 0.0, frame.L))
    end
    for region in kept
        for e in region.edges
            push!(us, clamp(_u_of(frame, e.p), 0.0, frame.L))
            push!(us, clamp(_u_of(frame, e.q), 0.0, frame.L))
            if e.arc !== nothing && abs(_dot(e.arc.dir, frame.dir) - 1) < 1e-8 &&
               _near(e.arc.origin, frame.origin)
                push!(us, clamp(e.arc.u_c, 0.0, frame.L))
            end
        end
    end
    sort!(us)
    cleaned = Float64[]
    for u in us
        (isempty(cleaned) || u - cleaned[end] > 1e-7) && push!(cleaned, u)
    end
    return cleaned
end

function _width_pieces(A, B, cell, kept, walls, wall_index)
    frame = _inward_frame(A, B, cell)
    us = _critical_u(frame, cell, kept)
    pieces = WallWidthPiece[]
    for i in 1:(length(us) - 1)
        u0, u1 = us[i], us[i + 1]
        u1 - u0 < 1e-8 && continue
        um = 0.5 * (u0 + u1)
        hit = _width_at(um, frame, cell, kept, walls, wall_index)
        hit.v <= 1e-9 && continue
        # Re-express the law about u0. `hit.coeff` is about `um`.
        a = hit.coeff.a
        δ = u0 - um
        # w = a (u-um)^2 + b (u-um) + c = a (t+δ)^2 + b (t+δ) + c, t = u-u0
        b = hit.coeff.b
        c = hit.coeff.c
        push!(pieces, WallWidthPiece(u0, u1, a, 2 * a * δ + b, a * δ * δ + b * δ + c))
    end
    return pieces
end

# -----------------------------------------------------------------------------
# Public split
# -----------------------------------------------------------------------------

"""A column region kept whole: either the corner Voronoi polygon or the
curved nearest-support region."""
struct _Kept
    curved::Bool
    edges::Vector{LoopEdge}
    polygon::Vector{NTuple{2, Float64}}
    column::NTuple{2, Float64}
    others::Vector{NTuple{2, Float64}}
end

function _matches_vertex(p, cell)
    return any(v -> _near(v, p, 1e-6), cell)
end

"""
    split_cell_supports(cell, columns, walls) -> (columns, walls)

`cell` is a convex plan polygon in metres. `columns` are column points.
`walls` are segments `(a, b)`, each covering a full edge of `cell`.

Each column is given the larger of its corner-Voronoi region and its
curved nearest-support region. Each wall is given the rest of the cell,
split with the other walls along the line equally far from both. With no
walls, the columns are the Voronoi of the real column points.

Areas are square metres. Column areas plus wall areas equal the cell area.
"""
function split_cell_supports(cell_in, columns, walls)
    cell = _ensure_ccw(cell_in)
    length(cell) >= 3 || throw(ArgumentError("A cell needs at least 3 vertices."))
    abs(_shoelace(cell)) > _GEOM_TOL || throw(ArgumentError("Cell outline has no area."))
    col_shares = ColumnSupportShare[]
    wall_shares = WallSupportShare[]
    n = length(columns)
    if isempty(walls)
        for (i, c) in enumerate(columns)
            others = NTuple{2, Float64}[columns[j] for j in 1:n if j != i]
            poly = _voronoi_cell(cell, c, others)
            area = abs(_shoelace(poly))
            push!(col_shares, ColumnSupportShare(c, area, poly))
        end
        return (columns=col_shares, walls=wall_shares)
    end
    kept = _Kept[]
    for (i, c) in enumerate(columns)
        corner_area = 0.0
        corner_poly = NTuple{2, Float64}[]
        if _matches_vertex(c, cell)
            sites = NTuple{2, Float64}[v for v in cell if !_near(v, c, 1e-6)]
            corner_poly = _voronoi_cell(cell, c, sites)
            corner_area = abs(_shoelace(corner_poly))
        end
        others = NTuple{2, Float64}[columns[j] for j in 1:n if j != i]
        edges = _curved_loop(cell, c, others, walls)
        curved_area = isempty(edges) ? 0.0 : _loop_area(edges)
        if curved_area > corner_area + 1e-8
            poly = _sample_loop(edges)
            push!(col_shares, ColumnSupportShare(c, curved_area, poly))
            push!(kept, _Kept(true, edges, poly, c, others))
        else
            push!(col_shares, ColumnSupportShare(c, corner_area, corner_poly))
            push!(kept, _Kept(false, _straight_edges(corner_poly), corner_poly, c, others))
        end
    end
    for (k, (A, B)) in enumerate(walls)
        pieces = _width_pieces(A, B, cell, kept, walls, k)
        area = sum(_piece_area, pieces; init=0.0)
        push!(wall_shares, WallSupportShare(A, B, area, pieces))
    end
    return (columns=col_shares, walls=wall_shares)
end

"""
    wall_edge_nodal_forces(stations_m, pieces, pressure_Pa) -> Vector{Float64}

Consistent nodal forces (newtons, along the load) for a pressure on the
width profile `pieces`. `stations_m` are node positions in metres along the
same axis as the pieces, in order. Between two stations the shape functions
are linear, and three-point Gauss–Legendre integrates a quadratic width
against them exactly.
"""
function wall_edge_nodal_forces(stations_m::AbstractVector{<:Real},
                                pieces::AbstractVector{WallWidthPiece},
                                pressure_Pa::Real)
    n = length(stations_m)
    F = zeros(n)
    q = Float64(pressure_Pa)
    for i in 1:(n - 1)
        s0 = Float64(stations_m[i])
        s1 = Float64(stations_m[i + 1])
        s1 - s0 < 1e-12 && continue
        for piece in pieces
            lo = max(s0, piece.u0)
            hi = min(s1, piece.u1)
            hi - lo < 1e-12 && continue
            half = 0.5 * (hi - lo)
            mid = 0.5 * (hi + lo)
            for k in 1:3
                u = mid + half * _Gξ[k]
                t = u - piece.u0
                w = piece.a * t * t + piece.b * t + piece.c
                N0 = (s1 - u) / (s1 - s0)
                N1 = (u - s0) / (s1 - s0)
                dF = q * w * _GW[k] * half
                F[i] += dF * N0
                F[i + 1] += dF * N1
            end
        end
    end
    return F
end

"""Move a width piece from a cell-edge coordinate onto the wall's own axis."""
function _piece_on_wall(piece::WallWidthPiece, edge_a, edge_b, wall_a, wall_b)
    d_edge = _sub(edge_b, edge_a)
    Le = _hypot(d_edge)
    d_wall = _sub(wall_b, wall_a)
    Lw = _hypot(d_wall)
    (Le < _GEOM_TOL || Lw < _GEOM_TOL) && return nothing
    wd = _mul(d_wall, 1 / Lw)
    σ = _dot(d_edge, wd) / Le
    abs(abs(σ) - 1) > 1e-6 && return nothing
    sP = _dot(_sub(edge_a, wall_a), wd)
    s_at(u) = sP + σ * u
    sa, sb = s_at(piece.u0), s_at(piece.u1)
    if sa <= sb
        return WallWidthPiece(sa, sb, piece.a, piece.b * σ, piece.c)
    end
    Δ = piece.u1 - piece.u0
    a, b, c = piece.a, piece.b, piece.c
    return WallWidthPiece(sb, sa, a, -2 * a * Δ - b, a * Δ * Δ + b * Δ + c)
end

"""Walls whose plan line covers a full edge of this cell, at this elevation."""
function _cell_wall_edges(struc, verts, cell_z)
    skel = struc.skeleton
    found = Tuple{NTuple{2, Float64}, NTuple{2, Float64}, Any}[]
    n = length(verts)
    for wall in struc.walls
        haskey(skel.stories, wall.story) || continue
        z = skel.stories[wall.story].elevation
        z_m = z isa Unitful.Quantity ? Float64(ustrip(u"m", z)) : Float64(z)
        abs(z_m - cell_z) < 0.1 || continue
        A = (wall.x1, wall.y1)
        B = (wall.x2, wall.y2)
        for i in 1:n
            P = verts[i]
            Q = verts[mod1(i + 1, n)]
            _covers_edge(A, B, P, Q) && push!(found, (P, Q, wall))
        end
    end
    return found
end

function _covers_edge(A, B, P, Q)
    d = _sub(B, A)
    L = _hypot(d)
    L < 1e-8 && return false
    dir = _mul(d, 1 / L)
    normal = (-dir[2], dir[1])
    on(R) = abs(_dot(_sub(R, A), normal)) <= 1e-6 &&
            -1e-6 <= _dot(_sub(R, A), dir) <= L + 1e-6
    return on(P) && on(Q)
end

"""
    wall_tributary_area(wall) -> Float64

Slab area this wall carries, in m², summed over the cells in
`wall.tributary_cell_areas`.
"""
wall_tributary_area(wall::Wall) = sum(values(wall.tributary_cell_areas); init=0.0)
