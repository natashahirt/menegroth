# =============================================================================
# Visual Debug: Tributary Area Computation
# Run: julia --project=. scripts/debug_tributaries.jl
# =============================================================================

using Pkg
Pkg.activate(".")

using Revise
using StructuralSizer
using Meshes
using GLMakie
using Unitful: @u_str

# =============================================================================
# Test Shape Definitions
# =============================================================================

"""Create Meshes.Point vertices from (x,y) tuples (in meters)."""
function make_vertices(coords::Vector{NTuple{2,Float64}})
    return [Meshes.Point(c[1] * u"m", c[2] * u"m") for c in coords]
end

"""Check if polygon is convex (for display purposes)."""
function is_convex(verts)
    pts = [(Float64(Meshes.coords(v).x.val), Float64(Meshes.coords(v).y.val)) for v in verts]
    n = length(pts)
    n < 3 && return true
    
    sign = 0
    for i in 1:n
        p1 = pts[mod1(i - 1, n)]
        p2 = pts[i]
        p3 = pts[mod1(i + 1, n)]
        cross = (p2[1] - p1[1]) * (p3[2] - p2[2]) - (p2[2] - p1[2]) * (p3[1] - p2[1])
        if abs(cross) > 1e-9
            s = cross > 0 ? 1 : -1
            sign == 0 && (sign = s)
            sign != s && return false
        end
    end
    return true
end

# --- Regular Shapes ---

rectangle() = make_vertices([
    (0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0)
])

square() = make_vertices([
    (0.0, 0.0), (4.0, 0.0), (4.0, 4.0), (0.0, 4.0)
])

parallelogram() = make_vertices([
    (0.0, 0.0), (5.0, 0.0), (6.5, 3.0), (1.5, 3.0)
])

trapezoid() = make_vertices([
    (0.0, 0.0), (6.0, 0.0), (5.0, 3.0), (1.0, 3.0)
])

trapezoid_wide_top() = make_vertices([
    (1.0, 0.0), (5.0, 0.0), (7.0, 4.0), (-1.0, 4.0)
])

pentagon() = make_vertices([
    (2.0, 0.0), (4.0, 0.0), (5.0, 2.5), (3.0, 4.0), (1.0, 2.5)
])

hexagon() = make_vertices([
    (1.0, 0.0), (3.0, 0.0), (4.0, 1.5), (3.0, 3.0), (1.0, 3.0), (0.0, 1.5)
])

octagon() = make_vertices([
    (1.0, 0.0), (3.0, 0.0), (4.0, 1.0), (4.0, 3.0),
    (3.0, 4.0), (1.0, 4.0), (0.0, 3.0), (0.0, 1.0)
])

# --- Irregular Shapes ---

irregular_quad() = make_vertices([
    (0.0, 0.0), (5.0, 0.5), (4.5, 3.5), (0.5, 2.5)
])

irregular_pentagon() = make_vertices([
    (0.0, 0.0), (4.0, 0.5), (5.5, 2.0), (3.0, 4.5), (0.5, 3.0)
])

irregular_hexagon() = make_vertices([
    (0.0, 1.0), (2.0, 0.0), (5.0, 0.5), (6.0, 2.5), (4.0, 4.0), (1.0, 3.5)
])

l_shape_convex_hull() = make_vertices([
    (0.0, 0.0), (4.0, 0.0), (4.0, 2.0), (2.0, 2.0), (2.0, 4.0), (0.0, 4.0)
])

arrow_shape() = make_vertices([
    (2.0, 0.0), (4.0, 2.0), (3.0, 2.0), (3.0, 4.0), (1.0, 4.0), (1.0, 2.0), (0.0, 2.0)
])

chevron() = make_vertices([
    (0.0, 0.0), (2.0, 2.0), (4.0, 0.0), (4.0, 1.0), (2.0, 3.0), (0.0, 1.0)
])

# Elongated shapes
long_thin_rect() = make_vertices([
    (0.0, 0.0), (10.0, 0.0), (10.0, 2.0), (0.0, 2.0)
])

narrow_triangle() = make_vertices([
    (0.0, 0.0), (8.0, 0.0), (4.0, 2.0)
])

wide_triangle() = make_vertices([
    (0.0, 0.0), (3.0, 0.0), (1.5, 5.0)
])

# =============================================================================
# Visualization
# =============================================================================

"""Plot a single shape with its tributary areas."""
function plot_tributaries!(ax, verts, results; title="", colors=nothing)
    if isnothing(colors)
        colors = [:coral, :skyblue, :lightgreen, :plum, :gold, :salmon, :cyan, :pink,
                  :orchid, :turquoise, :khaki, :thistle]
    end
    
    # Convert Meshes.Point to tuples
    pts = [(Float64(Meshes.coords(v).x.val), Float64(Meshes.coords(v).y.val)) for v in verts]
    n = length(pts)
    
    # Center the shape
    cx = sum(p[1] for p in pts) / n
    cy = sum(p[2] for p in pts) / n
    pts_centered = [(p[1] - cx, p[2] - cy) for p in pts]
    
    # Plot tributary polygons
    for (i, trib) in enumerate(results)
        if !isempty(trib.vertices)
            txs = [v[1] - cx for v in trib.vertices]
            tys = [v[2] - cy for v in trib.vertices]
            push!(txs, txs[1])
            push!(tys, tys[1])
            
            c = colors[mod1(i, length(colors))]
            poly!(ax, Point2f.(txs, tys),
                  color = (c, 0.5),
                  strokecolor = c,
                  strokewidth = 1.5)
        end
    
    end
    
    # Shape outline
    xs = [p[1] for p in pts_centered]
    ys = [p[2] for p in pts_centered]
    push!(xs, xs[1])
    push!(ys, ys[1])
    lines!(ax, xs, ys, color=:black, linewidth=2.5)
    
    # Vertex markers
    scatter!(ax, Point2f.(pts_centered), color=:black, markersize=8)

    for (i, trib) in enumerate(results)
        # Edge midpoint label
        if i <= n
            mx = (pts_centered[i][1] + pts_centered[mod1(i+1, n)][1]) / 2
            my = (pts_centered[i][2] + pts_centered[mod1(i+1, n)][2]) / 2
            label = "$(round(trib.fraction*100, digits=0))%"
            text!(ax, mx, my, text=label, fontsize=10, 
                  align=(:center, :center), color=:black, font=:bold)
        end
    end
        
    ax.title = title
end

"""Create the full debug visualization."""
function visualize_tributary_debug()
    # Define all test shapes: (name, vertices, weights)
    # weights = nothing means isotropic (all weights = 1.0)
    shapes = [
        ("Square", square(), nothing),
        ("Rectangle", rectangle(), nothing),
        ("Rectangle (w=[1,2,1,2])", rectangle(), [1.0, 2.0, 1.0, 2.0]),
        ("Long Rectangle", long_thin_rect(), nothing),
        ("Parallelogram", parallelogram(), nothing),
        ("Parallelogram (w=[2,1,2,1])", parallelogram(), [1.0, 1.0, 2.0, 1.0]),
        ("Trapezoid", trapezoid(), nothing),
        ("Trapezoid (wide top)", trapezoid_wide_top(), nothing),
        ("Triangle (narrow)", narrow_triangle(), nothing),
        ("Triangle (wide)", wide_triangle(), nothing),
        ("Pentagon", pentagon(), nothing),
        ("Hexagon", hexagon(), nothing),
        ("Octagon", octagon(), nothing),
        ("Irregular Quad", irregular_quad(), nothing),
        ("Irregular Pentagon", irregular_pentagon(), nothing),
        ("Irregular Hexagon", irregular_hexagon(), nothing),
        ("L-Shape Hull", l_shape_convex_hull(), nothing),
        ("Arrow", arrow_shape(), nothing),
        ("Chevron", chevron(), nothing),
    ]
    
    n_shapes = length(shapes)
    n_cols = 4
    n_rows = ceil(Int, n_shapes / n_cols)
    
    fig = Figure(size = (400 * n_cols, 380 * n_rows), fontsize=12)
    
    for (i, (name, verts, weights)) in enumerate(shapes)
        row = div(i - 1, n_cols) + 1
        col = mod(i - 1, n_cols) + 1
        
        ax = Axis(fig[row, col],
            aspect = DataAspect(),
            xlabel = "x [m]",
            ylabel = "y [m]"
        )
        
        # Compute tributaries (with optional weights)
        results = get_tributary_polygons_isotropic_dcel(verts; weights=weights)
        
        # Check convexity and if fractions sum to 1
        convex = is_convex(verts)
        total_frac = sum(r.fraction for r in results)
        
        if abs(total_frac - 1.0) < 0.01
            check = "✓"
        else
            check = "✗ ($(round(total_frac, digits=2)))"
        end
        
        title = "$(name) $(check)"
        plot_tributaries!(ax, verts, results; title=title)
    end
    
    # Super title
    Label(fig[0, :], "Tributary Area Debug — Straight Skeleton Algorithm",
          fontsize=20, font=:bold)
    
    return fig
end

"""Run validation checks on all shapes."""
function validate_shapes()
    shapes = [
        ("Square", square()),
        ("Rectangle", rectangle()),
        ("Long Rectangle", long_thin_rect()),
        ("Parallelogram", parallelogram()),
        ("Trapezoid", trapezoid()),
        ("Trapezoid (wide top)", trapezoid_wide_top()),
        ("Triangle (narrow)", narrow_triangle()),
        ("Triangle (wide)", wide_triangle()),
        ("Pentagon", pentagon()),
        ("Hexagon", hexagon()),
        ("Octagon", octagon()),
        ("Irregular Quad", irregular_quad()),
        ("Irregular Pentagon", irregular_pentagon()),
        ("Irregular Hexagon", irregular_hexagon()),
        ("L-Shape Hull", l_shape_convex_hull()),
        ("Arrow", arrow_shape()),
        ("Chevron", chevron()),
    ]
    
    println("=" ^ 60)
    println("Tributary Area Validation")
    println("=" ^ 60)
    
    for (name, verts) in shapes
        results = get_tributary_polygons_isotropic_dcel(verts)
        convex = is_convex(verts)
        total_frac = sum(r.fraction for r in results)
        total_area = sum(r.area for r in results)
        n_edges = length(verts)
        
        if abs(total_frac - 1.0) < 0.01
            status = "✓ PASS"
        else
            status = "✗ FAIL"
        end
        
        convex_str = convex ? "convex" : "NON-CONVEX"
        println("\n$(name) ($(n_edges) edges, $(convex_str))")
        println("  Total fraction: $(round(total_frac * 100, digits=1))% — $(status)")
        println("  Total area: $(round(total_area, digits=2)) m²")
        println("  Per edge:")
        for r in results
            println("    Edge $(r.edge_idx): $(round(r.fraction*100, digits=1))% ($(round(r.area, digits=2)) m²)")
        end
    end
    
    println("\n" * "=" ^ 60)
end

# =============================================================================
# Main
# =============================================================================

println("Running tributary area validation...")
validate_shapes()

# Debug: print octagon polygon vertices (DCEL algorithm)
println("\n" * "=" ^ 60)
println("Octagon Tributary Polygons — DCEL Algorithm")
println("=" ^ 60)
oct_results_dcel = get_tributary_polygons_isotropic_dcel(octagon())
for r in oct_results_dcel
    println("\nEdge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m²")
    for (j, v) in enumerate(r.vertices)
        println("  [$j] ($(round(v[1], digits=4)), $(round(v[2], digits=4)))")
    end
end
println("\nTotal fraction: $(round(sum(r.fraction for r in oct_results_dcel) * 100, digits=1))%")

# Debug: test weighted edges on a rectangle
println("\n" * "=" ^ 60)
println("Weighted Rectangle Test")
println("=" ^ 60)
rect = rectangle()
println("\nIsotropic (all weights = 1.0):")
rect_iso = get_tributary_polygons_isotropic_dcel(rect)
for r in rect_iso
    println("  Edge $(r.edge_idx): area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
end

println("\nWeighted [1.0, 2.0, 1.0, 2.0] (short edges move 2x faster): (Parallelogram)")
par = parallelogram()
println("Parallelogram vertices: $([(Float64(Meshes.coords(v).x.val), Float64(Meshes.coords(v).y.val)) for v in par])")
par_weighted = get_tributary_polygons_isotropic_dcel(par; weights=[1.0, 1.0, 1.0, 2.0])
println("\nResults:")
for r in par_weighted
    println("  Edge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
    if !isempty(r.vertices) && length(r.vertices) <= 6
        println("    Vertices: $([(round(v[1], digits=3), round(v[2], digits=3)) for v in r.vertices])")
    end
end
println("\nExpected: edges 2,4 (short, weight=2) should have SMALLER areas")

println("\nGenerating full debug visualization...")
fig = visualize_tributary_debug()
display(fig)