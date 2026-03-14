# =============================================================================
# Wood–Armer Transformation — Per-Element Design Moments
# =============================================================================
#
# Transforms the bending moment tensor (Mxx, Myy, Mxy) at each element into
# design moments for top and bottom reinforcement in the x and y directions.
#
# This is the standard approach for shell FEA design per:
#   Wood, R.H. (1968). "The reinforcement of slabs in accordance with a
#   pre-determined field of moments." Concrete, 2(2), 69-76.
#
# The transformation accounts for the twisting moment Mxy by combining it
# with the bending moments so that the resulting uniaxial design moments
# are always safe (conservative) for any crack orientation.
#
# Sign convention (standard Wood–Armer, NOT Asap shell convention):
#   Mxx, Myy > 0 → sagging (tension on bottom face)
#   Mxx, Myy < 0 → hogging (tension on top face)
#
# ⚠ Asap shell elements use the OPPOSITE convention (positive = hogging).
#   Callers must NEGATE the Asap moments before passing to wood_armer().
#   See _extract_wood_armer_strip_moments for the correct workflow.
#
# Wood–Armer rules (per Wood 1968, Eq. 10-13):
#   Bottom reinforcement (sagging):
#     Mx* = Mxx + |Mxy|,  My* = Myy + |Mxy|
#     If Mx* < 0: Mx* = 0,  My* = Myy + Mxy²/Mxx
#     If My* < 0: My* = 0,  Mx* = Mxx + Mxy²/Myy
#     If both < 0: Mx* = My* = 0 (no bottom steel needed)
#
#   Top reinforcement (hogging):
#     Mx* = Mxx - |Mxy|,  My* = Myy - |Mxy|
#     If Mx* > 0: Mx* = 0,  My* = Myy - Mxy²/Mxx
#     If My* > 0: My* = 0,  Mx* = Mxx - Mxy²/Myy
#     If both > 0: Mx* = My* = 0 (no top steel needed)
#
# =============================================================================

"""
    WoodArmerResult

Per-element Wood–Armer design moments.

# Fields
- `Mx_bot`, `My_bot`: Bottom (sagging) design moments in x, y (N·m/m). ≥ 0.
- `Mx_top`, `My_top`: Top (hogging) design moments in x, y (N·m/m). ≤ 0.
"""
struct WoodArmerResult
    Mx_bot::Float64
    My_bot::Float64
    Mx_top::Float64
    My_top::Float64
end

# =============================================================================
# Per-Element Transformation
# =============================================================================

"""
    wood_armer(Mxx, Myy, Mxy) -> WoodArmerResult

Apply the Wood–Armer transformation to a single element's moment tensor.

Arguments are moment intensities (N·m/m).  Returns `WoodArmerResult` with
non-negative bottom moments and non-positive top moments.
"""
function wood_armer(Mxx::Float64, Myy::Float64, Mxy::Float64)::WoodArmerResult
    absMxy = abs(Mxy)

    # ── Bottom reinforcement (sagging) ──
    Mx_b = Mxx + absMxy
    My_b = Myy + absMxy

    if Mx_b < 0 && My_b < 0
        Mx_b = 0.0
        My_b = 0.0
    elseif Mx_b < 0
        # Mxx is strongly hogging → no bottom x-steel, adjust y
        Mx_b = 0.0
        My_b = abs(Mxx) > 1e-12 ? Myy + Mxy^2 / Mxx : Myy + absMxy
        My_b = max(My_b, 0.0)
    elseif My_b < 0
        # Myy is strongly hogging → no bottom y-steel, adjust x
        My_b = 0.0
        Mx_b = abs(Myy) > 1e-12 ? Mxx + Mxy^2 / Myy : Mxx + absMxy
        Mx_b = max(Mx_b, 0.0)
    end

    # ── Top reinforcement (hogging) ──
    Mx_t = Mxx - absMxy
    My_t = Myy - absMxy

    if Mx_t > 0 && My_t > 0
        Mx_t = 0.0
        My_t = 0.0
    elseif Mx_t > 0
        # Mxx is strongly sagging → no top x-steel, adjust y
        Mx_t = 0.0
        My_t = abs(Mxx) > 1e-12 ? Myy - Mxy^2 / Mxx : Myy - absMxy
        My_t = min(My_t, 0.0)
    elseif My_t > 0
        # Myy is strongly sagging → no top y-steel, adjust x
        My_t = 0.0
        Mx_t = abs(Myy) > 1e-12 ? Mxx - Mxy^2 / Myy : Mxx - absMxy
        Mx_t = min(Mx_t, 0.0)
    end

    return WoodArmerResult(Mx_b, My_b, Mx_t, My_t)
end

# =============================================================================
# Strip Integration via Wood–Armer
# =============================================================================

"""
    _extract_wood_armer_strip_moments(cache, struc, slab, columns, span_axis;
                                       torsion_discount=nothing, verbose=false)
        -> NamedTuple

Extract design moments using the Wood–Armer per-element approach:
1. Rotate each element's local (Mxx, Myy, Mxy) to global coordinates
2. Rotate global moments to the **rebar frame** (primary + transverse axes)
3. (Optional) Apply ACI concrete torsion discount to reduce |Mxy|
4. Negate to convert Asap sign convention (positive = hogging) to the
   standard Wood–Armer convention (positive = sagging)
5. Apply Wood–Armer in the rebar frame → (Mx_bot, My_bot, Mx_top, My_top)
6. Use Mx_bot / Mx_top directly as the primary-rebar design moment
7. Area-weight average over each strip region (CS/MS) within a δ-band

Wood–Armer output is tied to the coordinate system of the input tensor:
Mx_bot is the design moment for reinforcement aligned with the x-axis of
that tensor.  By rotating into the rebar frame *before* applying Wood–Armer,
Mx_bot is the correct design moment for the primary rebar direction — no
further projection is needed.  (Projecting WA results with ax²/ay² is
invalid because WA outputs are scalar design moments, not tensor components.)

# Sign convention
Asap shell moments use positive = hogging (tension on top).  The standard
Wood–Armer formulation (Wood 1968) uses positive = sagging (tension on
bottom).  We negate the rotated tensor before passing to `wood_armer()` to
reconcile the two conventions.

# Torsion Discount
When `torsion_discount` is a NamedTuple with `(h_m, d_m, fc_Pa, λ)`, the
ACI concrete torsion capacity Mxy_c is subtracted from |Mxy| before the
Wood–Armer transformation.  See `_aci_concrete_torsion_capacity`.

# Returns
Same signature as `_extract_fea_strip_moments`.
"""
function _extract_wood_armer_strip_moments(
    cache::FEAModelCache,
    struc, slab, columns,
    span_axis::NTuple{2, Float64};
    rebar_axis::Union{Nothing, NTuple{2, Float64}} = nothing,
    torsion_discount::Union{Nothing, NamedTuple} = nothing,
    verbose::Bool = false,
)
    skel = struc.skeleton
    n_cols = length(columns)

    # Use rebar axis for δ-band orientation and strip classification when set
    cut_ax = !isnothing(rebar_axis) ? rebar_axis : span_axis
    ax, ay = cut_ax

    # Rebar frame axes for tensor rotation (primary + transverse)
    rebar_ax_prime = cut_ax                   # primary rebar direction
    rebar_ay_prime = (-cut_ax[2], cut_ax[1])  # perpendicular (90° CCW)

    col_by_vertex = Dict{Int, Int}(col.vertex_idx => i for (i, col) in enumerate(columns))
    cell_to_cols  = _build_cell_to_columns(columns)

    col_Mneg_cs = zeros(Float64, n_cols)
    col_Mneg_ms = zeros(Float64, n_cols)
    env_Mpos_cs = 0.0
    env_Mpos_ms = 0.0

    for ci in slab.cell_indices
        cell_cols = get(cell_to_cols, ci, eltype(columns)[])
        isempty(cell_cols) && continue

        geom = _cell_geometry_m(struc, ci; _cache=cache.cell_geometries)
        tri_idx = get(cache.cell_tri_indices, ci, Int[])

        # CS polygons — use directed tributaries when rebar_axis is set
        dp_hw = _drop_panel_half_widths_m(cache.drop_panel)
        neg_cs_polys = _build_cs_polygons_abs(geom.poly;
            span_axis=span_axis, rebar_axis=rebar_axis,
            drop_panel_half_widths=dp_hw)
        pos_cs_polys = _build_cs_polygons_abs(geom.poly;
            rebar_axis=rebar_axis,
            drop_panel_half_widths=dp_hw)

        # Apply Wood–Armer in the rebar frame for each element.
        #
        # Steps per element:
        # 1. Rotate element-local → global: M_g = R · M_l · Rᵀ, R = [ex ey].
        # 2. Rotate global → rebar frame: _rotate_moments_to_rebar.
        # 3. Negate: Asap positive = hogging, WA positive = sagging.
        # 4. Apply wood_armer() in the rebar frame.
        # 5. Use Mx_bot / Mx_top directly (primary rebar design moment).
        n_tri = length(tri_idx)
        Mn_bot = Vector{Float64}(undef, n_tri)  # sagging design moment (≥ 0)
        Mn_top = Vector{Float64}(undef, n_tri)  # hogging design moment (≤ 0)
        areas  = Vector{Float64}(undef, n_tri)

        for (j, k) in enumerate(tri_idx)
            ed = cache.element_data[k]
            ex1, ex2 = ed.ex
            ey1, ey2 = ed.ey

            # Rotate element-local moments to global frame:
            # M_global = R · M_local · Rᵀ  where R = [ex ey] (columns = local axes)
            Mxx_g = ed.Mxx * ex1^2 + ed.Myy * ey1^2 + 2 * ed.Mxy * ex1 * ey1
            Myy_g = ed.Mxx * ex2^2 + ed.Myy * ey2^2 + 2 * ed.Mxy * ex2 * ey2
            Mxy_g = ed.Mxx * ex1 * ex2 + ed.Myy * ey1 * ey2 + ed.Mxy * (ex1 * ey2 + ex2 * ey1)

            # Rotate global → rebar frame
            Mxx_r, Myy_r, Mxy_r = _rotate_moments_to_rebar(
                Mxx_g, Myy_g, Mxy_g, rebar_ax_prime, rebar_ay_prime)

            # Apply concrete torsion discount (reduce |Mxy| by concrete capacity)
            if !isnothing(torsion_discount)
                Mxy_c = _aci_concrete_torsion_capacity(
                    ed.Qxz, ed.Qyz,
                    torsion_discount.h_m, torsion_discount.d_m,
                    torsion_discount.fc_Pa, torsion_discount.λ)
                Mxy_r = _apply_torsion_discount(Mxy_r, Mxy_c)
            end

            # Negate to convert Asap convention (pos=hogging) → WA convention (pos=sagging)
            # Apply Wood–Armer in the rebar frame
            wa = wood_armer(-Mxx_r, -Myy_r, -Mxy_r)

            # Mx_bot/Mx_top are the primary-rebar design moments (no projection needed)
            Mn_bot[j] = wa.Mx_bot
            Mn_top[j] = wa.Mx_top
            areas[j]  = ed.area
        end

        # Classify elements into CS/MS
        neg_cs_mask = BitVector(undef, n_tri)
        pos_cs_mask = BitVector(undef, n_tri)
        for (j, k) in enumerate(tri_idx)
            ed = cache.element_data[k]
            neg_cs_mask[j] = _is_in_column_strip(ed.cx, ed.cy, neg_cs_polys)
            pos_cs_mask[j] = _is_in_column_strip(ed.cx, ed.cy, pos_cs_polys)
        end

        δ = _section_cut_bandwidth(cache, cell_cols)
        half_δ = δ / 2   # half-width of the band (matches _integrate_at_subset)

        # ── Column-face M⁻ (hogging, from Mn_top) ──
        for (_, col) in enumerate(cell_cols)
            px, py = _column_xy_m(skel, col)
            off = _column_face_offset_m(col, cut_ax)
            face_s = ax * (px + off * ax) + ay * (py + off * ay)

            Mneg_cs_sum = 0.0
            Mneg_ms_sum = 0.0

            for (j, k) in enumerate(tri_idx)
                ed = cache.element_data[k]
                elem_s = ax * ed.cx + ay * ed.cy
                abs(elem_s - face_s) > half_δ && continue

                # Hogging: Mn_top is ≤ 0; design moment magnitude is |Mn_top|
                M_hog = -Mn_top[j]  # ≥ 0
                if neg_cs_mask[j]
                    Mneg_cs_sum += M_hog * areas[j]
                else
                    Mneg_ms_sum += M_hog * areas[j]
                end
            end

            # Σ(Mₙ·A) has units (N·m/m)·m² = N·m·m.  Dividing by δ (m) → N·m.
            # This matches _integrate_at_subset exactly.
            Mneg_cs = Mneg_cs_sum / δ
            Mneg_ms = Mneg_ms_sum / δ

            idx = get(col_by_vertex, col.vertex_idx, nothing)
            idx === nothing && continue
            col_Mneg_cs[idx] = max(col_Mneg_cs[idx], Mneg_cs)
            col_Mneg_ms[idx] = max(col_Mneg_ms[idx], Mneg_ms)
        end

        # ── Midspan M⁺ (sagging, from Mn_bot) ──
        cx, cy = geom.centroid
        Mpos_cs_sum = 0.0
        Mpos_ms_sum = 0.0

        for (j, k) in enumerate(tri_idx)
            ed = cache.element_data[k]
            elem_s = ax * ed.cx + ay * ed.cy
            cent_s = ax * cx + ay * cy
            abs(elem_s - cent_s) > half_δ && continue

            M_sag = Mn_bot[j]  # ≥ 0
            if pos_cs_mask[j]
                Mpos_cs_sum += M_sag * areas[j]
            else
                Mpos_ms_sum += M_sag * areas[j]
            end
        end

        Mpos_cs = Mpos_cs_sum / δ
        Mpos_ms = Mpos_ms_sum / δ

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
        @debug "WOOD–ARMER STRIP MOMENTS" begin
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
