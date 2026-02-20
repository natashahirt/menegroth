# ==============================================================================
# ACI 318 Concrete Design
# ==============================================================================
# ACI 318-11 Building Code Requirements for Structural Concrete
#
# Shared material utilities (Ec, β1, fr, Whitney block, deflection, rebar)
# are in codes/aci/ — loaded earlier in the module include order.
#
# This file includes element-specific ACI design checks.
# ==============================================================================

# Column design (P-M interaction, slenderness, biaxial)
include("columns/_columns.jl")

# Beam design (flexure, shear, serviceability)
include("beams/_beams.jl")
