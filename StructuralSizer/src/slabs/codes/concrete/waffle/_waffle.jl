# =============================================================================
# Waffle Slab Geometry & Design per ACI 318
# =============================================================================
#
# Directory structure:
#   types.jl        - IsoParametricPanel, WaffleRibGrid, RibModule
#   geometry.jl     - Isoparametric mapping: forward, Jacobian, inverse
#   rib_layout.jl   - Rib lines, void enumeration, solid head regions
#   wachspress.jl   - WachspressPanel: generalized isoparametric map for
#                     convex N-gons (reduces to bilinear for quads)
#
# Future:
#   analysis/       - DDM/FEA with waffle section properties
#   design/         - Rib shear, punching at solid heads, deflection
#   pipeline.jl     - size_waffle! orchestration
#
# =============================================================================

include("types.jl")
include("geometry.jl")
include("rib_layout.jl")
include("wachspress.jl")    # must follow rib_layout.jl (extends its functions)
