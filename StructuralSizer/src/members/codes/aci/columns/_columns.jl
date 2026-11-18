# ==============================================================================
# ACI 318 Column Design
# ==============================================================================
# P-M interaction diagrams, slenderness effects, biaxial bending.

# P-M interaction (defines PMInteractionDiagram used by checker)
include("pm_rect.jl")
include("pm_circular.jl")
include("slenderness.jl")
include("biaxial.jl")

# Checker depends on pm, slenderness, biaxial
include("checker.jl")

# One-way shear. Ties are sized here; detailing places the spacing it returns.
include("shear.jl")

# ACI 318-11 §10.12: column strength where it passes through a weaker floor.
include("floor_transmission.jl")
