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
    deflected_meshes = design.params.visualization_detail == "minimal" ? APIDeflectedSlabMesh[] :
        _serialize_deflected_slab_meshes(design, struc, model, du, drop_panel_cache)
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

    # Global analytical maxima — single pass over frame elements and deflected meshes
    max_fa = 0.0; max_fm = 0.0; max_fv = 0.0
    for e in frame_elements
        a = abs(e.max_axial_force); a > max_fa && (max_fa = a)
        m = abs(e.max_moment);      m > max_fm && (max_fm = m)
        v = abs(e.max_shear);       v > max_fv && (max_fv = v)
    end

    max_sb = 0.0; max_sm = 0.0; max_ss = 0.0; max_sv = 0.0; max_sp = 0.0
    for dm in deflected_meshes
        if !isempty(dm.face_bending_moment)
            v = maximum(abs, dm.face_bending_moment); v > max_sb && (max_sb = v)
        end
        if !isempty(dm.face_membrane_force)
            v = maximum(abs, dm.face_membrane_force); v > max_sm && (max_sm = v)
        end
        if !isempty(dm.face_shear_force)
            v = maximum(dm.face_shear_force); v > max_ss && (max_ss = v)
        end
        if !isempty(dm.face_von_mises)
            v = maximum(dm.face_von_mises); v > max_sv && (max_sv = v)
        end
        if !isempty(dm.face_surface_stress)
            v = maximum(abs, dm.face_surface_stress); v > max_sp && (max_sp = v)
        end
    end

    len_label = du.units[:length] == u"ft" ? "ft" : "m"
    viz_units = APIVisualizationUnits(
        position = len_label,
        displacement = len_label,
        force = "N",
        moment = "N_m",
        distributed_moment = "N_m_per_m",
        distributed_force = "N_per_m",
        stress = "Pa",
    )

    return APIVisualization(
        nodes = nodes,
        frame_elements = frame_elements,
        sized_slabs = sized_slabs,
        deflected_slab_meshes = deflected_meshes,
        foundations = foundations,
        is_beamless_system = is_beamless_system,
        suggested_scale_factor = _round_val(suggested_scale),
        max_displacement = _round_val(max_disp; digits=6),
        max_frame_axial = _round_val(max_fa; digits=4),
        max_frame_moment = _round_val(max_fm; digits=4),
        max_frame_shear = _round_val(max_fv; digits=4),
        max_slab_bending = _round_val(max_sb; digits=4),
        max_slab_membrane = _round_val(max_sm; digits=4),
        max_slab_shear = _round_val(max_ss; digits=4),
        max_slab_von_mises = _round_val(max_sv; digits=4),
        max_slab_surface_stress = _round_val(max_sp; digits=4),
        units = viz_units,
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

    # Precompute meters→display-length scale factor (avoids per-value Unitful dispatch)
    _m_to_disp = ustrip(du.units[:length], 1.0u"m")
    
    # Build element → design result mapping
    element_ratios = Dict{Int, Float64}()
    element_ok = Dict{Int, Bool}()
    element_section = Dict{Int, String}()
    element_type = Dict{Int, Symbol}()
    element_section_obj = Dict{Int, StructuralSizer.AbstractSection}()
    element_material_color = Dict{Int, String}()
    element_orientation = Dict{Int, Float64}()
    # Skeleton edge index → design member id (matches API `columns[].id` / `beams[].id`).
    edge_to_column_id = Dict{Int, Int}()
    edge_to_beam_id = Dict{Int, Int}()

    # Finite ratios only. A failing member with no finite ratio still draws at 1.
    # Row F ratios live on `seismic_frame` and are included by the caller.
    function _member_display_ratio(ratios, ok::Bool)
        finite_ratios = filter(isfinite, ratios)
        ratio = isempty(finite_ratios) ? 0.0 : maximum(finite_ratios)
        return !ok && ratio < 1.0 ? 1.0 : ratio
    end

    # Material color cache: same material object → same hex string
    _mat_color_cache = Dict{UInt64, String}()
    _cached_mat_color(mat) = isnothing(mat) ? "" :
        get!(_mat_color_cache, objectid(mat)) do; _material_color_hex(mat); end
    
    for (col_idx, result) in design.columns
        col_idx > length(struc.columns) && continue
        col = struc.columns[col_idx]
        # An UNVERIFIED column (steel §E3/§E4 buckling capacity unavailable — see
        # `_populate_column_results!`) carries a `NaN` axial/interaction sentinel. A raw
        # `max(NaN, …) == NaN` would flow through `_round_val` → `nothing` (line ~612) and
        # then into the strict `utilization_ratio` field, throwing `convert(Float64, nothing)`
        # and crashing GET /result on the DEFAULT (`skip_visualization=false`) path. Exclude
        # NaN from the aggregate so it can never poison the max, then force a failing sentinel
        # (≥ 1.0) for a not-ok element so the element renders as failing/attention — never as
        # `0.0` (which would read as safe). Mirrors `_compute_design_summary!` / `_diagnose_column`.
        ratio = _member_display_ratio(
            (result.axial_ratio, result.interaction_ratio, result.shear_ratio,
             isnothing(result.punching) ? 0.0 : result.punching.ratio,
             _seismic_frame_ratio(result.seismic_frame)),
            result.ok)
        sec_obj = result.section_obj
        mat_obj = !isnothing(col.concrete) ? col.concrete :
                  (!isnothing(sec_obj) && hasproperty(sec_obj, :material) ? getproperty(sec_obj, :material) : nothing)
        mat_color = _cached_mat_color(mat_obj)
        for seg_idx in segment_indices(col)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_to_column_id[edge_idx] = col_idx
            element_ratios[edge_idx] = ratio
            element_ok[edge_idx] = result.ok
            element_section[edge_idx] = result.section_size
            element_type[edge_idx] = :column
            element_orientation[edge_idx] = col.θ
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
            !isempty(mat_color) && (element_material_color[edge_idx] = mat_color)
        end
    end
    
    for (beam_idx, result) in design.beams
        beam_idx > length(struc.beams) && continue
        beam = struc.beams[beam_idx]
        ratio = _member_display_ratio(
            (result.flexure_ratio, result.shear_ratio, result.governing_ratio,
             _seismic_frame_ratio(result.seismic_frame)),
            result.ok)
        sec_obj = result.section_obj
        mat_obj = !isnothing(sec_obj) && hasproperty(sec_obj, :material) ? getproperty(sec_obj, :material) : nothing
        mat_color = _cached_mat_color(mat_obj)
        for seg_idx in segment_indices(beam)
            seg_idx > length(struc.segments) && continue
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_to_beam_id[edge_idx] = beam_idx
            element_ratios[edge_idx] = ratio
            element_ok[edge_idx] = result.ok
            element_section[edge_idx] = result.section_size
            element_type[edge_idx] = :beam
            !isnothing(sec_obj) && (element_section_obj[edge_idx] = sec_obj)
            !isempty(mat_color) && (element_material_color[edge_idx] = mat_color)
        end
    end
    
    for (strut_idx, strut) in enumerate(struc.struts)
        sec_obj = section(strut)
        mat_obj = !isnothing(sec_obj) && hasproperty(sec_obj, :material) ? getproperty(sec_obj, :material) : nothing
        mat_color = _cached_mat_color(mat_obj)
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
    avg_len_unitful = model.nFrameElements > 0 ? sum(getproperty.(model.frame_elements, :length)) / model.nFrameElements : 1.0u"m"
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

    # Precomputed symbol→string for element types (avoids allocation per element)
    _type_str = Dict{Symbol, String}(:column => "column", :beam => "beam", :strut => "strut", :other => "other")

    # Serialize elements
    # Resolve element index → skeleton edge index mapping:
    # - design.asap_model: use stored frame_edge_indices (subset of edges)
    # - struc.asap_model: 1:1 with skeleton edges, elem_idx = edge_idx
    # - fallback: node-based lookup
    use_stored_mapping = !isnothing(design.asap_model) && design.asap_model === model &&
                         length(design.asap_model_frame_edge_indices) == length(model.frame_elements)
    use_elem_idx_1to1 = model === struc.asap_model &&
                       length(model.frame_elements) == length(skel.edge_indices)

    n_elems = length(model.frame_elements)
    elements = APIVisualizationFrameElement[]
    sizehint!(elements, n_elems)

    # Per-section caches: avoid recomputing geometry/polygon for elements sharing a section
    _sec_geom_cache = Dict{UInt64, Tuple{String, Float64, Float64, Float64, Float64, Float64}}()
    _sec_poly_cache = Dict{UInt64, Vector{Vector{Float64}}}()
    _sec_poly_inner_cache = Dict{UInt64, Vector{Vector{Float64}}}()
    _sec_rebar_cache = Dict{UInt64, Tuple{Vector{Vector{Float64}}, Float64}}()
    studs_by_element = stud_positions_by_element(struc)

    for (elem_idx, elem) in enumerate(model.frame_elements)
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
        orient_angle = src_edge_idx > 0 ? get(element_orientation, src_edge_idx, 0.0) : 0.0

        # Extract section geometry (cached by section identity)
        sec_obj = src_edge_idx > 0 ? get(element_section_obj, src_edge_idx, nothing) : nothing
        sec_key = isnothing(sec_obj) ? UInt64(0) : objectid(sec_obj)
        section_type, depth_ft, width_ft, flange_width_ft, web_thickness_ft, flange_thickness_ft =
            get!(_sec_geom_cache, sec_key) do
                _extract_section_geometry(sec_obj, du)
            end

        # Extract section polygon (cached by section identity)
        section_poly = get!(_sec_poly_cache, sec_key) do
            _serialize_section_polygon(sec_obj, du, elem_idx)
        end
        section_poly_inner = get!(_sec_poly_inner_cache, sec_key) do
            _serialize_section_polygon_inner(sec_obj, du, elem_idx)
        end
        rebar_pts, rebar_dia = get!(_sec_rebar_cache, sec_key) do
            _serialize_section_rebar(sec_obj, du)
        end
        stud_pts, stud_dia, stud_len = _serialize_element_studs(
            get(studs_by_element, elem.elementID, nothing), du)

        # Extract interpolated deflected curve points (cubic interpolation).
        # basepositions and uglobal are Matrix{Float64} in SI meters — avoid
        # per-element Unitful dispatch by using the precomputed scale factor.
        edisp_key = elem.elementID
        edisp_found = haskey(edisp_map, edisp_key)
        n_pts = edisp_found ? size(edisp_map[edisp_key].uglobal, 2) : 0

        original_points = Vector{Vector{Float64}}(undef, n_pts)
        displacement_vectors = Vector{Vector{Float64}}(undef, n_pts)

        if edisp_found
            edisp = edisp_map[edisp_key]
            bp = edisp.basepositions  # 3×n_pts Float64
            ug = edisp.uglobal        # 3×n_pts Float64
            for j in 1:n_pts
                original_points[j] = [_round_val(_m_to_disp * bp[k, j]; digits=6) for k in 1:3]
                displacement_vectors[j] = [_round_val(_m_to_disp * ug[k, j]; digits=6) for k in 1:3]
            end
        end
        
        # Analytical: max absolute internal forces along element
        max_P, max_M, max_V = _compute_frame_analytical(elem, model)

        # Sized mode mesh: build from section polygon when solid (no inner); hollow falls back to client sweep
        mesh_verts = Vector{Vector{Float64}}()
        mesh_fcs = Vector{Vector{Int}}()
        if isempty(section_poly_inner) && length(section_poly) >= 3
            p1 = _position_to_display_lengths(du, elem.nodeStart.position; node_id=node_start_id)
            p2 = _position_to_display_lengths(du, elem.nodeEnd.position; node_id=node_end_id)
            mesh_verts, mesh_fcs = _build_frame_element_mesh(section_poly, p1, p2, orient_angle)
        end

        # Expose design member ids for beams/columns so clients (inspectors, tools) match `columns`/`beams` arrays.
        client_element_id = if elem_type == :column && src_edge_idx > 0
            get(edge_to_column_id, src_edge_idx, edisp_key)
        elseif elem_type == :beam && src_edge_idx > 0
            get(edge_to_beam_id, src_edge_idx, edisp_key)
        else
            edisp_key
        end

        push!(elements, APIVisualizationFrameElement(
            element_id = client_element_id,
            node_start = node_start_id,
            node_end = node_end_id,
            element_type = get(_type_str, elem_type, string(elem_type)),
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
            orientation_angle = orient_angle,
            section_polygon = section_poly,
            section_polygon_inner = section_poly_inner,
            rebar_positions = rebar_pts,
            rebar_diameter = rebar_dia,
            stud_positions = stud_pts,
            stud_diameter = stud_dia,
            stud_length = stud_len,
            original_points = original_points,
            displacement_vectors = displacement_vectors,
            max_axial_force = _round_val(max_P; digits=4),
            max_moment = _round_val(max_M; digits=4),
            max_shear = _round_val(max_V; digits=4),
            mesh_vertices = mesh_verts,
            mesh_faces = mesh_fcs,
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
    best_val = v[1]
    best_abs = abs(best_val)
    @inbounds for i in 2:length(v)
        a = abs(v[i])
        if a > best_abs
            best_abs = a
            best_val = v[i]
        end
    end
    return best_val
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

"""
Width and depth axes of a frame element, or `nothing` when it has no length.

`y` is the section width axis and `z` the depth axis. `orient_angle` rotates
them about the member axis. This is the frame [`_build_frame_element_mesh`](@ref)
sweeps, so a drawing that moves the flange uses the same side as the solid.
"""
function _section_frame(p1::Vector{Float64}, p2::Vector{Float64}, orient_angle::Float64)
    (length(p1) < 3 || length(p2) < 3) && return nothing
    axis = [p2[i] - p1[i] for i in 1:3]
    len = sqrt(sum(abs2, axis))
    len < 1e-10 && return nothing
    axis = axis ./ len
    up = abs(axis[3]) < 0.9 ? [0.0, 0.0, 1.0] : [1.0, 0.0, 0.0]
    y_local = [up[2] * axis[3] - up[3] * axis[2],
               up[3] * axis[1] - up[1] * axis[3],
               up[1] * axis[2] - up[2] * axis[1]]
    n2 = sqrt(sum(abs2, y_local))
    n2 < 1e-10 && return nothing
    y_local = y_local ./ n2
    z_local = [axis[2] * y_local[3] - axis[3] * y_local[2],
               axis[3] * y_local[1] - axis[1] * y_local[3],
               axis[1] * y_local[2] - axis[2] * y_local[1]]
    n3 = sqrt(sum(abs2, z_local))
    n3 < 1e-10 && return nothing
    z_local = z_local ./ n3
    if abs(orient_angle) > 1e-9
        c, s = cos(orient_angle), sin(orient_angle)
        y_new = [c * y_local[i] - s * z_local[i] for i in 1:3]
        z_new = [s * y_local[i] + c * z_local[i] for i in 1:3]
        y_local, z_local = y_new, z_new
    end
    return (y = y_local, z = z_local)
end

"""Build extruded prism mesh from section polygon and path. Returns (vertices, faces) or empty on failure.
Solid sections only (no inner polygon). Vertices and faces use 1-based indexing."""
function _build_frame_element_mesh(
    section_poly::Vector{Vector{Float64}},
    p1::Vector{Float64},
    p2::Vector{Float64},
    orient_angle::Float64,
)
    (length(section_poly) < 3 || length(p1) < 3 || length(p2) < 3) && return (Vector{Vector{Float64}}(), Vector{Vector{Int}}())
    frame = _section_frame(p1, p2, orient_angle)
    frame === nothing && return (Vector{Vector{Float64}}(), Vector{Vector{Int}}())
    y_local, z_local = frame.y, frame.z

    # Transform [y,z] local to global: p + y*y_local + z*z_local
    to_global(pos, y, z) = [pos[i] + y * y_local[i] + z * z_local[i] for i in 1:3]

    n = length(section_poly)
    vertices = Vector{Float64}[]
    for (i, v) in enumerate(section_poly)
        y, z = length(v) >= 2 ? (v[1], v[2]) : (0.0, 0.0)
        push!(vertices, to_global(p1, y, z))
    end
    for (i, v) in enumerate(section_poly)
        y, z = length(v) >= 2 ? (v[1], v[2]) : (0.0, 0.0)
        push!(vertices, to_global(p2, y, z))
    end

    faces = Vector{Int}[]
    # Start cap: fan from vertex 1
    for i in 2:(n - 1)
        push!(faces, [1, i, i + 1])
    end
    # End cap: fan from vertex n+1, reversed winding
    for i in 2:(n - 1)
        push!(faces, [n + 1, n + i + 1, n + i])
    end
    # Lateral quads
    for i in 1:n
        i1 = i
        i2 = i == n ? 1 : i + 1
        push!(faces, [i1, i2, n + i2])
        push!(faces, [i1, n + i2, n + i1])
    end

    return (vertices, faces)
end

"""
`(positions, diameter, length)` for one element's studs.

`positions` are `[[s, y, z], ...]` in display length units. `s` is the
distance from the element's start. `y` and `z` are the shank base in the
section frame, `z` at the top of steel. The shank extends `length` in the
`+z` direction. Empty and zeros when `entry` is `nothing`.
"""
function _serialize_element_studs(entry, du::DisplayUnits)
    entry === nothing && return (Vector{Float64}[], 0.0, 0.0)
    pts = entry.pts
    isempty(pts) && return (Vector{Float64}[], 0.0, 0.0)
    z = _round_val(_to_display_length(du, entry.z_flange * u"m"); digits=6)
    out = Vector{Vector{Float64}}(undef, length(pts))
    for (i, (s, y)) in enumerate(pts)
        out[i] = [_round_val(_to_display_length(du, s * u"m"); digits=6),
                  _round_val(_to_display_length(du, y * u"m"); digits=6),
                  z]
    end
    dia = _round_val(_to_display_length(du, entry.d_sa); digits=6)
    len = _round_val(_to_display_length(du, entry.l_sa); digits=6)
    return (out, dia, len)
end

"""
    _serialize_section_rebar(sec_obj, du) -> (positions, diameter)

Longitudinal bar centres `[[y, z], ...]` and the equivalent-area bar diameter,
in display length units and the same centroid-origin frame as
`_serialize_section_polygon`. Empty and `0.0` for sections without rebar.
"""
function _serialize_section_rebar(sec_obj, du::DisplayUnits)
    empty = (Vector{Float64}[], 0.0)
    (isnothing(sec_obj) || !StructuralSizer.has_rebar(sec_obj)) && return empty
    pts = [[_round_val(_to_display_length(du, y); digits=6),
            _round_val(_to_display_length(du, z); digits=6)]
           for (y, z) in StructuralSizer.section_rebar_positions(sec_obj)]
    dia = _round_val(_to_display_length(du, 2 * StructuralSizer.section_rebar_radius(sec_obj)); digits=6)
    return (pts, dia)
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

