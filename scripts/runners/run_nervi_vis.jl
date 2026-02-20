# =============================================================================
# Runner: Nervi-like Isostatic Ribbing — Stress-Guided Anisotropic Laplace
# =============================================================================
#
# Two independent control parameters:
#
#   α ∈ [0, 1] — boundary condition blend (same as waffle geometry vis):
#       α=0 → harmonic coordinates (MVC)  — curved, shape-adapted BCs
#       α=1 → projection onto axes        — straight, symmetric BCs
#
#   β ≥ 0 — stress anisotropy strength:
#       β=0   → isotropic Laplace         — identical to waffle geometry vis
#       β>0   → ribs curve to follow principal moment trajectories
#       β→∞   → ribs closely track stress-field streamlines
#
# At β=0, this EXACTLY reproduces the existing waffle geometry approach.
# As β increases, the Nervi character emerges.
#
# Interior PDE:   ∇ · ((I + β·e⊗e) ∇φ) = 0
# Boundary:       blended MVC + projection (controlled by α)
# Guarantees:     edge-to-edge (Dirichlet), no loops (max principle)
#
# References:
#   - Nervi (1956), "Structures"
#   - Mitropoulou et al. (2024), "Fabrication-aware SDQ meshes", CAD 168
#
# Usage:
#   julia --project=. scripts/runners/run_nervi_vis.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using StructuralSizer
using GLMakie

const SS = StructuralSizer
const _point_in_simple_polygon = SS._point_in_simple_polygon
const is_convex_polygon        = SS.is_convex_polygon
const mean_value_parametric    = SS.mean_value_parametric
const auto_params              = SS.auto_params

# =============================================================================
# Phase 1: Membrane Deflection  (∇²w = -1, w = 0)
# =============================================================================

"""
Solve ∇²w = -1 on polygon interior, w = 0 on boundary.
Returns `(xr, yr, w, inside, is_bc, iters)`.
"""
function solve_poisson(verts; n_grid=200, max_iter=5000, ω=1.85, tol=1e-5)
    n = length(verts)
    vtup = ntuple(i -> (Float64(verts[i][1]), Float64(verts[i][2])), n)

    xs_v = [v[1] for v in verts]; ys_v = [v[2] for v in verts]
    xmin, xmax = extrema(xs_v); ymin, ymax = extrema(ys_v)
    pad = 0.03 * max(xmax - xmin, ymax - ymin)

    xr = range(xmin - pad, xmax + pad, length=n_grid)
    yr = range(ymin - pad, ymax + pad, length=n_grid)
    hx = Float64(step(xr)); hy = Float64(step(yr))
    hx2 = hx^2; hy2 = hy^2
    denom = 2.0 * (hx2 + hy2)

    inside = falses(n_grid, n_grid)
    for ix in 1:n_grid, iy in 1:n_grid
        inside[ix, iy] = _point_in_simple_polygon(
            vtup, Float64(xr[ix]), Float64(yr[iy]))
    end
    is_bc = falses(n_grid, n_grid)
    for ix in 1:n_grid, iy in 1:n_grid
        !inside[ix, iy] && continue
        if ix == 1 || ix == n_grid || iy == 1 || iy == n_grid
            is_bc[ix, iy] = true
        elseif !inside[ix-1, iy] || !inside[ix+1, iy] ||
               !inside[ix, iy-1] || !inside[ix, iy+1]
            is_bc[ix, iy] = true
        end
    end

    w = zeros(Float64, n_grid, n_grid)
    final_iter = 0
    for iter in 1:max_iter
        max_change = 0.0
        for ix in 2:n_grid-1, iy in 2:n_grid-1
            (inside[ix, iy] && !is_bc[ix, iy]) || continue
            w_avg = (hy2 * (w[ix-1, iy] + w[ix+1, iy]) +
                     hx2 * (w[ix, iy-1] + w[ix, iy+1]) + hx2 * hy2) / denom
            Δ = ω * (w_avg - w[ix, iy])
            max_change = max(max_change, abs(Δ))
            w[ix, iy] += Δ
        end
        final_iter = iter
        max_change < tol && break
    end

    (xr, yr, w, inside, is_bc, final_iter)
end

# =============================================================================
# Utilities
# =============================================================================

"""Iterative 3×3 box-blur (Jacobi-style)."""
function smooth_field!(f, inside; passes=20)
    ng = size(f, 1)
    buf = similar(f)
    for _ in 1:passes
        copyto!(buf, f)
        for ix in 2:ng-1, iy in 2:ng-1
            inside[ix, iy] || continue
            isnan(buf[ix, iy]) && continue
            cnt = 0; tot = 0.0
            for dx in -1:1, dy in -1:1
                nx, ny = ix + dx, iy + dy
                (1 ≤ nx ≤ ng && 1 ≤ ny ≤ ng && !isnan(buf[nx, ny])) || continue
                cnt += 1; tot += buf[nx, ny]
            end
            cnt > 0 && (f[ix, iy] = tot / cnt)
        end
    end
    f
end

"""Histogram-equalize for uniform strip widths."""
function equalize_potential!(φ, inside)
    ng = size(φ, 1)
    vals = Float32[]; ixs = Int[]; iys = Int[]
    for ix in 1:ng, iy in 1:ng
        (inside[ix, iy] && !isnan(φ[ix, iy])) || continue
        push!(vals, φ[ix, iy]); push!(ixs, ix); push!(iys, iy)
    end
    n = length(vals)
    n < 2 && return φ
    perm = sortperm(vals)
    for (rank, p) in enumerate(perm)
        φ[ixs[p], iys[p]] = Float32((rank - 1) / (n - 1))
    end
    φ
end

# =============================================================================
# Phase 2a: Curvature Tensor  (smoothed)
# =============================================================================

"""Compute smoothed κ_xx, κ_yy, κ_xy and principal direction θ."""
function compute_curvature_field(w, xr, yr, inside; smooth_passes=40)
    ng = length(xr)
    hx = Float64(step(xr)); hy = Float64(step(yr))

    κxx = fill(NaN, ng, ng)
    κyy = fill(NaN, ng, ng)
    κxy = fill(NaN, ng, ng)
    θ   = fill(NaN, ng, ng)

    for ix in 2:ng-1, iy in 2:ng-1
        (inside[ix-1, iy] && inside[ix+1, iy] &&
         inside[ix, iy-1] && inside[ix, iy+1] && inside[ix, iy]) || continue

        κxx[ix, iy] = (w[ix+1, iy] - 2w[ix, iy] + w[ix-1, iy]) / hx^2
        κyy[ix, iy] = (w[ix, iy+1] - 2w[ix, iy] + w[ix, iy-1]) / hy^2

        if inside[ix-1, iy-1] && inside[ix+1, iy-1] &&
           inside[ix-1, iy+1] && inside[ix+1, iy+1]
            κxy[ix, iy] = (w[ix+1, iy+1] - w[ix-1, iy+1] -
                           w[ix+1, iy-1] + w[ix-1, iy-1]) / (4hx * hy)
        else
            κxy[ix, iy] = 0.0
        end
    end

    if smooth_passes > 0
        smooth_field!(κxx, inside; passes=smooth_passes)
        smooth_field!(κyy, inside; passes=smooth_passes)
        smooth_field!(κxy, inside; passes=smooth_passes)
    end

    for ix in 1:ng, iy in 1:ng
        (isnan(κxx[ix, iy]) || isnan(κyy[ix, iy]) || isnan(κxy[ix, iy])) && continue
        θ[ix, iy] = 0.5 * atan(2κxy[ix, iy], κxx[ix, iy] - κyy[ix, iy])
    end

    (κxx, κyy, κxy, θ)
end

# =============================================================================
# Phase 2b: Globally Orient Direction Field  (BFS π-coherence)
# =============================================================================

"""BFS flood-fill to resolve the π-ambiguity in the principal direction field."""
function oriented_directions(θ, inside)
    ng = size(θ, 1)

    e1x = fill(NaN, ng, ng); e1y = fill(NaN, ng, ng)
    e2x = fill(NaN, ng, ng); e2y = fill(NaN, ng, ng)

    for ix in 1:ng, iy in 1:ng
        isnan(θ[ix, iy]) && continue
        e1x[ix, iy] =  cos(θ[ix, iy]); e1y[ix, iy] =  sin(θ[ix, iy])
        e2x[ix, iy] = -sin(θ[ix, iy]); e2y[ix, iy] =  cos(θ[ix, iy])
    end

    visited = falses(ng, ng)
    cx, cy, cnt = 0, 0, 0
    for ix in 1:ng, iy in 1:ng
        isnan(e1x[ix, iy]) && continue
        cx += ix; cy += iy; cnt += 1
    end
    cnt == 0 && return (e1x, e1y, e2x, e2y)
    cx = round(Int, cx / cnt); cy = round(Int, cy / cnt)

    if isnan(e1x[cx, cy])
        best_d2 = typemax(Int)
        for ix in 1:ng, iy in 1:ng
            isnan(e1x[ix, iy]) && continue
            d2 = (ix - cx)^2 + (iy - cy)^2
            if d2 < best_d2; best_d2 = d2; cx = ix; cy = iy; end
        end
    end

    queue = Tuple{Int,Int}[(cx, cy)]
    visited[cx, cy] = true

    while !isempty(queue)
        ix, iy = popfirst!(queue)
        for (dx, dy) in ((1,0),(-1,0),(0,1),(0,-1))
            nx, ny = ix + dx, iy + dy
            (1 ≤ nx ≤ ng && 1 ≤ ny ≤ ng) || continue
            visited[nx, ny] && continue
            isnan(e1x[nx, ny]) && continue

            dot = e1x[ix, iy] * e1x[nx, ny] + e1y[ix, iy] * e1y[nx, ny]
            if dot < 0
                e1x[nx, ny] = -e1x[nx, ny]; e1y[nx, ny] = -e1y[nx, ny]
                e2x[nx, ny] = -e2x[nx, ny]; e2y[nx, ny] = -e2y[nx, ny]
            end

            visited[nx, ny] = true
            push!(queue, (nx, ny))
        end
    end

    (e1x, e1y, e2x, e2y)
end

# =============================================================================
# Phase 3: Stress-Guided Anisotropic Laplace
# =============================================================================

"""
    solve_nervi_fields(verts, e1x, e1y, e2x, e2y;
                       α_bc=0.5, β=100.0, n_grid=200, ...)

Solve two anisotropic Laplace equations for the u (family 1) and v (family 2)
rib fields.

**Boundary conditions** (controlled by `α_bc`, same as waffle geometry vis):
  α_bc=0 → MVC harmonic coordinates (curved)
  α_bc=1 → projection onto axes (straight)
  0<α_bc<1 → smooth blend

**Interior PDE** (controlled by `β`, the Nervi parameter):
  ∇ · ((I + β·e₁⊗e₁) ∇u) = 0    (contours of u follow e₁)
  ∇ · ((I + β·e₂⊗e₂) ∇v) = 0    (contours of v follow e₂)

At β=0: pure isotropic Laplace (identical to waffle vis).
At β>0: ribs curve to follow principal moment trajectories.
"""
function solve_nervi_fields(verts, e1x, e1y, e2x, e2y;
                            α_bc=0.5, β=100.0, n_grid=200,
                            max_iter=12000, tol=1e-5)
    n = length(verts)
    vtup = ntuple(i -> (Float64(verts[i][1]), Float64(verts[i][2])), n)

    # ---- centroid + principal axes (same as waffle vis) ----
    cx = sum(v[1] for v in verts) / n
    cy = sum(v[2] for v in verts) / n

    Sxx = sum((v[2] - cy)^2 for v in verts)
    Syy = sum((v[1] - cx)^2 for v in verts)
    Sxy = -sum((v[1] - cx) * (v[2] - cy) for v in verts)

    a, b, d = Syy, Sxy, Sxx
    tr = a + d
    disc = sqrt(max(tr^2 / 4 - (a * d - b * b), 0.0))

    if abs(b) > 1e-12
        λ1 = tr / 2 + disc
        e1_geom = (λ1 - d, b)
        len = sqrt(e1_geom[1]^2 + e1_geom[2]^2)
        ax1 = (e1_geom[1] / len, e1_geom[2] / len)
    else
        ax1 = a ≥ d ? (1.0, 0.0) : (0.0, 1.0)
    end
    ax2 = (-ax1[2], ax1[1])

    # ---- MVC parametric setup ----
    use_mvc = α_bc < 1.0 - 1e-10
    if use_mvc
        params = auto_params(collect(verts))
        ptup = ntuple(i -> (Float64(params[i][1]), Float64(params[i][2])), n)
    end

    # ---- grid ----
    xs_v = [v[1] for v in verts]; ys_v = [v[2] for v in verts]
    xmin, xmax = extrema(xs_v); ymin, ymax = extrema(ys_v)
    pad = 0.03 * max(xmax - xmin, ymax - ymin)

    xr = range(xmin - pad, xmax + pad, length=n_grid)
    yr = range(ymin - pad, ymax + pad, length=n_grid)
    hx = Float64(step(xr)); hy = Float64(step(yr))
    hx2 = hx^2; hy2 = hy^2

    # ---- inside / boundary masks ----
    inside = falses(n_grid, n_grid)
    for ix in 1:n_grid, iy in 1:n_grid
        inside[ix, iy] = _point_in_simple_polygon(
            vtup, Float64(xr[ix]), Float64(yr[iy]))
    end

    is_bc = falses(n_grid, n_grid)
    for ix in 1:n_grid, iy in 1:n_grid
        !inside[ix, iy] && continue
        if ix == 1 || ix == n_grid || iy == 1 || iy == n_grid
            is_bc[ix, iy] = true
        elseif !inside[ix-1, iy] || !inside[ix+1, iy] ||
               !inside[ix, iy-1] || !inside[ix, iy+1]
            is_bc[ix, iy] = true
        end
    end

    # ---- projection normalization ----
    projs1 = [(v[1] - cx) * ax1[1] + (v[2] - cy) * ax1[2] for v in verts]
    projs2 = [(v[1] - cx) * ax2[1] + (v[2] - cy) * ax2[2] for v in verts]
    p1_min, p1_max = extrema(projs1); p1_range = max(p1_max - p1_min, 1e-10)
    p2_min, p2_max = extrema(projs2); p2_range = max(p2_max - p2_min, 1e-10)

    # ---- initialize u, v fields with blended BCs ----
    u   = fill(NaN, n_grid, n_grid)
    v_f = fill(NaN, n_grid, n_grid)

    for ix in 1:n_grid, iy in 1:n_grid
        inside[ix, iy] || continue
        x = Float64(xr[ix]); y = Float64(yr[iy])

        u_proj = ((x - cx) * ax1[1] + (y - cy) * ax1[2] - p1_min) / p1_range
        v_proj = ((x - cx) * ax2[1] + (y - cy) * ax2[2] - p2_min) / p2_range

        if is_bc[ix, iy] && use_mvc
            mvc = mean_value_parametric(vtup, ptup, x, y)
            u[ix, iy]   = α_bc * u_proj + (1.0 - α_bc) * mvc[1]
            v_f[ix, iy] = α_bc * v_proj + (1.0 - α_bc) * mvc[2]
        else
            u[ix, iy]   = u_proj
            v_f[ix, iy] = v_proj
        end
    end

    # ---- adaptive SOR relaxation (lower ω for high anisotropy) ----
    ω = β < 10 ? 1.7 : β < 50 ? 1.5 : β < 200 ? 1.3 : 1.1

    # ---- SOR with anisotropic diffusion tensor ----
    final_iter = 0
    for iter in 1:max_iter
        max_change = 0.0
        for ix in 2:n_grid-1, iy in 2:n_grid-1
            (inside[ix, iy] && !is_bc[ix, iy]) || continue

            # Direction field at this cell (NaN → isotropic fallback)
            ex1 = isnan(e1x[ix, iy]) ? 0.0 : Float64(e1x[ix, iy])
            ey1 = isnan(e1y[ix, iy]) ? 0.0 : Float64(e1y[ix, iy])
            ex2 = isnan(e2x[ix, iy]) ? 0.0 : Float64(e2x[ix, iy])
            ey2 = isnan(e2y[ix, iy]) ? 0.0 : Float64(e2y[ix, iy])

            # ---- u field: D = I + β·e₁⊗e₁ ----
            Du11 = 1.0 + β * ex1 * ex1
            Du22 = 1.0 + β * ey1 * ey1
            Du12 = β * ex1 * ey1

            axu = Du11 / hx2; ayu = Du22 / hy2
            nu = axu * (u[ix-1, iy] + u[ix+1, iy]) +
                 ayu * (u[ix, iy-1] + u[ix, iy+1])

            if inside[ix-1, iy-1] && inside[ix+1, iy-1] &&
               inside[ix-1, iy+1] && inside[ix+1, iy+1]
                axyu = Du12 / (2.0 * hx * hy)
                nu += axyu * (u[ix+1, iy+1] + u[ix-1, iy-1] -
                              u[ix+1, iy-1] - u[ix-1, iy+1])
            end
            du = 2.0 * (axu + ayu)
            Δu = ω * (nu / du - u[ix, iy])
            u[ix, iy] += Δu

            # ---- v field: D = I + β·e₂⊗e₂ ----
            Dv11 = 1.0 + β * ex2 * ex2
            Dv22 = 1.0 + β * ey2 * ey2
            Dv12 = β * ex2 * ey2

            axv = Dv11 / hx2; ayv = Dv22 / hy2
            nv = axv * (v_f[ix-1, iy] + v_f[ix+1, iy]) +
                 ayv * (v_f[ix, iy-1] + v_f[ix, iy+1])

            if inside[ix-1, iy-1] && inside[ix+1, iy-1] &&
               inside[ix-1, iy+1] && inside[ix+1, iy+1]
                axyv = Dv12 / (2.0 * hx * hy)
                nv += axyv * (v_f[ix+1, iy+1] + v_f[ix-1, iy-1] -
                              v_f[ix+1, iy-1] - v_f[ix-1, iy+1])
            end
            dv = 2.0 * (axv + ayv)
            Δv = ω * (nv / dv - v_f[ix, iy])
            v_f[ix, iy] += Δv

            max_change = max(max_change, abs(Δu), abs(Δv))
        end
        final_iter = iter
        max_change < tol && break
    end

    (xr, yr, Float32.(u), Float32.(v_f), inside, final_iter, ω)
end

# =============================================================================
# Full Pipeline
# =============================================================================

"""
    nervi_strip_fields(verts; α_bc=0.5, β=100.0, n_grid=200, verbose=false)

Complete Nervi pipeline: Poisson → curvature → orient → anisotropic Laplace.
Returns `(u, v, xr, yr, w, inside, poisson_iters)`.
"""
function nervi_strip_fields(verts; α_bc=0.5, β=100.0, n_grid=200, verbose=false)
    # Phase 1: membrane deflection
    xr, yr, w, inside, _, p_iters = solve_poisson(verts; n_grid)
    verbose && println("    Phase 1 (Poisson): $p_iters iters")

    # Phase 2: curvature + orientation
    κxx, κyy, κxy, θ = compute_curvature_field(w, xr, yr, inside)
    e1x, e1y, e2x, e2y = oriented_directions(θ, inside)
    if verbose
        n_ori = count(!isnan, e1x)
        println("    Phase 2 (curvature + orient): $n_ori oriented cells")
    end

    # Phase 3: anisotropic Laplace with MVC-blended BCs
    _, _, u, v, _, h_iters, ω_used =
        solve_nervi_fields(verts, e1x, e1y, e2x, e2y;
                           α_bc, β, n_grid)

    verbose && println("    Phase 3 (aniso Laplace): $h_iters iters  (β=$β, ω=$ω_used)")

    # Phase 4: equalize for uniform strip widths + smooth
    equalize_potential!(u, inside)
    equalize_potential!(v, inside)
    smooth_field!(u, inside; passes=15)
    smooth_field!(v, inside; passes=15)
    verbose && println("    Phase 4 (equalize + smooth): done")

    (u, v, xr, yr, w, inside, p_iters)
end

# =============================================================================
# Plotting
# =============================================================================

"""Plot Nervi strips on a single axis."""
function plot_nervi_panel!(ax, verts, nξ, nη; α_bc=0.5, β=100.0,
                           n_grid=200, title="", verbose=false)
    n = length(verts)
    vtup = ntuple(i -> (Float64(verts[i][1]), Float64(verts[i][2])), n)
    ng = n_grid

    u, v, xr, yr, w, inside, iters =
        nervi_strip_fields(verts; α_bc, β, n_grid, verbose)

    # Checkerboard
    cell_field = fill(NaN32, ng, ng)
    for ix in 1:ng, iy in 1:ng
        (isnan(u[ix, iy]) || isnan(v[ix, iy])) && continue
        ci = clamp(floor(Int, u[ix, iy] * nξ), 0, nξ - 1)
        cj = clamp(floor(Int, v[ix, iy] * nη), 0, nη - 1)
        cell_field[ix, iy] = Float32((ci + cj) % 2)
    end

    heatmap!(ax, xr, yr, cell_field;
             colormap=cgrad([:steelblue, :cornflowerblue], 2, categorical=true),
             nan_color=:transparent, interpolate=true)

    ξ_levels = [k / nξ for k in 0:nξ]
    η_levels = [k / nη for k in 0:nη]
    contour!(ax, xr, yr, u; levels=ξ_levels,
             color=:firebrick, linewidth=2.0, labels=false)
    contour!(ax, xr, yr, v; levels=η_levels,
             color=:darkred, linewidth=2.0, labels=false)

    bx = [vtup[k][1] for k in [1:n; 1]]
    by = [vtup[k][2] for k in [1:n; 1]]
    lines!(ax, bx, by; color=:black, linewidth=2.5)
    scatter!(ax, [v_[1] for v_ in verts], [v_[2] for v_ in verts];
             color=:red, markersize=6)

    ax.title = title
    ax.aspect = DataAspect()
    iters
end

# =============================================================================
# Shape Gallery
# =============================================================================

const SHAPES = [
    ("Square 4×4",       [(0.0,0.0),(4.0,0.0),(4.0,4.0),(0.0,4.0)]),
    ("Rectangle 6×4",    [(0.0,0.0),(6.0,0.0),(6.0,4.0),(0.0,4.0)]),
    ("Trapezoid",        [(0.0,0.0),(6.0,0.0),(5.0,3.0),(1.0,3.0)]),
    ("Parallelogram",    [(0.0,0.0),(5.0,0.0),(6.5,3.0),(1.5,3.0)]),
    ("Pentagon",         [(2.0,0.0),(4.0,0.0),(5.0,2.5),(3.0,4.0),(1.0,2.5)]),
    ("Hexagon",          [(1.0,0.0),(3.0,0.0),(4.0,1.5),(3.0,3.0),(1.0,3.0),(0.0,1.5)]),
    ("L-shape",          [(0.0,0.0),(4.0,0.0),(4.0,2.0),(2.0,2.0),(2.0,4.0),(0.0,4.0)]),
    ("Long rectangle",   [(0.0,0.0),(10.0,0.0),(10.0,2.0),(0.0,2.0)]),
]

# =============================================================================
# Single Figure: all shapes × all β values side by side
# =============================================================================

const BETA_VALS = [0.0, 20.0, 100.0, 500.0]

println("=" ^ 60)
println("  Nervi Strips — β Comparison (all shapes)")
println("  β=0 = pure geometry (same as waffle vis)")
println("  β→∞ = stress-guided (Nervi-like curving)")
println("=" ^ 60)

n_shapes = length(SHAPES)
n_betas  = length(BETA_VALS)

fig = Figure(size=(330 * n_betas, 290 * n_shapes),
             figure_padding=(10, 10, 50, 10))

for (r, (name, verts)) in enumerate(SHAPES)
    for (c, β_val) in enumerate(BETA_VALS)
        ax = Axis(fig[r, c]; xticklabelsize=6, yticklabelsize=6, titlesize=9)

        # Column headers on top row only
        β_str = β_val == 0 ? "β=0\n(geometry)" :
                β_val == 500 ? "β=500\n(Nervi)" : "β=$(Int(β_val))"
        t = r == 1 ? "$β_str\n$name" : name

        println("  $name  β=$β_val")
        plot_nervi_panel!(ax, verts, 8, 6; β=β_val,
                          title=t, verbose=true, n_grid=150)
    end
end

Label(fig[0, 1:n_betas],
      "Nervi Strips — Geometry (β=0) → Stress-Guided (β=500)\n" *
      "Left: identical to waffle vis  ·  Right: ribs follow principal moment trajectories",
      fontsize=14, font=:bold)

display(fig)

println("\n" * "=" ^ 60)
println("  Done. Gallery displayed.")
println("=" ^ 60)
