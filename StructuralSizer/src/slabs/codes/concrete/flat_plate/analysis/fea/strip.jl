# =============================================================================
# Design Strip Integration — Direct CS/MS Moment Extraction
# =============================================================================
#
# Extracts column-strip and middle-strip design moments directly from the
# FEA shell model by classifying elements into strips using the skeleton's
# tributary polygons.
# =============================================================================

"""
    _extract_fea_strip_moments(cache, struc, slab, columns, span_axis) -> NamedTuple

Extract column-strip and middle-strip design moments directly from the
FEA shell model by classifying elements into strips using the skeleton's
tributary polygons.

**Geometry-agnostic approach**:
1. For each cell, compute `PanelStripGeometry` from the cell's face vertices
   via `get_tributary_polygons_isotropic` + `compute_panel_strips`.
2. Convert each `ColumnStripPolygon` to absolute (x, y) coordinates.
3. Classify each FEA triangle centroid as column-strip or middle-strip
   via point-in-polygon testing.
4. Integrate moments per strip using the δ-band approach.

For rectangular panels this reproduces ACI 8.4.1.5 (l₂/4 column strip).
For irregular panels it generalises via the straight skeleton.

Returns `(M_neg_ext_cs, M_neg_int_cs, M_pos_cs, M_neg_ext_ms, M_neg_int_ms, M_pos_ms)`
in N·m (bare Float64).
"""
function _extract_fea_strip_moments(
    cache::FEAModelCache,
    struc, slab, columns,
    span_axis::NTuple{2,Float64};
    rebar_axis::Union{Nothing, NTuple{2, Float64}} = nothing,
    include_torsion::Bool = true,
    verbose::Bool = false,
)
    skel = struc.skeleton
    n_cols = length(columns)

    col_by_vertex = Dict{Int, Int}(col.vertex_idx => i for (i, col) in enumerate(columns))
    cell_to_cols  = _build_cell_to_columns(columns)

    # Per-column CS/MS M⁻ accumulators
    col_Mneg_cs = zeros(Float64, n_cols)
    col_Mneg_ms = zeros(Float64, n_cols)
    env_Mpos_cs = 0.0
    env_Mpos_ms = 0.0

    for ci in slab.cell_indices
        cell_cols = get(cell_to_cols, ci, eltype(columns)[])
        isempty(cell_cols) && continue

        geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)

        tri_idx = get(cache.cell_tri_indices, ci, Int[])

        # Two CS polygon sets:
        #   neg_cs — transverse edges only (span-filtered).
        #   pos_cs — all edges.
        # When rebar_axis is set, use directed tributaries aligned to rebar.
        dp_hw = _drop_panel_half_widths_m(cache.drop_panel)
        neg_cs_polys = _build_cs_polygons_abs(geom.poly;
            span_axis=span_axis, rebar_axis=rebar_axis,
            drop_panel_half_widths=dp_hw)
        pos_cs_polys = _build_cs_polygons_abs(geom.poly;
            rebar_axis=rebar_axis,
            drop_panel_half_widths=dp_hw)

        neg_cs_tri, neg_ms_tri = _classify_triangles(cache.element_data, tri_idx, neg_cs_polys)
        pos_cs_tri, pos_ms_tri = _classify_triangles(cache.element_data, tri_idx, pos_cs_polys)

        δ = _section_cut_bandwidth(cache, cell_cols)

        if verbose
            @debug "Cell $ci: neg $(length(neg_cs_tri))/$(length(neg_ms_tri)) CS/MS, " *
                   "pos $(length(pos_cs_tri))/$(length(pos_ms_tri)) CS/MS, " *
                   "$(length(neg_cs_polys))/$(length(pos_cs_polys)) CS polys (neg/pos), " *
                   "δ=$(round(δ*1000, digits=0))mm"
        end

        # Column-strip and middle-strip M⁻ at each column face.
        for (_, col) in enumerate(cell_cols)
            px, py = _column_xy_m(skel, col)
            off = _column_face_offset_m(col, span_axis)
            face = (px + off * span_axis[1], py + off * span_axis[2])

            Mn_cs = max(0.0, _integrate_at_subset(
                cache.element_data, neg_cs_tri, face, span_axis, δ;
                include_torsion=include_torsion))
            Mn_ms = max(0.0, _integrate_at_subset(
                cache.element_data, neg_ms_tri, face, span_axis, δ;
                include_torsion=include_torsion))

            idx = get(col_by_vertex, col.vertex_idx, nothing)
            idx === nothing && continue
            col_Mneg_cs[idx] = max(col_Mneg_cs[idx], Mn_cs)
            col_Mneg_ms[idx] = max(col_Mneg_ms[idx], Mn_ms)
        end

        # Column-strip and middle-strip M⁺ at centroid.
        Mpos_cs = max(0.0, -_integrate_at_subset(
            cache.element_data, pos_cs_tri, geom.centroid, span_axis, δ;
            include_torsion=include_torsion))
        Mpos_ms = max(0.0, -_integrate_at_subset(
            cache.element_data, pos_ms_tri, geom.centroid, span_axis, δ;
            include_torsion=include_torsion))
        env_Mpos_cs = max(env_Mpos_cs, Mpos_cs)
        env_Mpos_ms = max(env_Mpos_ms, Mpos_ms)
    end

    # Envelope per-column into ext/int
    M_neg_ext_cs = 0.0; M_neg_int_cs = 0.0
    M_neg_ext_ms = 0.0; M_neg_int_ms = 0.0
    for (i, col) in enumerate(columns)
        if col.position == :interior
            col_Mneg_cs[i] > M_neg_int_cs && (M_neg_int_cs = col_Mneg_cs[i])
            col_Mneg_ms[i] > M_neg_int_ms && (M_neg_int_ms = col_Mneg_ms[i])
        else
            col_Mneg_cs[i] > M_neg_ext_cs && (M_neg_ext_cs = col_Mneg_cs[i])
            col_Mneg_ms[i] > M_neg_ext_ms && (M_neg_ext_ms = col_Mneg_ms[i])
        end
    end

    if verbose
        @debug "FEA STRIP INTEGRATION (geometry-agnostic)" begin
            "CS: ext⁻=$(round(M_neg_ext_cs, digits=0))  int⁻=$(round(M_neg_int_cs, digits=0))  " *
            "pos=$(round(env_Mpos_cs, digits=0)) N·m\n" *
            "MS: ext⁻=$(round(M_neg_ext_ms, digits=0))  int⁻=$(round(M_neg_int_ms, digits=0))  " *
            "pos=$(round(env_Mpos_ms, digits=0)) N·m"
        end
    end

    return (
        M_neg_ext_cs = M_neg_ext_cs,
        M_neg_int_cs = M_neg_int_cs,
        M_pos_cs     = env_Mpos_cs,
        M_neg_ext_ms = M_neg_ext_ms,
        M_neg_int_ms = M_neg_int_ms,
        M_pos_ms     = env_Mpos_ms,
    )
end
