# Slab visualization utilities

"""
    draw_slab!(ax, slab::Slab, struc::BuildingStructure; kwargs...)

Draw a slab as a 3D box on top of its supporting face(s).

# Arguments
- `ax`: Makie Axis3
- `slab`: Slab to draw
- `struc`: BuildingStructure (for geometry access)
- `color`: Slab color (default: :lightblue)
- `alpha`: Transparency (default: 0.6)
- `show_outline`: Whether to show edge outlines (default: true)
- `outline_color`: Color for outlines (default: :gray40)
- `outline_width`: Line width for outlines (default: 1.0)
- `z_offset`: Additional z offset above face (default: 0.0 m)
"""
function draw_slab!(ax, slab::Slab, struc::BuildingStructure;
                    color=:lightblue, alpha=0.6, 
                    show_outline=true, outline_color=:gray40, outline_width=1.0,
                    z_offset=0.0)
    skel = struc.skeleton
    
    # Get slab thickness from result
    h = ustrip(u"m", StructuralSizer.total_depth(slab.result))
    
    # Collect all vertices from all cells in this slab
    all_verts_2d = Set{NTuple{2, Float64}}()
    z_coord = 0.0
    
    for cell_idx in slab.cell_indices
        cell = struc.cells[cell_idx]
        v_indices = skel.face_vertex_indices[cell.face_idx]
        
        for vi in v_indices
            pt = skel.vertices[vi]
            c = Meshes.coords(pt)
            x, y = ustrip(u"m", c.x), ustrip(u"m", c.y)
            z_coord = ustrip(u"m", c.z)  # Use last vertex z as reference
            push!(all_verts_2d, (x, y))
        end
    end
    
    # Apply z offset
    z_top = z_coord + z_offset
    z_bot = z_top - h
    
    # Convert to sorted vector and compute convex hull for multi-cell slabs
    verts_2d = collect(all_verts_2d)
    hull_pts = _convex_hull_2d(verts_2d)
    
    _draw_slab_box!(ax, hull_pts, z_bot, z_top;
                    color=color, alpha=alpha,
                    show_outline=show_outline, outline_color=outline_color, 
                    outline_width=outline_width)
end

"""
    draw_slabs!(ax, struc::BuildingStructure; kwargs...)

Draw all slabs in the structure.

# Arguments
- `color`: Slab color or function `slab -> color` (default: :lightblue)
- `alpha`: Transparency (default: 0.6)
- `color_by`: Coloring mode (default: :none)
  - `:none` - uniform color
  - `:floor_type` - color by floor system type
  - `:position` - color by corner/edge/interior
  - `:thickness` - color by slab thickness (uses colormap)
- `colormap`: Colormap for `:thickness` mode (default: :viridis)
- `show_outline`: Whether to show edge outlines (default: true)
- `outline_color`: Color for outlines (default: :gray40)
- `z_offset`: Additional z offset above beams (default: 0.0 m)
"""
function draw_slabs!(ax, struc::BuildingStructure;
                     color=:lightblue, alpha=0.6,
                     color_by::Symbol=:none, colormap=:viridis,
                     show_outline=true, outline_color=:gray40, outline_width=1.0,
                     z_offset=0.0)
    isempty(struc.slabs) && return
    
    # Build color mapping based on mode
    slab_colors = _resolve_slab_colors(struc, color, color_by, colormap)
    
    for (i, slab) in enumerate(struc.slabs)
        draw_slab!(ax, slab, struc;
                   color=slab_colors[i], alpha=alpha,
                   show_outline=show_outline, outline_color=outline_color,
                   outline_width=outline_width, z_offset=z_offset)
    end
end

# =============================================================================
# Internal Helpers
# =============================================================================

"""Resolve slab colors based on coloring mode."""
function _resolve_slab_colors(struc::BuildingStructure, color, color_by::Symbol, colormap)
    n = length(struc.slabs)
    n == 0 && return []
    
    if color_by == :none
        # Uniform color or per-slab function
        if color isa Function
            return [color(s) for s in struc.slabs]
        else
            return fill(color, n)
        end
        
    elseif color_by == :floor_type
        # Color by floor system type
        type_colors = Dict(
            :flat_plate => :lightblue,
            :flat_slab => :steelblue,
            :one_way => :lightyellow,
            :two_way => :lightgreen,
            :pt_banded => :lavender,
            :waffle => :wheat,
            :vault => :salmon,
            :composite_deck => :lightgray,
            :hollow_core => :bisque,
            :clt => :burlywood,
            :dlt => :tan,
            :nlt => :peru,
        )
        return [get(type_colors, s.floor_type, :gray80) for s in struc.slabs]
        
    elseif color_by == :position
        # Color by position (corner/edge/interior)
        pos_colors = Dict(
            :corner => :coral,
            :edge => :lightyellow,
            :interior => :lightgreen,
        )
        return [get(pos_colors, s.position, :gray80) for s in struc.slabs]
        
    elseif color_by == :thickness
        # Color by thickness using colormap
        thicknesses = [ustrip(u"m", StructuralSizer.total_depth(s.result)) for s in struc.slabs]
        t_min, t_max = extrema(thicknesses)
        if t_max ≈ t_min
            t_max = t_min + 0.01  # Avoid division by zero
        end
        cmap = GLMakie.cgrad(colormap)
        return [cmap[(t - t_min) / (t_max - t_min)] for t in thicknesses]
    else
        @warn "Unknown color_by mode: $color_by. Using uniform color."
        return fill(color, n)
    end
end

"""Draw a slab box from 2D hull vertices and z bounds."""
function _draw_slab_box!(ax, hull_pts::Vector{NTuple{2, Float64}}, z_bot, z_top;
                         color=:lightblue, alpha=0.6,
                         show_outline=true, outline_color=:gray40, outline_width=1.0)
    n = length(hull_pts)
    n < 3 && return
    
    # Create top and bottom face vertices
    top_verts = [GLMakie.Point3f(p[1], p[2], z_top) for p in hull_pts]
    bot_verts = [GLMakie.Point3f(p[1], p[2], z_bot) for p in hull_pts]
    
    # Triangulate top and bottom faces (fan from first vertex)
    top_faces = [GLMakie.TriangleFace(1, k, k+1) for k in 2:n-1]
    bot_faces = [GLMakie.TriangleFace(1, k+1, k) for k in 2:n-1]  # Reversed winding
    
    # Draw top face
    if !isempty(top_faces)
        top_mesh = GLMakie.GeometryBasics.Mesh(top_verts, top_faces)
        GLMakie.mesh!(ax, top_mesh, color=(color, alpha), transparency=true)
    end
    
    # Draw bottom face
    if !isempty(bot_faces)
        bot_mesh = GLMakie.GeometryBasics.Mesh(bot_verts, bot_faces)
        GLMakie.mesh!(ax, bot_mesh, color=(color, alpha), transparency=true)
    end
    
    # Draw side faces (quads as 2 triangles each)
    for i in 1:n
        j = mod1(i + 1, n)
        
        # Quad corners: top[i], top[j], bot[j], bot[i]
        quad_verts = GLMakie.Point3f[top_verts[i], top_verts[j], bot_verts[j], bot_verts[i]]
        quad_faces = GLMakie.TriangleFace[(1, 2, 3), (1, 3, 4)]
        
        quad_mesh = GLMakie.GeometryBasics.Mesh(quad_verts, quad_faces)
        GLMakie.mesh!(ax, quad_mesh, color=(color, alpha), transparency=true)
    end
    
    # Draw outlines
    if show_outline
        # Top edge loop
        top_loop = vcat(top_verts, [top_verts[1]])
        GLMakie.lines!(ax, top_loop, color=outline_color, linewidth=outline_width)
        
        # Bottom edge loop
        bot_loop = vcat(bot_verts, [bot_verts[1]])
        GLMakie.lines!(ax, bot_loop, color=outline_color, linewidth=outline_width)
        
        # Vertical edges
        for i in 1:n
            GLMakie.lines!(ax, [bot_verts[i], top_verts[i]], 
                          color=outline_color, linewidth=outline_width)
        end
    end
end

"""
    _convex_hull_2d(points) -> Vector{NTuple{2, Float64}}

Compute convex hull of 2D points using Graham scan.
Returns vertices in counter-clockwise order.
"""
function _convex_hull_2d(points::Vector{NTuple{2, Float64}})
    n = length(points)
    n <= 3 && return points
    
    # Find bottom-left point (min y, then min x)
    start_idx = argmin([(p[2], p[1]) for p in points])
    start = points[start_idx]
    
    # Sort by polar angle from start point
    others = [p for (i, p) in enumerate(points) if i != start_idx]
    
    function angle_key(p)
        dx, dy = p[1] - start[1], p[2] - start[2]
        return (atan(dy, dx), dx^2 + dy^2)  # angle, then distance for ties
    end
    
    sorted = sort(others, by=angle_key)
    
    # Graham scan
    hull = [start]
    for p in sorted
        while length(hull) >= 2 && _cross_2d(hull[end-1], hull[end], p) <= 0
            pop!(hull)
        end
        push!(hull, p)
    end
    
    return hull
end

"""Cross product of vectors (b-a) and (c-a)."""
function _cross_2d(a::NTuple{2, Float64}, b::NTuple{2, Float64}, c::NTuple{2, Float64})
    return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end

# =============================================================================
# Slab Result Summary Utilities
# =============================================================================

"""
    slab_info(slab::Slab) -> NamedTuple

Get summary information for a slab suitable for visualization labels.
"""
function slab_info(slab::Slab)
    result = slab.result
    
    (
        floor_type = slab.floor_type,
        position = slab.position,
        n_cells = length(slab.cell_indices),
        thickness = StructuralSizer.total_depth(result),
        primary_span = slab.spans.primary,
        secondary_span = slab.spans.secondary,
    )
end

"""
    slab_summary_text(slab::Slab) -> String

Generate a summary text string for a slab (for annotations/tooltips).
"""
function slab_summary_text(slab::Slab)
    info = slab_info(slab)
    h_in = ustrip(u"inch", info.thickness)
    l1_ft = ustrip(u"ft", info.primary_span)
    l2_ft = ustrip(u"ft", info.secondary_span)
    
    """$(info.floor_type) ($(info.position))
    h = $(round(h_in, digits=2))\"
    spans: $(round(l1_ft, digits=1))' × $(round(l2_ft, digits=1))'
    cells: $(info.n_cells)"""
end
