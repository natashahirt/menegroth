# =============================================================================
# Column and wall shares of a cell, from its edge polygons
# =============================================================================
#
# Every cell edge has one polygon ([`compute_cell_tributaries!`](@ref)): the
# straight skeleton for two-way floors, the span-axis partition for one-way
# floors. Beams carry these polygons directly. Columns and walls share them:
#
#   - An edge that walls cover goes to those walls.
#   - Any other edge is halved at its midpoint. Each half goes to the support
#     at its corner: the column there, else a wall at that corner.
#   - A corner with neither passes its half to the nearest support around the
#     boundary, and the edge is flagged as overhanging.

"""One column's share of a cell: area in m² and its plan outline in metres."""
struct ColumnSupportShare
    xy::NTuple{2, Float64}
    area::Float64
    polygon::Vector{NTuple{2, Float64}}
end

"""
One wall's share of a cell, or of the part of a cell on one side of a wall
that cuts it. `wall` indexes the `walls` argument of the split. Area in m²,
plan loops in metres.
"""
struct WallSupportShare
    wall::Int
    area::Float64
    polygons::Vector{Vector{NTuple{2, Float64}}}
end

# -----------------------------------------------------------------------------
# Plan geometry
# -----------------------------------------------------------------------------

const _GEOM_TOL = 1e-8
const _WALL_TOL = 1e-6

_sub(a::NTuple{2, Float64}, b::NTuple{2, Float64}) = (a[1] - b[1], a[2] - b[2])
_add(a::NTuple{2, Float64}, b::NTuple{2, Float64}) = (a[1] + b[1], a[2] + b[2])
_mul(a::NTuple{2, Float64}, s::Float64) = (a[1] * s, a[2] * s)
_dot(a::NTuple{2, Float64}, b::NTuple{2, Float64}) = a[1] * b[1] + a[2] * b[2]
_hypot(a::NTuple{2, Float64}) = hypot(a[1], a[2])
_near(a::NTuple{2, Float64}, b::NTuple{2, Float64}, tol::Float64=_GEOM_TOL) = _hypot(_sub(a, b)) <= tol
_lerp(p::NTuple{2, Float64}, q::NTuple{2, Float64}, t::Float64) = _add(p, _mul(_sub(q, p), t))

"""Signed area, positive counterclockwise."""
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
                push!(out, _lerp(s, e, ds / (ds - de)))
            end
            push!(out, e)
        elseif s_in
            push!(out, _lerp(s, e, ds / (ds - de)))
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

"""Even-odd test; a point on the boundary counts as inside."""
function _in_polygon(p, verts)
    length(verts) < 3 && return false
    n = length(verts)
    @inbounds for i in 1:n
        _seg_distance(p, verts[i], verts[i == n ? 1 : i + 1]) <= 1e-7 && return true
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

"""Distance from `p` to the segment `a`–`b`."""
function _seg_distance(p, a, b)
    ab = _sub(b, a)
    den = _dot(ab, ab)
    den < 1e-24 && return _hypot(_sub(p, a))
    t = clamp(_dot(_sub(p, a), ab) / den, 0.0, 1.0)
    return _hypot(_sub(p, _add(a, _mul(ab, t))))
end

function _boundary_distance(p, poly)
    n = length(poly)
    return minimum(_seg_distance(p, poly[i], poly[mod1(i + 1, n)]) for i in 1:n)
end

_strictly_inside(p, poly) = _in_polygon(p, poly) && _boundary_distance(p, poly) > _WALL_TOL

"""True when both ends of `A`–`B` lie on the infinite line through `P` and `Q`."""
function _on_line(A, B, P, Q)
    d = _sub(Q, P)
    L = _hypot(d)
    L < _WALL_TOL && return false
    nrm = (-d[2] / L, d[1] / L)
    return abs(_dot(_sub(A, P), nrm)) <= _WALL_TOL && abs(_dot(_sub(B, P), nrm)) <= _WALL_TOL
end

"""
Drop a vertex that repeats the one before it, or that is the tip of an
out-and-back spur (`a → b → a`).

A straight-skeleton edge polygon can list the spoke to its apex twice. The
spoke has no area, and leaving it in makes the outline fail a vertex check.
"""
function _drop_spurs(loop, tol)
    out = copy(loop)
    changed = true
    while changed && length(out) >= 3
        changed = false
        m = length(out)
        for i in 1:m
            a, b, c = out[mod1(i - 1, m)], out[i], out[mod1(i + 1, m)]
            (_near(a, b, tol) || _near(a, c, tol)) || continue
            deleteat!(out, i)
            changed = true
            break
        end
    end
    return out
end

"""Drop repeated, spur, and collinear vertices from a closed loop."""
function _clean_loop(loop, tol)
    return _drop_collinear(_drop_spurs(loop, tol), tol)
end

"""Drop repeated and collinear vertices from a closed loop."""
function _drop_collinear(loop, tol)
    out = copy(loop)
    changed = true
    while changed && length(out) >= 3
        changed = false
        m = length(out)
        for i in 1:m
            a, b, c = out[mod1(i - 1, m)], out[i], out[mod1(i + 1, m)]
            ab = _sub(b, a)
            bc = _sub(c, b)
            cross = ab[1] * bc[2] - ab[2] * bc[1]
            if abs(cross) <= tol * max(_hypot(ab) + _hypot(bc), 1.0) && _dot(ab, bc) >= 0
                deleteat!(out, i)
                changed = true
                break
            end
        end
    end
    return out
end

"""
Replace vertices closer than `tol` with one representative, in first-seen order.

Adjacent edge polygons of one straight skeleton compute their shared vertex
separately, and those copies disagree by about 1e-7 m. Until they are one
point, the shared boundary does not cancel and a column's two halves stay
two outlines.
"""
function _snap_loops(loops, tol)
    reps = NTuple{2, Float64}[]
    snapped = Vector{NTuple{2, Float64}}[]
    for loop in loops
        out = NTuple{2, Float64}[]
        for p in loop
            k = findfirst(r -> _near(r, p, tol), reps)
            if k === nothing
                push!(reps, p)
                push!(out, p)
            else
                push!(out, reps[k])
            end
        end
        push!(snapped, out)
    end
    return snapped
end

"""
Union of polygons that tile one region and meet along shared edges, as
counterclockwise loops, largest first.

Vertices closer than `tol` are one point, then each edge is split at every
vertex of the other polygons that lies on it, so two pieces that share a
boundary cut at different points still cancel along it. An edge whose reverse
is also present is interior and dropped; the rest are chained into loops.
"""
function _merge_loops(polys; tol::Float64 = 1e-6)
    loops = Vector{NTuple{2, Float64}}[]
    for p in polys
        q = _ensure_ccw(p)
        length(q) >= 3 && abs(_shoelace(q)) > 1e-12 && push!(loops, q)
    end
    loops = [_clean_loop(q, tol) for q in _snap_loops(loops, tol)]
    filter!(q -> length(q) >= 3 && abs(_shoelace(q)) > 1e-12, loops)
    length(loops) <= 1 && return loops
    pts = reduce(vcat, loops)
    edges = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    for loop in loops
        m = length(loop)
        for i in 1:m
            p, q = loop[i], loop[mod1(i + 1, m)]
            d = _sub(q, p)
            L = _hypot(d)
            L < tol && continue
            ts = Float64[]
            for v in pts
                t = _dot(_sub(v, p), d) / (L * L)
                tol < t * L < L - tol || continue
                _hypot(_sub(v, _add(p, _mul(d, t)))) <= tol && push!(ts, t)
            end
            sort!(ts)
            prev = p
            for t in ts
                x = _add(p, _mul(d, t))
                _near(x, prev, tol) && continue
                push!(edges, (prev, x))
                prev = x
            end
            _near(prev, q, tol) || push!(edges, (prev, q))
        end
    end
    alive = trues(length(edges))
    for i in eachindex(edges)
        alive[i] || continue
        for j in (i + 1):length(edges)
            alive[j] || continue
            if _near(edges[i][1], edges[j][2], tol) && _near(edges[i][2], edges[j][1], tol)
                alive[i] = alive[j] = false
                break
            end
        end
    end
    rest = edges[alive]
    used = falses(length(rest))
    out = Vector{NTuple{2, Float64}}[]
    for s in eachindex(rest)
        used[s] && continue
        used[s] = true
        loop = NTuple{2, Float64}[rest[s][1]]
        cur = rest[s][2]
        for _ in eachindex(rest)
            _near(cur, loop[1], tol) && break
            push!(loop, cur)
            k = findfirst(i -> !used[i] && _near(rest[i][1], cur, tol), eachindex(rest))
            k === nothing && break
            used[k] = true
            cur = rest[k][2]
        end
        loop = _clean_loop(loop, tol)
        length(loop) >= 3 && abs(_shoelace(loop)) > 1e-12 && push!(out, loop)
    end
    sort!(out; by = l -> -abs(_shoelace(l)))
    return out
end

# -----------------------------------------------------------------------------
# One edge polygon
# -----------------------------------------------------------------------------

"""
Direction the edge's load slices run in: the inward normal of edge
direction `dir` for a two-way partition, else the span `axis`.
"""
function _slice_direction(dir, axis)
    inward = (-dir[2], dir[1])
    axis === nothing && return inward
    a = (Float64(axis[1]), Float64(axis[2]))
    La = _hypot(a)
    La < 1e-12 && return inward
    a = _mul(a, 1 / La)
    abs(_dot(a, inward)) < 1e-9 && return inward
    return _dot(a, inward) < 0 ? _mul(a, -1.0) : a
end

"""
`∫ w ds` of a load profile over `[s0, s1]`. Positions are fractions of the
edge, widths in metres; a repeated position is a step.
"""
function _profile_integral(ps, pw, s0, s1)
    total = 0.0
    for i in 1:(length(ps) - 1)
        a, b = ps[i], ps[i + 1]
        b - a > 1e-15 || continue
        lo, hi = max(a, s0), min(b, s1)
        hi > lo || continue
        slope = (pw[i + 1] - pw[i]) / (b - a)
        wa = pw[i] + slope * (lo - a)
        wb = pw[i] + slope * (hi - a)
        total += 0.5 * (wa + wb) * (hi - lo)
    end
    return total
end

"""
Part of `poly` between the slice lines at fractions `s0` and `s1` of edge
`P → P + L dir`. A slice line runs along `t`. An infinite bound is open.
"""
function _clip_band(poly, P, dir, t, L, s0, s1)
    n = (-t[2], t[1])
    _dot(n, dir) < 0 && (n = _mul(n, -1.0))
    out = poly
    isfinite(s0) && (out = _clip_halfplane(out, _add(P, _mul(dir, s0 * L)), n))
    isfinite(s1) && length(out) >= 3 &&
        (out = _clip_halfplane(out, _add(P, _mul(dir, s1 * L)), _mul(n, -1.0)))
    return out
end

# -----------------------------------------------------------------------------
# Supports at the corners
# -----------------------------------------------------------------------------

"""
Walls that lie on edge `P`→`Q`, as `(wall index, lo, hi)` in metres from `P`,
when together they cover the whole edge. Otherwise empty. Two walls that
overlap along the edge throw: the slab would be given to both.
"""
function _edge_cover(P, Q, walls)
    d = _sub(Q, P)
    L = _hypot(d)
    L < _WALL_TOL && return Tuple{Int, Float64, Float64}[]
    dir = _mul(d, 1 / L)
    found = Tuple{Int, Float64, Float64}[]
    for (k, (A, B)) in enumerate(walls)
        _on_line(A, B, P, Q) || continue
        sA = _dot(_sub(A, P), dir)
        sB = _dot(_sub(B, P), dir)
        lo = max(min(sA, sB), 0.0)
        hi = min(max(sA, sB), L)
        hi - lo > _WALL_TOL && push!(found, (k, lo, hi))
    end
    isempty(found) && return found
    sort!(found; by = t -> t[2])
    reach = 0.0
    for (k, lo, hi) in found
        lo < reach - _WALL_TOL && throw(ArgumentError(
            "Two walls overlap along the cell edge from $P to $Q; the slab " *
            "there cannot be given to both."))
        lo > reach + _WALL_TOL && return Tuple{Int, Float64, Float64}[]
        reach = max(reach, hi)
    end
    reach < L - _WALL_TOL && return Tuple{Int, Float64, Float64}[]
    return found
end

"""
Support at corner `i` for the half of edge `j` next to it: `(:column, c)`,
`(:wall, k)`, or `nothing`.

A column wins. Otherwise a wall that ends at or passes through the corner:
first one on the line of edge `j`, then one on the line of the other edge at
the corner, then any. Ties go to the lower index.
"""
function _corner_support(i, j, cell, col_at, walls)
    col_at[i] === nothing || return (:column, col_at[i])
    n = length(cell)
    v = cell[i]
    P, Q = cell[j], cell[mod1(j + 1, n)]
    other = j == i ? mod1(i - 1, n) : i
    R, S = cell[other], cell[mod1(other + 1, n)]
    best = nothing
    rank = 3
    for (k, (A, B)) in enumerate(walls)
        _seg_distance(v, A, B) <= _WALL_TOL || continue
        r = _on_line(A, B, P, Q) ? 0 : _on_line(A, B, R, S) ? 1 : 2
        if r < rank
            best, rank = k, r
        end
    end
    return best === nothing ? nothing : (:wall, best)
end

"""
Owner of the half of edge `j` at corner `i`, and whether it came from
another corner. A corner with no support walks the boundary both ways to the
nearest corner that has one. A tie goes the way through edge `j`.
"""
function _half_owner(i, j, cell, col_at, walls)
    own = _corner_support(i, j, cell, col_at, walls)
    own === nothing || return (own, false)
    n = length(cell)
    toward = j == i ? 1 : -1
    best = nothing
    best_d = Inf
    for step in (toward, -toward)
        k = i
        dist = 0.0
        for _ in 1:(n - 1)
            nk = mod1(k + step, n)
            dist += _hypot(_sub(cell[nk], cell[k]))
            sup = _corner_support(nk, step == 1 ? k : nk, cell, col_at, walls)
            if sup !== nothing
                dist < best_d - 1e-9 && ((best, best_d) = (sup, dist))
                break
            end
            k = nk
        end
    end
    return (best, true)
end

# -----------------------------------------------------------------------------
# Public split
# -----------------------------------------------------------------------------

"""
    split_cell_edges(cell, tribs, columns, walls; axis=nothing, flag_overhang=true)
        -> (columns, walls, overhang)

Share one cell's edge polygons between its columns and walls.

`cell` is the plan outline in metres, counterclockwise, in the vertex order
`tribs` was computed with (one `TributaryPolygon` per edge, by
`local_edge_idx`). `axis` is the span axis of a one-way partition, or
`nothing`. `columns` are points; a column that is not a cell vertex gets
nothing. `walls` are plan segments `(a, b)`.

- An edge that walls on its line cover end to end goes to those walls,
  clipped to each wall's extent. A wall that covers only part of an edge
  does not take that edge.
- Any other edge is halved at its midpoint, cut along the load slices. Each
  half goes to the column at its corner, else to a wall that ends at or
  passes through that corner.
- A corner with neither passes its half to the nearest support around the
  cell boundary. With `flag_overhang`, that edge is listed in `overhang`.

Areas come from each edge's load profile, so an opening is not counted.
Polygons are the edge outlines clipped at the same cuts. `columns` in the
result has one entry per input column, `nothing` when it is not a vertex.
`walls` has one [`WallSupportShare`](@ref) per wall with area. With no
support at any corner and no wall on any edge, every share is empty.
"""
function split_cell_edges(cell_in, tribs, columns, walls; axis = nothing, flag_overhang::Bool = true)
    cell = NTuple{2, Float64}[(Float64(p[1]), Float64(p[2])) for p in cell_in]
    n = length(cell)
    n >= 3 || throw(ArgumentError("A cell needs at least 3 vertices."))
    _shoelace(cell) > _GEOM_TOL || throw(ArgumentError(
        "Cell vertices must run counterclockwise, the order its edge polygons were computed in."))

    col_at = Union{Nothing, Int}[findfirst(c -> _near((Float64(c[1]), Float64(c[2])), v, 1e-6), columns)
                                 for v in cell]
    covers = [_edge_cover(cell[j], cell[mod1(j + 1, n)], walls) for j in 1:n]
    col_area = zeros(length(columns))
    col_polys = [Vector{NTuple{2, Float64}}[] for _ in columns]
    wall_area = zeros(length(walls))
    wall_polys = [Vector{NTuple{2, Float64}}[] for _ in walls]
    overhang = NTuple{2, NTuple{2, Float64}}[]

    supported = any(c -> c !== nothing, col_at) || any(!isempty, covers) ||
                any(i -> _corner_support(i, i, cell, col_at, walls) !== nothing, 1:n)
    if !supported
        empty_cols = Union{Nothing, ColumnSupportShare}[nothing for _ in columns]
        for (i, c) in enumerate(col_at)
            c === nothing || (empty_cols[c] = ColumnSupportShare(columns[c], 0.0, NTuple{2, Float64}[]))
        end
        return (columns = empty_cols, walls = WallSupportShare[], overhang = overhang)
    end

    function give!(owner, area, poly)
        kind, idx = owner
        if kind === :column
            col_area[idx] += area
            length(poly) >= 3 && push!(col_polys[idx], poly)
        else
            wall_area[idx] += area
            length(poly) >= 3 && push!(wall_polys[idx], poly)
        end
    end

    total = 0.0
    for trib in tribs
        j = trib.local_edge_idx
        1 <= j <= n || throw(ArgumentError("Edge polygon $j does not match a $n-vertex cell."))
        trib.area > 1e-12 || continue
        total += trib.area
        P, Q = cell[j], cell[mod1(j + 1, n)]
        d = _sub(Q, P)
        L = _hypot(d)
        dir = _mul(d, 1 / L)
        t = _slice_direction(dir, axis)
        outline = Asap.vertices(trib, P, Q)
        piece(s0, s1) = (L * _profile_integral(trib.profile_s, trib.profile_w, s0, s1),
                         _clip_band(outline, P, dir, t, L, s0, s1))
        cover = covers[j]
        if !isempty(cover)
            for (m, (k, lo, hi)) in enumerate(cover)
                give!((:wall, k), piece(m == 1 ? -Inf : lo / L,
                                        m == length(cover) ? Inf : hi / L)...)
            end
            continue
        end
        a_owner, a_far = _half_owner(j, j, cell, col_at, walls)
        b_owner, b_far = _half_owner(mod1(j + 1, n), j, cell, col_at, walls)
        flag_overhang && (a_far || b_far) && push!(overhang, (P, Q))
        if a_owner == b_owner
            give!(a_owner, piece(-Inf, Inf)...)
        else
            give!(a_owner, piece(-Inf, 0.5)...)
            give!(b_owner, piece(0.5, Inf)...)
        end
    end

    given = sum(col_area) + sum(wall_area)
    abs(given - total) <= 1e-6 * max(total, 1.0) || error(
        "Cell split gave $given m² of its $total m² of edge polygons.")

    col_shares = Union{Nothing, ColumnSupportShare}[nothing for _ in columns]
    for (i, c) in enumerate(col_at)
        c === nothing && continue
        loops = _merge_loops(col_polys[c])
        if length(loops) > 1
            @warn "A column's share of a cell is in $(length(loops)) pieces; only the largest outline is stored." column = columns[c]
        end
        col_shares[c] = ColumnSupportShare(columns[c], col_area[c],
                                           isempty(loops) ? NTuple{2, Float64}[] : loops[1])
    end
    wall_shares = WallSupportShare[]
    for k in eachindex(walls)
        wall_area[k] > 1e-12 || continue
        push!(wall_shares, WallSupportShare(k, wall_area[k], _merge_loops(wall_polys[k])))
    end
    return (columns = col_shares, walls = wall_shares, overhang = overhang)
end

# -----------------------------------------------------------------------------
# Cells cut by walls through the interior
# -----------------------------------------------------------------------------

"""Part of segment `A`–`B` inside a convex counterclockwise polygon, or `nothing`."""
function _clip_segment(A, B, poly)
    d = _sub(B, A)
    t0, t1 = 0.0, 1.0
    n = length(poly)
    for i in 1:n
        a = poly[i]
        e = _sub(poly[mod1(i + 1, n)], a)
        nin = (-e[2], e[1])
        num = _dot(_sub(A, a), nin)
        den = _dot(d, nin)
        if abs(den) < 1e-14
            num < -1e-12 && return nothing
            continue
        end
        t = -num / den
        den > 0 ? (t0 = max(t0, t)) : (t1 = min(t1, t))
        t0 > t1 + 1e-12 && return nothing
    end
    p = _lerp(A, B, t0)
    q = _lerp(A, B, t1)
    _hypot(_sub(q, p)) <= _WALL_TOL && return nothing
    return (p, q)
end

"""The part of wall `A`–`B` that runs through the interior of `poly`, or `nothing`."""
function _interior_part(A, B, poly)
    part = _clip_segment(A, B, poly)
    part === nothing && return nothing
    p, q = part
    _strictly_inside(_lerp(p, q, 0.5), poly) || return nothing
    return part
end

"""Cut convex `poly` along the line through `p`–`q`. Both halves keep its orientation."""
function _cut_polygon(poly, p, q)
    d = _sub(q, p)
    normal = (-d[2], d[1])
    return _clip_halfplane(poly, p, normal), _clip_halfplane(poly, p, _mul(normal, -1.0))
end

"""Walls on one line that touch or overlap, merged into one segment each."""
function _collinear_runs(walls)
    runs = NTuple{2, NTuple{2, Float64}}[(A, B) for (A, B) in walls if _hypot(_sub(B, A)) > _WALL_TOL]
    merged = true
    while merged
        merged = false
        for i in eachindex(runs), j in eachindex(runs)
            i < j || continue
            A, B = runs[i]
            C, D = runs[j]
            _on_line(C, D, A, B) || continue
            dir = _mul(_sub(B, A), 1 / _hypot(_sub(B, A)))
            s = (0.0, _dot(_sub(B, A), dir), _dot(_sub(C, A), dir), _dot(_sub(D, A), dir))
            min(s[2], max(s[3], s[4])) + _WALL_TOL >= max(0.0, min(s[3], s[4])) || continue
            runs[i] = (_add(A, _mul(dir, minimum(s))), _add(A, _mul(dir, maximum(s))))
            deleteat!(runs, j)
            merged = true
            break
        end
    end
    return runs
end

"""`TributaryPolygon`s of a plan outline in metres, with the same partition as its cell."""
_part_edge_polygons(part, axis, holes) =
    _edge_polygons([Meshes.Point(p[1], p[2]) for p in part], axis, holes)

"""
    split_cell_walls(cell, columns, walls; tribs=nothing, axis=nothing,
                     holes=nothing, flag_overhang=true) -> (columns, walls, overhang)

Split a cell between `columns` (points) and `walls` (segments `(a, b)`
anywhere in plan), with [`split_cell_edges`](@ref) doing each split.

`cell` is counterclockwise in metres. `tribs` are its edge polygons in that
vertex order; without them they are computed with `axis` (`nothing` for the
straight skeleton) and the opening loops `holes`.

- A wall that runs through the cell interior cuts the cell along its line.
  Walls on one line that meet, such as a through-wall split at a tee, are
  one cut. A cut must reach the boundary of the part it cuts at both ends,
  possibly another wall that has already cut. One that ends inside throws.
  Each part gets its own edge polygons, so the cut wall is an edge wall on
  both sides. A cut cell with an opening throws.
- A column is used in the part whose vertex it is. A column at a vertex of
  two parts throws.

`columns` in the result is one entry per input column: its share, or
`nothing` when no part has it as a vertex. `walls` is one
[`WallSupportShare`](@ref) per wall and part. Areas are m², and the column
and wall areas add to the area of the parts that have a support.
"""
function split_cell_walls(cell_in, columns, walls; tribs = nothing, axis = nothing,
                          holes = nothing, flag_overhang::Bool = true)
    cell = NTuple{2, Float64}[(Float64(p[1]), Float64(p[2])) for p in cell_in]
    length(cell) >= 3 || throw(ArgumentError("A cell needs at least 3 vertices."))
    _shoelace(cell) > _GEOM_TOL || throw(ArgumentError(
        "Cell vertices must run counterclockwise."))
    parts = [cell]
    lines = _collinear_runs(walls)
    interior = Int[k for (k, (A, B)) in enumerate(lines) if _interior_part(A, B, cell) !== nothing]
    changed = true
    while changed
        changed = false
        for k in interior, i in eachindex(parts)
            A, B = lines[k]
            part = _interior_part(A, B, parts[i])
            part === nothing && continue
            p, q = part
            (_boundary_distance(p, parts[i]) <= _WALL_TOL &&
             _boundary_distance(q, parts[i]) <= _WALL_TOL) || continue
            left, right = _cut_polygon(parts[i], p, q)
            (length(left) >= 3 && length(right) >= 3) || continue
            parts[i] = left
            push!(parts, right)
            changed = true
            break
        end
    end
    for k in interior, part in parts
        A, B = lines[k]
        _interior_part(A, B, part) === nothing && continue
        throw(ArgumentError(
            "The wall from $A to $B ends inside a slab cell. A wall that does " *
            "not reach the cell boundary, or another wall, is not split yet."))
    end
    cut = length(parts) > 1
    cut && holes !== nothing && !isempty(holes) && throw(ArgumentError(
        "A slab cell with an opening is cut by a wall; that split is not supported yet."))

    col_shares = Union{Nothing, ColumnSupportShare}[nothing for _ in columns]
    wall_shares = WallSupportShare[]
    overhang = NTuple{2, NTuple{2, Float64}}[]
    for part in parts
        idx = Int[i for (i, c) in enumerate(columns)
                  if any(v -> _near(v, (Float64(c[1]), Float64(c[2])), 1e-6), part)]
        for i in idx
            col_shares[i] === nothing || throw(ArgumentError(
                "The column at $(columns[i]) is a vertex of two parts of a cell cut " *
                "by a wall. That split is not supported yet."))
        end
        part_tribs = !cut && tribs !== nothing ? tribs : _part_edge_polygons(part, axis, holes)
        split = split_cell_edges(part, part_tribs, columns[idx], walls; axis, flag_overhang)
        for (share, i) in zip(split.columns, idx)
            col_shares[i] = share
        end
        append!(wall_shares, split.walls)
        append!(overhang, split.overhang)
    end
    return (columns = col_shares, walls = wall_shares, overhang = overhang)
end

# -----------------------------------------------------------------------------
# Building pass
# -----------------------------------------------------------------------------

"""
Indices of the walls that hold up a slab at `cell_z`: the wall's top is that
elevation. The top is the next story with faces
([`StructuralSizer._wall_end_elevations_m`](@ref)), the same pier height the
wall is built with. A wall that stands on the slab does not support it.
"""
function _cell_top_walls(struc, cell_z)
    skel = struc.skeleton
    out = Int[]
    for (i, wall) in enumerate(struc.walls)
        zs = StructuralSizer._wall_end_elevations_m(skel, wall.story)
        length(zs) == 2 || continue
        abs(zs[2] - cell_z) < 0.1 && push!(out, i)
    end
    return out
end

"""
    compute_column_tributaries!(struc::BuildingStructure)

Split each cell between the columns and the walls that hold it up, and store
the areas ([`split_cell_walls`](@ref), [`split_cell_edges`](@ref)).

The split uses the cell's edge polygons, the same ones the beams carry
([`cell_support_polygons`](@ref)). An edge that walls cover goes to them.
Any other edge is halved at its midpoint between the supports at its two
corners. A half whose corner has no column and no wall goes to the nearest
support around the cell; in a flat plate or flat slab that edge is recorded
in `struc._tributary_caches.overhang` and reported once.

Stored for columns in `struc._tributary_caches.vertex` and on the column:

- `column_tributary_area(struc, col)` → total area (m²)
- `column_tributary_by_cell(struc, col)` → Dict{Int, Float64}
- `column_tributary_polygons(struc, col)` → Dict{Int, Vector{NTuple{2,Float64}}}

A wall's share is `wall.tributary_cell_areas` and `wall.tributary_polygons`.
Each slab also receives the column and wall outlines in
`slab.tributary_polygons`.

Columns are matched to a floor by `(x, y)` and the elevation of
`vertex_idx`, the column's top. A wall is matched to the slab at its top,
the slab it holds up ([`_cell_top_walls`](@ref)).
"""
function compute_column_tributaries!(struc::BuildingStructure{T}) where T
    isempty(struc.columns) && isempty(struc.walls) && return struc

    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    cache = struc._tributary_caches
    empty!(cache.vertex)
    empty!(cache.vertex_computed)
    empty!(cache.strip_columns)
    empty!(cache.strip_walls)
    empty!(cache.overhang)
    for col in struc.columns
        empty!(col.tributary_cell_indices)
        empty!(col.tributary_cell_areas)
    end
    for wall in struc.walls
        empty!(wall.tributary_cell_areas)
        empty!(wall.tributary_polygons)
    end

    # (x, y) → columns (rounded, so a vertex and its column still meet)
    col_by_xy = Dict{Tuple{Float64, Float64}, Vector{Column{T}}}()
    for col in struc.columns
        xy = (round(vc[col.vertex_idx, 1], digits=6),
              round(vc[col.vertex_idx, 2], digits=6))
        push!(get!(col_by_xy, xy, Column{T}[]), col)
    end

    col_by_cell = Dict{Tuple{Int, Int}, Dict{Int, AreaQuantity}}()
    col_polygons = Dict{Tuple{Int, Int}, Dict{Int, Vector{NTuple{2, LengthQuantity}}}}()
    col_totals = Dict{Tuple{Int, Int}, AreaQuantity}()

    for (cell_idx, cell) in enumerate(struc.cells)
        v_indices = skel.face_vertex_indices[cell.face_idx]
        length(v_indices) < 3 && continue
        cell_z = vc[v_indices[1], 3]
        corners = NTuple{2, Float64}[(vc[vi, 1], vc[vi, 2]) for vi in v_indices]

        matched = Column{T}[]
        sites = NTuple{2, Float64}[]
        for xy in corners
            cols = get(col_by_xy, (round(xy[1], digits=6), round(xy[2], digits=6)), nothing)
            cols === nothing && continue
            for col in cols
                abs(vc[col.vertex_idx, 3] - cell_z) < 0.1 || continue
                push!(matched, col)
                push!(sites, xy)
                break
            end
        end
        here = _cell_top_walls(struc, cell_z)
        isempty(matched) && isempty(here) && continue

        segments = [((struc.walls[i].x1, struc.walls[i].y1), (struc.walls[i].x2, struc.walls[i].y2))
                    for i in here]
        tribs, axis = cell_support_polygons(struc, cell_idx)
        split = split_cell_walls(corners, sites, segments;
                                 tribs, axis, holes = face_opening_loops(skel, cell.face_idx),
                                 flag_overhang = _cell_is_beamless(cell))

        for (share, col) in zip(split.columns, matched)
            share === nothing && continue
            key = (col.story, col.vertex_idx)
            if !haskey(col_by_cell, key)
                col_by_cell[key] = Dict{Int, AreaQuantity}()
                col_polygons[key] = Dict{Int, Vector{NTuple{2, LengthQuantity}}}()
                col_totals[key] = 0.0u"m^2"
            end
            area_unitful = share.area * u"m^2"
            col_by_cell[key][cell_idx] = area_unitful
            col_polygons[key][cell_idx] = [(x * u"m", y * u"m") for (x, y) in share.polygon]
            col_totals[key] += area_unitful
        end

        for share in split.walls
            wall = struc.walls[here[share.wall]]
            wall.tributary_cell_areas[cell_idx] = get(wall.tributary_cell_areas, cell_idx, 0.0) + share.area
            append!(get!(() -> Vector{NTuple{2, Float64}}[], wall.tributary_polygons, cell_idx),
                    share.polygons)
        end
        isempty(split.overhang) || (cache.overhang[cell_idx] = split.overhang)
    end

    if !isempty(cache.overhang)
        @warn "Slab edges with a corner that has no column or wall; that slab goes to the nearest support around the cell." cells = sort!(collect(keys(cache.overhang)))
    end

    for (key, total_area) in col_totals
        story, vertex_idx = key
        cache_column_tributary!(struc, story, vertex_idx, total_area,
                                col_by_cell[key], col_polygons[key])
    end
    for col in struc.columns
        key = (col.story, col.vertex_idx)
        haskey(col_by_cell, key) || continue
        col.tributary_cell_indices = Set(keys(col_by_cell[key]))
        col.tributary_cell_areas = Dict{Int, Float64}(
            cell_idx => ustrip(u"m^2", area) for (cell_idx, area) in col_by_cell[key])
    end

    refresh_edge_strip_tributaries!(struc)
    _assign_slab_tributary_polygons!(struc)
    return struc
end

"""
Copy the column and wall outlines onto the slabs that own those cells. A
beam-supported cell with no wall share is left to its edge polygons.
"""
function _assign_slab_tributary_polygons!(struc::BuildingStructure)
    for slab in struc.slabs
        empty!(slab.tributary_polygons)
    end
    isempty(struc.slabs) && return struc
    by_cell = Dict{Int, Vector{SlabTributaryPolygon}}()

    function _keep(cell_idx)
        1 <= cell_idx <= length(struc.cells) || return false
        _cell_is_beamless(struc.cells[cell_idx]) && return true
        return any(w -> !isempty(get(w.tributary_polygons, cell_idx, ())), struc.walls)
    end

    for (owner, col) in enumerate(struc.columns)
        for (cell_idx, poly) in column_tributary_polygons(struc, col)
            _keep(cell_idx) || continue
            xy = NTuple{2, Float64}[(ustrip(u"m", x), ustrip(u"m", y)) for (x, y) in poly]
            length(xy) < 3 && continue
            push!(get!(by_cell, cell_idx, SlabTributaryPolygon[]),
                  SlabTributaryPolygon(cell_idx, :column, owner, xy))
        end
    end
    for (owner, wall) in enumerate(struc.walls)
        for (cell_idx, loops) in wall.tributary_polygons
            _keep(cell_idx) || continue
            for xy in loops
                length(xy) < 3 && continue
                push!(get!(by_cell, cell_idx, SlabTributaryPolygon[]),
                      SlabTributaryPolygon(cell_idx, :wall, owner, xy))
            end
        end
    end
    for slab in struc.slabs, cell_idx in slab.cell_indices
        append!(slab.tributary_polygons, get(by_cell, cell_idx, SlabTributaryPolygon[]))
    end
    return struc
end

"""
    wall_tributary_area(wall) -> Float64

Slab area this wall carries, in m², summed over the cells in
`wall.tributary_cell_areas`.
"""
wall_tributary_area(wall::Wall) = sum(values(wall.tributary_cell_areas); init=0.0)

# -----------------------------------------------------------------------------
# Line load along a wall
# -----------------------------------------------------------------------------

const _Gξ = (-sqrt(0.6), 0.0, sqrt(0.6))
const _GW = (5 / 9, 8 / 9, 5 / 9)

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
