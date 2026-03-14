# =============================================================================
# Moment Diagram — Multi-Cut Envelope Extraction
# =============================================================================
#
# Orchestrates the nodal-smoothed section-cut approach:
#   1. Build nodal moment field (once per solve)
#   2. For each cell, build an isoparametric panel
#   3. Generate N section cuts at uniform ξ spacing
#   4. Integrate Mₙ along each cut, split into CS/MS
#   5. Envelope: max M⁻ near columns, max M⁺ at midspan
#
# This produces the same output signature as `_extract_fea_strip_moments`
# (N·m bare Float64) so downstream reinforcement design is unchanged.
#
# =============================================================================

"""
    _extract_nodal_strip_moments(cache, struc, slab, columns, span_axis;
                                  n_cuts=40, n_pts=30, verbose=false)
        -> NamedTuple

Extract column-strip and middle-strip design moments using the nodal-smoothed
line-integral approach with multiple isoparametric section cuts.

# Algorithm
For each quad cell:
1. Build `IsoParametricPanel` from the 4 cell vertices, oriented so ξ runs
   along `span_axis`.
2. Generate `n_cuts` iso-ξ cut lines through the panel.
3. For each cut, integrate the smoothed Mₙ field, split into CS and MS
   contributions using the straight-skeleton strip polygons.
4. Envelope: max hogging moment near column faces → M⁻; max sagging at
   midspan → M⁺.

For non-quad cells, falls back to the δ-band approach.

# Returns
Same signature as `_extract_fea_strip_moments`:
`(M_neg_ext_cs, M_neg_int_cs, M_pos_cs, M_neg_ext_ms, M_neg_int_ms, M_pos_ms)`
in N·m (bare Float64).
"""
function _extract_nodal_strip_moments(
    cache::FEAModelCache,
    struc, slab, columns,
    span_axis::NTuple{2, Float64};
    rebar_axis::Union{Nothing, NTuple{2, Float64}} = nothing,
    n_cuts::Int = 40,
    n_pts::Int = 30,
    iso_alpha::Float64 = 1.0,
    include_torsion::Bool = true,
    sign_treatment::Symbol = :signed,
    verbose::Bool = false,
)
    skel = struc.skeleton
    n_cols = length(columns)

    # Build nodal moment field (once for the whole slab)
    # For :separate_faces, build two independent fields by sign
    use_separate = sign_treatment == :separate_faces
    if use_separate
        sep_fields = build_separate_face_fields(cache, span_axis)
        hog_field = sep_fields.hogging   # for M⁻ extraction (column faces)
        sag_field = sep_fields.sagging   # for M⁺ extraction (midspan)
    end
    # Always build the standard field (used as fallback and for :signed)
    field = build_nodal_moment_field(cache)

    col_by_vertex = Dict{Int, Int}(col.vertex_idx => i for (i, col) in enumerate(columns))
    cell_to_cols  = _build_cell_to_columns(columns)

    # Per-column CS/MS M⁻ accumulators
    col_Mneg_cs = zeros(Float64, n_cols)
    col_Mneg_ms = zeros(Float64, n_cols)
    env_Mpos_cs = 0.0
    env_Mpos_ms = 0.0

    n_cells_iso = 0   # cells handled by isoparametric cuts
    n_cells_fallback = 0

    for ci in slab.cell_indices
        cell_cols = get(cell_to_cols, ci, eltype(columns)[])
        isempty(cell_cols) && continue

        geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)
        tri_idx = get(cache.cell_tri_indices, ci, Int[])

        # Try parametric panel (quad → bilinear, convex N-gon → Wachspress)
        cp = build_cell_panel(geom.poly, cell_cols, span_axis, skel)

        if cp === nothing
            # Non-convex cell: fall back to δ-band approach
            n_cells_fallback += 1
            fb_Mpos_cs, fb_Mpos_ms = _fallback_cell!(
                col_Mneg_cs, col_Mneg_ms,
                cache, skel, ci, geom, cell_cols, columns,
                col_by_vertex, span_axis, verbose;
                rebar_axis=rebar_axis, include_torsion=include_torsion)
            env_Mpos_cs = max(env_Mpos_cs, fb_Mpos_cs)
            env_Mpos_ms = max(env_Mpos_ms, fb_Mpos_ms)
            continue
        end

        n_cells_iso += 1

        # Generate section cuts (column-band-aware classification)
        cuts = generate_cut_lines(cp, cell_cols, span_axis, skel;
                                  n_cuts=n_cuts, n_pts=n_pts, iso_alpha=iso_alpha)

        # CS polygons for strip classification — use directed tributaries when
        # rebar_axis is set (span-filtered for neg, all for pos)
        dp_hw = _drop_panel_half_widths_m(cache.drop_panel)
        neg_cs_polys = _build_cs_polygons_abs(geom.poly;
            span_axis=span_axis, rebar_axis=rebar_axis,
            drop_panel_half_widths=dp_hw)
        pos_cs_polys = _build_cs_polygons_abs(geom.poly;
            rebar_axis=rebar_axis,
            drop_panel_half_widths=dp_hw)

        # ── Column-face M⁻: average over column-band cuts ──
        # Each cut classified as :column_face is near one or more columns.
        # We attribute it to the *closest* column (by ξ distance) and average
        # across all such cuts for that column (to smooth out singularity peaks).
        # Accumulators: column index → (sum_cs, sum_ms, count)
        col_cut_sums = Dict{Int, NTuple{3, Float64}}()

        for cut in cuts
            cut.region == :column_face || continue

            _hog_field = use_separate ? hog_field : field
            M_cs, M_ms = integrate_cut_Mn_split(
                cache, _hog_field, cut, tri_idx, span_axis, neg_cs_polys;
                include_torsion=include_torsion)

            # Hogging = positive Mₙ at column face (Asap convention)
            Mneg_cs = max(0.0, M_cs)
            Mneg_ms = max(0.0, M_ms)

            # Attribute to the closest column
            best_j = 0
            best_dist = Inf
            for (j, _) in enumerate(cell_cols)
                d = abs(cut.ξ - cp.col_ξη[j][1])
                d < best_dist && (best_dist = d; best_j = j)
            end
            best_j == 0 && continue

            idx = get(col_by_vertex, cell_cols[best_j].vertex_idx, nothing)
            idx === nothing && continue

            prev = get(col_cut_sums, idx, (0.0, 0.0, 0.0))
            col_cut_sums[idx] = (prev[1] + Mneg_cs, prev[2] + Mneg_ms, prev[3] + 1.0)
        end

        # Average the column-band cuts for each column
        for (idx, (sum_cs, sum_ms, cnt)) in col_cut_sums
            cnt > 0 || continue
            col_Mneg_cs[idx] = max(col_Mneg_cs[idx], sum_cs / cnt)
            col_Mneg_ms[idx] = max(col_Mneg_ms[idx], sum_ms / cnt)
        end

        # ── Midspan M⁺: find the cut with maximum total sagging moment ──
        # We must use the SAME cut for both CS and MS to avoid inflating the
        # total by combining independent maxima from different cut positions.
        best_total = 0.0
        best_cs = 0.0
        best_ms = 0.0
        for cut in cuts
            cut.region == :midspan || continue

            _sag_field = use_separate ? sag_field : field
            M_cs, M_ms = integrate_cut_Mn_split(
                cache, _sag_field, cut, tri_idx, span_axis, pos_cs_polys;
                include_torsion=include_torsion)

            # Sagging = negative Mₙ at midspan (Asap convention: negative = sagging)
            Mpos_cs = max(0.0, -M_cs)
            Mpos_ms = max(0.0, -M_ms)
            total = Mpos_cs + Mpos_ms

            if total > best_total
                best_total = total
                best_cs = Mpos_cs
                best_ms = Mpos_ms
            end
        end
        env_Mpos_cs = max(env_Mpos_cs, best_cs)
        env_Mpos_ms = max(env_Mpos_ms, best_ms)
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
        @debug "NODAL STRIP INTEGRATION ($n_cells_iso iso, $n_cells_fallback fallback)" begin
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

# =============================================================================
# Fallback for Non-Quad Cells
# =============================================================================

"""
    _fallback_cell!(col_Mneg_cs, col_Mneg_ms, ...) -> (Mpos_cs, Mpos_ms)

Fallback for non-quad cells: uses the existing δ-band approach from fea.jl.
Mutates the negative-moment accumulator arrays in place and returns the
positive moments for the caller to envelope.
"""
function _fallback_cell!(
    col_Mneg_cs, col_Mneg_ms,
    cache, skel, ci, geom, cell_cols, columns, col_by_vertex,
    span_axis, verbose;
    rebar_axis::Union{Nothing, NTuple{2, Float64}} = nothing,
    include_torsion::Bool = true,
)
    tri_idx = get(cache.cell_tri_indices, ci, Int[])
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

    for (_, col) in enumerate(cell_cols)
        px, py = _column_xy_m(skel, col)
        off = _column_face_offset_m(col, span_axis)
        face = (px + off * span_axis[1], py + off * span_axis[2])

        Mn_cs = max(0.0, _integrate_at_subset(cache.element_data, neg_cs_tri, face, span_axis, δ;
            include_torsion=include_torsion))
        Mn_ms = max(0.0, _integrate_at_subset(cache.element_data, neg_ms_tri, face, span_axis, δ;
            include_torsion=include_torsion))

        idx = get(col_by_vertex, col.vertex_idx, nothing)
        idx === nothing && continue
        col_Mneg_cs[idx] = max(col_Mneg_cs[idx], Mn_cs)
        col_Mneg_ms[idx] = max(col_Mneg_ms[idx], Mn_ms)
    end

    Mpos_cs = max(0.0, -_integrate_at_subset(
        cache.element_data, pos_cs_tri, geom.centroid, span_axis, δ;
        include_torsion=include_torsion))
    Mpos_ms = max(0.0, -_integrate_at_subset(
        cache.element_data, pos_ms_tri, geom.centroid, span_axis, δ;
        include_torsion=include_torsion))

    return (Mpos_cs, Mpos_ms)
end

# =============================================================================
# Peak Nodal Envelope (FEA_pk) — DEPRECATED
# =============================================================================
# This method is deprecated in favor of the new knob-based dispatch system.
# It is retained only for backward compatibility with `strip_design=:peak_nodal`.
# The legacy mapping in types.jl already warns when this path is used.
# =============================================================================

"""
    _extract_peak_nodal_strip_moments(cache, struc, slab, columns, span_axis;
                                       verbose=false)
        -> NamedTuple

⚠ **DEPRECATED** — Use `FEA(design_approach=:strip, field_smoothing=:nodal)` instead.

Extract design moments using the peak nodal envelope approach:
for each strip region (CS/MS), find the peak Mₙ among all nodes in that
region and multiply by the strip width.

This is the most conservative approach — it takes the worst-case moment
intensity and assumes it applies uniformly across the strip width.

# Returns
Same signature as `_extract_fea_strip_moments`.
"""
function _extract_peak_nodal_strip_moments(
    cache::FEAModelCache,
    struc, slab, columns,
    span_axis::NTuple{2, Float64};
    verbose::Bool = false,
)
    skel = struc.skeleton
    n_cols = length(columns)

    field = build_nodal_moment_field(cache)
    col_by_vertex = Dict{Int, Int}(col.vertex_idx => i for (i, col) in enumerate(columns))
    cell_to_cols  = _build_cell_to_columns(columns)

    col_Mneg_cs = zeros(Float64, n_cols)
    col_Mneg_ms = zeros(Float64, n_cols)
    env_Mpos_cs = 0.0
    env_Mpos_ms = 0.0

    ax, ay = span_axis

    for ci in slab.cell_indices
        cell_cols = get(cell_to_cols, ci, eltype(columns)[])
        isempty(cell_cols) && continue

        geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)
        tri_idx = get(cache.cell_tri_indices, ci, Int[])

        # CS polygons (span-filtered for neg, all for pos)
        dp_hw = _drop_panel_half_widths_m(cache.drop_panel)
        neg_cs_polys = _build_cs_polygons_abs(geom.poly;
            span_axis=span_axis, drop_panel_half_widths=dp_hw)
        pos_cs_polys = _build_cs_polygons_abs(geom.poly;
            drop_panel_half_widths=dp_hw)

        # Collect all unique node IDs in this cell, classified by strip
        neg_cs_nodes = Set{Int}()
        neg_ms_nodes = Set{Int}()
        pos_cs_nodes = Set{Int}()
        pos_ms_nodes = Set{Int}()

        for k in tri_idx
            nids = field.tri_node_ids[k]
            for nid in nids
                (nid < 1 || nid > field.max_node_id) && continue
                px, py = field.node_x[nid], field.node_y[nid]

                # Negative (column face) classification
                if _is_in_column_strip(px, py, neg_cs_polys)
                    push!(neg_cs_nodes, nid)
                else
                    push!(neg_ms_nodes, nid)
                end

                # Positive (midspan) classification
                if _is_in_column_strip(px, py, pos_cs_polys)
                    push!(pos_cs_nodes, nid)
                else
                    push!(pos_ms_nodes, nid)
                end
            end
        end

        # ── Estimate strip widths for converting intensity → total moment ──
        # Use the transverse extent of the CS/MS polygons as strip width
        trans_axis = (-ay, ax)  # perpendicular to span

        # CS width: project CS polygon extents onto transverse axis
        cs_width = _estimate_strip_width(neg_cs_polys, trans_axis)
        # Total panel width
        panel_projections = [trans_axis[1] * v[1] + trans_axis[2] * v[2] for v in geom.poly]
        total_width = maximum(panel_projections) - minimum(panel_projections)
        ms_width = max(0.0, total_width - cs_width)

        # ── Column-face M⁻: peak Mₙ × strip width ──
        for (_, col) in enumerate(cell_cols)
            # Find nodes near column face (within 2 × column dimension)
            px_col, py_col = _column_xy_m(skel, col)
            off = _column_face_offset_m(col, span_axis)
            face_s = ax * (px_col + off * ax) + ay * (py_col + off * ay)

            # Column dimension for proximity filter
            c_max = max(ustrip(u"m", col.c1), ustrip(u"m", col.c2))
            prox = max(c_max, 0.3)  # at least 0.3m proximity window

            # Peak Mₙ among CS nodes near column face
            peak_cs = 0.0
            for nid in neg_cs_nodes
                nx, ny = field.node_x[nid], field.node_y[nid]
                node_s = ax * nx + ay * ny
                abs(node_s - face_s) > prox && continue
                Mn = field.node_Mxx[nid] * ax^2 + field.node_Myy[nid] * ay^2 +
                     2 * field.node_Mxy[nid] * ax * ay
                Mn > peak_cs && (peak_cs = Mn)
            end

            peak_ms = 0.0
            for nid in neg_ms_nodes
                nx, ny = field.node_x[nid], field.node_y[nid]
                node_s = ax * nx + ay * ny
                abs(node_s - face_s) > prox && continue
                Mn = field.node_Mxx[nid] * ax^2 + field.node_Myy[nid] * ay^2 +
                     2 * field.node_Mxy[nid] * ax * ay
                Mn > peak_ms && (peak_ms = Mn)
            end

            idx = get(col_by_vertex, col.vertex_idx, nothing)
            idx === nothing && continue
            Mneg_cs = peak_cs * cs_width
            Mneg_ms = peak_ms * ms_width
            col_Mneg_cs[idx] = max(col_Mneg_cs[idx], Mneg_cs)
            col_Mneg_ms[idx] = max(col_Mneg_ms[idx], Mneg_ms)
        end

        # ── Midspan M⁺: peak negative Mₙ × strip width ──
        peak_pos_cs = 0.0
        for nid in pos_cs_nodes
            Mn = field.node_Mxx[nid] * ax^2 + field.node_Myy[nid] * ay^2 +
                 2 * field.node_Mxy[nid] * ax * ay
            -Mn > peak_pos_cs && (peak_pos_cs = -Mn)
        end

        peak_pos_ms = 0.0
        for nid in pos_ms_nodes
            Mn = field.node_Mxx[nid] * ax^2 + field.node_Myy[nid] * ay^2 +
                 2 * field.node_Mxy[nid] * ax * ay
            -Mn > peak_pos_ms && (peak_pos_ms = -Mn)
        end

        env_Mpos_cs = max(env_Mpos_cs, peak_pos_cs * cs_width)
        env_Mpos_ms = max(env_Mpos_ms, peak_pos_ms * ms_width)
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
        @debug "PEAK NODAL STRIP MOMENTS" begin
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

# =============================================================================
# Helpers
# =============================================================================

"""
    _estimate_strip_width(cs_polys, trans_axis) -> Float64

Estimate the total column-strip width by projecting all CS polygon vertices
onto the transverse axis and taking the total extent.
"""
function _estimate_strip_width(
    cs_polys::Vector{Vector{NTuple{2, Float64}}},
    trans_axis::NTuple{2, Float64},
)::Float64
    isempty(cs_polys) && return 0.0

    t_min = Inf
    t_max = -Inf
    for poly in cs_polys
        for v in poly
            t = trans_axis[1] * v[1] + trans_axis[2] * v[2]
            t < t_min && (t_min = t)
            t > t_max && (t_max = t)
        end
    end

    return t_max > t_min ? t_max - t_min : 0.0
end
