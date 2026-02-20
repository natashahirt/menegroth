# =============================================================================
# Isoparametric Panel Geometry
# =============================================================================
#
# Bilinear mapping between the reference square [0,1]² and a physical
# quadrilateral.  All functions are pure (no side effects) and unit-free
# (caller supplies coordinates in whatever system they prefer).
#
# Corner numbering follows standard FEA convention:
#
#     η                                   4 ─── 3
#     ↑                                   │     │
#     4 ── 3     ←→   physical panel      │     │
#     │    │                              1 ─── 2
#     1 ── 2 → ξ
#
# For a rectangle aligned with x/y axes, the mapping reduces to:
#   x(ξ,η) = x₁ + ξ·(x₂ - x₁)
#   y(ξ,η) = y₁ + η·(y₄ - y₁)
# with constant Jacobian = diag(Lx, Ly).
#
# =============================================================================

# =============================================================================
# Shape Functions
# =============================================================================

"""
    shape_functions(ξ, η) -> NTuple{4, Float64}

Bilinear shape functions evaluated at (ξ, η) ∈ [0,1]².

N₁ = (1-ξ)(1-η),  N₂ = ξ(1-η),  N₃ = ξη,  N₄ = (1-ξ)η
"""
@inline function shape_functions(ξ::Real, η::Real)
    (
        (1 - ξ) * (1 - η),   # N₁
        ξ       * (1 - η),   # N₂
        ξ       * η,         # N₃
        (1 - ξ) * η,         # N₄
    )
end

"""
    dN_dξη(ξ, η) -> (dN_dξ::NTuple{4}, dN_dη::NTuple{4})

Partial derivatives of the bilinear shape functions.
"""
@inline function dN_dξη(ξ::Real, η::Real)
    dN_dξ = (-(1 - η),  (1 - η),  η, -η)
    dN_dη = (-(1 - ξ), -ξ,        ξ,  (1 - ξ))
    (dN_dξ, dN_dη)
end

# =============================================================================
# Forward Map: (ξ, η) → (x, y)
# =============================================================================

"""
    physical_coords(panel, ξ, η) -> (x, y)

Map a point from the reference square to physical space.

# Example
```julia
panel = IsoParametricPanel(((0,0), (10,0), (10,8), (0,8)))
physical_coords(panel, 0.5, 0.5)  # → (5.0, 4.0)  center of rectangle
```
"""
function physical_coords(panel::IsoParametricPanel, ξ::Real, η::Real)
    N = shape_functions(ξ, η)
    c = panel.corners
    x = N[1]*c[1][1] + N[2]*c[2][1] + N[3]*c[3][1] + N[4]*c[4][1]
    y = N[1]*c[1][2] + N[2]*c[2][2] + N[3]*c[3][2] + N[4]*c[4][2]
    (x, y)
end

# =============================================================================
# Jacobian
# =============================================================================

"""
    jacobian(panel, ξ, η) -> SMatrix{2,2}

Jacobian matrix of the isoparametric mapping at (ξ, η).

    J = [∂x/∂ξ  ∂x/∂η]
        [∂y/∂ξ  ∂y/∂η]

For a rectangle, J is constant: diag(Lx, Ly).
"""
function jacobian(panel::IsoParametricPanel, ξ::Real, η::Real)
    dNξ, dNη = dN_dξη(ξ, η)
    c = panel.corners
    # ∂x/∂ξ, ∂x/∂η
    dx_dξ = dNξ[1]*c[1][1] + dNξ[2]*c[2][1] + dNξ[3]*c[3][1] + dNξ[4]*c[4][1]
    dx_dη = dNη[1]*c[1][1] + dNη[2]*c[2][1] + dNη[3]*c[3][1] + dNη[4]*c[4][1]
    # ∂y/∂ξ, ∂y/∂η
    dy_dξ = dNξ[1]*c[1][2] + dNξ[2]*c[2][2] + dNξ[3]*c[3][2] + dNξ[4]*c[4][2]
    dy_dη = dNη[1]*c[1][2] + dNη[2]*c[2][2] + dNη[3]*c[3][2] + dNη[4]*c[4][2]

    # Column-major 2×2: J[:, 1] = ∂/∂ξ, J[:, 2] = ∂/∂η
    [dx_dξ dx_dη;
     dy_dξ dy_dη]
end

"""
    jacobian_det(panel, ξ, η) -> Float64

Determinant of the Jacobian.  Positive for a valid (non-degenerate) CCW quad.
"""
jacobian_det(panel::IsoParametricPanel, ξ::Real, η::Real) = det(jacobian(panel, ξ, η))

# =============================================================================
# Inverse Map: (x, y) → (ξ, η)  via Newton–Raphson
# =============================================================================

"""
    parametric_coords(panel, x, y; tol=1e-12, maxiter=20) -> (ξ, η)

Invert the isoparametric mapping: find (ξ, η) such that
`physical_coords(panel, ξ, η) ≈ (x, y)`.

Uses Newton–Raphson iteration starting from (0.5, 0.5).
Converges in 1 iteration for rectangles, 2–4 for general quads.

Throws if the iteration does not converge (point likely outside panel).
"""
function parametric_coords(panel::IsoParametricPanel, x::Real, y::Real;
                           tol::Float64 = 1e-12, maxiter::Int = 20)
    ξ, η = 0.5, 0.5   # initial guess: center of reference square
    for _ in 1:maxiter
        xy = physical_coords(panel, ξ, η)
        r = [xy[1] - x, xy[2] - y]
        if norm(r) < tol
            return (ξ, η)
        end
        J = jacobian(panel, ξ, η)
        Δ = J \ r       # solve J · Δ = r
        ξ -= Δ[1]
        η -= Δ[2]
    end
    error("parametric_coords: Newton did not converge for (x=$x, y=$y) on panel $(panel.corners)")
end

# =============================================================================
# Convenience: construct from vertex list
# =============================================================================

"""
    ensure_ccw(pts::AbstractVector) -> NTuple{4, NTuple{2, Float64}}

Ensure four 2D points are in CCW order (positive signed area).
Accepts vectors of tuples, vectors, or any indexable 2-element container.
"""
function ensure_ccw(pts::AbstractVector)
    length(pts) == 4 || error("ensure_ccw: expected 4 points, got $(length(pts))")
    # Signed area via shoelace
    sa = 0.0
    for i in 1:4
        j = mod1(i + 1, 4)
        sa += pts[i][1] * pts[j][2] - pts[j][1] * pts[i][2]
    end
    ordered = sa ≥ 0 ? pts : reverse(pts)
    ntuple(i -> (Float64(ordered[i][1]), Float64(ordered[i][2])), 4)
end

"""
    IsoParametricPanel(pts::AbstractVector)

Construct from a vector of four 2D points (auto-ensures CCW ordering).
"""
IsoParametricPanel(pts::AbstractVector) = IsoParametricPanel(ensure_ccw(pts))

# =============================================================================
# Quality metric
# =============================================================================

"""
    min_jacobian_det(panel; n=5) -> Float64

Minimum Jacobian determinant sampled on an n×n grid over [0,1]².
A positive value indicates a valid (non-inverted) mapping everywhere.
"""
function min_jacobian_det(panel::IsoParametricPanel; n::Int = 5)
    jmin = Inf
    for i in 0:n, j in 0:n
        ξ = i / n
        η = j / n
        jd = jacobian_det(panel, ξ, η)
        jd < jmin && (jmin = jd)
    end
    jmin
end

"""
    panel_area(panel; n=10) -> Float64

Physical area of the panel via Gauss quadrature over the reference domain.
Uses an n×n grid of midpoint quadrature for simplicity.
"""
function panel_area(panel::IsoParametricPanel; n::Int = 10)
    A = 0.0
    dξ = 1.0 / n
    dη = 1.0 / n
    for i in 1:n, j in 1:n
        ξ = (i - 0.5) * dξ
        η = (j - 0.5) * dη
        A += abs(jacobian_det(panel, ξ, η)) * dξ * dη
    end
    A
end
