"""
Create a Column from a chain of shattered edge segments.

Uses the top vertex (highest Z) of the last edge in the chain for position
classification and story assignment.
"""
function _create_chain_column!(struc, skel, chain_seg_indices, chain_edge_indices,
                                L_total, Lb_gov, Cb_gov, default_Kx, default_Ky, vc, efc)
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
                boundary_edge_dirs=boundary_edge_dirs)
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

Compute and store Voronoi vertex tributary areas in the TributaryCache.

For each cell:
1. Get the cell's corner vertices (column positions)
2. Compute Voronoi clipped to the cell boundary
3. Store in `struc._tributary_caches.vertex[story][vertex_idx]`

Access via:
- `column_tributary_area(struc, col)` → total area (m²)
- `column_tributary_by_cell(struc, col)` → Dict{Int, Float64}
- `column_tributary_polygons(struc, col)` → Dict{Int, Vector{NTuple{2,Float64}}}

Note: Columns use their bottom vertex_idx, but floor cells have vertices at the floor 
elevation. We match by (x,y) position to link columns to their supported floor areas.
"""
function compute_column_tributaries!(struc::BuildingStructure{T}) where T
    isempty(struc.columns) && return struc
    
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    
    # Build (x,y) → Column lookup (rounded to avoid FP precision issues)
    col_by_xy = Dict{Tuple{Float64, Float64}, Vector{Column{T}}}()
    for col in struc.columns
        xy = (round(vc[col.vertex_idx, 1], digits=6), 
              round(vc[col.vertex_idx, 2], digits=6))
        push!(get!(col_by_xy, xy, Column{T}[]), col)
    end
    
    # Temporary storage: (story, vertex_idx) → accumulated data
    col_by_cell = Dict{Tuple{Int, Int}, Dict{Int, AreaQuantity}}()
    col_polygons = Dict{Tuple{Int, Int}, Dict{Int, Vector{NTuple{2, LengthQuantity}}}}()
    col_totals = Dict{Tuple{Int, Int}, AreaQuantity}()
    
    # Process each cell
    for (cell_idx, cell) in enumerate(struc.cells)
        v_indices = skel.face_vertex_indices[cell.face_idx]
        length(v_indices) < 3 && continue
        
        # Get cell elevation from cached coordinates
        cell_z = vc[v_indices[1], 3]
        
        # Extract vertex positions from cached coordinates
        n_v = length(v_indices)
        col_positions = Vector{NTuple{2, Float64}}(undef, n_v)
        cell_xys = Vector{Tuple{Float64, Float64}}(undef, n_v)
        @inbounds for (k, vi) in enumerate(v_indices)
            x, y = vc[vi, 1], vc[vi, 2]
            col_positions[k] = (x, y)
            cell_xys[k] = (round(x, digits=6), round(y, digits=6))
        end
        
        # Compute Voronoi within cell boundary (boundary = cell vertices)
        tribs = StructuralSizer.compute_voronoi_tributaries(col_positions; floor_boundary=col_positions)
        
        # Store results (matching by x,y position)
        for (i, trib) in enumerate(tribs)
            xy = cell_xys[i]
            cols = get(col_by_xy, xy, nothing)
            isnothing(cols) && continue
            
            # vertex_idx is at the top (slab level) — match directly
            matched_col = nothing
            for col in cols
                if abs(vc[col.vertex_idx, 3] - cell_z) < 0.1
                    matched_col = col
                    break
                end
            end
            isnothing(matched_col) && continue
            
            # Accumulate in temp storage (converting to Unitful)
            key = (matched_col.story, matched_col.vertex_idx)
            if !haskey(col_by_cell, key)
                col_by_cell[key] = Dict{Int, AreaQuantity}()
                col_polygons[key] = Dict{Int, Vector{NTuple{2, LengthQuantity}}}()
                col_totals[key] = 0.0u"m^2"
            end
            
            area_unitful = trib.area * u"m^2"
            polygon_unitful = [(x * u"m", y * u"m") for (x, y) in trib.polygon]
            
            col_by_cell[key][cell_idx] = area_unitful
            col_polygons[key][cell_idx] = polygon_unitful
            col_totals[key] += area_unitful
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


