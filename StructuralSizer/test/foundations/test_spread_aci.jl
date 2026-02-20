using StructuralSizer
using Unitful
using Test

println("Testing ACI 318-14 Spread Footing Design...")

# =============================================================================
# Validation against StructurePoint Reference
# =============================================================================
# Source: "Reinforced Concrete Spread Footing Analysis and Design ACI 318-14"
#         Wight 7th Ed., Example 15-2
#
# Given:
#   Column: 18" x 18", f'c_col = 5000 psi, 8 #9 Grade 60 bars
#   Footing: f'c = 3000 psi, Grade 60, normal weight concrete
#   PD = 400 kip, PL = 270 kip  →  Pu = 1.2(400)+1.6(270) = 912 kip
#   Ps = 400 + 270 = 670 kip (service)
#   qa_net = 5370 psf (after deducting surcharge)
#
# Reference results:
#   B = L = 11'-2" (134 in.)
#   h = 32 in., d = 28 in.
#   Mu = 954 kip-ft
#   As_required = 7.76 in²
#   11 #8 bars each way (As_provided = 8.69 in²)
#   Two-way shear: vu = 156 psi, ϕvc = 164 psi (OK)
#   One-way shear: Vu = 204 kip, ϕVc = 308 kip (OK)
# =============================================================================

# Set up demand
demand = FoundationDemand(1; Pu=912.0kip, Ps=670.0kip)

# Set up soil (net allowable = 5370 psf = 5.37 ksf)
soil = Soil(5.37ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")

# Set up options matching the reference problem
opts = SpreadFootingOptions(
    material = RC_3000_60,
    pier_c1 = 18.0u"inch",
    pier_c2 = 18.0u"inch",
    pier_shape = :rectangular,
    bar_size = 8,
    cover = 3.0u"inch",
    min_depth = 12.0u"inch",
    depth_increment = 1.0u"inch",
    size_increment = 1.0u"inch",  # 1" increments for exact match
    fc_col = 5000.0u"psi",       # column concrete strength
)

println("Designing spread footing...")
result = design_footing(SpreadFooting(), demand, soil; opts)

# Extract results in imperial for comparison
B_in = ustrip(u"inch", result.B)
L_in = ustrip(u"inch", result.L_ftg)
h_in = ustrip(u"inch", result.D)
d_in = ustrip(u"inch", result.d)

println("\n=== Design Results ===")
println("  B = $(round(B_in, digits=1)) in. ($(round(B_in/12, digits=2)) ft)")
println("  L = $(round(L_in, digits=1)) in. ($(round(L_in/12, digits=2)) ft)")
println("  h = $(round(h_in, digits=1)) in.")
println("  d = $(round(d_in, digits=1)) in.")
println("  n_bars = $(result.rebar_count) #$(opts.bar_size) each way")
As_per_width_in2 = ustrip(u"inch^2", result.As * result.B)  # convert m²/m × m → m² → in²
println("  As_provided = $(round(As_per_width_in2, digits=2)) in² each way")
println("  V_concrete = $(round(ustrip(u"m^3", result.concrete_volume), digits=3)) m³")
println("  V_steel = $(round(ustrip(u"m^3", result.steel_volume), digits=5)) m³")
println("  utilization = $(round(result.utilization, digits=3))")

# =============================================================================
# Validation checks
# =============================================================================
println("\n=== Validation ===")

# Footing size: reference = 11'-2" = 134 in. (we may get 134 or close)
@test B_in ≥ 130.0 && B_in ≤ 138.0  # within 3% of 134"
println("  B = $(B_in) in. (ref: 134 in.) ✓")

# Thickness: reference = 32 in.
@test h_in ≥ 30.0 && h_in ≤ 34.0  # within ±2" of 32
println("  h = $(h_in) in. (ref: 32 in.) ✓")

# Effective depth: reference = 28 in.
@test d_in ≥ 26.0 && d_in ≤ 30.0
println("  d = $(d_in) in. (ref: 28 in.) ✓")

# Number of bars: reference = 11 #8 each way
@test result.rebar_count ≥ 10 && result.rebar_count ≤ 14
println("  n_bars = $(result.rebar_count) (ref: 11) ✓")

# Utilization should be < 1.0 (design is adequate)
@test result.utilization < 1.0
println("  utilization = $(round(result.utilization, digits=3)) < 1.0 ✓")

println("\n=== All spread footing validation tests passed! ===")
