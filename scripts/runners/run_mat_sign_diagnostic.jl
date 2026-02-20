# =============================================================================
# Diagnostic: Mat Foundation Moment Sign Convention
# =============================================================================
#
# Single column on a mat — eliminates superposition ambiguity.
# Prints raw moment values and signs from both Shukla and FEA.
#
# Usage:  julia scripts/runners/run_mat_sign_diagnostic.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))
Pkg.resolve()

using Unitful
using Printf
using StructuralSizer
using StructuralSizer: kip, ksf, to_kip

# Asap access
using Asap: Node, ShellSection, ShellPatch, Shell, Spring, NodeForce,
            Model, process!, solve!, add_springs!, get_nodes,
            bending_moments, shell_centroid

println("="^80)
println("MAT FOUNDATION MOMENT SIGN DIAGNOSTIC")
println("="^80)

# ─────────────────────────────────────────────────────────────────────────────
# Problem: single interior column on a mat
# ─────────────────────────────────────────────────────────────────────────────

demands = [FoundationDemand(1; Pu=500.0kip, Ps=350.0kip)]
positions = [(10.0u"ft", 10.0u"ft")]

soil = Soil(5.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
            ks=25000.0u"kN/m^3")

println("\n  Single column: Pu = 500 kip at (10, 10) ft")
println("  Soil: qa = 5 ksf, ks = 25000 kN/m³")

fc = 4000.0u"psi"
Ec = 57000.0u"psi" * sqrt(4000.0)
μ  = 0.2
h  = 24.0u"inch"

# Plan sizing
plan = StructuralSizer._mat_plan_sizing(positions,
    MatFootingOptions(material=RC_4000_60, min_depth=h);
    demands = demands, soil = soil)
B = plan.B; Lm = plan.Lm
cx = plan.xs_loc[1]; cy = plan.ys_loc[1]

@printf("\n  Mat plan: B = %.2f ft × Lm = %.2f ft\n",
        ustrip(u"ft", B), ustrip(u"ft", Lm))
@printf("  Column in local coords: (%.2f, %.2f) ft\n",
        ustrip(u"ft", cx), ustrip(u"ft", cy))

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: SHUKLA — raw moment field
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "="^80)
println("PART 1 — SHUKLA AFM: Raw Moment Field")
println("="^80)

result = StructuralSizer._shukla_analysis(h, positions, demands, Ec, μ, soil.ks)
M_x_f, M_y_f = result[1], result[2]
δ_f = result[4]

# Sample points (local coordinates)
sample_pts = [
    ("Column center", cx, cy),
    ("Midspan (½ to left edge)", cx / 2, cy),
    ("Midspan (½ to bottom edge)", cx, cy / 2),
    ("Corner (0,0)", 0.0u"ft", 0.0u"ft"),
    ("Mat center", B / 2, Lm / 2),
]

# Shukla returns moments in Force dimension (kip). Convert to N for display.
println("\n  Location                     M_x (N/m)       M_y (N/m)       δ (mm)")
println("  ────────────────────────     ─────────       ─────────       ──────")
for (lbl, x, y) in sample_pts
    mx = M_x_f(x, y)
    my = M_y_f(x, y)
    δv = δ_f(x, y)
    # Shukla moments are Force (kip). Treat as moment/length → N·m/m = N
    mx_N = ustrip(u"N", uconvert(u"N", mx))
    my_N = ustrip(u"N", uconvert(u"N", my))
    δ_mm = ustrip(u"mm", uconvert(u"mm", δv))
    @printf("  %-30s %+12.1f    %+12.1f    %+9.4f\n", lbl, mx_N, my_N, δ_mm)
end

mx_col_N = ustrip(u"N", uconvert(u"N", M_x_f(cx, cy)))
println("\n  SHUKLA SIGN AT COLUMN:")
if mx_col_N < 0
    println("    M_x < 0 at column → NEGATIVE → plate theory: BOTTOM TENSION ✓")
    println("    Current code: |neg| → As_top → WRONG (should be As_bot)")
else
    println("    M_x > 0 at column → POSITIVE → plate theory: TOP TENSION")
    println("    This may indicate Shukla uses opposite convention — investigate.")
end

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: WINKLER FEA — raw element moments
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "="^80)
println("PART 2 — WINKLER FEA: Raw Element Moments")
println("="^80)

ν_c = 0.2
Ec_Pa = ustrip(u"Pa", uconvert(u"Pa", Ec))
h_m = ustrip(u"m", h)
B_m = ustrip(u"m", B)
Lm_m = ustrip(u"m", Lm)
c_est_m = ustrip(u"m", 18.0u"inch")

te_m = clamp(min(B_m, Lm_m) / 20.0, 0.15, 0.75)
refine_edge = clamp(c_est_m / 2.0, 0.04, te_m / 2.0) * u"m"
target_edge = te_m * u"m"

cx_m = ustrip(u"m", cx)
cy_m = ustrip(u"m", cy)

section = ShellSection(h_m * u"m", Ec_Pa * u"Pa", ν_c)

corner_nodes = (
    Node([0.0u"m", 0.0u"m", 0.0u"m"], :free),
    Node([B_m*u"m", 0.0u"m", 0.0u"m"], :free),
    Node([B_m*u"m", Lm_m*u"m", 0.0u"m"], :free),
    Node([0.0u"m", Lm_m*u"m", 0.0u"m"], :free),
)

interior_nodes = [Node([cx_m * u"m", cy_m * u"m", 0.0u"m"], :free)]
edge_dofs = [false, false, true, true, true, true]

patches = [ShellPatch(cx_m, cy_m, c_est_m, c_est_m, section; id=:col_patch)]

shells = Shell(corner_nodes, section;
               id=:mat_diag,
               interior_nodes=interior_nodes,
               interior_patches=patches,
               edge_support_type=edge_dofs,
               interior_support_type=:free,
               target_edge_length=target_edge,
               refinement_edge_length=refine_edge)

nodes = get_nodes(shells)

# Find nearest node to column
col_node_idx = 1
best_d2 = Inf
for (i, n) in enumerate(nodes)
    d2 = (ustrip(u"m", n.position[1]) - cx_m)^2 + (ustrip(u"m", n.position[2]) - cy_m)^2
    if d2 < best_d2
        global col_node_idx = i
        global best_d2 = d2
    end
end
col_node = nodes[col_node_idx]

# Apply column load (downward → -Z)
Pu_N = ustrip(u"N", uconvert(u"N", 500.0kip))
loads = [NodeForce(col_node, [0.0, 0.0, -Pu_N] .* u"N")]

model = Model(nodes, shells, loads)
process!(model)

# Add Winkler springs
ks_Pa_m = ustrip(u"N/m^3", uconvert(u"N/m^3", soil.ks))
trib = Dict{UInt64, Float64}()
for elem in shells
    A3 = elem.area / 3.0
    for nd in elem.nodes
        trib[objectid(nd)] = get(trib, objectid(nd), 0.0) + A3
    end
end
fea_springs = Spring[]
edge_tol = min(B_m, Lm_m) * 1e-4
for n in nodes
    A_t = get(trib, objectid(n), 0.0)
    A_t < 1e-12 && continue
    K = A_t * ks_Pa_m
    xn = ustrip(u"m", n.position[1])
    yn = ustrip(u"m", n.position[2])
    on_edge = (xn < edge_tol || xn > B_m - edge_tol ||
               yn < edge_tol || yn > Lm_m - edge_tol)
    if on_edge; K *= 2.0; end
    push!(fea_springs, Spring(n; kz = K * u"N/m"))
end
add_springs!(model, fea_springs)
solve!(model)

println("\n  Mesh: $(length(shells)) elements, $(length(nodes)) nodes")
@printf("  Target edge: %.3f m, Refinement edge: %.4f m\n",
        te_m, ustrip(u"m", refine_edge))

# Extract all element data
elem_data = []
for elem in shells
    c = shell_centroid(elem)
    dist_col = sqrt((c.x - cx_m)^2 + (c.y - cy_m)^2)
    M = bending_moments(elem, model)
    push!(elem_data, (dist_col=dist_col, cx=c.x, cy=c.y,
                       Mxx=M[1], Myy=M[2], Mxy=M[3]))
end
sort!(elem_data, by=x->x.dist_col)

println("\n  Elements NEAR COLUMN (closest 8):")
println("  dist(m)   cx(m)   cy(m)    Mxx(N·m/m)    Myy(N·m/m)")
println("  ───────   ─────   ─────    ──────────    ──────────")
for ed in elem_data[1:min(8, end)]
    @printf("  %7.3f  %6.3f  %6.3f  %+12.1f  %+12.1f\n",
            ed.dist_col, ed.cx, ed.cy, ed.Mxx, ed.Myy)
end

sort!(elem_data, by=x-> -x.dist_col)
println("\n  Elements FAR FROM COLUMN (8 furthest):")
println("  dist(m)   cx(m)   cy(m)    Mxx(N·m/m)    Myy(N·m/m)")
println("  ───────   ─────   ─────    ──────────    ──────────")
for ed in elem_data[1:min(8, end)]
    @printf("  %7.3f  %6.3f  %6.3f  %+12.1f  %+12.1f\n",
            ed.dist_col, ed.cx, ed.cy, ed.Mxx, ed.Myy)
end

# Global envelope
sort!(elem_data, by=x->x.dist_col)
gov_pos = maximum(ed.Mxx for ed in elem_data)
gov_neg = minimum(ed.Mxx for ed in elem_data)
@printf("\n  GLOBAL Mxx ENVELOPE: max = %+.1f  min = %+.1f N·m/m\n", gov_pos, gov_neg)

# Deflections
col_disp = ustrip(u"mm", col_node.displacement[3])
@printf("  Column node: w = %+.4f mm\n", col_disp)

println("\n  FEA SIGN AT COLUMN:")
near_col_Mxx = [ed.Mxx for ed in elem_data[1:min(4, end)]]
avg = sum(near_col_Mxx) / length(near_col_Mxx)
if avg < 0
    println("    Average Mxx near column < 0 → NEGATIVE → Asap: BOTTOM TENSION ✓")
    println("    Current code: |neg| → As_top → WRONG (should be As_bot)")
else
    println("    Average Mxx near column > 0 → POSITIVE → Asap: TOP TENSION")
    println("    This is unexpected for column bottom tension — investigate.")
end

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: Cross-reference with slab FEA
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "="^80)
println("PART 3 — CONCLUSION")
println("="^80)

println("""
  ASAP SIGN CONVENTION (from slab FEA code):
    Positive raw moment  →  TOP tension (hogging)
    Negative raw moment  →  BOTTOM tension (sagging)

  MAT PHYSICS (Mat Foundation Guide):
    At columns:  BOTTOM tension  →  expect NEGATIVE Mxx
    At midspan:  TOP tension     →  expect POSITIVE Mxx

  CURRENT CODE (both Shukla & FEA):
    positive  →  As_bot      (SHOULD be As_top — positive = top tension)
    |negative|  →  As_top    (SHOULD be As_bot — negative = bottom tension)

  FIX: Swap pos/neg → top/bot mapping in both mat_shukla.jl and mat_winkler_fea.jl.
""")

println("="^80)
println("END DIAGNOSTIC")
println("="^80)
