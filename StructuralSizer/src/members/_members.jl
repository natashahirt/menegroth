# Member sizing: materials, sections, codes, optimization

# Abstract interfaces (must come first - used by codes and sections)
include("optimize/interface.jl")
include("optimize/geometry.jl")
include("optimize/demands.jl")
include("optimize/objectives.jl")

# Sections (geometry + catalogs)
include("sections/_sections.jl")

# Design code checks (checkers use AbstractCapacityChecker from interface)
include("codes/_codes.jl")

# Optimization algorithms (use checkers from codes)
include("optimize/discrete_mip.jl")
