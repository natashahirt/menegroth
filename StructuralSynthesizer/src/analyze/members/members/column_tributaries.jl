"""
Create a Column from a chain of shattered edge segments.

Uses the top vertex (highest Z) of the last edge in the chain for position
classification and story assignment.
"""
function _create_chain_column!(struc, skel, chain_seg_indices, chain_edge_indices,
                                L_total, Lb_gov, Cb_gov, default_Kx, default_Ky, vc, efc,
                                column_θ::Float64=0.0)
    # Use the top vertex of the chain (highest Z) for classification
    last_edge = chain_edge_indices[end]
    v1, v2 = skel.edge_indices[last_edge]
    z1 = vc[v1, 3]
    z2 = vc[v2, 3]
    vertex_idx = z1 > z2 ? v1 : v2
    
    story = edge_story(skel, last_edge)
    position, boundary_edge_dirs = classify_column_position(skel, vertex_idx, vc, efc)
    corner_angle = position == :corner ? slab_material_angle(skel, vertex_idx, vc) : 0.0
    corner_kind = classify_corner_kind(corner_angle, position)
    
    col = Column(chain_seg_indices, L_total;
                Lb=Lb_gov, Kx=default_Kx, Ky=default_Ky, Cb=Cb_gov,
                vertex_idx=vertex_idx, story=story, position=position,
                corner_kind=corner_kind, corner_angle=corner_angle,
                boundary_edge_dirs=boundary_edge_dirs, θ=column_θ)
    push!(struc.columns, col)
end

"""
    link_column_stack!(struc::BuildingStructure)

Populate `col.column_above` for every column by matching `(x, y)` position
across stories.  A column on story `s` is linked to the column at the same
`(x, y)` on story `s + 1`, if one exists.  Roof-level columns (no column
above) keep `column_above = nothing`.

Called automatically by `initialize_members!`.
"""
function link_column_stack!(struc::BuildingStructure)
    vc = struc.skeleton.geometry.vertex_coords

    # Build (x, y, story) → Column reference lookup
    ColT = eltype(struc.columns)
    lookup = Dict{Tuple{Float64, Float64, Int}, ColT}()
    for col in struc.columns
        key = (round(vc[col.vertex_idx, 1]; digits=COORD_DIGITS),
               round(vc[col.vertex_idx, 2]; digits=COORD_DIGITS),
               col.story)
        lookup[key] = col
    end

    n_linked = 0
    for col in struc.columns
        above_key = (round(vc[col.vertex_idx, 1]; digits=COORD_DIGITS),
                     round(vc[col.vertex_idx, 2]; digits=COORD_DIGITS),
                     col.story + 1)
        col.column_above = get(lookup, above_key, nothing)
        !isnothing(col.column_above) && (n_linked += 1)
    end

    @debug "Linked column stack" total=length(struc.columns) linked=n_linked roof=(length(struc.columns) - n_linked)
end

"""
    compute_column_tributaries!(struc::BuildingStructure)

Split each cell between the columns and the walls that bound it, and store
the areas.

A column keeps the larger of its corner-Voronoi region and the curved region
closer to it than to any wall ([`split_cell_supports`](@ref)). The walls
receive the complement, so a corner with no column no longer drops its area.
A cell with no wall uses a Voronoi of the real columns only.

Stored for columns in `struc._tributary_caches.vertex` and on the column:

- `column_tributary_area(struc, col)` → total area (m²)
- `column_tributary_by_cell(struc, col)` → Dict{Int, Float64}
- `column_tributary_polygons(struc, col)` → Dict{Int, Vector{NTuple{2,Float64}}}

A wall's share is `wall.tributary_cell_areas` and `wall.tributary_widths`.
Each slab also receives those column polygons and wall loops, curves
included, in `slab.tributary_polygons`.

Columns are matched to a floor by `(x, y)` and the elevation of
`vertex_idx`. A wall is matched when its plan line is at the cell elevation
and covers a full edge of the cell.
"""
function compute_column_tributaries!(struc::BuildingStructure{T}) where T
    isempty(struc.columns) && isempty(struc.walls) && return struc

    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    empty!(struc._tributary_caches.vertex)
    empty!(struc._tributary_caches.vertex_computed)
    empty!(struc._tributary_caches.strip_columns)
    empty!(struc._tributary_caches.strip_walls)
    for col in struc.columns
        empty!(col.tributary_cell_indices)
        empty!(col.tributary_cell_areas)
    end
    for wall in struc.walls
        empty!(wall.tributary_cell_areas)
        empty!(wall.tributary_widths)
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

        n_v = length(v_indices)
        corners = Vector{NTuple{2, Float64}}(undef, n_v)
        @inbounds for (k, vi) in enumerate(v_indices)
            corners[k] = (vc[vi, 1], vc[vi, 2])
        end

        matched = Column{T}[]
        sites = NTuple{2, Float64}[]
        for xy in corners
            key = (round(xy[1], digits=6), round(xy[2], digits=6))
            cols = get(col_by_xy, key, nothing)
            cols === nothing && continue
            for col in cols
                abs(vc[col.vertex_idx, 3] - cell_z) < 0.1 || continue
                push!(matched, col)
                push!(sites, xy)
                break
            end
        end
        wall_edges = _cell_wall_edges(struc, corners, cell_z)
        isempty(matched) && isempty(wall_edges) && continue

        segments = [(e[1], e[2]) for e in wall_edges]
        split = split_cell_supports(corners, sites, segments)

        for (share, col) in zip(split.columns, matched)
            key = (col.story, col.vertex_idx)
            if !haskey(col_by_cell, key)
                col_by_cell[key] = Dict{Int, AreaQuantity}()
                col_polygons[key] = Dict{Int, Vector{NTuple{2, LengthQuantity}}}()
                col_totals[key] = 0.0u"m^2"
            end
            area_unitful = share.area * u"m^2"
            polygon_unitful = [(x * u"m", y * u"m") for (x, y) in share.polygon]
            col_by_cell[key][cell_idx] = area_unitful
            col_polygons[key][cell_idx] = polygon_unitful
            col_totals[key] += area_unitful
        end

        for (share, edge) in zip(split.walls, wall_edges)
            wall = edge[3]
            share.area <= 0 && continue
            wall.tributary_cell_areas[cell_idx] = share.area
            pieces = WallWidthPiece[]
            for piece in share.pieces
                moved = _piece_on_wall(piece, edge[1], edge[2],
                                        (wall.x1, wall.y1), (wall.x2, wall.y2))
                moved === nothing && continue
                push!(pieces, moved)
            end
            wall.tributary_widths[cell_idx] = pieces
        end
    end
    
    # Store in cache (all values are now Unitful)
    for (key, total_area) in col_totals
        story, vertex_idx = key
        cache_column_tributary!(struc, story, vertex_idx,
            total_area,
            col_by_cell[key],
            col_polygons[key])
    end
    
    # Populate tributary fields directly on each Column for Sizer access
    for col in struc.columns
        key = (col.story, col.vertex_idx)
        if haskey(col_by_cell, key)
            col.tributary_cell_indices = Set(keys(col_by_cell[key]))
            col.tributary_cell_areas = Dict{Int, Float64}(
                cell_idx => ustrip(u"m^2", area) 
                for (cell_idx, area) in col_by_cell[key]
            )
        end
    end

    refresh_edge_strip_tributaries!(struc)
    _assign_slab_tributary_polygons!(struc)
    return struc
end

"""A flat plate or flat slab carries its area on columns and walls, not on the grid beams."""
_cell_is_beamless(cell) = cell.floor_type === :flat_plate || cell.floor_type === :flat_slab

"""Copy the column and wall shares onto the slabs that own those cells.

A column loop is the polygon [`split_cell_supports`](@ref) already sampled,
parabola included. A wall loop is the stored width law, and a parabolic
piece is sampled so the sagitta stays within 1 mm. A beam-supported cell
with no wall is left to its edge polygons.
"""
function _assign_slab_tributary_polygons!(struc::BuildingStructure)
    for slab in struc.slabs
        empty!(slab.tributary_polygons)
    end
    isempty(struc.slabs) && return struc
    by_cell = Dict{Int, Vector{SlabTributaryPolygon}}()
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords

    function _keep(cell_idx)
        1 <= cell_idx <= length(struc.cells) || return false
        _cell_is_beamless(struc.cells[cell_idx]) && return true
        return any(w -> haskey(w.tributary_widths, cell_idx) && !isempty(w.tributary_widths[cell_idx]),
                   struc.walls)
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
        for (cell_idx, pieces) in wall.tributary_widths
            _keep(cell_idx) || continue
            vis = skel.face_vertex_indices[struc.cells[cell_idx].face_idx]
            length(vis) < 3 && continue
            corners = NTuple{2, Float64}[(Float64(vc[v, 1]), Float64(vc[v, 2])) for v in vis]
            for xy in _wall_share_polygons(wall.x1, wall.y1, wall.x2, wall.y2, pieces, corners)
                push!(get!(by_cell, cell_idx, SlabTributaryPolygon[]),
                      SlabTributaryPolygon(cell_idx, :wall, owner, xy))
            end
        end
    end

    for slab in struc.slabs
        for cell_idx in slab.cell_indices
            append!(slab.tributary_polygons, get(by_cell, cell_idx, SlabTributaryPolygon[]))
        end
    end
    return struc
end

"""Closed plan loops for one wall's width pieces, offset into the cell.

A straight piece (`a == 0`) is a quadrilateral. A parabolic piece is sampled
so the sagitta of `w = a s² + b s + c` stays within `chord` metres.
"""
function _wall_share_polygons(x1, y1, x2, y2, pieces, corners; chord::Float64 = 1e-3)
    dx = x2 - x1
    dy = y2 - y1
    span = hypot(dx, dy)
    span < 1e-9 && return Vector{NTuple{2, Float64}}[]
    isempty(pieces) && return Vector{NTuple{2, Float64}}[]
    ux, uy = dx / span, dy / span
    nx, ny = -uy, ux
    cx = sum(p -> p[1], corners) / length(corners)
    cy = sum(p -> p[2], corners) / length(corners)
    if (cx - (x1 + x2) / 2) * nx + (cy - (y1 + y2) / 2) * ny < 0
        nx, ny = -nx, -ny
    end
    ordered = sort(collect(pieces); by = p -> p.u0)
    loops = Vector{NTuple{2, Float64}}[]
    group = typeof(ordered)()
    for piece in ordered
        if !isempty(group) && piece.u0 - group[end].u1 > 1e-6
            xy = _width_group_polygon(x1, y1, ux, uy, nx, ny, group; chord)
            xy === nothing || push!(loops, xy)
            empty!(group)
        end
        push!(group, piece)
    end
    xy = _width_group_polygon(x1, y1, ux, uy, nx, ny, group; chord)
    xy === nothing || push!(loops, xy)
    return loops
end

function _width_group_polygon(x1, y1, ux, uy, nx, ny, pieces; chord::Float64 = 1e-3)
    outer = NTuple{2, Float64}[]
    inner = NTuple{2, Float64}[]
    for (gi, piece) in enumerate(pieces)
        piece.u1 - piece.u0 < 1e-8 && continue
        steps = piece.a == 0 ? 1 : max(1, ceil(Int, (piece.u1 - piece.u0) / sqrt(2 * chord / abs(piece.a))))
        i0 = gi == 1 || isempty(outer) ? 0 : 1
        for i in i0:steps
            t = i / steps
            u = piece.u0 + t * (piece.u1 - piece.u0)
            s = u - piece.u0
            w = max(piece.a * s * s + piece.b * s + piece.c, 0.0)
            px = x1 + ux * u
            py = y1 + uy * u
            push!(outer, (px, py))
            push!(inner, (px + nx * w, py + ny * w))
        end
    end
    length(outer) < 2 && return nothing
    maximum(hypot(a[1] - b[1], a[2] - b[2]) for (a, b) in zip(outer, inner)) > 1e-6 || return nothing
    return vcat(outer, reverse(inner))
end

"""
    refresh_edge_strip_tributaries!(struc) -> struc

Add the slab past the column centerlines ([`slab_edge_strips`](@ref)) to the
column and wall tributary areas, replacing what an earlier call added.

Along its edge a strip goes to the supports whose share of the cell meets
that part of the edge (the split of [`compute_column_tributaries!`](@ref)).
The corner slab at a run's start goes to the column at that corner, else to
the support at the start of the edge. A part of the edge that no column
share meets goes to the wall on that edge. With no wall there, the columns
on the edge take it in proportion. Call it again after columns are resized.
"""
function refresh_edge_strip_tributaries!(struc::BuildingStructure)
    cache = struc._tributary_caches
    _remove_edge_strip_shares!(struc)
    isempty(cache.vertex) && return struc
    strips = slab_edge_strips(struc)
    isempty(strips) && return struc

    owners = _cell_column_polygons(cache)
    walls_by_cell = Dict{Int, Vector{Wall}}()
    for wall in struc.walls, ci in keys(wall.tributary_cell_areas)
        push!(get!(() -> Wall[], walls_by_cell, ci), wall)
    end

    for s in strips
        L = hypot(s.b[1] - s.a[1], s.b[2] - s.a[2])
        L > 1e-9 || continue
        cands = get(owners, s.cell, Tuple{Tuple{Int, Int}, Vector{NTuple{2, Float64}}}[])
        inward = (-s.outward[1], -s.outward[2])
        e = 1e-4
        p = (s.a[1] + inward[1] * e, s.a[2] + inward[2] * e)
        q = (s.b[1] + inward[1] * e, s.b[2] + inward[2] * e)
        lens = [(key, _segment_length_inside(p, q, poly)) for (key, poly) in cands]
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
            _add_strip_share!(cache.strip_columns, key, s.cell, s.width * len)
        end
        s.corner_start > 0 || continue
        key = _corner_owner(cands, s, p, inward)
        if key !== nothing
            _add_strip_share!(cache.strip_columns, key, s.cell, s.corner_start)
        else
            wall = _wall_on_edge(get(walls_by_cell, s.cell, Wall[]), s)
            wall === nothing || _add_strip_share!(cache.strip_walls, wall, s.cell, s.corner_start)
        end
    end
    _apply_edge_strip_shares!(struc, 1.0)
    return struc
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

"""Cell → each column's `(story, vertex)` key and its share polygon in metres."""
function _cell_column_polygons(cache)
    owners = Dict{Int, Vector{Tuple{Tuple{Int, Int}, Vector{NTuple{2, Float64}}}}}()
    for (story, by_vertex) in cache.vertex, (vi, result) in by_vertex
        for (ci, poly) in result.polygons
            length(poly) >= 3 || continue
            pm = NTuple{2, Float64}[(ustrip(u"m", x), ustrip(u"m", y)) for (x, y) in poly]
            push!(get!(() -> Tuple{Tuple{Int, Int}, Vector{NTuple{2, Float64}}}[], owners, ci),
                  ((story, vi), pm))
        end
    end
    return owners
end

"""The column at the strip's start vertex, else the share that holds the edge's start."""
function _corner_owner(cands, s, p, inward)
    for (key, _) in cands
        key[2] == s.va && return key
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


