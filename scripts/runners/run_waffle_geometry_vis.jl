# =============================================================================
# Runner: Waffle Slab Geometry — Blended Laplacian / Harmonic Field Gallery
# =============================================================================
#
# Unified rib-field generation for arbitrary polygons.  A single blend
# parameter α ∈ [0, 1] interpolates between two boundary-condition regimes:
#
#   α = 0  →  "Harmonic coordinates": BCs = MVC-interpolated auto_params
#             (curved, shape-adapted ribs — equivalent to the bilinear map
#              for quads, generalized to N-gons)
#
#   α = 1  →  "Projection": BCs = projection onto principal axes
#             (straight, symmetric ribs — optimal for regular N-gons)
#
#   0 < α < 1  →  smooth blend of both (best of both worlds)
#
# The interior is always solved via ∇²u = 0, ∇²v = 0 (Laplace equation),
# so the field is guaranteed smooth and boundary-conforming regardless of α.
#
# Usage:
#   julia scripts/runners/run_waffle_geometry_vis.jl
#
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
# Laplacian Field Solver (with blend parameter α)
# =============================================================================

"""
    solve_laplacian_fields(verts; α, n_grid, max_iter, ω, tol)

Solve two decoupled Laplace equations  ∇²u = 0,  ∇²v = 0  on the polygon
interior using finite differences on a regular grid + SOR.

The blend parameter **α ∈ [0, 1]** controls the boundary conditions:

  - `α = 0` — *harmonic coordinates*: BCs from `mean_value_parametric` with
    `auto_params` vertex assignment.  Produces curved, shape-adapted ribs.
  - `α = 1` — *projection*: BCs from projection onto the polygon's principal
    axes.  Produces straight, symmetric ribs.
  - `0 < α < 1` — convex blend of both.

Returns `(xr, yr, u_field, v_field, iters)`.
"""
function solve_laplacian_fields(verts; α=0.5,
                                n_grid=150, max_iter=2000, ω=1.85, tol=1e-4)
    n = length(verts)
    vtup = ntuple(i -> (Float64(verts[i][1]), Float64(verts[i][2])), n)

    # ---- centroid (vertex-based) ----
    cx = sum(v[1] for v in verts) / n
    cy = sum(v[2] for v in verts) / n

    # ---- second-moment tensor of the vertex set ----
    Sxx = sum((v[2] - cy)^2 for v in verts)
    Syy = sum((v[1] - cx)^2 for v in verts)
    Sxy = -sum((v[1] - cx) * (v[2] - cy) for v in verts)

    # ---- principal axes via eigendecomposition of [[Syy, Sxy], [Sxy, Sxx]] ----
    a, b, d = Syy, Sxy, Sxx
    tr   = a + d
    disc = sqrt(max(tr^2 / 4 - (a * d - b * b), 0.0))

    if abs(b) > 1e-12
        λ1  = tr / 2 + disc
        e1  = (λ1 - d, b)
        len = sqrt(e1[1]^2 + e1[2]^2)
        ax1 = (e1[1] / len, e1[2] / len)
    else
        ax1 = a ≥ d ? (1.0, 0.0) : (0.0, 1.0)
    end
    ax2 = (-ax1[2], ax1[1])

    # ---- MVC parametric setup (for α < 1) ----
    use_mvc = α < 1.0 - 1e-10
    if use_mvc
        params = auto_params(collect(verts))
        ptup   = ntuple(i -> (Float64(params[i][1]), Float64(params[i][2])), n)
    end

    # ---- bounding box with padding ----
    xs_v = [v[1] for v in verts]
    ys_v = [v[2] for v in verts]
    xmin, xmax = extrema(xs_v)
    ymin, ymax = extrema(ys_v)
    pad = 0.01 * max(xmax - xmin, ymax - ymin)

    xr = range(xmin - pad, xmax + pad, length=n_grid)
    yr = range(ymin - pad, ymax + pad, length=n_grid)
    hx  = Float64(step(xr));  hy  = Float64(step(yr))
    hx2 = hx^2;               hy2 = hy^2
    denom = 2.0 * (hx2 + hy2)

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
    p1_min, p1_max = extrema(projs1)
    p2_min, p2_max = extrema(projs2)
    p1_range = max(p1_max - p1_min, 1e-10)
    p2_range = max(p2_max - p2_min, 1e-10)

    # ---- initialize fields ----
    #   BC points: blended projection + MVC values (fixed during SOR)
    #   Interior points: projection as initial guess (SOR converges from there)
    u   = fill(NaN, n_grid, n_grid)
    v_f = fill(NaN, n_grid, n_grid)

    for ix in 1:n_grid, iy in 1:n_grid
        inside[ix, iy] || continue
        x = Float64(xr[ix]); y = Float64(yr[iy])

        # Projection value (always computed)
        u_proj = ((x - cx) * ax1[1] + (y - cy) * ax1[2] - p1_min) / p1_range
        v_proj = ((x - cx) * ax2[1] + (y - cy) * ax2[2] - p2_min) / p2_range

        if is_bc[ix, iy] && use_mvc
            # Boundary: blend projection with MVC harmonic coords
            mvc = mean_value_parametric(vtup, ptup, x, y)
            u[ix, iy]   = α * u_proj + (1.0 - α) * mvc[1]
            v_f[ix, iy] = α * v_proj + (1.0 - α) * mvc[2]
        else
            # Interior (or α≈1): projection as initial guess
            u[ix, iy]   = u_proj
            v_f[ix, iy] = v_proj
        end
    end

    # ---- SOR iteration ----
    final_iter = 0
    for iter in 1:max_iter
        max_change = 0.0
        for ix in 2:n_grid-1, iy in 2:n_grid-1
            (inside[ix, iy] && !is_bc[ix, iy]) || continue

            u_avg = (hy2 * (u[ix-1, iy] + u[ix+1, iy]) +
                     hx2 * (u[ix, iy-1] + u[ix, iy+1])) / denom
            v_avg = (hy2 * (v_f[ix-1, iy] + v_f[ix+1, iy]) +
                     hx2 * (v_f[ix, iy-1] + v_f[ix, iy+1])) / denom

            Δu = ω * (u_avg - u[ix, iy])
            Δv = ω * (v_avg - v_f[ix, iy])
            max_change = max(max_change, abs(Δu), abs(Δv))
            u[ix, iy]   += Δu
            v_f[ix, iy] += Δv
        end
        final_iter = iter
        max_change < tol && break
    end

    (xr, yr, Float32.(u), Float32.(v_f), final_iter)
end

# =============================================================================
# Plotting helper
# =============================================================================

"""
Draw rib grid on any simple polygon using blended Laplacian fields.
"""
function plot_laplacian_panel!(ax, verts, nξ, nη;
                               α=0.5, title="", n_grid=150)
    n = length(verts)
    vtup = ntuple(i -> (Float64(verts[i][1]), Float64(verts[i][2])), n)

    xr, yr, u_field, v_field, iters = solve_laplacian_fields(verts; α, n_grid)

    # Checkerboard cell field
    cell_field = fill(NaN32, n_grid, n_grid)
    for ix in 1:n_grid, iy in 1:n_grid
        isnan(u_field[ix, iy]) && continue
        ci = clamp(floor(Int, u_field[ix, iy] * nξ), 0, nξ - 1)
        cj = clamp(floor(Int, v_field[ix, iy] * nη), 0, nη - 1)
        cell_field[ix, iy] = Float32((ci + cj) % 2)
    end

    # Filled checkerboard
    heatmap!(ax, xr, yr, cell_field;
             colormap=cgrad([:steelblue, :cornflowerblue], 2, categorical=true),
             nan_color=:transparent,
             interpolate=true)

    # Contour rib lines
    ξ_levels = [k / nξ for k in 0:nξ]
    η_levels = [k / nη for k in 0:nη]

    contour!(ax, xr, yr, u_field; levels=ξ_levels,
             color=:firebrick, linewidth=2.0, labels=false)
    contour!(ax, xr, yr, v_field; levels=η_levels,
             color=:darkred, linewidth=2.0, labels=false)

    # Boundary outline
    bx = [vtup[k][1] for k in [1:n; 1]]
    by = [vtup[k][2] for k in [1:n; 1]]
    lines!(ax, bx, by; color=:black, linewidth=2.5)
    scatter!(ax, [v[1] for v in verts], [v[2] for v in verts];
             color=:red, markersize=6)

    ax.title = title
    ax.aspect = DataAspect()

    iters
end

# =============================================================================
# Shape definitions (from test_tributaries.jl)
# =============================================================================

const SHAPES = [
    # Row 1: basic quads
    ("Square 4×4",
     [(0.0,0.0),(4.0,0.0),(4.0,4.0),(0.0,4.0)]),
    ("Rectangle 6×4",
     [(0.0,0.0),(6.0,0.0),(6.0,4.0),(0.0,4.0)]),
    ("Parallelogram",
     [(0.0,0.0),(5.0,0.0),(6.5,3.0),(1.5,3.0)]),
    ("Trapezoid",
     [(0.0,0.0),(6.0,0.0),(5.0,3.0),(1.0,3.0)]),
    ("Trapezoid\n(wide top)",
     [(1.0,0.0),(5.0,0.0),(7.0,4.0),(-1.0,4.0)]),
    ("Irregular quad",
     [(0.0,0.0),(5.0,0.5),(4.5,3.5),(0.5,2.5)]),

    # Row 2: convex N-gons
    ("Pentagon",
     [(2.0,0.0),(4.0,0.0),(5.0,2.5),(3.0,4.0),(1.0,2.5)]),
    ("Hexagon",
     [(1.0,0.0),(3.0,0.0),(4.0,1.5),(3.0,3.0),(1.0,3.0),(0.0,1.5)]),
    ("Octagon",
     [(1.0,0.0),(3.0,0.0),(4.0,1.0),(4.0,3.0),(3.0,4.0),(1.0,4.0),(0.0,3.0),(0.0,1.0)]),
    ("Irregular pentagon",
     [(0.0,0.0),(4.0,0.5),(5.5,2.0),(3.0,4.5),(0.5,3.0)]),
    ("Irregular hexagon",
     [(0.0,1.0),(2.0,0.0),(5.0,0.5),(6.0,2.5),(4.0,4.0),(1.0,3.5)]),
    ("Triangle (wide)",
     [(0.0,0.0),(3.0,0.0),(1.5,5.0)]),

    # Row 3: adversarial shapes
    ("Narrow triangle",
     [(0.0,0.0),(8.0,0.0),(4.0,2.0)]),
    ("Long thin rect",
     [(0.0,0.0),(10.0,0.0),(10.0,2.0),(0.0,2.0)]),
    ("Almost square",
     [(0.0,0.0),(4.001,0.0),(4.0,4.0),(0.0,4.0)]),
    ("Acute angle",
     [(0.0,0.0),(5.0,0.0),(4.99,0.1),(0.0,3.0)]),
    ("One short edge",
     [(0.0,0.0),(10.0,0.0),(10.0,0.01),(0.0,4.0)]),
    ("Obtuse angle",
     [(0.0,0.0),(1.0,0.0),(2.0,0.01),(3.0,0.0),(3.0,3.0),(0.0,3.0)]),

    # Row 4: NON-CONVEX shapes
    ("L-shape",
     [(0.0,0.0),(4.0,0.0),(4.0,2.0),(2.0,2.0),(2.0,4.0),(0.0,4.0)]),
    ("Arrow",
     [(2.0,0.0),(4.0,2.0),(3.0,2.0),(3.0,4.0),(1.0,4.0),(1.0,2.0),(0.0,2.0)]),
    ("Chevron",
     [(0.0,0.0),(2.0,2.0),(4.0,0.0),(4.0,1.0),(2.0,3.0),(0.0,1.0)]),
    ("With collinear",
     [(0.0,0.0),(2.0,0.0),(4.0,0.0),(4.0,3.0),(2.0,3.0),(0.0,3.0)]),
    ("Irregular varying",
     [(0.0,0.0),(0.5,0.0),(8.0,0.0),(9.0,1.0),(8.5,4.0),(0.5,4.0),(0.0,3.0)]),
    ("Extreme AR 20×1",
     [(0.0,0.0),(20.0,0.0),(20.0,1.0),(0.0,1.0)]),
]

# =============================================================================
# Figure 1: Main gallery at α = 0.5
# =============================================================================

const GALLERY_ALPHA = 0.5

println("=" ^ 60)
println("  Waffle Slab Rib Grids — Blended Laplacian Fields (α=$GALLERY_ALPHA)")
println("=" ^ 60)

n_shapes = length(SHAPES)
ncols = 6
nrows = ceil(Int, n_shapes / ncols)

fig = Figure(size=(360 * ncols, 330 * nrows),
             figure_padding=(10, 10, 40, 10))

for (k, (name, verts)) in enumerate(SHAPES)
    row = (k - 1) ÷ ncols + 1
    col = (k - 1) % ncols + 1
    ax  = Axis(fig[row, col]; xticklabelsize=8, yticklabelsize=8,
               titlesize=11)

    n = length(verts)
    convex = is_convex_polygon(verts)
    tag = convex ? (n == 4 ? "quad" : "convex") : "non-convex"

    iters = plot_laplacian_panel!(ax, verts, 8, 6; α=GALLERY_ALPHA,
                                  title="$name\n[$(n)-gon, $tag]")
    println("  $name: $(n)-gon ($tag) — $iters SOR iters")
end

Label(fig[0, 1:ncols],
      "Waffle Slab Rib Grids — Blended Laplacian Fields  (α = $GALLERY_ALPHA)\n" *
      "α=0 → harmonic coords (curved)  ·  α=1 → projection (straight)",
      fontsize=16, font=:bold)

display(fig)

# =============================================================================
# Figure 2: Blend comparison — 4 shapes × 5 α values
# =============================================================================

const COMPARE_SHAPES = [
    ("Trapezoid",     [(0.0,0.0),(6.0,0.0),(5.0,3.0),(1.0,3.0)]),
    ("Hexagon",       [(1.0,0.0),(3.0,0.0),(4.0,1.5),(3.0,3.0),(1.0,3.0),(0.0,1.5)]),
    ("L-shape",       [(0.0,0.0),(4.0,0.0),(4.0,2.0),(2.0,2.0),(2.0,4.0),(0.0,4.0)]),
    ("Arrow",         [(2.0,0.0),(4.0,2.0),(3.0,2.0),(3.0,4.0),(1.0,4.0),(1.0,2.0),(0.0,2.0)]),
]

const ALPHA_VALS = [0.0, 0.25, 0.5, 0.75, 1.0]

println("\n" * "=" ^ 60)
println("  Blend comparison: 4 shapes × 5 α values")
println("=" ^ 60)

n_compare = length(COMPARE_SHAPES)
n_alphas  = length(ALPHA_VALS)

fig2 = Figure(size=(330 * n_alphas, 310 * n_compare),
              figure_padding=(10, 10, 40, 10))

for (r, (name, verts)) in enumerate(COMPARE_SHAPES)
    for (c, α_val) in enumerate(ALPHA_VALS)
        ax = Axis(fig2[r, c]; xticklabelsize=7, yticklabelsize=7,
                  titlesize=10)

        iters = plot_laplacian_panel!(ax, verts, 8, 6; α=α_val,
                    title=(r == 1 ? "α = $α_val\n$name" : name))
        println("  $name α=$α_val — $iters iters")
    end
end

Label(fig2[0, 1:n_alphas],
      "Blend Comparison:  α = 0 (harmonic, curved)  →  α = 1 (projection, straight)",
      fontsize=15, font=:bold)

display(fig2)

println("\n" * "=" ^ 60)
println("  Done. Two figures displayed.")
println("=" ^ 60)
