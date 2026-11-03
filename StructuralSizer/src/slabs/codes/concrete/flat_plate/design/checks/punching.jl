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
# Punching Shear Check (ACI 318-11 §11.11)
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
- `Mub`: Unbalanced moment
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
  connection.  Applied to match `punching_check`: `:corner` adds both
  axes (PCA Case D); `:edge` uses the moment about the axis parallel to
  the free edge on the 3-sided Jc (R11.11.7.2, pages 209–211), taking
  `max(|Mux|, |Muy|)` on both `:c1` and `:c2` after any c1↔c2 geometry
  swap so the uniaxial check cannot drop the governing transfer moment;
  `:interior` superposes both axes.
- `free_edge_parallel`: `:c1` or `:c2`.  Default inferred from
  `col.boundary_edge_dirs` when present, otherwise `:c2`.

# Returns
Named tuple with `(ok, ratio, vu, φvc, b0, Jc, Mub)`
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
                                   θ::Union{Nothing, Real} = nothing)
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
                                            shape = geom_shape, λ = λ, ϕ = φ_shear, Mub_out = Mub)
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
                                        shape = geom_shape, λ = λ, ϕ = φ_shear, Mub_out = Mub)
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
                                   αs = αs_g, λ = λ, ϕ = φ_shear)
        if verbose
            status = g.ok ? "✓ PASS" : "✗ FAIL"
            @debug "Column $col_idx ($(kind) corner → general App. B)" c1=c1 c2=c2 b0=g.b0 β=round(β_g, digits=2) angle=round(col_corner_angle, digits=3)
            @debug "  Demand" Vu=Vu M_about_x=M_about_x M_about_y=M_about_y asymmetric=g.asymmetric θp=round(g.θp, digits=3)
            @debug "  Stress" vu=round(ustrip(u"psi", g.vu), digits=1) φvc=round(ustrip(u"psi", g.ϕvc), digits=1) ratio=round(g.utilization, digits=2) status=status
        end
        return (ok = g.ok, ratio = g.utilization, vu = g.vu, φvc = g.ϕvc,
                b0 = g.b0, Jc = g.J1, Mub = Mub)
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
    muy_present = !isnothing(Muy) && abs(ustrip(kip * u"ft", Muy_val)) > 1e-10

    if col.position == :interior
        Mub_adjusted = Mub
        e_centroid = zero(c1)
    elseif col.position == :edge
        # ACI 318-11 R11.11.7.2 (pages 209–211): moment about the axis
        # parallel to the free edge, after `_orient_edge_column`.
        # e = (b1 − cAB) − c1/2. See eccentricity_to_critical_centroid.
        e_centroid = eccentricity_to_critical_centroid(geom.b1, c1, cAB)
        Mub_adjusted = max(0.0kip*u"ft", abs(Mub) - Vu * e_centroid)
    else  # :corner — same centroid shift as punching_check (R11.11.7.2)
        e_centroid = eccentricity_to_critical_centroid(geom.b1, c1, geom.cAB_x)
        Mub_adjusted = max(0.0kip*u"ft", abs(Mub) - Vu * e_centroid)
    end

    b0 = geom.b0
    if col.position == :corner
        # Parity with punching_check: γv Mu c / Jc on each axis.
        # `Mub` is the span-direction (b1) transfer moment; optional `Muy`
        # is the perpendicular-axis moment when the caller has it.
        e_y = eccentricity_to_critical_centroid(geom.b2, c2, geom.cAB_y)
        Muy_adj = max(0.0kip*u"ft", abs(Muy_val) - Vu * e_y)
        γv_y = gamma_v(geom.b2, geom.b1)
        Jc_y = polar_moment_Jc_corner(geom.b2, geom.b1, d, geom.cAB_y)
        vu = uconvert(u"psi", Vu / (b0 * d)) +
             uconvert(u"psi", γv_val * Mub_adjusted * geom.cAB_x / Jc) +
             uconvert(u"psi", γv_y * Muy_adj * geom.cAB_y / Jc_y)
    elseif col.position == :interior && muy_present
        # Superpose both axes to match punching_check(; position=:interior).
        # Jc_x / γv_x from the cached 4-sided section; Jc_y / γv_y swap b1, b2.
        γv_y = gamma_v(geom.b2, geom.b1)
        Jc_y = polar_moment_Jc_interior(geom.b2, geom.b1, d)
        cAB_y = geom.b2 / 2
        vu = uconvert(u"psi", Vu / (b0 * d)) +
             uconvert(u"psi", γv_val * abs(Mub) * cAB / Jc) +
             uconvert(u"psi", γv_y * abs(Muy_val) * cAB_y / Jc_y)
    else
        vu = combined_punching_stress(Vu, Mub_adjusted, b0, d, γv_val, Jc, cAB)
    end
    
    vc = punching_capacity_stress(fc, β, αs, b0, d; λ=λ)
    φvc = φ_shear * vc
    
    ok = vu <= φvc
    ratio = ustrip(u"psi", vu) / ustrip(u"psi", φvc)
    
    if verbose
        status = ok ? "✓ PASS" : "✗ FAIL"
        @debug "Column $col_idx ($(col.position))" c1=c1 c2=c2 b0=b0 β=round(β, digits=2) αs=αs
        if col.position != :interior
            @debug "  Mub correction" Mub_original=Mub Mub_adjusted=Mub_adjusted e_centroid=e_centroid
        end
        @debug "  Demand" Vu=Vu γv=round(γv_val, digits=3) Mub=Mub_adjusted
        @debug "  Stress" vu=round(ustrip(u"psi", vu), digits=1) φvc=round(ustrip(u"psi", φvc), digits=1) ratio=round(ratio, digits=2) status=status
    end
    
    return (ok=ok, ratio=ratio, vu=vu, φvc=φvc, b0=b0, Jc=Jc, Mub=Mub)
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
    sec = drop_plan_section(col.c1, col.c2, a1, a2, d_slab, col.position, col_θ, span_axis;
                           swapped = swapped)
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
    
    vc = punching_capacity_stress(fc, β, αs, b0, d_slab; λ=λ)
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
                             flat_slab = flat_slab, column_strips = column_strips,
                             column_strip_half = column_strip_half)
    if b0_open !== nothing
        b0 = b0_open
        # §11.11.2.1(c) depends on b0/d, so the capacity moves with the cut.
        vc = punching_capacity_stress(fc, β, αs, b0, d_slab; λ=λ)
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
Named tuple `(ok, ratio, vu, φvc, b0, Jc, Mub, governing_section)` where
`governing_section` is `:column` or `:drop_edge`.

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
    if check_drop.ratio >= check_col.ratio
        return (ok=check_drop.ok, ratio=check_drop.ratio, vu=check_drop.vu,
                φvc=check_drop.φvc, b0=check_drop.b0, Jc=check_drop.Jc,
                Mub=Mub, governing_section=:drop_edge)
    else
        return (ok=check_col.ok, ratio=check_col.ratio, vu=check_col.vu,
                φvc=check_col.φvc, b0=check_col.b0, Jc=check_col.Jc,
                Mub=Mub, governing_section=:column)
    end
end

