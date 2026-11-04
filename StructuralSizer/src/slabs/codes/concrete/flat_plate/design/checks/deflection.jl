# =============================================================================
# Two-Way Deflection Check (ACI 318-11 §9.5.2.6)
# =============================================================================

"""
Steel area for the cracked `I` estimate: `max(As_reqd, As_min)`, or `As_min`
when `required_reinforcement` reported an inadequate section (`Inf`).  Less
steel gives a smaller `Icr`, so the fallback over-predicts deflection.
"""
_deflection_As(As_reqd, As_min) = isfinite(As_reqd) ? max(As_reqd, As_min) : As_min

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
    As_provided        = nothing,
    deflection_Ie_method::Symbol = :branson,
)
    l1 = spans.primary
    l2 = spans.secondary

    has_exterior = any(col.position != :interior for col in columns)
    position = has_exterior ? :exterior : :interior

    # ── Section properties ──
    # ACI 318-11 §13.2.1 / §13.2.2 — column-strip width = min(ℓ1, ℓ2)/2;
    # middle strip occupies the remainder of ℓ2.
    cs_width = min(l1, l2) / 2
    ms_width = l2 - cs_width
    Ig_frame = slab_moment_of_inertia(l2, h)            # full frame strip
    Ig_cs    = slab_moment_of_inertia(cs_width, h)      # column strip
    Ig_ms    = slab_moment_of_inertia(ms_width, h)      # middle strip

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
        _deflection_As(required_reinforcement(moment_results.M_pos, l2, d, fc, fy), As_min)
    else
        max(As_provided, As_min)
    end
    Icr_mid = cracked_moment_of_inertia(As_mid, l2, d, Ecs, Es)

    # Support (negative) reinforcement estimate
    As_neg = _deflection_As(required_reinforcement(M_neg_max, l2, d, fc, fy), As_min)
    Icr_sup = cracked_moment_of_inertia(As_neg, l2, d, Ecs, Es)

    # ── Effective I at each section ──
    _Ie = deflection_Ie_method === :bischoff ?
        effective_moment_of_inertia_bischoff : effective_moment_of_inertia
    Ie_mid_D  = _Ie(Mcr, Ma_D_mid,  Ig_frame, Icr_mid)
    Ie_mid_DL = _Ie(Mcr, Ma_DL_mid, Ig_frame, Icr_mid)
    Ie_sup_D  = _Ie(Mcr, Ma_D_sup,  Ig_frame, Icr_sup)
    Ie_sup_DL = _Ie(Mcr, Ma_DL_sup, Ig_frame, Icr_sup)

    # ── ACI 435R-95 Eq. 4-1a/b weighted average (NOT ACI 318-11 §9.5.2.4,
    # which permits a simple average of Eq. 9-8; corpus: aci-318-11, page 132) ──
    Ie_D  = weighted_effective_Ie(Ie_mid_D,  Ie_sup_D,  Ie_sup_D;  position=position)
    Ie_DL = weighted_effective_Ie(Ie_mid_DL, Ie_sup_DL, Ie_sup_DL; position=position)

    # ── Long-term factor: λ_Δ = ξ / (1 + 50ρ') ──
    λ_Δ = long_term_deflection_factor(ξ, ρ_prime)

    # ── Load distribution factors (ACI 318-11 §13.6.4/.6 weighted averages) ──
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
- ACI 435R-95 Eq. 4-1a and 4-1b (not in the curated corpus; coefficients
  are the existing project citation for this weighted form).
- ACI 318-11 §9.5.2.4 (corpus: aci-318-11, page 132) permits a *simple
  average* of Eq. (9-8) at the critical positive and negative sections as
  an alternative. It does **not** prescribe the 0.70 / 0.15 / 0.15
  weights; those are ACI 435R-95, not §9.5.2.4.
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
    deflection_Ie_method::Symbol = :branson,
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
        _deflection_As(required_reinforcement(moment_results.M_pos, l2, d_slab, fc, fy), As_min)
    else
        max(As_provided, As_min)
    end

    # Cracked I at midspan
    Icr_mid = cracked_moment_of_inertia(As_est, l2, d_slab, Ecs, Es)
    
    # Cracked I at support (use total depth for effective depth)
    h_total = total_depth_at_drop(h_slab, drop)
    d_total = h_total - (h_slab - d_slab)  # same cover
    As_neg = _deflection_As(required_reinforcement(M_neg_max, l2, d_total, fc, fy), As_min)
    Icr_sup = cracked_moment_of_inertia(As_neg, l2, d_total, Ecs, Es)

    # ── Effective I at each section ──
    _Ie = deflection_Ie_method === :bischoff ?
        effective_moment_of_inertia_bischoff : effective_moment_of_inertia
    Ie_mid_D  = _Ie(Mcr_mid, Ma_D_mid,  Ig_mid, Icr_mid)
    Ie_mid_DL = _Ie(Mcr_mid, Ma_DL_mid, Ig_mid, Icr_mid)
    Ie_sup_D  = _Ie(Mcr_supp, Ma_D_sup,  Ig_support, Icr_sup)
    Ie_sup_DL = _Ie(Mcr_supp, Ma_DL_sup, Ig_support, Icr_sup)

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
        # ACI 318-11 §13.2.1 / §13.2.2 — column strip = min(ℓ1,ℓ2)/2;
        # middle strip = remainder of ℓ2.
        cs_width = min(l1, l2) / 2
        ms_width = l2 - cs_width
        Ig_cs = slab_moment_of_inertia(cs_width, h_slab)
        Ig_ms = slab_moment_of_inertia(ms_width, h_slab)
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

