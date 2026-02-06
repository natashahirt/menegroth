# ==============================================================================
# Optimization Infrastructure (Shared)
# ==============================================================================
#
# Shared optimization components for members, slabs, and foundations.
#
# Structure:
#   core/       - Abstract types, interface, objectives, options
#   solvers/    - MIP (JuMP/HiGHS) and NLP (NonConvex/Ipopt) solvers
#
# Member-specific optimization (catalogs, API) is in members/optimize/.
# Floor-specific optimization will be in slabs/optimize/.
#
# This entire module loads BEFORE members/, so it cannot depend on:
#   - Section definitions (members/sections/)
#   - Capacity checkers (members/codes/)
#
# The generic solver (optimize_discrete) uses AbstractCapacityChecker interface,
# which is implemented by checkers loaded later.

# Core abstractions (types, objectives, options)
include("core/_core.jl")

# Solvers (use abstract interface only)
include("solvers/_solvers.jl")
