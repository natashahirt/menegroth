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

# The published example parks the exterior column at the property line.
# That face does not develop (§15.6.3). The comparison below is the
# published section; the following testset lengthens the strip.
opts = StripParams(
    material = RC_3000_60,
    bar_size_long = 8,
    bar_size_trans = 5,
    cover = 3.0u"inch",  # ACI 318-11 §7.7.1 clear cover (true clear; d = h − cover − db/2)
    min_depth = 12.0u"inch",
    depth_increment = 1.0u"inch",
    width_increment = 1.0u"inch",
    check_development = false,
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

@testset "A flush end is lengthened until the bars develop" begin
    # ACI 318-11 §15.6.3 (corpus: aci-318-11, page 274): each bar is
    # developed from its own column face. The property-line face has no
    # projection, so the plan grows until Eq. (12-1) or a §12.5 hook fits.
    developed_opts = StripParams(
        material = RC_3000_60,
        bar_size_long = 8,
        bar_size_trans = 5,
        cover = 3.0u"inch",
        min_depth = 12.0u"inch",
        depth_increment = 1.0u"inch",
        width_increment = 1.0u"inch",
    )
    grown = design_footing(StripFooting(), [d_ext, d_int], positions, soil;
                           opts = developed_opts)
    @test grown.L_ftg > result.L_ftg

    fc = developed_opts.material.concrete.fc′
    fy = developed_opts.material.rebar.Fy
    λ = something(developed_opts.λ, developed_opts.material.concrete.λ)
    cover = developed_opts.cover
    x_bar = (d_ext.Ps * positions[1] + d_int.Ps * positions[2]) / (d_ext.Ps + d_int.Ps)

    function nearest_face(footing)
        L = footing.L_ftg
        x_left = x_bar - L / 2
        avail = L
        for (dem, p) in zip((d_ext, d_int), positions)
            xc = p - x_left
            avail = min(avail, min(xc, L - xc) - dem.c1 / 2 - cover)
        end
        return avail
    end

    short_avail = nearest_face(result)
    grown_avail = nearest_face(grown)
    @test short_avail <= 1.0u"inch"
    @test grown_avail > short_avail
    As_short = max(result.As_long_top, result.As_long_bot)
    As_grown = max(grown.As_long_top, grown.As_long_bot)
    refused = StructuralSizer._one_way_anchorage(
        8, As_short, result.B, result.D, cover, fc, fy, λ, short_avail,
        min(3 * result.D, 18.0u"inch"))
    accepted = StructuralSizer._one_way_anchorage(
        8, As_grown, grown.B, grown.D, cover, fc, fy, λ, grown_avail,
        min(3 * grown.D, 18.0u"inch"))
    @test !refused.ok
    @test accepted.ok
end

@testset "lateral combination stays on the gravity resultant" begin
    # Equal service loads put the centroid 10 ft from the first column.
    # The second combination moves the resultant to 2 ft. Eq. (3-1) needs
    # the footing at least 6|e| = 48 ft long, still centered at 10 ft.
    d1 = FoundationDemand(1; Pu=150.0kip, Ps=100.0kip, c1=12.0u"inch", c2=12.0u"inch")
    d2 = FoundationDemand(2; Pu=150.0kip, Ps=100.0kip, c1=12.0u"inch", c2=12.0u"inch")
    positions = [0.0u"ft", 20.0u"ft"]
    soil = Soil(20.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    opts = StripParams(
        material = RC_3000_60,
        cover = 3.0u"inch",
        min_depth = 16.0u"inch",
        depth_increment = 4.0u"inch",
        width_increment = 6.0u"inch",
        check_development = false,
    )
    plain = design_footing(StripFooting(), [d1, d2], positions, soil; opts)
    newtons(F) = ustrip(u"N", F)
    service = [
        [FootingAction(:g, newtons(100u"kip"), 0.0, 0.0),
         FootingAction(:lat, newtons(180u"kip"), 0.0, 0.0)],
        [FootingAction(:g, newtons(100u"kip"), 0.0, 0.0),
         FootingAction(:lat, newtons(20u"kip"), 0.0, 0.0)],
    ]
    strength = [
        [FootingAction(:gu, newtons(150u"kip"), 0.0, 0.0),
         FootingAction(:lu, newtons(250u"kip"), 0.0, 0.0)],
        [FootingAction(:gu, newtons(150u"kip"), 0.0, 0.0),
         FootingAction(:lu, newtons(30u"kip"), 0.0, 0.0)],
    ]
    grown = design_footing(StripFooting(), [d1, d2], positions, soil; opts,
                           column_service = service, column_strength = strength)
    @test ustrip(u"ft", plain.L_ftg) < 30
    @test ustrip(u"ft", grown.L_ftg) ≥ 48
    e = abs(2.0u"ft" - 10.0u"ft")
    @test e ≤ grown.L_ftg / 6 + 0.5u"inch"
end
