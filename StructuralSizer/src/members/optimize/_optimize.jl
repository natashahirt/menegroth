# ==============================================================================
# Member-Specific Optimization
# ==============================================================================
# Depends on: sections/, codes/ (must be included after them)
# Uses: optimize/core/ and optimize/solvers/ (loaded earlier)

# Catalog builders (depend on sections)
include("catalogs.jl")

# NLP problem definitions (for continuous optimization)
include("problems.jl")

# High-level API (depends on catalogs, checkers, solvers, problems)
include("api.jl")
