# Member sizing: types, sections, codes, optimization
# Note: Shared optimization infrastructure is in top-level optimize/

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
