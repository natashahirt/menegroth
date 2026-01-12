module StructuralSynthesizer

using StructuralBase  # Internal use (Constants, AbstractMaterial)

import GLMakie
import Meshes
import Graphs
import Asap
using Unitful

include("types.jl")
include("./core/_core.jl")
include("./external/_external.jl")
include("./generate/_generate.jl")
include("./visualization/_visualization.jl")
include("./analyze/_analyze.jl")

using .AsapToolkit

# Geometry generation
export gen_medium_office

# Core types
export BuildingSkeleton, BuildingStructure, Story, Slab, SlabSection

# Functions
export visualize
export add_vertex!, add_element!, find_faces!, rebuild_stories!, initialize_slabs!, to_asap!

# Internal toolkit
export AsapToolkit

end # module StructuralSynthesizer