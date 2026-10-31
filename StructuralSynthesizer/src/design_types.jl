# =============================================================================
# Design Result Types
# =============================================================================
#
# Separates building geometry/loads (BuildingStructure) from design results
# (BuildingDesign). This enables:
#   - Multiple designs for the same building (different materials)
#   - Parametric studies (sweep f'c, thickness, etc.)
#   - Design comparison and optimization
#
# Architecture:
#   BuildingStructure          → geometry, loads, tributaries (see building_types.jl)
#   BuildingDesign             → design results for a specific parameter set
#   DesignParameters           → material choices, optimization targets
#
# Unit Convention:
#   All design results are stored in coherent SI:
#     m, m², m³, kN, kN·m, kPa, kg
#   Analysis modules work in whatever units are natural internally,
#   then normalize at their return boundary.
#   DisplayUnits controls how values are presented to the user.
# =============================================================================

using Dates
using Unitful
using Accessors: setproperties, @set

include("design/display_units.jl")
include("design/material_options.jl")
include("design/parameters.jl")
include("design/overrides.jl")
include("design/context.jl")
include("design/results/slab.jl")
include("design/results/column.jl")
include("design/results/beam.jl")
include("design/results/foundation.jl")
include("design/summary.jl")
include("design/results/wall.jl")
include("design/building_design.jl")
