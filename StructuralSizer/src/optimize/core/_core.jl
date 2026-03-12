# Core optimization abstractions (domain-agnostic)
#
# Member-specific types (geometry, demands) are in members/types/.
# Floor-specific types will be in slabs/optimize/ (future).

include("interface.jl")   # AbstractCapacityChecker, AbstractCapacityCache
include("objectives.jl")  # AbstractObjective, MinVolume, MinWeight, etc.
include("options.jl")     # SteelColumnOptions, SteelBeamOptions, ConcreteColumnOptions, ConcreteBeamOptions, NLP options