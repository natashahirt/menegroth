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
#
# The snapped section is checked with ACIBeamChecker in `size_rc_beam_nlp`
# (the catalog sizer's check, including hogging). Top steel is not an NLP
# design variable, so that check may return `:infeasible`.

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
    # Signed axial (kip). Positive = compression (Eq. 11-4); negative = tension
    # (Eq. 11-8, Vc ≥ 0). 0.0 = shear and flexure only (Eq. 11-3).
    Nu_kip::Float64
end

"""
    RCBeamNLPProblem(Mu, Vu, opts; Tu=0.0, Nu=0.0)

Construct an RC beam NLP problem from factored demands and options.
Converts Unitful inputs to bare ACI units (kip, kip-ft, inches, psi).
`Nu` is signed: compression positive (ACI 318-11 Eq. 11-4), tension
negative (Eq. 11-8). Public default is `Nu = 0` (no axial modifier).
"""
function RCBeamNLPProblem(Mu, Vu, opts::NLPBeamOptions; Tu=0.0, Nu=0.0)
    _require_nlp_objective(
        opts.objective, (MinVolume, MinWeight); problem="RC beam NLP")
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

    # Signed axial: preserve sign (tension is negative).
    Nu_kip_val = Nu isa Unitful.Quantity ? to_kip(Nu) : Float64(Nu)

    RCBeamNLPProblem(
        Mu_kipft, Vu_kip, opts,
        fc_psi, fy_psi, fyt_psi, Es, λ_val,
        cover_offset, c_ctr,
        ρ_min_aci,
        b_min, b_max, h_min, h_max,
        Tu_kipin_val,
        Nu_kip_val,
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

    # --- Shear adequacy (signed Nu via Eq. 11-4 / 11-8) ---
    # ACI 318-11 §11.2.1.2 Eq. (11-4) / §11.2.2.3 Eq. (11-8) —
    # corpus: aci-318-11, pages 168 / 170. Vc ≥ 0.
    sqrt_fc = sqrt(p.fc_psi)
    Ag_in2 = b * h
    φVn_max_kip = _φVn_with_axial(b, d, Ag_in2, Ag_in2, p.fc_psi, p.λ, p.Nu_kip)

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
