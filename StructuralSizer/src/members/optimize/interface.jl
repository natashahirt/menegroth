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
"""
abstract type AbstractMemberGeometry end

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
