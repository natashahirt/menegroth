# ==============================================================================
# AISC 360 Steel Design Checks
# ==============================================================================
# Organized by chapter

include("slenderness.jl")  # Table B4.1b - must come first (used by flexure)
include("flexure.jl")      # Chapter F
include("shear.jl")        # Chapter G
include("compression.jl")  # Chapter E
include("tension.jl")      # Chapter D
include("interaction.jl")  # Chapter H

# Capacity Checker (implements AbstractCapacityChecker interface)
include("checker.jl")
