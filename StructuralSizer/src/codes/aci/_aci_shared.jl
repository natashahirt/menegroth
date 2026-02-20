# ==============================================================================
# Shared ACI 318 Concrete Design Utilities
# ==============================================================================
#
# Element-agnostic ACI math used by BOTH members (beams, columns) and slabs.
# Included BEFORE members/ and slabs/ in the StructuralSizer module.
#
# Contents:
#   material_properties.jl  - Ec, beta1/β1, fr, material extractors
#   whitney.jl              - Whitney stress block (required_reinforcement)
#   deflection.jl           - Icr, Ie, Mcr, immediate deflection
#   rebar_utils.jl          - Bar selection, ASTM A615 catalog lookups
#
# ==============================================================================

include("material_properties.jl")
include("whitney.jl")
include("deflection.jl")
include("rebar_utils.jl")
include("punching.jl")
include("fire.jl")