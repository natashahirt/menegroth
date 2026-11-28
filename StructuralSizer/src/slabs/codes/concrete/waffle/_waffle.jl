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
#   rib_arrangement.jl - ribs on any polygon with holes: planar bays,
#                     module grids at an angle, per-bay skeleton loads
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
include("rib_network.jl")   # crossings and the straight pieces between them
include("rib_tributary.jl") # rectangular-bay load on those ribs
include("rib_arrangement.jl") # any region with holes: bays, module grids, skeleton loads
include("solid_head_modules.jl") # per-column solid bays, grown one module at a time
include("solid_head_punching.jl") # column and rib-web punching; no joist factor
include("rib_head_shear.jl")      # one-way rib shear at d from the head face
include("rib_deflection.jl")        # frame deflection scaled by Eq. (9-8) and Eq. (9-11)
include("wachspress.jl")    # must follow rib_layout.jl (extends its functions)
