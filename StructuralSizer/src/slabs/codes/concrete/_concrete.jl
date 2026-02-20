# Concrete floor systems
# CIP, precast, and special concrete slabs

# ACI minimum thickness tables (deflection control, all CIP types)
include("min_thickness.jl")

# Calculations and analysis (loads before sizing)
include("flat_plate/_flat_plate.jl")

# Waffle slab geometry and design (two-way joist system)
include("waffle/_waffle.jl")

# CIP sizing for all cast-in-place types (FlatPlate, FlatSlab, TwoWay, OneWay, Waffle, PTBanded)
include("sizing.jl")

# Precast (separate sizing)
include("hollow_core.jl")