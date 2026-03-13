# ==============================================================================
# RC Beam NLP Problem
# ==============================================================================
# Continuous optimization problem for RC beam sizing.
# Interfaces with src/optimize/continuous_nlp.jl via AbstractNLPProblem.
#
# Design variables: [b, h, ρ] (width, depth in inches, reinforcement ratio)
# Objective: Minimize cross-sectional area (b × h)
# Constraints:
#   1. Flexure utilization:  Mu / φMn ≤ 1.0
#   2. Shear section adequacy: Vu / φVn_max ≤ 1.0
#   3. Net tensile strain:  εt ≥ 0.004  (ACI 318-11 §10.3.5)
#   4. Minimum reinforcement: As ≥ As,min (ACI 318-11 §10.5.1)

using Unitful
using Asap: kip, ksi, to_kip, to_kipft, to_inches, to_sqinches

# ==============================================================================
# Problem Type
# ==============================================================================

"""
    RCBeamNLPProblem <: AbstractNLPProblem

Continuous optimization problem for RC beam sizing.

Optimizes beam width (b), depth (h), and reinforcement ratio (ρ) to find
the minimum-area section satisfying ACI 318 requirements.

# Design Variables
- `x[1]` = b: Beam width (inches)
- `x[2]` = h: Beam depth (inches)
- `x[3]` = ρ: Longitudinal reinforcement ratio (dimensionless)

# Constraints
- Flexure utilization: Mu / φMn ≤ 1.0
- Shear section adequacy: Vu / φVn_max ≤ 1.0
- Net tensile strain: εt ≥ 0.004 (ACI 318-11 §10.3.5 — beams must not be
  compression-controlled; prevents over-reinforcement)
- Minimum reinforcement: ρ ≥ ρ_min (ACI 318-11 §10.5.1)
- (optional) Torsion adequacy: shear-torsion interaction ≤ 1.0 (ACI §11.5.3.1)
"""
struct RCBeamNLPProblem <: AbstractNLPProblem
    Mu_kipft::Float64
    Vu_kip::Float64
    opts::NLPBeamOptions

    # Material properties (cached in ACI units)
    fc_psi::Float64
    fy_psi::Float64
    fyt_psi::Float64      # Stirrup yield strength (psi) — for torsion
    Es_ksi::Float64
    λ::Float64

    # Cached cover offset for effective depth (inches)
    cover_offset_in::Float64
    # Distance from face to stirrup centerline (inches) — for torsion Aoh
    cover_to_stirrup_ctr_in::Float64

    # ACI 318-11 §10.5.1 minimum reinforcement ratio
    ρ_min_aci::Float64

    # Bounds in inches
    b_min::Float64
    b_max::Float64
    h_min::Float64
    h_max::Float64

    # Torsion demand (kip·in). 0.0 = no torsion constraint.
    Tu_kipin::Float64
end

"""
    RCBeamNLPProblem(Mu, Vu, opts; Tu=0.0)

Construct an RC beam NLP problem from factored demands and options.
Converts Unitful inputs to bare ACI units (kip, kip-ft, inches, psi).
"""
function RCBeamNLPProblem(Mu, Vu, opts::NLPBeamOptions; Tu=0.0)
    fc = fc_ksi(opts.material)
    fy = fy_ksi(opts.rebar_material)
    Es = Es_ksi(opts.rebar_material)
    λ_val = opts.material.λ

    Mu_kipft = to_kipft(Mu)
    Vu_kip   = to_kip(Vu)

    # Cover offset: cover + stirrup_dia + bar_dia/2
    cov_in    = ustrip(u"inch", opts.cover)
    d_stir_in = ustrip(u"inch", rebar(opts.stirrup_size).diameter)
    d_bar_in  = ustrip(u"inch", rebar(opts.bar_size).diameter)
    cover_offset = cov_in + d_stir_in + d_bar_in / 2
    c_ctr = cov_in + d_stir_in / 2   # face → stirrup centerline

    b_min = ustrip(u"inch", opts.min_width)
    b_max = ustrip(u"inch", opts.max_width)
    h_min = ustrip(u"inch", opts.min_depth)
    h_max = ustrip(u"inch", opts.max_depth)

    # ACI 318-11 §10.5.1: As,min = max(3√f'c/fy, 200/fy) × bw × d
    # Since As = ρ × b × d, the minimum ρ is:
    fc_psi = fc * 1000.0
    fy_psi = fy * 1000.0
    fyt_psi = fy_psi  # Assume stirrup grade = main rebar grade for NLP
    ρ_min_aci = max(3.0 * sqrt(fc_psi) / fy_psi, 200.0 / fy_psi)

    # Torsion demand
    Tu_kipin_val = if Tu isa Unitful.Quantity
        abs(ustrip(u"lbf*inch", Tu)) / 1000.0
    else
        abs(Float64(Tu))
    end

    RCBeamNLPProblem(
        Mu_kipft, Vu_kip, opts,
        fc_psi, fy_psi, fyt_psi, Es, λ_val,
        cover_offset, c_ctr,
        ρ_min_aci,
        b_min, b_max, h_min, h_max,
        Tu_kipin_val,
    )
end

# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

"""Number of design variables: b, h, ρ."""
n_variables(::RCBeamNLPProblem) = 3

"""Variable bounds for RC beam NLP: [b_min, h_min, 0.003] to [b_max, h_max, 0.015]."""
function variable_bounds(p::RCBeamNLPProblem)
    lb = [p.b_min, p.h_min, 0.003]   # ACI practical ρ_min
    ub = [p.b_max, p.h_max, 0.015]   # Practical ρ_max for beams (lower to keep εt ≥ 0.004 after bar rounding)
    return (lb, ub)
end

"""Midrange initial guess for RC beam NLP: [b_mid, h_mid, 0.012]."""
function initial_guess(p::RCBeamNLPProblem)
    # Start at midrange dimensions and low reinforcement
    b0 = (p.b_min + p.b_max) / 2
    h0 = (p.h_min + p.h_max) / 2
    return [b0, h0, 0.012]
end

"""Human-readable variable names for solver output."""
variable_names(::RCBeamNLPProblem) = ["b (in)", "h (in)", "ρ"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

"""Objective function: cross-sectional area with optional ρ weighting."""
function objective_fn(p::RCBeamNLPProblem, x::Vector{Float64})
    b, h, ρ = x
    Ag = b * h

    obj = p.opts.objective
    if obj isa MinVolume
        # Gross area with ρ penalty — prevents pegging at ρ_max.
        return Ag * (1 + 2.0 * ρ)
    elseif obj isa MinWeight
        γ_c = ustrip(u"lb/ft^3", p.opts.material.ρ)
        γ_s = ustrip(u"lb/ft^3", p.opts.rebar_material.ρ)
        return Ag * ((1 - ρ) * γ_c + ρ * γ_s)
    else
        return Ag * (1 + 2.0 * ρ)
    end
end

# ==============================================================================
# AbstractNLPProblem Interface: Constraints
# ==============================================================================

"""Number of constraints: 4 base + 1 torsion (if Tu > 0)."""
function n_constraints(p::RCBeamNLPProblem)
    nc = 4
    p.Tu_kipin > 0 && (nc += 1)  # torsion adequacy (ACI §11.5.3.1)
    return nc
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::RCBeamNLPProblem)
    names = [
        "flexure utilization",
        "shear adequacy",
        "net tensile strain (εt ≥ 0.005)",
        "min reinforcement (§10.5.1)",
    ]
    p.Tu_kipin > 0 && push!(names, "torsion adequacy (§11.5.3.1)")
    return names
end

"""Constraint bounds: all utilizations ≤ 1.0, no lower bound."""
function constraint_bounds(p::RCBeamNLPProblem)
    nc = n_constraints(p)
    return (fill(-Inf, nc), fill(1.0, nc))
end

"""
    constraint_fns(p::RCBeamNLPProblem, x) -> Vector{Float64}

Evaluate ACI 318 constraint utilizations for RC beam at design point `x`.
Returns utilization ratios: flexure, shear adequacy, εt ≥ 0.005, ρ ≥ ρ_min,
plus optional torsion adequacy per ACI 318-11 §11.5.3.1.
"""
function constraint_fns(p::RCBeamNLPProblem, x::Vector{Float64})
    b, h, ρ = x

    # Effective depth
    d = h - p.cover_offset_in
    d = max(d, 1.0)  # Prevent negative d

    # Steel area
    As = ρ * b * d

    # --- Flexure (Whitney stress block) ---
    a = As * p.fy_psi / (0.85 * p.fc_psi * b)
    β1 = _beta1_from_fc_psi(p.fc_psi)
    c = a / max(β1, 0.5)

    εcu = 0.003  # ACI 318-11 §10.2.3
    εt = c > 0 ? εcu * (d - c) / max(c, 0.01) : 0.0

    φ = flexure_phi(εt)

    Mn_lbin = As * p.fy_psi * (d - a / 2)
    φMn_kipft = φ * Mn_lbin / 12_000.0

    util_flexure = p.Mu_kipft / max(φMn_kipft, 1e-6)

    # --- Shear adequacy ---
    sqrt_fc = sqrt(p.fc_psi)
    Vc_lb     = 2 * p.λ * sqrt_fc * b * d
    Vs_max_lb = 8 * sqrt_fc * b * d
    φVn_max_kip = 0.75 * (Vc_lb + Vs_max_lb) / 1000.0

    util_shear = p.Vu_kip / max(φVn_max_kip, 1e-6)

    # --- Net tensile strain (ACI 318-11 §10.3.5) ---
    # Beams must have εt ≥ 0.004 (absolute min).  We target εt ≥ 0.005
    # to ensure tension-controlled behavior (φ = 0.9) and provide margin
    # for bar discretization which typically increases ρ and decreases εt.
    util_strain = 0.005 / max(εt, 1e-8)

    # --- Minimum reinforcement (ACI 318-11 §10.5.1) ---
    # ρ_min = max(3√f'c / fy, 200 / fy)  (precomputed in constructor)
    util_as_min = p.ρ_min_aci / max(ρ, 1e-8)

    constraints = [util_flexure, util_shear, util_strain, util_as_min]

    # --- Torsion adequacy (ACI 318-11 §11.5.3.1) ---
    # Shear-torsion interaction: √[(Vu/(bw·d))² + (Tu·ph/(1.7·Aoh²))²] ≤ φ·(Vc/(bw·d) + 8·√f'c)
    # Already a smooth function (sqrt of sum of squares).
    if p.Tu_kipin > 0
        c_ctr = p.cover_to_stirrup_ctr_in
        xo = max(b - 2*c_ctr, 0.1)   # inner width to stirrup centerline
        yo = max(h - 2*c_ctr, 0.1)   # inner height to stirrup centerline
        Aoh = xo * yo
        ph  = 2 * (xo + yo)

        Vu_lb   = p.Vu_kip * 1000.0
        Tu_lbin = p.Tu_kipin * 1000.0

        τv = Vu_lb / max(b * d, 0.01)
        τt = Tu_lbin * ph / max(1.7 * Aoh^2, 0.01)
        lhs = sqrt(τv^2 + τt^2)

        Vc_stress = 2 * p.λ * sqrt_fc        # Vc/(bw·d) per unit area
        rhs = 0.75 * (Vc_stress + 8 * sqrt_fc)

        util_torsion = lhs / max(rhs, 1e-6)
        push!(constraints, util_torsion)
    end

    return constraints
end


# ==============================================================================
# Result Type
# ==============================================================================

"""
    RCBeamNLPResult

Result from RC beam NLP optimization.

# Fields
- `section`: Constructed `RCBeamSection` from optimal dimensions
- `b_opt`, `h_opt`, `ρ_opt`: Continuous solver output (inches, dimensionless)
- `b_final`, `h_final`: Dimensions after optional snapping (inches)
- `area`: Final cross-sectional area b×h (in²)
- `status`: Solver termination status
- `iterations`: Number of solver iterations
"""
struct RCBeamNLPResult
    section::RCBeamSection
    b_opt::Float64
    h_opt::Float64
    ρ_opt::Float64
    b_final::Float64
    h_final::Float64
    area::Float64
    status::Symbol
    iterations::Int
end

"""
    build_rc_beam_nlp_result(p::RCBeamNLPProblem, opt_result) -> RCBeamNLPResult

Convert optimization result to `RCBeamNLPResult` with practical section.
Snaps dimensions to increment grid and constructs an `RCBeamSection`.
"""
function build_rc_beam_nlp_result(p::RCBeamNLPProblem, opt_result)
    b_opt, h_opt, ρ_opt = opt_result.minimizer

    if p.opts.snap
        incr = ustrip(u"inch", p.opts.dim_increment)
        b_final = ceil(b_opt / incr) * incr
        h_final = ceil(h_opt / incr) * incr
    else
        b_final = b_opt
        h_final = h_opt
    end

    section = _build_beam_nlp_section(b_final, h_final, ρ_opt, p.opts)

    # Fallback if rounding made it infeasible
    if isnothing(section) && p.opts.snap
        incr = ustrip(u"inch", p.opts.dim_increment)
        b_final += incr
        h_final += incr
        section = _build_beam_nlp_section(b_final, h_final, ρ_opt, p.opts)
    end

    if isnothing(section)
        section = _build_beam_nlp_section(b_opt, h_opt, ρ_opt, p.opts)
        b_final, h_final = b_opt, h_opt
    end

    return RCBeamNLPResult(
        section,
        b_opt, h_opt, ρ_opt,
        b_final, h_final,
        b_final * h_final,
        opt_result.status,
        opt_result.iterations,
    )
end

"""Build an RCBeamSection from continuous NLP design variables."""
function _build_beam_nlp_section(
    b_in::Real, h_in::Real, ρg::Real, opts::NLPBeamOptions
)
    try
        cov_in    = ustrip(u"inch", opts.cover)
        d_stir_in = ustrip(u"inch", rebar(opts.stirrup_size).diameter)
        d_bar_in  = ustrip(u"inch", rebar(opts.bar_size).diameter)
        d_in = h_in - cov_in - d_stir_in - d_bar_in / 2

        As_required = ρg * b_in * d_in
        bar = rebar(opts.bar_size)
        As_bar = ustrip(u"inch^2", bar.A)

        n_bars = max(2, ceil(Int, As_required / As_bar))
        n_bars = min(n_bars, 20)

        return RCBeamSection(
            b = b_in * u"inch",
            h = h_in * u"inch",
            bar_size = opts.bar_size,
            n_bars = n_bars,
            cover = opts.cover,
            stirrup_size = opts.stirrup_size,
        )
    catch e
        @warn "RC beam section construction failed" b_in h_in ρg exception=(e, catch_backtrace())
        return nothing
    end
end

# ==============================================================================
# AbstractNLPProblem Interface: evaluate + build_result
# ==============================================================================

"""Dispatch `build_result` to `build_rc_beam_nlp_result` for the RC beam problem."""
function build_result(p::RCBeamNLPProblem, opt_result)
    build_rc_beam_nlp_result(p, opt_result)
end


# ╔═══════════════════════════════════════════════════════════════════════════╗
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
- Web slenderness: h/tw ≤ limit
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
    SteelWBeamNLPProblem(Mu, Vu, geometry, opts; Ix_min, Tu, L_span)

Construct a steel W-beam NLP problem from factored demands and options.
Converts Unitful inputs to bare AISC units (kip, kip-ft, inches, ksi).
"""
function SteelWBeamNLPProblem(
    Mu, Vu,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions;
    Ix_min = nothing,
    Ix_min_total = nothing,
    Tu = 0.0,
    L_span = nothing,
)
    E_ksi = to_ksi(opts.material.E)
    G_ksi = to_ksi(opts.material.G)
    Fy_ksi = to_ksi(opts.material.Fy)
    
    Mu_kipft = to_kipft(Mu)
    Vu_kip = to_kip(Vu)
    
    Lb_in = to_inches(geometry.Lb)
    Cb = geometry.Cb
    
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
             "web slenderness (h/tw)"]
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
    
    # ── Web slenderness (AISC F13.2: h/tw ≤ 260) ──
    util_web = _smooth_max(h, 0.1; k=k) / (tw * 260.0)
    
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
    
    ρ_steel = 490.0  # lb/ft³
    weight_per_ft = A * ρ_steel / 144.0
    
    return WColumnNLPResult(
        section,
        d_opt, bf_opt, tf_opt, tw_opt,
        d_final, bf_final, tf_final, tw_final,
        A, weight_per_ft,
        Ix, Iy, rx, ry,
        opt_result.status,
        opt_result.iterations
    )
end

"""Dispatch `build_result` to `build_w_beam_nlp_result` for W-beam problem."""
function build_result(p::SteelWBeamNLPProblem, opt_result)
    build_w_beam_nlp_result(p, opt_result)
end


# ╔═══════════════════════════════════════════════════════════════════════════╗
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
    
    section = HSSRectSection(H_final * u"inch", B_final * u"inch", t_final * u"inch")
    
    area = ustrip(u"inch^2", section.A)
    ρ_steel = 490.0
    weight_per_ft = area * ρ_steel / 144.0
    
    return HSSColumnNLPResult(
        section,
        B_opt, H_opt, t_opt,
        B_final, H_final, t_final,
        area, weight_per_ft,
        opt_result.status,
        opt_result.iterations
    )
end

"""Dispatch `build_result` to `build_hss_beam_nlp_result` for HSS beam problem."""
function build_result(p::SteelHSSBeamNLPProblem, opt_result)
    build_hss_beam_nlp_result(p, opt_result)
end
