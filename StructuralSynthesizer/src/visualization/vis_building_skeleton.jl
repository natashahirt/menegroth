import LinearAlgebra: normalize

# Helper to handle different Meshes coordinate formats
function extract_point3f(v)
    c = Meshes.coords(v)
    if hasproperty(c, :x)
        return GLMakie.Point3f(ustrip(c.x), ustrip(c.y), ustrip(c.z))
    else
        return GLMakie.Point3f(ustrip(c[1]), ustrip(c[2]), ustrip(c[3]))
    end
end

"""
    visualize(skel::BuildingSkeleton; kwargs...)

Enhanced visualization for BuildingSkeleton geometry.

# Arguments
- `show_stories::Bool=true`: Show horizontal planes at story heights.
- `show_direction::Bool=true`: Show arrows indicating member direction (start -> end).
- `show_labels::Bool=false`: Show story height labels.
"""
function visualize(skel::BuildingSkeleton; 
    show_stories = true, 
    show_direction = true,
    show_labels = false
)
    # handle empty skeleton
    if isempty(skel.vertices)
        @warn "Skeleton is empty, nothing to visualize."
        return GLMakie.Figure()
    end

    # get units from first vertex
    c1 = Meshes.coords(skel.vertices[1])
    z_coord = hasproperty(c1, :x) ? c1.x : c1[1]
    vertex_units = Unitful.unit(z_coord)

    fig = GLMakie.Figure(size = (1200, 800))
    ax = GLMakie.Axis3(
        fig[1, 1],
        title = "Structure Skeleton",
        aspect = :data,
        xlabel = "x [$(vertex_units)]",
        ylabel = "y [$(vertex_units)]",
        zlabel = "z [$(vertex_units)]"
    )

    # Collectors for custom legend
    leg_elems = []
    leg_labels = String[]

    # 1. Get Base Coordinates
    xyz = [extract_point3f(v) for v in skel.vertices]

    # 2. Story Levels (Contextual Geometry)
    if show_stories && !isempty(skel.stories_z)
        xs = [p[1] for p in xyz]
        ys = [p[2] for p in xyz]
        x_rng = [minimum(xs), maximum(xs)]
        y_rng = [minimum(ys), maximum(ys)]
        
        for (i, z) in enumerate(skel.stories_z)
            z_val = ustrip(z)
            # Use a mesh for 3D planes to avoid poly!/SizedVector issues
            pts = GLMakie.Point3f[
                (x_rng[1], y_rng[1], z_val), 
                (x_rng[2], y_rng[1], z_val), 
                (x_rng[2], y_rng[2], z_val), 
                (x_rng[1], y_rng[2], z_val)
            ]
            faces = [GLMakie.TriangleFace(1, 2, 3), GLMakie.TriangleFace(1, 3, 4)]
            m = GLMakie.GeometryBasics.Mesh(pts, faces)
            GLMakie.mesh!(ax, m, color = (:gray, 0.05), transparency = true)
            
            if show_labels
                GLMakie.text!(ax, x_rng[1], y_rng[1], z_val, 
                    text = "Story $i ($(z))", color = :gray, fontsize = 12)
            end
        end
    end

    # 3. Vertices (Categorized)
    GLMakie.scatter!(ax, xyz, color = :black, markersize = 8)
    push!(leg_elems, GLMakie.MarkerElement(marker = :circle, color = :black, markersize = 10))
    push!(leg_labels, "Nodes")
    
    # Highlight Supports (Consistency with asap.jl)
    if haskey(skel.groups_vertices, :support)
        supp_pts = xyz[skel.groups_vertices[:support]]
        GLMakie.scatter!(ax, supp_pts, color = :red, marker = :utriangle, markersize = 12)
        push!(leg_elems, GLMakie.MarkerElement(marker = :utriangle, color = :red, markersize = 12))
        push!(leg_labels, "Supports")
    end

    # 4. Edges with Directionality
    palette = [:blue, :red, :green, :orange, :purple]
    
    for (i, (group_name, edge_indices)) in enumerate(skel.groups_edges)
        group_segments = skel.edges[edge_indices]
        
        line_pts = GLMakie.Point3f[]
        dir_starts = GLMakie.Point3f[]
        dir_vecs = GLMakie.Vec3f[]
        
        for seg in group_segments
            v1, v2 = Meshes.vertices(seg)
            p1, p2 = extract_point3f(v1), extract_point3f(v2)
            
            push!(line_pts, p1, p2)
            
            if show_direction
                # Vector for direction arrow (at the 2/3 point of the member)
                vec = p2 - p1
                L = norm(vec)
                if L > 1e-6
                    push!(dir_starts, p1 + vec * 0.66)
                    push!(dir_vecs, normalize(vec) * 0.2) 
                end
            end
        end
        
        color = palette[mod1(i, length(palette))]
        GLMakie.linesegments!(ax, line_pts, color = color, linewidth = 1.0)
        
        # Add to legend
        push!(leg_elems, GLMakie.LineElement(color = color, linewidth = 2))
        push!(leg_labels, string(group_name))
        
        if show_direction && !isempty(dir_starts)
            # Use arrows3d! for consistent 3D rendering
            GLMakie.arrows3d!(ax, dir_starts, dir_vecs, color = color, 
                             shaftradius = 0.02, tipradius = 0.05, tiplength = 0.1)
        end
    end

    # 5. Faces (Keep existing transparent logic)
    face_palette = [:blue, :red, :green, :orange, :purple]
    for (i, (group_name, face_indices)) in enumerate(skel.groups_faces)
        group_name == :slabs && continue
        group_polygons = skel.faces[face_indices]
        color_base = face_palette[mod1(i, length(face_palette))]
        
        # Add a nice square swatch for the face group to legend
        push!(leg_elems, GLMakie.PolyElement(color = (color_base, 0.5), strokecolor = :black, strokewidth = 1))
        push!(leg_labels, string(group_name))

        for (j, poly) in enumerate(group_polygons)
            pts = [extract_point3f(v) for v in Meshes.vertices(poly)]
            
            # Simple triangulation for convex polygons (like floor panels)
            # Create TriangleFaces: (1,2,3), (1,3,4), ..., (1, n-1, n)
            n = length(pts)
            if n >= 3
                faces = [GLMakie.TriangleFace(1, k, k+1) for k in 2:n-1]
                m = GLMakie.GeometryBasics.Mesh(pts, faces)
                
                color = (color_base, 0.2)
                GLMakie.mesh!(ax, m, color = color, transparency = true)
            end
        end
    end

    # Create the custom legend in a sidebar
    if !isempty(leg_elems)
        GLMakie.Legend(fig[1, 2], leg_elems, leg_labels, "Structure Components")
    end

    return fig
end