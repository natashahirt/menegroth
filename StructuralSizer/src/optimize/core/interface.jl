# ==============================================================================
# Capacity Checker Interface
# ==============================================================================
# Abstract interface for material/code-specific capacity checking.
# Enables material-agnostic optimization by decoupling the MIP solver
# from design code specifics.

"""
    AbstractCapacityChecker

Base type for design code capacity checkers. Each design code (AISC, NDS, ACI, etc.)
implements a concrete subtype that knows how to check if a section satisfies
all code requirements for a given demand.

# Required Interface
- `create_cache(checker, n_sections) -> cache` - create checker-specific capacity cache
- `precompute_capacities!(checker, cache, catalogue, material, objective)` - fill cache
- `is_feasible(checker, cache, j, section, material, demand, geometry) -> Bool`
- `get_objective_coeff(checker, cache, j) -> Float64`

# Optional Interface
- `get_feasibility_error_msg(checker, demand, geometry) -> String`
"""
abstract type AbstractCapacityChecker end

"""
    AbstractCapacityCache

Base type for checker-specific capacity caches. Each checker defines its own
cache structure optimized for its capacity calculations.
"""
abstract type AbstractCapacityCache end

"""
    AbstractMemberGeometry

Base type for member geometry parameters (lengths, bracing, effective length factors).
Different materials have different geometric considerations:
- Steel: Lb, Cb, Kx, Ky (lateral-torsional buckling, column buckling)
- Timber: Lu, support conditions (lateral stability)
- Concrete: Le (effective length for slenderness)

Note: AbstractMemberGeometry is defined in StructuralSizer/src/types.jl
"""

# ==============================================================================
# Generic Interface Functions
# ==============================================================================

"""
    create_cache(checker, n_sections) -> AbstractCapacityCache

Create a checker-specific capacity cache for `n_sections` sections.
Each checker type returns its own cache type optimized for its calculations.
"""
function create_cache end

"""
    precompute_capacities!(checker, cache, catalogue, material, objective)

Precompute and cache capacity values that are reused across multiple 
feasibility checks. Called once before the optimization loop.
"""
function precompute_capacities! end

"""
    is_feasible(checker, cache, j, section, material, demand, geometry) -> Bool

Check if `section` (at index `j` in catalogue) with `material` satisfies all 
design code requirements for the given `demand` and `geometry`. 
Returns `true` if all checks pass.

Uses `cache` for precomputed values.
"""
function is_feasible end

"""
    get_objective_coeff(checker, cache, j) -> Float64

Get the precomputed objective function coefficient for section at index `j`.
"""
function get_objective_coeff end

"""
    get_feasibility_error_msg(checker, demand, geometry) -> String

Generate a descriptive error message when no feasible sections exist for a group.
Useful for debugging undersized catalogs or extreme demands.
"""
function get_feasibility_error_msg end

# Default implementation
function get_feasibility_error_msg(::AbstractCapacityChecker, demand, geometry)
    "No feasible section found for demand=$demand"
end

# ==============================================================================
# NLP Problem Interface (for Continuous Optimization)
# ==============================================================================
# Abstract interface for continuous optimization problems (floors, custom members).
# Enables solver-agnostic optimization by decoupling the NLP solver from
# domain-specific problem definitions.
#
# Two usage modes:
# 1. Simple (grid search): implement `evaluate()` which returns feasibility + objective
# 2. Gradient-based (NonConvex/Ipopt): implement `objective_fn()` + `constraint_fns()`
#
# The gradient-based interface is preferred for new implementations as it:
# - Supports automatic differentiation
# - Provides constraint violation info for debugging
# - Works with all solver backends

"""
    AbstractNLPProblem

Base type for continuous optimization problems. Each domain (vaults, CLT, etc.)
implements a concrete subtype that defines the optimization problem.

# Core Interface (required for all solvers)
- `n_variables(problem) -> Int` - number of decision variables
- `variable_bounds(problem) -> (lb::Vector, ub::Vector)` - box constraints
- `initial_guess(problem) -> Vector` - starting point for solver

# Gradient-Based Interface (for NonConvex.jl, Ipopt, etc.)
- `objective_fn(problem, x) -> Float64` - objective function value
- `constraint_fns(problem, x) -> Vector{Float64}` - constraint values g(x)
- `constraint_bounds(problem) -> (lb::Vector, ub::Vector)` - bounds on g(x)
- `n_constraints(problem) -> Int` - number of constraints

# Legacy Interface (for grid search)
- `evaluate(problem, x) -> (feasible, objective, result)` - combined evaluation

# Optional Interface
- `variable_names(problem) -> Vector{String}` - human-readable variable names
- `constraint_names(problem) -> Vector{String}` - human-readable constraint names
"""
abstract type AbstractNLPProblem end

# ==============================================================================
# Core Interface (required)
# ==============================================================================

"""Number of decision variables."""
function n_variables end

"""Box constraints (lower, upper) for all variables."""
function variable_bounds end

"""Starting point for optimization."""
function initial_guess end

# ==============================================================================
# Gradient-Based Interface (for NonConvex.jl, Ipopt)
# ==============================================================================

"""
    objective_fn(problem, x::Vector{Float64}) -> Float64

Evaluate the objective function at point x.
This should be a smooth function suitable for gradient-based optimization.
"""
function objective_fn end

"""
    constraint_fns(problem, x::Vector{Float64}) -> Vector{Float64}

Evaluate all constraint functions at point x.
Returns a vector g(x) where feasibility requires: lb ≤ g(x) ≤ ub.

Constraint convention:
- g(x) ≤ 0 for inequality constraints (set lb=-Inf, ub=0)
- g(x) = 0 for equality constraints (set lb=ub=0)
"""
function constraint_fns end

"""
    constraint_bounds(problem) -> (lb::Vector{Float64}, ub::Vector{Float64})

Return bounds on constraint functions.
Feasible when: lb[i] ≤ constraint_fns(problem, x)[i] ≤ ub[i]
"""
function constraint_bounds end

"""Number of constraints."""
function n_constraints end

# ==============================================================================
# Legacy Interface (combined evaluation for grid search)
# ==============================================================================

"""
    evaluate(problem, x::Vector) -> (feasible, objective_value, domain_result)

Combined evaluation for grid-based solvers.

Returns:
- `feasible::Bool` - whether x satisfies all constraints
- `objective_value::Float64` - value to minimize (should be Inf if infeasible)
- `domain_result` - domain-specific result (e.g., NamedTuple with analysis data)
"""
function evaluate end

# ==============================================================================
# Default Implementations
# ==============================================================================

# Default: no constraints
n_constraints(::AbstractNLPProblem) = 0
constraint_bounds(::AbstractNLPProblem) = (Float64[], Float64[])
constraint_fns(::AbstractNLPProblem, ::Vector{Float64}) = Float64[]

# Default evaluate using gradient-based interface
function evaluate(p::AbstractNLPProblem, x::Vector{Float64})
    obj = objective_fn(p, x)
    
    nc = n_constraints(p)
    if nc == 0
        return (true, obj, nothing)
    end
    
    g = constraint_fns(p, x)
    lb, ub = constraint_bounds(p)
    feasible = all(i -> lb[i] ≤ g[i] ≤ ub[i], 1:nc)
    
    return (feasible, feasible ? obj : Inf, (constraints=g,))
end

# Default variable names
function variable_names(p::AbstractNLPProblem)
    ["x$i" for i in 1:n_variables(p)]
end

# Default constraint names
function constraint_names(p::AbstractNLPProblem)
    ["g$i" for i in 1:n_constraints(p)]
end

# ==============================================================================
# Problem Inspection Utilities
# ==============================================================================

"""
    problem_summary(problem::AbstractNLPProblem) -> String

Return a human-readable summary of the optimization problem.
Useful for debugging and logging.
"""
function problem_summary(p::AbstractNLPProblem)
    lb, ub = variable_bounds(p)
    names = variable_names(p)
    nc = n_constraints(p)
    
    lines = String[]
    push!(lines, "NLP Problem: $(typeof(p))")
    push!(lines, "  Variables: $(n_variables(p))")
    for (i, name) in enumerate(names)
        push!(lines, "    $name ∈ [$(lb[i]), $(ub[i])]")
    end
    push!(lines, "  Constraints: $nc")
    if nc > 0
        c_lb, c_ub = constraint_bounds(p)
        c_names = constraint_names(p)
        for (i, name) in enumerate(c_names)
            push!(lines, "    $name: $(c_lb[i]) ≤ g$i(x) ≤ $(c_ub[i])")
        end
    end
    
    return join(lines, "\n")
end