using StructuralSizer
using Unitful
using Test

println("Testing ACI 318-14 Strip (Combined) Footing Design...")

# =============================================================================
# Validation against StructurePoint Combined Footing Reference
# =============================================================================
# Source: "Reinforced Concrete Column Combined Footing Analysis and Design"
#         Wight 7th Ed., Example 15-5
#         (corpus: sp-de-combined-footing-aci318-14)
#
# Given:
#   Exterior column: 24" x 16", PD=200 kip, PL=150 kip
#   Interior column: 24" x 24", PD=300 kip, PL=225 kip
#   f'c = 3000 psi, fy = 60000 psi
#   qa = 5000 psf → after surcharge ≈ 4.37 ksf net (reference pre-sizes to L=25.33', B=8')
#   Pu_ext = 1.2(200)+1.6(150) = 480 kip
#   Pu_int = 1.2(300)+1.6(225) = 720 kip
#   Ps_ext = 200+150 = 350 kip
#   Ps_int = 300+225 = 525 kip
#
# Reference results:
#   Footing: 25'-4" x 8', h=40 in., d=36.5 in.
#   qu = 5.92 ksf
#   Negative Mu = 2100 kip-ft → As = 13.4 in², use 17 #8
#   Interior punching: vu = 80.2 psi < ϕvc = 164 psi
#   Exterior punching (at h=40): vu = 157 psi < ϕvc = 164 psi
#
# Note on h convergence:  the reference's h = 40 in. is set by exterior-column
# punching with unbalanced moment ALONE; the StructurePoint document explicitly
# defers the one-way shear check to a different example (page 10: "this example
# focus on the calculation of two-way shear capacity for combined foundation").
# Our routine enforces BOTH punching (ACI 318-11 §11.11) and one-way shear (ACI
# 318-11 §11.2.1, Eq. 11-3) using bw = B; with d = 36.5 in. and B = 8 ft, the
# strip's V(x) at d from the interior column face exceeds ϕVc = 2λ√f'c·B·d,
# so one-way shear governs and our routine converges one increment higher
# (h = 43 in.) — more conservative than, and consistent with, the literal ACI
# formula.  Asserted bound: h ∈ [40, 44].
# =============================================================================

# Demands
d_ext = FoundationDemand(1; Pu=480.0kip, Ps=350.0kip, c1=18.0u"inch", c2=18.0u"inch")
d_int = FoundationDemand(2; Pu=720.0kip, Ps=525.0kip, c1=18.0u"inch", c2=18.0u"inch")

# The reference uses pre-computed net qa ≈ 4.37 ksf (after footing weight, etc.)
# From the reference: total area = 25.33 × 8 = 202.67 ft²
# Service load = 350+525 = 875 kip → qa_net = 875/202.67 = 4.32 ksf
# Let's use a net qa that yields the reference's pre-sized dimensions
soil = Soil(4.32ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")

# Column positions: exterior at 1 ft from left edge, interior at 21 ft from left edge
# The reference places columns such that centroid aligns at L/2
# Exterior column is near property line
# Column spacing = 20 ft (from the reference figure)
# With the resultant at x = (350×0 + 525×20)/875 = 12 ft from exterior
# L/2 = 12 + overhang → L ≈ 25.33 ft
positions = [0.0u"ft", 20.0u"ft"]

opts = StripParams(
    material = RC_3000_60,
    bar_size_long = 8,
    bar_size_trans = 5,
    cover = 3.0u"inch",  # ACI 318-11 §7.7.1 clear cover (true clear; d = h − cover − db/2)
    min_depth = 12.0u"inch",
    depth_increment = 1.0u"inch",
    width_increment = 1.0u"inch",
)

println("Designing strip footing...")
result = design_footing(StripFooting(), [d_ext, d_int], positions, soil; opts)

# Extract results
B_in = ustrip(u"inch", result.B)
L_in = ustrip(u"inch", result.L_ftg)
h_in = ustrip(u"inch", result.D)
d_in = ustrip(u"inch", result.d)

println("\n=== Design Results ===")
println("  B = $(round(B_in, digits=1)) in. ($(round(B_in/12, digits=2)) ft)")
println("  L = $(round(L_in, digits=1)) in. ($(round(L_in/12, digits=2)) ft)")
println("  h = $(round(h_in, digits=1)) in.")
println("  d = $(round(d_in, digits=1)) in.")
println("  n_columns = $(result.n_columns)")
As_bot = ustrip(u"inch^2", result.As_long_bot)
As_top = ustrip(u"inch^2", result.As_long_top)
As_trans = ustrip(u"inch^2", result.As_trans)
println("  As_long_bot = $(round(As_bot, digits=2)) in²")
println("  As_long_top = $(round(As_top, digits=2)) in²")
println("  As_trans = $(round(As_trans, digits=2)) in²")
println("  utilization = $(round(result.utilization, digits=3))")

# =============================================================================
# Validation
# =============================================================================
println("\n=== Validation ===")

# Thickness: reference = 40 in. (set by punching only; ref defers one-way to
# a separate example).  Our routine enforces both punching and ACI 11.2.1
# one-way shear, so we converge one increment higher (~43 in.).  Tight band
# [40, 44] keeps both ours and the reference inside.
@test h_in ≥ 40.0 && h_in ≤ 44.0
println("  h = $(h_in) in. (ref: 40 in., ours ~43 in. due to one-way shear) ✓")

# Width: reference = 8 ft = 96 in.
@test B_in ≥ 80.0 && B_in ≤ 120.0
println("  B = $(round(B_in/12, digits=2)) ft (ref: 8 ft) ✓")

# Top steel under midspan negative moment Mu = 2100 kip-ft.
# StructurePoint hand calc and spMats both give As_required ≈ 13.4 in² and
# select 17 #8 (As_provided ≈ 13.43 in²).  Allow ±15 % to accommodate the
# small differences in B / h convergence (our plan dim and depth iterate to
# B ≈ 7.83 ft, h ≈ 43 in. vs. the reference B = 8 ft, h = 40 in.).  A larger
# d gives slightly less As, so As_top tends to come in just under 13.4 in².
@test isapprox(As_top, 13.4; rtol = 0.15)
@test isapprox(As_bot, 13.4; rtol = 0.15)
println("  As_top = $(round(As_top, digits=2)) in² (ref: ≈13.4 in², ±15%) ✓")
println("  As_bot = $(round(As_bot, digits=2)) in² (ref: ≈13.4 in², ±15%) ✓")

# Utilization should be < 1.0
@test result.utilization < 1.0
println("  utilization = $(round(result.utilization, digits=3)) < 1.0 ✓")

println("\n=== All strip footing validation tests passed! ===")
