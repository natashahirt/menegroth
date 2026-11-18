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

"""One shear row of an RC beam NLP. `Nu_kip` is compression-positive."""
struct RCBeamNLPShearCase
    Vu_kip::Float64
    Nu_kip::Float64
    Tu_kipin::Float64
end

"""`Tu` as kip·in. A bare number is already kip·in."""
function _torsion_kipin(Tu)
    Tu isa Unitful.Quantity && return abs(ustrip(u"lbf*inch", Tu)) / 1000.0
    return abs(Float64(Tu))
end

"""
Shear rows the beam NLP constrains.

`shear_cases === nothing` keeps today's single row, built from the scalar
`Vu`, `Nu`, and `Tu`. A vector is one row per load case: `(Vu, Nu, Tu)`,
each a bare kip value or a unitful force / moment. `Nu` stays signed.
"""
function _beam_nlp_shear_cases(Vu_kip, Nu_kip, Tu_kipin, shear_cases)
    shear_cases === nothing &&
        return [RCBeamNLPShearCase(Vu_kip, Nu_kip, Tu_kipin)]
    out = RCBeamNLPShearCase[]
    for c in shear_cases
        if c isa RCBeamNLPShearCase
            push!(out, c)
            continue
        end
        Vu, Nu, Tu = c
        push!(out, RCBeamNLPShearCase(
            Vu isa Unitful.Quantity ? to_kip(Vu) : Float64(Vu),
            Nu isa Unitful.Quantity ? to_kip(Nu) : Float64(Nu),
            _torsion_kipin(Tu),
        ))
    end
    isempty(out) && throw(ArgumentError("RC beam NLP shear_cases is empty"))
    return out
end

"""
Sagging moments the beam NLP constrains, in kip·ft.

`flexure_cases === nothing` keeps the single `Mu` envelope. A vector is one
row per load case. The envelope is added when it exceeds every case, so a
shell moment that is not on a station row still binds. Each row uses the
same Whitney φMn (ACI 318-11 §10.2).
"""
function _beam_nlp_flexure_cases(Mu_kipft, flexure_cases)
    flexure_cases === nothing && return [Mu_kipft]
    out = Float64[]
    for m in flexure_cases
        push!(out, m isa Unitful.Quantity ? to_kipft(m) : Float64(m))
    end
    isempty(out) && throw(ArgumentError("RC beam NLP flexure_cases is empty"))
    maximum(out) + 1e-9 < Mu_kipft && push!(out, Mu_kipft)
    return out
end

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
    # One shear (and, when `Tu_kipin > 0`, torsion) row per load case.
    # The scalars above are the first case, kept for the single-row API.
    shear_cases::Vector{RCBeamNLPShearCase}
    # One sagging moment per load case, kip·ft. The scalar `Mu_kipft` is the
    # first case when the caller passed no vector.
    flexure_cases::Vector{Float64}

    # Uniform-load deflection (ACI 318-11 §9.5.2). `w_dead_kiplf == 0` skips it.
    w_dead_kiplf::Float64
    w_live_kiplf::Float64
    L_in::Float64
    Ec_psi::Float64
    fr_psi::Float64
    defl_support::Symbol
    defl_ξ::Float64
    defl_sustained_live::Float64
end

"""
    RCBeamNLPProblem(Mu, Vu, opts; Tu=0.0, Nu=0.0, shear_cases=nothing,
                     flexure_cases=nothing, w_dead=nothing, w_live=nothing,
                     L_span=nothing, support=:simply_supported, ξ=2.0,
                     sustained_live_fraction=0.0)

Construct an RC beam NLP problem from factored demands and options.
Converts Unitful inputs to bare ACI units (kip, kip-ft, inches, psi).
`Nu` is signed: compression positive (ACI 318-11 Eq. 11-4), tension
negative (Eq. 11-8). Public default is `Nu = 0` (no axial modifier).
`shear_cases` replaces that one shear row with one row per load case.
Each case is `(Vu, Nu, Tu)`. `flexure_cases` is one sagging moment per
load case; omitted, flexure is the single `Mu` envelope.
`w_dead`, `w_live`, and `L_span` together add the rectangular deflection
check of [`design_beam_deflection`](@ref). Omitting any one of them skips it.
"""
function RCBeamNLPProblem(Mu, Vu, opts::NLPBeamOptions; Tu=0.0, Nu=0.0,
                          shear_cases=nothing, flexure_cases=nothing,
                          w_dead=nothing, w_live=nothing, L_span=nothing,
                          support::Symbol=:simply_supported, ξ::Float64=2.0,
                          sustained_live_fraction::Real=0.0)
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

    Tu_kipin_val = _torsion_kipin(Tu)

    # Signed axial: preserve sign (tension is negative).
    Nu_kip_val = Nu isa Unitful.Quantity ? to_kip(Nu) : Float64(Nu)
    cases = _beam_nlp_shear_cases(Vu_kip, Nu_kip_val, Tu_kipin_val, shear_cases)
    moments = _beam_nlp_flexure_cases(Mu_kipft, flexure_cases)
    wd, wl, L_in, Ec_psi, fr_psi = _rect_nlp_service(fc_psi, w_dead, w_live, L_span)

    RCBeamNLPProblem(
        Mu_kipft, Vu_kip, opts,
        fc_psi, fy_psi, fyt_psi, Es, λ_val,
        cover_offset, c_ctr,
        ρ_min_aci,
        b_min, b_max, h_min, h_max,
        Tu_kipin_val,
        Nu_kip_val,
        cases,
        moments,
        wd, wl, L_in, Ec_psi, fr_psi,
        support, Float64(ξ), _as_sustained_live_fraction(sustained_live_fraction),
    )
end

"""
Service loads for the rectangular NLP deflection check.

All three of `w_dead`, `w_live`, and `L_span` are required. A bare span is
feet, matching the T-beam NLP. `Ec` uses `wc = 150` pcf, the default of
[`design_beam_deflection`](@ref) (ACI 318-11 §8.5.1). `fr = 7.5√f'c`
(§9.5.2.3), the same `fr` that function calls.
"""
function _rect_nlp_service(fc_psi, w_dead, w_live, L_span)
    if isnothing(w_dead) || isnothing(w_live) || isnothing(L_span)
        return 0.0, 0.0, 0.0, 0.0, 0.0
    end
    wd = w_dead isa Unitful.Quantity ? ustrip(kip / u"ft", w_dead) : Float64(w_dead)
    wl = w_live isa Unitful.Quantity ? ustrip(kip / u"ft", w_live) : Float64(w_live)
    L_in = L_span isa Unitful.Quantity ? ustrip(u"inch", L_span) : Float64(L_span) * 12.0
    Ec_psi = 33.0 * 150.0^1.5 * sqrt(fc_psi)
    fr_psi = 7.5 * sqrt(fc_psi)
    return wd, wl, L_in, Ec_psi, fr_psi
end

"""
Live and total deflection utilizations of a rectangular section.

Same arithmetic as [`design_beam_deflection`](@ref): Ig = bh³/12, transformed
Icr, Branson Ie at dead, sustained, and dead-plus-live, then Table 9.5(b).
ACI 318-11 §9.5.2 (corpus: aci-318-11, PDF pp. 131–133). No compression steel,
so λΔ = ξ (§9.5.2.5, Eq. 9-11).
"""
function _rect_nlp_deflection_utils(p::RCBeamNLPProblem, b, h, d, As)
    Ec = p.Ec_psi
    Es_psi = p.Es_ksi * 1000.0
    n_mod = Es_psi / max(Ec, 1.0)
    L = p.L_in
    w_d = p.w_dead_kiplf / 12.0
    w_l = p.w_live_kiplf / 12.0

    Ig = b * h^3 / 12
    Mcr = p.fr_psi * Ig / max(h / 2, 0.01)

    k1 = 2 * n_mod * As / max(b, 0.01)
    c = (-k1 + sqrt(max(k1^2 + 4 * k1 * d, 0.0))) / 2
    Icr = max(b * c^3 / 3 + n_mod * As * (d - c)^2, 1.0)

    Ma_D  = _tbeam_nlp_service_moment(w_d, L, p.defl_support) * 1000.0
    Ma_DL = _tbeam_nlp_service_moment(w_d + w_l, L, p.defl_support) * 1000.0
    w_s = w_d + p.defl_sustained_live * w_l
    Ma_S = _tbeam_nlp_service_moment(w_s, L, p.defl_support) * 1000.0
    Ie_D  = _tbeam_nlp_branson(Mcr, Ma_D, Ig, Icr)
    Ie_DL = _tbeam_nlp_branson(Mcr, Ma_DL, Ig, Icr)
    Ie_S  = _tbeam_nlp_branson(Mcr, Ma_S, Ig, Icr)

    coeff = _tbeam_nlp_defl_coeff(p.defl_support)
    Δ_D  = coeff * (w_d * 1000.0) * L^4 / max(Ec * Ie_D, 1.0)
    Δ_DL = coeff * ((w_d + w_l) * 1000.0) * L^4 / max(Ec * Ie_DL, 1.0)
    Δ_S  = coeff * (w_s * 1000.0) * L^4 / max(Ec * Ie_S, 1.0)
    Δ_LL = max(Δ_DL - Δ_D, 0.0)
    Δ_total = p.defl_ξ * Δ_S + (Δ_DL - Δ_S)
    return (Δ_LL / max(L / 360.0, 1e-6), Δ_total / max(L / 240.0, 1e-6))
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

"""Number of constraints: one flexure per case, one shear per case, strain, ρmin, optional deflection, plus torsion per case with Tu > 0."""
function n_constraints(p::RCBeamNLPProblem)
    nc = 2 + length(p.flexure_cases) + length(p.shear_cases)
    p.w_dead_kiplf > 0 && (nc += 2)
    return nc + count(c -> c.Tu_kipin > 0, p.shear_cases)
end

"""Human-readable constraint names for solver diagnostics."""
function constraint_names(p::RCBeamNLPProblem)
    names = String[]
    if length(p.flexure_cases) == 1
        push!(names, "flexure utilization")
    else
        for i in eachindex(p.flexure_cases)
            push!(names, "flexure utilization (case $i)")
        end
    end
    if length(p.shear_cases) == 1
        push!(names, "shear adequacy")
    else
        for i in eachindex(p.shear_cases)
            push!(names, "shear adequacy (case $i)")
        end
    end
    push!(names, "net tensile strain (εt ≥ 0.005)")
    push!(names, "min reinforcement (§10.5.1)")
    if p.w_dead_kiplf > 0
        push!(names, "deflection LL (L/360)")
        push!(names, "deflection total (L/240)")
    end
    for (i, c) in enumerate(p.shear_cases)
        c.Tu_kipin > 0 || continue
        push!(names, length(p.shear_cases) == 1 ?
            "torsion adequacy (§11.5.3.1)" : "torsion adequacy (case $i)")
    end
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

    # One sagging row per load case. φMn does not depend on the case, so the
    # largest Mu binds. The rows stay separate so a case above the scalar
    # envelope is not dropped.
    constraints = Float64[]
    for Mu_kipft in p.flexure_cases
        push!(constraints, Mu_kipft / max(φMn_kipft, 1e-6))
    end

    # --- Shear adequacy, one row per load case (signed Nu via Eq. 11-4 / 11-8) ---
    # ACI 318-11 §11.2.1.2 Eq. (11-4) / §11.2.2.3 Eq. (11-8) —
    # corpus: aci-318-11, pages 168 / 170. Vc ≥ 0.
    # Each case pairs its own Vu with the axial at that case. Pairing the
    # largest compression with the largest shear raises Vc and is unconservative.
    sqrt_fc = sqrt(p.fc_psi)
    Ag_in2 = b * h
    for sc in p.shear_cases
        φVn_max_kip = _φVn_with_axial(b, d, Ag_in2, Ag_in2, p.fc_psi, p.λ, sc.Nu_kip)
        push!(constraints, sc.Vu_kip / max(φVn_max_kip, 1e-6))
    end

    # --- Net tensile strain (ACI 318-11 §10.3.5) ---
    # Beams must have εt ≥ 0.004 (absolute min).  We target εt ≥ 0.005
    # to ensure tension-controlled behavior (φ = 0.9) and provide margin
    # for bar discretization which typically increases ρ and decreases εt.
    util_strain = 0.005 / max(εt, 1e-8)

    # --- Minimum reinforcement (ACI 318-11 §10.5.1) ---
    # ρ_min = max(3√f'c / fy, 200 / fy)  (precomputed in constructor)
    util_as_min = p.ρ_min_aci / max(ρ, 1e-8)
    push!(constraints, util_strain, util_as_min)

    # ACI 318-11 §9.5.2. Same check as design_beam_deflection.
    if p.w_dead_kiplf > 0
        ll, tot = _rect_nlp_deflection_utils(p, b, h, d, As)
        push!(constraints, ll, tot)
    end

    # --- Torsion adequacy (ACI 318-11 §11.5.3.1) ---
    # Shear-torsion interaction: √[(Vu/(bw·d))² + (Tu·ph/(1.7·Aoh²))²] ≤ φ·(Vc/(bw·d) + 8·√f'c)
    # One row per case that has torsion, using that case's Vu and Tu.
    c_ctr = p.cover_to_stirrup_ctr_in
    for sc in p.shear_cases
        sc.Tu_kipin > 0 || continue
        xo = max(b - 2*c_ctr, 0.1)   # inner width to stirrup centerline
        yo = max(h - 2*c_ctr, 0.1)   # inner height to stirrup centerline
        Aoh = xo * yo
        ph  = 2 * (xo + yo)

        Vu_lb   = sc.Vu_kip * 1000.0
        Tu_lbin = sc.Tu_kipin * 1000.0

        τv = Vu_lb / max(b * d, 0.01)
        τt = Tu_lbin * ph / max(1.7 * Aoh^2, 0.01)
        lhs = sqrt(τv^2 + τt^2)

        Vc_stress = 2 * p.λ * sqrt_fc        # Vc/(bw·d) per unit area
        rhs = 0.75 * (Vc_stress + 8 * sqrt_fc)

        push!(constraints, lhs / max(rhs, 1e-6))
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
