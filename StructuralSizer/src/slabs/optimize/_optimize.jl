# ==============================================================================
# Floor Optimization
# ==============================================================================
# Depends on: codes/ (must be included after codes load)
# Uses: optimize/core/ and optimize/solvers/ (loaded earlier)

# Problem definitions (implement AbstractNLPProblem)
include("problems.jl")

# High-level API
include("api.jl")
