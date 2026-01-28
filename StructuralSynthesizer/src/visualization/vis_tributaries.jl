# Visualization for cell groups and tributary areas
# All coordinates are in METERS (SI units)

"""
    visualize_cell_groups(struc::BuildingStructure; kwargs...)

Plot each unique cell group geometry on its own axis. All coordinates in meters.

# Arguments
- `max_cols::Int=4`: Maximum columns in the grid layout.
- `show_edges::Bool=true`: Label edge indices on the polygon.
- `show_info::Bool=true`: Display cell count and floor type in title.
"""
function visualize_cell_groups(struc::BuildingStructure;
    max_cols::Int = 4,
    show_edges::Bool = true,
    show_info::Bool = true
)
    # Ensure cell groups exist
    isempty(struc.cell_groups) && build_cell_groups!(struc)
    
    groups = collect(values(struc.cell_groups))
    n_groups = length(groups)
    
    if n_groups == 0
        @warn "No cell groups to visualize"
        return GLMakie.Figure()
    end
    
    # Grid layout
    n_cols = min(n_groups, max_cols)
    n_rows = ceil(Int, n_groups / n_cols)
    
    fig = GLMakie.Figure(size = (300 * n_cols, 300 * n_rows))
    
    for (i, cg) in enumerate(groups)
        row = div(i - 1, n_cols) + 1
        col = mod(i - 1, n_cols) + 1
        
        # Get canonical cell
        canonical_idx = first(cg.cell_indices)
        cell = struc.cells[canonical_idx]
        
        # Extract 2D geometry in meters
        verts = _get_cell_vertices_2d(struc, cell)
        
        # Create axis
        title_str = "Group $(i)"
        if show_info
            ft = cell.floor_type
            n_cells = length(cg.cell_indices)
            title_str = "$(ft) (n=$(n_cells))"
        end
        
        ax = GLMakie.Axis(fig[row, col],
            title = title_str,
            aspect = GLMakie.DataAspect(),
            xlabel = "x [m]",
            ylabel = "y [m]"
        )
        
        # Plot polygon
        _plot_cell_polygon!(ax, verts; show_edges=show_edges, 
                           edge_ids=struc.skeleton.face_edge_indices[cell.face_idx])
    end
    
    return fig
end

"""Extract cell vertices as 2D points (meters) centered at origin."""
function _get_cell_vertices_2d(struc::BuildingStructure, cell::Cell)
    verts, offset = _get_cell_vertices_2d_with_offset(struc, cell)
    return [(v[1] - offset[1], v[2] - offset[2]) for v in verts]
end

"""Extract cell vertices as 2D points in meters (raw) and centering offset."""
function _get_cell_vertices_2d_with_offset(struc::BuildingStructure, cell::Cell)
    # Use same vertex source as tributary computation (face_vertex_indices)
    v_indices = struc.skeleton.face_vertex_indices[cell.face_idx]
    pts = [struc.skeleton.vertices[i] for i in v_indices]
    
    coords = NTuple{2, Float64}[]
    for p in pts
        c = Meshes.coords(p)
        # Convert to meters (matching TributaryPolygon internal storage)
        x = Float64(ustrip(u"m", c.x))
        y = Float64(ustrip(u"m", c.y))
        push!(coords, (x, y))
    end
    
    # IMPORTANT: Ensure CCW ordering to match tributary computation
    coords = StructuralSizer._ensure_ccw(coords)
    
    # Compute centroid offset
    cx = sum(v[1] for v in coords) / length(coords)
    cy = sum(v[2] for v in coords) / length(coords)
    
    return coords, (cx, cy)
end

"""Plot a 2D polygon with optional edge labels."""
function _plot_cell_polygon!(ax, verts::Vector{<:NTuple{2, Float64}}; 
                             show_edges::Bool=true, edge_ids::Vector{Int}=Int[])
    n = length(verts)
    n == 0 && return
    
    # Close the polygon
    xs = [v[1] for v in verts]
    ys = [v[2] for v in verts]
    push!(xs, xs[1])
    push!(ys, ys[1])
    
    # Fill
    GLMakie.poly!(ax, GLMakie.Point2f.(xs, ys), 
                  color = (:steelblue, 0.3), 
                  strokecolor = :black, 
                  strokewidth = 2)
    
    # Edge labels
    if show_edges && !isempty(edge_ids)
        for i in 1:n
            j = mod1(i + 1, n + 1)
            if j > n
                j = 1
            end
            mx = (verts[i][1] + verts[mod1(i+1, n)][1]) / 2
            my = (verts[i][2] + verts[mod1(i+1, n)][2]) / 2
            
            edge_label = i <= length(edge_ids) ? "e$(edge_ids[i])" : "e?"
            GLMakie.text!(ax, mx, my, text=edge_label, 
                         fontsize=10, align=(:center, :center), color=:red)
        end
    end
    
    # Vertex markers
    GLMakie.scatter!(ax, GLMakie.Point2f.(verts), color=:black, markersize=8)
end

"""
    visualize_cell_tributaries(struc::BuildingStructure; kwargs...)

Plot all cell groups with their tributary polygons (grid layout like visualize_cell_groups).
Automatically computes tributaries if not already computed. All coordinates in meters.

# Arguments
- `max_cols::Int=4`: Maximum columns in the grid layout.
- `show_labels::Bool=true`: Show edge index and fraction labels.
"""
function visualize_cell_tributaries(struc::BuildingStructure;
    max_cols::Int = 4,
    show_labels::Bool = true
)
    # Ensure cell groups and tributaries exist
    isempty(struc.cell_groups) && build_cell_groups!(struc)
    
    # Compute tributaries if any cell is missing them
    needs_compute = any(isnothing(c.tributary) for c in struc.cells)
    needs_compute && compute_cell_tributaries!(struc)
    
    groups = collect(values(struc.cell_groups))
    n_groups = length(groups)
    
    if n_groups == 0
        @warn "No cell groups to visualize"
        return GLMakie.Figure()
    end
    
    # Grid layout
    n_cols = min(n_groups, max_cols)
    n_rows = ceil(Int, n_groups / n_cols)
    
    fig = GLMakie.Figure(size = (350 * n_cols, 350 * n_rows))
    
    # Use StructuralPlots harmonic palette (main colors, no accents)
    colors = StructuralPlots.harmonic
    
    for (i, cg) in enumerate(groups)
        row = div(i - 1, n_cols) + 1
        col = mod(i - 1, n_cols) + 1
        
        # Get canonical cell
        canonical_idx = first(cg.cell_indices)
        cell = struc.cells[canonical_idx]
        
        # Create axis
        n_cells = length(cg.cell_indices)
        title_str = "$(cell.floor_type) (n=$(n_cells))"
        
        ax = GLMakie.Axis(fig[row, col],
            title = title_str,
            aspect = GLMakie.DataAspect(),
            xlabel = "x [m]",
            ylabel = "y [m]"
        )
        
        # Get cell vertices and centering offset (in meters)
        verts_raw, offset = _get_cell_vertices_2d_with_offset(struc, cell)
        verts = [(v[1] - offset[1], v[2] - offset[2]) for v in verts_raw]
        
        # Plot tributary polygons
        if !isnothing(cell.tributary)
            n_verts = length(verts_raw)
            for (j, trib) in enumerate(cell.tributary)
                if !isempty(trib.s)
                    # Get beam endpoints for this tributary (in meters)
                    local_idx = trib.local_edge_idx
                    beam_start = verts_raw[local_idx]
                    beam_end = verts_raw[mod1(local_idx + 1, n_verts)]
                    
                    # Compute absolute coordinates from parametric (all in meters)
                    trib_verts = vertices(trib, beam_start, beam_end)
                    
                    txs = [v[1] - offset[1] for v in trib_verts]
                    tys = [v[2] - offset[2] for v in trib_verts]
                    push!(txs, txs[1])
                    push!(tys, tys[1])
                    
                    c = colors[mod1(j, length(colors))]
                    GLMakie.poly!(ax, GLMakie.Point2f.(txs, tys),
                                 color = (c, 0.3),
                                 strokecolor = c,
                                 strokewidth = 1.5)
                end
                
                # Labels
                if show_labels
                    local_idx = trib.local_edge_idx
                    if local_idx <= length(verts)
                        label = "$(round(trib.fraction*100, digits=0))%"
                        mx = (verts[local_idx][1] + verts[mod1(local_idx+1, length(verts))][1]) / 2
                        my = (verts[local_idx][2] + verts[mod1(local_idx+1, length(verts))][2]) / 2
                        GLMakie.text!(ax, mx, my, text=label, fontsize=9, 
                                     align=(:center, :center), color=:black)
                    end
                end
            end
        end
        
        # Cell outline on top
        xs = [v[1] for v in verts]
        ys = [v[2] for v in verts]
        push!(xs, xs[1])
        push!(ys, ys[1])
        GLMakie.lines!(ax, xs, ys, color=:black, linewidth=2)
    end
    
    return fig
end

"""
    visualize_cell_tributary(struc::BuildingStructure, cell_idx::Int)

Plot a single cell with its tributary polygons (one per edge). All coordinates in meters.
"""
function visualize_cell_tributary(struc::BuildingStructure, cell_idx::Int)
    cell = struc.cells[cell_idx]
    
    # Compute if needed
    if isnothing(cell.tributary)
        compute_cell_tributaries!(struc)
        cell = struc.cells[cell_idx]  # refresh
    end
    
    fig = GLMakie.Figure(size = (600, 600))
    ax = GLMakie.Axis(fig[1, 1],
        title = "Cell $(cell_idx) Tributary Areas",
        aspect = GLMakie.DataAspect(),
        xlabel = "x [m]",
        ylabel = "y [m]"
    )
    
    # Get cell vertices and compute centering offset (in meters)
    verts_raw, offset = _get_cell_vertices_2d_with_offset(struc, cell)
    verts = [(v[1] - offset[1], v[2] - offset[2]) for v in verts_raw]
    
    # Use StructuralPlots harmonic palette (main colors, no accents)
    colors = StructuralPlots.harmonic
    
    # Plot tributary polygons
    if !isnothing(cell.tributary)
        n_verts = length(verts_raw)
        for (i, trib) in enumerate(cell.tributary)
            if !isempty(trib.s)
                # Get beam endpoints for this tributary (in meters)
                local_idx = trib.local_edge_idx
                beam_start = verts_raw[local_idx]
                beam_end = verts_raw[mod1(local_idx + 1, n_verts)]
                
                # Compute absolute coordinates from parametric (all in meters)
                trib_verts = vertices(trib, beam_start, beam_end)
                
                txs = [v[1] - offset[1] for v in trib_verts]
                tys = [v[2] - offset[2] for v in trib_verts]
                push!(txs, txs[1])
                push!(tys, tys[1])
                
                c = colors[mod1(i, length(colors))]
                GLMakie.poly!(ax, GLMakie.Point2f.(txs, tys),
                             color = (c, 0.3),
                             strokecolor = c,
                             strokewidth = 1.5)
            end
            
            # Label with local edge index and fraction
            local_idx = trib.local_edge_idx
            label = "e$(local_idx)\n$(round(trib.fraction*100, digits=1))%"
            if local_idx <= length(verts)
                mx = (verts[local_idx][1] + verts[mod1(local_idx+1, length(verts))][1]) / 2
                my = (verts[local_idx][2] + verts[mod1(local_idx+1, length(verts))][2]) / 2
                GLMakie.text!(ax, mx, my, text=label, fontsize=9, 
                             align=(:center, :center), color=:black)
            end
        end
    else
        GLMakie.text!(ax, 0.0, 0.0, text="No tributary data", 
                     fontsize=14, align=(:center, :center))
    end
    
    # Cell outline on top
    xs = [v[1] for v in verts]
    ys = [v[2] for v in verts]
    push!(xs, xs[1])
    push!(ys, ys[1])
    GLMakie.lines!(ax, xs, ys, color=:black, linewidth=2)
    
    return fig
end

# =============================================================================
# Vertex Tributary Visualization (Voronoi)
# =============================================================================

"""
    visualize_vertex_tributaries(struc::BuildingStructure; story=0, kwargs...)

Visualize stored Voronoi vertex tributary polygons for columns at a given story.
Uses pre-computed polygons from `col.tributary_polygons` (no recomputation).

# Arguments
- `story::Int=0`: Which story to visualize (0 = ground level columns)
- `show_labels::Bool=true`: Show column index and tributary area labels
- `show_column_positions::Bool=true`: Show column position markers

# Returns
GLMakie.Figure with colored Voronoi cells for each column.
"""
function visualize_vertex_tributaries(struc::BuildingStructure;
    story::Int = 0,
    show_labels::Bool = true,
    show_column_positions::Bool = true
)
    skel = struc.skeleton
    
    # Get columns at this story with their stored polygons
    story_cols = filter(c -> c.story == story, struc.columns)
    
    if isempty(story_cols)
        @warn "No columns found at story $story"
        return GLMakie.Figure()
    end
    
    # Collect all polygon vertices for centering
    all_xs = Float64[]
    all_ys = Float64[]
    for col in story_cols
        for (_, polygon) in col.tributary_polygons
            for v in polygon
                push!(all_xs, v[1])
                push!(all_ys, v[2])
            end
        end
        # Also include column position
        v = skel.vertices[col.vertex_idx]
        c = Meshes.coords(v)
        push!(all_xs, Float64(ustrip(u"m", c.x)))
        push!(all_ys, Float64(ustrip(u"m", c.y)))
    end
    
    if isempty(all_xs)
        @warn "No tributary polygons found for story $story"
        return GLMakie.Figure()
    end
    
    cx = (minimum(all_xs) + maximum(all_xs)) / 2
    cy = (minimum(all_ys) + maximum(all_ys)) / 2
    
    # Create figure
    fig = GLMakie.Figure(size = (700, 700))
    ax = GLMakie.Axis(fig[1, 1],
        title = "Vertex Tributaries (Story $story)",
        aspect = GLMakie.DataAspect(),
        xlabel = "x [m]",
        ylabel = "y [m]"
    )
    
    colors = StructuralPlots.harmonic
    
    # Plot stored polygons for each column
    for (col_idx, col) in enumerate(story_cols)
        color = colors[mod1(col_idx, length(colors))]
        
        # Draw each per-cell polygon
        for (cell_idx, polygon) in col.tributary_polygons
            isempty(polygon) && continue
            
            xs = [v[1] - cx for v in polygon]
            ys = [v[2] - cy for v in polygon]
            push!(xs, xs[1])
            push!(ys, ys[1])
            
            GLMakie.poly!(ax, GLMakie.Point2f.(xs, ys),
                         color = (color, 0.4),
                         strokecolor = color,
                         strokewidth = 2)
        end
        
        # Label at column position
        if show_labels && !isnothing(col.tributary_area)
            v = skel.vertices[col.vertex_idx]
            c = Meshes.coords(v)
            mx = Float64(ustrip(u"m", c.x)) - cx
            my = Float64(ustrip(u"m", c.y)) - cy
            label = "$(round(col.tributary_area, digits=1)) m²"
            GLMakie.text!(ax, mx, my + 0.5, text=label, fontsize=10,
                         align=(:center, :bottom), color=:black)
        end
    end
    
    # Plot column positions
    if show_column_positions
        for col in story_cols
            v = skel.vertices[col.vertex_idx]
            c = Meshes.coords(v)
            x = Float64(ustrip(u"m", c.x)) - cx
            y = Float64(ustrip(u"m", c.y)) - cy
            GLMakie.scatter!(ax, [x], [y], color=:black, markersize=12, marker=:rect)
        end
    end
    
    return fig
end

"""
    visualize_tributaries_combined(struc::BuildingStructure, cell_idx::Int; kwargs...)

Visualize both edge tributaries (straight skeleton) and vertex tributaries (Voronoi)
for a single cell side-by-side.

# Arguments
- `cell_idx::Int`: Which cell to visualize
- `show_labels::Bool=true`: Show area/fraction labels

# Returns
GLMakie.Figure with two panels: [Edge Tribs | Vertex Tribs]
"""
function visualize_tributaries_combined(struc::BuildingStructure, cell_idx::Int;
    show_labels::Bool = true
)
    cell = struc.cells[cell_idx]
    skel = struc.skeleton
    
    # Compute edge tributaries if needed
    if isnothing(cell.tributary)
        compute_cell_tributaries!(struc)
        cell = struc.cells[cell_idx]
    end
    
    # Get cell vertices
    verts_raw, offset = _get_cell_vertices_2d_with_offset(struc, cell)
    verts = [(v[1] - offset[1], v[2] - offset[2]) for v in verts_raw]
    
    # Compute Voronoi for cell vertices (these would be column positions)
    points = [Meshes.Point(v[1], v[2]) for v in verts_raw]
    vertex_tribs = StructuralSizer.compute_voronoi_tributaries(points)
    
    # Create figure with two panels
    fig = GLMakie.Figure(size = (1200, 550))
    
    colors = StructuralPlots.harmonic
    
    # --- Left panel: Edge Tributaries ---
    ax1 = GLMakie.Axis(fig[1, 1],
        title = "Edge Tributaries (Straight Skeleton)",
        aspect = GLMakie.DataAspect(),
        xlabel = "x [m]", ylabel = "y [m]"
    )
    
    if !isnothing(cell.tributary)
        n_verts = length(verts_raw)
        for (j, trib) in enumerate(cell.tributary)
            if !isempty(trib.s)
                local_idx = trib.local_edge_idx
                beam_start = verts_raw[local_idx]
                beam_end = verts_raw[mod1(local_idx + 1, n_verts)]
                
                trib_verts = vertices(trib, beam_start, beam_end)
                txs = [v[1] - offset[1] for v in trib_verts]
                tys = [v[2] - offset[2] for v in trib_verts]
                push!(txs, txs[1])
                push!(tys, tys[1])
                
                c = colors[mod1(j, length(colors))]
                GLMakie.poly!(ax1, GLMakie.Point2f.(txs, tys),
                             color = (c, 0.3), strokecolor = c, strokewidth = 1.5)
                
                if show_labels
                    label = "$(round(trib.fraction*100, digits=0))%"
                    mx = (verts[local_idx][1] + verts[mod1(local_idx+1, length(verts))][1]) / 2
                    my = (verts[local_idx][2] + verts[mod1(local_idx+1, length(verts))][2]) / 2
                    GLMakie.text!(ax1, mx, my, text=label, fontsize=10,
                                 align=(:center, :center), color=:black)
                end
            end
        end
    end
    
    # Cell outline
    xs = [v[1] for v in verts]; ys = [v[2] for v in verts]
    push!(xs, xs[1]); push!(ys, ys[1])
    GLMakie.lines!(ax1, xs, ys, color=:black, linewidth=2)
    GLMakie.scatter!(ax1, GLMakie.Point2f.(verts), color=:black, markersize=8)
    
    # --- Right panel: Vertex Tributaries ---
    ax2 = GLMakie.Axis(fig[1, 2],
        title = "Vertex Tributaries (Voronoi)",
        aspect = GLMakie.DataAspect(),
        xlabel = "x [m]", ylabel = "y [m]"
    )
    
    for (i, trib) in enumerate(vertex_tribs)
        if !isempty(trib.polygon)
            pxs = [v[1] - offset[1] for v in trib.polygon]
            pys = [v[2] - offset[2] for v in trib.polygon]
            push!(pxs, pxs[1])
            push!(pys, pys[1])
            
            c = colors[mod1(i, length(colors))]
            GLMakie.poly!(ax2, GLMakie.Point2f.(pxs, pys),
                         color = (c, 0.4), strokecolor = c, strokewidth = 2)
            
            if show_labels
                mx = sum(v[1] for v in trib.polygon) / length(trib.polygon) - offset[1]
                my = sum(v[2] for v in trib.polygon) / length(trib.polygon) - offset[2]
                label = "V$(i)\n$(round(trib.area, digits=1)) m²"
                GLMakie.text!(ax2, mx, my, text=label, fontsize=9,
                             align=(:center, :center), color=:black)
            end
        end
    end
    
    # Cell outline and vertices
    GLMakie.lines!(ax2, xs, ys, color=:black, linewidth=2)
    GLMakie.scatter!(ax2, GLMakie.Point2f.(verts), color=:black, markersize=10, marker=:rect)
    
    return fig
end