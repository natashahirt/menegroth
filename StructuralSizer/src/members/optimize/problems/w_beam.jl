# ║               STEEL W BEAM NLP PROBLEM  (AISC 360-16 F2/G2)              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Dedicated beam formulation with direct flexure + shear constraints.
# Unlike the column NLP (H1-1 interaction), this uses:
#   - AISC F2 flexural capacity including smooth LTB
#   - AISC G2 shear capacity
#   - No compression capacity (Pu = 0)
#
# Design variables: [d, bf, tf, tw] (depth, flange width, flange/web thickness)
# Objective: Minimize cross-sectional area
# Constraints: Mu/φMn ≤ 1.0, Vu/φVn ≤ 1.0, proportioning

"""
    SteelWBeamNLPProblem <: AbstractNLPProblem

Continuous optimization for W-shape beam sizing (pure flexure + shear).

Uses smooth AISC F2 (flexure with LTB) and G2 (shear) formulations.
This is a beam-specific problem — no axial compression.

# Design Variables
- `x[1]` = d: Overall depth (inches)
- `x[2]` = bf: Flange width (inches)
- `x[3]` = tf: Flange thickness (inches)
- `x[4]` = tw: Web thickness (inches)

# Constraints
- Flexure utilization: Mu / φMn(Lb) ≤ 1.0 (with smooth LTB)
- Shear utilization: Vu / φVn ≤ 1.0
- Proportioning: bf/d, tf/tw ratios
- Web compactness: h/tw ≤ 3.76√(E/Fy) (the §F2 flexure model needs a compact web)
- Flange compactness (if required)
- Deflection: Ix_min / Ix ≤ 1.0 (if Ix_min > 0)
"""
struct SteelWBeamNLPProblem <: AbstractNLPProblem
    opts::NLPWOptions
    
    E_ksi::Float64
    G_ksi::Float64
    Fy_ksi::Float64
    
    Mu_kipft::Float64
    Vu_kip::Float64
    
    Lb_in::Float64
    Cb::Float64
    
    # Deflection: minimum required Ix for LL (in⁴). 0.0 = no check.
    Ix_min_in4::Float64
    # Deflection: minimum required Ix for DL+LL total (in⁴). 0.0 = no check.
    Ix_min_total_in4::Float64
    
    Tu_kipin::Float64
    L_in::Float64
    
    # Bounds in inches
    d_min::Float64
    d_max::Float64
    bf_min::Float64
    bf_max::Float64
    tf_min::Float64
    tf_max::Float64
    tw_min::Float64
    tw_max::Float64
end

"""
    SteelWBeamNLPProblem(Mu, Vu, geometry, opts; Mux_neg, Ix_min, Tu, L_span)

Construct a steel W-beam NLP problem from factored demands and options.
Converts Unitful inputs to bare AISC units (kip, kip-ft, inches, ksi).

When `Mux_neg > 0`, sizes against `max(Mu, Mux_neg)` with hogging Chapter F
geometry (`Lb = L`, `Cb = 1.0`) whenever deck-braced sagging `Lb`/`Cb` would
otherwise inflate φMn. Mirrors `_nlp_hogging_demands`.

AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
# ENGINEERING JUDGMENT
`SteelMemberGeometry` has only sagging `Cb`. Hogging uses `Cb = 1.0`.
"""
function SteelWBeamNLPProblem(
    Mu, Vu,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions;
    Mux_neg = Mu,
    Ix_min = nothing,
    Ix_min_total = nothing,
    Tu = 0.0,
    L_span = nothing,
)
    _require_nlp_objective(
        opts.objective, (MinWeight,); problem="steel W-beam NLP")
    E_ksi = to_ksi(opts.material.E)
    G_ksi = to_ksi(opts.material.G)
    Fy_ksi = to_ksi(opts.material.Fy)
    
    Mu_kipft = max(to_kipft(Mu), to_kipft(Mux_neg))
    Vu_kip = to_kip(Vu)
    
    Lb_in = to_inches(geometry.Lb)
    Cb = geometry.Cb
    # When Mux_neg > 0, size against hogging Chapter F (Lb=L, Cb=1.0).
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
    # ENGINEERING JUDGMENT: hogging Cb=1.0 — no bottom-flange Cb field.
    if to_kipft(Mux_neg) > 0 && _hogging_is_stricter(geometry)
        hog_g = _hogging_chapter_f_geometry(geometry)
        Lb_in = to_inches(hog_g.Lb)
        Cb = hog_g.Cb
    end
    
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
    
    # Span length for torsion (defaults to Lb if not specified)
    L_in_val = if !isnothing(L_span)
        L_span isa Unitful.Quantity ? to_inches(L_span) : Float64(L_span) * 12.0
    else
        Lb_in  # fallback to unbraced length
    end
    
    d_min = to_inches(opts.min_depth)
    d_max = to_inches(opts.max_depth)
    bf_min = to_inches(opts.min_flange_width)
    bf_max = to_inches(opts.max_flange_width)
    tf_min = to_inches(opts.min_flange_thickness)
    tf_max = to_inches(opts.max_flange_thickness)
    tw_min = to_inches(opts.min_web_thickness)
    tw_max = to_inches(opts.max_web_thickness)
    
    SteelWBeamNLPProblem(
        opts, E_ksi, G_ksi, Fy_ksi,
        Mu_kipft, Vu_kip,
        Lb_in, Cb,
        Ix_min_in4, Ix_min_total_in4,
        Tu_kipin_val, L_in_val,
        d_min, d_max, bf_min, bf_max, tf_min, tf_max, tw_min, tw_max
    )
end

# --- Interface: Core ---

"""Number of design variables: d, bf, tf, tw."""
n_variables(::SteelWBeamNLPProblem) = 4

"""Variable bounds for steel W-beam NLP."""
function variable_bounds(p::SteelWBeamNLPProblem)
    lb = [p.d_min, p.bf_min, p.tf_min, p.tw_min]
    ub = [p.d_max, p.bf_max, p.tf_max, p.tw_max]
    return (lb, ub)
end

"""Initial guess from required plastic modulus Zx estimate."""
function initial_guess(p::SteelWBeamNLPProblem)
    # Estimate from Mu: Zx_required ≈ Mu / (0.9 × Fy)
    # Mu in kip-ft, Fy in ksi → Zx in in³ = Mu×12 / (0.9 × Fy)
    Zx_est = p.Mu_kipft * 12.0 / (0.9 * p.Fy_ksi)
    
    # For a W beam, Zx ≈ bf × tf × (d - tf) + tw × (d - 2tf)² / 4
    # Use typical proportions for a beam (deeper, narrower flanges than columns)
    d_guess = clamp(sqrt(Zx_est) * 2.0, p.d_min, p.d_max)
    bf_guess = clamp(0.5 * d_guess, p.bf_min, p.bf_max)
    tf_guess = clamp(0.5, p.tf_min, p.tf_max)
    tw_guess = clamp(0.3, p.tw_min, p.tw_max)
    
    return [d_guess, bf_guess, tf_guess, tw_guess]
end

"""Human-readable variable names for solver output."""
variable_names(::SteelWBeamNLPProblem) = ["d (in)", "bf (in)", "tf (in)", "tw (in)"]

# --- Interface: Objective ---

"""Objective function: W-section cross-sectional area (AISC 360)."""
function objective_fn(p::SteelWBeamNLPProblem, x::Vector{Float64})
    d, bf, tf, tw = x
    return _w_area_smooth(d, bf, tf, tw)
end

# --- Interface: Constraints ---

"""Number of constraints: 5 base + optional compactness, LL deflection, total deflection, torsion."""
function n_constraints(p::SteelWBeamNLPProblem)
    nc = 5  # flexure, shear, bf/d, tf/tw, web slenderness
    p.opts.require_compact && (nc += 1)
    p.Ix_min_in4 > 0 && (nc += 1)
    p.Ix_min_total_in4 > 0 && (nc += 1)
    p.Tu_kipin > 0 && (nc += 1)
    return nc
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::SteelWBeamNLPProblem)
    names = ["flexure utilization", "shear utilization", "bf/d ratio", "tf/tw ratio",
             "web compactness (h/tw ≤ λp)"]
    p.opts.require_compact && push!(names, "flange compactness")
    p.Ix_min_in4 > 0 && push!(names, "LL deflection (Ix adequacy)")
    p.Ix_min_total_in4 > 0 && push!(names, "total deflection (Ix adequacy)")
    p.Tu_kipin > 0 && push!(names, "torsion interaction (DG9 §4.7.1)")
    return names
end

"""Constraint bounds: all utilizations ≤ 1.0, no lower bound."""
function constraint_bounds(p::SteelWBeamNLPProblem)
    nc = n_constraints(p)
    return (fill(-Inf, nc), ones(nc))
end

"""
    constraint_fns(p::SteelWBeamNLPProblem, x) -> Vector{Float64}

Evaluate AISC 360 constraint utilizations for W-beam at design point `x`.
Includes smooth F2 flexure (with LTB), G2 shear, proportioning, web
slenderness, and optional flange compactness, deflection (Ix), and DG9
torsion interaction.
"""
function constraint_fns(p::SteelWBeamNLPProblem, x::Vector{Float64})
    d, bf, tf, tw = x
    k = p.opts.smooth_k
    
    # ── Section properties (all smooth polynomials) ──
    A = _w_area_smooth(d, bf, tf, tw)
    Ix, Iy = _w_inertia_smooth(d, bf, tf, tw)
    Zx, _ = _w_plastic_modulus_smooth(d, bf, tf, tw)
    Sx = Ix / (d / 2)           # Elastic section modulus (in³)
    ry = sqrt(Iy / A)
    
    h = d - 2*tf                # Clear web height
    ho = d - tf                  # Distance between flange centroids
    
    # Torsion constant  J ≈ (2 bf tf³ + h tw³) / 3
    J = (2*bf*tf^3 + _smooth_max(h, 0.1; k=k)*tw^3) / 3
    
    # rts (effective radius of gyration for LTB)
    # rts² = Iy × ho / (2 × Sx)  for doubly symmetric I-sections
    rts_sq = Iy * _smooth_max(ho, 0.1; k=k) / (2 * _smooth_max(Sx, 0.01; k=k))
    rts = sqrt(_smooth_max(rts_sq, 0.01; k=k))
    
    # ── AISC F2: Flexural capacity with smooth LTB ──
    Mp = p.Fy_ksi * Zx              # Plastic moment (kip-in)
    
    # Limiting unbraced lengths (AISC F2-5, F2-6)
    Lp = 1.76 * ry * sqrt(p.E_ksi / p.Fy_ksi)
    
    jc_term = J / (_smooth_max(Sx, 0.01; k=k) * _smooth_max(ho, 0.1; k=k))
    Lr_inner = jc_term + sqrt(jc_term^2 + 6.76 * (0.7 * p.Fy_ksi / p.E_ksi)^2)
    Lr = 1.95 * rts * (p.E_ksi / (0.7 * p.Fy_ksi)) * sqrt(Lr_inner)
    
    # Elastic LTB critical stress (AISC F2-4)
    Lb_rts = p.Lb_in / _smooth_max(rts, 0.01; k=k)
    Fcr_ltb = p.Cb * π^2 * p.E_ksi / _smooth_max(Lb_rts^2, 0.01; k=k) *
              sqrt(1 + 0.078 * jc_term * Lb_rts^2)
    
    # Three-zone smooth blending:
    # Zone 1 (Lb ≤ Lp):  Mn = Mp
    # Zone 2 (Lp < Lb ≤ Lr): inelastic LTB
    # Zone 3 (Lb > Lr):  elastic LTB
    
    # Inelastic LTB moment (F2-2)
    Lb_frac = _smooth_max(p.Lb_in - Lp, 0.0; k=k) / _smooth_max(Lr - Lp, 0.01; k=k)
    Lb_frac_clamped = _smooth_min(Lb_frac, 1.0; k=k)
    Mn_inelastic = p.Cb * (Mp - (Mp - 0.7*p.Fy_ksi*Sx) * Lb_frac_clamped)
    
    # Elastic LTB moment (F2-3)
    Mn_elastic = Fcr_ltb * Sx
    
    # Take minimum of all branches, capped at Mp
    Mn = _smooth_min(_smooth_min(Mn_inelastic, Mn_elastic; k=k), Mp; k=k)
    
    # Apply conservatism factor (0.98) to account for smooth blending error
    # at piecewise boundaries.  Without this, the smooth min/max can
    # overestimate capacity by 1–3 % near LTB transition points.
    φMn_kipft = 0.98 * 0.9 * Mn / 12.0   # kip-ft
    
    # Flexure utilization
    util_flex = p.Mu_kipft / _smooth_max(φMn_kipft, 0.001; k=k)
    
    # ── AISC G2: Shear capacity ──
    Aw = d * tw                     # Web area (in²)
    # Cv1 for rolled shapes: 1.0 if h/tw ≤ 2.24√(E/Fy)
    h_tw = _smooth_max(h, 0.1; k=k) / tw
    Cv1_limit = 2.24 * sqrt(p.E_ksi / p.Fy_ksi)
    # Smooth Cv1: blend between 1.0 and 1.10√(5.34 E/Fy)/(h/tw)
    compact_shear = 1.0 - _smooth_step(h_tw, Cv1_limit; k=k)
    Cv1_reduced = 1.10 * sqrt(5.34 * p.E_ksi / p.Fy_ksi) / _smooth_max(h_tw, 1.0; k=k)
    Cv1 = compact_shear * 1.0 + (1 - compact_shear) * _smooth_min(Cv1_reduced, 1.0; k=k)
    
    Vn = 0.6 * p.Fy_ksi * Aw * Cv1  # kip
    φVn = 1.0 * Vn                    # φ=1.0 for most rolled W shapes
    
    # Shear utilization
    util_shear = p.Vu_kip / _smooth_max(φVn, 0.001; k=k)
    
    # ── Proportioning constraints ──
    bf_d = bf / d
    util_bf_d = _smooth_max(p.opts.bf_d_min / _smooth_max(bf_d, 0.1; k=k),
                             bf_d / p.opts.bf_d_max; k=k)
    
    tf_tw = tf / tw
    util_tf_tw = _smooth_max(p.opts.tf_tw_min / _smooth_max(tf_tw, 0.5; k=k),
                              tf_tw / p.opts.tf_tw_max; k=k)
    
    # ── Web compactness ──
    # The flexure model above is AISC 360-16 §F2, which "applies to doubly
    # symmetric I-shaped members ... having compact webs and compact flanges"
    # (corpus: aisc-360-16, page 103). Compact web per Table B4.1b, Case 15:
    # h/tw ≤ λp = 3.76 √(E/Fy) (corpus: aisc-360-16, page 75). This is
    # stricter than the §F13.2 limit h/tw ≤ 260, so it replaces it. A web
    # past λp needs §F4/§F5, which the checker refuses.
    λpw = 3.76 * sqrt(p.E_ksi / p.Fy_ksi)
    util_web = _smooth_max(h, 0.1; k=k) / (tw * λpw)
    
    constraints = [util_flex, util_shear, util_bf_d, util_tf_tw, util_web]
    
    if p.opts.require_compact
        λf = bf / (2*tf)
        λpf = 0.38 * sqrt(p.E_ksi / p.Fy_ksi)
        push!(constraints, λf / λpf)
    end
    
    if p.Ix_min_in4 > 0
        Ix_check, _ = _w_inertia_smooth(d, bf, tf, tw)
        push!(constraints, p.Ix_min_in4 / _smooth_max(Ix_check, 0.1; k=k))
    end
    
    if p.Ix_min_total_in4 > 0
        Ix_check2, _ = _w_inertia_smooth(d, bf, tf, tw)
        push!(constraints, p.Ix_min_total_in4 / _smooth_max(Ix_check2, 0.1; k=k))
    end
    
    # ── DG9 Torsion interaction (§4.7.1) ──
    # Combined normal + shear stress check at midspan (critical for concentrated load).
    # (f_un / (φ·Fy))² + (f_uv / (φ·0.6·Fy))² ≤ 1.0
    if p.Tu_kipin > 0
        G_ksi = p.G_ksi
        
        # Warping constant  Cw ≈ Iy × ho² / 4  (DG9 Eq. C.3)
        Cw = Iy * _smooth_max(ho, 0.1; k=k)^2 / 4
        
        # Torsional parameter  a = √(E·Cw / (G·J))
        a_tor = sqrt(_smooth_max(p.E_ksi * Cw / (G_ksi * _smooth_max(J, 1e-6; k=k)), 0.01; k=k))
        
        # DG9 Case 3 derivatives at midspan (concentrated midspan torque)
        L_tor = _smooth_max(p.L_in, 1.0; k=k)
        α = L_tor / (2 * a_tor)
        GJ = G_ksi * _smooth_max(J, 1e-6; k=k)
        half_TGJ = p.Tu_kipin / _smooth_max(GJ, 1e-6; k=k)
        
        # At midspan (z = L/2), for Case 3:
        # θ' = 0 (by symmetry), θ'' = -T/(2GJ·a) × sinh(α)/cosh(α), θ''' = -T/(2GJ·a²) × 1
        cosh_α_safe = cosh(_smooth_min(α, 20.0; k=k))  # clamp to prevent overflow
        tanh_α = tanh(_smooth_min(α, 20.0; k=k))
        
        θp_mid  = 0.0  # pure torsion shear is zero at midspan for Case 3
        θpp_mid = -half_TGJ / a_tor * tanh_α
        θppp_mid = -half_TGJ / a_tor^2 * (1.0 / _smooth_max(cosh_α_safe, 1.0; k=k))
        
        # DG9 torsional properties
        Wno = bf * _smooth_max(ho, 0.1; k=k) / 4      # Normalized warping function (in²)
        Sw1 = tf * bf^2 * _smooth_max(ho, 0.1; k=k) / 16  # Warping statical moment (in⁴)
        
        # Stresses at midspan (ksi)
        σ_w_mid = p.E_ksi * Wno * θpp_mid        # Warping normal stress
        τ_t_mid = G_ksi * tf * abs(θp_mid)        # Pure torsional shear (0 at midspan)
        τ_ws_mid = p.E_ksi * Sw1 * abs(θppp_mid) / _smooth_max(tf, 0.01; k=k)  # Warping shear
        
        # Bending stress at midspan
        σ_b_ksi = p.Mu_kipft * 12.0 / _smooth_max(Sx, 0.01; k=k)
        
        # Combined stresses (DG9 Eq. 4.12, 4.13)
        f_un = abs(σ_b_ksi) + abs(σ_w_mid)
        f_uv = τ_t_mid + τ_ws_mid
        
        # Interaction (DG9 Eq. 4.16a)
        φFy = 0.9 * p.Fy_ksi
        φFvy = 0.9 * 0.6 * p.Fy_ksi
        ir = (f_un / _smooth_max(φFy, 0.01; k=k))^2 + (f_uv / _smooth_max(φFvy, 0.01; k=k))^2
        
        push!(constraints, ir)
    end
    
    return constraints
end

# --- Result builder (reuses WColumnNLPResult) ---

"""
    build_w_beam_nlp_result(p, opt_result) -> WColumnNLPResult

Convert optimization result to `WColumnNLPResult` with practical ISymmSection.
"""
function build_w_beam_nlp_result(p::SteelWBeamNLPProblem, opt_result)
    d_opt, bf_opt, tf_opt, tw_opt = opt_result.minimizer
    
    if p.opts.snap
        incr = 0.0625  # 1/16"
        d_final = ceil(d_opt / incr) * incr
        bf_final = ceil(bf_opt / incr) * incr
        tf_final = ceil(tf_opt / incr) * incr
        tw_final = ceil(tw_opt / incr) * incr
    else
        d_final = d_opt
        bf_final = bf_opt
        tf_final = tf_opt
        tw_final = tw_opt
    end
    
    return _w_beam_nlp_at(
        p, d_opt, bf_opt, tf_opt, tw_opt,
        d_final, bf_final, tf_final, tw_final,
        opt_result.status, opt_result.iterations)
end

"""`WColumnNLPResult` at the given final dimensions (inches)."""
function _w_beam_nlp_at(
    p::SteelWBeamNLPProblem,
    d_opt, bf_opt, tf_opt, tw_opt,
    d_final, bf_final, tf_final, tw_final,
    status::Symbol, iterations::Int,
)
    section = ISymmSection(
        d_final * u"inch", bf_final * u"inch",
        tw_final * u"inch", tf_final * u"inch";
        name = "NLP-W d=$(round(d_final, digits=2)) bf=$(round(bf_final, digits=2))",
        material = p.opts.material,
    )

    A = _w_area_smooth(d_final, bf_final, tf_final, tw_final)
    Ix, Iy = _w_inertia_smooth(d_final, bf_final, tf_final, tw_final)
    rx = sqrt(Ix / A)
    ry = sqrt(Iy / A)
    weight_per_ft = A * 490.0 / 144.0

    return WColumnNLPResult(
        section,
        d_opt, bf_opt, tf_opt, tw_opt,
        d_final, bf_final, tf_final, tw_final,
        A, weight_per_ft,
        Ix, Iy, rx, ry,
        status, iterations,
    )
end

"""Dispatch `build_result` to `build_w_beam_nlp_result` for W-beam problem."""
function build_result(p::SteelWBeamNLPProblem, opt_result)
    build_w_beam_nlp_result(p, opt_result)
end


# ╔═══════════════════════════════════════════════════════════════════════════╗
