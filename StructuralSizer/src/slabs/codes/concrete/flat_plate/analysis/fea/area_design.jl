# =============================================================================
# Area-Based Per-Element Design — Moment Extraction & Rebar Sizing
# =============================================================================
#
# Extracts design moments for each finite element individually, rather than
# integrating across strips.  This is the most general approach and works
# for arbitrary slab geometries.
#
# Two moment transformation options:
#   - :wood_armer — conservative envelope accounting for twisting moments
#   - :projection — tensor projection onto rebar axes (requires equilibrium check)
#
# The output is a vector of per-element design moments that can be used
# directly for reinforcement design at each element location.
#
# Per-element rebar sizing (`ElementRebarResult`) applies the Whitney stress
# block to each element's design moment, enforcing ACI minimum steel and
# producing a full-field reinforcement map.
#
# =============================================================================

"""
    AreaDesignMoment

Per-element design moment for area-based reinforcement design.

# Fields
- `elem_idx::Int`: Index into `cache.element_data`
- `cx::Float64`: Element centroid x (meters)
- `cy::Float64`: Element centroid y (meters)
- `area::Float64`: Element area (m²)
- `Mx_bot::Float64`: Bottom (sagging) design moment in x' direction (N·m/m, ≥ 0)
- `My_bot::Float64`: Bottom (sagging) design moment in y' direction (N·m/m, ≥ 0)
- `Mx_top::Float64`: Top (hogging) design moment in x' direction (N·m/m, ≤ 0)
- `My_top::Float64`: Top (hogging) design moment in y' direction (N·m/m, ≤ 0)

x' and y' are the reinforcement axes (from `_resolve_rebar_axes`).
"""
struct AreaDesignMoment
    elem_idx::Int
    cx::Float64
    cy::Float64
    area::Float64
    Mx_bot::Float64
    My_bot::Float64
    Mx_top::Float64
    My_top::Float64
end

"""
    _extract_area_design_moments(cache, method, span_axis; verbose=false)
        -> Vector{AreaDesignMoment}

Extract per-element design moments for area-based reinforcement design.

# Algorithm
For each element in `cache.element_data`:
1. Rotate element-local moments (Mxx, Myy, Mxy) to global frame.
2. Negate to convert Asap convention (positive = hogging) to standard
   (positive = sagging).
3. If `method.moment_transform == :wood_armer`:
   - Apply Wood–Armer transformation in the rebar coordinate system.
4. If `method.moment_transform == :no_torsion`:
   - Project onto rebar axes ignoring Mxy: Mn = Mxx·ax² + Myy·ay².
   - ⚠ Intentionally unconservative baseline — use only for comparison.
5. If `method.moment_transform == :projection`:
   - Project the moment tensor onto the rebar axes to get Mx', My'.
   - Use Mx' and My' directly (no twisting moment envelope).
   - ⚠ This can be unconservative if Mxy is significant.

# Returns
Vector of `AreaDesignMoment` for each element.
"""
function _extract_area_design_moments(
    cache::FEAModelCache,
    method::FEA,
    span_axis::NTuple{2, Float64};
    torsion_discount::Union{Nothing, NamedTuple} = nothing,
    verbose::Bool = false,
)
    # Resolve reinforcement axes
    rebar_ax, rebar_ay = _resolve_rebar_axes(method, span_axis)

    n_elem = length(cache.element_data)
    results = Vector{AreaDesignMoment}(undef, n_elem)

    for k in 1:n_elem
        ed = cache.element_data[k]
        ex1, ex2 = ed.ex
        ey1, ey2 = ed.ey

        # Step 1: Rotate element-local moments to global frame
        # M_global = R · M_local · Rᵀ  where R = [ex ey] (columns = local axes)
        Mxx_g = ed.Mxx * ex1^2 + ed.Myy * ey1^2 + 2 * ed.Mxy * ex1 * ey1
        Myy_g = ed.Mxx * ex2^2 + ed.Myy * ey2^2 + 2 * ed.Mxy * ex2 * ey2
        Mxy_g = ed.Mxx * ex1 * ex2 + ed.Myy * ey1 * ey2 + ed.Mxy * (ex1 * ey2 + ex2 * ey1)

        # Step 2: Negate to convert Asap convention (positive=hogging) → standard (positive=sagging)
        Mxx_s = -Mxx_g
        Myy_s = -Myy_g
        Mxy_s = -Mxy_g

        if method.moment_transform == :wood_armer
            # Step 3a: Rotate to rebar axes, then apply Wood–Armer
            Mxx_r, Myy_r, Mxy_r = _rotate_moments_to_rebar(
                Mxx_s, Myy_s, Mxy_s, rebar_ax, rebar_ay)

            # Apply concrete torsion discount (reduce |Mxy| by concrete capacity)
            if !isnothing(torsion_discount)
                Mxy_c = _aci_concrete_torsion_capacity(
                    ed.Qxz, ed.Qyz,
                    torsion_discount.h_m, torsion_discount.d_m,
                    torsion_discount.fc_Pa, torsion_discount.λ)
                Mxy_r = _apply_torsion_discount(Mxy_r, Mxy_c)
            end

            wa = wood_armer(Mxx_r, Myy_r, Mxy_r)
            results[k] = AreaDesignMoment(
                k, ed.cx, ed.cy, ed.area,
                wa.Mx_bot, wa.My_bot, wa.Mx_top, wa.My_top)
        elseif method.moment_transform == :no_torsion
            # Step 3b: No-torsion projection — drop Mxy entirely
            # Mn = Mxx·ax² + Myy·ay²  (intentionally unconservative baseline)
            Mx_proj = _project_moment_no_torsion(Mxx_s, Myy_s, rebar_ax)
            My_proj = _project_moment_no_torsion(Mxx_s, Myy_s, rebar_ay)

            Mx_bot = max(0.0, Mx_proj)
            My_bot = max(0.0, My_proj)
            Mx_top = min(0.0, Mx_proj)
            My_top = min(0.0, My_proj)

            results[k] = AreaDesignMoment(
                k, ed.cx, ed.cy, ed.area,
                Mx_bot, My_bot, Mx_top, My_top)
        else
            # Step 3c: Projection — project onto rebar axes (includes Mxy)
            # Mx' = Mxx·ax² + Myy·ay² + 2·Mxy·ax·ay  (for rebar_ax)
            Mx_proj = _project_moment_onto_axis(Mxx_s, Myy_s, Mxy_s, rebar_ax)
            My_proj = _project_moment_onto_axis(Mxx_s, Myy_s, Mxy_s, rebar_ay)

            # Split into bot (sagging, ≥ 0) and top (hogging, ≤ 0)
            Mx_bot = max(0.0, Mx_proj)
            My_bot = max(0.0, My_proj)
            Mx_top = min(0.0, Mx_proj)
            My_top = min(0.0, My_proj)

            results[k] = AreaDesignMoment(
                k, ed.cx, ed.cy, ed.area,
                Mx_bot, My_bot, Mx_top, My_top)
        end
    end

    if verbose
        # Summary statistics
        max_bot_x = maximum(r.Mx_bot for r in results)
        max_bot_y = maximum(r.My_bot for r in results)
        max_top_x = minimum(r.Mx_top for r in results)
        max_top_y = minimum(r.My_top for r in results)
        @debug "AREA-BASED DESIGN MOMENTS ($(n_elem) elements)" begin
            "transform=$(method.moment_transform)\n" *
            "Max sagging: Mx'=$(round(max_bot_x, digits=0))  My'=$(round(max_bot_y, digits=0)) N·m/m\n" *
            "Max hogging: Mx'=$(round(max_top_x, digits=0))  My'=$(round(max_top_y, digits=0)) N·m/m"
        end
    end

    return results
end

# =============================================================================
# Area Design → Strip-Compatible Output (Bridge to Existing Pipeline)
# =============================================================================

"""
    _area_to_strip_envelope(area_moments, cache, struc, slab, columns, span_axis)
        -> NamedTuple

Convert per-element area design moments to the strip-compatible output format
used by the existing pipeline.

This is a bridge function that allows area-based design to feed into the
existing reinforcement design pipeline by computing area-weighted averages
over column-strip and middle-strip regions.

The output matches the standard strip extraction signature:
  (M_neg_ext_cs, M_neg_int_cs, M_pos_cs,
   M_neg_ext_ms, M_neg_int_ms, M_pos_ms)
in N·m (bare Float64).

# Notes
- For true area-based design, downstream code should iterate over
  `AreaDesignMoment` elements directly and design reinforcement per-element.
- This bridge function is provided for comparison and validation against
  strip-based methods.
"""
function _area_to_strip_envelope(
    area_moments::Vector{AreaDesignMoment},
    cache::FEAModelCache,
    struc, slab, columns,
    span_axis::NTuple{2, Float64};
    rebar_axis::Union{Nothing, NTuple{2, Float64}} = nothing,
    verbose::Bool = false,
)
    skel = struc.skeleton
    n_cols = length(columns)

    # Use rebar axis for δ-band orientation and strip classification when set;
    # otherwise fall back to the span axis.
    cut_ax = !isnothing(rebar_axis) ? rebar_axis : span_axis
    ax, ay = cut_ax

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

        δ = _section_cut_bandwidth(cache, cell_cols)
        half_δ = δ / 2

        # ── Column-face M⁻ (hogging) ──
        for (_, col) in enumerate(cell_cols)
            px, py = _column_xy_m(skel, col)
            off = _column_face_offset_m(col, cut_ax)
            face_s = ax * (px + off * ax) + ay * (py + off * ay)

            Mneg_cs_sum = 0.0
            Mneg_ms_sum = 0.0

            for k in tri_idx
                k > length(area_moments) && continue
                am = area_moments[k]
                ed = cache.element_data[k]
                elem_s = ax * ed.cx + ay * ed.cy
                abs(elem_s - face_s) > half_δ && continue

                # Rebar-axis hogging: Mx_top is the moment about the primary
                # rebar axis (= span axis when rebar_direction is nothing).
                M_hog = -am.Mx_top  # Mx_top ≤ 0, so M_hog ≥ 0

                if _is_in_column_strip(ed.cx, ed.cy, neg_cs_polys)
                    Mneg_cs_sum += M_hog * ed.area
                else
                    Mneg_ms_sum += M_hog * ed.area
                end
            end

            idx = get(col_by_vertex, col.vertex_idx, nothing)
            idx === nothing && continue
            col_Mneg_cs[idx] = max(col_Mneg_cs[idx], Mneg_cs_sum / δ)
            col_Mneg_ms[idx] = max(col_Mneg_ms[idx], Mneg_ms_sum / δ)
        end

        # ── Midspan M⁺ (sagging) ──
        cx, cy = geom.centroid
        Mpos_cs_sum = 0.0
        Mpos_ms_sum = 0.0

        for k in tri_idx
            k > length(area_moments) && continue
            am = area_moments[k]
            ed = cache.element_data[k]
            elem_s = ax * ed.cx + ay * ed.cy
            cent_s = ax * cx + ay * cy
            abs(elem_s - cent_s) > half_δ && continue

            # Rebar-axis sagging: Mx_bot is the moment about the primary
            # rebar axis (= span axis when rebar_direction is nothing).
            M_sag = am.Mx_bot  # Mx_bot ≥ 0

            if _is_in_column_strip(ed.cx, ed.cy, pos_cs_polys)
                Mpos_cs_sum += M_sag * ed.area
            else
                Mpos_ms_sum += M_sag * ed.area
            end
        end

        env_Mpos_cs = max(env_Mpos_cs, Mpos_cs_sum / δ)
        env_Mpos_ms = max(env_Mpos_ms, Mpos_ms_sum / δ)
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
# Per-Element Reinforcement Sizing
# =============================================================================

"""
    ElementRebarResult

Per-element reinforcement design at a single finite element.

All steel areas are per unit width (m²/m) — multiply by the element's
tributary width to get total bar area if needed.

# Fields
- `elem_idx::Int`: Index into `cache.element_data`
- `cx::Float64`, `cy::Float64`: Element centroid (meters)
- `area::Float64`: Element area (m²)
- `Mu_x_bot::Float64`: Sagging design moment in x' direction (N·m/m, ≥ 0)
- `Mu_x_top::Float64`: Hogging design moment in x' direction (N·m/m, ≤ 0)
- `Mu_y_bot::Float64`: Sagging design moment in y' direction (N·m/m, ≥ 0)
- `Mu_y_top::Float64`: Hogging design moment in y' direction (N·m/m, ≤ 0)
- `As_x_bot::Float64`: Required bottom steel in x' (m²/m)
- `As_x_top::Float64`: Required top steel in x' (m²/m)
- `As_y_bot::Float64`: Required bottom steel in y' (m²/m)
- `As_y_top::Float64`: Required top steel in y' (m²/m)
- `As_min::Float64`: ACI minimum steel per unit width (m²/m)
- `section_adequate::Bool`: `false` if Whitney block solution is imaginary
"""
struct ElementRebarResult
    elem_idx::Int
    cx::Float64
    cy::Float64
    area::Float64
    # Design moments (N·m/m)
    Mu_x_bot::Float64
    Mu_x_top::Float64
    Mu_y_bot::Float64
    Mu_y_top::Float64
    # Required steel areas (m²/m)
    As_x_bot::Float64
    As_x_top::Float64
    As_y_bot::Float64
    As_y_top::Float64
    As_min::Float64
    section_adequate::Bool
end

"""
    _element_As(Mu_Nm_per_m, d, fc, fy) -> (As_m2_per_m, adequate)

Whitney stress block for a unit-width slab strip.

Inputs are bare SI: Mu in N·m/m, d in m, fc/fy in Pa.
Returns As in m²/m and whether the section is adequate.

Reference: ACI 318-11 §10.2.7
"""
function _element_As(Mu::Float64, d_m::Float64, fc_Pa::Float64, fy_Pa::Float64)
    Mu <= 0.0 && return (0.0, true)

    φ = 0.9  # tension-controlled (ACI 21.2.2)
    b = 1.0  # unit width (1 m)

    Rn = Mu / (φ * b * d_m^2)  # Pa

    β1_val = if fc_Pa <= 27.58e6       # ≤ 4000 psi
        0.85
    elseif fc_Pa >= 55.16e6            # ≥ 8000 psi
        0.65
    else
        0.85 - 0.05 * (fc_Pa - 27.58e6) / 6.895e6
    end

    term = 2.0 * Rn / (β1_val * fc_Pa)
    term > 1.0 && return (0.0, false)  # section inadequate

    ρ = (β1_val * fc_Pa / fy_Pa) * (1.0 - sqrt(1.0 - term))
    return (ρ * b * d_m, true)
end

"""
    _design_area_reinforcement(area_moments, h, d, fc, fy; verbose=false)
        -> Vector{ElementRebarResult}

Size reinforcement at every element from per-element design moments.

For each element in `area_moments`:
1. Compute As from the Whitney stress block for each face/direction
   (x'-bottom, x'-top, y'-bottom, y'-top).
2. Enforce ACI §7.12.2.1 minimum steel (ρ_min × h per unit width).
3. Return the governing As (max of required and minimum).

# Arguments
- `area_moments::Vector{AreaDesignMoment}`: Per-element design moments
- `h`, `d`: Slab thickness and effective depth (Unitful lengths)
- `fc`, `fy`: Concrete and steel strengths (Unitful pressures)

# Returns
`Vector{ElementRebarResult}` — one entry per element, same indexing as
`area_moments` and `cache.element_data`.
"""
function _design_area_reinforcement(
    area_moments::Vector{AreaDesignMoment},
    h::Length,
    d::Length,
    fc::Pressure,
    fy::Pressure;
    verbose::Bool = false,
)
    d_m   = ustrip(u"m", d)
    h_m   = ustrip(u"m", h)
    fc_Pa = ustrip(u"Pa", fc)
    fy_Pa = ustrip(u"Pa", fy)

    # ACI §7.12.2.1 minimum steel per unit width: ρ_min × 1 m × h
    fy_psi = round(Int, ustrip(u"psi", fy))
    ρ_min = if fy_psi < 60_000
        0.0020
    elseif fy_psi < 77_000
        0.0018
    else
        max(0.0014, 0.0018 * 60_000 / fy_psi)
    end
    As_min_per_m = ρ_min * 1.0 * h_m   # m²/m

    n = length(area_moments)
    results = Vector{ElementRebarResult}(undef, n)
    n_inadequate = 0

    @inbounds for k in 1:n
        am = area_moments[k]

        # Whitney block for each face/direction (moments already in N·m/m)
        As_xb, ok_xb = _element_As(am.Mx_bot, d_m, fc_Pa, fy_Pa)
        As_xt, ok_xt = _element_As(-am.Mx_top, d_m, fc_Pa, fy_Pa)  # Mx_top ≤ 0
        As_yb, ok_yb = _element_As(am.My_bot, d_m, fc_Pa, fy_Pa)
        As_yt, ok_yt = _element_As(-am.My_top, d_m, fc_Pa, fy_Pa)  # My_top ≤ 0

        ok = ok_xb & ok_xt & ok_yb & ok_yt
        !ok && (n_inadequate += 1)

        # Enforce minimum steel on each layer
        As_xb = max(As_xb, As_min_per_m)
        As_xt = max(As_xt, As_min_per_m)
        As_yb = max(As_yb, As_min_per_m)
        As_yt = max(As_yt, As_min_per_m)

        results[k] = ElementRebarResult(
            am.elem_idx, am.cx, am.cy, am.area,
            am.Mx_bot, am.Mx_top, am.My_bot, am.My_top,
            As_xb, As_xt, As_yb, As_yt,
            As_min_per_m, ok,
        )
    end

    if verbose
        max_xb = maximum(r.As_x_bot for r in results)
        max_xt = maximum(r.As_x_top for r in results)
        max_yb = maximum(r.As_y_bot for r in results)
        max_yt = maximum(r.As_y_top for r in results)
        @debug "PER-ELEMENT REBAR SIZING ($(n) elements)" begin
            "As_min=$(round(As_min_per_m * 1e6, digits=0)) mm²/m\n" *
            "Max As_x_bot=$(round(max_xb * 1e6, digits=0))  As_x_top=$(round(max_xt * 1e6, digits=0)) mm²/m\n" *
            "Max As_y_bot=$(round(max_yb * 1e6, digits=0))  As_y_top=$(round(max_yt * 1e6, digits=0)) mm²/m\n" *
            "Inadequate sections: $(n_inadequate)"
        end
    end

    return results
end

"""
    ElementRebarField

Full-field reinforcement map from per-element FEA design.

Wraps the per-element rebar results with section metadata so downstream
code (visualization, export, comparison) has everything in one object.

# Fields
- `elements::Vector{ElementRebarResult}`: Per-element rebar sizing
- `h::Float64`: Slab thickness (m)
- `d::Float64`: Effective depth (m)
- `fc::Float64`: f'c (Pa)
- `fy::Float64`: fy (Pa)
- `moment_transform::Symbol`: `:wood_armer`, `:projection`, or `:no_torsion`
- `section_adequate::Bool`: `true` if all elements are adequate
"""
struct ElementRebarField
    elements::Vector{ElementRebarResult}
    h::Float64    # m
    d::Float64    # m
    fc::Float64   # Pa
    fy::Float64   # Pa
    moment_transform::Symbol
    section_adequate::Bool
end

"""
    _build_element_rebar_field(area_moments, h, d, fc, fy, moment_transform;
                                verbose=false) -> ElementRebarField

Convenience wrapper: size rebar at every element and bundle into a field.
"""
function _build_element_rebar_field(
    area_moments::Vector{AreaDesignMoment},
    h::Length,
    d::Length,
    fc::Pressure,
    fy::Pressure,
    moment_transform::Symbol;
    verbose::Bool = false,
)
    elems = _design_area_reinforcement(area_moments, h, d, fc, fy; verbose=verbose)
    all_ok = all(r.section_adequate for r in elems)

    return ElementRebarField(
        elems,
        ustrip(u"m", h),
        ustrip(u"m", d),
        ustrip(u"Pa", fc),
        ustrip(u"Pa", fy),
        moment_transform,
        all_ok,
    )
end
