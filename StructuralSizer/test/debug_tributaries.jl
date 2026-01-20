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

# --- Adversarial / Edge Case Shapes ---

"""Very thin rectangle (tests numerical stability)."""
very_thin_rect() = make_vertices([
    (0.0, 0.0), (10.0, 0.0), (10.0, 0.1), (0.0, 0.1)
])

"""Rectangle with one very short edge."""
rect_one_short_edge() = make_vertices([
    (0.0, 0.0), (10.0, 0.0), (10.0, 0.01), (0.0, 4.0)
])

"""Shape with very acute angle."""
acute_angle_shape() = make_vertices([
    (0.0, 0.0), (5.0, 0.0), (4.99, 0.1), (0.0, 3.0)
])

"""Shape with very obtuse angle (near 180°)."""
obtuse_angle_shape() = make_vertices([
    (0.0, 0.0), (1.0, 0.0), (2.0, 0.01), (3.0, 0.0), (3.0, 3.0), (0.0, 3.0)
])

"""Highly irregular shape with varying edge lengths."""
irregular_varying_edges() = make_vertices([
    (0.0, 0.0), (0.5, 0.0), (8.0, 0.0), (9.0, 1.0), (8.5, 4.0), (0.5, 4.0), (0.0, 3.0)
])

"""Almost-square with slight asymmetry."""
almost_square() = make_vertices([
    (0.0, 0.0), (4.001, 0.0), (4.0, 4.0), (0.0, 4.0)
])

"""Rectangle with extreme aspect ratio."""
extreme_aspect_rect() = make_vertices([
    (0.0, 0.0), (20.0, 0.0), (20.0, 1.0), (0.0, 1.0)
])

"""Shape with collinear vertices (should be simplified)."""
with_collinear() = make_vertices([
    (0.0, 0.0), (2.0, 0.0), (4.0, 0.0), (4.0, 3.0), (2.0, 3.0), (0.0, 3.0)
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
function visualize_tributary_debug(; axis::Union{Nothing, Vector{Float64}} = nothing)
    # Define all test shapes: (name, vertices, weights)
    # weights = nothing means isotropic (all weights = 1.0)
    shapes = [
        # Basic shapes (isotropic)
        ("Square", square(), nothing),
        ("Rectangle", rectangle(), nothing),
        ("Long Rectangle", long_thin_rect(), nothing),
        ("Parallelogram", parallelogram(), nothing),
        ("Trapezoid", trapezoid(), nothing),
        ("Trapezoid (wide top)", trapezoid_wide_top(), nothing),
        ("Triangle (narrow)", narrow_triangle(), nothing),
        ("Triangle (wide)", wide_triangle(), nothing),
        ("Pentagon", pentagon(), nothing),
        ("Hexagon", hexagon(), nothing),
        ("Octagon", octagon(), nothing),
        
        # Weighted cases - symmetric patterns
        ("Rectangle (w=[1,2,1,2])", rectangle(), [1.0, 2.0, 1.0, 2.0]),
        ("Rectangle (w=[2,1,2,1])", rectangle(), [2.0, 1.0, 2.0, 1.0]),
        ("Square (w=[1,3,1,3])", square(), [1.0, 3.0, 1.0, 3.0]),
        ("Parallelogram (w=[1,1,2,1])", parallelogram(), [1.0, 1.0, 2.0, 1.0]),
        ("Octagon (w=[1,1,2,1,2,1,1,1])", octagon(), [1.0, 1.0, 2.0, 1.0, 2.0, 1.0, 1.0, 1.0]),
        
        # Weighted cases - extreme ratios
        ("Rectangle (w=[1,10,1,10])", rectangle(), [1.0, 10.0, 1.0, 10.0]),
        ("Square (w=[0.5,2,0.5,2])", square(), [0.5, 2.0, 0.5, 2.0]),
        ("Rectangle (w=[1,0.1,1,0.1])", rectangle(), [1.0, 0.1, 1.0, 0.1]),
        
        # Weighted cases - asymmetric
        ("Rectangle (w=[1,1,1,5])", rectangle(), [1.0, 1.0, 1.0, 5.0]),
        ("Square (w=[1,1,5,1])", square(), [1.0, 1.0, 5.0, 1.0]),
        ("Parallelogram (w=[1,2,3,4])", parallelogram(), [1.0, 2.0, 3.0, 4.0]),
        
        # Adversarial cases - thin/narrow shapes
        # ("Very Thin Rect", very_thin_rect(), nothing),
        # ("Very Thin (w=[1,10,1,10])", very_thin_rect(), [1.0, 10.0, 1.0, 10.0]),
        # ("Extreme Aspect", extreme_aspect_rect(), nothing),
        ("One Short Edge", rect_one_short_edge(), nothing),
        ("One Short (w=[1,1,1,10])", rect_one_short_edge(), [1.0, 1.0, 1.0, 10.0]),
        
        # Adversarial cases - angles
        ("Acute Angle", acute_angle_shape(), nothing),
        ("Obtuse Angle", obtuse_angle_shape(), nothing),
        ("Almost Square", almost_square(), nothing),
        
        # Adversarial cases - irregular
        ("Irregular Varying", irregular_varying_edges(), nothing),
        ("Irregular Varying (w=[1,1,2,1,2,1,1])", irregular_varying_edges(), [1.0, 1.0, 2.0, 1.0, 2.0, 1.0, 1.0]),
        ("With Collinear", with_collinear(), nothing),
        
        # Complex shapes
        ("Irregular Quad", irregular_quad(), nothing),
        ("Irregular Pentagon", irregular_pentagon(), nothing),
        ("Irregular Hexagon", irregular_hexagon(), nothing),
        ("L-Shape Hull", l_shape_convex_hull(), nothing),
        ("Arrow", arrow_shape(), nothing),
        ("Chevron", chevron(), nothing),
    ]
    
    n_shapes = length(shapes)
    n_cols = 6
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
        results = get_tributary_polygons(verts; weights=weights, axis=axis)
        
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
        results = get_tributary_polygons_isotropic(verts)
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

# Debug: print octagon polygon vertices (One-Way algorithm)
println("\n" * "=" ^ 60)
println("Octagon Tributary Polygons — One-Way Algorithm (axis=[1.0, 0.0])")
println("=" ^ 60)
oct_results = get_tributary_polygons(octagon(); axis=[1.0, 0.0])
for r in oct_results
    println("\nEdge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
    if !isempty(r.vertices)
        for (j, v) in enumerate(r.vertices)
            println("  [$j] ($(round(v[1], digits=4)), $(round(v[2], digits=4)))")
        end
    else
        println("  (empty polygon)")
    end
end
println("\nTotal fraction: $(round(sum(r.fraction for r in oct_results) * 100, digits=1))%")

# Debug: test weighted edges on a rectangle
println("\n" * "=" ^ 60)
println("Weighted Rectangle Test")
println("=" ^ 60)
rect = rectangle()
println("\nOne-Way (axis=[1.0, 0.0], all weights = 1.0):")
rect_iso = get_tributary_polygons(rect; weights=nothing, axis=[1.0, 0.0])
for r in rect_iso
    println("  Edge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
    if !isempty(r.vertices) && length(r.vertices) <= 8
        println("    Vertices: $([(round(v[1], digits=3), round(v[2], digits=3)) for v in r.vertices])")
    end
end

println("\nOne-Way (axis=[1.0, 0.0]) Weighted [1.0, 1.0, 1.0, 2.0] (edge 4 moves 2x faster): (Parallelogram)")
par = parallelogram()
println("Parallelogram vertices: $([(Float64(Meshes.coords(v).x.val), Float64(Meshes.coords(v).y.val)) for v in par])")
par_weighted = get_tributary_polygons(par; weights=[1.0, 1.0, 1.0, 2.0], axis=[1.0, 0.0])
println("\nResults:")
for r in par_weighted
    println("  Edge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
    if !isempty(r.vertices) && length(r.vertices) <= 10
        println("    Vertices: $([(round(v[1], digits=3), round(v[2], digits=3)) for v in r.vertices])")
    end
end
println("\nExpected: edge 4 (weight=2) should have SMALLER area")

# Debug: test irregular varying edges
println("\n" * "=" ^ 60)
println("Irregular Varying Edges Test")
println("=" ^ 60)
irreg_var = irregular_varying_edges()
println("\nIrregular Varying vertices: $([(Float64(Meshes.coords(v).x.val), Float64(Meshes.coords(v).y.val)) for v in irreg_var])")
println("\nOne-Way (axis=[1.0, 0.0]) Isotropic (all weights = 1.0):")
irreg_var_iso = get_tributary_polygons(irreg_var; axis=[1.0, 0.0])
for r in irreg_var_iso
    println("  Edge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
    if !isempty(r.vertices) && length(r.vertices) <= 10
        println("    Vertices: $([(round(v[1], digits=3), round(v[2], digits=3)) for v in r.vertices])")
    end
end
total_frac_iso = sum(r.fraction for r in irreg_var_iso)
println("\nTotal fraction: $(round(total_frac_iso * 100, digits=1))%")

println("\nWeighted [1.0, 1.0, 2.0, 1.0, 2.0, 1.0, 1.0] (edges 3,5 move 2x faster):")
irreg_var_weighted = get_tributary_polygons(irreg_var; weights=[1.0, 1.0, 2.0, 1.0, 2.0, 1.0, 1.0])
println("\nResults:")
for r in irreg_var_weighted
    println("  Edge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
    if !isempty(r.vertices) && length(r.vertices) <= 10
        println("    Vertices: $([(round(v[1], digits=3), round(v[2], digits=3)) for v in r.vertices])")
    end
end
total_frac_weighted = sum(r.fraction for r in irreg_var_weighted)
println("\nTotal fraction: $(round(total_frac_weighted * 100, digits=1))%")
println("\nExpected: edges 3,5 (weight=2) should have SMALLER areas")

# Debug: test with collinear vertices
println("\n" * "=" ^ 60)
println("With Collinear Vertices Test")
println("=" ^ 60)
collinear_shape = with_collinear()
println("\nWith Collinear vertices (6 vertices, should simplify to 4): $([(Float64(Meshes.coords(v).x.val), Float64(Meshes.coords(v).y.val)) for v in collinear_shape])")
println("Note: Vertices (0,0), (2,0), (4,0) are collinear on bottom edge")
println("      Vertices (4,3), (2,3), (0,3) are collinear on top edge")
println("      Should simplify to rectangle: (0,0), (4,0), (4,3), (0,3)")
collinear_results = get_tributary_polygons(collinear_shape)
println("\nResults:")
for r in collinear_results
    println("  Edge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
    if !isempty(r.vertices) && length(r.vertices) <= 10
        println("    Vertices: $([(round(v[1], digits=3), round(v[2], digits=3)) for v in r.vertices])")
    end
end
total_frac_collinear = sum(r.fraction for r in collinear_results)
println("\nTotal fraction: $(round(total_frac_collinear * 100, digits=1))%")
println("Expected: Should match a 4x3 rectangle (area=12.0 m²)")

# Debug: test chevron shape
println("\n" * "=" ^ 60)
println("Chevron Test")
println("=" ^ 60)
chev = chevron()
println("\nChevron vertices: $([(Float64(Meshes.coords(v).x.val), Float64(Meshes.coords(v).y.val)) for v in chev])")
println("\nOne-Way (axis=[1.0, 0.0]) Isotropic (all weights = 1.0):")
chev_iso = get_tributary_polygons(chev; axis=[1.0, 0.0])
for r in chev_iso
    println("  Edge $(r.edge_idx): $(length(r.vertices)) vertices, area=$(round(r.area, digits=4)) m² ($(round(r.fraction*100, digits=1))%)")
    if !isempty(r.vertices) && length(r.vertices) <= 10
        println("    Vertices: $([(round(v[1], digits=3), round(v[2], digits=3)) for v in r.vertices])")
    end
end
total_frac_chev = sum(r.fraction for r in chev_iso)
println("\nTotal fraction: $(round(total_frac_chev * 100, digits=1))%")

println("\nGenerating full debug visualization...")
fig = visualize_tributary_debug(axis=[1.,0.])
display(fig)
