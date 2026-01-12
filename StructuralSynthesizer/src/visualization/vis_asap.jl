import .AsapToolkit
import GLMakie
import Asap
import LinearAlgebra: norm

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
"""
function get_drawing_pts(element::Asap.Element{R}, gap_factor=0.05) where R
    p1 = element.nodeStart.position
    p2 = element.nodeEnd.position
    
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
    # Truss elements are inherently pinned, so we might want to show gaps by default
    p1 = element.nodeStart.position
    p2 = element.nodeEnd.position
    v = p2 .- p1
    return p1 .+ (v .* gap_factor), p2 .- (v .* gap_factor)
end

"""
    visualize(struc::BuildingStructure; kwargs...)

Karamba-style visualization for a BuildingStructure. 
"""
function visualize(struc::BuildingStructure; kwargs...)
    return visualize(struc.skeleton, struc.asap_model; kwargs...)
end

"""
    visualize(skel::BuildingSkeleton, model::Asap.Model; kwargs...)

Karamba-style visualization for Asap models, using skeleton groups for supports.

# Arguments
- `deflection_scale::Union{Float64,Symbol}=:auto`: Scale factor for deflected shape, or `:auto` to auto-compute.
- `mode::Symbol=:original`: `:original` or `:deflected`.
- `color_by::Symbol=:none`: `:none`, `:displacement`, or `:stress`.
- `show_nodes::Bool=true`: Whether to show nodes.
- `show_supports::Bool=true`: Whether to show supports.
- `show_releases::Bool=true`: Whether to show element releases (gaps).
- `show_dofs::Bool=false`: Whether to show degrees of freedom (arrows).
- `resolution::Int=20`: Number of segments per element for curved shapes.
- `linewidth::Float64=1.0`: Line width for elements.
- `markersize::Float64=10.0`: Marker size for nodes/supports.
"""
function visualize(skel::BuildingSkeleton, model::Asap.Model;
    deflection_scale = :auto, # :auto or a Float64 scale factor
    mode = :original, # :original, :deflected
    color_by = :none, # :none, :displacement, :stress
    show_nodes = true,
    show_supports = true,
    show_releases = true,
    show_dofs = false,
    resolution = 20,
    linewidth = 1.0,
    markersize = 10.0
)
    fig = GLMakie.Figure(size = (1200, 800))
    ax = GLMakie.Axis3(fig[1, 1], aspect = :data, title = "Asap Model Visualization ($(mode))")

    # Collectors for custom legend
    leg_elems = []
    leg_labels = String[]

    # 1. Elements
    if mode == :original
        for element in model.elements
            if show_releases
                p1, p2 = get_drawing_pts(element, 0.05)
            else
                p1 = element.nodeStart.position
                p2 = element.nodeEnd.position
            end
            GLMakie.lines!(ax, [p1[1], p2[1]], [p1[2], p2[2]], [p1[3], p2[3]], 
                          color = :black, linewidth = linewidth)
        end
        push!(leg_elems, GLMakie.LineElement(color = :black, linewidth = 2))
        push!(leg_labels, "Elements")

    elseif mode == :deflected
        # Draw original geometry as thin dotted lines for reference
        for element in model.elements
            p1 = element.nodeStart.position
            p2 = element.nodeEnd.position
            GLMakie.lines!(ax, [p1[1], p2[1]], [p1[2], p2[2]], [p1[3], p2[3]], 
                          color = (:black, 0.75), linewidth = 0.5, linestyle = :dash)
        end
        push!(leg_elems, GLMakie.LineElement(color = (:black, 0.4), linewidth = 1, linestyle = :dot))
        push!(leg_labels, "Original Geometry")

        # Calculate displacements/forces with a reasonable increment
        avg_len = model.nElements > 0 ? sum(getproperty.(model.elements, :length)) / model.nElements : 1.0
        increment = avg_len / resolution
        
        # AsapToolkit provides high-level helpers for displacements and forces
        edisps = AsapToolkit.displacements(model, increment)
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
        eforces = color_by == :stress ? AsapToolkit.InternalForces(model, increment) : nothing

        # Collectors for consistent coloring across all members
        all_points = Vector{GLMakie.Point3f}[]
        all_colors = Float64[]

        for (i, edisp) in enumerate(edisps)
            # basepositions + (deflection * uglobal)
            # Both are [3 x n] matrices in GCS
            pos = edisp.basepositions .+ deflection_scale .* edisp.uglobal
            pts = [GLMakie.Point3f(pos[1, j], pos[2, j], pos[3, j]) for j in 1:size(pos, 2)]
            push!(all_points, pts)
            
            if color_by == :displacement
                dvals = [norm(edisp.uglobal[:, j]) for j in 1:size(edisp.uglobal, 2)]
                append!(all_colors, dvals)
            elseif color_by == :stress && !isnothing(eforces)
                eforce = eforces[i]
                section = edisp.element.section
                
                # Extract section properties (fallback to unit values if missing)
                A = hasproperty(section, :area) ? section.area : 1.0
                Sx = hasproperty(section, :Sx) ? section.Sx : 1.0
                Sy = hasproperty(section, :Sy) ? section.Sy : 1.0
                
                # Combined stress approximation: σ = |P/A| + |Mz/Sx| + |My/Sy|
                # AsapToolkit.InternalForces contains vectors P, My, Vy, Mz, Vz
                svals = [abs(eforce.P[j]/A) + abs(eforce.Mz[j]/Sx) + abs(eforce.My[j]/Sy) for j in 1:length(eforce.P)]
                append!(all_colors, svals)
            end
        end

        # Calculate consistent color range for the whole model
        crange = isempty(all_colors) ? (0.0, 1.0) : (minimum(all_colors), maximum(all_colors))
        if crange[1] == crange[2]
            crange = (crange[1], crange[1] + 1.0) # avoid singular range
        end

        # Plot deflected elements
        color_idx = 1
        for pts in all_points
            if color_by == :none
                GLMakie.lines!(ax, pts, color = :black, linewidth = linewidth)
            else
                res = length(pts)
                cvals = all_colors[color_idx:color_idx+res-1]
                GLMakie.lines!(ax, pts, color = cvals, colorrange = crange, 
                              linewidth = linewidth, colormap = :turbo)
                color_idx += res
            end
        end
        
        if color_by == :none
            push!(leg_elems, GLMakie.LineElement(color = :black, linewidth = 2))
            push!(leg_labels, "Elements (Deflected)")
        end
    end

    # 2. Nodes
    if show_nodes
        nodes_pos = [GLMakie.Point3f(n.position...) for n in model.nodes]
        GLMakie.scatter!(ax, nodes_pos, color = :black, markersize = markersize / 2)
        push!(leg_elems, GLMakie.MarkerElement(marker = :circle, color = :black, markersize = 8))
        push!(leg_labels, "Nodes")
    end

    # 3. Supports (Triangle markers)
    if show_supports
        support_indices = get(skel.groups_vertices, :support, Int[])
        if !isempty(support_indices)
            supports = model.nodes[support_indices]
            supp_pos = [GLMakie.Point3f(n.position...) for n in supports]
            GLMakie.scatter!(ax, supp_pos, color = :red, marker = :utriangle, markersize = markersize)
            push!(leg_elems, GLMakie.MarkerElement(marker = :utriangle, color = :red, markersize = 12))
            push!(leg_labels, "Supports")
        end
    end

    # 4. Degrees of Freedom
    if show_dofs
        # Ensure model is processed to populate length, LCS, etc.
        model.processed || Asap.process!(model)

        # Estimate a good reference size for markers
        avg_len = model.nElements > 0 ? sum(getproperty.(model.elements, :length)) / model.nElements : 1.0
        size_ref = avg_len * 0.15
        
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
            p = GLMakie.Point3f(node.position...)
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