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

For exterior columns, adjusts Mub for reaction eccentricity per StructurePoint:
    Mub_adjusted = Mub - Vu × e_centroid

where e_centroid is the distance from column centerline to critical section centroid.

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

# Returns
Named tuple with `(ok, ratio, vu, φvc, b0, Jc)`
"""
function check_punching_for_column(col, Vu, Mub, d, h, fc;
                                   verbose=false, col_idx=1, λ=1.0, φ_shear=0.75,
                                   _geom_cache::Union{Nothing, Dict} = nothing)
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
    
    # ── Geometry (cached: depends only on c1, c2, d, position, shape) ──
    cache_key = !isnothing(_geom_cache) ?
        (ustrip(u"m", c1), ustrip(u"m", c2), ustrip(u"m", d), col.position, geom_shape) :
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
            geom = punching_geometry_corner(c1, c2, d)
            cAB = max(geom.cAB_x, geom.cAB_y)
            Jc = polar_moment_Jc_edge(geom.b1, geom.b2, d, cAB) / 2
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
    if col.position == :interior
        Mub_adjusted = Mub
    elseif col.position == :edge
        e_centroid = c1 / 2 - cAB
        Mub_adjusted = max(0.0kip*u"ft", Mub - Vu * e_centroid)
    else  # :corner
        e_x = c1 / 2 - geom.cAB_x
        e_y = c2 / 2 - geom.cAB_y
        e_centroid = max(e_x, e_y)
        Mub_adjusted = max(0.0kip*u"ft", Mub - Vu * e_centroid)
    end
    
    b0 = geom.b0
    vu = combined_punching_stress(Vu, Mub_adjusted, b0, d, γv_val, Jc, cAB)
    
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
    
    return (ok=ok, ratio=ratio, vu=vu, φvc=φvc, b0=b0, Jc=Jc)
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
                                      verbose=false, col_idx=1, λ=1.0, φ_shear=0.75)
    # Critical section: d_slab/2 from drop panel edge
    # Drop panel plan dimensions: 2×a_drop_1 × 2×a_drop_2
    # Critical section dimensions (assuming interior):
    #   b1 = 2×a_drop_1 + d_slab (direction parallel to span)
    #   b2 = 2×a_drop_2 + d_slab (direction perpendicular to span)
    
    a1 = drop.a_drop_1
    a2 = drop.a_drop_2
    
    # Treat the drop panel as a "large column" for punching geometry.
    # The critical section is d/2 from the edge of the drop panel.
    if col.position == :interior
        b1 = 2 * a1 + d_slab
        b2 = 2 * a2 + d_slab
        b0 = 2 * (b1 + b2)
    elseif col.position == :edge
        b1 = a1 + d_slab / 2
        b2 = 2 * a2 + d_slab
        b0 = 2 * b1 + b2
    else  # :corner
        b1 = a1 + d_slab / 2
        b2 = a2 + d_slab / 2
        b0 = b1 + b2
    end
    
    # Reduce Vu by factored slab load within the critical section
    Vu_net = Vu
    if !isnothing(qu)
        A_crit = b1 * b2  # area enclosed by critical section
        Vu_net = max(Vu - qu * A_crit, 0.0 * Vu)
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

# Returns
Named tuple `(ok, ratio, vu, φvc, b0, Jc, governing_section)` where
`governing_section` is `:column` or `:drop_edge`.

# Reference
- ACI 318-11 §11.11.1.2
- StructurePoint DE-Two-Way-Flat-Slab
"""
function check_punching(col, Vu, Mub, h_slab, d_slab, h_total, d_total,
                                   fc, drop::DropPanelGeometry;
                                   qu = nothing,
                                   verbose=false, col_idx=1, λ=1.0, φ_shear=0.75)
    # Check 1: At column face with total depth
    check_col = check_punching_for_column(col, Vu, Mub, d_total, h_total, fc;
                                          verbose=verbose, col_idx=col_idx, λ=λ, φ_shear=φ_shear)
    
    # Check 2: At drop panel edge with slab depth (direct shear only, Vu reduced)
    check_drop = check_punching_at_drop_edge(col, Vu, Mub, h_slab, d_slab, fc, drop;
                                              qu=qu,
                                              verbose=verbose, col_idx=col_idx, λ=λ, φ_shear=φ_shear)
    
    # Governing check: higher ratio controls
    if check_drop.ratio >= check_col.ratio
        return (ok=check_drop.ok, ratio=check_drop.ratio, vu=check_drop.vu,
                φvc=check_drop.φvc, b0=check_drop.b0, Jc=check_drop.Jc,
                governing_section=:drop_edge)
    else
        return (ok=check_col.ok, ratio=check_col.ratio, vu=check_col.vu,
                φvc=check_col.φvc, b0=check_col.b0, Jc=check_col.Jc,
                governing_section=:column)
    end
end

# =============================================================================
# Two-Way Deflection Check (ACI 318-11 §9.5.2.6)
# =============================================================================

"""
    check_two_way_deflection(moment_results, h, d, fc, fy, Es, Ecs, spans, γ_concrete,
                             columns; verbose, limit_type, rotation_factor, As_provided) -> NamedTuple

Two-way deflection check per ACI 318-11 §9.5.2.6.

## Deflection source — auto-selected

- **FEA**: When `moment_results.fea_Δ_panel` is set, the max mid-panel displacement
  comes directly from FEA nodal displacements (factored load, gross section).
  This is scaled to service levels by load ratio (linear elastic) and corrected
  for cracking via Ig/Ie.  No crossing-beam approximation needed — the 2D
  displacement already captures both-direction effects.

- **DDM / EFM**: Falls back to the PCA crossing-beam method (frame → strip → panel)
  with load distribution factors and a simplified rotation contribution.

Both paths share the same long-term creep/shrinkage calculation (ACI 24.2.4)
and the same ACI Table 24.2.2 limit comparisons.

# Arguments
- `moment_results`: `MomentAnalysisResult` (carries M_pos, qD, qL, qu, l1, l2, ln,
  and optionally `fea_Δ_panel` for FEA-based deflection)
- `h`: Slab thickness
- `d`: Effective depth
- `fc`, `fy`, `Es`, `Ecs`: Material properties
- `spans`: Slab spans `(primary, secondary)`
- `γ_concrete`: Concrete density (mass density, e.g. 150 pcf)
- `columns`: Supporting columns (for position classification)

# Keyword Arguments
- `verbose`: Enable debug logging (default `false`)
- `limit_type`: `:L_360` (default, LL only), `:L_240` (after construction), or `:L_480`
- `rotation_factor`: Multiplier on fixed-end deflection for joint rotation
  contribution (default `0.10`). Only used by the crossing-beam path (DDM/EFM).
- `ξ`: ACI 24.2.4.1 time-dependent factor (default `2.0` for ≥ 5 years)
- `ρ_prime`: Compression reinforcement ratio at midspan (default `0.0`)
- `As_provided`: Actual provided reinforcement area for cracked I calculation.
  If `nothing` (default), estimates from `required_reinforcement(M_pos, l2, d, fc, fy)`
  bounded below by `minimum_reinforcement(l2, h, fy)`.

# Returns
Named tuple: `(ok, Δ_check, Δ_total, Δ_limit, Δ_panel_D, Δ_panel_DL,
               Δi_live, Δ_creep, λ_Δ, Δcx_D, Δmx_D, Δcx_DL, Δmx_DL,
               LDF_c, LDF_m, Ie_D, Ie_DL, Mcr)`
"""
function check_two_way_deflection(
    moment_results, h, d, fc, fy, Es, Ecs, spans, γ_concrete, columns;
    verbose::Bool      = false,
    limit_type::Symbol = :L_360,
    rotation_factor    = 0.10,
    ξ::Float64         = 2.0,
    ρ_prime::Float64   = 0.0,
    As_provided        = nothing
)
    l1 = spans.primary
    l2 = spans.secondary

    has_exterior = any(col.position != :interior for col in columns)
    position = has_exterior ? :exterior : :interior

    # ── Section properties ──
    Ig_frame = slab_moment_of_inertia(l2, h)         # full frame strip
    Ig_half  = slab_moment_of_inertia(l2 / 2, h)     # half-width strip
    Ig_cs    = Ig_half                                 # column strip
    Ig_ms    = Ig_half                                 # middle strip

    # ── Cracking check ──
    fr_val = fr(fc)
    Mcr    = cracking_moment(fr_val, Ig_frame, h)

    # ── Service moments (scale factored moments by load ratios) ──
    qu_val  = ustrip(psf, moment_results.qu)          # factored load (already stored)
    qD_val  = ustrip(psf, moment_results.qD)
    qDL_val = ustrip(psf, moment_results.qD + moment_results.qL)

    # Midspan positive moment (service)
    Ma_D_mid  = moment_results.M_pos * (qD_val  / qu_val)
    Ma_DL_mid = moment_results.M_pos * (qDL_val / qu_val)

    # Support negative moment (service) — envelope of exterior and interior
    M_neg_max = max(moment_results.M_neg_ext, moment_results.M_neg_int)
    Ma_D_sup  = M_neg_max * (qD_val  / qu_val)
    Ma_DL_sup = M_neg_max * (qDL_val / qu_val)

    # ── Reinforcement for cracked I ──
    As_min = minimum_reinforcement(l2, h, fy)

    # Midspan (positive) reinforcement estimate
    As_mid = if isnothing(As_provided)
        As_reqd = required_reinforcement(moment_results.M_pos, l2, d, fc, fy)
        max(As_reqd, As_min)
    else
        max(As_provided, As_min)
    end
    Icr_mid = cracked_moment_of_inertia(As_mid, l2, d, Ecs, Es)

    # Support (negative) reinforcement estimate
    As_neg = max(required_reinforcement(M_neg_max, l2, d, fc, fy), As_min)
    Icr_sup = cracked_moment_of_inertia(As_neg, l2, d, Ecs, Es)

    # ── Effective I at each section (Branson's equation) ──
    Ie_mid_D  = effective_moment_of_inertia(Mcr, Ma_D_mid,  Ig_frame, Icr_mid)
    Ie_mid_DL = effective_moment_of_inertia(Mcr, Ma_DL_mid, Ig_frame, Icr_mid)
    Ie_sup_D  = effective_moment_of_inertia(Mcr, Ma_D_sup,  Ig_frame, Icr_sup)
    Ie_sup_DL = effective_moment_of_inertia(Mcr, Ma_DL_sup, Ig_frame, Icr_sup)

    # ── ACI 435R-95 weighted average (accounts for support cracking) ──
    Ie_D  = weighted_effective_Ie(Ie_mid_D,  Ie_sup_D,  Ie_sup_D;  position=position)
    Ie_DL = weighted_effective_Ie(Ie_mid_DL, Ie_sup_DL, Ie_sup_DL; position=position)

    # ── Long-term factor: λ_Δ = ξ / (1 + 50ρ') ──
    λ_Δ = long_term_deflection_factor(ξ, ρ_prime)

    # ── Load distribution factors (ACI 8.10.5 weighted averages) ──
    LDF_c = load_distribution_factor(:column, position)
    LDF_m = load_distribution_factor(:middle, position)

    # ════════════════════════════════════════════════════════════════════════
    # Branch: FEA direct displacement vs. crossing-beam approximation
    # ════════════════════════════════════════════════════════════════════════
    fea_Δ = hasproperty(moment_results, :fea_Δ_panel) ? moment_results.fea_Δ_panel : nothing

    if !isnothing(fea_Δ)
        # ── FEA path: use actual nodal displacements ──
        # The FEA model was solved at factored load (qu) with gross section (Ig).
        # Linear elastic → deflection ∝ load.  Scale to service levels, then
        # apply Ig/Ie cracking correction (Ie ≤ Ig → ratio ≥ 1.0 → more deflection).
        ratio_D  = qD_val  / qu_val
        ratio_DL = qDL_val / qu_val

        Δ_panel_D  = uconvert(u"inch", fea_Δ * ratio_D  * (Ig_frame / Ie_D))
        Δ_panel_DL = uconvert(u"inch", fea_Δ * ratio_DL * (Ig_frame / Ie_DL))

        # Strip-level breakdown not meaningful for FEA (the 2D displacement
        # already captures both-direction effects).  Report panel totals.
        Δcx_D  = Δ_panel_D  * LDF_c
        Δmx_D  = Δ_panel_D  * LDF_m
        Δcx_DL = Δ_panel_DL * LDF_c
        Δmx_DL = Δ_panel_DL * LDF_m

        if verbose
            @debug "DEFLECTION — FEA direct" Δ_fea_factored=uconvert(u"inch", fea_Δ) ratio_D=round(ratio_D, digits=3) ratio_DL=round(ratio_DL, digits=3) Ig_Ie_D=round(ustrip(Ig_frame/Ie_D), digits=2) Ig_Ie_DL=round(ustrip(Ig_frame/Ie_DL), digits=2)
        end
    else
        # ── Crossing-beam path (DDM / EFM) ──
        w_D  = moment_results.qD * l2
        w_DL = (moment_results.qD + moment_results.qL) * l2

        Δ_frame_D  = frame_deflection_fixed(w_D,  l1, Ecs, Ie_D)
        Δ_frame_DL = frame_deflection_fixed(w_DL, l1, Ecs, Ie_DL)

        Δc_fixed_D  = strip_deflection_fixed(Δ_frame_D,  LDF_c, Ie_D,  Ig_cs)
        Δm_fixed_D  = strip_deflection_fixed(Δ_frame_D,  LDF_m, Ie_D,  Ig_ms)
        Δc_fixed_DL = strip_deflection_fixed(Δ_frame_DL, LDF_c, Ie_DL, Ig_cs)
        Δm_fixed_DL = strip_deflection_fixed(Δ_frame_DL, LDF_m, Ie_DL, Ig_ms)

        Δcx_D  = uconvert(u"inch", Δc_fixed_D  * (1 + rotation_factor))
        Δmx_D  = uconvert(u"inch", Δm_fixed_D  * (1 + rotation_factor))
        Δcx_DL = uconvert(u"inch", Δc_fixed_DL * (1 + rotation_factor))
        Δmx_DL = uconvert(u"inch", Δm_fixed_DL * (1 + rotation_factor))

        Δ_panel_D  = two_way_panel_deflection(Δcx_D,  Δmx_D)
        Δ_panel_DL = two_way_panel_deflection(Δcx_DL, Δmx_DL)
    end

    # ── Deflection components per ACI Table 24.2.2 ──
    Δi_live       = Δ_panel_DL - Δ_panel_D            # immediate live load
    Δ_creep       = Δ_panel_D  * λ_Δ                   # long-term creep+shrinkage (dead)
    Δ_after_const = Δi_live + Δ_creep                  # after attachment of partitions
    Δ_total       = Δ_panel_D + Δ_after_const          # total from day 1

    # ── ACI Table 24.2.2 limit comparison ──
    if limit_type == :L_240
        Δ_check = Δ_after_const
        Δ_limit = deflection_limit(l1, :total)
    elseif limit_type == :L_480
        Δ_check = Δ_after_const
        Δ_limit = deflection_limit(l1, :sensitive)
    else  # :L_360 (default)
        Δ_check = Δi_live
        Δ_limit = deflection_limit(l1, :immediate_ll)
    end
    ok = Δ_check <= Δ_limit

    if verbose
        status = ok ? "✓ PASS" : "✗ FAIL"
        src = isnothing(fea_Δ) ? "crossing-beam" : "FEA direct"
        @debug "Section (mid)" Ig=Ig_frame Icr_mid=Icr_mid Ie_mid_DL=Ie_mid_DL
        @debug "Section (sup)" Ig=Ig_frame Icr_sup=Icr_sup Ie_sup_DL=Ie_sup_DL
        @debug "Weighted Ie" Ie_D=Ie_D Ie_DL=Ie_DL Ie_Ig=round(ustrip(Ie_DL / Ig_frame), digits=3)
        @debug "Service moments" Ma_mid=uconvert(kip*u"ft", Ma_DL_mid) Ma_sup=uconvert(kip*u"ft", Ma_DL_sup) Mcr=uconvert(kip*u"ft", Mcr)
        @debug "LDF" LDF_c=round(LDF_c, digits=3) LDF_m=round(LDF_m, digits=3) position=position
        @debug "Strip (D)"  Δcx=Δcx_D  Δmx=Δmx_D  panel=Δ_panel_D
        @debug "Strip (D+L)" Δcx=Δcx_DL Δmx=Δmx_DL panel=Δ_panel_DL
        @debug "Components" Δi_live=Δi_live Δ_creep=Δ_creep λ_Δ=λ_Δ Δ_total=Δ_total
        @debug "Check ($limit_type, $src)" Δ_check=Δ_check Δ_limit=Δ_limit ratio=round(ustrip(Δ_check)/ustrip(Δ_limit), digits=3) status=status
    end

    return (
        ok          = ok,
        Δ_check     = Δ_check,
        Δ_total     = Δ_total,
        Δ_limit     = Δ_limit,
        Δ_panel_D   = Δ_panel_D,
        Δ_panel_DL  = Δ_panel_DL,
        Δi_live     = Δi_live,
        Δ_creep     = Δ_creep,
        λ_Δ         = λ_Δ,
        Δcx_D       = Δcx_D,
        Δmx_D       = Δmx_D,
        Δcx_DL      = Δcx_DL,
        Δmx_DL      = Δmx_DL,
        LDF_c       = LDF_c,
        LDF_m       = LDF_m,
        Ie_D        = Ie_D,
        Ie_DL       = Ie_DL,
        Mcr         = Mcr,
    )
end

# =============================================================================
# Non-Prismatic Effective I Averaging (ACI 435R-95 — Flat Slab)
# =============================================================================

"""
    weighted_effective_Ie(Ie_midspan, Ie_left, Ie_right; position=:interior)

Weighted effective moment of inertia for non-prismatic members (ACI 435R-95).

For continuous spans with non-prismatic sections (e.g., drop panels),
the effective I varies along the span. ACI 435R-95 provides a weighted average:

**Interior spans:**
    Ie_avg = 0.70 × Ie_midspan + 0.15 × (Ie_left + Ie_right)

**End spans:**
    Ie_avg = 0.85 × Ie_midspan + 0.15 × Ie_continuous_support

These weights give more influence to the midspan section (where the slab
is thin) and less to the supports (where drop panels increase I).

# Arguments
- `Ie_midspan`: Effective I at midspan (slab thickness only)
- `Ie_left`: Effective I at left support (may be composite with drop)
- `Ie_right`: Effective I at right support (may be composite with drop)
- `position`: `:interior` or `:exterior` (end span)

# Reference
- ACI 435R-95 Eq. 4-1a and 4-1b
- StructurePoint DE-Two-Way-Flat-Slab:
    Interior: Ie_avg = 0.70 × Ie_m + 0.15 × (Ie_1 + Ie_2)
"""
function weighted_effective_Ie(Ie_midspan, Ie_left, Ie_right; position::Symbol=:interior)
    if position == :interior
        return 0.70 * Ie_midspan + 0.15 * (Ie_left + Ie_right)
    else  # :exterior or :end
        # Use the continuous-end support (larger Ie)
        Ie_cont = max(Ie_left, Ie_right)
        return 0.85 * Ie_midspan + 0.15 * Ie_cont
    end
end

"""
    check_two_way_deflection(moment_results, h_slab, d_slab, fc, fy, Es, Ecs,
                              spans, γ_concrete, columns, drop::DropPanelGeometry;
                              kwargs...) -> NamedTuple

Two-way deflection check for flat slab with drop panels per ACI 318-11 §9.5.2.6
and ACI 435R-95 for non-prismatic I_e averaging.

Extends the base `check_two_way_deflection` by:
1. Computing I_g and I_cr at both midspan (slab only) and support (composite drop+slab)
2. Using ACI 435R-95 weighted average: Ie_avg = 0.70 Ie_m + 0.15(Ie_1 + Ie_2) for interior
3. Using the composite I_g at supports in the Ie calculation

Otherwise follows the same crossing-beam or FEA-direct path.

# Additional Arguments
- `drop`: Drop panel geometry for composite section properties

# Reference
- ACI 435R-95 Eq. 4-1a, 4-1b
- StructurePoint DE-Two-Way-Flat-Slab (Deflection section)
"""
function check_two_way_deflection(
    moment_results, h_slab, d_slab, fc, fy, Es, Ecs, spans, γ_concrete, columns,
    drop::DropPanelGeometry;
    verbose::Bool      = false,
    limit_type::Symbol = :L_360,
    rotation_factor    = 0.10,
    ξ::Float64         = 2.0,
    ρ_prime::Float64   = 0.0,
    As_provided        = nothing,
)
    l1 = spans.primary
    l2 = spans.secondary

    has_exterior = any(col.position != :interior for col in columns)
    position = has_exterior ? :exterior : :interior

    # ── Midspan section properties (slab only) ──
    Ig_mid = slab_moment_of_inertia(l2, h_slab)

    # ── Support section properties (composite drop + slab) ──
    gs = gross_section_at_drop(l2, h_slab, drop)
    Ig_support = gs.Ig

    # ── Cracking ──
    fr_val = fr(fc)
    # At midspan: cracking based on slab Ig
    Mcr_mid = cracking_moment(fr_val, Ig_mid, h_slab)
    # At support: cracking based on composite Ig (use yt from composite centroid)
    Mcr_supp = fr_val * Ig_support / gs.yt

    # ── Service moments ──
    qu_val  = ustrip(psf, moment_results.qu)
    qD_val  = ustrip(psf, moment_results.qD)
    qDL_val = ustrip(psf, moment_results.qD + moment_results.qL)

    # Midspan positive moment (service)
    Ma_D_mid  = moment_results.M_pos * (qD_val / qu_val)
    Ma_DL_mid = moment_results.M_pos * (qDL_val / qu_val)

    # Support negative moment (service) — use envelope
    M_neg_max = max(moment_results.M_neg_ext, moment_results.M_neg_int)
    Ma_D_sup  = M_neg_max * (qD_val / qu_val)
    Ma_DL_sup = M_neg_max * (qDL_val / qu_val)

    # ── Reinforcement for cracked I ──
    As_min = minimum_reinforcement(l2, h_slab, fy)
    As_est = if isnothing(As_provided)
        As_reqd = required_reinforcement(moment_results.M_pos, l2, d_slab, fc, fy)
        max(As_reqd, As_min)
    else
        max(As_provided, As_min)
    end

    # Cracked I at midspan
    Icr_mid = cracked_moment_of_inertia(As_est, l2, d_slab, Ecs, Es)
    
    # Cracked I at support (use total depth for effective depth)
    h_total = total_depth_at_drop(h_slab, drop)
    d_total = h_total - (h_slab - d_slab)  # same cover
    As_neg = max(required_reinforcement(M_neg_max, l2, d_total, fc, fy), As_min)
    Icr_sup = cracked_moment_of_inertia(As_neg, l2, d_total, Ecs, Es)

    # ── Effective I at each section ──
    Ie_mid_D  = effective_moment_of_inertia(Mcr_mid, Ma_D_mid,  Ig_mid, Icr_mid)
    Ie_mid_DL = effective_moment_of_inertia(Mcr_mid, Ma_DL_mid, Ig_mid, Icr_mid)
    Ie_sup_D  = effective_moment_of_inertia(Mcr_supp, Ma_D_sup,  Ig_support, Icr_sup)
    Ie_sup_DL = effective_moment_of_inertia(Mcr_supp, Ma_DL_sup, Ig_support, Icr_sup)

    # ── ACI 435R-95 weighted average ──
    Ie_D  = weighted_effective_Ie(Ie_mid_D,  Ie_sup_D,  Ie_sup_D;  position=position)
    Ie_DL = weighted_effective_Ie(Ie_mid_DL, Ie_sup_DL, Ie_sup_DL; position=position)

    # ── Long-term factor ──
    λ_Δ = long_term_deflection_factor(ξ, ρ_prime)

    # ── Load distribution factors ──
    LDF_c = load_distribution_factor(:column, position)
    LDF_m = load_distribution_factor(:middle, position)

    # ── Deflection calculation (same branching as flat plate) ──
    fea_Δ = hasproperty(moment_results, :fea_Δ_panel) ? moment_results.fea_Δ_panel : nothing

    if !isnothing(fea_Δ)
        ratio_D  = qD_val / qu_val
        ratio_DL = qDL_val / qu_val
        Δ_panel_D  = uconvert(u"inch", fea_Δ * ratio_D  * (Ig_mid / Ie_D))
        Δ_panel_DL = uconvert(u"inch", fea_Δ * ratio_DL * (Ig_mid / Ie_DL))
        Δcx_D  = Δ_panel_D  * LDF_c
        Δmx_D  = Δ_panel_D  * LDF_m
        Δcx_DL = Δ_panel_DL * LDF_c
        Δmx_DL = Δ_panel_DL * LDF_m
    else
        w_D  = moment_results.qD * l2
        w_DL = (moment_results.qD + moment_results.qL) * l2
        Δ_frame_D  = frame_deflection_fixed(w_D,  l1, Ecs, Ie_D)
        Δ_frame_DL = frame_deflection_fixed(w_DL, l1, Ecs, Ie_DL)
        Ig_cs = slab_moment_of_inertia(l2 / 2, h_slab)
        Ig_ms = slab_moment_of_inertia(l2 / 2, h_slab)
        Δc_fixed_D  = strip_deflection_fixed(Δ_frame_D,  LDF_c, Ie_D,  Ig_cs)
        Δm_fixed_D  = strip_deflection_fixed(Δ_frame_D,  LDF_m, Ie_D,  Ig_ms)
        Δc_fixed_DL = strip_deflection_fixed(Δ_frame_DL, LDF_c, Ie_DL, Ig_cs)
        Δm_fixed_DL = strip_deflection_fixed(Δ_frame_DL, LDF_m, Ie_DL, Ig_ms)
        Δcx_D  = uconvert(u"inch", Δc_fixed_D  * (1 + rotation_factor))
        Δmx_D  = uconvert(u"inch", Δm_fixed_D  * (1 + rotation_factor))
        Δcx_DL = uconvert(u"inch", Δc_fixed_DL * (1 + rotation_factor))
        Δmx_DL = uconvert(u"inch", Δm_fixed_DL * (1 + rotation_factor))
        Δ_panel_D  = two_way_panel_deflection(Δcx_D,  Δmx_D)
        Δ_panel_DL = two_way_panel_deflection(Δcx_DL, Δmx_DL)
    end

    # ── Deflection components per ACI Table 24.2.2 ──
    Δi_live       = Δ_panel_DL - Δ_panel_D
    Δ_creep       = Δ_panel_D * λ_Δ
    Δ_after_const = Δi_live + Δ_creep
    Δ_total       = Δ_panel_D + Δ_after_const

    if limit_type == :L_240
        Δ_check = Δ_after_const
        Δ_limit = deflection_limit(l1, :total)
    elseif limit_type == :L_480
        Δ_check = Δ_after_const
        Δ_limit = deflection_limit(l1, :sensitive)
    else
        Δ_check = Δi_live
        Δ_limit = deflection_limit(l1, :immediate_ll)
    end
    ok = Δ_check <= Δ_limit

    if verbose
        src = isnothing(fea_Δ) ? "crossing-beam" : "FEA direct"
        status = ok ? "✓ PASS" : "✗ FAIL"
        @debug "DEFLECTION (flat slab) — $src" Ig_mid=Ig_mid Ig_support=Ig_support
        @debug "  Ie weighted (ACI 435R-95)" Ie_D=Ie_D Ie_DL=Ie_DL
        @debug "  Check ($limit_type)" Δ_check=Δ_check Δ_limit=Δ_limit status=status
    end

    return (
        ok=ok, Δ_check=Δ_check, Δ_total=Δ_total, Δ_limit=Δ_limit,
        Δ_panel_D=Δ_panel_D, Δ_panel_DL=Δ_panel_DL,
        Δi_live=Δi_live, Δ_creep=Δ_creep, λ_Δ=λ_Δ,
        Δcx_D=Δcx_D, Δmx_D=Δmx_D, Δcx_DL=Δcx_DL, Δmx_DL=Δmx_DL,
        LDF_c=LDF_c, LDF_m=LDF_m,
        Ie_D=Ie_D, Ie_DL=Ie_DL, Mcr=Mcr_mid,
    )
end

# =============================================================================
# One-Way Shear Check (ACI 318-11 §11.2)
# =============================================================================

"""
    check_one_way_shear(moment_results, d, fc; verbose=false, λ=1.0, φ_shear=0.75) -> NamedTuple

Check one-way (beam) shear at the critical section (distance d from column face)
per ACI 318-11 §11.2.

# Returns
Named tuple with `(ok, ratio, Vu, Vc, message)`
"""
function check_one_way_shear(moment_results, d, fc; verbose=false, λ=1.0, φ_shear=0.75)
    l2 = moment_results.l2
    ln = moment_results.ln
    qu = moment_results.qu
    
    # Shear at critical section d from face of support (ACI 22.5.1.2)
    Vu = one_way_shear_demand(qu, l2, ln, d)
    Vc = one_way_shear_capacity(fc, l2, d; λ=λ)
    result = StructuralSizer.check_one_way_shear(Vu, Vc; φ=φ_shear)
    
    if verbose
        status = result.ok ? "✓ PASS" : "✗ FAIL"
        φVc = φ_shear * Vc
        @debug "One-way shear" Vu=Vu Vc=Vc φVc=φVc ratio=round(result.ratio, digits=2) status=status
    end
    
    return (ok=result.ok, ratio=result.ratio, Vu=Vu, Vc=Vc, message=result.message)
end

# =============================================================================
# Flexural Adequacy Check (ACI 318-11 §9.3.2)
# =============================================================================

"""
    check_flexural_adequacy(moment_results, columns, d, fc; verbose=false) -> NamedTuple

Verify that all strip locations remain tension-controlled (Rn ≤ Rn_max).

Computes the resistance coefficient Rn = Mu / (φ·b·d²) for each strip and
compares against the tension-controlled limit Rn_max = 0.319·β₁·f'c.  If any
strip exceeds the limit the section needs more depth.

Uses the same ACI 8.10.5 transverse distribution as `design_strip_reinforcement`:
exterior negative → 100 % column strip; interior negative → 75 / 25 %;
positive → 60 / 40 %.

# Returns
Named tuple `(ok, max_ratio, governing_strip)` where
- `ok::Bool`:  true when all strips satisfy Rn ≤ Rn_max
- `max_ratio`: worst-case Rn / Rn_max across all strips
- `governing_strip`: symbol identifying the controlling location
"""
function check_flexural_adequacy(moment_results, columns, d, fc; verbose=false)
    φ = 0.9
    β = beta1(fc)
    Rn_max = 0.319 * β * fc   # tension-controlled limit (units of pressure)

    l2 = moment_results.l2
    cs_width = l2 / 2   # column strip width
    ms_width = l2 / 2   # middle strip width

    # Derive strip design moments (mirrors design_strip_reinforcement)
    zero_M = zero(moment_results.M0)
    M_neg_ext_cs = zero_M
    M_neg_int_cs = zero_M
    M_neg_int_ms = zero_M

    for (i, col) in enumerate(columns)
        m = moment_results.column_moments[i]
        if col.position == :interior
            M_neg_int_cs = max(M_neg_int_cs, 0.75 * m)
            M_neg_int_ms = max(M_neg_int_ms, 0.25 * m)
        else
            M_neg_ext_cs = max(M_neg_ext_cs, 1.00 * m)
        end
    end

    M_pos_cs = 0.60 * moment_results.M_pos
    M_pos_ms = 0.40 * moment_results.M_pos

    # Collect (label, Mu, strip width) for every strip location
    strips = [
        (:ext_neg_cs,  M_neg_ext_cs, cs_width),
        (:int_neg_cs,  M_neg_int_cs, cs_width),
        (:pos_cs,      M_pos_cs,     cs_width),
        (:int_neg_ms,  M_neg_int_ms, ms_width),
        (:pos_ms,      M_pos_ms,     ms_width),
    ]

    max_ratio = 0.0
    governing = :none

    for (label, Mu, b) in strips
        Rn = Mu / (φ * b * d^2)
        ratio = ustrip(Rn / Rn_max)   # dimensionless
        if ratio > max_ratio
            max_ratio = ratio
            governing = label
        end
    end

    ok = max_ratio ≤ 1.0

    if verbose
        status = ok ? "✓ PASS" : "✗ FAIL"
        @debug "Flexural adequacy (tension-controlled)" Rn_max=Rn_max max_ratio=round(max_ratio, digits=3) governing=governing status=status
    end

    return (ok=ok, max_ratio=max_ratio, governing_strip=governing)
end

