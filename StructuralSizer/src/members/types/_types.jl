# ==============================================================================
# Member-Specific Types for Optimization
# ==============================================================================
#
# These types are used by the optimization framework but are member-specific.
# Generic optimization abstractions (AbstractCapacityChecker, AbstractObjective)
# live in optimize/core/.

# Geometry types for different material systems
include("geometry.jl")

# Demand types for force/moment envelopes
include("demands.jl")
