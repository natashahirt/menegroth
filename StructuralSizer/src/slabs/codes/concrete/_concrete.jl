# Concrete floor systems
# CIP, precast, and special concrete slabs

# ACI minimum thickness tables (deflection control, all CIP types)
include("min_thickness.jl")

# Waffle slab geometry and design (two-way joist system)
# Included before flat_plate because flat_plate/analysis/fea/ reuses
# IsoParametricPanel + bilinear mapping from waffle/geometry.jl.
include("waffle/_waffle.jl")

# Calculations and analysis (loads before sizing)
include("flat_plate/_flat_plate.jl")

# One-way coefficients, or the shell for any other panel.
include("panel_analysis.jl")

# Frame beams sharing nodes with that shell. Wall lines are supports of it.
include("panel_shell_beams.jl")

# Slab edge outside the column centerlines. The centerline polygon stays put.
include("slab_edge.jl")

# Slab bars from that shell's moment tensor.
include("story_shell_bars.jl")

# CIP sizing for all cast-in-place types (FlatPlate, FlatSlab, TwoWay, OneWay, Waffle, PTBanded)
include("sizing.jl")

# Precast (separate sizing)
include("hollow_core.jl")