# =============================================================================
# Waffle Slab Geometry Types
# =============================================================================
#
# Core data structures for isoparametric panel mapping and waffle rib grids.
#
# The isoparametric approach maps any convex quadrilateral panel to a unit
# square [0,1]², enabling a single code path for regular, trapezoidal, and
# general quad panels.  Rib lines run along iso-ξ and iso-η curves; void
# sizes are evaluated per-module using the local Jacobian.
#
# References:
#   - Hartwell (2023), Ch. 3 & 5  — parametric waffle slab definition
#   - Hughes (2000), §3.2          — bilinear isoparametric mapping
# =============================================================================

using LinearAlgebra: det, norm

# =============================================================================
# Isoparametric Panel
# =============================================================================

"""
    IsoParametricPanel

Bilinear map from the reference square [0,1]² to a physical quadrilateral
defined by four corner points (CCW order).

Corner numbering (reference domain):

    η
    ↑
    4 ────── 3       corners[1] = (ξ=0, η=0)
    │        │       corners[2] = (ξ=1, η=0)
    │        │       corners[3] = (ξ=1, η=1)
    1 ────── 2 → ξ   corners[4] = (ξ=0, η=1)

For a rectangle with origin at corner 1, this reduces to a linear scaling.
"""
struct IsoParametricPanel
    corners::NTuple{4, NTuple{2, Float64}}  # (x, y), CCW from bottom-left
end

# =============================================================================
# Waffle Rib Grid
# =============================================================================

"""
    WaffleRibGrid

Waffle rib layout on an `IsoParametricPanel`.

Ribs run along lines of constant ξ (family 1) and constant η (family 2),
dividing the panel into `nξ × nη` rectangular modules in parametric space.

# Fields
- `panel`:       Underlying isoparametric panel
- `nξ`, `nη`:    Number of rib modules in each parametric direction
- `solid_head`:  Extent of solid region near each corner, in parametric
                 units [0, 0.5).  Voids within this distance of any corner
                 are filled solid (no void form).
"""
struct WaffleRibGrid
    panel::IsoParametricPanel
    nξ::Int
    nη::Int
    solid_head::Float64   # parametric distance from corners
end

"""
    WaffleRibGrid(panel, nξ, nη; solid_head=0.0)

Construct a `WaffleRibGrid` with validation on grid counts and solid head extent.

# Arguments
- `panel::IsoParametricPanel`: underlying panel geometry.
- `nξ::Int`: number of rib modules in the ξ direction (≥ 1).
- `nη::Int`: number of rib modules in the η direction (≥ 1).
- `solid_head::Float64`: parametric distance from corners defining the solid region, in [0, 0.5).
"""
function WaffleRibGrid(panel::IsoParametricPanel, nξ::Int, nη::Int;
                       solid_head::Float64 = 0.0)
    @assert nξ ≥ 1 "nξ must be ≥ 1"
    @assert nη ≥ 1 "nη must be ≥ 1"
    @assert 0.0 ≤ solid_head < 0.5 "solid_head must be in [0, 0.5)"
    WaffleRibGrid(panel, nξ, nη, solid_head)
end

# =============================================================================
# Rib Module (output of grid queries)
# =============================================================================

"""
    RibModule

Geometry of a single waffle rib module (one void cell).

# Fields
- `i`, `j`:          Grid indices (1-based)
- `ξ_center`, `η_center`: Centroid in parametric space
- `xy_center`:       Centroid in physical space (x, y)
- `xy_corners`:      Four physical corners of the module (CCW)
- `phys_area`:       Physical area of the module (m² or ft²)
- `is_solid`:        `true` if within the solid head region
"""
struct RibModule
    i::Int
    j::Int
    ξ_center::Float64
    η_center::Float64
    xy_center::NTuple{2, Float64}
    xy_corners::NTuple{4, NTuple{2, Float64}}
    phys_area::Float64
    is_solid::Bool
end
