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
- `precompute_capacities!(checker, cache, catalog, material, objective)` - fill cache
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
    precompute_capacities!(checker, cache, catalog, material, objective)

Precompute and cache capacity values that are reused across multiple 
feasibility checks. Called once before the optimization loop.
"""
function precompute_capacities! end

"""
    is_feasible(checker, cache, j, section, material, demand, geometry) -> Bool

Check if `section` (at index `j` in catalog) with `material` satisfies all 
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

"""Default error message when no section is feasible."""
function get_feasibility_error_msg(::AbstractCapacityChecker, demand, geometry)
    "No feasible section found for demand=$demand"
end

"""
    diagnose_infeasibility(checker, cache, catalog, material, demand, geometry) -> Union{String, Nothing}

Optional: return a diagnostic string when no section is feasible. Returns `nothing` if
the checker does not support diagnostics.
"""
function diagnose_infeasibility(::AbstractCapacityChecker, cache, catalog, material, demand, geometry)
    nothing
end

# ==============================================================================
# Feasibility Explanation (for Solver Trace)
# ==============================================================================

"""
    CheckResult

Result of a single design code check within `explain_feasibility`.

# Fields
- `name::String` — check name (e.g. "shear_strong", "pm_interaction_compression")
- `passed::Bool` — whether this check passed
- `ratio::Float64` — demand/capacity ratio (< 1.0 passes, > 1.0 fails)
- `demand::Float64` — demand value in SI units
- `capacity::Float64` — capacity value in SI units
- `code_clause::String` — governing code clause (e.g. "AISC 360-16 G2", "ACI 318-19 22.6")
"""
struct CheckResult
    name::String
    passed::Bool
    ratio::Float64
    demand::Float64
    capacity::Float64
    code_clause::String
end

"""
    FeasibilityExplanation

Detailed breakdown of all design code checks for a single section/demand pair.
Returned by `explain_feasibility` — the diagnostic sibling of `is_feasible`.

# Fields
- `passed::Bool` — overall feasibility (all checks pass)
- `checks::Vector{CheckResult}` — individual check results in evaluation order
- `governing_check::String` — name of the check with the highest ratio
- `governing_ratio::Float64` — the highest ratio across all checks
"""
struct FeasibilityExplanation
    passed::Bool
    checks::Vector{CheckResult}
    governing_check::String
    governing_ratio::Float64
end

"""
    explain_feasibility(checker, cache, j, section, material, demand, geometry) -> FeasibilityExplanation

Detailed diagnostic version of `is_feasible`. Evaluates ALL design code checks
(does not short-circuit on first failure) and returns per-check ratios.

Used by the solver trace to explain why a section was selected or rejected.
NOT used in the hot MIP loop — `is_feasible` remains the fast path.

The default implementation returns a single-check explanation based on
`is_feasible` (pass/fail only, no ratios). Checkers should override this
with their code-specific check breakdown.
"""
function explain_feasibility(checker::AbstractCapacityChecker, cache, j, section, material, demand, geometry)
    ok = is_feasible(checker, cache, j, section, material, demand, geometry)
    check = CheckResult("aggregate", ok, ok ? 0.0 : Inf, 0.0, 0.0, "")
    FeasibilityExplanation(ok, [check], "aggregate", ok ? 0.0 : Inf)
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

"""Default: no constraints for an NLP problem."""
n_constraints(::AbstractNLPProblem) = 0

"""Default: empty constraint bounds for an unconstrained NLP problem."""
constraint_bounds(::AbstractNLPProblem) = (Float64[], Float64[])

"""Default: empty constraint vector for an unconstrained NLP problem."""
constraint_fns(::AbstractNLPProblem, ::Vector{Float64}) = Float64[]

"""Default `evaluate` implementation using the gradient-based interface."""
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

"""Default variable names (`x1`, `x2`, …) for an NLP problem."""
function variable_names(p::AbstractNLPProblem)
    ["x$i" for i in 1:n_variables(p)]
end

"""Default constraint names (`g1`, `g2`, …) for an NLP problem."""
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