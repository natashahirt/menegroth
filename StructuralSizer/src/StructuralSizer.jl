module StructuralSizer

using StructuralBase
using Unitful

include("types.jl")
include("materials/steel.jl")
include("materials/concrete.jl")

# Types
export Metal

# Material Instances
export A992_Steel, S355_Steel

end # module
