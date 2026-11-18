# =============================================================================
# Slab past the centerlines, added to the column and wall shares
# =============================================================================

"""
    refresh_edge_strip_tributaries!(struc) -> struc

Add the slab past the column centerlines ([`slab_edge_strips`](@ref)) to the
column and wall tributary areas, replacing what an earlier call added.

Along its edge a strip goes to the supports whose share of the cell meets
that part of the edge (the split of [`compute_column_tributaries!`](@ref)):
a column's polygon, or a wall's. The corner slab at a run's start goes to
the column at that corner, else to the share that holds the edge's start. A
part of the edge that no share meets goes to the wall on that edge. With no
wall there, the supports on the edge take it in proportion. Call it again
after columns are resized.
"""
function refresh_edge_strip_tributaries!(struc::BuildingStructure)
    cache = struc._tributary_caches
    _remove_edge_strip_shares!(struc)
    owners = _cell_support_polygons(struc)
    isempty(owners) && return struc
    strips = slab_edge_strips(struc)
    isempty(strips) && return struc

    walls_by_cell = Dict{Int, Vector{Wall}}()
    for wall in struc.walls, ci in keys(wall.tributary_cell_areas)
        push!(get!(() -> Wall[], walls_by_cell, ci), wall)
    end

    for s in strips
        L = hypot(s.b[1] - s.a[1], s.b[2] - s.a[2])
        L > 1e-9 || continue
        cands = get(owners, s.cell, Tuple{Any, Vector{NTuple{2, Float64}}}[])
        inward = (-s.outward[1], -s.outward[2])
        e = 1e-4
        p = (s.a[1] + inward[1] * e, s.a[2] + inward[2] * e)
        q = (s.b[1] + inward[1] * e, s.b[2] + inward[2] * e)
        lens = Tuple{Any, Float64}[(key, _segment_length_inside(p, q, poly)) for (key, poly) in cands]
        filter!(t -> t[2] > 1e-6, lens)
        rest = L - sum((t[2] for t in lens); init = 0.0)
        if rest > 1e-6
            wall = _wall_on_edge(get(walls_by_cell, s.cell, Wall[]), s)
            if wall !== nothing
                _add_strip_share!(cache.strip_walls, wall, s.cell, s.width * rest)
            elseif !isempty(lens)
                scale = L / (L - rest)
                lens = [(key, len * scale) for (key, len) in lens]
            end
        end
        for (key, len) in lens
            _add_support_strip_share!(cache, key, s.cell, s.width * len)
        end
        s.corner_start > 0 || continue
        key = _corner_owner(cands, s, p, inward)
        if key !== nothing
            _add_support_strip_share!(cache, key, s.cell, s.corner_start)
        else
            wall = _wall_on_edge(get(walls_by_cell, s.cell, Wall[]), s)
            wall === nothing || _add_strip_share!(cache.strip_walls, wall, s.cell, s.corner_start)
        end
    end
    _apply_edge_strip_shares!(struc, 1.0)
    return struc
end

"""Record a strip share on a column (`(story, vertex)` key) or a wall."""
function _add_support_strip_share!(cache, key, cell::Int, area::Float64)
    key isa Tuple{Int, Int} && return _add_strip_share!(cache.strip_columns, key, cell, area)
    return _add_strip_share!(cache.strip_walls, key, cell, area)
end

"""Take the shares recorded in the cache back out of the support areas, then forget them."""
function _remove_edge_strip_shares!(struc::BuildingStructure)
    cache = struc._tributary_caches
    _apply_edge_strip_shares!(struc, -1.0)
    empty!(cache.strip_columns)
    empty!(cache.strip_walls)
    return struc
end

"""Add (`sign = 1`) or remove (`sign = -1`) the recorded shares on columns, the cache, and walls."""
function _apply_edge_strip_shares!(struc::BuildingStructure, sign::Float64)
    cache = struc._tributary_caches
    cols_at = Dict{Tuple{Int, Int}, Vector{eltype(struc.columns)}}()
    for col in struc.columns
        push!(get!(() -> eltype(struc.columns)[], cols_at, (col.story, col.vertex_idx)), col)
    end
    for (key, shares) in cache.strip_columns
        story, vi = key
        old = get_vertex_tributary(cache, story, vi)
        old === nothing && continue
        by_cell = copy(old.by_cell)
        for (ci, a) in shares
            v = get(by_cell, ci, 0.0u"m^2") + sign * a * u"m^2"
            # A cell the column reaches only through the strip leaves with it.
            if !haskey(old.polygons, ci) && ustrip(u"m^2", v) <= 1e-9
                delete!(by_cell, ci)
            else
                by_cell[ci] = v
            end
        end
        total = sum(values(by_cell); init = 0.0u"m^2")
        set_vertex_tributary!(cache, story, vi, ColumnTributaryResult(total, by_cell, old.polygons))
        for col in get(cols_at, key, eltype(struc.columns)[])
            col.tributary_cell_areas = Dict{Int, Float64}(ci => ustrip(u"m^2", a) for (ci, a) in by_cell)
            col.tributary_cell_indices = Set(keys(by_cell))
        end
    end
    for (wall, shares) in cache.strip_walls
        for (ci, a) in shares
            wall.tributary_cell_areas[ci] = get(wall.tributary_cell_areas, ci, 0.0) + sign * a
        end
    end
    return struc
end

function _add_strip_share!(store, key, cell::Int, area::Float64)
    area > 0 || return store
    shares = get!(() -> Dict{Int, Float64}(), store, key)
    shares[cell] = get(shares, cell, 0.0) + area
    return store
end

"""
Cell → each support's share polygons in metres. A column is keyed by
`(story, vertex)`, a wall by the `Wall` itself. Columns come first.
"""
function _cell_support_polygons(struc::BuildingStructure)
    owners = Dict{Int, Vector{Tuple{Any, Vector{NTuple{2, Float64}}}}}()
    for (story, by_vertex) in struc._tributary_caches.vertex, (vi, result) in by_vertex
        for (ci, poly) in result.polygons
            length(poly) >= 3 || continue
            pm = NTuple{2, Float64}[(ustrip(u"m", x), ustrip(u"m", y)) for (x, y) in poly]
            push!(get!(() -> Tuple{Any, Vector{NTuple{2, Float64}}}[], owners, ci), ((story, vi), pm))
        end
    end
    for wall in struc.walls, (ci, polys) in wall.tributary_polygons, poly in polys
        length(poly) >= 3 || continue
        push!(get!(() -> Tuple{Any, Vector{NTuple{2, Float64}}}[], owners, ci), (wall, poly))
    end
    return owners
end

"""The column at the strip's start vertex, else the share that holds the edge's start."""
function _corner_owner(cands, s, p, inward)
    for (key, _) in cands
        key isa Tuple{Int, Int} && key[2] == s.va && return key
    end
    L = hypot(s.b[1] - s.a[1], s.b[2] - s.a[2])
    t = min(1e-3, 0.5 * L)
    probe = (p[1] + (s.b[1] - s.a[1]) / L * t, p[2] + (s.b[2] - s.a[2]) / L * t)
    for (key, poly) in cands
        _point_in_polygon(probe, poly) && return key
    end
    return nothing
end

"""The wall whose plan line holds the strip's edge midpoint, or `nothing`."""
function _wall_on_edge(walls, s)
    mid = ((s.a[1] + s.b[1]) / 2, (s.a[2] + s.b[2]) / 2)
    for wall in walls
        StructuralSizer._segment_station(mid, (wall.x1, wall.y1), (wall.x2, wall.y2); tol = 0.05) ===
            nothing || return wall
    end
    return nothing
end

"""Length of segment `p`→`q` inside polygon `poly`."""
function _segment_length_inside(p, q, poly)
    d = (q[1] - p[1], q[2] - p[2])
    L = hypot(d...)
    L > 1e-12 || return 0.0
    ts = Float64[0.0, 1.0]
    n = length(poly)
    for i in 1:n
        a = poly[i]
        b = poly[mod1(i + 1, n)]
        e = (b[1] - a[1], b[2] - a[2])
        den = d[1] * e[2] - d[2] * e[1]
        abs(den) < 1e-14 && continue
        w = (a[1] - p[1], a[2] - p[2])
        t = (w[1] * e[2] - w[2] * e[1]) / den
        u = (w[1] * d[2] - w[2] * d[1]) / den
        (0 < t < 1 && -1e-12 <= u <= 1 + 1e-12) && push!(ts, t)
    end
    sort!(ts)
    inside = 0.0
    for k in 1:(length(ts) - 1)
        t0, t1 = ts[k], ts[k + 1]
        t1 - t0 > 1e-12 || continue
        tm = (t0 + t1) / 2
        _point_in_polygon((p[1] + tm * d[1], p[2] + tm * d[2]), poly) && (inside += (t1 - t0) * L)
    end
    return inside
end

"""Even-odd test for a plan point in a polygon."""
function _point_in_polygon(pt, poly)
    inside = false
    n = length(poly)
    j = n
    for i in 1:n
        yi, yj = poly[i][2], poly[j][2]
        if (yi > pt[2]) != (yj > pt[2])
            x = poly[i][1] + (pt[2] - yi) * (poly[j][1] - poly[i][1]) / (yj - yi)
            pt[1] < x && (inside = !inside)
        end
        j = i
    end
    return inside
end


