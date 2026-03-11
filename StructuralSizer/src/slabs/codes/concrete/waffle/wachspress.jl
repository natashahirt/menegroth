# =============================================================================
# Wachspress Panel — Generalized Isoparametric Map for Convex Polygons
# =============================================================================
#
# Wachspress barycentric coordinates generalize the bilinear shape functions
# from quads to arbitrary convex polygons.  For a quadrilateral, Wachspress
# coordinates ARE the bilinear shape functions, so `WachspressPanel{4}`
# produces identical results to `IsoParametricPanel`.
#
# Each vertex i has physical position (xᵢ, yᵢ) and parametric coordinates
# (ξᵢ, ηᵢ).  Interior parametric coordinates are:
#
#     ξ(x,y) = Σ λᵢ(x,y) · ξᵢ
#     η(x,y) = Σ λᵢ(x,y) · ηᵢ
#
# The valid parametric domain is the convex hull of {(ξᵢ, ηᵢ)}, which for
# a quad with standard assignment equals [0,1]² exactly.
#
# References:
#   - Wachspress (1975), "A Rational Finite Element Basis"
#   - Floater, Hormann, Kós (2006), Adv. Comput. Math.
# =============================================================================

# =============================================================================
# Types
# =============================================================================

"""
    WachspressPanel{N}

Parameterization of a convex N-gon via Wachspress barycentric coordinates.

For N=4 with the standard assignment `(0,0)→(1,0)→(1,1)→(0,1)`, this
reproduces the bilinear isoparametric map exactly.

# Fields
- `vertices`:  Physical corner positions (x, y), CCW order
- `params`:    Parametric coordinates (ξ, η) assigned to each vertex
"""
struct WachspressPanel{N}
    vertices::NTuple{N, NTuple{2, Float64}}
    params::NTuple{N, NTuple{2, Float64}}
end

"""
    WachspressGrid{N}

Waffle rib layout on a `WachspressPanel{N}`.  Rib lines are isolines of
the Wachspress-interpolated ξ and η fields.
"""
struct WachspressGrid{N}
    panel::WachspressPanel{N}
    nξ::Int
    nη::Int
    solid_head::Float64
end

# =============================================================================
# Constructors
# =============================================================================

"""
    WachspressPanel(corners::NTuple{4, NTuple{2, Float64}})

Construct a quad `WachspressPanel{4}` with the standard isoparametric parametric
assignment: `(0,0)→(1,0)→(1,1)→(0,1)`.
"""
function WachspressPanel(corners::NTuple{4, NTuple{2, Float64}})
    WachspressPanel{4}(corners, ((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)))
end

"""
    WachspressPanel(pts::AbstractVector)

Construct a quad `WachspressPanel{4}` from a vector of four 2D points, auto-ensuring
CCW ordering. Only 4-vertex inputs are supported; for N ≠ 4 supply explicit parametric
coordinates via `WachspressPanel(verts, params)`.
"""
function WachspressPanel(pts::AbstractVector)
    n = length(pts)
    if n == 4
        ordered = _ensure_ccw_wach(pts)
        return WachspressPanel(ordered)
    else
        error("For n ≠ 4, supply parametric coords: WachspressPanel(verts, params)")
    end
end

"""
    WachspressPanel(verts::AbstractVector, params::AbstractVector)

Construct a `WachspressPanel{N}` from vertex positions and explicit parametric
coordinates. Both vectors must have the same length N.

# Arguments
- `verts`:  Physical (x, y) positions of the polygon vertices.
- `params`: Parametric (ξ, η) assigned to each vertex.
"""
function WachspressPanel(verts::AbstractVector, params::AbstractVector)
    n = length(verts)
    @assert length(params) == n "Need same count of vertices ($n) and params ($(length(params)))"
    v = ntuple(i -> (Float64(verts[i][1]), Float64(verts[i][2])), n)
    p = ntuple(i -> (Float64(params[i][1]), Float64(params[i][2])), n)
    WachspressPanel{n}(v, p)
end

"""
    WachspressGrid(panel, nξ, nη; solid_head=0.0)

Construct a `WachspressGrid{N}` with validation on grid counts and solid head extent.

# Arguments
- `panel::WachspressPanel{N}`: underlying Wachspress panel geometry.
- `nξ::Int`: number of rib modules in the ξ direction (≥ 1).
- `nη::Int`: number of rib modules in the η direction (≥ 1).
- `solid_head::Float64`: parametric distance from corners defining the solid region, in [0, 0.5).
"""
function WachspressGrid(panel::WachspressPanel{N}, nξ::Int, nη::Int;
                        solid_head::Float64 = 0.0) where {N}
    @assert nξ ≥ 1 && nη ≥ 1
    @assert 0.0 ≤ solid_head < 0.5
    WachspressGrid{N}(panel, nξ, nη, solid_head)
end

"""Ensure four 2D points are in CCW order for Wachspress quad construction."""
function _ensure_ccw_wach(pts::AbstractVector)
    length(pts) == 4 || error("Expected 4 points, got $(length(pts))")
    sa = 0.0
    for i in 1:4
        j = mod1(i + 1, 4)
        sa += pts[i][1] * pts[j][2] - pts[j][1] * pts[i][2]
    end
    ordered = sa ≥ 0 ? pts : reverse(pts)
    ntuple(i -> (Float64(ordered[i][1]), Float64(ordered[i][2])), 4)
end

# =============================================================================
# Geometry helpers (using Meshes.jl)
# =============================================================================

"""Check if a polygon (given as NTuple or vector of (x,y)) is convex (CCW)."""
function is_convex_polygon(verts::NTuple{N}) where {N}
    N < 3 && return true
    sign = 0
    for i in 1:N
        im1 = mod1(i - 1, N)
        ip1 = mod1(i + 1, N)
        cross = (verts[i][1] - verts[im1][1]) * (verts[ip1][2] - verts[i][2]) -
                (verts[i][2] - verts[im1][2]) * (verts[ip1][1] - verts[i][1])
        abs(cross) < 1e-10 && continue
        s = cross > 0 ? 1 : -1
        sign == 0 && (sign = s)
        sign != s && return false
    end
    true
end

"""Vector overload: convert to NTuple and delegate to `is_convex_polygon(::NTuple)`."""
function is_convex_polygon(verts::AbstractVector)
    n = length(verts)
    tup = ntuple(i -> (Float64(verts[i][1]), Float64(verts[i][2])), n)
    is_convex_polygon(tup)
end

"""Polygon area via Meshes.jl `Ngon` + `measure`."""
function _ngon_area(verts::NTuple{N}) where {N}
    pts = ntuple(i -> Meshes.Point(verts[i][1], verts[i][2]), N)
    poly = Meshes.Ngon(pts...)
    Float64(ustrip(Meshes.area(poly)))
end

"""Polygon area from a vector of (x,y) tuples via Meshes.jl `PolyArea`."""
function _ngon_area(verts::AbstractVector)
    pts = [Meshes.Point(v[1], v[2]) for v in verts]
    ring = Meshes.Ring(pts...)
    poly = Meshes.PolyArea(ring)
    Float64(ustrip(Meshes.area(poly)))
end

"""Point-in-convex-polygon test (CCW cross-product, 2D)."""
function _point_in_polygon(verts::NTuple{N}, x::Float64, y::Float64) where {N}
    for i in 1:N
        j = mod1(i + 1, N)
        cross = (verts[j][1] - verts[i][1]) * (y - verts[i][2]) -
                (verts[j][2] - verts[i][2]) * (x - verts[i][1])
        cross < -1e-14 && return false
    end
    true
end

"""Point-in-simple-polygon test (winding number, works for non-convex)."""
function _point_in_simple_polygon(verts, x::Float64, y::Float64)
    n = length(verts)
    winding = 0
    for i in 1:n
        j = mod1(i + 1, n)
        yi = verts[i][2]; yj = verts[j][2]
        if yi ≤ y
            if yj > y
                cross = (verts[j][1] - verts[i][1]) * (y - yi) -
                        (x - verts[i][1]) * (yj - yi)
                cross > 0 && (winding += 1)
            end
        else
            if yj ≤ y
                cross = (verts[j][1] - verts[i][1]) * (y - yi) -
                        (x - verts[i][1]) * (yj - yi)
                cross < 0 && (winding -= 1)
            end
        end
    end
    winding != 0
end

# =============================================================================
# Mean Value Coordinates (Floater 2003)
# =============================================================================
#
# Generalized barycentric coordinates for ANY simple polygon (convex or not).
# For convex polygons, nearly identical to Wachspress.  For concave polygons,
# they remain smooth and well-defined in the interior.
#
# Ref: Floater (2003), "Mean value coordinates", CAGD 22(1):19–27
# =============================================================================

"""
    mean_value_weights(verts, x, y) -> NTuple{N, Float64}

Mean value barycentric coordinates.  Works for convex AND non-convex polygons.
"""
function mean_value_weights(verts::NTuple{N}, x::Real, y::Real) where {N}
    px, py = Float64(x), Float64(y)

    # Displacement vectors and distances
    r  = ntuple(i -> (verts[i][1] - px, verts[i][2] - py), N)
    d  = ntuple(i -> sqrt(r[i][1]^2 + r[i][2]^2), N)

    # Vertex snap
    for i in 1:N
        d[i] < 1e-12 && return ntuple(j -> j == i ? 1.0 : 0.0, N)
    end

    # Edge snap
    for i in 1:N
        ip1 = mod1(i + 1, N)
        cross = r[i][1] * r[ip1][2] - r[i][2] * r[ip1][1]
        dot_rr = r[i][1] * r[ip1][1] + r[i][2] * r[ip1][2]
        if abs(cross) < 1e-12 * d[i] * d[ip1] && dot_rr < 0
            t = d[i] / (d[i] + d[ip1])
            return ntuple(j -> j == i ? 1.0 - t : (j == ip1 ? t : 0.0), N)
        end
    end

    # tan(α_i / 2) for each consecutive edge angle — use atan2 for robustness
    # (the sin/(1+cos) formula blows up when cos_α ≈ -1)
    tan_half = ntuple(N) do i
        ip1 = mod1(i + 1, N)
        dot_val   = r[i][1] * r[ip1][1] + r[i][2] * r[ip1][2]
        cross_val = r[i][1] * r[ip1][2] - r[i][2] * r[ip1][1]
        α = atan(cross_val, dot_val)   # full-range angle via atan2
        tan(α / 2)
    end

    w = ntuple(N) do i
        im1 = mod1(i - 1, N)
        (tan_half[im1] + tan_half[i]) / d[i]
    end

    wsum = sum(w)
    ntuple(i -> w[i] / wsum, N)
end

"""Vector overload: convert to NTuple and delegate to `mean_value_weights(::NTuple, ...)`."""
function mean_value_weights(verts::AbstractVector, x::Real, y::Real)
    tup = ntuple(i -> (Float64(verts[i][1]), Float64(verts[i][2])), length(verts))
    mean_value_weights(tup, x, y)
end

"""Interpolate parametric coords using mean value coordinates (any polygon)."""
function mean_value_parametric(verts, params, x::Real, y::Real)
    λ = mean_value_weights(verts, x, y)
    n = length(verts)
    ξ = sum(λ[i] * params[i][1] for i in 1:n)
    η = sum(λ[i] * params[i][2] for i in 1:n)
    (ξ, η)
end

# =============================================================================
# Wachspress Weights (convex polygons only)
# =============================================================================

"""Signed area of triangle (a, b, c). Positive for CCW."""
@inline function _wach_tri_area(a, b, c)
    0.5 * ((b[1] - a[1]) * (c[2] - a[2]) -
           (c[1] - a[1]) * (b[2] - a[2]))
end

"""
    wachspress_weights(verts::NTuple{N}, x, y) -> NTuple{N, Float64}

Normalized Wachspress barycentric coordinates for point (x, y) inside a
convex polygon.  Handles vertex and edge degeneracies gracefully.

For a quadrilateral, these are identical to the bilinear shape functions.
"""
function wachspress_weights(verts::NTuple{N}, x::Real, y::Real) where {N}
    px, py = Float64(x), Float64(y)

    # --- vertex proximity ---
    for i in 1:N
        dx = px - verts[i][1]
        dy = py - verts[i][2]
        if dx * dx + dy * dy < 1e-24
            return ntuple(j -> j == i ? 1.0 : 0.0, N)
        end
    end

    # --- sub-triangle areas ---
    A = ntuple(N) do i
        ip1 = mod1(i + 1, N)
        _wach_tri_area((px, py), verts[i], verts[ip1])
    end

    # --- edge proximity (Aᵢ ≈ 0) ---
    for i in 1:N
        if abs(A[i]) < 1e-14
            ip1 = mod1(i + 1, N)
            dx = verts[ip1][1] - verts[i][1]
            dy = verts[ip1][2] - verts[i][2]
            len2 = dx * dx + dy * dy
            t = clamp(((px - verts[i][1]) * dx + (py - verts[i][2]) * dy) / len2,
                      0.0, 1.0)
            return ntuple(j -> j == i ? 1.0 - t : (j == ip1 ? t : 0.0), N)
        end
    end

    # --- standard formula: wᵢ = Cᵢ / (Aᵢ₋₁ · Aᵢ) ---
    w = ntuple(N) do i
        im1 = mod1(i - 1, N)
        ip1 = mod1(i + 1, N)
        Ci = _wach_tri_area(verts[im1], verts[i], verts[ip1])
        Ci / (A[im1] * A[i])
    end

    wsum = sum(w)
    ntuple(i -> w[i] / wsum, N)
end

# =============================================================================
# Parametric ↔ Physical Mapping
# =============================================================================

"""
    parametric_coords(panel::WachspressPanel, x, y) -> (ξ, η)

Direct (non-iterative) map from physical to parametric space.
"""
function parametric_coords(panel::WachspressPanel{N}, x::Real, y::Real) where {N}
    λ = wachspress_weights(panel.vertices, x, y)
    ξ = sum(λ[i] * panel.params[i][1] for i in 1:N)
    η = sum(λ[i] * panel.params[i][2] for i in 1:N)
    (ξ, η)
end

# --- physical_coords: specialized for quads (bilinear, exact, no Newton) ---

"""
    physical_coords(panel::WachspressPanel{4}, ξ, η) -> (x, y)

Bilinear forward map — identical to `IsoParametricPanel`, no iteration needed.
"""
function physical_coords(panel::WachspressPanel{4}, ξ::Real, η::Real; kwargs...)
    ξf, ηf = Float64(ξ), Float64(η)
    N1 = (1 - ξf) * (1 - ηf)
    N2 = ξf       * (1 - ηf)
    N3 = ξf       * ηf
    N4 = (1 - ξf) * ηf
    v = panel.vertices
    x = N1*v[1][1] + N2*v[2][1] + N3*v[3][1] + N4*v[4][1]
    y = N1*v[1][2] + N2*v[2][2] + N3*v[3][2] + N4*v[4][2]
    (x, y)
end

# --- physical_coords: general N-gon (Newton with robust initial guess) ---

"""
    physical_coords(panel::WachspressPanel{N}, ξ, η) -> (x, y)  where N ≠ 4

Newton iteration on the Wachspress inverse.  The valid parametric domain is
the convex hull of the vertex parametric coords, NOT [0,1]².
"""
function physical_coords(panel::WachspressPanel{N}, ξ::Real, η::Real;
                         tol::Float64 = 1e-10, maxiter::Int = 50) where {N}
    ξt, ηt = Float64(ξ), Float64(η)
    v = panel.vertices
    p = panel.params

    # --- exact at vertices ---
    for i in 1:N
        if abs(p[i][1] - ξt) + abs(p[i][2] - ηt) < 1e-12
            return v[i]
        end
    end

    # --- exact on parametric edges (polygon boundary) ---
    for i in 1:N
        ip1 = mod1(i + 1, N)
        dx = p[ip1][1] - p[i][1]; dy = p[ip1][2] - p[i][2]
        len2 = dx^2 + dy^2
        len2 < 1e-20 && continue
        t = ((ξt - p[i][1]) * dx + (ηt - p[i][2]) * dy) / len2
        if 0.0 ≤ t ≤ 1.0
            proj_ξ = p[i][1] + t * dx
            proj_η = p[i][2] + t * dy
            if (proj_ξ - ξt)^2 + (proj_η - ηt)^2 < 1e-16
                return (v[i][1] + t * (v[ip1][1] - v[i][1]),
                        v[i][2] + t * (v[ip1][2] - v[i][2]))
            end
        end
    end

    # --- check target is inside the parametric polygon ---
    if !_point_in_polygon(p, ξt, ηt)
        error("physical_coords: target (ξ=$ξ, η=$η) is outside the parametric " *
              "domain (convex hull of vertex params) for this $(N)-gon panel")
    end

    # --- initial guess: inverse-distance weighting from vertices ---
    wsum = 0.0; x = 0.0; y = 0.0
    for i in 1:N
        d2 = (p[i][1] - ξt)^2 + (p[i][2] - ηt)^2 + 1e-10
        w = 1.0 / d2
        x += w * v[i][1];  y += w * v[i][2]
        wsum += w
    end
    x /= wsum;  y /= wsum

    # --- damped Newton iteration ---
    for iter in 1:maxiter
        ξc, ηc = parametric_coords(panel, x, y)
        rξ = ξc - ξt;  rη = ηc - ηt
        if rξ^2 + rη^2 < tol^2
            return (x, y)
        end

        J = _wach_jacobian(v, p, x, y)
        det_J = J[1] * J[4] - J[2] * J[3]
        abs(det_J) < 1e-20 && break

        Δx = ( J[4] * rξ - J[2] * rη) / det_J
        Δy = (-J[3] * rξ + J[1] * rη) / det_J

        α = iter ≤ 5 ? 0.7 : 1.0   # damping for early iterations
        x -= α * Δx;  y -= α * Δy
    end
    error("physical_coords: Newton did not converge for (ξ=$ξ, η=$η) on WachspressPanel")
end

# =============================================================================
# Jacobian: ∂(ξ,η)/∂(x,y)
# =============================================================================

"""
    _wach_jacobian(verts, params, x, y) -> (dξdx, dξdy, dηdx, dηdy)

Analytical Jacobian as flat 4-tuple (allocation-free).
"""
function _wach_jacobian(verts::NTuple{N}, params::NTuple{N},
                        x::Real, y::Real) where {N}
    px, py = Float64(x), Float64(y)

    A     = Vector{Float64}(undef, N)
    dA_dx = Vector{Float64}(undef, N)
    dA_dy = Vector{Float64}(undef, N)

    for i in 1:N
        ip1 = mod1(i + 1, N)
        A[i]     = _wach_tri_area((px, py), verts[i], verts[ip1])
        dA_dx[i] = 0.5 * (verts[i][2] - verts[ip1][2])
        dA_dy[i] = 0.5 * (verts[ip1][1] - verts[i][1])
    end

    w       = Vector{Float64}(undef, N)
    dlnw_dx = Vector{Float64}(undef, N)
    dlnw_dy = Vector{Float64}(undef, N)

    for i in 1:N
        im1 = mod1(i - 1, N)
        ip1 = mod1(i + 1, N)
        Ci = _wach_tri_area(verts[im1], verts[i], verts[ip1])
        w[i] = Ci / (A[im1] * A[i])
        dlnw_dx[i] = -(dA_dx[im1] / A[im1] + dA_dx[i] / A[i])
        dlnw_dy[i] = -(dA_dy[im1] / A[im1] + dA_dy[i] / A[i])
    end

    W = sum(w)
    λ = w ./ W
    avg_dx = sum(λ[i] * dlnw_dx[i] for i in 1:N)
    avg_dy = sum(λ[i] * dlnw_dy[i] for i in 1:N)

    dξdx = sum(λ[i] * (dlnw_dx[i] - avg_dx) * params[i][1] for i in 1:N)
    dξdy = sum(λ[i] * (dlnw_dy[i] - avg_dy) * params[i][1] for i in 1:N)
    dηdx = sum(λ[i] * (dlnw_dx[i] - avg_dx) * params[i][2] for i in 1:N)
    dηdy = sum(λ[i] * (dlnw_dy[i] - avg_dy) * params[i][2] for i in 1:N)

    (dξdx, dξdy, dηdx, dηdy)
end

"""
    jacobian(panel::WachspressPanel{N}, x, y) -> Matrix{Float64}

Jacobian matrix ∂(ξ,η)/∂(x,y) at physical point (x, y), returned as a 2×2 `Matrix`.
"""
function jacobian(panel::WachspressPanel{N}, x::Real, y::Real) where {N}
    J = _wach_jacobian(panel.vertices, panel.params, x, y)
    [J[1] J[2]; J[3] J[4]]
end

"""Forward Jacobian det ∂(x,y)/∂(ξ,η) at parametric point (ξ,η)."""
function jacobian_det_parametric(panel::WachspressPanel{4}, ξ::Real, η::Real)
    # For quads, use the isoparametric Jacobian directly (faster, no inverse)
    dNξ, dNη = dN_dξη(Float64(ξ), Float64(η))
    c = panel.vertices
    dx_dξ = dNξ[1]*c[1][1] + dNξ[2]*c[2][1] + dNξ[3]*c[3][1] + dNξ[4]*c[4][1]
    dx_dη = dNη[1]*c[1][1] + dNη[2]*c[2][1] + dNη[3]*c[3][1] + dNη[4]*c[4][1]
    dy_dξ = dNξ[1]*c[1][2] + dNξ[2]*c[2][2] + dNξ[3]*c[3][2] + dNξ[4]*c[4][2]
    dy_dη = dNη[1]*c[1][2] + dNη[2]*c[2][2] + dNη[3]*c[3][2] + dNη[4]*c[4][2]
    dx_dξ * dy_dη - dx_dη * dy_dξ
end

"""General N-gon: forward Jacobian det via inversion of the parametric-space Jacobian."""
function jacobian_det_parametric(panel::WachspressPanel{N}, ξ::Real, η::Real) where {N}
    xy = physical_coords(panel, ξ, η)
    J_inv = _wach_jacobian(panel.vertices, panel.params, xy[1], xy[2])
    det_inv = J_inv[1] * J_inv[4] - J_inv[2] * J_inv[3]
    1.0 / det_inv
end

# =============================================================================
# Quality Metrics — work in physical space for N-gons
# =============================================================================

"""Panel area from the physical polygon vertices (exact, no quadrature)."""
function panel_area(panel::WachspressPanel{N}; kwargs...) where {N}
    _ngon_area(panel.vertices)
end

"""
Minimum forward Jacobian det, sampled over the parametric domain.
For quads, samples [0,1]²; for N-gons, samples the parametric convex hull.
"""
function min_jacobian_det(panel::WachspressPanel{4}; n::Int = 5)
    jmin = Inf
    for i in 0:n, j in 0:n
        jd = jacobian_det_parametric(panel, i / n, j / n)
        jd < jmin && (jmin = jd)
    end
    jmin
end

"""
    min_jacobian_det(panel::WachspressPanel{N}; n=10) where N

General N-gon: minimum forward Jacobian det sampled on an n×n physical-space
grid, skipping points outside the polygon.
"""
function min_jacobian_det(panel::WachspressPanel{N}; n::Int = 10) where {N}
    # Sample a grid of physical points inside the polygon, compute inverse Jacobian
    v = panel.vertices
    xs = [v[i][1] for i in 1:N]
    ys = [v[i][2] for i in 1:N]
    xmin, xmax = extrema(xs)
    ymin, ymax = extrema(ys)

    jmin = Inf
    for i in 0:n, j in 0:n
        x = xmin + (xmax - xmin) * i / n
        y = ymin + (ymax - ymin) * j / n
        _point_in_polygon(v, x, y) || continue
        J = _wach_jacobian(v, panel.params, x, y)
        det_inv = J[1] * J[4] - J[2] * J[3]
        abs(det_inv) < 1e-20 && continue
        jd = 1.0 / det_inv   # forward Jacobian det
        jd < jmin && (jmin = jd)
    end
    jmin
end

# =============================================================================
# Automatic Parametric Assignment
# =============================================================================

"""
    auto_params(vertices) -> Vector{NTuple{2, Float64}}

Assign parametric (ξ, η) to polygon vertices.

For a quad, uses the standard isoparametric assignment:
  vertex 1 → (0,0), 2 → (1,0), 3 → (1,1), 4 → (0,1).

For N > 4, distributes vertices around the [0,1]² boundary
proportionally to arc length.
"""
function auto_params(verts)
    n = length(verts)
    n < 3 && error("Need at least 3 vertices, got $n")
    n == 4 && return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]

    edges = [sqrt((verts[mod1(i+1, n)][1] - verts[i][1])^2 +
                  (verts[mod1(i+1, n)][2] - verts[i][2])^2) for i in 1:n]
    P = sum(edges)
    cum = zeros(n)
    for i in 2:n
        cum[i] = cum[i-1] + edges[i-1]
    end

    params = Vector{NTuple{2, Float64}}(undef, n)
    for i in 1:n
        t = 4.0 * cum[i] / P
        if t < 1.0;       params[i] = (t, 0.0)
        elseif t < 2.0;   params[i] = (1.0, t - 1.0)
        elseif t < 3.0;   params[i] = (3.0 - t, 1.0)
        else;              params[i] = (0.0, 4.0 - t)
        end
    end
    params
end

# =============================================================================
# Rib Grid Layout
# =============================================================================

"""Parametric bounding box from vertex params."""
function _param_bounds(panel::WachspressPanel{N}) where {N}
    ξs = [panel.params[i][1] for i in 1:N]
    ηs = [panel.params[i][2] for i in 1:N]
    (ξmin=minimum(ξs), ξmax=maximum(ξs), ηmin=minimum(ηs), ηmax=maximum(ηs))
end

"""
    rib_lines_ξ(grid::WachspressGrid{4}; n_pts=20)

Polylines for constant-ξ ribs on a quad Wachspress grid via direct bilinear evaluation.
Returns `nξ + 1` polylines, each with `n_pts` points.
"""
function rib_lines_ξ(grid::WachspressGrid{4}; n_pts::Int = 20)
    panel = grid.panel
    lines = Vector{Vector{NTuple{2, Float64}}}(undef, grid.nξ + 1)
    for i in 0:grid.nξ
        ξ = i / grid.nξ
        pts = [physical_coords(panel, ξ, (k-1)/(n_pts-1)) for k in 1:n_pts]
        lines[i + 1] = pts
    end
    lines
end

"""
    rib_lines_η(grid::WachspressGrid{4}; n_pts=20)

Polylines for constant-η ribs on a quad Wachspress grid via direct bilinear evaluation.
Returns `nη + 1` polylines, each with `n_pts` points.
"""
function rib_lines_η(grid::WachspressGrid{4}; n_pts::Int = 20)
    panel = grid.panel
    lines = Vector{Vector{NTuple{2, Float64}}}(undef, grid.nη + 1)
    for j in 0:grid.nη
        η = j / grid.nη
        pts = [physical_coords(panel, (k-1)/(n_pts-1), η) for k in 1:n_pts]
        lines[j + 1] = pts
    end
    lines
end

# --- N-gon: boundary-tracing isolines ---
#
# Strategy: find where each iso-ξ (or iso-η) line crosses the polygon
# boundary, then march through the interior with Newton steps starting
# from each previous point.  This guarantees ribs reach the edges.

"""
Find the physical (x,y) and secondary parametric value at each point where
the polygon boundary crosses `field_val`, where "field" is either ξ or η.

Returns `Vector{Tuple{NTuple{2,Float64}, Float64}}` — each entry is
`((x, y), secondary_param)`, sorted by the secondary parametric coordinate.
"""
function _boundary_crossings(panel::WachspressPanel{N},
                             field_idx::Int,          # 1 for ξ, 2 for η
                             field_val::Float64) where {N}
    v = panel.vertices
    p = panel.params
    other = field_idx == 1 ? 2 : 1   # secondary param index
    crossings = Tuple{NTuple{2,Float64}, Float64}[]

    for i in 1:N
        ip1 = mod1(i + 1, N)
        f_i   = p[i][field_idx]
        f_ip1 = p[ip1][field_idx]
        denom = f_ip1 - f_i
        abs(denom) < 1e-14 && continue
        t = (field_val - f_i) / denom
        (-1e-10 ≤ t ≤ 1.0 + 1e-10) || continue
        t = clamp(t, 0.0, 1.0)
        x = v[i][1] + t * (v[ip1][1] - v[i][1])
        y = v[i][2] + t * (v[ip1][2] - v[i][2])
        s = p[i][other] + t * (p[ip1][other] - p[i][other])
        push!(crossings, ((x, y), s))
    end

    sort!(crossings, by = c -> c[2])

    # Deduplicate near-coincident crossings (shared vertices)
    isempty(crossings) && return crossings
    unique = [crossings[1]]
    for i in 2:length(crossings)
        prev_xy = unique[end][1]
        curr_xy = crossings[i][1]
        if (curr_xy[1] - prev_xy[1])^2 + (curr_xy[2] - prev_xy[2])^2 > 1e-16
            push!(unique, crossings[i])
        end
    end
    unique
end

"""
Trace an isoline from `start_xy` to `end_xy` with `n_pts` total points,
refining each via Newton so that `parametric_coords(panel, x, y)[field_idx] ≈ target`.
Uses marching: each Newton iterate starts from the previous converged point.
"""
function _trace_isoline(panel::WachspressPanel{N},
                        field_idx::Int,
                        field_val::Float64,
                        start_xy::NTuple{2,Float64}, s_start::Float64,
                        end_xy::NTuple{2,Float64},   s_end::Float64;
                        n_pts::Int = 20) where {N}
    v = panel.vertices
    p = panel.params
    other = field_idx == 1 ? 2 : 1

    pts = NTuple{2,Float64}[start_xy]
    prev_xy = start_xy

    for j in 2:(n_pts - 1)
        frac = (j - 1) / (n_pts - 1)
        s_target = s_start + frac * (s_end - s_start)

        # Initial guess: previous point shifted linearly toward end
        x = prev_xy[1] + (end_xy[1] - start_xy[1]) / (n_pts - 1)
        y = prev_xy[2] + (end_xy[2] - start_xy[2]) / (n_pts - 1)

        # Newton: solve  parametric[field_idx] = field_val
        #                parametric[other]      = s_target
        for _ in 1:20
            pc = parametric_coords(panel, x, y)
            r_field = pc[field_idx] - field_val
            r_other = pc[other]     - s_target
            r_field^2 + r_other^2 < 1e-18 && break

            J4 = _wach_jacobian(v, p, x, y)
            # J4 = (dξ/dx, dξ/dy, dη/dx, dη/dy) — order residuals to match
            if field_idx == 1
                r1, r2 = r_field, r_other
                j11, j12 = J4[1], J4[2]   # dξ/dx, dξ/dy
                j21, j22 = J4[3], J4[4]   # dη/dx, dη/dy
            else
                r1, r2 = r_other, r_field
                j11, j12 = J4[1], J4[2]
                j21, j22 = J4[3], J4[4]
            end
            d = j11 * j22 - j12 * j21
            abs(d) < 1e-20 && break
            dx = ( j22 * r1 - j12 * r2) / d
            dy = (-j21 * r1 + j11 * r2) / d
            x -= dx;  y -= dy
        end

        push!(pts, (x, y))
        prev_xy = (x, y)
    end

    push!(pts, end_xy)
    pts
end

"""
    rib_lines_ξ(grid::WachspressGrid{N}; n_pts=20) where N

Polylines for constant-ξ ribs on a general N-gon Wachspress grid.
Uses boundary-tracing isolines with Newton refinement.
"""
function rib_lines_ξ(grid::WachspressGrid{N}; n_pts::Int = 20) where {N}
    panel = grid.panel
    ξ_vals = [panel.params[i][1] for i in 1:N]
    ξ_min, ξ_max = extrema(ξ_vals)

    lines = Vector{Vector{NTuple{2, Float64}}}(undef, grid.nξ + 1)
    for k in 0:grid.nξ
        ξ_target = ξ_min + (ξ_max - ξ_min) * k / grid.nξ
        cx = _boundary_crossings(panel, 1, ξ_target)
        if length(cx) < 2
            lines[k + 1] = [c[1] for c in cx]
        else
            lines[k + 1] = _trace_isoline(panel, 1, ξ_target,
                cx[1][1], cx[1][2], cx[end][1], cx[end][2]; n_pts)
        end
    end
    lines
end

"""
    rib_lines_η(grid::WachspressGrid{N}; n_pts=20) where N

Polylines for constant-η ribs on a general N-gon Wachspress grid.
Uses boundary-tracing isolines with Newton refinement.
"""
function rib_lines_η(grid::WachspressGrid{N}; n_pts::Int = 20) where {N}
    panel = grid.panel
    η_vals = [panel.params[i][2] for i in 1:N]
    η_min, η_max = extrema(η_vals)

    lines = Vector{Vector{NTuple{2, Float64}}}(undef, grid.nη + 1)
    for k in 0:grid.nη
        η_target = η_min + (η_max - η_min) * k / grid.nη
        cx = _boundary_crossings(panel, 2, η_target)
        if length(cx) < 2
            lines[k + 1] = [c[1] for c in cx]
        else
            lines[k + 1] = _trace_isoline(panel, 2, η_target,
                cx[1][1], cx[1][2], cx[end][1], cx[end][2]; n_pts)
        end
    end
    lines
end

"""
    modules(grid::WachspressGrid{4}) -> Vector{RibModule}

Enumerate all rib modules on a quad Wachspress grid. Identical logic to
`modules(::WaffleRibGrid)` but uses the `WachspressPanel{4}` forward map.
"""
function modules(grid::WachspressGrid{4})
    panel = grid.panel
    nξ, nη = grid.nξ, grid.nη
    result = Vector{RibModule}(undef, nξ * nη)
    idx = 0
    for j in 1:nη, i in 1:nξ
        ξ_lo = (i - 1) / nξ;  ξ_hi = i / nξ
        η_lo = (j - 1) / nη;  η_hi = j / nη
        ξ_c = (ξ_lo + ξ_hi) / 2;  η_c = (η_lo + η_hi) / 2

        c1 = physical_coords(panel, ξ_lo, η_lo)
        c2 = physical_coords(panel, ξ_hi, η_lo)
        c3 = physical_coords(panel, ξ_hi, η_hi)
        c4 = physical_coords(panel, ξ_lo, η_hi)
        xy_c = physical_coords(panel, ξ_c, η_c)
        corners = (c1, c2, c3, c4)
        area = abs(_shoelace4(corners))
        solid = is_in_solid_head(ξ_c, η_c, grid.solid_head)

        idx += 1
        result[idx] = RibModule(i, j, ξ_c, η_c, xy_c, corners, area, solid)
    end
    result
end

"""
    modules(grid::WachspressGrid{N}) -> Vector{RibModule}  where N

Enumerate rib modules on a general N-gon Wachspress grid. Modules whose
parametric centroid falls outside the convex hull of vertex params are skipped.
"""
function modules(grid::WachspressGrid{N}) where {N}
    panel = grid.panel
    nξ, nη = grid.nξ, grid.nη
    b = _param_bounds(panel)
    result = RibModule[]

    for j in 1:nη, i in 1:nξ
        ξ_lo = b.ξmin + (b.ξmax - b.ξmin) * (i - 1) / nξ
        ξ_hi = b.ξmin + (b.ξmax - b.ξmin) * i / nξ
        η_lo = b.ηmin + (b.ηmax - b.ηmin) * (j - 1) / nη
        η_hi = b.ηmin + (b.ηmax - b.ηmin) * j / nη
        ξ_c = (ξ_lo + ξ_hi) / 2;  η_c = (η_lo + η_hi) / 2

        # Skip modules outside the parametric polygon
        _point_in_polygon(panel.params, ξ_c, η_c) || continue

        try
            c1 = physical_coords(panel, ξ_lo, η_lo)
            c2 = physical_coords(panel, ξ_hi, η_lo)
            c3 = physical_coords(panel, ξ_hi, η_hi)
            c4 = physical_coords(panel, ξ_lo, η_hi)
            xy_c = physical_coords(panel, ξ_c, η_c)
            corners = (c1, c2, c3, c4)
            area = abs(_shoelace4(corners))
            solid = is_in_solid_head(ξ_c, η_c, grid.solid_head)
            push!(result, RibModule(i, j, ξ_c, η_c, xy_c, corners, area, solid))
        catch
            # Module corner outside domain — skip
        end
    end
    result
end

"""
    grid_summary(grid::WachspressGrid) -> NamedTuple

Quick summary of Wachspress grid geometry for debugging, analogous to
`grid_summary(::WaffleRibGrid)`.
"""
function grid_summary(grid::WachspressGrid)
    mods = modules(grid)
    isempty(mods) && return (n_modules=0, n_solid=0, n_void=0,
        panel_area=panel_area(grid.panel), module_area_sum=0.0,
        min_module_area=0.0, max_module_area=0.0, area_ratio=0.0,
        min_jac_det=min_jacobian_det(grid.panel))
    n_solid = count(m -> m.is_solid, mods)
    areas = [m.phys_area for m in mods]
    p_area = panel_area(grid.panel)
    (
        n_modules       = length(mods),
        n_solid         = n_solid,
        n_void          = length(mods) - n_solid,
        panel_area      = p_area,
        module_area_sum = sum(areas),
        min_module_area = minimum(areas),
        max_module_area = maximum(areas),
        area_ratio      = sum(areas) / p_area,
        min_jac_det     = min_jacobian_det(grid.panel),
    )
end
