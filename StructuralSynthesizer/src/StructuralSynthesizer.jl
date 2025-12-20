module StructuralSynthesizer

import GLMakie
import Meshes
import Graphs
import Asap
using Unitful

include("./generate/_generate.jl")
include("./visualization/_visualization.jl")

export gen_medium_office
export StructureSkeleton
export visualize
export add_vertex!, add_element!

end # module StructuralSynthesizer