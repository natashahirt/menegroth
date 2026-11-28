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
    # Every load case. One entry for a single demand. Scalars below start the solver.
    cases::Vector{RCColumnDemand}
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
    return _assemble_rc_circular_nlp(
        RCColumnDemand[demand], demand, geometry, opts,
        Float64(to_kip(demand.Pu)), Float64(to_kipft(demand.Mux)))
end

function _assemble_rc_circular_nlp(cases::Vector{RCColumnDemand}, demand::RCColumnDemand,
                                  geometry::ConcreteMemberGeometry, opts::NLPColumnOptions,
                                  Pu_kip::Float64, Mux_kipft::Float64)
    mat = to_material_tuple(opts.material, fy_ksi(opts.rebar_material), Es_ksi(opts.rebar_material))
    D_min = ustrip(u"inch", opts.min_dim)
    D_max = ustrip(u"inch", opts.max_dim)
    return RCCircularNLPProblem(
        demand, cases, geometry, opts, mat,
        Pu_kip, Mux_kipft,
        D_min, D_max,
    )
end

function RCCircularNLPProblem(
    set::RCColumnDemandSet,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions,
)
    cases = _unique_rc_nlp_cases(set.cases)
    Pu = maximum(Float64(to_kip(d.Pu)) for d in cases)
    Mux = maximum(abs(Float64(to_kipft(d.Mux))) for d in cases)
    rep = cases[argmax([Float64(to_kip(d.Pu)) for d in cases])]
    return _assemble_rc_circular_nlp(cases, rep, geometry, opts, Pu, Mux)
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
        # Strip typed `ecc` once at the NLP boundary — JuMP needs bare Float64.
        ecc_concrete = ustrip(u"kgCO2e/kg", p.opts.material.ecc)      * ρ_c_kgft3
        ecc_steel    = ustrip(u"kgCO2e/kg", p.opts.rebar_material.ecc) * ρ_s_kgft3
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

"""One P-M row per load case."""
n_constraints(p::RCCircularNLPProblem) = length(p.cases)

"""Constraint name for solver diagnostics."""
function constraint_names(p::RCCircularNLPProblem)
    length(p.cases) == 1 && return ["P-M utilization"]
    return ["P-M utilization case $i" for i in eachindex(p.cases)]
end

"""Constraint bounds: P-M utilization ≤ 1.0."""
function constraint_bounds(p::RCCircularNLPProblem)
    n = n_constraints(p)
    return (fill(-Inf, n), fill(1.0, n))
end

"""
    constraint_fns(p::RCCircularNLPProblem, x) -> Vector{Float64}

Evaluate smooth P-M utilization for circular column at design point `x`.
Includes optional ACI 318 slenderness magnification (moment magnifier δns).
"""
function constraint_fns(p::RCCircularNLPProblem, x::Vector{Float64})
    db = ustrip(u"inch", rebar(p.opts.bar_size).diameter)
    shared = (
        cover = 1.5 + (p.opts.tie_type == :spiral ? 0.375 : 0.5) + db / 2.0,
        Ec_ksi = 57.0 * sqrt(p.mat.fc * 1000.0),
        Lu_in = ustrip(u"inch", p.geometry.Lu),
    )
    return [_rc_circular_nlp_util(p, x, d; shared) for d in p.cases]
end

"""Smooth P-M utilization of one circular-column load case."""
function _rc_circular_nlp_util(p::RCCircularNLPProblem, x::Vector{Float64}, demand::RCColumnDemand;
                              shared=nothing)
    D, ρ = x
    Pu_kip = Float64(to_kip(demand.Pu))
    Mux_kipft = Float64(to_kipft(demand.Mux))

    # Effective cover to bar centroid (inches)
    if shared === nothing
        db = ustrip(u"inch", rebar(p.opts.bar_size).diameter)
        shared = (
            cover = 1.5 + (p.opts.tie_type == :spiral ? 0.375 : 0.5) + db / 2.0,
            Ec_ksi = 57.0 * sqrt(p.mat.fc * 1000.0),
            Lu_in = ustrip(u"inch", p.geometry.Lu),
        )
    end
    cover = shared.cover

    # Number of bars for smooth P-M (match typical circular arrangement)
    n_bars = p.opts.tie_type == :spiral ? 12 : 8

    # Slenderness. Same simplified stiffness and §6.2.5.3 cap as the
    # rectangular NLP. A circular section has one radius; the larger of kx
    # and ky governs. The as-built checker applies the §6.2.5.1 neglect test.
    # `demand.magnify == false` skips §6.6 when the moments already include
    # second-order effects (ACI 318-19 §6.7).
    Mux_design = Mux_kipft
    stab = 0.0
    δ_ratio = 0.0
    if p.opts.include_slenderness && demand.magnify
        R = D / 2.0
        Ig = π * R^4 / 4.0   # in⁴
        Ec_ksi = shared.Ec_ksi
        # ACI 318-19 §6.6.4.4.4(a) (corpus: aci-318-19, printed page 79).
        EI = 0.4 * Ec_ksi * Ig / (1.0 + p.opts.βdns)

        Lu_in = shared.Lu_in
        k = max(Float64(p.geometry.kx), Float64(p.geometry.ky), 1e-6)
        Pc = π^2 * EI / (k * Lu_in)^2

        Cm = calc_Cm(to_kipft(demand.M1x), to_kipft(demand.M2x);
                     transverse_load=demand.transverse_load)

        # ACI 318-19 §6.6.4.5.2. See `_rc_nlp_delta_ns` for the smooth pole.
        stab = Pu_kip / (0.75 * max(Pc, 1e-6))
        δns = _rc_nlp_delta_ns(Cm, stab)
        δ_ratio = δns / SECOND_ORDER_MOMENT_RATIO_LIMIT
        Mux_design = δns * Mux_kipft
    end

    # Smooth analytical P-M utilization (replaces piecewise-linear P-M diagram)
    util = _smooth_rc_pm_util(D, ρ, Pu_kip, Mux_design, p.mat;
                                    cover, n_bars, tie_type=p.opts.tie_type)
    # ACI 318-19 §6.2.5.3: δns ≤ 1.4. Eq. (6.6.4.5.2) is undefined for
    # Pu ≥ 0.75 Pc; that ratio stays in the same row.
    if δ_ratio >= 1.0
        util = _smooth_max(util, δ_ratio; k=80.0)
    end
    if stab >= 1.0
        util = _smooth_max(util, stab; k=80.0)
    end
    return util
end

# ==============================================================================
# Helper: Build Trial Circular Section from Continuous Variables
# ==============================================================================

"""Bar centers fall inside the section. Matches the spiral-diameter assumption in `RCCircularSection`."""
function _circular_bars_fit(D_in::Real, opts::NLPColumnOptions)
    cover = ustrip(u"inch", opts.cover)
    db = ustrip(u"inch", rebar(opts.bar_size).diameter)
    R_bar = D_in / 2 - cover - 0.5 - db / 2
    return R_bar > 0
end

"""
    _circular_trial_bar_count(D_in, ρg, opts) -> Int

Even bar count for `ρg` at diameter `D_in` (inches): `ceil(ρg·Ag / A_bar)`,
at least the tie-type minimum, then capped at `RC_COLUMN_NLP_MAX_BARS`.
"""
function _circular_trial_bar_count(D_in::Real, ρg::Real, opts::NLPColumnOptions)
    Ag = π * D_in^2 / 4
    As_bar = ustrip(u"inch^2", rebar(opts.bar_size).A)
    n_bars = max(_nlp_min_bars(opts), ceil(Int, ρg * Ag / As_bar))
    n_bars = iseven(n_bars) ? n_bars : n_bars + 1
    return min(n_bars, RC_COLUMN_NLP_MAX_BARS)
end

"""
    _build_nlp_circular_section(D_in, n_bars, opts) -> Union{RCCircularSection, Nothing}

`nothing` when the bars do not fit or the constructor rejects the layout.
"""
function _build_nlp_circular_section(D_in::Real, n_bars::Int, opts::NLPColumnOptions)
    n_bars <= RC_COLUMN_NLP_MAX_BARS || return nothing
    n_bars >= _nlp_min_bars(opts) || return nothing
    _circular_bars_fit(D_in, opts) || return nothing
    try
        return RCCircularSection(
            D = D_in * u"inch",
            bar_size = opts.bar_size,
            n_bars = n_bars,
            cover = opts.cover,
            tie_type = opts.tie_type,
        )
    catch
        return nothing
    end
end

function _build_nlp_trial_circular_section(
    D_in::Real, ρg::Real,
    opts::NLPColumnOptions
)
    return _build_nlp_circular_section(D_in, _circular_trial_bar_count(D_in, ρg, opts), opts)
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
