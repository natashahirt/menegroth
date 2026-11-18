# Tributary areas. Each cell edge gets one polygon (`cell_tributaries.jl`).
# Beams carry those polygons (`beam_tributaries.jl`). Columns and walls share
# the same polygons (`support_tributaries.jl`) and then take the slab past
# the centerlines (`edge_strips.jl`).
include("cell_tributaries.jl")
include("beam_tributaries.jl")
include("support_tributaries.jl")
include("edge_strips.jl")
