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
_thickness_unit_string(du::DisplayUnits) = du.units[:thickness] == u"inch" ? "in" : "mm"
_volume_unit_string(du::DisplayUnits) = du.units[:volume] == u"ft^3" ? "ft3" : "m3"
_mass_unit_string(du::DisplayUnits) = du.units[:mass] == u"lb" ? "lb" : "kg"

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
        thickness_unit = _thickness_unit_string(du),
        volume_unit = _volume_unit_string(du),
        mass_unit = _mass_unit_string(du),
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
            thickness = _round_val(t_display; digits=2),
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
            c1 = _round_val(c1_display; digits=1),
            c2 = _round_val(c2_display; digits=1),
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
            length = _round_val(_to_display_length(du, fr.length); digits=2),
            width = _round_val(_to_display_length(du, fr.width); digits=2),
            depth = _round_val(_to_display_length(du, fr.depth); digits=2),
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
        concrete_volume = _round_val(vol_display; digits=1),
        steel_weight = _round_val(steel_display; digits=0),
        rebar_weight = _round_val(rebar_display; digits=0),
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
    t_vis_start = time()
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

    # Extract nodes with displacements.
    # Structural offsets are already baked into the Asap model node positions
    # (applied in to_asap!) so no additional shifting is needed here.
    support_node_ids = Set{Int}()
    for sup in struc.supports
        1 <= sup.node_idx <= length(model.nodes) || continue
        push!(support_node_ids, sup.node_idx)
    end
    t0 = time()
    nodes = _serialize_visualization_nodes(model, du, support_node_ids)
    t_nodes = time() - t0

    t0 = time()
    frame_elements = _serialize_visualization_frame_elements(design, model, du)
    t_frames = time() - t0

    # Pre-compute drop panels once (used by both sized slabs and deflected meshes)
    drop_panel_cache = Dict{Int, Vector{APIDropPanelPatch}}()
    for (slab_idx, slab) in enumerate(struc.slabs)
        drop_panel_cache[slab_idx] = _serialize_drop_panel_patches(slab_idx, slab, struc, design, du)
    end

    t0 = time()
    sized_slabs = _serialize_sized_slabs(design, struc, du, drop_panel_cache)
    t_sized = time() - t0

    t0 = time()
    deflected_meshes = _serialize_deflected_slab_meshes(design, struc, model, du, drop_panel_cache)
    t_deflected = time() - t0

    t0 = time()
    foundations = _serialize_visualization_foundations(design, struc, du)
    t_found = time() - t0

    @info "serialize_visualization timing" nodes=round(t_nodes; digits=2) frames=round(t_frames; digits=2) sized_slabs=round(t_sized; digits=2) deflected_meshes=round(t_deflected; digits=2) foundations=round(t_found; digits=2) total=round(time() - t_vis_start; digits=2)

    # Compute suggested scale factor
    max_disp = isempty(nodes) ? 0.0 : maximum(norm(n.displacement) for n in nodes)
    avg_length = _compute_avg_element_length(model, du)
    suggested_scale = max_disp > 1e-12 ? (avg_length * 0.1) / max_disp : 1.0
    
    is_beamless_system = !isempty(struc.slabs) &&
                         all(slab -> slab.floor_type in (:flat_plate, :flat_slab), struc.slabs)

    # Global analytical maxima (max |value|) for diverging color normalization
    max_fa = isempty(frame_elements) ? 0.0 : maximum(abs(e.max_axial_force) for e in frame_elements)
    max_fm = isempty(frame_elements) ? 0.0 : maximum(abs(e.max_moment) for e in frame_elements)
    max_fv = isempty(frame_elements) ? 0.0 : maximum(abs(e.max_shear) for e in frame_elements)
    max_sb = isempty(deflected_meshes) ? 0.0 : maximum((isempty(m.face_bending_moment) ? 0.0 : maximum(abs, m.face_bending_moment) for m in deflected_meshes))
    max_sm = isempty(deflected_meshes) ? 0.0 : maximum((isempty(m.face_membrane_force) ? 0.0 : maximum(abs, m.face_membrane_force) for m in deflected_meshes))
    max_ss = isempty(deflected_meshes) ? 0.0 : maximum((isempty(m.face_shear_force) ? 0.0 : maximum(m.face_shear_force) for m in deflected_meshes))
    max_sv = isempty(deflected_meshes) ? 0.0 : maximum((isempty(m.face_von_mises) ? 0.0 : maximum(m.face_von_mises) for m in deflected_meshes))
    max_sp = isempty(deflected_meshes) ? 0.0 : maximum((isempty(m.face_surface_stress) ? 0.0 : maximum(abs, m.face_surface_stress) for m in deflected_meshes))

    return APIVisualization(
        nodes = nodes,
        frame_elements = frame_elements,
        sized_slabs = sized_slabs,
        deflected_slab_meshes = deflected_meshes,
        foundations = foundations,
        is_beamless_system = is_beamless_system,
        suggested_scale_factor = _round_val(suggested_scale),
        max_displacement = _round_val(max_disp; digits=6),
        max_frame_axial = _round_val(max_fa; digits=2),
        max_frame_moment = _round_val(max_fm; digits=2),
        max_frame_shear = _round_val(max_fv; digits=2),
        max_slab_bending = _round_val(max_sb; digits=4),
        max_slab_membrane = _round_val(max_sm; digits=4),
        max_slab_shear = _round_val(max_ss; digits=4),
        max_slab_von_mises = _round_val(max_sv; digits=2),
        max_slab_surface_stress = _round_val(max_sp; digits=2),
    )
end

"""Serialize model nodes with positions and displacements for visualization.
Positions and displacements are forced to display length units (ft or m) so Grasshopper
always receives consistent numeric data.

Structural offsets are already applied in `to_asap!` — the model node positions
reflect the structural centerlines, so no additional shifting is needed here.
"""
function _serialize_visualization_nodes(model, du::DisplayUnits, support_node_ids::Set{Int}=Set{Int}())
    nodes = APIVisualizationNode[]
    sizehint!(nodes, length(model.nodes))
    for (i, node) in enumerate(model.nodes)
        pos = _position_to_display_lengths(du, node.position; node_id=i)
        disp_m = Asap.to_displacement_vec(node.displacement)[1:3]
        disp = _to_display_length.(Ref(du), disp_m)
        def_pos = pos .+ disp
        push!(nodes, APIVisualizationNode(
            node_id = i,
            position = [_round_val(p; digits=6) for p in pos],
            displacement = [_round_val(d; digits=9) for d in disp],
            deflected_position = [_round_val(p; digits=9) for p in def_pos],
            is_support = in(i, support_node_ids),
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
    element_material_color = Dict{Int, String}()
    
    # Map columns — read section from captured design result (survives restore!)
    for (col_idx, result) in design.columns
        col_idx > length(struc.columns) && continue
        col = struc.columns[col_idx]
        ratio = max(result.axial_ratio, result.interaction_ratio)
        sec_obj = result.section_obj
        mat_obj = !isnothing(col.concrete) ? col.concrete :
                  (!isnothing(sec_obj) && hasproperty(sec_obj, :material) ? getproperty(sec_obj, :material) : nothing)
        mat_color = _material_color_hex(mat_obj)
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            element_ratios[edge_idx] = ratio
            element_ok[edge_idx] = result.ok
            element_section[edge_idx] = result.section_size
            element_type[edge_idx] = :column
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
            !isempty(mat_color) && (element_material_color[edge_idx] = mat_color)
        end
    end
    
    # Map beams — read section from captured design result (survives restore!)
    for (beam_idx, result) in design.beams
        beam_idx > length(struc.beams) && continue
        beam = struc.beams[beam_idx]
        ratio = max(result.flexure_ratio, result.shear_ratio)
        sec_obj = result.section_obj
        mat_obj = !isnothing(sec_obj) && hasproperty(sec_obj, :material) ? getproperty(sec_obj, :material) : nothing
        mat_color = _material_color_hex(mat_obj)
        for seg_idx in segment_indices(beam)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            element_ratios[edge_idx] = ratio
            element_ok[edge_idx] = result.ok
            element_section[edge_idx] = result.section_size
            element_type[edge_idx] = :beam
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
            !isempty(mat_color) && (element_material_color[edge_idx] = mat_color)
        end
    end
    
    # Map struts
    for (strut_idx, strut) in enumerate(struc.struts)
        sec_obj = section(strut)
        mat_obj = !isnothing(sec_obj) && hasproperty(sec_obj, :material) ? getproperty(sec_obj, :material) : nothing
        mat_color = _material_color_hex(mat_obj)
        for seg_idx in segment_indices(strut)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            element_type[edge_idx] = :strut
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
            !isempty(mat_color) && (element_material_color[edge_idx] = mat_color)
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
    
    # Map analysis-model elements back to skeleton edge indices by node connectivity.
    # This is robust when analysis models include a subset/reordering of skeleton edges.
    edge_by_nodes = Dict{Tuple{Int, Int}, Int}()
    for (edge_idx, (v1, v2)) in enumerate(skel.edge_indices)
        key = v1 <= v2 ? (v1, v2) : (v2, v1)
        edge_by_nodes[key] = edge_idx
    end

    # Serialize elements
    # Resolve element index → skeleton edge index mapping:
    # - design.asap_model: use stored frame_edge_indices (subset of edges)
    # - struc.asap_model: 1:1 with skeleton edges, elem_idx = edge_idx
    # - fallback: node-based lookup
    use_stored_mapping = !isnothing(design.asap_model) && design.asap_model === model &&
                         length(design.asap_model_frame_edge_indices) == length(model.elements)
    use_elem_idx_1to1 = model === struc.asap_model &&
                       length(model.elements) == length(skel.edge_indices)

    n_elems = length(model.elements)
    elements = APIVisualizationFrameElement[]
    sizehint!(elements, n_elems)
    for (elem_idx, elem) in enumerate(model.elements)
        node_start_id = elem.nodeStart.nodeID
        node_end_id = elem.nodeEnd.nodeID

        src_edge_idx = if use_stored_mapping
            design.asap_model_frame_edge_indices[elem_idx]
        elseif use_elem_idx_1to1
            elem_idx
        else
            edge_key = node_start_id <= node_end_id ?
                (node_start_id, node_end_id) :
                (node_end_id, node_start_id)
            get(edge_by_nodes, edge_key, 0)
        end

        ratio = src_edge_idx > 0 ? get(element_ratios, src_edge_idx, 0.0) : 0.0
        ok = src_edge_idx > 0 ? get(element_ok, src_edge_idx, true) : true
        sec_name = src_edge_idx > 0 ? get(element_section, src_edge_idx, "") : ""
        elem_type = src_edge_idx > 0 ? get(element_type, src_edge_idx, :other) : :other
        mat_color_hex = src_edge_idx > 0 ? get(element_material_color, src_edge_idx, "") : ""
        
        # Extract section geometry
        sec_obj = src_edge_idx > 0 ? get(element_section_obj, src_edge_idx, nothing) : nothing
        section_type, depth_ft, width_ft, flange_width_ft, web_thickness_ft, flange_thickness_ft =
            _extract_section_geometry(sec_obj, du)

        # Extract section polygon (2D outline in local y-z coordinates)
        section_poly = _serialize_section_polygon(sec_obj, du, elem_idx)
        section_poly_inner = _serialize_section_polygon_inner(sec_obj, du, elem_idx)

        # Extract interpolated deflected curve points (cubic interpolation)
        original_points = Vector{Float64}[]
        displacement_vectors = Vector{Float64}[]

        edisp_key = elem.elementID
        if haskey(edisp_map, edisp_key)
            edisp = edisp_map[edisp_key]
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
        
        # Analytical: max absolute internal forces along element
        max_P, max_M, max_V = _compute_frame_analytical(elem, model)

        push!(elements, APIVisualizationFrameElement(
            element_id = edisp_key,
            node_start = node_start_id,
            node_end = node_end_id,
            element_type = string(elem_type),
            utilization_ratio = _round_val(ratio),
            ok = ok,
            section_name = sec_name,
            material_color_hex = mat_color_hex,
            section_type = section_type,
            section_depth = depth_ft,
            section_width = width_ft,
            flange_width = flange_width_ft,
            web_thickness = web_thickness_ft,
            flange_thickness = flange_thickness_ft,
            section_polygon = section_poly,
            section_polygon_inner = section_poly_inner,
            original_points = original_points,
            displacement_vectors = displacement_vectors,
            max_axial_force = _round_val(max_P; digits=2),
            max_moment = _round_val(max_M; digits=2),
            max_shear = _round_val(max_V; digits=2),
        ))
    end
    
    return elements
end

"""Compute signed extremum of P, M, V along a frame element (value with largest |·|, sign preserved).
Falls back to end-forces when ElementInternalForces is unavailable."""
function _compute_frame_analytical(elem, model)
    try
        eif = Asap.ElementInternalForces(elem, model; resolution=10)
        ext_P = _vec_signed_extremum(eif.P)
        ext_My = _vec_signed_extremum(eif.My)
        ext_Mz = _vec_signed_extremum(eif.Mz)
        ext_Vy = _vec_signed_extremum(eif.Vy)
        ext_Vz = _vec_signed_extremum(eif.Vz)
        ext_M = _signed_extremum(ext_My, ext_Mz)
        ext_V = _signed_extremum(ext_Vy, ext_Vz)
        return (ext_P, ext_M, ext_V)
    catch
        P = Asap.axial_force(elem)
        return (P, 0.0, 0.0)
    end
end

"""Return the element of `v` with the largest absolute value, preserving sign."""
function _vec_signed_extremum(v::AbstractVector)
    isempty(v) && return 0.0
    idx = argmax(abs.(v))
    return v[idx]
end

"""Return a normalized hex color string from a material, or empty string if unavailable."""
function _material_color_hex(mat)
    isnothing(mat) && return ""

    # Use concrete display color for RC wrappers.
    if mat isa StructuralSizer.ReinforcedConcreteMaterial
        mat = mat.concrete
    end

    if !hasproperty(mat, :color)
        return ""
    end
    raw = getproperty(mat, :color)
    isnothing(raw) && return ""

    s = strip(String(raw))
    isempty(s) && return ""
    if startswith(s, "#")
        s = s[2:end]
    end

    # Accept RGB/RGBA hex, normalize to uppercase "#RRGGBB" or "#RRGGBBAA".
    if !occursin(r"^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$", s)
        return ""
    end
    return "#" * uppercase(s)
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
    elseif geom isa StructuralSizer.SolidRound
        d_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))
        return ("circular", _round_val(d_ft; digits=4), _round_val(d_ft; digits=4), 0.0, 0.0, 0.0)
    elseif geom isa StructuralSizer.HollowRect
        d_ft = _to_display_length(du, StructuralSizer.section_depth(sec_obj))
        w_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))
        return ("HSS_rect", _round_val(d_ft; digits=4), _round_val(w_ft; digits=4), 0.0, 0.0, 0.0)
    elseif geom isa StructuralSizer.HollowRound
        d_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))
        return ("HSS_round", _round_val(d_ft; digits=4), _round_val(d_ft; digits=4), 0.0, 0.0, 0.0)
    elseif geom isa StructuralSizer.TShape
        d_ft = _to_display_length(du, StructuralSizer.section_depth(sec_obj))
        w_ft = _to_display_length(du, StructuralSizer.flange_width(sec_obj))
        return ("T-beam", _round_val(d_ft; digits=4), _round_val(w_ft; digits=4), 0.0, 0.0, 0.0)
    elseif sec_obj isa StructuralSizer.PixelFrameSection
        d_ft = _to_display_length(du, StructuralSizer.section_depth(sec_obj))
        w_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))
        return ("pixelframe", _round_val(d_ft; digits=4), _round_val(w_ft; digits=4), 0.0, 0.0, 0.0)
    else
        d_ft = _to_display_length(du, StructuralSizer.section_depth(sec_obj))
        w_ft = _to_display_length(du, StructuralSizer.section_width(sec_obj))
        return ("other", _round_val(d_ft; digits=4), _round_val(w_ft; digits=4), 0.0, 0.0, 0.0)
    end
end

"""Serialize section polygon to display units. Uses StructuralSizer.section_polygon for all section types."""
function _serialize_section_polygon(sec_obj, du::DisplayUnits, elem_idx::Int)
    isnothing(sec_obj) && return Vector{Float64}[]

    try
        poly_local = StructuralSizer.section_polygon(sec_obj)
        section_poly = Vector{Float64}[]
        for (y, z) in poly_local
            y_disp = _to_display_length(du, y)
            z_disp = _to_display_length(du, z)
            push!(section_poly, [_round_val(y_disp; digits=6), _round_val(z_disp; digits=6)])
        end
        return section_poly
    catch e
        @debug "Failed to extract section polygon for element $elem_idx" exception=e
        return Vector{Float64}[]
    end
end

"""Serialize inner section polygon for hollow sections (HSS rect/round). Empty for solid sections."""
function _serialize_section_polygon_inner(sec_obj, du::DisplayUnits, elem_idx::Int)
    isnothing(sec_obj) && return Vector{Float64}[]

    try
        poly_local = StructuralSizer.section_polygon_inner(sec_obj)
        isempty(poly_local) && return Vector{Float64}[]
        section_poly = Vector{Float64}[]
        for (y, z) in poly_local
            y_disp = _to_display_length(du, y)
            z_disp = _to_display_length(du, z)
            push!(section_poly, [_round_val(y_disp; digits=6), _round_val(z_disp; digits=6)])
        end
        return section_poly
    catch e
        @debug "Failed to extract inner section polygon for element $elem_idx" exception=e
        return Vector{Float64}[]
    end
end

"""Serialize sized slab boundary polygons and utilization for 3D visualization."""
function _serialize_sized_slabs(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits,
                                drop_panel_cache::Dict{Int, Vector{APIDropPanelPatch}})
    sized_slabs = APISizedSlab[]
    sizehint!(sized_slabs, length(struc.slabs))
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
        drop_panels = get(drop_panel_cache, slab_idx, APIDropPanelPatch[])
        ratio = max(slab_result.deflection_ratio, slab_result.punching_max_ratio)
        ok = slab_result.deflection_ok && slab_result.punching_ok
        
        # Check for vault slab and serialize curved mesh
        is_vault = slab.result isa StructuralSizer.VaultResult
        vault_mesh_vertices = Vector{Float64}[]
        vault_mesh_faces = Vector{Int}[]
        
        if is_vault
            try
                vault_mesh = _serialize_vault_mesh(slab, struc, du)
                vault_mesh_vertices = vault_mesh.vertices
                vault_mesh_faces = vault_mesh.faces
            catch e
                @warn "Vault mesh serialization failed for slab $slab_idx — omitting curved mesh" exception=(e, catch_backtrace())
            end
        end
        
        push!(sized_slabs, APISizedSlab(
            slab_id = slab_idx,
            boundary_vertices = [[_round_val(v; digits=6) for v in vert] for vert in boundary_vertices],
            thickness = _round_val(thickness_ft; digits=4),
            z_top = _round_val(z_top_ft; digits=6),
            drop_panels = drop_panels,
            utilization_ratio = _round_val(ratio),
            ok = ok,
            is_vault = is_vault,
            vault_mesh_vertices = vault_mesh_vertices,
            vault_mesh_faces = vault_mesh_faces,
        ))
    end
    
    return sized_slabs
end

"""
Build parabolic vault mesh for visualization/serialization.

Uses Asap.get_vault_mesh_data() for Delaunay mesh projected onto parabolic surface.
Returns (vertices=..., faces=...) with vertices in display length units.
"""
function _serialize_vault_mesh(slab, struc::BuildingStructure, du::DisplayUnits;
                                target_edge_length::Float64=0.15)
    result = slab.result
    skel = struc.skeleton
    
    # Build corner nodes from face vertices
    cell_idx = slab.cell_indices[1]
    cell = struc.cells[cell_idx]
    v_indices = skel.face_vertex_indices[cell.face_idx]
    
    # Create temporary Asap nodes for get_vault_mesh_data
    corner_nodes = [let c = Meshes.coords(skel.vertices[vi])
        Asap.Node([c.x, c.y, c.z], :free)
    end for vi in v_indices]
    
    # Get vault mesh data from Asap (Delaunay projected onto parabola)
    span_axis = slab.spans.axis
    rise = result.rise
    
    mesh_data = Asap.get_vault_mesh_data(corner_nodes, span_axis, rise;
                                          target_edge_length=target_edge_length * u"m")
    
    # Convert vertices to display units
    vertices = Vector{Float64}[]
    for (x, y, z) in mesh_data.vertices
        x_disp = _to_display_length(du, x * u"m")
        y_disp = _to_display_length(du, y * u"m")
        z_disp = _to_display_length(du, z * u"m")
        
        push!(vertices, [_round_val(x_disp; digits=6), 
                         _round_val(y_disp; digits=6), 
                         _round_val(z_disp; digits=6)])
    end
    
    # Convert faces to vectors (JSON serialization)
    faces = [[f[1], f[2], f[3]] for f in mesh_data.faces]
    
    return (vertices=vertices, faces=faces)
end

"""Serialize shell-element meshes with global/local vertex displacements for deflected slab visualization."""
function _serialize_deflected_slab_meshes(design::BuildingDesign, struc::BuildingStructure, model, du::DisplayUnits,
                                          drop_panel_cache::Dict{Int, Vector{APIDropPanelPatch}})
    deflected_meshes = APIDeflectedSlabMesh[]

    !Asap.has_shell_elements(model) && return deflected_meshes

    draped = compute_draped_displacements(design)
    total_disp = draped.total
    local_disp = draped.local_bending

    sif_ws = Asap.ShellForcesWorkspace()

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
        slab_idx > length(struc.slabs) && continue
        slab = struc.slabs[slab_idx]

        # Collect all vertices and faces from shell elements
        # Each ShellTri3 is a triangle with 3 nodes
        n_shells = length(shells)
        n_verts_est = div(n_shells * 3, 2)  # ~shared vertices in triangle mesh

        vertices = Vector{Float64}[]
        vertex_displacements = Vector{Float64}[]
        vertex_displacements_local = Vector{Float64}[]
        faces = Vector{Int}[]
        sizehint!(vertices, n_verts_est)
        sizehint!(vertex_displacements, n_verts_est)
        sizehint!(vertex_displacements_local, n_verts_est)
        sizehint!(faces, n_shells)
        vertex_map = Dict{Asap.Node, Int}()
        sizehint!(vertex_map, n_verts_est)

        # Per-face analytical values (one entry per triangle, parallel to `faces`)
        face_bending = Float64[]
        face_membrane = Float64[]
        face_shear = Float64[]
        face_vm = Float64[]
        face_surf = Float64[]
        sizehint!(face_bending, n_shells)
        sizehint!(face_membrane, n_shells)
        sizehint!(face_shear, n_shells)
        sizehint!(face_vm, n_shells)
        sizehint!(face_surf, n_shells)

        for shell in shells
            shell_nodes = shell.nodes
            if length(shell_nodes) == 3
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
                push!(faces, tri_indices)

                # Compute shell internal forces for this triangle
                _append_shell_analytical!(face_bending, face_membrane, face_shear,
                                          face_vm, face_surf, shell, model.u, sif_ws)
            end
        end

        thickness_ft = _to_display_length(du, slab_result.thickness)
        drop_panels = get(drop_panel_cache, slab_idx, APIDropPanelPatch[])
        ratio = max(slab_result.deflection_ratio, slab_result.punching_max_ratio)
        ok = slab_result.deflection_ok && slab_result.punching_ok
        is_vault = slab.result isa StructuralSizer.VaultResult
        
        push!(deflected_meshes, APIDeflectedSlabMesh(
            slab_id = slab_idx,
            vertices = vertices,
            vertex_displacements = vertex_displacements,
            vertex_displacements_local = vertex_displacements_local,
            faces = faces,
            thickness = _round_val(thickness_ft; digits=4),
            drop_panels = drop_panels,
            utilization_ratio = _round_val(ratio),
            ok = ok,
            is_vault = is_vault,
            face_bending_moment = [_round_val(v; digits=4) for v in face_bending],
            face_membrane_force = [_round_val(v; digits=4) for v in face_membrane],
            face_shear_force = [_round_val(v; digits=4) for v in face_shear],
            face_von_mises = [_round_val(v; digits=2) for v in face_vm],
            face_surface_stress = [_round_val(v; digits=2) for v in face_surf],
        ))
    end
    
    return deflected_meshes
end

"""Compute per-face analytical scalars from ShellInternalForces and append to arrays.
Signed quantities preserve physical meaning (+ tension/sagging, − compression/hogging)."""
function _append_shell_analytical!(face_bending, face_membrane, face_shear,
                                    face_vm, face_surf, shell, u_global, sif_ws)
    sif = Asap.ShellInternalForces(shell, u_global, sif_ws)
    t = shell.thickness  # [m]

    # Signed dominant principal bending moment (+ sagging, − hogging)
    pm = Asap.principal_moments(sif)
    push!(face_bending, _signed_extremum(pm.M1, pm.M2))

    # Signed dominant principal membrane force (+ tension, − compression)
    pf = Asap.principal_forces(sif)
    push!(face_membrane, _signed_extremum(pf.N1, pf.N2))

    # Transverse shear resultant: √(Qxz² + Qyz²) — always ≥ 0
    push!(face_shear, sqrt(sif.Qxz^2 + sif.Qyz^2))

    # Von Mises at top (+t/2) and bottom (-t/2) surfaces — always ≥ 0
    vm_top = Asap.von_mises_stress(sif, t / 2, t)
    vm_bot = Asap.von_mises_stress(sif, -t / 2, t)
    push!(face_vm, max(vm_top, vm_bot))

    # Signed dominant principal stress at top/bottom (+ tension, − compression)
    surf = Asap.max_surface_stresses(sif, t)
    σ_top = _signed_principal_stress(surf.top.σxx, surf.top.σyy, surf.top.τxy)
    σ_bot = _signed_principal_stress(surf.bottom.σxx, surf.bottom.σyy, surf.bottom.τxy)
    push!(face_surf, _signed_extremum(σ_top, σ_bot))

    return nothing
end

"""Return the value with the largest absolute magnitude, preserving sign."""
_signed_extremum(a, b) = abs(a) >= abs(b) ? a : b

"""Signed dominant principal stress from a 2D stress state (σxx, σyy, τxy).
Returns the principal stress (σ1 or σ2) with the largest absolute value, keeping sign."""
function _signed_principal_stress(σxx, σyy, τxy)
    avg = (σxx + σyy) / 2
    R = sqrt(((σxx - σyy) / 2)^2 + τxy^2)
    σ1 = avg + R
    σ2 = avg - R
    return _signed_extremum(σ1, σ2)
end

"""Serialize foundation blocks for visualization in sized/original modes."""
function _serialize_visualization_foundations(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    skel = struc.skeleton
    out = APIVisualizationFoundation[]

    # Use offsets captured at design time (survives restore!)
    col_offset_by_vertex = design.structural_offsets

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
            off = get(col_offset_by_vertex, v_idx, nothing)
            push!(xs, _to_display_length(du, c.x + (isnothing(off) ? 0.0u"m" : off[1] * u"m")))
            push!(ys, _to_display_length(du, c.y + (isnothing(off) ? 0.0u"m" : off[2] * u"m")))
            push!(zs, _to_display_length(du, c.z))
        end
        isempty(xs) && continue

        cx = sum(xs) / length(xs)
        cy = sum(ys) / length(ys)
        z_top = minimum(zs)

        push!(out, APIVisualizationFoundation(
            foundation_id = fdn_idx,
            center = [_round_val(cx; digits=6), _round_val(cy; digits=6), _round_val(z_top; digits=6)],
            length = _round_val(_to_display_length(du, fdn_result.length); digits=4),
            width = _round_val(_to_display_length(du, fdn_result.width); digits=4),
            depth = _round_val(_to_display_length(du, fdn_result.depth); digits=4),
            utilization_ratio = _round_val(fdn_result.bearing_ratio),
            ok = fdn_result.ok,
        ))
    end

    return out
end

"""Serialize drop panel footprint patches for slab visualization."""
function _serialize_drop_panel_patches(slab_idx::Int, slab, struc::BuildingStructure, design::BuildingDesign, du::DisplayUnits)
    isnothing(slab.drop_panel) && return APIDropPanelPatch[]

    dp = slab.drop_panel
    h_drop_ft = _to_display_length(du, dp.h_drop)
    a1_full_ft = _to_display_length(du, 2 * dp.a_drop_1)
    a2_full_ft = _to_display_length(du, 2 * dp.a_drop_2)
    h_drop_ft <= 0 && return APIDropPanelPatch[]

    centers = Set{Int}()
    slab_cells = Set(slab.cell_indices)
    for (col_idx, col) in enumerate(struc.columns)
        if !isempty(intersect(col.tributary_cell_indices, slab_cells))
            push!(centers, col_idx)
        end
    end

    if isempty(centers)
        slab_result = get(design.slabs, slab_idx, nothing)
        if !isnothing(slab_result) && hasproperty(slab_result, :punching_check)
            pc = getproperty(slab_result, :punching_check)
            if hasproperty(pc, :details)
                for (col_idx, _) in getproperty(pc, :details)
                    if col_idx isa Integer && 1 <= col_idx <= length(struc.columns)
                        push!(centers, Int(col_idx))
                    end
                end
            end
        end
    end

    patches = APIDropPanelPatch[]
    for col_idx in centers
        col = struc.columns[col_idx]
        v_idx = col.vertex_idx
        (v_idx < 1 || v_idx > length(struc.skeleton.vertices)) && continue
        c = Meshes.coords(struc.skeleton.vertices[v_idx])
        off = get(design.structural_offsets, v_idx, (0.0, 0.0))
        cx = _to_display_length(du, c.x + off[1] * u"m")
        cy = _to_display_length(du, c.y + off[2] * u"m")
        cz = _to_display_length(du, c.z)

        push!(patches, APIDropPanelPatch(
            center = [_round_val(cx; digits=6), _round_val(cy; digits=6), _round_val(cz; digits=6)],
            length = _round_val(a1_full_ft; digits=4),
            width = _round_val(a2_full_ft; digits=4),
            extra_depth = _round_val(h_drop_ft; digits=4),
        ))
    end

    return patches
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
