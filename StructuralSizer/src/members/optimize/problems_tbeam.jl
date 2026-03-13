# ==============================================================================
# RC T-Beam NLP Problem
# ==============================================================================
# Continuous optimization problem for RC T-beam sizing.
# Interfaces with src/optimize/continuous_nlp.jl via AbstractNLPProblem.
#
# Design variables: [bw, h, ρ] (web width, total depth in inches, reinforcement ratio)
# Fixed parameters: bf (flange width), hf (flange thickness) — from slab sizing
# Objective: Minimize web cross-sectional area (bw × h)
# Constraints:
#   1. Flexure utilization:  Mu / φMn ≤ 1.0  (T-beam Whitney block)
#   2. Shear section adequacy: Vu / φVn_max ≤ 1.0  (uses bw)
#   3. Net tensile strain:  εt ≥ 0.005  (ACI 318-11 §10.3.5)
#   4. Minimum reinforcement: As ≥ As,min (ACI 318-11 §10.5.1, uses bw)
#   5. Geometric: bw ≤ bf (web can't exceed flange)
#   6. Geometric: hf < h (slab thickness < total depth)
#   7. (optional) LL deflection: Δ_LL ≤ L/360  (ACI §24.2)
#   8. (optional) Total deflection: Δ_total ≤ L/240  (ACI §24.2)

using Unitful
using Asap: kip, ksi, to_kip, to_kipft, to_inches, to_sqinches

# ==============================================================================
# Problem Type
# ==============================================================================

"""
    RCTBeamNLPProblem <: AbstractNLPProblem

Continuous optimization problem for RC T-beam sizing.

Optimizes web width (bw), total depth (h), and reinforcement ratio (ρ) to find
the minimum-area section satisfying ACI 318 T-beam requirements. The flange
width (bf) and flange thickness (hf) are fixed parameters determined by slab
sizing and tributary geometry.

# Design Variables
- `x[1]` = bw: Web width (inches)
- `x[2]` = h: Total depth (inches)
- `x[3]` = ρ: Longitudinal reinforcement ratio As/(bw×d) (dimensionless)

# Fixed Parameters
- `bf`: Effective flange width (inches) — from tributary polygon / ACI Table 6.3.2.1
- `hf`: Flange (slab) thickness (inches) — from slab sizing

# Constraints
- Flexure utilization: Mu / φMn ≤ 1.0 (T-beam two-case Whitney block)
- Shear section adequacy: Vu / φVn_max ≤ 1.0 (uses bw, not bf)
- Net tensile strain: εt ≥ 0.005 (tension-controlled)
- Minimum reinforcement: ρ ≥ ρ_min (ACI 318-11 §10.5.1, uses bw)
- Geometric: bw ≤ bf, hf < h
- (optional) LL deflection: Δ_LL ≤ L/360 (ACI §24.2, when service loads provided)
- (optional) Total deflection: Δ_total ≤ L/240 (ACI §24.2)
"""
struct RCTBeamNLPProblem <: AbstractNLPProblem
    Mu_kipft::Float64
    Vu_kip::Float64
    opts::NLPBeamOptions

    # Fixed flange geometry (inches)
    bf_in::Float64
    hf_in::Float64

    # Material properties (cached in ACI units)
    fc_psi::Float64
    fy_psi::Float64
    Es_ksi::Float64
    λ::Float64

    # Cached cover offset for effective depth (inches)
    cover_offset_in::Float64

    # ACI 318-11 §10.5.1 minimum reinforcement ratio
    ρ_min_aci::Float64

    # Bounds in inches
    bw_min::Float64
    bw_max::Float64
    h_min::Float64
    h_max::Float64

    # ── Deflection constraint (ACI §24.2) ──
    # When w_dead_kiplf > 0, adds LL and total deflection constraints.
    w_dead_kiplf::Float64   # Service dead load (kip/ft), 0.0 = no check
    w_live_kiplf::Float64   # Service live load (kip/ft)
    L_in::Float64           # Span length (inches)
    Ec_psi::Float64         # Concrete elastic modulus (psi)
    fr_psi::Float64         # Modulus of rupture (psi)
    defl_support::Symbol    # :simply_supported, :cantilever, etc.
    defl_ξ::Float64         # Long-term factor (2.0 = 5+ years)

    # ── Torsion constraint (ACI §11.5.3.1) ──
    Tu_kipin::Float64              # Torsion demand (kip·in). 0.0 = no torsion.
    cover_to_stirrup_ctr_in::Float64  # face → stirrup centerline (inches)
end

"""
    RCTBeamNLPProblem(Mu, Vu, bf, hf, opts; w_dead, w_live, L_span, support, ξ, Tu)

Construct an RC T-beam NLP problem from demand, flange geometry, and options.
Converts all Unitful inputs to bare ACI units (kip, kip-ft, inches, psi).
"""
function RCTBeamNLPProblem(Mu, Vu, bf, hf, opts::NLPBeamOptions;
                           w_dead=nothing, w_live=nothing, L_span=nothing,
                           support::Symbol=:simply_supported, ξ::Float64=2.0,
                           Tu=0.0)
    fc = fc_ksi(opts.material)
    fy = fy_ksi(opts.rebar_material)
    Es = Es_ksi(opts.rebar_material)
    λ_val = opts.material.λ

    Mu_kipft = to_kipft(Mu)
    Vu_kip   = to_kip(Vu)

    # Fixed flange dimensions
    bf_in = ustrip(u"inch", bf)
    hf_in = ustrip(u"inch", hf)

    # Cover offset: cover + stirrup_dia + bar_dia/2
    cov_in    = ustrip(u"inch", opts.cover)
    d_stir_in = ustrip(u"inch", rebar(opts.stirrup_size).diameter)
    d_bar_in  = ustrip(u"inch", rebar(opts.bar_size).diameter)
    cover_offset = cov_in + d_stir_in + d_bar_in / 2
    c_ctr = cov_in + d_stir_in / 2   # face → stirrup centerline

    bw_min = ustrip(u"inch", opts.min_width)
    bw_max = min(ustrip(u"inch", opts.max_width), bf_in)  # bw ≤ bf
    h_min  = max(ustrip(u"inch", opts.min_depth), hf_in + 2.0)  # h > hf + clearance
    h_max  = ustrip(u"inch", opts.max_depth)

    # ACI 318-11 §10.5.1: ρ_min = max(3√f'c/fy, 200/fy) (uses bw)
    fc_psi = fc * 1000.0
    fy_psi = fy * 1000.0
    ρ_min_aci = max(3.0 * sqrt(fc_psi) / fy_psi, 200.0 / fy_psi)

    # Deflection parameters
    if !isnothing(w_dead) && !isnothing(w_live) && !isnothing(L_span)
        wd_kiplf = w_dead isa Unitful.Quantity ? ustrip(kip/u"ft", w_dead) : Float64(w_dead)
        wl_kiplf = w_live isa Unitful.Quantity ? ustrip(kip/u"ft", w_live) : Float64(w_live)
        L_span_in = L_span isa Unitful.Quantity ? ustrip(u"inch", L_span) : Float64(L_span) * 12.0
        Ec_psi_val = 57000.0 * sqrt(fc_psi)
        fr_psi_val = 7.5 * λ_val * sqrt(fc_psi)
    else
        wd_kiplf = 0.0
        wl_kiplf = 0.0
        L_span_in = 0.0
        Ec_psi_val = 0.0
        fr_psi_val = 0.0
    end

    # Torsion demand
    Tu_kipin_val = if Tu isa Unitful.Quantity
        abs(ustrip(u"lbf*inch", Tu)) / 1000.0
    else
        abs(Float64(Tu))
    end

    RCTBeamNLPProblem(
        Mu_kipft, Vu_kip, opts,
        bf_in, hf_in,
        fc_psi, fy_psi, Es, λ_val,
        cover_offset,
        ρ_min_aci,
        bw_min, bw_max, h_min, h_max,
        wd_kiplf, wl_kiplf, L_span_in, Ec_psi_val, fr_psi_val,
        support, ξ,
        Tu_kipin_val, c_ctr,
    )
end

# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

"""Number of design variables: bw, h, ρ."""
n_variables(::RCTBeamNLPProblem) = 3

"""Variable bounds for T-beam NLP: [bw_min, h_min, 0.003] to [bw_max, h_max, 0.025]."""
function variable_bounds(p::RCTBeamNLPProblem)
    lb = [p.bw_min, p.h_min, 0.003]
    # T-beams: ρ = As/(bw×d) is relative to the narrow web, so it's naturally
    # higher than for rectangular beams.  The wide flange absorbs compression
    # efficiently, keeping εt well above 0.005 even at high ρ.  The εt ≥ 0.005
    # constraint (constraint #3) is the correct governing limit — no need for
    # an artificially low cap here.
    ub = [p.bw_max, p.h_max, 0.025]
    return (lb, ub)
end

"""Midrange initial guess for T-beam NLP: [bw_mid, h_mid, 0.012]."""
function initial_guess(p::RCTBeamNLPProblem)
    bw0 = (p.bw_min + p.bw_max) / 2
    h0  = (p.h_min + p.h_max) / 2
    return [bw0, h0, 0.012]
end

"""Human-readable variable names for solver output."""
variable_names(::RCTBeamNLPProblem) = ["bw (in)", "h (in)", "ρ"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

"""Objective function: web cross-sectional area with optional ρ weighting."""
function objective_fn(p::RCTBeamNLPProblem, x::Vector{Float64})
    bw, h, ρ = x
    # Web area only — flange (slab) is already counted as slab material
    Ag_web = bw * h

    obj = p.opts.objective
    if obj isa MinVolume
        return Ag_web * (1 + 2.0 * ρ)
    elseif obj isa MinWeight
        γ_c = ustrip(u"lb/ft^3", p.opts.material.ρ)
        γ_s = ustrip(u"lb/ft^3", p.opts.rebar_material.ρ)
        return Ag_web * ((1 - ρ) * γ_c + ρ * γ_s)
    else
        return Ag_web * (1 + 2.0 * ρ)
    end
end

# ==============================================================================
# AbstractNLPProblem Interface: Constraints
# ==============================================================================

"""Number of constraints: 4 base + 2 deflection (if service loads) + 1 torsion (if Tu > 0)."""
function n_constraints(p::RCTBeamNLPProblem)
    nc = 4
    p.w_dead_kiplf > 0 && (nc += 2)  # LL + total deflection
    p.Tu_kipin > 0 && (nc += 1)       # torsion adequacy (ACI §11.5.3.1)
    return nc
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::RCTBeamNLPProblem)
    names = [
        "flexure utilization",
        "shear adequacy",
        "net tensile strain (εt ≥ 0.005)",
        "min reinforcement (§10.5.1)",
    ]
    if p.w_dead_kiplf > 0
        push!(names, "deflection LL (L/360)")
        push!(names, "deflection total (L/240)")
    end
    p.Tu_kipin > 0 && push!(names, "torsion adequacy (§11.5.3.1)")
    return names
end

"""Constraint bounds: all utilizations ≤ 1.0, no lower bound."""
function constraint_bounds(p::RCTBeamNLPProblem)
    nc = n_constraints(p)
    return (fill(-Inf, nc), fill(1.0, nc))
end

"""
    constraint_fns(p::RCTBeamNLPProblem, x) -> Vector{Float64}

Evaluate all constraint utilizations for the T-beam NLP at design point `x`.
Returns utilization ratios per ACI 318: flexure, shear, εt, ρ_min,
plus optional deflection (LL and total) and torsion adequacy.
"""
function constraint_fns(p::RCTBeamNLPProblem, x::Vector{Float64})
    bw, h, ρ = x
    bf = p.bf_in
    hf = p.hf_in

    # Effective depth
    d = h - p.cover_offset_in
    d = max(d, 1.0)

    # Steel area (defined using web width)
    As = ρ * bw * d

    # --- T-Beam Flexure (Whitney stress block) ---
    # Trial: assume stress block entirely in flange (rectangular with bf)
    a_trial = As * p.fy_psi / (0.85 * p.fc_psi * bf)
    β1 = _beta1_from_fc_psi(p.fc_psi)
    εcu = 0.003  # ACI 318-11 §10.2.3

    if a_trial ≤ hf
        # Case 1: stress block in flange — rectangular with bf
        a = a_trial
        c = a / max(β1, 0.5)
        εt = c > 0 ? εcu * (d - c) / max(c, 0.01) : 0.0
        Mn_lbin = As * p.fy_psi * (d - a / 2)
    else
        # Case 2: stress block extends into web — T-beam decomposition
        Cf_lb = 0.85 * p.fc_psi * (bf - bw) * hf
        Cw_lb = As * p.fy_psi - Cf_lb

        # Guard: if Cw_lb ≤ 0, the web contribution is non-physical;
        # this happens when As is too small for the flange to need the web.
        # Treat as flange-only with a = hf.
        if Cw_lb ≤ 0
            a = hf
            c = a / max(β1, 0.5)
            εt = c > 0 ? εcu * (d - c) / max(c, 0.01) : 0.0
            Mn_lbin = As * p.fy_psi * (d - a / 2)
        else
            aw = Cw_lb / (0.85 * p.fc_psi * bw)
            c = aw / max(β1, 0.5)
            εt = c > 0 ? εcu * (d - c) / max(c, 0.01) : 0.0
            Mn_lbin = Cf_lb * (d - hf / 2) + Cw_lb * (d - aw / 2)
        end
    end

    φ = flexure_phi(εt)

    φMn_kipft = φ * Mn_lbin / 12_000.0
    util_flexure = p.Mu_kipft / max(φMn_kipft, 1e-6)

    # --- Shear adequacy (uses bw, not bf) ---
    sqrt_fc = sqrt(p.fc_psi)
    Vc_lb     = 2 * p.λ * sqrt_fc * bw * d
    Vs_max_lb = 8 * sqrt_fc * bw * d
    φVn_max_kip = 0.75 * (Vc_lb + Vs_max_lb) / 1000.0
    util_shear = p.Vu_kip / max(φVn_max_kip, 1e-6)

    # --- Net tensile strain ---
    util_strain = 0.005 / max(εt, 1e-8)

    # --- Minimum reinforcement (uses bw) ---
    util_as_min = p.ρ_min_aci / max(ρ, 1e-8)

    constraints = [util_flexure, util_shear, util_strain, util_as_min]

    # --- Deflection constraints (ACI §24.2) ---
    if p.w_dead_kiplf > 0
        # All in inches, psi, kip/in (consistent units)
        Ec = p.Ec_psi          # psi
        fr_val = p.fr_psi      # psi
        Es_psi = p.Es_ksi * 1000.0
        n_mod = Es_psi / max(Ec, 1.0)
        L = p.L_in             # inches
        # Convert kip/ft → kip/in for deflection formula
        w_d = p.w_dead_kiplf / 12.0   # kip/in
        w_l = p.w_live_kiplf / 12.0   # kip/in

        # T-beam gross moment of inertia Ig
        Af = bf * hf
        hw = max(h - hf, 0.01)
        Aw = bw * hw
        Ag = Af + Aw
        ȳ  = (Af * hf / 2 + Aw * (hf + hw / 2)) / max(Ag, 0.01)
        yb = h - ȳ
        Ig_f = bf * hf^3 / 12 + Af * (ȳ - hf / 2)^2
        Ig_w = bw * hw^3 / 12 + Aw * (hf + hw / 2 - ȳ)^2
        Ig = Ig_f + Ig_w

        # Cracking moment
        Mcr_lbin = fr_val * Ig / max(yb, 0.01)  # lb·in

        # Cracked Icr (T-beam transformed section)
        # Trial: NA in flange?
        k1_cr = 2 * n_mod * As / max(bf, 0.01)
        c_trial = (-k1_cr + sqrt(max(k1_cr^2 + 4 * k1_cr * d, 0.0))) / 2
        if c_trial ≤ hf
            c_cr = c_trial
            Icr = bf * c_cr^3 / 3 + n_mod * As * (d - c_cr)^2
        else
            a_q = bw / 2
            b_q = (bf - bw) * hf + n_mod * As
            c_q = -((bf - bw) * hf^2 / 2 + n_mod * As * d)
            disc = max(b_q^2 - 4 * a_q * c_q, 0.0)
            c_cr = (-b_q + sqrt(disc)) / max(2 * a_q, 0.01)
            Icr_fl = bf * hf^3 / 12 + bf * hf * (c_cr - hf / 2)^2
            Icr_web = bw * max(c_cr - hf, 0.0)^3 / 3
            Icr_st  = n_mod * As * (d - c_cr)^2
            Icr = Icr_fl + Icr_web + Icr_st
        end
        Icr = max(Icr, 1.0)

        # Service moments (kip·in) → convert to lb·in for consistency
        Ma_D_lbin  = _tbeam_nlp_service_moment(w_d, L, p.defl_support) * 1000.0   # kip·in → lb·in
        Ma_DL_lbin = _tbeam_nlp_service_moment(w_d + w_l, L, p.defl_support) * 1000.0

        # Effective moment of inertia (Branson)
        Ie_D  = _tbeam_nlp_branson(Mcr_lbin, Ma_D_lbin, Ig, Icr)
        Ie_DL = _tbeam_nlp_branson(Mcr_lbin, Ma_DL_lbin, Ig, Icr)

        # Deflections (inches): Δ = coeff × w × L⁴ / (E × Ie)
        # w in kip/in, L in inches, E in psi (= lb/in²), Ie in in⁴
        # → w (kip/in) × L⁴ (in⁴) / (E (psi) × Ie (in⁴)) gives kip·in³/lb = 1000·in
        # Need to convert w to lb/in: w_lb = w_kip × 1000
        w_d_lbin  = w_d * 1000.0      # lb/in
        w_dl_lbin = (w_d + w_l) * 1000.0

        coeff = _tbeam_nlp_defl_coeff(p.defl_support)
        Δ_D  = coeff * w_d_lbin * L^4 / max(Ec * Ie_D, 1.0)
        Δ_DL = coeff * w_dl_lbin * L^4 / max(Ec * Ie_DL, 1.0)
        Δ_LL = max(Δ_DL - Δ_D, 0.0)

        # Long-term
        λΔ = p.defl_ξ  # no compression steel assumed in NLP
        Δ_total = λΔ * Δ_D + Δ_LL

        # Deflection limits
        Δ_allow_LL  = L / 360.0
        Δ_allow_tot = L / 240.0

        util_defl_LL  = Δ_LL / max(Δ_allow_LL, 1e-6)
        util_defl_tot = Δ_total / max(Δ_allow_tot, 1e-6)

        push!(constraints, util_defl_LL)
        push!(constraints, util_defl_tot)
    end

    # --- Torsion adequacy (ACI 318-11 §11.5.3.1) ---
    # For T-beams: Aoh/ph based on web rectangle (closed stirrups in web)
    if p.Tu_kipin > 0
        c_ctr = p.cover_to_stirrup_ctr_in
        xo = max(bw - 2*c_ctr, 0.1)   # inner width to stirrup centerline
        yo = max(h - 2*c_ctr, 0.1)    # inner height to stirrup centerline
        Aoh = xo * yo
        ph  = 2 * (xo + yo)

        Vu_lb   = p.Vu_kip * 1000.0
        Tu_lbin = p.Tu_kipin * 1000.0

        τv = Vu_lb / max(bw * d, 0.01)
        τt = Tu_lbin * ph / max(1.7 * Aoh^2, 0.01)
        lhs = sqrt(τv^2 + τt^2)

        Vc_stress = 2 * p.λ * sqrt_fc
        rhs = 0.75 * (Vc_stress + 8 * sqrt_fc)

        util_torsion = lhs / max(rhs, 1e-6)
        push!(constraints, util_torsion)
    end

    return constraints
end

# ── NLP deflection helpers (bare Float64, no Unitful) ──

"""Service moment for NLP deflection constraint (kip·in)."""
function _tbeam_nlp_service_moment(w_kipin::Float64, L_in::Float64, support::Symbol)
    if support == :simply_supported
        return w_kipin * L_in^2 / 8
    elseif support == :cantilever
        return w_kipin * L_in^2 / 2
    elseif support == :one_end_continuous
        return w_kipin * L_in^2 / 10
    elseif support == :both_ends_continuous
        return w_kipin * L_in^2 / 16
    else
        return w_kipin * L_in^2 / 8
    end
end

"""Branson effective Ie for NLP (bare Float64)."""
function _tbeam_nlp_branson(Mcr::Float64, Ma::Float64, Ig::Float64, Icr::Float64)
    Ma ≤ 0 && return Ig
    Ma ≤ Mcr && return Ig
    ratio = Mcr / Ma
    Ie = Icr + (Ig - Icr) * ratio^3
    return min(Ie, Ig)
end

"""Deflection coefficient for NLP (support-dependent)."""
function _tbeam_nlp_defl_coeff(support::Symbol)
    if support == :simply_supported
        return 5.0 / 384.0
    elseif support == :cantilever
        return 1.0 / 8.0
    elseif support == :one_end_continuous
        return 1.0 / 185.0
    elseif support == :both_ends_continuous
        return 1.0 / 384.0
    else
        return 5.0 / 384.0
    end
end

# ==============================================================================
# Result Type
# ==============================================================================

"""
    RCTBeamNLPResult

Result from RC T-beam NLP optimization.

# Fields
- `section`: Constructed `RCTBeamSection` from optimal dimensions
- `bw_opt`, `h_opt`, `ρ_opt`: Continuous solver output (inches, dimensionless)
- `bw_final`, `h_final`: Dimensions after optional snapping (inches)
- `bf`, `hf`: Fixed flange dimensions (inches)
- `area_web`: Web cross-sectional area bw×h (in²)
- `status`: Solver termination status
- `iterations`: Number of solver iterations
"""
struct RCTBeamNLPResult
    section::RCTBeamSection
    bw_opt::Float64
    h_opt::Float64
    ρ_opt::Float64
    bw_final::Float64
    h_final::Float64
    bf::Float64
    hf::Float64
    area_web::Float64
    status::Symbol
    iterations::Int
end

"""
    build_rc_tbeam_nlp_result(p::RCTBeamNLPProblem, opt_result) -> RCTBeamNLPResult

Convert optimization result to `RCTBeamNLPResult` with practical section.
Snaps dimensions to increment grid and constructs an `RCTBeamSection`.
"""
function build_rc_tbeam_nlp_result(p::RCTBeamNLPProblem, opt_result)
    bw_opt, h_opt, ρ_opt = opt_result.minimizer

    if p.opts.snap
        incr = ustrip(u"inch", p.opts.dim_increment)
        bw_final = ceil(bw_opt / incr) * incr
        h_final  = ceil(h_opt  / incr) * incr
    else
        bw_final = bw_opt
        h_final  = h_opt
    end

    # Ensure constraints after snapping
    bw_final = min(bw_final, p.bf_in)
    h_final  = max(h_final, p.hf_in + 2.0)

    section = _build_tbeam_nlp_section(bw_final, h_final, p.bf_in, p.hf_in, ρ_opt, p.opts)

    # Fallback if rounding made it infeasible
    if isnothing(section) && p.opts.snap
        incr = ustrip(u"inch", p.opts.dim_increment)
        bw_final = min(bw_final + incr, p.bf_in)
        h_final += incr
        section = _build_tbeam_nlp_section(bw_final, h_final, p.bf_in, p.hf_in, ρ_opt, p.opts)
    end

    if isnothing(section)
        section = _build_tbeam_nlp_section(bw_opt, h_opt, p.bf_in, p.hf_in, ρ_opt, p.opts)
        bw_final, h_final = bw_opt, h_opt
    end

    return RCTBeamNLPResult(
        section,
        bw_opt, h_opt, ρ_opt,
        bw_final, h_final,
        p.bf_in, p.hf_in,
        bw_final * h_final,
        opt_result.status,
        opt_result.iterations,
    )
end

"""Build an RCTBeamSection from continuous NLP design variables."""
function _build_tbeam_nlp_section(
    bw_in::Real, h_in::Real, bf_in::Real, hf_in::Real,
    ρg::Real, opts::NLPBeamOptions,
)
    try
        cov_in    = ustrip(u"inch", opts.cover)
        d_stir_in = ustrip(u"inch", rebar(opts.stirrup_size).diameter)
        d_bar_in  = ustrip(u"inch", rebar(opts.bar_size).diameter)
        d_in = h_in - cov_in - d_stir_in - d_bar_in / 2

        As_required = ρg * bw_in * d_in
        bar = rebar(opts.bar_size)
        As_bar = ustrip(u"inch^2", bar.A)

        n_bars = max(2, ceil(Int, As_required / As_bar))
        n_bars = min(n_bars, 20)

        return RCTBeamSection(
            bw = bw_in * u"inch",
            h  = h_in * u"inch",
            bf = bf_in * u"inch",
            hf = hf_in * u"inch",
            bar_size = opts.bar_size,
            n_bars = n_bars,
            cover = opts.cover,
            stirrup_size = opts.stirrup_size,
        )
    catch e
        @warn "RC T-beam section construction failed" bw_in h_in bf_in hf_in ρg exception=(e, catch_backtrace())
        return nothing
    end
end

# ==============================================================================
# AbstractNLPProblem Interface: build_result
# ==============================================================================

"""Dispatch `build_result` to `build_rc_tbeam_nlp_result` for the T-beam problem."""
function build_result(p::RCTBeamNLPProblem, opt_result)
    build_rc_tbeam_nlp_result(p, opt_result)
end
