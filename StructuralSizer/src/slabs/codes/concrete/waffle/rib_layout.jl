# =============================================================================
# Waffle Rib Grid Layout
# =============================================================================
#
# Functions to generate rib lines, void centroids, and module geometry
# from a WaffleRibGrid.  All geometry is computed via the isoparametric
# mapping, so irregular/skewed panels are handled automatically.
#
# =============================================================================

# =============================================================================
# Rib Lines
# =============================================================================

"""
    rib_lines_ξ(grid; n_pts=20) -> Vector{Vector{NTuple{2,Float64}}}

Polylines for ribs of constant ξ (running in the η direction).
Returns `nξ + 1` polylines (at ξ = 0, 1/nξ, 2/nξ, ..., 1).
Each polyline has `n_pts` points sampled along η ∈ [0, 1].

For a rectangular panel these are straight vertical lines;
for a general quad they curve smoothly.
"""
function rib_lines_ξ(grid::WaffleRibGrid; n_pts::Int = 20)
    panel = grid.panel
    lines = Vector{Vector{NTuple{2, Float64}}}(undef, grid.nξ + 1)
    for i in 0:grid.nξ
        ξ = i / grid.nξ
        pts = Vector{NTuple{2, Float64}}(undef, n_pts)
        for k in 1:n_pts
            η = (k - 1) / (n_pts - 1)
            pts[k] = physical_coords(panel, ξ, η)
        end
        lines[i + 1] = pts
    end
    lines
end

"""
    rib_lines_η(grid; n_pts=20) -> Vector{Vector{NTuple{2,Float64}}}

Polylines for ribs of constant η (running in the ξ direction).
Returns `nη + 1` polylines.
"""
function rib_lines_η(grid::WaffleRibGrid; n_pts::Int = 20)
    panel = grid.panel
    lines = Vector{Vector{NTuple{2, Float64}}}(undef, grid.nη + 1)
    for j in 0:grid.nη
        η = j / grid.nη
        pts = Vector{NTuple{2, Float64}}(undef, n_pts)
        for k in 1:n_pts
            ξ = (k - 1) / (n_pts - 1)
            pts[k] = physical_coords(panel, ξ, η)
        end
        lines[j + 1] = pts
    end
    lines
end

# =============================================================================
# Solid Head Region
# =============================================================================

"""
    is_in_solid_head(ξ, η, solid_head) -> Bool

Check whether parametric coordinates (ξ, η) fall within the solid head
region near any corner.  A module is solid if its center is within
`solid_head` of any corner in *both* ξ and η simultaneously.

This produces a rectangular solid zone at each corner in parametric space,
which maps to the physical solid head shape through the isoparametric map.
"""
function is_in_solid_head(ξ::Real, η::Real, solid_head::Real)
    solid_head ≤ 0 && return false
    # Check proximity to each of the four corners: (0,0), (1,0), (1,1), (0,1)
    near_ξ_0 = ξ ≤ solid_head
    near_ξ_1 = ξ ≥ 1 - solid_head
    near_η_0 = η ≤ solid_head
    near_η_1 = η ≥ 1 - solid_head
    return (near_ξ_0 || near_ξ_1) && (near_η_0 || near_η_1)
end

# =============================================================================
# Void / Module Enumeration
# =============================================================================

"""
    modules(grid) -> Vector{RibModule}

Enumerate all rib modules (void cells) in the grid.

Each module `(i, j)` occupies parametric rectangle
    [(i-1)/nξ, i/nξ] × [(j-1)/nη, j/nη]

Returns a flat vector; use `i, j` fields to reconstruct the 2D layout.
"""
function modules(grid::WaffleRibGrid)
    panel = grid.panel
    nξ, nη = grid.nξ, grid.nη
    result = Vector{RibModule}(undef, nξ * nη)
    idx = 0
    for j in 1:nη, i in 1:nξ
        ξ_lo = (i - 1) / nξ
        ξ_hi = i / nξ
        η_lo = (j - 1) / nη
        η_hi = j / nη
        ξ_c = (ξ_lo + ξ_hi) / 2
        η_c = (η_lo + η_hi) / 2

        # Physical corners of the module (CCW)
        c1 = physical_coords(panel, ξ_lo, η_lo)
        c2 = physical_coords(panel, ξ_hi, η_lo)
        c3 = physical_coords(panel, ξ_hi, η_hi)
        c4 = physical_coords(panel, ξ_lo, η_hi)
        xy_c = physical_coords(panel, ξ_c, η_c)

        # Area via cross product of diagonals (exact for bilinear quad)
        # Shoelace formula for the 4 corners
        corners = (c1, c2, c3, c4)
        area = abs(_shoelace4(corners))

        solid = is_in_solid_head(ξ_c, η_c, grid.solid_head)

        idx += 1
        result[idx] = RibModule(i, j, ξ_c, η_c, xy_c, corners, area, solid)
    end
    result
end

"""Shoelace area for 4-vertex polygon."""
@inline function _shoelace4(c::NTuple{4, NTuple{2, Float64}})
    0.5 * (
        (c[1][1]*c[2][2] - c[2][1]*c[1][2]) +
        (c[2][1]*c[3][2] - c[3][1]*c[2][2]) +
        (c[3][1]*c[4][2] - c[4][1]*c[3][2]) +
        (c[4][1]*c[1][2] - c[1][1]*c[4][2])
    )
end

# =============================================================================
# Summary
# =============================================================================

"""
    grid_summary(grid) -> NamedTuple

Quick summary of grid geometry for debugging.
"""
function grid_summary(grid::WaffleRibGrid)
    mods = modules(grid)
    n_solid = count(m -> m.is_solid, mods)
    areas = [m.phys_area for m in mods]
    panel_a = panel_area(grid.panel)
    (
        n_modules   = length(mods),
        n_solid     = n_solid,
        n_void      = length(mods) - n_solid,
        panel_area  = panel_a,
        module_area_sum = sum(areas),
        min_module_area = minimum(areas),
        max_module_area = maximum(areas),
        area_ratio  = sum(areas) / panel_a,
        min_jac_det = min_jacobian_det(grid.panel),
    )
end
