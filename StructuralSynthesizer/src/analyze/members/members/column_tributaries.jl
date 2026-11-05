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
    
    return struc
end


