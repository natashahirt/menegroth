is_released_start(::Type{<:Asap.Release}) = false
is_released_start(::Type{Asap.FreeFixed}) = true
is_released_start(::Type{Asap.FreeFree}) = true
is_released_start(::Type{Asap.Joist}) = true

is_released_end(::Type{<:Asap.Release}) = false
is_released_end(::Type{Asap.FixedFree}) = true
is_released_end(::Type{Asap.FreeFree}) = true
is_released_end(::Type{Asap.Joist}) = true

"""
Helper to get start and end points for drawing, accounting for releases.
Returns positions as Float64 arrays in meters.
"""
function get_drawing_pts(element::Asap.Element{R}, gap_factor=0.05) where R
    # Strip units to meters for visualization
    p1 = [ustrip(u"m", x) for x in element.nodeStart.position]
    p2 = [ustrip(u"m", x) for x in element.nodeEnd.position]
    
    # Vector from start to end (the axis of the element)
    vec = p2 .- p1
    
    # Use dispatch/traits on the type parameter R
    # start_draw: move from p1 towards p2
    # end_draw: move from p2 towards p1
    start_draw = is_released_start(R) ? p1 .+ (vec .* gap_factor) : p1
    end_draw = is_released_end(R) ? p2 .- (vec .* gap_factor) : p2
    
    return start_draw, end_draw
end

# Fallback for TrussElements (always pinned-pinned, but usually drawn connected unless specified)
function get_drawing_pts(element::Asap.TrussElement, gap_factor=0.1)
    # Strip units to meters for visualization
    p1 = [ustrip(u"m", x) for x in element.nodeStart.position]
    p2 = [ustrip(u"m", x) for x in element.nodeEnd.position]
    v = p2 .- p1
    return p1 .+ (v .* gap_factor), p2 .- (v .* gap_factor)
end

"""
    visualize(struc::BuildingStructure; kwargs...)

Karamba-style visualization for a BuildingStructure.

# Arguments
- `deflection_scale::Union{Float64,Symbol}=:auto`: Scale factor for deflected shape, or `:auto` to auto-compute.
- `mode::Symbol=:original`: `:original` or `:deflected`.
- `color_by::Symbol=:none`: Coloring mode:
  - `:none` - no coloring
  - `:displacement_global` - total displacement magnitude (includes rigid body motion)
  - `:displacement_local` - chord-relative deflection (member bending only, excludes rigid body motion)
  - `:stress` - combined stress approximation
  - `:tributary_edge` - show edge tributary areas (straight skeleton, for beam loads)
  - `:tributary_vertex` - show vertex tributary areas (Voronoi, for column loads)
- `theme::Union{Nothing,Symbol}=nothing`: Apply StructuralPlots theme (`:light`, `:dark`, or `nothing` for default)
- `show_nodes::Bool=true`: Whether to show nodes.
- `show_supports::Bool=true`: Whether to show supports.
- `show_releases::Bool=true`: Whether to show element releases (gaps).
- `show_dofs::Bool=false`: Whether to show degrees of freedom (arrows).
- `show_original_geometry::Bool=true`: Whether to show the dotted lines of the original geometry to emphasise deflection.
- `resolution::Int=20`: Number of segments per element for curved shapes.
- `linewidth::Float64=1.0`: Line width for elements.
- `markersize::Float64=10.0`: Marker size for nodes/supports.

Note: For sized elements (slabs, foundations, member sections), use `visualize(design::BuildingDesign)`.
"""
function visualize(struc::BuildingStructure;
    deflection_scale = :auto,
    mode = :original,
    color_by = :none,
    theme::Union{Nothing, Symbol} = nothing,
    show_nodes = true,
    show_supports = true,
    show_releases = true,
    show_dofs = false,
    show_original_geometry = true,
    resolution = 20,
    linewidth = 1.0,
    markersize = 10.0,
)
    skel = struc.skeleton
    model = struc.asap_model
    
    # Apply StructuralPlots theme if specified
    if theme == :light
        GLMakie.set_theme!(StructuralPlots.sp_light)
    elseif theme == :dark
        GLMakie.set_theme!(StructuralPlots.sp_dark)
    end

    fig = GLMakie.Figure(size = (1200, 800))
    ax = GLMakie.Axis3(fig[1, 1], 
        aspect = :data, 
        title = "Structural Model ($(mode))",
        xlabel = "x [m]",
        ylabel = "y [m]",
        zlabel = "z [m]"
    )

    # Collectors for custom legend
    leg_elems = []
    leg_labels = String[]
    
    # Color data (populated in :deflected mode with coloring)
    all_colors = Float64[]
    crange = (0.0, 1.0)

    # 1. Elements
    if mode == :original
        for element in model.elements
            # get_drawing_pts returns positions in meters (raw Float64)
            p1, p2 = get_drawing_pts(element, show_releases ? 0.05 : 0.0)
            GLMakie.lines!(ax, [p1[1], p2[1]], [p1[2], p2[2]], [p1[3], p2[3]], 
                          color = :black, linewidth = linewidth)
        end
        push!(leg_elems, GLMakie.LineElement(color = :black, linewidth = 2))
        push!(leg_labels, "Elements")

    elseif mode == :deflected
        if show_original_geometry
            # Draw original geometry as thin faded lines for reference
            for element in model.elements
                # get_drawing_pts returns positions in meters (raw Float64)
                p1, p2 = get_drawing_pts(element, 0.0)
                GLMakie.lines!(ax, [p1[1], p2[1]], [p1[2], p2[2]], [p1[3], p2[3]], 
                            color = (:black, 0.4), linewidth = 0.5, linestyle = :dash,
                            transparency = true)
            end
            push!(leg_elems, GLMakie.LineElement(color = (:black, 0.4), linewidth = 1, linestyle = :dot))
            push!(leg_labels, "Original Geometry")
        end

        # Calculate displacements/forces with a reasonable increment
        # Asap accepts Unitful at API boundary, but visualization math uses Float64
        avg_len_unitful = model.nElements > 0 ? sum(getproperty.(model.elements, :length)) / model.nElements : 1.0u"m"
        avg_len = ustrip(u"m", avg_len_unitful)  # Float64 for internal visualization math
        increment = avg_len_unitful / resolution  # Unitful for Asap API
        
        # Asap provides displacements and forces analysis
        edisps = Asap.displacements(model, increment)
        isempty(edisps) && error("No element displacements available. Is the model empty or unsolved? (nElements=$(model.nElements), nLoads=$(length(model.loads)))")
        println("First element uglobal: ", edisps[1].uglobal[:, 1:3])

        # Auto-scale: make max displacement ~10% of avg element length
        if deflection_scale === :auto
            max_disp = 0.0
            for edisp in edisps
                for j in 1:size(edisp.uglobal, 2)
                    max_disp = max(max_disp, norm(edisp.uglobal[:, j]))
                end
            end
            deflection_scale = max_disp > 1e-12 ? (avg_len * 0.1) / max_disp : 1.0
        end

        # For stress coloring, we need internal forces
        eforces = color_by == :stress ? Asap.InternalForces(model, increment) : nothing

        # Collectors for consistent coloring across all members
        all_points = Vector{GLMakie.Point3f}[]

        for (i, edisp) in enumerate(edisps)
            # basepositions + (deflection * uglobal)
            # Both are [3 x n] matrices in GCS
            pos = edisp.basepositions .+ deflection_scale .* edisp.uglobal
            pts = [GLMakie.Point3f(pos[1, j], pos[2, j], pos[3, j]) for j in 1:size(pos, 2)]
            push!(all_points, pts)
            
            if color_by == :displacement_global
                # Total displacement magnitude in global coordinates (includes rigid body motion)
                dvals = [norm(edisp.uglobal[:, j]) for j in 1:size(edisp.uglobal, 2)]
                append!(all_colors, dvals)
            elseif color_by == :displacement_local
                # Chord-relative deflection: displacement relative to a straight line between endpoints
                # This shows actual member deformation (bending), excluding rigid body motion
                n_pts = size(edisp.uglobal, 2)
                u_start = edisp.uglobal[:, 1]      # Displacement at start
                u_end = edisp.uglobal[:, end]      # Displacement at end
                
                dvals = Float64[]
                for j in 1:n_pts
                    # Linear interpolation factor (0 at start, 1 at end)
                    t = (j - 1) / max(n_pts - 1, 1)
                    # Chord displacement at this point
                    u_chord = u_start .+ t .* (u_end .- u_start)
                    # Relative displacement (deviation from chord)
                    u_relative = edisp.uglobal[:, j] .- u_chord
                    push!(dvals, norm(u_relative))
                end
                append!(all_colors, dvals)
            elseif color_by == :stress && !isnothing(eforces)
                eforce = eforces[i]
                section = edisp.element.section
                
                # Extract section properties via accessor functions
                A = StructuralSizer.section_area(section)
                Sx_val = StructuralSizer.Sx(section)
                Sy_val = StructuralSizer.Sy(section)
                
                # Combined stress approximation: σ = |P/A| + |Mz/Sx| + |My/Sy|
                # Asap.InternalForces (dispatches to ElementInternalForces) contains vectors P, My, Vy, Mz, Vz
                svals = [abs(eforce.P[j]/A) + abs(eforce.Mz[j]/Sx_val) + abs(eforce.My[j]/Sy_val) for j in 1:length(eforce.P)]
                append!(all_colors, svals)
            end
        end

        # Calculate consistent color range for the whole model
        crange = isempty(all_colors) ? (0.0, 1.0) : (minimum(all_colors), maximum(all_colors))
        if crange[1] == crange[2]
            crange = (crange[1], crange[1] + 1.0) # avoid singular range
        end

        # Plot deflected elements
        # Note: tributary coloring only applies to :original mode, so treat it as :none here
        use_coloring = color_by ∉ (:none, :tributary_edge, :tributary_vertex) && !isempty(all_colors)
        
        color_idx = 1
        for pts in all_points
            if !use_coloring
                GLMakie.lines!(ax, pts, color = :black, linewidth = linewidth)
            else
                res = length(pts)
                cvals = all_colors[color_idx:color_idx+res-1]
                GLMakie.lines!(ax, pts, color = cvals, colorrange = crange, 
                              linewidth = linewidth, colormap = :turbo)
                color_idx += res
            end
        end
        
        if !use_coloring
            push!(leg_elems, GLMakie.LineElement(color = :black, linewidth = 2))
            push!(leg_labels, "Elements (Deflected)")
        end
    end

    # 1b. Tributary Areas (works with both original and deflected modes)
    if color_by == :tributary_edge
        _draw_tributary_areas!(ax, struc, leg_elems, leg_labels)
    elseif color_by == :tributary_vertex
        _draw_vertex_tributary_areas!(ax, struc, leg_elems, leg_labels)
    end

    # 2. Nodes
    if show_nodes
        nodes_pos = [GLMakie.Point3f(ustrip.(u"m", n.position)...) for n in model.nodes]
        GLMakie.scatter!(ax, nodes_pos, color = :black, markersize = markersize / 2)
        push!(leg_elems, GLMakie.MarkerElement(marker = :circle, color = :black, markersize = 8))
        push!(leg_labels, "Nodes")
    end

    # 3. Supports (Triangle markers)
    if show_supports
        support_indices = get(skel.groups_vertices, :support, Int[])
        if !isempty(support_indices)
            supports = model.nodes[support_indices]
            supp_pos = [GLMakie.Point3f(ustrip.(u"m", n.position)...) for n in supports]
            GLMakie.scatter!(ax, supp_pos, color = :red, marker = :utriangle, markersize = markersize)
            push!(leg_elems, GLMakie.MarkerElement(marker = :utriangle, color = :red, markersize = 12))
            push!(leg_labels, "Supports")
        end
    end

    # 3b. Degrees of Freedom
    if show_dofs
        # Ensure model is processed to populate length, LCS, etc.
        model.processed || Asap.process!(model)

        # Estimate a good reference size for markers (in meters)
        avg_len_unitful = model.nElements > 0 ? sum(getproperty.(model.elements, :length)) / model.nElements : 1.0u"m"
        avg_len = ustrip(u"m", avg_len_unitful)  # Convert to Float64 in meters
        size_ref = avg_len * 0.15  # Now a Float64 in meters
        
        t_pos, t_dir = GLMakie.Point3f[], GLMakie.Vec3f[]
        r_pos, r_rot = GLMakie.Point3f[], GLMakie.Quaternionf[]
        
        axes = [GLMakie.Vec3f(1,0,0), GLMakie.Vec3f(0,1,0), GLMakie.Vec3f(0,0,1)]
        
        # Rotations to align a Z-facing circle/torus to the X, Y, and Z axes
        rotations = [
            GLMakie.qrotation(GLMakie.Vec3f(0,1,0), 0.5pi),  # To X
            GLMakie.qrotation(GLMakie.Vec3f(1,0,0), -0.5pi), # To Y
            GLMakie.qrotation(GLMakie.Vec3f(0,0,1), 0.0)     # To Z (Identity)
        ]
        
        for node in model.nodes
            p = GLMakie.Point3f(ustrip.(u"m", node.position)...)
            for i in 1:3
                # Translations (Green arrows)
                node.dof[i] && (push!(t_pos, p); push!(t_dir, axes[i] * size_ref))
                # Rotations (Blue circles)
                node.dof[i+3] && (push!(r_pos, p); push!(r_rot, rotations[i]))
            end
        end
        
        # Plot Translations as arrows
        if !isempty(t_pos)
            GLMakie.arrows3d!(ax, t_pos, t_dir, color = :green, 
                             tipradius = size_ref * 0.1, 
                             tiplength = size_ref * 0.2, 
                             shaftradius = size_ref * 0.02)
            push!(leg_elems, GLMakie.MarkerElement(marker = '→', color = :green, markersize = 12))
            push!(leg_labels, "DOF (Translational)")
        end
        
        # Plot Rotations as oriented circles
        if !isempty(r_pos)
            n_div = 32
            θ = range(0, 2π, length=n_div)
            circle_base = [GLMakie.Point3f(cos(t), sin(t), 0) for t in θ]
            
            all_circle_pts = GLMakie.Point3f[]
            for (p, rot) in zip(r_pos, r_rot)
                for cp in circle_base
                    # Scale, rotate, and shift circle to node position
                    push!(all_circle_pts, p + rot * (cp * size_ref * 0.5))
                end
                push!(all_circle_pts, GLMakie.Point3f(NaN)) # Break the line between nodes
            end
            
            GLMakie.lines!(ax, all_circle_pts, color = :blue, linewidth = linewidth * 2)
            push!(leg_elems, GLMakie.LineElement(color = :blue, linewidth = 2))
            push!(leg_labels, "DOF (Rotational)")
        end
    end

    # Sidebar for legend and colorbar
    if !isempty(leg_elems) || (mode == :deflected && color_by != :none && !isempty(all_colors))
        sidebar = fig[1, 2] = GLMakie.GridLayout()
        row_idx = 1
        
        # Add colorbar if coloring is active
        if mode == :deflected && color_by != :none && !isempty(all_colors)
            label = color_by == :displacement ? "Displacement Magnitude [m]" : "Approx. Stress [Pa]"
            GLMakie.Colorbar(sidebar[row_idx, 1], limits = crange, label = label, colormap = :turbo)
            row_idx += 1
        end
        
        # Add legend
        if !isempty(leg_elems)
            GLMakie.Legend(sidebar[row_idx, 1], leg_elems, leg_labels, "Asap Model")
        end
    end
    display(fig)
    return fig
end

"""Draw tributary area polygons in 3D using StructuralPlots colors."""
function _draw_tributary_areas!(ax, struc::BuildingStructure, leg_elems, leg_labels)
    skel = struc.skeleton
    
    # Ensure tributaries are computed
    compute_cell_tributaries!(struc)  # Cache handles deduplication
    
    # Use StructuralPlots harmonic palette (main colors, no accents)
    colors = StructuralPlots.harmonic
    
    drawn_edges = Set{Int}()
    
    for (cell_idx, cell) in enumerate(struc.cells)
        # Get tributaries from cache
        tribs = cell_edge_tributaries(struc, cell_idx)
        isnothing(tribs) && continue
        
        # Use same vertex source as tributary computation (face_vertex_indices)
        v_indices = skel.face_vertex_indices[cell.face_idx]
        face_verts = [skel.vertices[i] for i in v_indices]
        face_edges = skel.face_edge_indices[cell.face_idx]
        
        # Get z-coordinate - use meters for 3D visualization (Asap uses meters internally)
        z_coord = ustrip(u"m", Meshes.coords(face_verts[1]).z)
        
        # Convert to 2D coords in meters and ensure CCW to match tributary computation
        # Tributary computation uses meters internally, so we must use meters here
        verts_2d = NTuple{2, Float64}[]
        for p in face_verts
            c = Meshes.coords(p)
            push!(verts_2d, (ustrip(u"m", c.x), ustrip(u"m", c.y)))
        end
        verts_2d = Asap._ensure_ccw(verts_2d)
        n_verts = length(verts_2d)
        
        for trib in tribs
            isempty(trib.s) && continue
            
            # Get beam endpoints from CCW-ordered vertices (in meters, matching trib.d)
            local_idx = trib.local_edge_idx
            beam_start = verts_2d[local_idx]
            beam_end = verts_2d[mod1(local_idx + 1, n_verts)]
            
            # Get tributary vertices in absolute coords (meters)
            trib_verts_2d = StructuralSizer.vertices(trib, beam_start, beam_end)
            
            # Convert to 3D points
            pts_3d = [GLMakie.Point3f(v[1], v[2], z_coord) for v in trib_verts_2d]
            length(pts_3d) < 3 && continue
            
            # Create triangulated mesh for the polygon
            n_pts = length(pts_3d)
            tri_faces = [GLMakie.TriangleFace(1, k, k+1) for k in 2:n_pts-1]
            
            # Color based on global edge index (consistent coloring for same beam)
            global_edge_idx = local_idx <= length(face_edges) ? face_edges[local_idx] : 0
            color = colors[mod1(max(global_edge_idx, 1), length(colors))]
            
            mesh = GLMakie.GeometryBasics.Mesh(pts_3d, tri_faces)
            GLMakie.mesh!(ax, mesh, color = (color, 0.6), transparency = true)
            
            # Outline
            outline = vcat(pts_3d, [pts_3d[1]])
            GLMakie.lines!(ax, outline, color = color, linewidth = 1.5)
            
            # Track which edges we've drawn for legend
            global_edge_idx > 0 && push!(drawn_edges, global_edge_idx)
        end
    end
    
    # Add legend entry using the first harmonic color
    if !isempty(drawn_edges)
        push!(leg_elems, GLMakie.PolyElement(color = (colors[1], 0.6), strokecolor = colors[1], strokewidth = 1))
        push!(leg_labels, "Edge Tributary Areas")
    end
end

"""Draw Voronoi vertex tributary areas in 3D using stored polygons on columns."""
function _draw_vertex_tributary_areas!(ax, struc::BuildingStructure, leg_elems, leg_labels)
    skel = struc.skeleton
    colors = StructuralPlots.harmonic
    
    drawn_any = false
    
    # Draw stored polygons for each column
    for col in struc.columns
        trib_polygons = column_tributary_polygons(struc, col)
        isempty(trib_polygons) && continue  # Skip columns without tributaries
        
        # Color by column position
        color = if col.position == :corner
            colors[1]
        elseif col.position == :edge
            colors[2]
        else
            colors[3]
        end
        
        # Draw each per-cell polygon (polygon vertices are Unitful)
        for (cell_idx, polygon) in trib_polygons
            isempty(polygon) && continue
            
            # Get z-coordinate from the cell's face
            z_coord = 0.0
            if cell_idx <= length(struc.cells)
                face_idx = struc.cells[cell_idx].face_idx
                v_indices = skel.face_vertex_indices[face_idx]
                if !isempty(v_indices)
                    first_vert = skel.vertices[v_indices[1]]
                    z_coord = ustrip(u"m", Meshes.coords(first_vert).z)
                end
            end
            
            # Convert to 3D points (strip units from Unitful polygon vertices)
            pts_3d = [GLMakie.Point3f(ustrip(u"m", vx), ustrip(u"m", vy), z_coord) 
                      for (vx, vy) in polygon]
            length(pts_3d) < 3 && continue
            
            # Create triangulated mesh
            n_pts = length(pts_3d)
            tri_faces = [GLMakie.TriangleFace(1, k, k+1) for k in 2:n_pts-1]
            
            mesh = GLMakie.GeometryBasics.Mesh(pts_3d, tri_faces)
            GLMakie.mesh!(ax, mesh, color = (color, 0.5), transparency = true)
            
            # Outline
            outline = vcat(pts_3d, [pts_3d[1]])
            GLMakie.lines!(ax, outline, color = color, linewidth = 1.5)
            
            drawn_any = true
        end
        
        # Draw column marker at structural centerline
        v = skel.vertices[col.vertex_idx]
        c = Meshes.coords(v)
        off = col.structural_offset
        z_col = ustrip(u"m", c.z)
        pt = GLMakie.Point3f(ustrip(u"m", c.x) + off[1], ustrip(u"m", c.y) + off[2], z_col)
        GLMakie.scatter!(ax, [pt], color = :black, markersize = 10, marker = :rect)
    end
    
    # Add legend entries
    if drawn_any
        push!(leg_elems, GLMakie.PolyElement(color = (colors[1], 0.5), strokecolor = colors[1], strokewidth = 1))
        push!(leg_labels, "Corner Column Trib")
        push!(leg_elems, GLMakie.PolyElement(color = (colors[2], 0.5), strokecolor = colors[2], strokewidth = 1))
        push!(leg_labels, "Edge Column Trib")
        push!(leg_elems, GLMakie.PolyElement(color = (colors[3], 0.5), strokecolor = colors[3], strokewidth = 1))
        push!(leg_labels, "Interior Column Trib")
    end
end