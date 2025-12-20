function visualize(skel::StructureSkeleton)
    vertex_units = Unitful.unit(Meshes.coords(skel.vertices[1]).x)

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
        GLMakie.Point3f(Unitful.ustrip(c.x), Unitful.ustrip(c.y), Unitful.ustrip(c.z))
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
            p1 = GLMakie.Point3f(Unitful.ustrip(c1.x), Unitful.ustrip(c1.y), Unitful.ustrip(c1.z))
            p2 = GLMakie.Point3f(Unitful.ustrip(c2.x), Unitful.ustrip(c2.y), Unitful.ustrip(c2.z))
            push!(line_pts, p1, p2)
        end
        
        # draw segments
        GLMakie.linesegments!(ax, line_pts, 
                      color = palette[mod1(i, length(palette))], 
                      linewidth = 3, 
                      label = string(group_name))
    end

    # 3. Add a legend
    GLMakie.axislegend(ax)

    return fig
end