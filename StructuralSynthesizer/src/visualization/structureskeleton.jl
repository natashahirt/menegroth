function visualize(skel::StructureSkeleton)
    # handle empty skeleton
    if isempty(skel.vertices)
        @warn "Skeleton is empty, nothing to visualize."
        return GLMakie.Figure()
    end

    # get units from first vertex
    c1 = Meshes.coords(skel.vertices[1])
    # handle both Meshes coordinate formats (NamedTuple or SVector)
    z_coord = hasproperty(c1, :x) ? c1.x : c1[1]
    vertex_units = Unitful.unit(z_coord)

    fig = GLMakie.Figure(size = (1200, 800))
    ax = GLMakie.Axis3(
        fig[1, 1],
        title = "Structure Skeleton (only geometry)",
        aspect = :data,
        xlabel = "x [$(vertex_units)]",
        ylabel = "y [$(vertex_units)]",
        zlabel = "z [$(vertex_units)]"
    )

    # get coordinates
    xyz = map(skel.vertices) do v
        c = Meshes.coords(v)
        # handle different Meshes versions
        if hasproperty(c, :x)
            GLMakie.Point3f(ustrip(c.x), ustrip(c.y), ustrip(c.z))
        else
            GLMakie.Point3f(ustrip(c[1]), ustrip(c[2]), ustrip(c[3]))
        end
    end
    GLMakie.scatter!(ax, xyz, color = :black, markersize = 10)

    # plot edges
    # each group gets its own color
    palette = [:blue, :red, :green, :orange, :purple]
    
    for (i, (group_name, edge_indices)) in enumerate(skel.groups_edges)
        # get segments for that group
        group_segments = skel.edges[edge_indices]
        
        # get line segments
        line_pts = GLMakie.Point3f[]
        for seg in group_segments
            v1, v2 = Meshes.vertices(seg)
            c1, c2 = Meshes.coords(v1), Meshes.coords(v2)
            if hasproperty(c1, :x)
                p1 = GLMakie.Point3f(ustrip(c1.x), ustrip(c1.y), ustrip(c1.z))
                p2 = GLMakie.Point3f(ustrip(c2.x), ustrip(c2.y), ustrip(c2.z))
            else
                p1 = GLMakie.Point3f(ustrip(c1[1]), ustrip(c1[2]), ustrip(c1[3]))
                p2 = GLMakie.Point3f(ustrip(c2[1]), ustrip(c2[2]), ustrip(c2[3]))
            end
            push!(line_pts, p1, p2)
        end
        
        # draw segments
        GLMakie.linesegments!(ax, line_pts, 
                      color = palette[mod1(i, length(palette))], 
                      linewidth = 3, 
                      label = string(group_name))
    end

    # faces
    # faces are transparent to allow seeing the beams
    face_palette = [:blue, :red, :green, :orange, :purple]
    for (i, (group_name, face_indices)) in enumerate(skel.groups_faces)
        # get polygons for that group
        group_polygons = skel.faces[face_indices]
        
        for (j, poly) in enumerate(group_polygons)
            # extract coordinates
            pts = GLMakie.Point3f[]
            for v in Meshes.vertices(poly)
                c = Meshes.coords(v)
                if hasproperty(c, :x)
                    push!(pts, GLMakie.Point3f(ustrip(c.x), ustrip(c.y), ustrip(c.z)))
                else
                    push!(pts, GLMakie.Point3f(ustrip(c[1]), ustrip(c[2]), ustrip(c[3])))
                end
            end

            # plot polygon
            if j == 1
                GLMakie.poly!(ax, pts,
                            color = (face_palette[mod1(i, length(face_palette))], 0.2),
                            transparency = true,
                            label = string(group_name))
            else
                GLMakie.poly!(ax, pts,
                            color = (face_palette[mod1(i, length(face_palette))], 0.2),
                            transparency = true)
            end
        end
    end

    # 4. Add a legend
    GLMakie.axislegend(ax)

    return fig
end