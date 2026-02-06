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
- `check_asymmetric`: Whether to check asymmetric load case
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
    check_asymmetric::Bool
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
- `check_asymmetric::Bool`: Check half-span loading (default: true)
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
    check_asymmetric::Bool = true,
    rib_depth::Length = 0.0u"m",
    rib_apex_rise::Length = 0.0u"m",
    mode::Symbol = :both,
)
    span_m = ustrip(u"m", span)
    trib_m = ustrip(u"m", trib_depth)
    sdl_kN = ustrip(u"kN/m^2", sdl)
    live_kN = ustrip(u"kN/m^2", live)
    finish_kN = ustrip(u"kN/m^2", finishing_load)
    
    # Default allowable stress: 0.45 fc'
    σ_allow = isnothing(allowable_stress) ? 
        0.45 * ustrip(u"MPa", material.fc′) : Float64(allowable_stress)
    
    # Default deflection limit: span/240
    δ_lim = isnothing(deflection_limit) ? 
        span_m / 240 : ustrip(u"m", deflection_limit)
    
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
        check_asymmetric, rib_d, rib_h,
        mode
    )
end

# ==============================================================================
# NLP Interface Implementation (Core)
# ==============================================================================

"""Number of decision variables depends on mode."""
n_variables(p::VaultNLPProblem) = p.mode == :both ? 2 : 1

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

function variable_names(p::VaultNLPProblem)
    if p.mode == :both
        ["rise_m", "thickness_m"]
    elseif p.mode == :rise_only
        ["rise_m"]
    else  # :thickness_only
        ["thickness_m"]
    end
end
constraint_names(::VaultNLPProblem) = ["stress", "convergence"]

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

"""Number of constraints: stress and convergence/deflection."""
n_constraints(::VaultNLPProblem) = 2

"""
Constraint bounds for vault:
- g1 = σ_max - σ_allow ≤ 0 (stress)
- g2 = δ - δ_limit ≤ 0 (deflection)
"""
function constraint_bounds(::VaultNLPProblem)
    lb = [-Inf, -Inf]
    ub = [0.0, 0.0]
    return (lb, ub)
end

"""
Objective function: shell volume = arc_length × thickness × trib_depth.

Note: Uses initial rise for arc length (not equilibrium rise) to keep
the function smooth for gradient-based optimization.
"""
function objective_fn(p::VaultNLPProblem, x::Vector{Float64})
    h, t = _get_h_t(p, x)
    arc_len = parabolic_arc_length(p.span_m, h)
    return arc_len * t * p.trib_m
end

"""
Constraint functions for vault optimization.

Returns [g1, g2] where:
- g1 = σ_max - σ_allow (stress constraint, ≤ 0 for feasible)
- g2 = δ - δ_limit (deflection constraint, ≤ 0 for feasible)

For non-convergent cases, g2 returns a large positive value.
"""
function constraint_fns(p::VaultNLPProblem, x::Vector{Float64})
    h, t = _get_h_t(p, x)
    
    # Convert back to Unitful for vault analysis functions
    span_u = p.span_m * u"m"
    rise_u = h * u"m"
    trib_u = p.trib_m * u"m"
    thick_u = t * u"m"
    rib_d_u = p.rib_depth_m * u"m"
    rib_h_u = p.rib_apex_m * u"m"
    density_u = p.material.ρ
    load_u = (p.sdl_kN + p.live_kN) * u"kN/m^2"
    finish_u = p.finish_kN * u"kN/m^2"
    
    # Compute stress (symmetric case)
    sym = vault_stress_symmetric(
        span_u, rise_u, trib_u, thick_u, rib_d_u, rib_h_u,
        density_u, load_u, finish_u
    )
    σ_max_MPa = ustrip(u"MPa", sym.σ)
    sw_kN_m2 = ustrip(u"kN/m^2", sym.self_weight)
    
    # Asymmetric case (if enabled)
    if p.check_asymmetric
        asym = vault_stress_asymmetric(
            span_u, rise_u, trib_u, thick_u, rib_d_u, rib_h_u,
            density_u, load_u, finish_u
        )
        σ_max_MPa = max(σ_max_MPa, ustrip(u"MPa", asym.σ))
    end
    
    # Compute elastic shortening (Unitful version)
    total_load_u = load_u + sym.self_weight + finish_u
    E_u = p.material.E
    eq = solve_equilibrium_rise(
        span_u, rise_u, total_load_u, thick_u, trib_u, E_u;
        deflection_limit = p.δ_limit * u"m"
    )
    
    # Constraint values
    g1 = σ_max_MPa - p.σ_allow  # Stress constraint: g1 ≤ 0
    
    # Deflection constraint: g2 ≤ 0
    if eq.converged
        δ = abs(h - ustrip(u"m", eq.final_rise))
        g2 = δ - p.δ_limit
    else
        g2 = 1.0  # Large positive = infeasible (non-convergent)
    end
    
    return [g1, g2]
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
    
    # Convert back to Unitful for vault analysis functions
    span_u = p.span_m * u"m"
    rise_u = h * u"m"
    trib_u = p.trib_m * u"m"
    thick_u = t * u"m"
    rib_d_u = p.rib_depth_m * u"m"
    rib_h_u = p.rib_apex_m * u"m"
    density_u = p.material.ρ
    load_u = (p.sdl_kN + p.live_kN) * u"kN/m^2"
    finish_u = p.finish_kN * u"kN/m^2"
    
    # Compute stress (symmetric case)
    sym = vault_stress_symmetric(
        span_u, rise_u, trib_u, thick_u, rib_d_u, rib_h_u,
        density_u, load_u, finish_u
    )
    σ_max = ustrip(u"MPa", sym.σ)
    sw_kN_m2 = ustrip(u"kN/m^2", sym.self_weight)
    
    # Asymmetric case (if enabled)
    if p.check_asymmetric
        asym = vault_stress_asymmetric(
            span_u, rise_u, trib_u, thick_u, rib_d_u, rib_h_u,
            density_u, load_u, finish_u
        )
        σ_max = max(σ_max, ustrip(u"MPa", asym.σ))
    end
    
    # Compute elastic shortening (Unitful version)
    total_load_u = load_u + sym.self_weight + finish_u
    E_u = p.material.E
    eq = solve_equilibrium_rise(
        span_u, rise_u, total_load_u, thick_u, trib_u, E_u;
        deflection_limit = p.δ_limit * u"m"
    )
    
    # Extract results
    converged = eq.converged
    final_rise_m = converged ? ustrip(u"m", eq.final_rise) : h
    deflection_ok = converged && eq.deflection_ok
    
    # Evaluate feasibility
    stress_ok = σ_max <= p.σ_allow
    feasible = stress_ok && deflection_ok
    
    # Compute objective (volume)
    arc_len = parabolic_arc_length(p.span_m, final_rise_m)
    volume = arc_len * t * p.trib_m
    
    # Rich result for build_result()
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
        volume = volume,
        arc_length = arc_len,
    )
    
    return (feasible, volume, result)
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
    L_unit = units.length
    F_unit = units.pressure
    
    # Convert to user's units
    thickness = uconvert(L_unit, t * u"m")
    rise = uconvert(L_unit, eval_result.final_rise * u"m")
    arc_length = uconvert(L_unit, eval_result.arc_length * u"m")
    
    # Convert to Unitful for vault analysis functions
    span_u = p.span_m * u"m"
    rise_u = h * u"m"
    trib_u = p.trib_m * u"m"
    thick_u = t * u"m"
    rib_d_u = p.rib_depth_m * u"m"
    rib_h_u = p.rib_apex_m * u"m"
    density_u = p.material.ρ
    sdl_u = p.sdl_kN * u"kN/m^2"
    live_u = p.live_kN * u"kN/m^2"
    finish_u = p.finish_kN * u"kN/m^2"
    
    # Compute thrust from symmetric analysis
    sym = vault_stress_symmetric(
        span_u, rise_u, trib_u, thick_u, rib_d_u, rib_h_u,
        density_u, sdl_u, finish_u  # Dead only
    )
    sym_live = vault_stress_symmetric(
        span_u, rise_u, trib_u, thick_u, rib_d_u, rib_h_u,
        density_u, live_u, 0.0u"kN/m^2"  # Live only
    )
    
    # Line load units (force per length) - thrust is a force, convert to force/length
    # thrust is total horizontal force, divide by trib_depth to get kN/m
    thrust_dead = sym.thrust / trib_u  # Force / Length = Force/Length
    thrust_live = sym_live.thrust / trib_u
    
    # Volume and self-weight
    volume_per_area = uconvert(L_unit, eval_result.arc_length * t * u"m")
    self_weight = uconvert(F_unit, sym.self_weight)
    
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
    
    # Determine governing case
    governing_case = :symmetric  # We'd need to track this in eval_result for accuracy
    if p.check_asymmetric
        load_total_u = (p.sdl_kN + p.live_kN) * u"kN/m^2"
        asym = vault_stress_asymmetric(
            span_u, rise_u, trib_u, thick_u, rib_d_u, rib_h_u,
            density_u, load_total_u, finish_u
        )
        if ustrip(u"MPa", asym.σ) > eval_result.σ_max * 0.99  # Allow small tolerance
            governing_case = :asymmetric
        end
    end
    
    VaultResult(
        thickness, rise, arc_length,
        thrust_dead, thrust_live,
        volume_per_area, self_weight,
        eval_result.σ_max, governing_case,
        stress_check, deflection_check, convergence_check
    )
end

# ==============================================================================
# Objective Value Computation (extends optimize/core/objectives.jl)
# ==============================================================================
# Note: These are kept for compatibility but the solver now uses _convert_objective
# for efficiency during grid search.

"""Volume-based objective for vault: arc_length × thickness × trib_depth."""
function objective_value(::MinVolume, p::VaultNLPProblem, x::Vector{Float64})
    h, t = x
    arc_len = parabolic_arc_length(p.span_m, h)
    return arc_len * t * p.trib_m
end

"""Weight-based objective for vault: volume × density."""
function objective_value(::MinWeight, p::VaultNLPProblem, x::Vector{Float64})
    vol = objective_value(MinVolume(), p, x)
    density = ustrip(u"kg/m^3", p.material.ρ)
    return vol * density
end

"""Carbon-based objective for vault: weight × embodied carbon factor."""
function objective_value(::MinCarbon, p::VaultNLPProblem, x::Vector{Float64})
    weight = objective_value(MinWeight(), p, x)
    ecc = p.material.ecc
    return weight * ecc
end

"""Cost-based objective for vault: volume × material cost per m³."""
function objective_value(::MinCost, p::VaultNLPProblem, x::Vector{Float64})
    vol = objective_value(MinVolume(), p, x)
    # Use material cost if available, otherwise estimate from typical concrete
    cost_per_m3 = hasproperty(p.material, :cost) ? p.material.cost : 150.0  # $/m³ default
    return vol * cost_per_m3
end
