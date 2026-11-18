# ║            STEEL HSS BEAM NLP PROBLEM  (AISC 360-16 F7/G4)               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Dedicated beam formulation for rectangular HSS (closed section — no LTB).
#
# Design variables: [B, H, t] (outer width, outer height, wall thickness)
# Objective: Minimize cross-sectional area
# Constraints: Mu/φMn ≤ 1.0, Vu/φVn ≤ 1.0, b/t fabrication limit

"""
    SteelHSSBeamNLPProblem <: AbstractNLPProblem

Continuous optimization for rectangular HSS beam sizing (pure flexure + shear).

Uses smooth AISC F7 (compact HSS flexure) and G4 (shear) formulations.
Closed HSS sections are not susceptible to LTB.

# Design Variables
- `x[1]` = B: Outer width (inches)
- `x[2]` = H: Outer height/depth (inches)
- `x[3]` = t: Wall thickness (inches)

# Constraints
- Flexure utilization: Mu / φMn ≤ 1.0
- Shear utilization: Vu / φVn ≤ 1.0
- Width-to-thickness: fabrication limit
- Deflection: Ix_min / Ix ≤ 1.0 (if Ix_min > 0)
"""
struct SteelHSSBeamNLPProblem <: AbstractNLPProblem
    opts::NLPHSSOptions
    
    E_ksi::Float64
    Fy_ksi::Float64
    
    Mu_kipft::Float64
    Vu_kip::Float64
    
    # Deflection: minimum required Ix for LL (in⁴). 0.0 = no check.
    Ix_min_in4::Float64
    # Deflection: minimum required Ix for DL+LL total (in⁴). 0.0 = no check.
    Ix_min_total_in4::Float64
    
    Tu_kipin::Float64
    
    # Bounds in inches
    B_min::Float64
    B_max::Float64
    t_min::Float64
    t_max::Float64
end

"""
    SteelHSSBeamNLPProblem(Mu, Vu, opts; Ix_min, Tu)

Construct a steel HSS beam NLP problem from factored demands and options.
Converts Unitful inputs to bare AISC units (kip, kip-ft, inches, ksi).
"""
function SteelHSSBeamNLPProblem(
    Mu, Vu,
    opts::NLPHSSOptions;
    Ix_min = nothing,
    Ix_min_total = nothing,
    Tu = 0.0,
)
    _require_nlp_objective(
        opts.objective, (MinWeight,); problem="steel HSS beam NLP")
    E_ksi = to_ksi(opts.material.E)
    Fy_ksi = to_ksi(opts.material.Fy)
    
    Mu_kipft = to_kipft(Mu)
    Vu_kip = to_kip(Vu)
    
    Ix_min_in4 = if isnothing(Ix_min)
        0.0
    elseif Ix_min isa Unitful.Quantity
        ustrip(u"inch^4", Ix_min)
    else
        Float64(Ix_min)
    end
    
    Ix_min_total_in4 = if isnothing(Ix_min_total)
        0.0
    elseif Ix_min_total isa Unitful.Quantity
        ustrip(u"inch^4", Ix_min_total)
    else
        Float64(Ix_min_total)
    end
    
    # Torsion demand
    Tu_kipin_val = if Tu isa Unitful.Quantity
        abs(ustrip(u"lbf*inch", Tu)) / 1000.0
    else
        abs(Float64(Tu))
    end
    
    B_min = to_inches(opts.min_outer)
    B_max = to_inches(opts.max_outer)
    t_min = to_inches(opts.min_thickness)
    t_max = to_inches(opts.max_thickness)
    
    SteelHSSBeamNLPProblem(
        opts, E_ksi, Fy_ksi,
        Mu_kipft, Vu_kip,
        Ix_min_in4, Ix_min_total_in4, Tu_kipin_val,
        B_min, B_max, t_min, t_max
    )
end

# --- Interface: Core ---

"""Number of design variables: B, H, t."""
n_variables(::SteelHSSBeamNLPProblem) = 3

"""Variable bounds for HSS beam NLP."""
function variable_bounds(p::SteelHSSBeamNLPProblem)
    lb = [p.B_min, p.B_min, p.t_min]
    ub = [p.B_max, p.B_max, p.t_max]
    return (lb, ub)
end

"""Initial guess from required plastic modulus Zx estimate."""
function initial_guess(p::SteelHSSBeamNLPProblem)
    # Estimate Zx_required: Mu × 12 / (0.9 × Fy)
    Zx_est = p.Mu_kipft * 12.0 / (0.9 * p.Fy_ksi)
    
    # For rectangular HSS, Zx ≈ B×H²/4 - (B-2t)×(H-2t)²/4
    # Start with a deep rectangular section
    t_guess = (p.t_min + p.t_max) / 2
    H_guess = clamp(sqrt(Zx_est * 4) * 0.8, p.B_min, p.B_max)
    B_guess = clamp(H_guess * 0.6, p.B_min, p.B_max)
    
    return [B_guess, H_guess, t_guess]
end

"""Human-readable variable names for solver output."""
variable_names(::SteelHSSBeamNLPProblem) = ["B (in)", "H (in)", "t (in)"]

# --- Interface: Objective ---

"""Objective function: HSS cross-sectional area with optional aspect penalty."""
function objective_fn(p::SteelHSSBeamNLPProblem, x::Vector{Float64})
    B, H, t = x
    area = _hss_area_smooth(B, H, t)
    
    if p.opts.prefer_square > 0
        k = p.opts.smooth_k
        aspect = _smooth_max(B/H, H/B; k=k)
        area *= (1 + p.opts.prefer_square * (aspect - 1))
    end
    
    return area
end

# --- Interface: Constraints ---

"""Number of constraints: 3 base + optional LL deflection, total deflection, torsion."""
function n_constraints(p::SteelHSSBeamNLPProblem)
    nc = 3  # flexure, shear, b/t fabrication
    p.Ix_min_in4 > 0 && (nc += 1)
    p.Ix_min_total_in4 > 0 && (nc += 1)
    p.Tu_kipin > 0 && (nc += 1)
    return nc
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::SteelHSSBeamNLPProblem)
    names = ["flexure utilization", "shear utilization", "min b/t ratio"]
    p.Ix_min_in4 > 0 && push!(names, "LL deflection (Ix adequacy)")
    p.Ix_min_total_in4 > 0 && push!(names, "total deflection (Ix adequacy)")
    p.Tu_kipin > 0 && push!(names, "torsion interaction (AISC H3-6)")
    return names
end

"""Constraint bounds: all utilizations ≤ 1.0, no lower bound."""
function constraint_bounds(p::SteelHSSBeamNLPProblem)
    nc = n_constraints(p)
    return (fill(-Inf, nc), ones(nc))
end

"""
    constraint_fns(p::SteelHSSBeamNLPProblem, x) -> Vector{Float64}

Evaluate AISC 360 constraint utilizations for HSS beam at design point `x`.
Includes smooth F7 flexure (compact/noncompact), G4 shear (Cv2), b/t
fabrication limit, and optional Ix deflection and H3-6 torsion interaction.
"""
function constraint_fns(p::SteelHSSBeamNLPProblem, x::Vector{Float64})
    B, H, t = x
    k = p.opts.smooth_k
    
    # ── Section properties ──
    Zx, _ = _hss_plastic_modulus_smooth(B, H, t)
    Sx, _ = _hss_section_modulus_smooth(B, H, t)
    
    # ── AISC F7: Flexural capacity with element compactness (no LTB) ──
    # F7-1: Compact → Mn = Mp
    # F7-2: Noncompact flange → linear reduction from Mp to My
    # F7-3: Noncompact web   → linear reduction from Mp to My
    # Closed HSS sections: no lateral-torsional buckling.
    
    Mp = p.Fy_ksi * Zx              # kip-in (plastic moment)
    My = p.Fy_ksi * Sx              # kip-in (yield moment)
    
    # Flange slenderness (flat width / thickness)
    b_f = _smooth_max(B - 3*t, 0.1; k=k)
    λ_f = b_f / t
    λp_f = 1.12 * sqrt(p.E_ksi / p.Fy_ksi)   # Table B4.1b
    λr_f = 1.40 * sqrt(p.E_ksi / p.Fy_ksi)
    
    # Web slenderness (flat depth / thickness)
    h_w = _smooth_max(H - 3*t, 0.1; k=k)
    λ_w = h_w / t
    λp_w = 2.42 * sqrt(p.E_ksi / p.Fy_ksi)   # Table B4.1b
    λr_w = 5.70 * sqrt(p.E_ksi / p.Fy_ksi)
    
    # Smooth noncompact reduction (F7-2 for flange, F7-3 for web):
    # At λ ≤ λp → frac = 0 → Mn = Mp
    # At λ = λr → frac = 1 → Mn = My
    # Beyond λr → frac > 1  → continues reducing (conservative for slender)
    frac_f = _smooth_max(λ_f - λp_f, 0.0; k=k) / _smooth_max(λr_f - λp_f, 0.01; k=k)
    frac_w = _smooth_max(λ_w - λp_w, 0.0; k=k) / _smooth_max(λr_w - λp_w, 0.01; k=k)
    
    Mn_f = Mp - (Mp - My) * _smooth_min(frac_f, 1.5; k=k)
    Mn_w = Mp - (Mp - My) * _smooth_min(frac_w, 1.5; k=k)
    
    Mn = _smooth_min(Mn_f, Mn_w; k=k)
    Mn = _smooth_min(Mn, Mp; k=k)           # Cap at Mp
    Mn = _smooth_max(Mn, 0.01; k=k)         # Prevent ≤ 0
    
    # Apply conservatism factor (0.92) to account for smooth blending error
    # at noncompact transition boundaries — ensures NLP capacity ≤ exact AISC.
    φMn_kipft = 0.92 * 0.9 * Mn / 12.0    # kip-ft
    
    util_flex = p.Mu_kipft / _smooth_max(φMn_kipft, 0.001; k=k)
    
    # ── AISC G4: Shear capacity ──
    # Vn = 0.6 Fy Aw Cv2, Aw = 2 h t (two webs)
    h_clear = H - 3*t                     # Clear internal height
    Aw = 2 * _smooth_max(h_clear, 0.1; k=k) * t
    
    # Cv2 (smooth three-branch)
    kv = 5.0
    w = _smooth_max(h_clear, 0.1; k=k) / t   # h/t slenderness
    lim1 = 1.10 * sqrt(kv * p.E_ksi / p.Fy_ksi)
    lim2 = 1.37 * sqrt(kv * p.E_ksi / p.Fy_ksi)
    
    # Zone 1: w ≤ lim1 → Cv2 = 1.0
    # Zone 2: lim1 < w ≤ lim2 → Cv2 = 1.10√(kv E/Fy) / w
    # Zone 3: w > lim2 → Cv2 = 1.51 kv E / (Fy w²)
    zone1 = 1.0 - _smooth_step(w, lim1; k=k)
    zone3 = _smooth_step(w, lim2; k=k)
    zone2 = 1.0 - zone1 - zone3
    
    Cv2_1 = 1.0
    Cv2_2 = 1.10 * sqrt(kv * p.E_ksi / p.Fy_ksi) / _smooth_max(w, 1.0; k=k)
    Cv2_3 = 1.51 * kv * p.E_ksi / (p.Fy_ksi * _smooth_max(w^2, 1.0; k=k))
    Cv2 = zone1 * Cv2_1 + _smooth_max(zone2, 0.0; k=k) * Cv2_2 + zone3 * Cv2_3
    
    Vn = 0.6 * p.Fy_ksi * Aw * Cv2   # kip
    φVn = 0.9 * Vn                     # φ = 0.9 for HSS shear
    
    util_shear = p.Vu_kip / _smooth_max(φVn, 0.001; k=k)
    
    # ── b/t fabrication limit ──
    b = H - 3*t
    b_t = b / t
    util_bt = p.opts.min_b_t / _smooth_max(b_t, 1.0; k=k)
    
    constraints = [util_flex, util_shear, util_bt]
    
    if p.Ix_min_in4 > 0
        Ix_check, _ = _hss_inertia_smooth(B, H, t)
        push!(constraints, p.Ix_min_in4 / _smooth_max(Ix_check, 0.1; k=k))
    end
    
    if p.Ix_min_total_in4 > 0
        Ix_check2, _ = _hss_inertia_smooth(B, H, t)
        push!(constraints, p.Ix_min_total_in4 / _smooth_max(Ix_check2, 0.1; k=k))
    end
    
    # ── AISC H3-6: HSS Torsion interaction ──
    # (Pr/Pc + Mr/Mc) + (Vr/Vc + Tr/Tc)² ≤ 1.0
    # For pure beam: Pr = 0, so first term = Mr/Mc.
    if p.Tu_kipin > 0
        # Torsional constant C = 2(B-t)(H-t)t - 4.5(4-π)t³
        C_tor = 2 * _smooth_max(B - t, 0.1; k=k) * _smooth_max(H - t, 0.1; k=k) * t -
                4.5 * (4 - π) * t^3
        C_tor = _smooth_max(C_tor, 0.01; k=k)
        
        # Critical torsional stress Fcr (smooth three-zone for rectangular HSS)
        # h/t slenderness using the longer wall
        ht_tor = _smooth_max(H - 3*t, 0.1; k=k) / t
        rt_tor = sqrt(p.E_ksi / p.Fy_ksi)
        lim1_tor = 2.45 * rt_tor   # Compact limit
        lim2_tor = 3.07 * rt_tor   # Noncompact limit
        
        # Smooth three-zone blending (same pattern as Cv2)
        zone1_tor = 1.0 - _smooth_step(ht_tor, lim1_tor; k=k)
        zone3_tor = _smooth_step(ht_tor, lim2_tor; k=k)
        zone2_tor = 1.0 - zone1_tor - zone3_tor
        
        Fcr_1 = 0.6 * p.Fy_ksi                                              # Yielding
        Fcr_2 = 0.6 * p.Fy_ksi * (2.45 * rt_tor) / _smooth_max(ht_tor, 1.0; k=k)  # Inelastic
        Fcr_3 = 0.458 * π^2 * p.E_ksi / _smooth_max(ht_tor^2, 1.0; k=k)   # Elastic
        
        Fcr_tor = zone1_tor * Fcr_1 + _smooth_max(zone2_tor, 0.0; k=k) * Fcr_2 + zone3_tor * Fcr_3
        
        # φTn = φ × Fcr × C  (kip·in)
        φTn = 0.9 * Fcr_tor * C_tor
        
        # Flexural capacity already computed above as φMn_kipft (kip·ft)
        # Shear capacity already computed above as φVn (kip)
        
        # H3-6: (Mr/Mc) + (Vr/Vc + Tr/Tc)²
        Mr_Mc = p.Mu_kipft / _smooth_max(φMn_kipft / 0.92, 0.001; k=k)  # undo the conservatism factor for interaction
        Vr_Vc = p.Vu_kip / _smooth_max(φVn, 0.001; k=k)
        Tr_Tc = p.Tu_kipin / _smooth_max(φTn, 0.001; k=k)
        
        util_h3 = Mr_Mc + (Vr_Vc + Tr_Tc)^2
        push!(constraints, util_h3)
    end
    
    return constraints
end

# --- Result builder (reuses HSSColumnNLPResult) ---

"""
    build_hss_beam_nlp_result(p, opt_result) -> HSSColumnNLPResult

Convert optimization result to `HSSColumnNLPResult` with practical HSSRectSection.
"""
function build_hss_beam_nlp_result(p::SteelHSSBeamNLPProblem, opt_result)
    B_opt, H_opt, t_opt = opt_result.minimizer
    
    if p.opts.snap
        outer_incr = ustrip(u"inch", p.opts.outer_increment)
        t_incr = ustrip(u"inch", p.opts.thickness_increment)
        
        B_final = ceil(B_opt / outer_incr) * outer_incr
        H_final = ceil(H_opt / outer_incr) * outer_incr
        t_final = ceil(t_opt / t_incr) * t_incr
        
        max_t = min(B_final, H_final) / 4
        t_final = min(t_final, max_t)
        t_final = max(t_final, p.t_min)
    else
        B_final = B_opt
        H_final = H_opt
        t_final = t_opt
    end
    
    return _hss_beam_nlp_at(
        B_opt, H_opt, t_opt, B_final, H_final, t_final,
        opt_result.status, opt_result.iterations)
end

"""`HSSColumnNLPResult` at the given final dimensions (inches)."""
function _hss_beam_nlp_at(
    B_opt, H_opt, t_opt, B_final, H_final, t_final,
    status::Symbol, iterations::Int,
)
    section = HSSRectSection(H_final * u"inch", B_final * u"inch", t_final * u"inch")
    area = ustrip(u"inch^2", section.A)
    weight_per_ft = area * 490.0 / 144.0
    return HSSColumnNLPResult(
        section, B_opt, H_opt, t_opt, B_final, H_final, t_final,
        area, weight_per_ft, status, iterations)
end

"""Dispatch `build_result` to `build_hss_beam_nlp_result` for HSS beam problem."""
function build_result(p::SteelHSSBeamNLPProblem, opt_result)
    build_hss_beam_nlp_result(p, opt_result)
end
