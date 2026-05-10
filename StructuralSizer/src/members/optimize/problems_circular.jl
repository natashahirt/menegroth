# ==============================================================================
# RC Circular Column NLP Problem
# ==============================================================================
# Continuous optimization problem for circular RC column sizing.
# Interfaces with src/optimize/continuous_nlp.jl via AbstractNLPProblem.
#
# Design variables: [D, ρg] (diameter in inches, reinforcement ratio)
# Objective: Minimize cross-sectional area (π/4 × D²)
# Constraints: ACI 318 P-M interaction, slenderness, reinforcement limits

using Unitful
using Asap: kip, ksi, to_kip, to_kipft, to_inches, to_sqinches, pcf

# ==============================================================================
# Problem Type
# ==============================================================================

"""
    RCCircularNLPProblem <: AbstractNLPProblem

Continuous optimization problem for circular RC column sizing.

Implements the `AbstractNLPProblem` interface for use with `optimize_continuous`.
Treats column diameter (D) and reinforcement ratio (ρg) as continuous design
variables, finding the minimum-area section that satisfies ACI 318.

# Design Variables
- `x[1]` = D: Column diameter (inches)
- `x[2]` = ρg: Longitudinal reinforcement ratio (dimensionless, 0.01-0.08)

# Constraints
- P-M interaction: utilization ≤ 1.0

# Usage
```julia
demand = RCColumnDemand(1; Pu=500.0, Mux=200.0)  # kip, kip-ft
geometry = ConcreteMemberGeometry(4.0u"m"; k=1.0)
opts = NLPColumnOptions(material=NWC_5000, tie_type=:spiral)

problem = RCCircularNLPProblem(demand, geometry, opts)
result = optimize_continuous(problem; solver=:ipopt)

D_opt, ρ_opt = result.minimizer
```
"""
struct RCCircularNLPProblem <: AbstractNLPProblem
    demand::RCColumnDemand
    geometry::ConcreteMemberGeometry
    opts::NLPColumnOptions

    # Material tuple for P-M calculations (cached)
    mat::NamedTuple{(:fc, :fy, :Es, :εcu), NTuple{4, Float64}}

    # Cached demand values in ACI units (kip, kip-ft)
    Pu_kip::Float64
    Mux_kipft::Float64

    # Diameter bounds in inches
    D_min::Float64
    D_max::Float64
end

"""
    RCCircularNLPProblem(demand, geometry, opts)

Construct an RC circular column NLP problem from demand, geometry, and options.
"""
function RCCircularNLPProblem(
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions
)
    mat = to_material_tuple(opts.material, fy_ksi(opts.rebar_material), Es_ksi(opts.rebar_material))

    Pu_kip = to_kip(demand.Pu)
    Mux_kipft = to_kipft(demand.Mux)

    D_min = ustrip(u"inch", opts.min_dim)
    D_max = ustrip(u"inch", opts.max_dim)

    RCCircularNLPProblem(
        demand, geometry, opts, mat,
        Pu_kip, Mux_kipft,
        D_min, D_max
    )
end

# ==============================================================================
# AbstractNLPProblem Interface: Core
# ==============================================================================

"""Number of design variables: D, ρg."""
n_variables(::RCCircularNLPProblem) = 2

"""Variable bounds for circular column NLP: [D_min, 0.01] to [D_max, ρ_max]."""
function variable_bounds(p::RCCircularNLPProblem)
    lb = [p.D_min, 0.01]   # ACI min ρ = 0.01
    ub = [p.D_max, p.opts.ρ_max]  # Practical ρ limit (default 0.06)
    return (lb, ub)
end

"""Initial guess from simplified axial capacity estimate: [D0, 0.04]."""
function initial_guess(p::RCCircularNLPProblem)
    # Estimate from simplified axial capacity: Ag ≈ Pu / (0.40 × f'c)
    Ag_est = p.Pu_kip / (0.40 * p.mat.fc)
    D0 = sqrt(max(Ag_est, (p.D_min/2)^2 * π) * 4 / π)
    D0 = clamp(D0, p.D_min, p.D_max)
    return [D0, 0.04]  # Midrange reinforcement
end

"""Human-readable variable names for solver output."""
variable_names(::RCCircularNLPProblem) = ["D (in)", "ρg"]

# ==============================================================================
# AbstractNLPProblem Interface: Objective
# ==============================================================================

"""Objective function: circular cross-sectional area with ρ weighting per objective type."""
function objective_fn(p::RCCircularNLPProblem, x::Vector{Float64})
    D, ρ = x
    Ag = π * D^2 / 4

    obj = p.opts.objective

    if obj isa MinVolume
        # Gross area with constructability penalty for high reinforcement.
        # See RCColumnNLPProblem for rationale — prevents ρ from pegging at max.
        value = Ag * (1 + 2.0 * ρ)
    elseif obj isa MinWeight
        γ_concrete = ustrip(pcf, p.opts.material.ρ)
        γ_steel = ustrip(pcf, p.opts.rebar_material.ρ)
        value = Ag * ((1 - ρ) * γ_concrete + ρ * γ_steel)
    elseif obj isa MinCost
        isnan(p.opts.material.cost) && error("MinCost requires material.cost to be set (concrete has cost=NaN)")
        isnan(p.opts.rebar_material.cost) && error("MinCost requires material.cost to be set (rebar has cost=NaN)")
        ρ_c_kgft3 = ustrip(u"kg/ft^3", p.opts.material.ρ)
        ρ_s_kgft3 = ustrip(u"kg/ft^3", p.opts.rebar_material.ρ)
        cost_c_vol = p.opts.material.cost * ρ_c_kgft3
        cost_s_vol = p.opts.rebar_material.cost * ρ_s_kgft3
        value = Ag * ((1 - ρ) * cost_c_vol + ρ * cost_s_vol)
    elseif obj isa MinCarbon
        ρ_c_kgft3 = ustrip(u"kg/ft^3", p.opts.material.ρ)
        ρ_s_kgft3 = ustrip(u"kg/ft^3", p.opts.rebar_material.ρ)
        ecc_concrete = p.opts.material.ecc * ρ_c_kgft3
        ecc_steel = p.opts.rebar_material.ecc * ρ_s_kgft3
        value = Ag * ((1 - ρ) * ecc_concrete + ρ * ecc_steel)
    else
        # Default: gross area with ρ penalty (same as MinVolume)
        value = Ag * (1 + 2.0 * ρ)
    end

    return value
end

# ==============================================================================
# AbstractNLPProblem Interface: Constraints
# ==============================================================================

"""Single constraint: P-M interaction utilization."""
n_constraints(::RCCircularNLPProblem) = 1

"""Constraint name for solver diagnostics."""
constraint_names(::RCCircularNLPProblem) = ["P-M utilization"]

"""Constraint bounds: P-M utilization ≤ 1.0."""
function constraint_bounds(p::RCCircularNLPProblem)
    return ([-Inf], [1.0])
end

"""
    constraint_fns(p::RCCircularNLPProblem, x) -> Vector{Float64}

Evaluate smooth P-M utilization for circular column at design point `x`.
Includes optional ACI 318 slenderness magnification (moment magnifier δns).
"""
function constraint_fns(p::RCCircularNLPProblem, x::Vector{Float64})
    D, ρ = x

    # Effective cover to bar centroid (inches)
    db = ustrip(u"inch", rebar(p.opts.bar_size).diameter)
    cover = 1.5 + (p.opts.tie_type == :spiral ? 0.375 : 0.5) + db / 2.0

    # Number of bars for smooth P-M (match typical circular arrangement)
    n_bars = p.opts.tie_type == :spiral ? 12 : 8

    # Slenderness magnification (smooth analytical version)
    Mux_design = p.Mux_kipft
    if p.opts.include_slenderness
        R = D / 2.0
        Ig = π * R^4 / 4.0   # in⁴
        Ec_ksi = 57.0 * sqrt(p.mat.fc * 1000.0)
        EI = 0.4 * Ec_ksi * Ig / (1.0 + p.opts.βdns)

        Lu_in = ustrip(u"inch", p.geometry.Lu)
        # Circular sections are axisymmetric, so kx and ky give the same
        # geometry; use kx to mirror the convention in the rectangular NLP.
        k = Float64(p.geometry.kx)
        Pc = π^2 * EI / (k * Lu_in)^2

        M1x = to_kipft(p.demand.M1x)
        M2x = to_kipft(p.demand.M2x)
        Cm = abs(M2x) > 1e-6 ? max(0.6 - 0.4 * M1x / M2x, 0.4) : 1.0

        denom = max(1.0 - p.Pu_kip / (0.75 * Pc), 0.001)
        δns = max(Cm / denom, 1.0)

        if δns > 50.0
            return [100.0]
        end
        Mux_design = δns * p.Mux_kipft
    end

    # Smooth analytical P-M utilization (replaces piecewise-linear P-M diagram)
    util = _smooth_rc_pm_util(D, ρ, p.Pu_kip, Mux_design, p.mat;
                                    cover, n_bars, tie_type=p.opts.tie_type)
    return [util]
end

# ==============================================================================
# Helper: Build Trial Circular Section from Continuous Variables
# ==============================================================================

"""
    _build_nlp_trial_circular_section(D_in, ρg, opts) -> Union{RCCircularSection, Nothing}

Build an `RCCircularSection` from continuous design variables (D, ρg).
Returns `nothing` if the configuration is invalid.
"""
function _build_nlp_trial_circular_section(
    D_in::Real, ρg::Real,
    opts::NLPColumnOptions
)
    try
        Ag = π * D_in^2 / 4
        As_required = ρg * Ag

        bar = rebar(opts.bar_size)
        As_bar = ustrip(u"inch^2", bar.A)

        min_bars = opts.tie_type == :spiral ? 6 : 4
        n_bars_raw = As_required / As_bar
        n_bars = max(min_bars, ceil(Int, n_bars_raw))

        # Round to even for symmetric placement
        n_bars = iseven(n_bars) ? n_bars : n_bars + 1

        n_bars = min(n_bars, 32)

        return RCCircularSection(
            D = D_in * u"inch",
            bar_size = opts.bar_size,
            n_bars = n_bars,
            cover = opts.cover,
            tie_type = opts.tie_type
        )
    catch e
        return nothing
    end
end

# ==============================================================================
# Result Type
# ==============================================================================

"""
    RCCircularNLPResult

Result from circular RC column NLP optimization.

# Fields
- `section`: Optimized `RCCircularSection` (rounded to practical diameter)
- `D_opt`: Optimal diameter from solver (inches, continuous)
- `ρ_opt`: Optimal reinforcement ratio (continuous)
- `D_final`: Final diameter after rounding (inches)
- `area`: Final cross-sectional area (sq in)
- `status`: Solver termination status
- `iterations`: Number of solver iterations/evaluations
"""
struct RCCircularNLPResult
    section::RCCircularSection
    D_opt::Float64
    ρ_opt::Float64
    D_final::Float64
    area::Float64
    status::Symbol
    iterations::Int
end

"""
    build_rc_circular_nlp_result(problem, opt_result) -> RCCircularNLPResult

Convert optimization result to `RCCircularNLPResult` with practical section.
Dispatch target for `build_result`.
"""
function build_rc_circular_nlp_result(p::RCCircularNLPProblem, opt_result)
    D_opt, ρ_opt = opt_result.minimizer

    if p.opts.snap
        incr = ustrip(u"inch", p.opts.dim_increment)
        D_final = ceil(D_opt / incr) * incr
    else
        D_final = D_opt
    end

    section = _build_nlp_trial_circular_section(D_final, ρ_opt, p.opts)

    if isnothing(section) && p.opts.snap
        incr = ustrip(u"inch", p.opts.dim_increment)
        D_final += incr
        section = _build_nlp_trial_circular_section(D_final, ρ_opt, p.opts)
    end

    if isnothing(section)
        section = _build_nlp_trial_circular_section(D_opt, ρ_opt, p.opts)
        D_final = D_opt
    end

    area = π * D_final^2 / 4

    return RCCircularNLPResult(
        section,
        D_opt, ρ_opt,
        D_final, area,
        opt_result.status,
        opt_result.iterations
    )
end
