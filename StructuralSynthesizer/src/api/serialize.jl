# =============================================================================
# API Serialize — BuildingDesign → JSON output structs
#
# All length/volume/mass values are converted to the display system specified
# in design.params.display_units (from params.unit_system: "imperial" or "metric").
# Positions and displacements sent to clients (e.g. Grasshopper) are forced to
# regular length units (ft or m) so the API always returns consistent numeric data.
# =============================================================================

"""Round a number to the given decimal digits (default 3). Used for consistent API output."""
_round_val(x; digits=3) = round(x; digits=digits)

"""Return sorted indices of a dict (e.g. design.slabs, design.columns)."""
_sorted_indices(d::AbstractDict) = sort(collect(keys(d)))

"""Convert a length value to display units as Float64. Accepts Number (assumed m) or Quantity.
Throws `ArgumentError` when a non-length quantity is passed into a length field.
Optional `context` (e.g. (node_id=i, position_index=j)) is included for diagnostics."""
function _to_display_length(du::DisplayUnits, value; context=nothing)
    len_unit = du.units[:length]
    if value isa Quantity
        try
            return ustrip(len_unit, uconvert(len_unit, value))
        catch e
            if e isa Unitful.DimensionError
                d = dimension(value)
                msg = context === nothing ?
                      "Expected length (𝐋), got $d in a length output field." :
                      "Expected length (𝐋), got $d in a length output field (context=$(context))."
                throw(ArgumentError(msg))
            end
            rethrow()
        end
    elseif value isa Number
        # Plain numerics are treated as SI meters by API convention.
        return ustrip(len_unit, value * u"m")
    else
        return Float64(value)
    end
end

"""Length unit string for API consumers (e.g. Grasshopper): \"ft\" or \"m\"."""
_length_unit_string(du::DisplayUnits) = du.units[:length] == u"ft" ? "ft" : "m"

"""
Force a 3D position (or any length-3 vector of numbers/quantities) into Float64s
in display length units. Used so Grasshopper and other clients always receive positions
in consistent units (ft or m). Non-length quantities throw immediately.
"""
function _position_to_display_lengths(du::DisplayUnits, position_vec; node_id=nothing)
    n = length(position_vec)
    out = Vector{Float64}(undef, n)
    for j in 1:n
        ctx = node_id !== nothing ? (node_id=node_id, position_index=j) : (position_index=j,)
        out[j] = _to_display_length(du, position_vec[j]; context=ctx)
    end
    return out
end

"""Convert a Quantity to display unit for a given category (:length, :thickness, :volume, :mass, etc.)."""
_to_display(du::DisplayUnits, category::Symbol, value) =
    ustrip(du.units[category], uconvert(du.units[category], value))

"""
    design_to_json(design::BuildingDesign; geometry_hash::String="") -> APIOutput

Extract a `BuildingDesign` into an `APIOutput` struct ready for JSON serialisation.
Units are converted to the display system specified in `design.params.display_units`.
"""
function design_to_json(design::BuildingDesign; geometry_hash::String="")
    du = design.params.display_units

    slabs = _serialize_slabs(design, du)
    columns = _serialize_columns(design, du)
    beams = _serialize_beams(design, du)
    foundations = _serialize_foundations(design, du)
    summary = _serialize_summary(design, du)
    visualization = _serialize_visualization(design, du)

    return APIOutput(
        status = "ok",
        compute_time_s = _round_val(design.compute_time_s; digits=3),
        length_unit = _length_unit_string(du),
        summary = summary,
        slabs = slabs,
        columns = columns,
        beams = beams,
        foundations = foundations,
        geometry_hash = geometry_hash,
        visualization = visualization,
    )
end

# ─── Slabs ────────────────────────────────────────────────────────────────────

"""Serialize slab design results into `APISlabResult` records."""
function _serialize_slabs(design::BuildingDesign, du::DisplayUnits)
    results = APISlabResult[]
    for idx in _sorted_indices(design.slabs)
        sr = design.slabs[idx]
        t_display = _to_display(du, :thickness, sr.thickness)
        slab_ok = sr.converged && sr.deflection_ok && sr.punching_ok
        push!(results, APISlabResult(
            id = idx,
            ok = slab_ok,
            thickness_in = _round_val(t_display; digits=2),
            converged = sr.converged,
            failure_reason = sr.failure_reason,
            failing_check = sr.failing_check,
            iterations = sr.iterations,
            deflection_ok = sr.deflection_ok,
            deflection_ratio = _round_val(sr.deflection_ratio),
            punching_ok = sr.punching_ok,
            punching_max_ratio = _round_val(sr.punching_max_ratio),
        ))
    end
    return results
end

# ─── Columns ──────────────────────────────────────────────────────────────────

"""Serialize column design results into `APIColumnResult` records."""
function _serialize_columns(design::BuildingDesign, du::DisplayUnits)
    results = APIColumnResult[]
    for idx in _sorted_indices(design.columns)
        cr = design.columns[idx]
        c1_display = _to_display(du, :thickness, cr.c1)
        c2_display = _to_display(du, :thickness, cr.c2)
        push!(results, APIColumnResult(
            id = idx,
            section = cr.section_size,
            c1_in = _round_val(c1_display; digits=1),
            c2_in = _round_val(c2_display; digits=1),
            shape = string(cr.shape),
            axial_ratio = _round_val(cr.axial_ratio),
            interaction_ratio = _round_val(cr.interaction_ratio),
            ok = cr.ok,
        ))
    end
    return results
end

# ─── Beams ────────────────────────────────────────────────────────────────────

"""Serialize beam design results into `APIBeamResult` records."""
function _serialize_beams(design::BuildingDesign, du::DisplayUnits)
    results = APIBeamResult[]
    for idx in _sorted_indices(design.beams)
        br = design.beams[idx]
        push!(results, APIBeamResult(
            id = idx,
            section = br.section_size,
            flexure_ratio = _round_val(br.flexure_ratio),
            shear_ratio = _round_val(br.shear_ratio),
            ok = br.ok,
        ))
    end
    return results
end

# ─── Foundations ──────────────────────────────────────────────────────────────

"""Serialize foundation design results into `APIFoundationResult` records."""
function _serialize_foundations(design::BuildingDesign, du::DisplayUnits)
    results = APIFoundationResult[]
    for idx in _sorted_indices(design.foundations)
        fr = design.foundations[idx]
        push!(results, APIFoundationResult(
            id = idx,
            length_ft = _round_val(_to_display_length(du, fr.length); digits=2),
            width_ft = _round_val(_to_display_length(du, fr.width); digits=2),
            depth_ft = _round_val(_to_display_length(du, fr.depth); digits=2),
            bearing_ratio = _round_val(fr.bearing_ratio),
            ok = fr.ok,
        ))
    end
    return results
end

# ─── Summary ─────────────────────────────────────────────────────────────────

"""Serialize the design summary (material quantities, critical ratio) into `APISummary`."""
function _serialize_summary(design::BuildingDesign, du::DisplayUnits)
    s = design.summary
    vol_display = _to_display(du, :volume, s.concrete_volume)
    steel_display = _to_display(du, :mass, s.steel_weight)
    rebar_display = _to_display(du, :mass, s.rebar_weight)
    return APISummary(
        all_pass = s.all_checks_pass,
        concrete_volume_ft3 = _round_val(vol_display; digits=1),
        steel_weight_lb = _round_val(steel_display; digits=0),
        rebar_weight_lb = _round_val(rebar_display; digits=0),
        embodied_carbon_kgCO2e = _round_val(s.embodied_carbon; digits=0),
        critical_ratio = _round_val(s.critical_ratio),
        critical_element = s.critical_element,
    )
end

# ─── Visualization ────────────────────────────────────────────────────────────

"""
    _serialize_visualization(design::BuildingDesign, du::DisplayUnits) -> Union{APIVisualization, Nothing}

Extract visualization geometry from the analysis model (post-shatter, post-design).
Returns nothing if analysis model is not available.
"""
function _serialize_visualization(design::BuildingDesign, du::DisplayUnits)
    struc = design.structure
    model = isnothing(design.asap_model) ? struc.asap_model : design.asap_model
    isnothing(model) && return nothing

    # Ensure model is solved (needed for displacements)
    if !model.processed
        Asap.process!(model)
    end
    if isempty(model.u)
        Asap.solve!(model)
    end

    # Extract nodes with displacements
    nodes = _serialize_visualization_nodes(model, du)

    # Extract frame elements
    frame_elements = _serialize_visualization_frame_elements(design, model, du)

    # Extract sized slabs (from struc.slabs - cell boundaries)
    sized_slabs = _serialize_sized_slabs(design, struc, du)

    # Extract deflected slab meshes (from model.shell_elements)
    deflected_meshes = _serialize_deflected_slab_meshes(design, model, du)

    # Extract foundations for sized/original visualization modes
    foundations = _serialize_visualization_foundations(design, struc, du)

    # Compute suggested scale factor
    max_disp = isempty(nodes) ? 0.0 : maximum(norm(n.displacement_ft) for n in nodes)
    avg_length = _compute_avg_element_length(model, du)
    suggested_scale = max_disp > 1e-12 ? (avg_length * 0.1) / max_disp : 1.0
    
    return APIVisualization(
        nodes = nodes,
        frame_elements = frame_elements,
        sized_slabs = sized_slabs,
        deflected_slab_meshes = deflected_meshes,
        foundations = foundations,
        suggested_scale_factor = _round_val(suggested_scale),
        max_displacement_ft = _round_val(max_disp; digits=6),
    )
end

"""Serialize model nodes with positions and displacements for visualization.
Positions and displacements are forced to display length units (ft or m) so Grasshopper
always receives consistent numeric data."""
function _serialize_visualization_nodes(model, du::DisplayUnits)
    nodes = APIVisualizationNode[]
    for (i, node) in enumerate(model.nodes)
        # Force position to three lengths in display units (handles bad dimensions with 0.0 + warning)
        pos = _position_to_display_lengths(du, node.position; node_id=i)
        # Displacement: first 3 components are translations (Float64 in m from to_displacement_vec)
        disp_m = Asap.to_displacement_vec(node.displacement)[1:3]
        disp = _to_display_length.(Ref(du), disp_m)
        push!(nodes, APIVisualizationNode(
            node_id = i,
            position_ft = [_round_val(p; digits=6) for p in pos],
            displacement_ft = [_round_val(d; digits=9) for d in disp],
        ))
    end
    return nodes
end

"""Serialize frame elements with section geometry, utilization, and interpolated deflected shapes."""
function _serialize_visualization_frame_elements(design::BuildingDesign, model, du::DisplayUnits)
    struc = design.structure
    skel = struc.skeleton
    
    # Build element → design result mapping
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
        sec_obj = section(col)
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_idx > length(model.elements) && continue
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
            edge_idx > length(model.elements) && continue
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
            edge_idx > length(model.elements) && continue
            element_type[edge_idx] = :strut
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
        end
    end
    
    # Get interpolated displacements using Asap.displacements (cubic interpolation)
    # This provides smooth deflected curves with cubic Hermite interpolation
    avg_len_unitful = model.nElements > 0 ? sum(getproperty.(model.elements, :length)) / model.nElements : 1.0u"m"
    increment = avg_len_unitful / 20  # 20 points per element (matches Julia visualization)
    edisps = Asap.displacements(model, increment)
    
    # Build element_id -> ElementDisplacements map
    edisp_map = Dict{Int, Asap.ElementDisplacements}()
    for (i, edisp) in enumerate(edisps)
        elem_idx = edisp.element.elementID
        edisp_map[elem_idx] = edisp
    end
    
    # Import section_polygon from visualization utilities
    # section_polygon returns Vector{NTuple{2, Float64}} in meters (local y-z coordinates)
    
    # Serialize elements
    elements = APIVisualizationFrameElement[]
    for (elem_idx, elem) in enumerate(model.elements)
        node_start_id = elem.nodeStart.nodeID
        node_end_id = elem.nodeEnd.nodeID
        
        ratio = get(element_ratios, elem_idx, 0.0)
        ok = get(element_ok, elem_idx, true)
        sec_name = get(element_section, elem_idx, "")
        elem_type = get(element_type, elem_idx, :other)
        
        # Extract section geometry
        sec_obj = get(element_section_obj, elem_idx, nothing)
        section_type, depth_ft, width_ft, flange_width_ft, web_thickness_ft, flange_thickness_ft =
            _extract_section_geometry(sec_obj, du)

        # Extract section polygon (2D outline in local y-z coordinates)
        section_poly = Vector{Float64}[]
        if !isnothing(sec_obj)
            try
                # section_polygon returns Vector{NTuple{2, Float64}} in meters
                poly_local = section_polygon(sec_obj)
                for (y, z) in poly_local
                    y_disp = _to_display_length(du, y)
                    z_disp = _to_display_length(du, z)
                    push!(section_poly, [_round_val(y_disp; digits=6), _round_val(z_disp; digits=6)])
                end
            catch e
                # If section_polygon fails (e.g., unsupported section type), leave empty
                @debug "Failed to extract section polygon for element $elem_idx" exception=e
            end
        end

        # Extract interpolated deflected curve points (cubic interpolation)
        original_points = Vector{Float64}[]
        displacement_vectors = Vector{Float64}[]

        if haskey(edisp_map, elem_idx)
            edisp = edisp_map[elem_idx]
            n_pts = size(edisp.uglobal, 2)
            # basepositions and uglobal are Matrix{Float64} in meters (no Unitful)

            for j in 1:n_pts
                orig_pos_m = edisp.basepositions[:, j]
                orig_pos = _to_display_length.(Ref(du), orig_pos_m)
                push!(original_points, [_round_val(p; digits=6) for p in orig_pos])

                disp_m = edisp.uglobal[:, j]
                disp_vec = _to_display_length.(Ref(du), disp_m)
                push!(displacement_vectors, [_round_val(d; digits=6) for d in disp_vec])
            end
        end
        
        push!(elements, APIVisualizationFrameElement(
            element_id = elem_idx,
            node_start = node_start_id,
            node_end = node_end_id,
            element_type = string(elem_type),
            utilization_ratio = _round_val(ratio),
            ok = ok,
            section_name = sec_name,
            section_type = section_type,
            section_depth_ft = depth_ft,
            section_width_ft = width_ft,
            flange_width_ft = flange_width_ft,
            web_thickness_ft = web_thickness_ft,
            flange_thickness_ft = flange_thickness_ft,
            section_polygon = section_poly,
            original_points = original_points,
            displacement_vectors = displacement_vectors,
        ))
    end
    
    return elements
end

"""Extract section type string and key dimensions in display length units from a section object."""
function _extract_section_geometry(sec_obj, du::DisplayUnits)
    isnothing(sec_obj) && return ("", 0.0, 0.0, 0.0, 0.0, 0.0)

    geom = StructuralSizer.section_geometry(sec_obj)

    if geom isa StructuralSizer.IShape
        d_ft = _to_display_length(du, StructuralSizer.section_depth(sec_obj))
        bf_ft = _to_display_length(du, StructuralSizer.section_flange_width(sec_obj))
        tw_ft = _to_display_length(du, StructuralSizer.section_web_thickness(sec_obj))
        tf_ft = _to_display_length(du, StructuralSizer.section_flange_thickness(sec_obj))
        return ("W-shape", _round_val(d_ft; digits=4), _round_val(bf_ft; digits=4),
                _round_val(bf_ft; digits=4), _round_val(tw_ft; digits=4), _round_val(tf_ft; digits=4))
    elseif geom isa StructuralSizer.SolidRect
        d_ft = _to_display_length(du, StructuralSizer.section_depth(sec_obj))
        w_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))
        return ("rectangular", _round_val(d_ft; digits=4), _round_val(w_ft; digits=4), 0.0, 0.0, 0.0)
    elseif geom isa StructuralSizer.HollowRect
        d_ft = _to_display_length(du, StructuralSizer.section_depth(sec_obj))
        w_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))
        return ("HSS_rect", _round_val(d_ft; digits=4), _round_val(w_ft; digits=4), 0.0, 0.0, 0.0)
    elseif geom isa StructuralSizer.HollowRound
        d_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))  # diameter
        return ("HSS_round", _round_val(d_ft; digits=4), _round_val(d_ft; digits=4), 0.0, 0.0, 0.0)
    else
        d_ft = _to_display_length(du, StructuralSizer.section_depth(sec_obj))
        w_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))
        return ("other", _round_val(d_ft; digits=4), _round_val(w_ft; digits=4), 0.0, 0.0, 0.0)
    end
end

"""Serialize sized slab boundary polygons and utilization for 3D visualization."""
function _serialize_sized_slabs(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    sized_slabs = APISizedSlab[]
    skel = struc.skeleton

    for (slab_idx, slab) in enumerate(struc.slabs)
        isnothing(slab.result) && continue
        slab_result = get(design.slabs, slab_idx, nothing)
        isnothing(slab_result) && continue

        # Collect boundary vertices from all cells
        all_verts_2d = Set{NTuple{2, Float64}}()
        z_coord = 0.0

        for cell_idx in slab.cell_indices
            cell = struc.cells[cell_idx]
            v_indices = skel.face_vertex_indices[cell.face_idx]

            for vi in v_indices
                pt = skel.vertices[vi]
                c = Meshes.coords(pt)
                x = _to_display_length(du, c.x)
                y = _to_display_length(du, c.y)
                z_coord = _to_display_length(du, c.z)
                push!(all_verts_2d, (x, y))
            end
        end

        # Convert to boundary polygon (convex hull for multi-cell slabs)
        verts_2d = collect(all_verts_2d)
        hull_pts = _convex_hull_2d(verts_2d)

        # Convert to 3D vertices at z_top
        boundary_vertices = [[p[1], p[2], z_coord] for p in hull_pts]

        thickness_ft = _to_display_length(du, slab_result.thickness)
        z_top_ft = z_coord
        ratio = max(slab_result.deflection_ratio, slab_result.punching_max_ratio)
        ok = slab_result.deflection_ok && slab_result.punching_ok
        
        push!(sized_slabs, APISizedSlab(
            slab_id = slab_idx,
            boundary_vertices = [[_round_val(v; digits=6) for v in vert] for vert in boundary_vertices],
            thickness_ft = _round_val(thickness_ft; digits=4),
            z_top_ft = _round_val(z_top_ft; digits=6),
            utilization_ratio = _round_val(ratio),
            ok = ok,
        ))
    end
    
    return sized_slabs
end

"""Serialize shell-element meshes with global/local vertex displacements for deflected slab visualization."""
function _serialize_deflected_slab_meshes(design::BuildingDesign, model, du::DisplayUnits)
    deflected_meshes = APIDeflectedSlabMesh[]

    !Asap.has_shell_elements(model) && return deflected_meshes

    draped = compute_draped_displacements(design)
    total_disp = draped.total
    local_disp = draped.local_bending

    # Group shells by slab ID
    slab_shells = Dict{Symbol, Vector{Asap.ShellElement}}()
    for shell in model.shell_elements
        shells = get!(slab_shells, shell.id, Asap.ShellElement[])
        push!(shells, shell)
    end

    # Extract mesh data per slab
    for (slab_id_sym, shells) in slab_shells
        # Extract slab index from symbol (e.g., :slab_1 -> 1)
        slab_idx = try
            parse(Int, string(slab_id_sym)[6:end])  # Remove "slab_" prefix
        catch
            continue
        end

        slab_result = get(design.slabs, slab_idx, nothing)
        isnothing(slab_result) && continue

        # Collect all vertices and faces from shell elements
        # Each ShellTri3 is a triangle with 3 nodes
        vertices = Vector{Float64}[]
        vertex_displacements = Vector{Float64}[]  # global
        vertex_displacements_local = Vector{Float64}[]
        faces = Vector{Int}[]
        vertex_map = Dict{Asap.Node, Int}()

        for shell in shells
            # ShellTri3 has 3 nodes - extract triangle connectivity
            shell_nodes = shell.nodes  # Tuple of 3 nodes
            if length(shell_nodes) == 3
                # Map nodes to vertex indices
                tri_indices = Int[]
                for node in shell_nodes
                    if !haskey(vertex_map, node)
                        pos = _position_to_display_lengths(du, node.position)
                        push!(vertices, [_round_val(p; digits=6) for p in pos])

                        nid = objectid(node)
                        disp_global_m = get(total_disp, nid, Asap.to_displacement_vec(node.displacement)[1:3])
                        disp_local_m = get(local_disp, nid, disp_global_m)

                        disp_global_vec = _to_display_length.(Ref(du), disp_global_m)
                        disp_local_vec = _to_display_length.(Ref(du), disp_local_m)

                        push!(vertex_displacements, [_round_val(d; digits=6) for d in disp_global_vec])
                        push!(vertex_displacements_local, [_round_val(d; digits=6) for d in disp_local_vec])

                        vertex_map[node] = length(vertices)
                    end
                    push!(tri_indices, vertex_map[node])
                end
                # Add triangle face (1-based indices for JSON)
                push!(faces, tri_indices)
            end
        end

        thickness_ft = _to_display_length(du, slab_result.thickness)
        ratio = max(slab_result.deflection_ratio, slab_result.punching_max_ratio)
        ok = slab_result.deflection_ok && slab_result.punching_ok
        
        push!(deflected_meshes, APIDeflectedSlabMesh(
            slab_id = slab_idx,
            vertices = vertices,
            vertex_displacements = vertex_displacements,
            vertex_displacements_local = vertex_displacements_local,
            faces = faces,  # Triangle connectivity (1-based indices)
            thickness_ft = _round_val(thickness_ft; digits=4),
            utilization_ratio = _round_val(ratio),
            ok = ok,
        ))
    end
    
    return deflected_meshes
end

"""Serialize foundation blocks for visualization in sized/original modes."""
function _serialize_visualization_foundations(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    skel = struc.skeleton
    out = APIVisualizationFoundation[]

    for (fdn_idx, fdn) in enumerate(struc.foundations)
        fdn_result = get(design.foundations, fdn_idx, nothing)
        isnothing(fdn_result) && continue
        isempty(fdn.support_indices) && continue

        xs = Float64[]
        ys = Float64[]
        zs = Float64[]
        for sup_idx in fdn.support_indices
            sup_idx > length(struc.supports) && continue
            v_idx = struc.supports[sup_idx].vertex_idx
            v_idx > length(skel.vertices) && continue
            c = Meshes.coords(skel.vertices[v_idx])
            push!(xs, _to_display_length(du, c.x))
            push!(ys, _to_display_length(du, c.y))
            push!(zs, _to_display_length(du, c.z))
        end
        isempty(xs) && continue

        cx = sum(xs) / length(xs)
        cy = sum(ys) / length(ys)
        z_top = minimum(zs)

        push!(out, APIVisualizationFoundation(
            foundation_id = fdn_idx,
            center_ft = [_round_val(cx; digits=6), _round_val(cy; digits=6), _round_val(z_top; digits=6)],
            length_ft = _round_val(_to_display_length(du, fdn_result.length); digits=4),
            width_ft = _round_val(_to_display_length(du, fdn_result.width); digits=4),
            depth_ft = _round_val(_to_display_length(du, fdn_result.depth); digits=4),
            utilization_ratio = _round_val(fdn_result.bearing_ratio),
            ok = fdn_result.ok,
        ))
    end

    return out
end

"""Compute average frame element length in display units for displacement scale calibration."""
function _compute_avg_element_length(model, du::DisplayUnits)
    isempty(model.elements) && return 1.0
    total_length = sum(_to_display_length(du, elem.length) for elem in model.elements)
    return total_length / length(model.elements)
end

"""Compute the 2D convex hull of `points` via Graham scan."""
function _convex_hull_2d(points::Vector{NTuple{2, Float64}})
    length(points) <= 3 && return points
    
    # Sort by x, then y
    sorted = sort(points)
    
    # Lower hull
    lower = NTuple{2, Float64}[]
    for p in sorted
        while length(lower) >= 2 && _cross_product(lower[end-1], lower[end], p) <= 0
            pop!(lower)
        end
        push!(lower, p)
    end
    
    # Upper hull
    upper = NTuple{2, Float64}[]
    for p in reverse(sorted)
        while length(upper) >= 2 && _cross_product(upper[end-1], upper[end], p) <= 0
            pop!(upper)
        end
        push!(upper, p)
    end
    
    # Remove duplicates at ends
    pop!(lower)
    pop!(upper)
    
    return vcat(lower, upper)
end

"""2D cross product `(a - o) × (b - o)` for convex hull orientation tests."""
function _cross_product(o::NTuple{2, Float64}, a::NTuple{2, Float64}, b::NTuple{2, Float64})
    return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
end
