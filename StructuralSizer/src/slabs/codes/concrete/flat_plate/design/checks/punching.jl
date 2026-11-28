# =============================================================================
# Flat Plate Design Checks
# =============================================================================
#
# ACI 318 design checks for flat plate slabs:
# - Punching shear (§22.6)
# - Two-way deflection (§24.2)
# - One-way shear (§22.5)
# - Flexural adequacy / tension-controlled (§21.2.2)
#
# These wrap the pure ACI equations from calculations.jl with logging and
# result struct construction.
#
# Note: This file is included in StructuralSizer, inheriting Logging, etc.
# =============================================================================

# =============================================================================
# Punching Shear Check (geometry ACI 318-11 §11.11; vc ACI 318-19 Table 22.6.5.2)
# =============================================================================

"""
    check_punching_for_column(col, Vu, Mub, d, h, fc; kwargs...) -> NamedTuple

Check punching shear for a single column with combined stress method.

For exterior columns, adjusts Mub for reaction eccentricity:
    Mub_adjusted = |Mub| − Vu × e_centroid

where e_centroid is the distance from the column centerline to the critical
section centroid, `e = (b_section − cAB) − c_col/2`
(`eccentricity_to_critical_centroid`; ACI 318-11 R11.11.7.2, page 210).

# Arguments
- `col`: Column with position (:interior, :edge, :corner) and dimensions (c1, c2)
- `Vu`: Factored shear demand
- `Mub`: Unbalanced moment spanning along `span_axis`
- `d`: Effective slab depth
- `h`: Total slab thickness
- `fc`: Concrete compressive strength

# Keyword Arguments
- `verbose`: Enable debug logging
- `col_idx`: Column index for logging
- `λ`: Lightweight concrete factor (default: 1.0)
- `φ_shear`: Strength reduction factor (default: 0.75)
- `Muy`: Optional perpendicular-axis unbalanced moment
  (default `nothing` → 0).  ACI 318-11 §11.11.7.1 (corpus: aci-318-11,
  page 209) transfers γv Mu by eccentric shear at every slab-column
  connection.  Every position superposes both axes: `:corner` per PCA
  Case D, `:interior` on the 4-sided section, and `:edge` with the moment
  about the axis parallel to the free edge on the 3-sided Jc (R11.11.7.2,
  pages 209–211) plus the other about the symmetry axis
  ([`_edge_punching_stress`](@ref)). Which moment is which comes from the
  free-edge direction; without one, both assignments are checked.
- `span_axis`, `θ`: plan direction of `Mub` and the column rotation
  (default `col.θ`). Interior and corner moments are put on the column's
  `c1` / `c2` from these, so each meets the `b1`, `b2` and Jc of its own span.
- `free_edge_parallel`: `:c1` or `:c2`.  Default inferred from
  `col.boundary_edge_dirs` when present, otherwise `:c2`.
- `moment_transfer`: `(fy,)`, optionally with `(bar_diameter, cover)` for
  the inner-layer depth, to apply ACI 318-11 §13.5.3.3 (corpus: aci-318-11,
  page 250) on the closed-form rectangular section; `nothing` (default)
  keeps Eq. (13-1). The increase is permitted, not required, so it is used
  only at a column that fails with Eq. (13-1). See `_increased_transfer_stress`.
  Sections with openings, circular columns and skew or re-entrant corners
  keep Eq. (13-1).
- `centroid_dims`: `(c1, c2)` of the column whose centroid carries `Vu` and
  the moments, in the same named axes as `col`, when `col` is a larger
  support around it (a shear cap or capital footprint flush with the slab
  edge). Only the edge and corner centroid shift reads it. Default: `col`.

# Returns
Named tuple with `(ok, ratio, vu, φvc, b0, Jc, Mub, direction)`; the closed-form
path adds `moment_transfer`, the §13.5.3.3 fractions used or `nothing`.
`direction` is the unit plan vector from the section centroid toward the one
vertex where the signed eccentric stress peaks, or `nothing` when that vertex
is not unique or either axis moment stress is under 2% of `Vu/(b₀ d)`
(`moment_names_a_face`). `vu` still adds the absolute moment term.
"""
function check_punching_for_column(col, Vu, Mub, d, h, fc;
                                   verbose=false, col_idx=1, λ=1.0, φ_shear=0.75,
                                   Muy=nothing,
                                   free_edge_parallel::Union{Nothing, Symbol} = nothing,
                                   _geom_cache::Union{Nothing, Dict} = nothing,
                                   openings=nothing, column_xy=nothing,
                                   flat_slab::Bool = false,
                                   column_strip_half=nothing,
                                   column_strips=nothing,
                                   span_axis::NTuple{2, Float64} = (1.0, 0.0),
                                   θ::Union{Nothing, Real} = nothing,
                                   moment_transfer = nothing,
                                   centroid_dims = nothing)
    edge_par = something(free_edge_parallel, _infer_free_edge_parallel(col))
    c1 = col.c1
    c2 = col.c2
    col_shape_val = col_shape(col)
    
    # For circular edge/corner columns, use equivalent square dimensions
    # (circular critical section geometry only implemented for interior)
    use_circ = (col_shape_val == :circular && col.position == :interior)
    geom_shape = use_circ ? :circular : :rectangular
    
    # For edge/corner circular, convert to equivalent square for geometry
    if col_shape_val == :circular && col.position != :interior
        c_eq = equivalent_square_column(c1)
        c1 = c_eq
        c2 = c_eq
    end
    c1_ctr, c2_ctr = something(centroid_dims, (c1, c2))
    col.position == :edge && edge_par === :c1 && ((c1_ctr, c2_ctr) = (c2_ctr, c1_ctr))

    Muy_val = isnothing(Muy) ? zero(Mub) : Muy
    # Span-axis moments, before the edge check collapses them to one governing value.
    M_span = Mub
    M_perp = Muy_val
    swapped = false
    if col.position == :edge
        ori = _orient_edge_column(c1, c2, Mub, Muy_val; free_edge_parallel = edge_par)
        c1 = ori.c1
        c2 = ori.c2
        Mub = ori.M_edge
        Muy_val = zero(Muy_val)
        Muy = nothing
        swapped = edge_par == :c1
    end

    # ── Non-orthogonal / re-entrant corners → general-shape engine ──
    # These corners' critical sections are built by `corner_critical_section`,
    # which offsets the column by d/2 and clips the perimeter to the real slab
    # region defined by the two free edges (ACI 318-11 §11.11.1.2 — section at
    # d/2 wherever slab exists). The resisting (open) polyline is then evaluated
    # with the ACI 421.1R-99 Appendix B segment engine on its true principal
    # axes. This handles ANY free-edge angle, so both orthogonal AND skewed
    # re-entrant corners route here (the clipper reduces exactly to the
    # orthogonal section), and non-orthogonal convex (wedge) corners too.
    #
    # Orthogonal CONVEX corners keep the validated closed-form `punching_check`
    # path (below) — their eccentric-shear Jc is calibrated against spSlab — so
    # only *non-orthogonal* convex corners are diverted here.
    #
    # Routing requires the two free-edge inward normals (from the Synthesizer's
    # structural-offset pass). Columns lacking them (e.g. bare test stubs) fall
    # through to the conservative closed-form corner check.
    col_corner_kind  = hasproperty(col, :corner_kind)  ? getfield(col, :corner_kind)          : :none
    col_corner_angle = hasproperty(col, :corner_angle) ? Float64(getfield(col, :corner_angle)) : NaN
    inward_normals   = (hasproperty(col, :boundary_inward_normals) &&
                        length(getfield(col, :boundary_inward_normals)) == 2) ?
                       getfield(col, :boundary_inward_normals) : nothing
    is_reentrant     = col_corner_kind == :reentrant
    is_nonortho_cvx  = col_corner_kind == :convex && !isnan(col_corner_angle) &&
                       !isapprox(col_corner_angle, π / 2; atol = 0.12)
    route_general    = col.position == :corner && inward_normals !== nothing &&
                       (is_reentrant || is_nonortho_cvx)
    if verbose && col.position == :corner && (is_reentrant || is_nonortho_cvx) &&
       inward_normals === nothing
        @debug "Column $col_idx: $(col_corner_kind) corner lacks inward normals → conservative closed-form fallback"
    end
    # ACI 318-11 §11.11.6 (corpus: aci-318-11, page 209). The section is built
    # in plan axes: a rotated rectangle, a circular ring, or the clipped corner.
    # Openings are only translated to the column centre. The same tangent cut
    # applies to every one of those sections.
    col_θ = θ === nothing ? (hasproperty(col, :θ) ? Float64(getfield(col, :θ)) : 0.0) : Float64(θ)
    section_ang = col_θ + (swapped ? π / 2 : 0.0)
    has_openings = openings !== nothing && column_xy !== nothing && !isempty(openings)
    if route_general
        kind = is_reentrant ? :reentrant : :convex
        pts, closed = corner_critical_section(c1, c2, d, kind, inward_normals; θ = col_θ)
        if has_openings
            opened = punching_check_reduced(pts, closed, _column_rect_m(c1, c2, col_θ),
                                            openings, column_xy, h, fc, Vu, M_span, M_perp, d, c1, c2;
                                            flat_slab = flat_slab,
                                            column_strips = column_strips,
                                            column_strip_half = column_strip_half,
                                            span_axis = span_axis,
                                            αs = is_reentrant ? punching_αs(:interior) : punching_αs(:corner),
                                            shape = geom_shape, λ = λ, λs = size_effect_factor(d),
                                            ϕ = φ_shear, Mub_out = Mub)
            opened !== nothing && return opened
        end
    elseif has_openings
        pts, closed, reaction = column_plan_section(c1, c2, d, col.position, section_ang;
                                                    circular = use_circ)
        opened = punching_check_reduced(pts, closed, reaction, openings, column_xy,
                                        h, fc, Vu, M_span, M_perp, d, c1, c2;
                                        flat_slab = flat_slab,
                                        column_strips = column_strips,
                                        column_strip_half = column_strip_half,
                                        span_axis = span_axis,
                                        αs = punching_αs(col.position),
                                        shape = geom_shape, λ = λ, λs = size_effect_factor(d),
                                            ϕ = φ_shear, Mub_out = Mub)
        opened !== nothing && return opened
    end
    if route_general
        props = critical_section_properties(pts, d; closed = closed)

        # Transfer the applied unbalanced moments (taken about the column center)
        # to the critical-section centroidal axis, per ACI 318-11 R11.11.7.2
        # (corpus: aci-318-11, page 210): Vu and Mu are referenced to the
        # section centroid c-c, so the moment reduces by Vu·e where e is the
        # offset from the column centerline to the section centroid. Here e is
        # the TRUE general-section offset (props.xc, props.yc) — the exact
        # generalization of the closed-form `eccentricity_to_critical_centroid`
        # used on the validated orthogonal edge/corner path (which subtracts the
        # same Vu·e per axis, floored at 0; deci-8ec247a3).
        #
        # ⚠ TRANSFER SIGN (pinned) — the sign is a REDUCTION, not a guess: for an
        # exterior column the gravity-reaction eccentricity opposes the
        # unbalanced moment, so the centroidal-axis moment is |M| − Vu·e. This is
        # the convention worked in the PCA/ACI example (46.65 → 37.81 kip·ft, a
        # reduction; corpus: sp-de-two-way-flat-plate-aci318-14, page 42) and
        # already validated against spSlab for orthogonal edge/corner columns. A
        # re-entrant or skewed corner is the same class (section centroid shifts
        # toward the slab interior), so it inherits the identical reduction.
        #
        # ⚠ AXIS CONVENTION — the two engines name moments OPPOSITELY, so the
        # mapping is made explicit with physical names (see deci-6bee9104 / the
        # convention-lock test):
        #   • Sizer corner branch: `Mub` drives stress in x (pairs with x-ecc
        #     props.xc); `Muy_val` drives stress in y (pairs with y-ecc props.yc).
        #   • 421.1R `punching_check_general`: 1st moment arg is about x (stress
        #     in y), 2nd is about y (stress in x).
        # Plan components of the span-axis moments, then the centroid shift.
        # With span_axis = (1, 0) this is the previous mapping: M_perp stresses
        # y and M_span stresses x.
        Mux_plan, Muy_plan = plan_unbalanced_moments(M_span, M_perp, span_axis)
        M_about_x = _shift_moment(Mux_plan, Vu, props.yc)   # about x, stress in y
        M_about_y = _shift_moment(Muy_plan, Vu, props.xc)   # about y, stress in x

        β_g = punching_β(c1, c2; shape = geom_shape)
        # αs by resisting side count (ACI 421.3R-15 §4.8): the re-entrant section
        # is ~4-sided (interior αs); the convex wedge is 2-sided (corner αs).
        αs_g = is_reentrant ? punching_αs(:interior) : punching_αs(:corner)
        g = punching_check_general(Vu, M_about_x, M_about_y, d, fc, pts;
                                   closed = closed, β = β_g,
                                   αs = αs_g, λ = λ, λs = size_effect_factor(d), ϕ = φ_shear)
        if verbose
            status = g.ok ? "✓ PASS" : "✗ FAIL"
            @debug "Column $col_idx ($(kind) corner → general App. B)" c1=c1 c2=c2 b0=g.b0 β=round(β_g, digits=2) angle=round(col_corner_angle, digits=3)
            @debug "  Demand" Vu=Vu M_about_x=M_about_x M_about_y=M_about_y asymmetric=g.asymmetric θp=round(g.θp, digits=3)
            @debug "  Stress" vu=round(ustrip(u"psi", g.vu), digits=1) φvc=round(ustrip(u"psi", g.ϕvc), digits=1) ratio=round(g.utilization, digits=2) status=status
        end
        return (ok = g.ok, ratio = g.utilization, vu = g.vu, φvc = g.ϕvc,
                b0 = g.b0, Jc = g.J1, Mub = Mub, direction = g.direction)
    end

    # ── Geometry (cached: c1, c2, d, position, shape, edge_par) ──
    cache_key = !isnothing(_geom_cache) ?
        (ustrip(u"m", c1), ustrip(u"m", c2), ustrip(u"m", d), col.position, geom_shape, edge_par) :
        nothing

    cached = !isnothing(cache_key) ? get(_geom_cache, cache_key, nothing) : nothing

    if !isnothing(cached)
        geom = cached.geom
        Jc = cached.Jc
        γv_val = cached.γv
        cAB = cached.cAB
        αs = cached.αs
        β = cached.β
    else
        if col.position == :interior
            geom = punching_geometry_interior(c1, c2, d; shape=geom_shape)
            Jc = polar_moment_Jc_interior(geom.b1, geom.b2, d)
            γv_val = gamma_v(geom.b1, geom.b2)
            cAB = geom.cAB
        elseif col.position == :edge
            geom = punching_geometry_edge(c1, c2, d)
            Jc = polar_moment_Jc_edge(geom.b1, geom.b2, d, geom.cAB)
            γv_val = gamma_v(geom.b1, geom.b2)
            cAB = geom.cAB
        else  # :corner
            # Two-sided Jc from PCA EB712 Fig. 16-13 Case D (page 486),
            # same formulas as punching_check(; position=:corner).
            geom = punching_geometry_corner(c1, c2, d)
            cAB = geom.cAB_x
            Jc = polar_moment_Jc_corner(geom.b1, geom.b2, d, geom.cAB_x)
            γv_val = gamma_v(geom.b1, geom.b2)
        end

        c1_in = ustrip(u"inch", c1)
        c2_in = ustrip(u"inch", c2)
        β = col_shape_val == :circular ? 1.0 : max(c1_in, c2_in) / max(min(c1_in, c2_in), 1.0)
        αs = punching_αs(col.position)

        if !isnothing(cache_key)
            _geom_cache[cache_key] = (geom=geom, Jc=Jc, γv=γv_val, cAB=cAB, αs=αs, β=β)
        end
    end

    # ── Eccentricity correction (load-dependent — not cached) ──
    # ACI 318-11 §11.11.7.1 (corpus: aci-318-11, page 209) — remainder γv Mu
    # transferred by eccentricity of shear about the §11.11.1.2 centroid.
    # `geom.b1` and `Jc` belong to the moment spanning along `c1`. Interior
    # and corner moments are mapped onto `c1` / `c2` from the span direction.
    along = _span_along_c1(col_θ, span_axis)
    M_c1, M_c2 = along ? (Mub, Muy_val) : (Muy_val, Mub)

    if col.position == :interior
        Mub_adjusted = abs(M_c1)
        e_centroid = zero(c1)
    elseif col.position == :edge
        # ACI 318-11 R11.11.7.2 (pages 209–211): the moment about the axis
        # parallel to the free edge is shifted to the section centroid,
        # e = (b1 − cAB) − c1/2 (eccentricity_to_critical_centroid).
        e_centroid = eccentricity_to_critical_centroid(geom.b1, c1_ctr, cAB)
        stated = free_edge_parallel === nothing ? nothing :
                 along == (free_edge_parallel === :c2)
        edge_pairs = _edge_moment_pairs(col, M_span, M_perp, span_axis; stated)
        Mub_adjusted = maximum(max(0.0kip*u"ft", abs(p.M_par) - Vu * e_centroid)
                               for p in edge_pairs)
    else  # :corner — same centroid shift as punching_check (R11.11.7.2)
        e_centroid = eccentricity_to_critical_centroid(geom.b1, c1_ctr, geom.cAB_x)
        Mub_adjusted = max(0.0kip*u"ft", abs(M_c1) - Vu * e_centroid)
    end

    b0 = geom.b0
    vc = punching_capacity_stress(fc, β, αs, b0, d; λ=λ, λs=size_effect_factor(d))
    φvc = φ_shear * vc

    direction = nothing
    if col.position == :corner
        # Parity with punching_check: γv Mu c / Jc on each axis, each moment
        # shifted to the section centroid along its own span.
        e_y = eccentricity_to_critical_centroid(geom.b2, c2_ctr, geom.cAB_y)
        γv_y = gamma_v(geom.b2, geom.b1)
        Jc_y = polar_moment_Jc_corner(geom.b2, geom.b1, d, geom.cAB_y)
        vu = uconvert(u"psi", Vu / (b0 * d)) +
             shifted_moment_stress(γv_val, M_c1, Vu, e_centroid, geom.cAB_x, geom.b1 - geom.cAB_x, Jc) +
             shifted_moment_stress(γv_y, M_c2, Vu, e_y, geom.cAB_y, geom.b2 - geom.cAB_y, Jc_y)
        direction = _corner_peak_direction(c1, c2, d, geom, Vu, M_c1, M_c2,
                                           e_centroid, e_y, γv_val, γv_y, Jc, Jc_y, col_θ)
    elseif col.position == :interior
        # Superpose both axes to match punching_check(; position=:interior).
        # Jc_y / γv_y swap b1, b2.
        vu = uconvert(u"psi", combined_punching_stress(Vu, Mub_adjusted, b0, d, γv_val, Jc, cAB))
        if abs(ustrip(kip * u"ft", M_c2)) > 1e-10
            γv_y = gamma_v(geom.b2, geom.b1)
            Jc_y = polar_moment_Jc_interior(geom.b2, geom.b1, d)
            vu += uconvert(u"psi", γv_y * abs(M_c2) * (geom.b2 / 2) / Jc_y)
        end
        direction = geom_shape == :circular ? nothing :
            _interior_peak_direction(M_c1, M_c2, geom.b1, geom.b2, d, γv_val, Jc,
                                    col_θ, Vu, b0)
    else  # :edge
        pair_vu = [_edge_punching_stress(geom, Jc, γv_val, cAB, e_centroid, Vu, b0, d,
                                         p.M_par, p.M_oth) for p in edge_pairs]
        vu = maximum(pair_vu)
        direction = _edge_peak_direction(c1, c2, d, geom, Vu, edge_pairs, pair_vu,
                                         e_centroid, γv_val, Jc, col_θ, col, edge_par)
    end

    # §13.5.3.3 is permitted, not required: it is taken only at a column that
    # fails with Eq. (13-1), where it moves moment into flexural steel.
    transfer = nothing
    if moment_transfer !== nothing && col_shape_val != :circular && vu > φvc
        alt = _increased_transfer_stress(col, geom, Jc, cAB, Vu, M_span, M_perp,
                                         d, h, fc, φvc * b0 * d,
                                         edge_par, moment_transfer, span_axis, along)
        if alt !== nothing && alt.vu < vu
            vu = alt.vu
            transfer = alt.transfer
            # §13.5.3.3 moves moment into flexural steel. The face above is
            # the Eq. (13-1) face, and it is not reused after that reduction.
            direction = nothing
        end
    end

    ok = vu <= φvc
    ratio = ustrip(u"psi", vu) / ustrip(u"psi", φvc)
    
    if verbose
        status = ok ? "✓ PASS" : "✗ FAIL"
        @debug "Column $col_idx ($(col.position))" c1=c1 c2=c2 b0=b0 β=round(β, digits=2) αs=αs
        if col.position != :interior
            @debug "  Mub correction" Mub_original=Mub Mub_adjusted=Mub_adjusted e_centroid=e_centroid
        end
        @debug "  Demand" Vu=Vu γv=round(γv_val, digits=3) Mub=Mub_adjusted
        @debug "  Stress" vu=round(ustrip(u"psi", vu), digits=1) φvc=round(ustrip(u"psi", φvc), digits=1) ratio=round(ratio, digits=2) status=status moment_transfer=transfer
    end
    
    return (ok=ok, ratio=ratio, vu=vu, φvc=φvc, b0=b0, Jc=Jc, Mub=Mub,
            moment_transfer=transfer, direction=direction)
end

"""
    _increased_transfer_stress(col, geom, Jc, cAB, Vu, M_span, M_perp,
                               d, h, fc, φVc, edge_par, mt, span_axis, along)
        -> Union{Nothing, NamedTuple}

Column-face punching stress with the flexural fractions of ACI 318-11
§13.5.3.3 (corpus: aci-318-11, page 250), from `moment_transfer_gamma_f`.
Returns `(vu, transfer)`, where `transfer = (γf_x, γf_y, provision_x,
provision_y)` is in the named column axes (`γf_x` for the moment spanning
along `c1`), or `nothing` when no increase applies. That is the frame
`governing_transfer_reinforcement` sizes the steel in. The caller only asks
for it where Eq. (13-1) fails, and keeps the Eq. (13-1) stress unless this
one is lower.

`mt` is `(fy,)` and, when the secondary layer depth should gate the strain,
`(bar_diameter, cover)`. `span_axis` is the plan direction of `M_span`;
`along` is true when that direction is the column's `c1`. Widths come from
`transfer_bands`.

- Interior: (b) on each axis, the same superposition as the Eq. (13-1) check.
- Corner: (a) on each axis (0.5φVc), with the R11.11.7.2 centroid shift.
- Edge: (a) sets γv = 0 for the moment about the axis parallel to the edge
  (0.75φVc). The other moment is then checked on the 3-sided section about
  its symmetry axis, `polar_moment_Jc_edge_perpendicular`, with γf from (b)
  or Eq. (13-1). Which moment is parallel is found from the free-edge
  direction and `span_axis`; when the column has no edge direction, or the
  edge is skew to the span, (a) is not applied.
"""
function _increased_transfer_stress(col, geom, Jc, cAB, Vu, M_span, M_perp,
                                    d, h, fc, φVc, edge_par, mt, span_axis, along)
    fy = mt.fy
    d2 = _secondary_layer_depth(mt, h, d)
    v_direct = uconvert(u"psi", Vu / (geom.b0 * d))
    if col.position == :interior || col.position == :corner
        bands = transfer_bands(col.c1, col.c2, h, d; position = col.position)
        M_c1, M_c2 = along ? (M_span, M_perp) : (M_perp, M_span)
        d_c1, d_c2 = along ? (d, d2) : (d2, d)
        case = col.position == :interior ? :interior : :corner
        g_c1 = moment_transfer_gamma_f(bands.b1_x, bands.b2_x, case, Vu, φVc, M_c1,
                                       bands.bb_x, d_c1, fc, fy)
        g_c2 = moment_transfer_gamma_f(bands.b1_y, bands.b2_y, case, Vu, φVc, M_c2,
                                       bands.bb_y, d_c2, fc, fy)
        g_c1.provision === :eq_13_1 && g_c2.provision === :eq_13_1 && return nothing
        if col.position == :interior
            Jc_y = polar_moment_Jc_interior(geom.b2, geom.b1, d)
            vu = v_direct +
                 uconvert(u"psi", (1 - g_c1.γf) * abs(M_c1) * cAB / Jc) +
                 uconvert(u"psi", (1 - g_c2.γf) * abs(M_c2) * (geom.b2 / 2) / Jc_y)
        else
            e_x = eccentricity_to_critical_centroid(geom.b1, col.c1, geom.cAB_x)
            e_y = eccentricity_to_critical_centroid(geom.b2, col.c2, geom.cAB_y)
            Jc_y = polar_moment_Jc_corner(geom.b2, geom.b1, d, geom.cAB_y)
            vu = v_direct +
                 shifted_moment_stress(1 - g_c1.γf, M_c1, Vu, e_x, geom.cAB_x,
                                       geom.b1 - geom.cAB_x, Jc) +
                 shifted_moment_stress(1 - g_c2.γf, M_c2, Vu, e_y, geom.cAB_y,
                                       geom.b2 - geom.cAB_y, Jc_y)
        end
        return (vu = vu, transfer = _transfer_fractions(g_c1, g_c2))
    elseif col.position == :edge
        span_is_parallel = _span_moment_about_edge_axis(col, span_axis)
        span_is_parallel === nothing && return nothing
        M_par, M_other = span_is_parallel ? (M_span, M_perp) : (M_perp, M_span)
        d_par, d_other = span_is_parallel ? (d, d2) : (d2, d)
        bands = transfer_bands(col.c1, col.c2, h, d; position = :edge,
                               free_edge_parallel = edge_par)
        # The moment about the axis parallel to the edge spans perpendicular
        # to it: along c1 when the edge runs along c2.
        perp_is_c1 = edge_par === :c2
        b_par = perp_is_c1 ? (bands.b1_x, bands.b2_x, bands.bb_x) :
                             (bands.b1_y, bands.b2_y, bands.bb_y)
        b_oth = perp_is_c1 ? (bands.b1_y, bands.b2_y, bands.bb_y) :
                             (bands.b1_x, bands.b2_x, bands.bb_x)
        ga = moment_transfer_gamma_f(b_par[1], b_par[2], :edge_parallel, Vu, φVc, M_par,
                                     b_par[3], d_par, fc, fy)
        ga.provision === :aci_13_5_3_3a || return nothing
        gb = moment_transfer_gamma_f(b_oth[1], b_oth[2], :edge_perpendicular, Vu, φVc,
                                     M_other, b_oth[3], d_other, fc, fy)
        Jc_p = polar_moment_Jc_edge_perpendicular(geom.b1, geom.b2, d)
        vu = v_direct + uconvert(u"psi", (1 - gb.γf) * abs(M_other) * (geom.b2 / 2) / Jc_p)
        g_span, g_perp = span_is_parallel ? (ga, gb) : (gb, ga)
        transfer = along ? _transfer_fractions(g_span, g_perp) :
                           _transfer_fractions(g_perp, g_span)
        return (vu = vu, transfer = transfer)
    end
    return nothing
end

"""Fractions for the moments spanning the named `c1` (`_x`) and `c2` (`_y`)."""
_transfer_fractions(gx, gy) = (γf_x = gx.γf, γf_y = gy.γf,
                               provision_x = gx.provision, provision_y = gy.provision)

"""
    _span_along_c1(col, span_axis) -> Bool
    _span_along_c1(θ, span_axis) -> Bool

`true` when the slab span lies along the column's `c1` (its local x, rotated
by `θ`). A column with no `θ` is taken as aligned with global x.
"""
_span_along_c1(col, span_axis) =
    _span_along_c1(hasproperty(col, :θ) ? Float64(getfield(col, :θ)) : 0.0, span_axis)

function _span_along_c1(θ::Real, span_axis)
    sx, sy = span_axis
    along = abs(sx * cos(θ) + sy * sin(θ))
    across = abs(-sx * sin(θ) + sy * cos(θ))
    return along >= across
end

"""Inner-layer depth for the secondary span, or `d` when `mt` has no bar size."""
function _secondary_layer_depth(mt, h, d)
    hasproperty(mt, :bar_diameter) || return d
    return inner_layer_effective_depth(h, mt.cover, mt.bar_diameter, mt.bar_diameter)
end

"""
    _span_moment_about_edge_axis(col, span_axis) -> Union{Bool, Nothing}

`true` when the span-direction moment of an edge column acts about an axis
parallel to its free edge, i.e. the span runs perpendicular to the edge
(§13.5.3.3(a)). `false` when the span runs along the edge (§13.5.3.3(b)).
`nothing` when the column has no stored edge direction or the edge is skew
to the span (more than about 6° off either).
"""
function _span_moment_about_edge_axis(col, span_axis)
    hasproperty(col, :boundary_edge_dirs) || return nothing
    dirs = getfield(col, :boundary_edge_dirs)
    isempty(dirs) && return nothing
    ex, ey = dirs[1]
    sx, sy = span_axis
    ne = hypot(ex, ey)
    ns = hypot(sx, sy)
    (ne > 0 && ns > 0) || return nothing
    c = abs(ex * sx + ey * sy) / (ne * ns)
    c < 0.1 && return true
    c > 0.995 && return false
    return nothing
end

"""
    _edge_moment_pairs(col, M_span, M_perp, span_axis; stated=nothing) -> Tuple of (M_par, M_oth)

The edge column's moments as `M_par`, about the axis parallel to the free
edge, and `M_oth`, about the perpendicular axis. `stated` is the caller's
explicit answer to "does the span moment act about the edge-parallel axis"
(from a `free_edge_parallel` argument); otherwise the stored edge direction
decides. With neither, or an edge skew to the span, both assignments are
returned and the caller keeps the worse.
"""
function _edge_moment_pairs(col, M_span, M_perp, span_axis; stated::Union{Nothing, Bool} = nothing)
    par = something(stated, _span_moment_about_edge_axis(col, span_axis), Some(nothing))
    a = (M_par = M_span, M_oth = M_perp)
    b = (M_par = M_perp, M_oth = M_span)
    par === nothing && return (a, b)
    return par ? (a,) : (b,)
end

"""
    _edge_punching_stress(geom, Jc, γv, cAB, e, Vu, b0, d, M_par, M_oth) -> Pressure

Eq. (13-1) punching stress on the 3-sided edge section with both moments:

    vu = Vu/(b0 d) + γv·(|M_par| − Vu·e)·cAB/Jc + γv⊥·|M_oth|·(b2/2)/Jc⊥

ACI 318-11 §11.11.7.1–2 (corpus: aci-318-11, pages 209–211) give γv Mu c/Jc
for one moment. ENGINEERING JUDGMENT: both are superposed, as at interior
and corner columns. The perpendicular moment acts about the section's axis
of symmetry, so it has no centroid shift; γv⊥ takes `b2` as the width in
its span (Eq. 11-37 with b1 and b2 exchanged) and Jc⊥ is
`polar_moment_Jc_edge_perpendicular`, the same terms the §13.5.3.3 path
uses for that moment.
"""
function _edge_punching_stress(geom, Jc, γv, cAB, e, Vu, b0, d, M_par, M_oth)
    γv_p = gamma_v(geom.b2, geom.b1)
    Jc_p = polar_moment_Jc_edge_perpendicular(geom.b1, geom.b2, d)
    return uconvert(u"psi", Vu / (b0 * d)) +
           shifted_moment_stress(γv, M_par, Vu, e, cAB, geom.b1 - cAB, Jc) +
           uconvert(u"psi", γv_p * abs(M_oth) * (geom.b2 / 2) / Jc_p)
end

"""`1`, `-1`, or `0` when the moment is below the eccentric-shear threshold."""
function _moment_side(M)
    abs(to_kipft(M)) < 1e-6 && return 0
    return ustrip(u"N*m", M) > 0 ? 1 : -1
end

"""Plan unit vector of a local offset. `axes.x` and `axes.y` are plan unit vectors."""
function _offset_direction(dx, dy, axes)
    px = dx * axes.x[1] + dy * axes.y[1]
    py = dx * axes.x[2] + dy * axes.y[2]
    L = hypot(px, py)
    L > 1e-8 || return nothing
    return (px / L, py / L)
end

"""
Column axes in plan. `+x` is `c1` at `θ`, `+y` is the left-hand `c2`.

`_span_along_c1` uses the same pair: `(cos θ, sin θ)` and `(-sin θ, cos θ)`.
"""
function _column_axes(θ)
    c = cos(θ)
    s = sin(θ)
    return (x = (c, s), y = (-s, c))
end

"""
The one interior corner where both signed moments add, or `nothing`.

ACI 318-11 R11.11.7.2 (corpus: aci-318-11, page 210) and
`combined_punching_stress`: `vu = Vu/(b₀d) + γv Mu c / Jc`. A positive moment
peaks on the positive side of the axis it stresses. Both corners of one face
share that stress, so a moment about only one axis names no direction. Either
axis under 2% of `Vu/(b₀ d)` also names none (`moment_names_a_face`). `vu`
keeps the absolute moments.
"""
function _interior_peak_direction(M_c1, M_c2, b1, b2, d, γv_x, Jc_x, θ, Vu, b0)
    sx = _moment_side(M_c1)
    sy = _moment_side(M_c2)
    (sx == 0 || sy == 0) && return nothing
    γv_y = gamma_v(b2, b1)
    Jc_y = polar_moment_Jc_interior(b2, b1, d)
    tx = abs(ustrip(u"psi", uconvert(u"psi", γv_x * M_c1 * (b1 / 2) / Jc_x)))
    ty = abs(ustrip(u"psi", uconvert(u"psi", γv_y * M_c2 * (b2 / 2) / Jc_y)))
    tol = max(1e-4, 1e-6 * max(tx, ty))
    (tx < tol || ty < tol) && return nothing
    direct = abs(ustrip(u"psi", uconvert(u"psi", Vu / (b0 * d))))
    (moment_names_a_face(tx, direct) && moment_names_a_face(ty, direct)) || return nothing
    return _offset_direction(sx * ustrip(u"inch", b1 / 2),
                             sy * ustrip(u"inch", b2 / 2), _column_axes(θ))
end

"""
Plan axes of an edge critical section.

`rectangular_critical_section` puts the free edge at `+c1` and the slab on
the negative side (ACI 318-11 §11.11.1.2, corpus: aci-318-11, page 200).
`+x` here is toward that free edge. An inward normal, when the column has
one, is the slab side, so `+x` is its opposite. Without a normal, `+c1` is
toward the free edge only for `free_edge_parallel = :c2`, the same default
`_infer_free_edge_parallel` uses. The other storage names no side.
"""
function _edge_section_axes(θ, free_edge_parallel, col)
    if hasproperty(col, :boundary_inward_normals)
        dirs = getfield(col, :boundary_inward_normals)
        if length(dirs) == 1
            inn = dirs[1]
            L = hypot(inn[1], inn[2])
            L > 1e-12 || return nothing
            out = (-inn[1] / L, -inn[2] / L)
            return (x = out, y = (-out[2], out[1]))
        end
    end
    free_edge_parallel === :c2 || return nothing
    return _column_axes(θ)
end

"""
The one edge-section vertex where both moments add, or `nothing`.

`shifted_moment_stress` puts the larger stress on face AB, the inner face,
when `|M| − Vu·e` is non-negative, and on face CD when the reaction
eccentricity reverses it (ACI 318-11 R11.11.7.2, corpus: aci-318-11, page 210;
the 46.65 kip·ft to 37.81 kip·ft reduction, corpus:
sp-de-two-way-flat-plate-aci318-14, page 42). The perpendicular moment peaks
on its own sign. One moment alone leaves two vertices, so no direction.
Two moment assignments within tolerance of the governing stress also name none.
Either axis moment stress under 2% of `Vu/(b₀ d)` names none
(`moment_names_a_face`).
"""
function _edge_peak_direction(c1, c2, d, geom, Vu, edge_pairs, pair_vu,
                              e, γv, Jc, θ, col, free_edge_parallel)
    axes = _edge_section_axes(θ, free_edge_parallel, col)
    axes === nothing && return nothing
    length(pair_vu) == length(edge_pairs) || return nothing
    best = maximum(ustrip(u"psi", v) for v in pair_vu)
    tol = max(1e-3, 1e-4 * abs(best))
    facing = [i for i in eachindex(pair_vu) if ustrip(u"psi", pair_vu[i]) >= best - tol]
    length(facing) == 1 || return nothing
    pair = edge_pairs[facing[1]]
    (_moment_side(pair.M_par) == 0 || _moment_side(pair.M_oth) == 0) && return nothing
    direct = abs(ustrip(u"psi", uconvert(u"psi", Vu / (geom.b0 * d))))
    m_par = abs(ustrip(u"psi", shifted_moment_stress(γv, pair.M_par, Vu, e,
                                                    geom.cAB, geom.b1 - geom.cAB, Jc)))
    γv_p = gamma_v(geom.b2, geom.b1)
    Jc_p = polar_moment_Jc_edge_perpendicular(geom.b1, geom.b2, d)
    m_oth = abs(_perp_moment_psi(pair.M_oth, γv_p, Jc_p, geom.b2, true))
    (moment_names_a_face(m_par, direct) && moment_names_a_face(m_oth, direct)) ||
        return nothing
    pts, _ = rectangular_critical_section(c1, c2, d; position = :edge)
    props = critical_section_properties(pts, d; closed = false)
    stresses = _edge_vertex_moment_psi(pts, geom, Vu, pair.M_par, pair.M_oth, e, γv, Jc, d)
    reported = best - ustrip(u"psi", uconvert(u"psi", Vu / (geom.b0 * d)))
    return _direction_of_peak(pts, stresses, props.xc, props.yc, reported, axes)
end

"""
Moment term `γv Mc c / Jc` on one face, in psi.

AB, the inner face, takes `+Mc·cAB`. CD takes `−Mc·cCD`. That is the pair in
`shifted_moment_stress` (ACI 318-11 R11.11.7.2, corpus: aci-318-11, page 210).
A moment below the threshold contributes nothing.
"""
function _face_moment_psi(M, Vu, e, γv, Jc, cAB, cCD, on_inner::Bool)
    abs(to_kipft(M)) < 1e-10 && return 0.0
    Mc = abs(M) - Vu * e
    lever = on_inner ? Mc * cAB : -Mc * cCD
    return ustrip(u"psi", uconvert(u"psi", γv * lever / Jc))
end

"""Moment-term stress, in psi, at each vertex of the edge section."""
function _edge_vertex_moment_psi(pts, geom, Vu, M_par, M_oth, e, γv, Jc, d)
    cCD = geom.b1 - geom.cAB
    γv_p = gamma_v(geom.b2, geom.b1)
    Jc_p = polar_moment_Jc_edge_perpendicular(geom.b1, geom.b2, d)
    xs = [ustrip(u"inch", p[1]) for p in pts]
    x_inner = minimum(xs)
    out = Float64[]
    for p in pts
        x = ustrip(u"inch", p[1])
        y = ustrip(u"inch", p[2])
        push!(out, _face_moment_psi(M_par, Vu, e, γv, Jc, geom.cAB, cCD,
                                    abs(x - x_inner) <= 1e-6) +
                  _perp_moment_psi(M_oth, γv_p, Jc_p, geom.b2, y > 0))
    end
    return out
end

"""Perpendicular edge moment, signed so a positive moment peaks at `+y`."""
function _perp_moment_psi(M, γv, Jc, b2, positive::Bool)
    abs(to_kipft(M)) < 1e-10 && return 0.0
    s = positive ? 1.0 : -1.0
    return ustrip(u"psi", uconvert(u"psi", γv * M * s * (b2 / 2) / Jc))
end

"""
The one corner-section vertex where both axis peaks meet, or `nothing`.

The L has no vertex that is outside on both legs. When both centroid moments
are reversed, the two governing faces do not meet, the vertex stress is below
the sum `vu` reports, and this returns `nothing`. Either axis under 2% of
`Vu/(b₀ d)` also names none (`moment_names_a_face`).
"""
function _corner_peak_direction(c1, c2, d, geom, Vu, M_c1, M_c2, e_x, e_y,
                                γv_x, γv_y, Jc_x, Jc_y, θ)
    (_moment_side(M_c1) == 0 || _moment_side(M_c2) == 0) && return nothing
    direct = abs(ustrip(u"psi", uconvert(u"psi", Vu / (geom.b0 * d))))
    mx = abs(ustrip(u"psi", shifted_moment_stress(γv_x, M_c1, Vu, e_x, geom.cAB_x,
                                                 geom.b1 - geom.cAB_x, Jc_x)))
    my = abs(ustrip(u"psi", shifted_moment_stress(γv_y, M_c2, Vu, e_y, geom.cAB_y,
                                                 geom.b2 - geom.cAB_y, Jc_y)))
    (moment_names_a_face(mx, direct) && moment_names_a_face(my, direct)) || return nothing
    pts, _ = rectangular_critical_section(c1, c2, d; position = :corner)
    props = critical_section_properties(pts, d; closed = false)
    stresses = _corner_vertex_moment_psi(pts, geom, Vu, M_c1, M_c2, e_x, e_y,
                                         γv_x, γv_y, Jc_x, Jc_y)
    reported = ustrip(u"psi",
        shifted_moment_stress(γv_x, M_c1, Vu, e_x, geom.cAB_x, geom.b1 - geom.cAB_x, Jc_x) +
        shifted_moment_stress(γv_y, M_c2, Vu, e_y, geom.cAB_y, geom.b2 - geom.cAB_y, Jc_y))
    return _direction_of_peak(pts, stresses, props.xc, props.yc, reported, _column_axes(θ))
end

"""Moment-term stress, in psi, at each vertex of the two-sided corner section."""
function _corner_vertex_moment_psi(pts, geom, Vu, M_c1, M_c2, e_x, e_y,
                                  γv_x, γv_y, Jc_x, Jc_y)
    xs = [ustrip(u"inch", p[1]) for p in pts]
    ys = [ustrip(u"inch", p[2]) for p in pts]
    x_inner = minimum(xs)
    y_inner = minimum(ys)
    out = Float64[]
    for p in pts
        x = ustrip(u"inch", p[1])
        y = ustrip(u"inch", p[2])
        push!(out, _face_moment_psi(M_c1, Vu, e_x, γv_x, Jc_x, geom.cAB_x,
                                    geom.b1 - geom.cAB_x, abs(x - x_inner) <= 1e-6) +
                  _face_moment_psi(M_c2, Vu, e_y, γv_y, Jc_y, geom.cAB_y,
                                    geom.b2 - geom.cAB_y, abs(y - y_inner) <= 1e-6))
    end
    return out
end

"""
Unit plan direction of the one vertex at `reported` psi, or `nothing`.

A second vertex within tolerance, or a peak that is not the stress `vu` adds,
names no face.
"""
function _direction_of_peak(pts, stresses, xc, yc, reported, axes)
    isempty(stresses) && return nothing
    peak = maximum(stresses)
    abs(peak - reported) <= max(1e-2, 1e-3 * max(abs(reported), 1.0)) || return nothing
    tol = max(1e-4, 1e-6 * max(abs(peak), 1.0))
    winners = [k for k in eachindex(stresses) if stresses[k] >= peak - tol]
    length(winners) == 1 || return nothing
    pt = pts[winners[1]]
    dx = ustrip(u"inch", pt[1]) - ustrip(u"inch", xc)
    dy = ustrip(u"inch", pt[2]) - ustrip(u"inch", yc)
    return _offset_direction(dx, dy, axes)
end

# =============================================================================
# Punching Shear Check at Drop Panel Edge (Flat Slab — ACI 318-11 §11.11.1.2)
# =============================================================================

"""
    check_punching_at_drop_edge(col, Vu, Mub, h_slab, d_slab, fc, drop::DropPanelGeometry;
                                 qu=nothing, verbose=false, col_idx=1, λ=1.0, φ_shear=0.75)

Check punching shear at d/2 from the drop panel edge for flat slab design.

Per ACI 318-11 §11.11.1.2, when drop panels are present, punching shear
must also be checked at a critical section located at d/2 from the edge
of the drop panel (where d is the slab effective depth, NOT the total depth
at the drop).

Per StructurePoint, the check at the drop edge uses **direct shear only**
(no unbalanced moment term) because the critical section is far from the
column and moment transfer is negligible.  Additionally, Vu is reduced by
the factored slab-only load within the critical section when `qu` is provided.

# Arguments
- `col`: Column with position and dimensions
- `Vu`: Factored shear demand at the column (gross)
- `Mub`: Unbalanced moment (unused — kept for API consistency)
- `h_slab`: Slab thickness (without drop panel)
- `d_slab`: Effective slab depth (h_slab - cover - db/2)
- `fc`: Concrete compressive strength
- `drop`: Drop panel geometry

# Keyword Arguments
- `qu`: Factored slab-only load (Pressure). When provided, Vu is reduced by
  `qu × A_crit` where A_crit is the area within the critical section.

# Returns
Named tuple `(ok, ratio, vu, φvc, b0, Jc)`

# Reference
- ACI 318-11 §11.11.1.2
- StructurePoint DE-Two-Way-Flat-Slab: Two critical sections checked
"""
function check_punching_at_drop_edge(col, Vu, Mub, h_slab, d_slab, fc,
                                      drop::DropPanelGeometry;
                                      qu = nothing,
                                      verbose=false, col_idx=1, λ=1.0, φ_shear=0.75,
                                      openings=nothing, column_xy=nothing,
                                      flat_slab::Bool = false,
                                      column_strip_half=nothing,
                                      column_strips=nothing,
                                      span_axis::NTuple{2, Float64} = (1.0, 0.0),
                                      θ::Union{Nothing, Real} = nothing)
    a1 = drop.a_drop_1
    a2 = drop.a_drop_2

    # The drop is the ±a1 by ±a2 rectangle centred on the column. A free edge
    # clips it, and the critical section sits d/2 outside that outline.
    # ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200). The same outline,
    # with and without an opening, is what StructurePoint uses: an exterior
    # drop has b1 = a1 + c1/2 + d/2, not a1 + d/2
    # (sp-de-two-way-flat-slab-drop-panels-aci318-14, pages 60–62, Table 13 p. 107).
    col_θ = θ === nothing ? (hasproperty(col, :θ) ? Float64(getfield(col, :θ)) : 0.0) : Float64(θ)
    swapped = col.position == :edge && _infer_free_edge_parallel(col) == :c1
    corner_kind = hasproperty(col, :corner_kind) ? getfield(col, :corner_kind) : :convex
    sec = drop_plan_section(col.c1, col.c2, a1, a2, d_slab, col.position, col_θ, span_axis;
                           swapped = swapped, corner_kind = corner_kind)
    b0 = critical_section_properties(sec.points, d_slab; closed = sec.closed).b0

    # qu acts on the area inside the critical section (b1 × b2 in the example).
    Vu_net = Vu
    if !isnothing(qu)
        Vu_net = max(Vu - qu * sec.area, 0.0 * Vu)
    end
    
    # Direct shear only — no unbalanced moment term at the drop edge
    vu = uconvert(u"psi", Vu_net / (b0 * d_slab))
    
    # Column aspect ratio uses drop panel extents
    β_drop = max(2*a1, 2*a2) / max(min(2*a1, 2*a2), 1.0u"inch")
    β = max(ustrip(β_drop), 1.0)
    αs = punching_αs(col.position)
    
    vc = punching_capacity_stress(fc, β, αs, b0, d_slab; λ=λ, λs=size_effect_factor(d_slab))
    φvc = φ_shear * vc
    
    ok = vu <= φvc
    ratio = ustrip(u"psi", vu) / ustrip(u"psi", φvc)
    
    if verbose
        status = ok ? "✓ PASS" : "✗ FAIL"
        @debug "Drop panel punching — Column $col_idx ($(col.position))" b0=b0 d_slab=d_slab Vu_net=Vu_net
        @debug "  Stress (direct shear only)" vu=round(ustrip(u"psi", vu), digits=1) φvc=round(ustrip(u"psi", φvc), digits=1) ratio=round(ratio, digits=2) status=status
    end
    
    # Jc not meaningful for direct-shear-only check but kept for API consistency
    Jc = 0.0u"inch^4"  # placeholder — no moment transfer at drop edge

    # ACI 318-11 §11.11.6 modifies that same section (corpus: aci-318-11, pages
    # 200 and 209). Tangents come from the drop centroid and 10h is measured
    # from the drop outline, with h the slab thickness outside the drop.
    # Only the resisting perimeter changes; the area inside the section stays.
    b0_open = drop_opening_b0(col.c1, col.c2, drop.a_drop_1, drop.a_drop_2, d_slab, h_slab,
                             col.position, openings, column_xy;
                             column_θ = col_θ, span_axis = span_axis, swapped = swapped,
                             corner_kind = corner_kind,
                             flat_slab = flat_slab, column_strips = column_strips,
                             column_strip_half = column_strip_half)
    if b0_open !== nothing
        b0 = b0_open
        # §11.11.2.1(c) depends on b0/d, so the capacity moves with the cut.
        vc = punching_capacity_stress(fc, β, αs, b0, d_slab; λ=λ, λs=size_effect_factor(d_slab))
        φvc = φ_shear * vc
        vu = uconvert(u"psi", Vu_net / (b0 * d_slab))
        ok = vu <= φvc
        ratio = ustrip(u"psi", vu) / ustrip(u"psi", φvc)
    end

    return (ok=ok, ratio=ratio, vu=vu, φvc=φvc, b0=b0, Jc=Jc)
end

"""
    check_punching(col, Vu, Mub, h_slab, d_slab, h_total, d_total,
                   fc, drop::DropPanelGeometry; kwargs...) -> NamedTuple

Combined punching shear check for flat slab — both critical sections.

Per ACI 318-11 §11.11.1.2, flat slabs with drop panels require TWO checks:
1. At d/2 from column face, using total depth h_total = h_slab + h_drop
2. At d/2 from drop panel edge, using slab depth h_slab

The governing (worst) result is returned.

# Keyword Arguments
- `Muy`: Optional perpendicular-axis unbalanced moment, forwarded to
  `check_punching_for_column` at the column-face section (edge / interior /
  corner).  Drop-edge remains direct-shear only.

# Returns
Named tuple `(ok, ratio, vu, φvc, b0, Jc, Mub, governing_section, column_section,
drop_section)` where `governing_section` is `:column` or `:drop_edge`, `ok` requires
both sections to pass, and `column_section` / `drop_section` are the two
individual results.

# Reference
- ACI 318-11 §11.11.1.2
- StructurePoint DE-Two-Way-Flat-Slab
"""
function check_punching(col, Vu, Mub, h_slab, d_slab, h_total, d_total,
                                   fc, drop::DropPanelGeometry;
                                   qu = nothing,
                                   Muy = nothing,
                                   verbose=false, col_idx=1, λ=1.0, φ_shear=0.75,
                                   openings=nothing, column_xy=nothing,
                                   flat_slab::Bool = false,
                                   column_strip_half=nothing,
                                   column_strips=nothing,
                                   span_axis::NTuple{2, Float64} = (1.0, 0.0),
                                   θ::Union{Nothing, Real} = nothing)
    # Check 1: At column face with total depth.
    # ACI 318-11 §11.11.7.1 (corpus: aci-318-11, page 209) — γv Mu by
    # eccentric shear at every slab-column connection (interior / edge /
    # corner).  Perpendicular-axis Muy is the secondary-frame transfer
    # moment (PCA EB712 Fig. 16-13 Case D on :corner, corpus: pca-eb712,
    # page 486; punching_check max/superposition on :edge / :interior).
    check_col = check_punching_for_column(col, Vu, Mub, d_total, h_total, fc;
                                          verbose=verbose, col_idx=col_idx, λ=λ, φ_shear=φ_shear,
                                          Muy=Muy, openings=openings, column_xy=column_xy,
                                          flat_slab=flat_slab, column_strip_half=column_strip_half,
                                          column_strips=column_strips, span_axis=span_axis, θ=θ)
    
    # Check 2: At drop panel edge with slab depth (direct shear only, Vu reduced).
    # h_slab is the thickness outside the drop, which is the 10h thickness here.
    check_drop = check_punching_at_drop_edge(col, Vu, Mub, h_slab, d_slab, fc, drop;
                                              qu=qu,
                                              verbose=verbose, col_idx=col_idx, λ=λ, φ_shear=φ_shear,
                                              openings=openings, column_xy=column_xy,
                                              flat_slab=flat_slab, column_strip_half=column_strip_half,
                                              column_strips=column_strips, span_axis=span_axis, θ=θ)
    
    # Governing check: higher ratio controls
    # Mub is the slab-column unbalanced moment from moment analysis, carried through
    # for downstream consumers (PunchingDesignResult, micro-experiments).
    ok = check_col.ok && check_drop.ok
    if check_drop.ratio >= check_col.ratio
        return (ok=ok, ratio=check_drop.ratio, vu=check_drop.vu,
                φvc=check_drop.φvc, b0=check_drop.b0, Jc=check_drop.Jc,
                Mub=Mub, governing_section=:drop_edge,
                column_section=check_col, drop_section=check_drop)
    else
        return (ok=ok, ratio=check_col.ratio, vu=check_col.vu,
                φvc=check_col.φvc, b0=check_col.b0, Jc=check_col.Jc,
                Mub=Mub, governing_section=:column,
                column_section=check_col, drop_section=check_drop)
    end
end

# =============================================================================
# Punching at wall reactions (ACI 318-11 §11.11.1.2)
# =============================================================================

"""
    wall_reaction_punching(struc, slab, d, fc, qu; λ=1.0, ϕ=0.75)

Two-way shear at each wall reaction that meets `slab`.

One section per connected reaction, at `d/2` from the wall faces
(§11.11.1.2, corpus: aci-318-11, page 200). A closed rectangular shaft is
one loop. Two walls that meet are the re-entrant corner or the outside
corner, whichever quadrant has slab. A wall on its own is the rectangular
section: four sides when the slab is on both faces, three sides when the
slab is on one face and both ends.

`Vu` is `qu` times the walls' tributary area, the same demand as a column.
`wall_transfer` (`MomentAnalysisResult.wall_transfer`, primary and
secondary lists together) gives the moment the slab transfers to each wall
about the wall's axis; the analyses restrain the slab's rotation at a wall.
It is combined with `Vu` on the same section as eccentric shear, ACI
421.1R-99 Eq. (3.2) with `γv` from Eq. (3.3) (corpus: aci-421-1r-99,
page 421.1R-4), through [`punching_check_general`](@ref). A wall missing
from the list carries direct shear only. `β` is the long side over the thickness of the reaction
(§11.11.2.1). `αs` is 40 on a re-entrant corner, 20 on an outside corner,
30 on an edge or a shaft loop, 40 when the slab surrounds the wall.

A wall with no tributary area is omitted.

Each wall's moment is about its own axis. A cluster whose walls are
parallel or perpendicular to its first wall is turned onto that wall's
axis and checked as above: a single wall or a corner takes each wall's
moment about its axis, with both relative signs tried when two act
together. Walls that meet at another angle have no section here; they are
checked for direct shear on the lines at `d/2` from the slab-side faces
alone (`_junction_face_punching`), a shorter perimeter than the true one.

ENGINEERING JUDGMENT: the transfer moments are magnitudes enveloped per
wall, so on a closed shaft the opposite walls' moments are not netted.
Each axis takes the larger of its two walls, which bounds their difference
from above without adding them.
"""
function wall_reaction_punching(struc, slab, d::Length, fc::Pressure, qu::Pressure;
                                λ::Float64 = 1.0, ϕ::Float64 = 0.75,
                                wall_transfer = nothing)
    walls = _with_wall_moments(_walls_meeting_slab(struc, slab), wall_transfer)
    isempty(walls) && return NamedTuple[]
    in_slab = _slab_plan_contains(struc, slab)
    in_slab === nothing && return NamedTuple[]
    checks = NamedTuple[]
    for cluster in _wall_clusters(walls)
        _push_cluster_checks!(checks, cluster, d, fc, qu, in_slab; λ, ϕ)
    end
    return checks
end

"""
    wall_transfer_of(results...) -> Union{Nothing, Vector}

The `wall_transfer` lists of the primary and secondary results together,
for [`wall_reaction_punching`](@ref). `nothing` when neither reports one.
"""
function wall_transfer_of(results...)
    lists = [r.wall_transfer for r in results
             if r !== nothing && hasproperty(r, :wall_transfer) && r.wall_transfer !== nothing]
    return isempty(lists) ? nothing : reduce(vcat, lists)
end

"""
    _with_wall_moments(walls, wall_transfer) -> Vector

The walls as named tuples carrying `M`, the transfer moment about the
wall's axis from `wall_transfer` (zero when the wall is not listed). A wall
listed twice keeps the larger moment.
"""
function _with_wall_moments(walls, wall_transfer)
    moment = Dict{Any, Any}()
    if wall_transfer !== nothing
        for w in wall_transfer
            key = _segment_key(w.seg)
            moment[key] = haskey(moment, key) ? max(moment[key], w.M) : w.M
        end
    end
    z = 0.0u"kip*ft"
    return Any[(x1 = Float64(w.x1), y1 = Float64(w.y1), x2 = Float64(w.x2), y2 = Float64(w.y2),
                thickness = w.thickness,
                tributary_cell_areas = hasproperty(w, :tributary_cell_areas) ?
                                       w.tributary_cell_areas : Dict{Int, Float64}(),
                M = uconvert(kip * u"ft",
                             get(moment, _segment_key(((w.x1, w.y1), (w.x2, w.y2))), z)))
               for w in walls]
end

"""Checks of one wall reaction (a cluster from `_wall_clusters`), pushed onto `checks`."""
function _push_cluster_checks!(checks, raw, d, fc, qu, in_slab; λ, ϕ)
    turned = _turn_to_first_wall(raw, in_slab)
    if turned === nothing
        chk = _junction_face_punching(raw, d, fc, qu, in_slab; λ, ϕ)
        chk === nothing || push!(checks, chk)
        return checks
    end
    cluster, inside = turned
    _push_loop_check!(checks, cluster, d, fc, qu, inside; λ, ϕ) && return checks
    paired = _push_corner_checks!(checks, cluster, d, fc, qu, inside; λ, ϕ)
    for (i, w) in enumerate(cluster)
        paired[i] && continue
        chk = _single_wall_punching(w, d, fc, qu, inside; λ, ϕ)
        chk === nothing || push!(checks, chk)
    end
    return checks
end

"""
    _turn_to_first_wall(walls, in_slab) -> Union{Nothing, Tuple}

`(walls′, in_slab′)` with the plan turned so the first wall lies along x:
each wall's ends rotated by −θ, and the point test rotating back. `nothing`
when a wall is neither parallel nor perpendicular to the first (more than
about 0.6° off).
"""
function _turn_to_first_wall(walls, in_slab)
    w0 = walls[1]
    L0 = _wall_len_m(w0)
    L0 > 0 || return nothing
    c, s = (w0.x2 - w0.x1) / L0, (w0.y2 - w0.y1) / L0
    for w in walls
        L = _wall_len_m(w)
        L > 0 || return nothing
        cross = abs(c * (w.y2 - w.y1) - s * (w.x2 - w.x1)) / L
        min(cross, sqrt(max(1 - cross^2, 0.0))) > 0.01 && return nothing
    end
    fwd(x, y) = (c * x + s * y, -s * x + c * y)
    back(x, y) = (c * x - s * y, s * x + c * y)
    turned = map(walls) do w
        x1, y1 = fwd(w.x1, w.y1)
        x2, y2 = fwd(w.x2, w.y2)
        (x1 = x1, y1 = y1, x2 = x2, y2 = y2, thickness = w.thickness,
         tributary_cell_areas = hasproperty(w, :tributary_cell_areas) ?
                                w.tributary_cell_areas : Dict{Int, Float64}(),
         M = _wall_M(w))
    end
    return (Any[turned...], pt -> in_slab(back(pt[1], pt[2])))
end

"""
    _junction_face_punching(walls, d, fc, qu, in_slab; λ, ϕ) -> Union{Nothing, NamedTuple}

Walls that meet at an angle other than 90°, as one reaction. The section is
the lines at `d/2` from each face with slab beside it, `b0 = Σ L` over those
faces; the wall ends and the junction are left out, so `b0` is below the
true perimeter. `Vu` is `qu` times the walls' tributary area. `αs = 30` and
`β` is the longest wall over the thinnest (§11.11.2.1, corpus: aci-318-11,
page 202).
"""
function _junction_face_punching(walls, d, fc, qu, in_slab; λ, ϕ)
    b0 = 0.0u"m"
    for w in walls
        len = _wall_len_m(w)
        len > 0 || continue
        nx, ny = -(w.y2 - w.y1) / len, (w.x2 - w.x1) / len
        mx, my = (w.x1 + w.x2) / 2, (w.y1 + w.y2) / 2
        off = ustrip(u"m", w.thickness) / 2 + 0.05
        sides = in_slab((mx + nx * off, my + ny * off)) + in_slab((mx - nx * off, my - ny * off))
        b0 += sides * len * u"m"
    end
    b0 > zero(b0) || return nothing
    Vu = _vu_from_area(qu, sum(_wall_trib_m2, walls))
    Vu === nothing && return nothing
    β = punching_β(maximum(_wall_len_m, walls) * u"m", minimum(w -> w.thickness, walls))
    vc = punching_capacity_stress(fc, Float64(β), 30, b0, d; λ = λ, λs = size_effect_factor(d))
    ϕvc = ϕ * vc
    vu = uconvert(u"psi", Vu / (b0 * d))
    return (ok = vu <= ϕvc, utilization = ustrip(vu / ϕvc), b0 = uconvert(u"inch", b0),
            vu = vu, ϕvc = uconvert(u"psi", ϕvc), kind = :wall_junction)
end

"""Walls that share an endpoint, within a millimetre, are one reaction."""
function _wall_clusters(walls)
    n = length(walls)
    parent = collect(1:n)
    function root(i)
        parent[i] == i && return i
        parent[i] = root(parent[i])
        return parent[i]
    end
    ends = Dict{NTuple{2,Int}, Int}()
    for i in 1:n
        w = walls[i]
        for (x, y) in ((w.x1, w.y1), (w.x2, w.y2))
            key = (round(Int, 1000 * x), round(Int, 1000 * y))
            if haskey(ends, key)
                parent[root(i)] = root(ends[key])
            else
                ends[key] = i
            end
        end
    end
    groups = Dict{Int, Vector{Any}}()
    for i in 1:n
        push!(get!(groups, root(i), Any[]), walls[i])
    end
    return collect(values(groups))
end

function _walls_meeting_slab(struc, slab)
    hasproperty(struc, :walls) || return Any[]
    walls = struc.walls
    isempty(walls) && return Any[]
    skel = struc.skeleton
    hasproperty(skel, :stories) || return Any[]
    z = _slab_elevation_m(struc, slab)
    z === nothing && return Any[]
    out = Any[]
    for w in walls
        hasproperty(w, :x1) || continue
        any(zw -> abs(zw - z) <= 0.1, _wall_end_elevations_m(skel, w.story)) || continue
        push!(out, w)
    end
    return out
end

"""Point-in-slab test in plan metres, or `nothing` when the slab has no outline."""
function _slab_plan_contains(struc, slab; boundary::Bool = false)
    skel = struc.skeleton
    vis, _, _ = _get_slab_face_boundary(struc, slab)
    isempty(vis) && return nothing
    exterior = [_vertex_xy_m(skel, vi) for vi in vis]
    holes = slab_void_loops(struc, slab)
    return function (pt)
        # The crossing test is strict, and it is not consistent on an edge:
        # one side of a rectangle counts as inside and the other as outside.
        # An edge frame sits on that line. `boundary` keeps the edge and
        # still rejects a point in the opening.
        inside = _eq137_point_in_poly(pt, exterior) ||
            (boundary && _eq137_on_boundary(pt, exterior))
        inside || return false
        for hole in holes
            in_hole = _eq137_point_in_poly(pt, hole)
            boundary && in_hole && _eq137_on_boundary(pt, hole) && (in_hole = false)
            in_hole && return false
        end
        return true
    end
end

function _wall_trib_m2(w)
    hasproperty(w, :tributary_cell_areas) || return 0.0
    return sum(values(w.tributary_cell_areas); init = 0.0)
end

"""Transfer moment carried by a wall from `_with_wall_moments` (zero if absent)."""
_wall_M(w) = hasproperty(w, :M) ? w.M : 0.0u"kip*ft"

"""
    _reaction_punch(points, closed, Vu, d, fc, β, αs; λ, ϕ, kind, Mux=0, Muy=0)

ACI 421.1R-99 Eq. (3.2)–(3.3) on a wall reaction's section through
`punching_check_general` (`Mux` about the section's x axis, `Muy` about y).
The moments are magnitudes, so with both present the worse of the two
relative signs governs.
"""
function _reaction_punch(points, closed, Vu, d, fc, β, αs; λ, ϕ, kind,
                         Mux = 0.0u"kip*ft", Muy = 0.0u"kip*ft")
    check(My) = punching_check_general(Vu, Mux, My, d, fc, points;
                                       closed = closed, β = Float64(β), αs = Int(αs), λ = λ,
                                       λs = size_effect_factor(d), ϕ = ϕ)
    r = check(Muy)
    if Mux != zero(Mux) && Muy != zero(Muy)
        r2 = check(-Muy)
        r2.utilization > r.utilization && (r = r2)
    end
    return (ok = r.ok, utilization = r.utilization, b0 = r.b0, vu = r.vu,
            ϕvc = r.ϕvc, kind = kind, Mux = Mux, Muy = Muy)
end

function _vu_from_area(qu, area_m2)
    area_m2 > 0 || return nothing
    return uconvert(kip, qu * (area_m2 * u"m^2"))
end

_wall_len_m(w) = hypot(w.x2 - w.x1, w.y2 - w.y1)

function _axis_aligned(w)
    return abs(w.x1 - w.x2) <= 1e-6 || abs(w.y1 - w.y2) <= 1e-6
end

function _same_point(x1, y1, x2, y2)
    return hypot(x1 - x2, y1 - y2) <= 1e-3
end

function _push_loop_check!(checks, walls, d, fc, qu, in_slab; λ, ϕ)
    length(walls) == 4 || return false
    all(_axis_aligned, walls) || return false
    xs = Float64[]
    ys = Float64[]
    for w in walls
        append!(xs, (w.x1, w.x2))
        append!(ys, (w.y1, w.y2))
    end
    ux = unique(round.(xs, digits = 4))
    uy = unique(round.(ys, digits = 4))
    (length(ux) == 2 && length(uy) == 2) || return false
    t = walls[1].thickness
    all(w -> w.thickness == t, walls) || return false
    Wx = abs(ux[2] - ux[1]) * u"m"
    Wy = abs(uy[2] - uy[1]) * u"m"
    outward = !in_slab(((ux[1] + ux[2]) / 2, (uy[1] + uy[2]) / 2))
    pts, closed = try
        closed_wall_loop_section(Wx, Wy, t, d; outward = outward)
    catch
        return false
    end
    Vu = _vu_from_area(qu, sum(_wall_trib_m2, walls))
    Vu === nothing && return true
    β = punching_β(max(Wx, Wy), t)
    z = 0.0u"kip*ft"
    Mux = maximum(w -> abs(w.y1 - w.y2) <= 1e-6 ? _wall_M(w) : z, walls)
    Muy = maximum(w -> abs(w.x1 - w.x2) <= 1e-6 ? _wall_M(w) : z, walls)
    push!(checks, _reaction_punch(pts, closed, Vu, d, fc, β, 30; λ, ϕ, kind = :wall_loop,
                                  Mux = Mux, Muy = Muy))
    return true
end

function _push_corner_checks!(checks, walls, d, fc, qu, in_slab; λ, ϕ)
    n = length(walls)
    paired = falses(n)
    for i in 1:n, j in (i + 1):n
        w1, w2 = walls[i], walls[j]
        (_axis_aligned(w1) && _axis_aligned(w2)) || continue
        h1 = abs(w1.y1 - w1.y2) <= 1e-6
        h2 = abs(w2.y1 - w2.y2) <= 1e-6
        h1 == h2 && continue
        horiz, vert = h1 ? (w1, w2) : (w2, w1)
        corner = nothing
        for (x, y) in ((horiz.x1, horiz.y1), (horiz.x2, horiz.y2))
            if _same_point(x, y, vert.x1, vert.y1) || _same_point(x, y, vert.x2, vert.y2)
                corner = (x, y)
                break
            end
        end
        corner === nothing && continue
        cx, cy = corner
        Lx = _wall_len_m(horiz) * u"m"
        Ly = _wall_len_m(vert) * u"m"
        tx, ty = horiz.thickness, vert.thickness
        ux = (abs(horiz.x1 - cx) <= 1e-3 && abs(horiz.y1 - cy) <= 1e-3) ?
             sign(horiz.x2 - horiz.x1) : sign(horiz.x1 - horiz.x2)
        uy = (abs(vert.x1 - cx) <= 1e-3 && abs(vert.y1 - cy) <= 1e-3) ?
             sign(vert.y2 - vert.y1) : sign(vert.y1 - vert.y2)
        ux == 0 && (ux = 1.0)
        uy == 0 && (uy = 1.0)
        offx = ustrip(u"m", ty) / 2 + 0.05
        offy = ustrip(u"m", tx) / 2 + 0.05
        between = in_slab((cx + ux * offx, cy + uy * offy))
        outside = in_slab((cx - ux * offx, cy - uy * offy))
        Vu = _vu_from_area(qu, _wall_trib_m2(horiz) + _wall_trib_m2(vert))
        Vu === nothing && (paired[i] = true; paired[j] = true; continue)
        β = max(ustrip(u"m", Lx), ustrip(u"m", Ly)) /
            max(min(ustrip(u"m", tx), ustrip(u"m", ty)), 1e-6)
        ox, oy = ty / 2 + d / 2, tx / 2 + d / 2
        pushed = false
        if between && Lx > ox && Ly > oy
            pts, closed = reentrant_wall_corner_section(tx, Lx, ty, Ly, d)
            push!(checks, _reaction_punch(pts, closed, Vu, d, fc, β, 40; λ, ϕ,
                                          kind = :reentrant_corner,
                                          Mux = _wall_M(horiz), Muy = _wall_M(vert)))
            pushed = true
        end
        if outside
            pts, closed = convex_wall_corner_section(tx, Lx, ty, Ly, d)
            push!(checks, _reaction_punch(pts, closed, Vu, d, fc, β, 20; λ, ϕ,
                                          kind = :convex_corner,
                                          Mux = _wall_M(horiz), Muy = _wall_M(vert)))
            pushed = true
        end
        if pushed
            paired[i] = true
            paired[j] = true
        end
    end
    return paired
end

function _single_wall_punching(w, d, fc, qu, in_slab; λ, ϕ)
    _axis_aligned(w) || return nothing
    L = _wall_len_m(w) * u"m"
    t = w.thickness
    L > zero(L) && t > zero(t) || return nothing
    dx, dy = w.x2 - w.x1, w.y2 - w.y1
    len = hypot(dx, dy)
    nx, ny = -dy / len, dx / len
    mx, my = (w.x1 + w.x2) / 2, (w.y1 + w.y2) / 2
    off = ustrip(u"m", t) / 2 + 0.05
    sides = (in_slab((mx + nx * off, my + ny * off)) ? 1 : 0) +
            (in_slab((mx - nx * off, my - ny * off)) ? 1 : 0)
    sides == 0 && return nothing
    Vu = _vu_from_area(qu, _wall_trib_m2(w))
    Vu === nothing && return nothing
    # The wall lies along x in the four-sided section and along y in the
    # three-sided one; its moment is about its own axis.
    z = 0.0u"kip*ft"
    if sides == 2
        pts, closed = rectangular_critical_section(L, t, d; position = :interior)
        αs = 40
        kind = :wall_interior
        Mux, Muy = _wall_M(w), z
    else
        pts, closed = wall_face_critical_section(t, L, d)
        αs = 30
        kind = :wall_end
        Mux, Muy = z, _wall_M(w)
    end
    return _reaction_punch(pts, closed, Vu, d, fc, punching_β(L, t), αs; λ, ϕ, kind,
                           Mux = Mux, Muy = Muy)
end

