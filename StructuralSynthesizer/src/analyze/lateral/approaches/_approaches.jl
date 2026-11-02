# Behavior for the lateral design types. The types are in `types.jl`, which is
# included before `design_types.jl`.
include("interface.jl")
include("systems/walls_seismic_system.jl")
include("systems/interactive_shear_wall_frame_system.jl")
include("systems/outrigger_system.jl")
include("assignment/building_unit.jl")
include("assignment/isolated_wall_share.jl")
