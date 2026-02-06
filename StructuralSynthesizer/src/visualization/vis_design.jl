# =============================================================================
# Visualization for BuildingDesign
# =============================================================================
#
# visualize(design::BuildingDesign) - Display sized members with capacity ratios
#
# Modes:
#   :sized     - (default) 3D solid geometry showing actual element sizes
#   :deflected - Deformed shape with lines and shell meshes
#
# Coloring modes:
#   :utilization  - capacity ratio gradient (green → yellow → red)
#   :pass_fail    - binary green (ok) / red (not ok)
#   :member_type  - color by beam/column/strut
#   :section_type - categorical by section name
#   :displacement - (deflected mode only) total displacement magnitude
#
# Section visualization (sized mode only):
#   :none   - just centerlines (fastest)
#   :ends   - 2D section silhouettes at member endpoints
#   :solid  - 3D extruded sections as composed primitives
# =============================================================================

"""
    _build_element_design_map(design::BuildingDesign)

Build lookup tables mapping edge indices to design results.

Returns (ratios, ok_flags, section_names, types, section_objects) as Dicts keyed by edge_idx.
"""
function _build_element_design_map(design::BuildingDesign)
    struc = design.structure
    
    element_ratios = Dict{Int, Float64}()
    element_ok = Dict{Int, Bool}()
    element_section = Dict{Int, String}()
    element_type = Dict{Int, Symbol}()
    element_section_obj = Dict{Int, StructuralSizer.AbstractSection}()
    
    # Map columns
    for (col_idx, result) in design.columns
        col_idx > length(struc.columns) && continue
        col = struc.columns[col_idx]
        ratio = max(result.axial_ratio, result.interaction_ratio)
        sec_obj = section(col)  # Get actual section object from member
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            element_ratios[edge_idx] = ratio
            element_ok[edge_idx] = result.ok
            element_section[edge_idx] = result.section_size
            element_type[edge_idx] = :column
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
        end
    end
    
    # Map beams
    for (beam_idx, result) in design.beams
        beam_idx > length(struc.beams) && continue
        beam = struc.beams[beam_idx]
        ratio = max(result.flexure_ratio, result.shear_ratio)
        sec_obj = section(beam)
        for seg_idx in segment_indices(beam)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            element_ratios[edge_idx] = ratio
            element_ok[edge_idx] = result.ok
            element_section[edge_idx] = result.section_size
            element_type[edge_idx] = :beam
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
        end
    end
    
    # Map struts
    for (strut_idx, strut) in enumerate(struc.struts)
        sec_obj = section(strut)
        for seg_idx in segment_indices(strut)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            element_type[edge_idx] = :strut
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
        end
    end
    
    return element_ratios, element_ok, element_section, element_type, element_section_obj
end

"""
    _utilization_color(ratio::Float64, limits::Tuple{Float64, Float64})

Map a utilization ratio to a color on the RdYlGn reversed (red-yellow-green) colormap.
Low utilization → green, high utilization → red.
"""
function _utilization_color(ratio::Float64, limits::Tuple{Float64, Float64})
    t = clamp((ratio - limits[1]) / (limits[2] - limits[1]), 0.0, 1.0)
    # Sample reversed RdYlGn colormap: green at 0, red at 1
    cmap = GLMakie.Makie.to_colormap(:RdYlGn)
    # Reverse and interpolate
    idx = 1.0 - t  # reverse: low ratio → high index (green), high ratio → low index (red)
    n = length(cmap)
    i = clamp(Int(floor(idx * (n - 1))) + 1, 1, n)
    return cmap[i]
end

"""
    visualize(design::BuildingDesign; kwargs...)

Visualize a complete building design with sized members, slabs, and foundations.

This is the presentation-quality visualization for design output.

# Arguments
## Mode
- `mode::Symbol=:sized`: Visualization mode:
  - `:sized` - 3D solid geometry showing actual element sizes (default)
  - `:deflected` - Deformed shape with lines for frames, triangulated mesh for slabs
                   (requires `build_analysis_model!(design)` to have been called)

## Coloring
- `color_by::Symbol=:utilization`: Coloring mode:
  - `:utilization` - capacity ratio gradient (green → yellow → red at 1.0)
  - `:pass_fail` - binary green (ok) / red (not ok)
  - `:member_type` - color by beam/column/strut
  - `:section_type` - categorical by section name
  - `:displacement` - (deflected mode only) displacement magnitude
- `utilization_limits::Tuple=(0.0, 1.0)`: Color range for utilization mode

## Frame Elements (sized mode)
- `show_sections::Symbol=:none`: Section visualization mode:
  - `:none` - just centerlines (fastest)
  - `:ends` - 2D section silhouettes at member endpoints
  - `:solid` - 3D extruded sections as composed primitives
- `section_scale::Float64=1.0`: Scale factor for section geometry
- `section_alpha::Float64=0.7`: Transparency for section geometry
- `show_labels::Bool=false`: Show section size labels on elements
- `linewidth::Float64=2.0`: Line width for elements

## Deflected Mode
- `deflection_scale=:auto`: Scale factor for deflections, or `:auto` to auto-compute
- `show_original_geometry::Bool=true`: Show original geometry as dashed reference

## Slabs & Foundations (sized mode)
- `show_slabs::Bool=true`: Show slabs as 3D boxes with designed thickness
- `show_foundations::Bool=true`: Show foundations as 3D boxes
- `slab_color=:lightblue`: Slab color
- `slab_alpha::Float64=0.6`: Slab transparency
- `foundation_color=:gray70`: Foundation color
- `foundation_alpha::Float64=0.7`: Foundation transparency

## Other
- `show_nodes::Bool=true`: Show node markers
- `show_supports::Bool=true`: Show support markers
- `markersize::Float64=10.0`: Marker size for nodes/supports
- `theme::Union{Nothing,Symbol}=nothing`: `:light`, `:dark`, or `nothing`

# Example
```julia
design = design_building(struc, params)
visualize(design)                              # Full design view with slabs + foundations
visualize(design, mode=:deflected)             # Deflected shape view
visualize(design, show_sections=:solid)        # With 3D member sections
visualize(design, color_by=:pass_fail)         # Quick pass/fail check
visualize(design, show_slabs=false)            # Hide slabs
```
"""
function visualize(design::BuildingDesign;
    mode::Symbol = :sized,
    color_by::Symbol = :utilization,
    show_sections::Symbol = :none,
    section_scale::Float64 = 1.0,
    section_alpha::Float64 = 0.7,
    utilization_limits::Tuple{Float64, Float64} = (0.0, 1.0),
    show_labels::Bool = false,
    show_nodes::Bool = true,
    show_supports::Bool = true,
    show_slabs::Bool = true,
    show_foundations::Bool = true,
    show_original_geometry::Bool = true,
    deflection_scale = :auto,
    slab_color = :lightblue,
    slab_alpha::Float64 = 0.6,
    foundation_color = :gray70,
    foundation_alpha::Float64 = 0.7,
    linewidth::Float64 = 2.0,
    markersize::Float64 = 10.0,
    theme::Union{Nothing, Symbol} = nothing,
    resolution::Int = 20
)
    struc = design.structure
    skel = struc.skeleton
    # For deflected mode, prefer design.asap_model (has shells) if available
    model = if mode == :deflected && !isnothing(design.asap_model)
        design.asap_model
    else
        struc.asap_model
    end
    
    # Apply theme if specified
    if theme == :light
        GLMakie.set_theme!(StructuralPlots.sp_light)
    elseif theme == :dark
        GLMakie.set_theme!(StructuralPlots.sp_dark)
    end
    
    # Build element → design data mapping
    element_ratios, element_ok, element_section, element_type, element_section_obj = _build_element_design_map(design)
    
    # Collect unique sections for categorical coloring
    unique_sections = unique(values(element_section))
    section_colors_map = Dict(s => StructuralPlots.harmonic[mod1(i, length(StructuralPlots.harmonic))] 
                              for (i, s) in enumerate(unique_sections))
    
    # Member type colors
    type_colors = Dict(
        :column => :steelblue,
        :beam => :coral,
        :strut => :mediumpurple,
        :other => :gray60
    )
    
    # Create figure
    title_str = "Design: $(design.params.name)"
    if !design.summary.all_checks_pass
        title_str *= " [FAILS]"
    end
    if mode == :deflected
        title_str *= " (Deflected)"
    end
    
    fig = GLMakie.Figure(size = (1200, 800))
    ax = GLMakie.Axis3(fig[1, 1], 
        aspect = :data,
        title = title_str,
        xlabel = "x [m]",
        ylabel = "y [m]",
        zlabel = "z [m]"
    )
    
    # Legend collectors
    leg_elems = []
    leg_labels = String[]
    
    # Track label positions for later
    label_positions = GLMakie.Point3f[]
    label_texts = String[]
    
    # Color data for deflected mode coloring
    all_colors = Float64[]
    crange = (0.0, 1.0)
    
    # =========================================================================
    # MODE: DEFLECTED - deformed shape with lines and shell meshes
    # =========================================================================
    if mode == :deflected
        # Draw original geometry as dashed reference
        if show_original_geometry
            # Frame elements
            for element in model.elements
                p1, p2 = get_drawing_pts(element, 0.0)
                GLMakie.lines!(ax, [p1[1], p2[1]], [p1[2], p2[2]], [p1[3], p2[3]], 
                              color = (:gray60, 0.4), linewidth = 0.5, linestyle = :dash,
                              transparency = true)
            end
            # Shell elements (original mesh outlines)
            if Asap.has_shell_elements(model)
                for shell in model.shell_elements
                    pts = [GLMakie.Point3f(ustrip.(u"m", node.position)...) for node in shell.nodes]
                    GLMakie.lines!(ax, [pts..., pts[1]],
                                   color = (:gray60, 0.3), linewidth = 0.3, linestyle = :dash,
                                   transparency = true)
                end
            end
            push!(leg_elems, GLMakie.LineElement(color = (:gray60, 0.4), linewidth = 1, linestyle = :dash))
            push!(leg_labels, "Original Geometry")
        end
        
        # Calculate displacement data
        avg_len_unitful = model.nElements > 0 ? sum(getproperty.(model.elements, :length)) / model.nElements : 1.0u"m"
        avg_len = ustrip(u"m", avg_len_unitful)
        increment = avg_len_unitful / resolution
        
        edisps = Asap.displacements(model, increment)
        if isempty(edisps)
            @warn "No displacement data available for deflected mode"
        else
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
            
            # Collect all displaced points for coloring
            all_points = Vector{GLMakie.Point3f}[]
            
            for (i, edisp) in enumerate(edisps)
                pos = edisp.basepositions .+ deflection_scale .* edisp.uglobal
                pts = [GLMakie.Point3f(pos[1, j], pos[2, j], pos[3, j]) for j in 1:size(pos, 2)]
                push!(all_points, pts)
                
                if color_by == :displacement
                    dvals = [norm(edisp.uglobal[:, j]) for j in 1:size(edisp.uglobal, 2)]
                    append!(all_colors, dvals)
                end
            end
            
            # Compute color range
            if color_by == :displacement && !isempty(all_colors)
                crange = (minimum(all_colors), maximum(all_colors))
                if crange[1] ≈ crange[2]
                    crange = (crange[1], crange[1] + 1.0)
                end
            end
            
            # Draw deflected elements
            use_displacement_coloring = color_by == :displacement && !isempty(all_colors)
            color_idx = 1
            
            for (i, pts) in enumerate(all_points)
                n_pts = length(pts)
                if use_displacement_coloring
                    # Use per-point coloring - slice exactly n_pts colors
                    local_colors = all_colors[color_idx:min(color_idx + n_pts - 1, length(all_colors))]
                    GLMakie.lines!(ax, pts, color = local_colors, colorrange = crange,
                                  linewidth = linewidth, colormap = :turbo)
                    color_idx += n_pts
                else
                    # Use utilization coloring
                    c = if color_by == :utilization
                        ratio = get(element_ratios, i, 0.0)
                        _utilization_color(ratio, utilization_limits)
                    elseif color_by == :pass_fail
                        get(element_ok, i, true) ? :green : :red
                    elseif color_by == :member_type
                        typ = get(element_type, i, :other)
                        get(type_colors, typ, :gray60)
                    else
                        :black
                    end
                    lw = haskey(element_ratios, i) ? linewidth : linewidth * 0.5
                    GLMakie.lines!(ax, pts, color = c, linewidth = lw)
                end
            end
            
            push!(leg_elems, GLMakie.LineElement(color = :steelblue, linewidth = 2))
            push!(leg_labels, "Elements (Deflected)")
        end
        
        # Draw deflected shell mesh if available
        if show_slabs && Asap.has_shell_elements(model)
            shell_disp_colors = Float64[]  # For displacement coloring
            
            # Compute deflection scale from shells if not set by frame elements
            if deflection_scale === :auto || deflection_scale == 1.0
                max_shell_disp = 0.0
                for shell in model.shell_elements
                    for node in shell.nodes
                        disp = Asap.to_displacement_vec(node.displacement)
                        max_shell_disp = max(max_shell_disp, norm(disp[1:3]))
                    end
                end
                if max_shell_disp > 1e-12
                    # Scale so max deflection is ~10% of typical span
                    avg_len = model.nElements > 0 ? avg_len : 5.0  # fallback to 5m
                    deflection_scale = (avg_len * 0.1) / max_shell_disp
                end
            end
            
            # Collect all shell triangles
            shell_verts = GLMakie.Point3f[]
            shell_faces = GLMakie.TriangleFace{Int}[]
            
            for shell in model.shell_elements
                base_idx = length(shell_verts)
                
                # Add displaced vertices for this triangle
                for node in shell.nodes
                    pos = [ustrip(u"m", node.position[j]) for j in 1:3]
                    disp = Asap.to_displacement_vec(node.displacement)
                    deformed = pos .+ deflection_scale .* disp[1:3]
                    push!(shell_verts, GLMakie.Point3f(deformed...))
                    
                    if color_by == :displacement
                        push!(shell_disp_colors, norm(disp[1:3]))
                    end
                end
                
                # Add triangle face (1-indexed)
                push!(shell_faces, GLMakie.TriangleFace(base_idx + 1, base_idx + 2, base_idx + 3))
            end
            
            if !isempty(shell_verts) && !isempty(shell_faces)
                if color_by == :displacement && !isempty(shell_disp_colors)
                    # Compute combined color range (frames + shells)
                    shell_crange = (minimum(shell_disp_colors), maximum(shell_disp_colors))
                    combined_crange = if !isempty(all_colors)
                        (min(crange[1], shell_crange[1]), max(crange[2], shell_crange[2]))
                    else
                        shell_crange
                    end
                    if combined_crange[1] ≈ combined_crange[2]
                        combined_crange = (combined_crange[1], combined_crange[1] + 1.0)
                    end
                    crange = combined_crange  # Update for colorbar
                    
                    GLMakie.mesh!(ax, shell_verts, shell_faces,
                                  color = shell_disp_colors,
                                  colorrange = combined_crange,
                                  colormap = :turbo,
                                  transparency = true)
                else
                    GLMakie.mesh!(ax, shell_verts, shell_faces,
                                  color = (slab_color, slab_alpha),
                                  transparency = true)
                end
                
                # Draw mesh edges for visibility
                for face in shell_faces
                    p1, p2, p3 = shell_verts[face[1]], shell_verts[face[2]], shell_verts[face[3]]
                    GLMakie.lines!(ax, [p1, p2, p3, p1],
                                   color = (:gray40, 0.3), linewidth = 0.5,
                                   transparency = true)
                end
                
                push!(leg_elems, GLMakie.PolyElement(color = (slab_color, slab_alpha), 
                      strokecolor = :gray40, strokewidth = 1))
                push!(leg_labels, "Slabs (Deflected Mesh)")
            end
        elseif show_slabs && !isempty(struc.slabs)
            # Fallback: no shell model available, show reference slabs
            draw_slabs!(ax, struc; color=slab_color, alpha=slab_alpha * 0.5)
            push!(leg_elems, GLMakie.PolyElement(color = (slab_color, slab_alpha * 0.5), 
                  strokecolor = :gray40, strokewidth = 1))
            push!(leg_labels, "Slabs (Reference)")
        end
        
    # =========================================================================
    # MODE: SIZED - 3D solid geometry showing actual element sizes
    # =========================================================================
    else  # mode == :sized (default)
        # Draw elements with design-based coloring and optional section geometry
        for (i, element) in enumerate(model.elements)
            p1_raw, p2_raw = get_drawing_pts(element, 0.0)
            p1 = GLMakie.Point3f(p1_raw...)
            p2 = GLMakie.Point3f(p2_raw...)
            
            # Determine color based on coloring mode
            c = if color_by == :utilization
                ratio = get(element_ratios, i, 0.0)
                _utilization_color(ratio, utilization_limits)
            elseif color_by == :pass_fail
                get(element_ok, i, true) ? :green : :red
            elseif color_by == :member_type
                typ = get(element_type, i, :other)
                get(type_colors, typ, :gray60)
            elseif color_by == :section_type
                sec_name = get(element_section, i, "")
                get(section_colors_map, sec_name, :gray60)
            else
                :black
            end
            
            # Get section object for this element (if available)
            sec_obj = get(element_section_obj, i, nothing)
            has_section = !isnothing(sec_obj)
            
            # Draw based on show_sections mode
            if show_sections == :solid && has_section
                # Draw 3D extruded section
                draw_section_solid!(ax, sec_obj, p1, p2; 
                    color = c, alpha = section_alpha)
            elseif show_sections == :ends && has_section
                # Draw 2D section silhouettes at ends + centerline
                draw_section_ends!(ax, sec_obj, p1, p2;
                    color = c, alpha = section_alpha, scale = section_scale)
                # Also draw thin centerline for context
                GLMakie.lines!(ax, [p1[1], p2[1]], [p1[2], p2[2]], [p1[3], p2[3]],
                    color = (c, 0.5), linewidth = 0.5, linestyle = :dash)
            else
                # Default: just draw centerline
                lw = haskey(element_ratios, i) ? linewidth : linewidth * 0.5
                GLMakie.lines!(ax, [p1[1], p2[1]], [p1[2], p2[2]], [p1[3], p2[3]],
                    color = c, linewidth = lw)
            end
            
            # Collect label position (midpoint) if requested
            if show_labels && haskey(element_section, i) && !isempty(element_section[i])
                mid = (p1 .+ p2) ./ 2
                push!(label_positions, mid)
                push!(label_texts, element_section[i])
            end
        end
        
        # Draw slabs (3D boxes with designed thickness)
        if show_slabs && !isempty(struc.slabs)
            draw_slabs!(ax, struc; color=slab_color, alpha=slab_alpha)
            push!(leg_elems, GLMakie.PolyElement(color = (slab_color, slab_alpha), 
                  strokecolor = :gray40, strokewidth = 1))
            push!(leg_labels, "Slabs")
        end
        
        # Draw foundations (3D boxes with designed dimensions)
        if show_foundations && !isempty(struc.foundations)
            draw_foundations!(ax, struc; color=foundation_color, alpha=foundation_alpha)
            push!(leg_elems, GLMakie.PolyElement(color = (foundation_color, foundation_alpha), 
                  strokecolor = :gray40, strokewidth = 1))
            push!(leg_labels, "Foundations")
        end
    end
    
    # Draw nodes
    if show_nodes && !isempty(model.nodes)
        nodes_pos = [GLMakie.Point3f(ustrip.(u"m", n.position)...) for n in model.nodes]
        GLMakie.scatter!(ax, nodes_pos, color = :black, markersize = markersize / 2)
        push!(leg_elems, GLMakie.MarkerElement(marker = :circle, color = :black, markersize = 8))
        push!(leg_labels, "Nodes")
    end
    
    # Draw supports
    if show_supports
        support_indices = get(skel.groups_vertices, :support, Int[])
        if !isempty(support_indices) && !isempty(model.nodes)
            valid_indices = filter(i -> i <= length(model.nodes), support_indices)
            if !isempty(valid_indices)
                supports = model.nodes[valid_indices]
                supp_pos = [GLMakie.Point3f(ustrip.(u"m", n.position)...) for n in supports]
                GLMakie.scatter!(ax, supp_pos, color = :red, marker = :utriangle, markersize = markersize)
                push!(leg_elems, GLMakie.MarkerElement(marker = :utriangle, color = :red, markersize = 12))
                push!(leg_labels, "Supports")
            end
        end
    end
    
    # Draw labels (sized mode only)
    if mode == :sized && show_labels && !isempty(label_positions)
        GLMakie.text!(ax, label_positions, text = label_texts,
            fontsize = 10, color = :black, align = (:center, :bottom))
    end
    
    # Sidebar with legend and colorbar
    sidebar = fig[1, 2] = GLMakie.GridLayout()
    row_idx = 1
    
    # Colorbar based on mode and coloring
    if mode == :deflected && color_by == :displacement && !isempty(all_colors)
        GLMakie.Colorbar(sidebar[row_idx, 1], 
            limits = crange, 
            colormap = :turbo,
            label = "Displacement [m]")
        row_idx += 1
    elseif color_by == :utilization
        GLMakie.Colorbar(sidebar[row_idx, 1], 
            limits = utilization_limits, 
            colormap = GLMakie.cgrad(:RdYlGn, rev=true),
            label = "Capacity Ratio")
        row_idx += 1
    elseif color_by == :pass_fail
        push!(leg_elems, GLMakie.LineElement(color = :green, linewidth = 3))
        push!(leg_labels, "OK (ratio ≤ 1.0)")
        push!(leg_elems, GLMakie.LineElement(color = :red, linewidth = 3))
        push!(leg_labels, "FAIL (ratio > 1.0)")
    elseif color_by == :member_type
        push!(leg_elems, GLMakie.LineElement(color = :steelblue, linewidth = 3))
        push!(leg_labels, "Columns")
        push!(leg_elems, GLMakie.LineElement(color = :coral, linewidth = 3))
        push!(leg_labels, "Beams")
        push!(leg_elems, GLMakie.LineElement(color = :mediumpurple, linewidth = 3))
        push!(leg_labels, "Struts")
    end
    
    # Add legend
    if !isempty(leg_elems)
        GLMakie.Legend(sidebar[row_idx, 1], leg_elems, leg_labels, 
            mode == :deflected ? "Deflected" : "Design")
    end
    
    # Add summary text
    row_idx += 1
    summary = design.summary
    summary_text = if mode == :deflected
        """
        Mode: Deflected Shape
        Scale: $(round(deflection_scale, digits=1))x
        """
    else
        """
        Critical: $(summary.critical_element)
        Max ratio: $(round(summary.critical_ratio, digits=3))
        All pass: $(summary.all_checks_pass ? "✓" : "✗")
        """
    end
    GLMakie.Label(sidebar[row_idx, 1], summary_text, 
        fontsize = 12, halign = :left, valign = :top)
    
    display(fig)
    return fig
end
