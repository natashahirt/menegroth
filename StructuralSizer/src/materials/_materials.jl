# Import units for material display functions
using Asap: ksi
using Unitful: psi

# Material type definitions first
include("types.jl")

# Preset instances
include("steel.jl")
include("concrete.jl")
include("frc.jl")
include("timber.jl")

# Empirical ECC distribution registry (NRMCA / RMC EPD dataset).
# Loaded lazily; used by `flat_plate_methods` Section 2 sensitivity sweep.
include("ecc/distributions.jl")

# Fire protection types (SurfaceCoating, SFRM, IntumescentCoating, etc.)
include("fire_protection.jl")
