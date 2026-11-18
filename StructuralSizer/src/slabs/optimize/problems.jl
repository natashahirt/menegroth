# ==============================================================================
# Floor Optimization Problem Definitions
# ==============================================================================
# Concrete implementations of AbstractNLPProblem for floor systems.

# ==============================================================================
# Vault Optimization Problem
# ==============================================================================

"""
    VaultNLPProblem <: AbstractNLPProblem

Continuous optimization problem for unreinforced parabolic vaults.

Supports three optimization modes:
- `:both` - Optimize both rise and thickness [h, t]
- `:rise_only` - Optimize rise only, thickness fixed [h]
- `:thickness_only` - Optimize thickness only, rise fixed [t]

Objective: Minimize volume (or weight/carbon via AbstractObjective)

Constraints:
- Stress: σ_max ≤ σ_allow
- Deflection: elastic shortening converges and δ ≤ δ_limit

# Fields
- `span_m`: Clear span in meters
- `trib_m`: Tributary depth in meters  
- `sdl_kN`: Superimposed dead load in kN/m²
- `live_kN`: Live load in kN/m²
- `finish_kN`: Finishing load in kN/m²
- `material`: Concrete material (for ρ, E, fc')
- `σ_allow`: Allowable stress in MPa
- `δ_limit`: Maximum allowable rise reduction in meters
- `h_bounds`: (h_min, h_max) rise bounds in meters
- `t_bounds`: (t_min, t_max) thickness bounds in meters
- `rib_depth_m`: Rib depth (0 for no ribs)
- `rib_apex_m`: Rib apex rise above extrados (0 for no ribs)
- `mode`: Optimization mode (:both, :rise_only, :thickness_only)
"""
struct VaultNLPProblem <: AbstractNLPProblem
    span_m::Float64
    trib_m::Float64
    sdl_kN::Float64
    live_kN::Float64
    finish_kN::Float64
    material::Concrete
    σ_allow::Float64
    δ_limit::Float64
    h_bounds::Tuple{Float64, Float64}
    t_bounds::Tuple{Float64, Float64}
    rib_depth_m::Float64
    rib_apex_m::Float64
    mode::Symbol  # :both, :rise_only, :thickness_only
end

# Convenience constructor with Unitful inputs
# This is the recommended API - always pass unitful quantities
"""
    VaultNLPProblem(span, trib_depth, sdl, live; kwargs...)

Create a vault optimization problem with Unitful inputs.

# Arguments (all Unitful)
- `span::Length`: Clear span (e.g., `6.0u"m"`)
- `trib_depth::Length`: Tributary depth / rib spacing
- `sdl::Pressure`: Superimposed dead load (e.g., `1.0u"kN/m^2"`)
- `live::Pressure`: Live load

# Keyword Arguments
- `material::Concrete`: Concrete material (default: NWC_4000)
- `finishing_load::Pressure`: Finishing load (default: 0)
- `allowable_stress::Real`: Allowable stress in MPa (default: 0.45 fc')
- `deflection_limit::Length`: Max rise reduction (default: span/240)
- `rise_bounds::Tuple{Length, Length}`: (h_min, h_max) rise bounds
- `thickness_bounds::Tuple{Length, Length}`: (t_min, t_max) thickness bounds
- `rib_depth::Length`: Rib depth (default: 0)
- `rib_apex_rise::Length`: Rib apex rise (default: 0)
- `mode::Symbol`: Optimization mode (:both, :rise_only, :thickness_only)
"""
function VaultNLPProblem(
    span::Length,
    trib_depth::Length,
    sdl::Pressure,
    live::Pressure;
    material::Concrete = NWC_4000,
    finishing_load::Pressure = 0.0u"kN/m^2",
    allowable_stress::Union{Real, Nothing} = nothing,
    deflection_limit::Union{Length, Nothing} = nothing,
    rise_bounds::Tuple{<:Length, <:Length},
    thickness_bounds::Tuple{<:Length, <:Length},
    rib_depth::Length = 0.0u"m",
    rib_apex_rise::Length = 0.0u"m",
    mode::Symbol = :both,
)
    span_m = ustrip(u"m", span)
    trib_m = ustrip(u"m", trib_depth)
    sdl_kN = ustrip(u"kN/m^2", sdl)
    live_kN = ustrip(u"kN/m^2", live)
    finish_kN = ustrip(u"kN/m^2", finishing_load)
    
    σ_allow = ustrip(u"MPa", vault_allowable_stress(material, allowable_stress))
    δ_lim = ustrip(u"m", vault_rise_loss_limit(span, deflection_limit))
    
    h_min = ustrip(u"m", rise_bounds[1])
    h_max = ustrip(u"m", rise_bounds[2])
    t_min = ustrip(u"m", thickness_bounds[1])
    t_max = ustrip(u"m", thickness_bounds[2])
    
    rib_d = ustrip(u"m", rib_depth)
    rib_h = ustrip(u"m", rib_apex_rise)
    
    VaultNLPProblem(
        span_m, trib_m, sdl_kN, live_kN, finish_kN,
        material, σ_allow, δ_lim,
        (h_min, h_max), (t_min, t_max),
        rib_d, rib_h,
        mode
    )
end

# ==============================================================================
# NLP Interface Implementation (Core)
# ==============================================================================

"""Number of decision variables depends on mode."""
n_variables(p::VaultNLPProblem) = p.mode == :both ? 2 : 1

"""Return `(lb, ub)` variable bound vectors depending on optimization mode."""
function variable_bounds(p::VaultNLPProblem)
    if p.mode == :both
        lb = [p.h_bounds[1], p.t_bounds[1]]
        ub = [p.h_bounds[2], p.t_bounds[2]]
    elseif p.mode == :rise_only
        lb = [p.h_bounds[1]]
        ub = [p.h_bounds[2]]
    else  # :thickness_only
        lb = [p.t_bounds[1]]
        ub = [p.t_bounds[2]]
    end
    return (lb, ub)
end

"""Return midpoint initial guess for the vault optimization variables."""
function initial_guess(p::VaultNLPProblem)
    h0 = (p.h_bounds[1] + p.h_bounds[2]) / 2
    t0 = (p.t_bounds[1] + p.t_bounds[2]) / 2
    if p.mode == :both
        return [h0, t0]
    elseif p.mode == :rise_only
        return [h0]
    else  # :thickness_only
        return [t0]
    end
end

"""Return variable name strings for the vault optimization (mode-dependent)."""
function variable_names(p::VaultNLPProblem)
    if p.mode == :both
        ["rise_m", "thickness_m"]
    elseif p.mode == :rise_only
        ["rise_m"]
    else  # :thickness_only
        ["thickness_m"]
    end
end
"""Return constraint name strings for the vault optimization problem."""
constraint_names(::VaultNLPProblem) = ["stress", "convergence", "kern"]

"""
    _get_h_t(p::VaultNLPProblem, x) -> (h, t)

Extract (rise, thickness) from optimization variable vector based on mode.
For 1D modes, the fixed variable comes from the degenerate bounds.
"""
function _get_h_t(p::VaultNLPProblem, x::Vector{Float64})
    if p.mode == :both
        return x[1], x[2]
    elseif p.mode == :rise_only
        return x[1], p.t_bounds[1]  # thickness is fixed (bounds are degenerate)
    else  # :thickness_only
        return p.h_bounds[1], x[1]  # rise is fixed (bounds are degenerate)
    end
end

# ==============================================================================
# Gradient-Based Interface (for NonConvex.jl, Ipopt)
# ==============================================================================

"""Number of constraints: stress, convergence/deflection, and thrust-line kern."""
n_constraints(::VaultNLPProblem) = 3

"""
Constraint bounds for vault:
- g1 = σ_max - σ_allow ≤ 0 (stress)
- g2 = δ - δ_limit ≤ 0 (deflection)
- g3 = e / (t cos θ / 6) - 1 ≤ 0 (half-span thrust line in the middle third)
"""
function constraint_bounds(::VaultNLPProblem)
    lb = [-Inf, -Inf, -Inf]
    ub = [0.0, 0.0, 0.0]
    return (lb, ub)
end

"""
Concrete volume of one vault bay (shell and ribs), m³, from
[`get_vault_properties`](@ref): the extrados is the intrados raised by `t`,
so the shell is `t · span · trib`. The analytical path uses the same volume.
"""
_vault_volume(p::VaultNLPProblem, h, t) =
    get_vault_properties(p.span_m, h, t, p.trib_m, p.rib_depth_m, p.rib_apex_m).total_vol

"""
    _vault_cases(p, h, t) -> NamedTuple

[`vault_load_cases`](@ref) at rise `h` and thickness `t`, in metres.
"""
function _vault_cases(p::VaultNLPProblem, h, t)
    return vault_load_cases(p.span_m * u"m", h * u"m", p.trib_m * u"m", t * u"m",
                            p.rib_depth_m * u"m", p.rib_apex_m * u"m", p.material.ρ,
                            p.sdl_kN * u"kN/m^2", p.live_kN * u"kN/m^2",
                            p.finish_kN * u"kN/m^2")
end

"""
Elastic shortening at rise `h` and thickness `t` under the full service load
and the self-weight from `cases`.
"""
function _vault_shortening(p::VaultNLPProblem, h, t, cases)
    total = (p.sdl_kN + p.live_kN + p.finish_kN) * u"kN/m^2" + cases.self_weight
    return solve_equilibrium_rise(p.span_m * u"m", h * u"m", total, t * u"m",
                                  p.trib_m * u"m", p.material.E;
                                  deflection_limit = p.δ_limit * u"m")
end

"""
Objective function: concrete volume of one bay ([`_vault_volume`](@ref)).

Note: Uses initial rise (not equilibrium rise) to keep the function smooth
for gradient-based optimization.
"""
function objective_fn(p::VaultNLPProblem, x::Vector{Float64})
    h, t = _get_h_t(p, x)
    return _vault_volume(p, h, t)
end

"""
Constraint functions for vault optimization.

Returns [g1, g2, g3] where:
- g1 = σ_max - σ_allow (stress constraint, ≤ 0 for feasible)
- g2 = δ - δ_limit (deflection constraint, ≤ 0 for feasible)
- g3 = kern ratio - 1 (≤ 0 for feasible)

For non-convergent cases, g2 returns a large positive value.
"""
function constraint_fns(p::VaultNLPProblem, x::Vector{Float64})
    h, t = _get_h_t(p, x)
    cases = _vault_cases(p, h, t)
    eq = _vault_shortening(p, h, t, cases)

    # Constraint values
    g1 = ustrip(u"MPa", cases.σ_max) - p.σ_allow  # Stress constraint: g1 ≤ 0
    
    # Deflection constraint: g2 ≤ 0
    if eq.converged
        δ = abs(h - ustrip(u"m", eq.final_rise))
        g2 = δ - p.δ_limit
    else
        g2 = 1.0  # Large positive = infeasible (non-convergent)
    end
    g3 = cases.kern.ratio - 1.0

    return [g1, g2, g3]
end

# ==============================================================================
# Legacy Evaluate Interface (for grid search + result building)
# ==============================================================================

"""
    evaluate(problem::VaultNLPProblem, x::Vector) -> (feasible, objective, result)

Combined evaluation for grid-based solvers.
Returns rich result data for `build_result()`.
"""
function evaluate(p::VaultNLPProblem, x::Vector{Float64})
    h, t = _get_h_t(p, x)
    cases = _vault_cases(p, h, t)
    eq = _vault_shortening(p, h, t, cases)
    σ_max = ustrip(u"MPa", cases.σ_max)

    converged = eq.converged
    final_rise_m = converged ? ustrip(u"m", eq.final_rise) : h
    deflection_ok = converged && eq.deflection_ok
    stress_ok = σ_max <= p.σ_allow
    feasible = stress_ok && cases.kern.ok && deflection_ok

    # Objective at the equilibrium rise, the geometry that is built.
    props = get_vault_properties(p.span_m, final_rise_m, t, p.trib_m, p.rib_depth_m, p.rib_apex_m)

    result = (
        h = h,
        t = t,
        σ_max = σ_max,
        σ_allow = p.σ_allow,
        stress_ratio = σ_max / p.σ_allow,
        stress_ok = stress_ok,
        converged = converged,
        final_rise = final_rise_m,
        deflection_ok = deflection_ok,
        feasible = feasible,
        volume = props.total_vol,
        arc_length = props.arc_length,
        governing = cases.governing,
        kern = cases.kern,
        thrust_dead = cases.thrust_dead,
        thrust_live = cases.thrust_live,
        self_weight = cases.self_weight,
    )

    return (feasible, props.total_vol, result)
end

# ==============================================================================
# Result Builder (converts lightweight eval → VaultResult)
# ==============================================================================

"""
    build_result(problem::VaultNLPProblem, x::Vector, eval_result, units) -> VaultResult

Convert the lightweight evaluation NamedTuple to a full VaultResult with units.

This is called ONCE at the end of optimization, avoiding redundant analysis.

# Arguments
- `problem`: The optimization problem
- `x`: Optimal point [h, t] in meters
- `eval_result`: NamedTuple from `evaluate()`
- `units`: NamedTuple with `(length, pressure)` units from original inputs
"""
function build_result(
    p::VaultNLPProblem,
    x::Vector{Float64},
    eval_result::NamedTuple,
    units::NamedTuple{(:length, :pressure)}
)
    h, t = x
    
    # Normalize to coherent SI (m, kPa)
    thickness = t * u"m"
    rise = eval_result.final_rise * u"m"
    arc_length = eval_result.arc_length * u"m"
    trib_u = p.trib_m * u"m"

    # Thrust per unit length of support (kN/m), from the evaluated load cases.
    thrust_dead = uconvert(u"kN/m", eval_result.thrust_dead / trib_u)
    thrust_live = uconvert(u"kN/m", eval_result.thrust_live / trib_u)

    # Volume per plan area of the bay (m³/m² = m), as the analytical path.
    volume_per_area = eval_result.volume / (p.span_m * p.trib_m) * u"m"
    self_weight = uconvert(u"kPa", eval_result.self_weight)
    
    # Build check tuples
    stress_check = (
        σ = eval_result.σ_max,
        σ_allow = eval_result.σ_allow,
        ratio = eval_result.stress_ratio,
        ok = eval_result.stress_ok,
    )
    
    deflection_m = h - eval_result.final_rise
    deflection_check = (
        δ = deflection_m,
        limit = p.δ_limit,
        ratio = deflection_m / p.δ_limit,
        ok = eval_result.deflection_ok,
    )
    
    convergence_check = (converged = eval_result.converged, iterations = 0)

    VaultResult(
        thickness, rise, arc_length,
        thrust_dead, thrust_live,
        volume_per_area, self_weight,
        eval_result.σ_max, eval_result.governing,
        stress_check, deflection_check, convergence_check, eval_result.kern
    )
end

# ==============================================================================
# Objective Value Computation (extends optimize/core/objectives.jl)
# ==============================================================================
# Kept for compatibility; the solver uses _convert_objective
# for efficiency during grid search.

"""Volume-based objective for vault: concrete volume of one bay ([`_vault_volume`](@ref))."""
function objective_value(::MinVolume, p::VaultNLPProblem, x::Vector{Float64})
    h, t = x
    return _vault_volume(p, h, t)
end

"""Weight-based objective for vault: volume × density."""
function objective_value(::MinWeight, p::VaultNLPProblem, x::Vector{Float64})
    vol = objective_value(MinVolume(), p, x)
    density = ustrip(u"kg/m^3", p.material.ρ)
    return vol * density
end

"""Carbon-based objective for vault: weight × embodied carbon factor. Returns
a bare Float64 in kgCO₂e for the NLP solver (typed `ecc` is stripped once at
this boundary)."""
function objective_value(::MinCarbon, p::VaultNLPProblem, x::Vector{Float64})
    weight = objective_value(MinWeight(), p, x)               # Float64, kg
    ecc = ustrip(u"kgCO2e/kg", p.material.ecc)                # Float64
    return weight * ecc                                       # Float64, kgCO₂e
end

"""Cost-based objective for vault: volume × density × unit cost."""
function objective_value(::MinCost, p::VaultNLPProblem, x::Vector{Float64})
    isnan(p.material.cost) && error("MinCost requires material.cost to be set (material has cost=NaN)")
    vol = objective_value(MinVolume(), p, x)
    density = ustrip(u"kg/m^3", p.material.ρ)
    return vol * density * p.material.cost  # m³ × kg/m³ × $/kg = $
end
