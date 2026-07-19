# Member sizing: types, sections, codes, optimization
# Note: Shared optimization infrastructure is in top-level optimize/

# (role, material, lateral_role) connection defaults — entry points + fallbacks.
# Per-material specializations live in materials/{steel,concrete,timber}.jl
# (loaded earlier); this file declares the public signatures and the explicit
# error fallbacks for undeclared combinations.
include("defaults.jl")

# Member-specific optimization types (geometry, demands)
# Must come before codes/ which use these types
include("types/_types.jl")

# Sections (geometry + catalogs)
include("sections/_sections.jl")

# Design code checks (checkers use AbstractCapacityChecker from optimize/core)
include("codes/_codes.jl")

# Member-specific optimization (catalogs, API)
# Must come after sections/ and codes/
include("optimize/_optimize.jl")
