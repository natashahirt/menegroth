# =============================================================================
# Flat Plate Design Pipeline
# =============================================================================

include("pipeline/column_updates.jl")
include("pipeline/punching_resolution.jl")
include("pipeline/final_design.jl")
include("pipeline/transfer_reinforcement.jl")
include("pipeline/thickness_jump.jl")
include("pipeline/joint_search.jl")
include("pipeline/api.jl")
include("pipeline/iteration.jl")
