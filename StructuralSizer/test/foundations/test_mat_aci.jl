using StructuralSizer
using Unitful
using Test

println("Testing ACI 336.2R Rigid Mat Foundation Design...")

# =============================================================================
# Test case: 3x3 column grid, typical office building
# =============================================================================
# Grid: 3 bays × 3 bays, 25 ft spacing each way
# Interior columns: Pu ≈ 500 kip, Ps ≈ 350 kip
# Edge columns: Pu ≈ 300 kip, Ps ≈ 210 kip
# Corner columns: Pu ≈ 180 kip, Ps ≈ 125 kip
# Soil: medium sand, qa_net ≈ 3.0 ksf

demands = FoundationDemand[]
positions = NTuple{2, typeof(0.0u"ft")}[]

# 3x3 grid (4 columns each way = 16 columns total, 3 bays)
spacings_x = [0.0, 25.0, 50.0, 75.0]
spacings_y = [0.0, 25.0, 50.0, 75.0]

for (i, x) in enumerate(spacings_x), (j, y) in enumerate(spacings_y)
    idx = (i - 1) * length(spacings_y) + j
    is_corner = (i == 1 || i == 4) && (j == 1 || j == 4)
    is_edge = !is_corner && (i == 1 || i == 4 || j == 1 || j == 4)

    if is_corner
        Pu = 180.0kip
        Ps = 125.0kip
    elseif is_edge
        Pu = 300.0kip
        Ps = 210.0kip
    else
        Pu = 500.0kip
        Ps = 350.0kip
    end

    push!(demands, FoundationDemand(idx; Pu=Pu, Ps=Ps))
    push!(positions, (x * u"ft", y * u"ft"))
end

println("  $(length(demands)) columns on 3-bay × 3-bay grid (25 ft spacing)")
println("  Total Pu = $(sum(to_kip(d.Pu) for d in demands)) kip")
println("  Total Ps = $(sum(to_kip(d.Ps) for d in demands)) kip")

soil = Soil(3.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
            ks=25000.0u"kN/m^3")

opts = MatFootingOptions(
    material = RC_4000_60,
    bar_size_x = 8,
    bar_size_y = 8,
    cover = 3.0u"inch",
    min_depth = 24.0u"inch",
    depth_increment = 1.0u"inch",
)

println("\nDesigning mat footing...")
result = design_mat_footing(demands, positions, soil; opts)

B_ft = ustrip(u"ft", result.B)
L_mat_ft = ustrip(u"ft", result.L_ftg)
h_in = ustrip(u"inch", result.D)
d_in = ustrip(u"inch", result.d)

println("\n=== Design Results ===")
println("  Mat size = $(round(B_ft, digits=1)) ft × $(round(L_mat_ft, digits=1)) ft")
println("  h = $(round(h_in, digits=1)) in.")
println("  d = $(round(d_in, digits=1)) in.")
println("  n_columns = $(result.n_columns)")
println("  As_x_bot = $(round(ustrip(u"inch^2", result.As_x_bot), digits=2)) in²")
println("  As_x_top = $(round(ustrip(u"inch^2", result.As_x_top), digits=2)) in²")
println("  As_y_bot = $(round(ustrip(u"inch^2", result.As_y_bot), digits=2)) in²")
println("  As_y_top = $(round(ustrip(u"inch^2", result.As_y_top), digits=2)) in²")
println("  V_concrete = $(round(ustrip(u"m^3", result.concrete_volume), digits=1)) m³")
println("  utilization = $(round(result.utilization, digits=3))")

# =============================================================================
# Sanity checks
# =============================================================================
println("\n=== Sanity Checks ===")

# Mat should be at least as large as the grid
@test B_ft ≥ 75.0   # 75 ft grid + overhang
@test L_mat_ft ≥ 75.0
println("  Mat ≥ grid footprint ✓")

# Thickness: punching governs, expect 24-48"
@test h_in ≥ 23.9 && h_in ≤ 60.0
println("  h = $(h_in) in. (reasonable range) ✓")

# Utilization < 1.0
@test result.utilization < 1.0
println("  utilization = $(round(result.utilization, digits=3)) < 1.0 ✓")

# Reinforcement provided in all directions
@test ustrip(u"inch^2", result.As_x_bot) > 0.0
@test ustrip(u"inch^2", result.As_y_bot) > 0.0
println("  All reinforcement layers > 0 ✓")

# Concrete volume sanity: B × L × h (rough check)
V_expected_m3 = B_ft * L_mat_ft * (h_in / 12.0) * 0.0283168  # ft³ → m³
V_actual = ustrip(u"m^3", result.concrete_volume)
@test abs(V_actual - V_expected_m3) / V_expected_m3 < 0.01
println("  Concrete volume consistent ✓")

println("\n=== All mat footing sanity tests passed! ===")
