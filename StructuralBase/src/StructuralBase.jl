module StructuralBase

using Unitful
using Reexport

# Constants submodule (loads, material densities, unit standards)
include("Constants.jl")
@reexport using .Constants

# Abstract types for inheritance
include("types.jl")

# Exports
export AbstractMaterial, AbstractDesignCode
export AbstractStructuralSynthesizer, AbstractBuildingSkeleton, AbstractBuildingStructure
export Constants  # Allow qualified access: Constants.LL_FLOOR, Constants.ρ_STEEL, etc.

# Package Initialization
function __init__()
    # Registers custom structural units (psf, kip, lbf) defined in Constants
    Unitful.register(Constants)
end

end # module StructuralBase