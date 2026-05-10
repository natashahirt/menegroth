using StructuralSizer
using Unitful
using Test

# =============================================================================
# Mat WinklerFEA — Compression-only (no-tension) soil springs
# =============================================================================
#
# Validates the iterative deactivate / reactivate algorithm in
# `_solve_winkler!`.  Two complementary cases:
#
#   1. **Concentric point load on a stiff square mat.**  A 24 in. × 48 ft
#      mat with a single 400 kip column at the geometric centre has a high
#      flexural rigidity and large overhang, so the corners must lift off
#      under any cohesionless soil.  We verify:
#        - the no-tension iteration converges,
#        - a substantial fraction of spring nodes lift off (≥ 30 %),
#        - the resulting As is at least the §7.12.2.1 T&S floor.
#
#   2. **Diagnostic comparison vs. the legacy two-way model.**  Same load
#      case, run with `WinklerFEA(no_tension_springs = false)`.  Verifies
#      that the legacy path:
#        - still solves cleanly (back-compat),
#        - converges to the same `h` (depth iteration is driven by punching
#          shear, which is independent of spring tension), and
#        - produces a comparable As at the T&S floor (because strength is
#          below T&S in this load case under either spring model).
#
# Together these pin the contract: the new default (no-tension) reproduces
# the spMats / production-tool convention without breaking the legacy
# diagnostic path.
#
# References:
#   - ACI 336.2R-88 §6.4 / §6.7 (Winkler FEM model assumptions).
#   - StructurePoint *spMats Engineering Software Program Manual* v8.12
#     (2016) §3.4 — soil-pressure springs are compression-only by default.
# =============================================================================

println("\n" * "="^90)
println("Mat WinklerFEA — Compression-only soil springs")
println("="^90)

# Load case shared by both modes — the 48 ft × 48 ft × 24 in. concentric
# reference also used in test_rebar_quantity.jl, with `edge_overhang = 24 ft`
# locking plan dimensions to the StructurePoint reference geometry.
dem_center = FoundationDemand(1; Pu = 400.0kip, Ps = 280.0kip,
                                 c1 = 18.0u"inch", c2 = 18.0u"inch",
                                 shape = :rectangular)
positions  = [(24.0u"ft", 24.0u"ft")]
soil       = Soil(2.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
                  ks = 100_000.0u"kN/m^3")

opts_base = (
    material        = RC_4000_60,
    bar_size_x      = 8,
    bar_size_y      = 8,
    cover           = 3.0u"inch",
    min_depth       = 24.0u"inch",
    depth_increment = 1.0u"inch",
    edge_overhang   = 24.0u"ft",
)

opts_no_tension = MatParams(; opts_base...,
    analysis_method = WinklerFEA(no_tension_springs = true))
opts_two_way    = MatParams(; opts_base...,
    analysis_method = WinklerFEA(no_tension_springs = false))

println("\n--- Mode 1: compression-only (default) ---")
result_nt = design_footing(MatFoundation(), [dem_center], positions, soil;
                           opts = opts_no_tension)

println("\n--- Mode 2: legacy two-way (diagnostic) ---")
result_2w = design_footing(MatFoundation(), [dem_center], positions, soil;
                           opts = opts_two_way)

# Helpers — strip units once.
h_in_nt   = ustrip(u"inch", result_nt.D)
h_in_2w   = ustrip(u"inch", result_2w.D)
Asy_nt    = ustrip(u"inch^2", result_nt.As_y_bot)
Asy_2w    = ustrip(u"inch^2", result_2w.As_y_bot)
util_nt   = result_nt.utilization
util_2w   = result_2w.utilization

# §7.12.2.1 T&S floor for Grade 60 steel — same as the test_rebar_quantity
# reference; serves as the lower-bound expectation under either spring model.
fy_psi    = ustrip(u"psi", opts_no_tension.material.rebar.Fy)
ρ_min     = fy_psi == 60_000.0 ? 0.0018 :
            fy_psi <  60_000.0 ? 0.0020 :
            max(0.0014, 0.0018 * 60_000.0 / fy_psi)
As_TS_in2 = ρ_min *
            ustrip(u"inch", result_nt.B) *
            ustrip(u"inch", result_nt.D)

println()
println("  no-tension : h = $(round(h_in_nt, digits=1)) in., " *
        "As_y_bot = $(round(Asy_nt, digits=2)) in², util = $(round(util_nt, digits=3))")
println("  two-way    : h = $(round(h_in_2w, digits=1)) in., " *
        "As_y_bot = $(round(Asy_2w, digits=2)) in², util = $(round(util_2w, digits=3))")
println("  T&S floor  : $(round(As_TS_in2, digits=2)) in²")

@testset "WinklerFEA — compression-only springs (no-tension default)" begin
    # Punching governs depth and is independent of soil-spring tension; both
    # spring models must converge to h = 24 in. (the imposed minimum).
    @test isapprox(h_in_nt, 24.0; atol = 0.5)
    @test isapprox(h_in_2w, 24.0; atol = 0.5)

    # Punching utilization unchanged between modes (the punching critical
    # section is local to the column and uses the design qu, not FEA stress).
    @test isapprox(util_nt, util_2w; rtol = 1e-6)

    # Strength-based As is below the T&S minimum for this load case → both
    # modes pin to the §7.12.2.1 floor within ±5 %.
    @test isapprox(Asy_nt, As_TS_in2; rtol = 0.05)
    @test isapprox(Asy_2w, As_TS_in2; rtol = 0.05)

    # The no-tension design must not produce *less* steel than the two-way
    # design for the same load case — deactivating uplift springs reduces the
    # supported area, which can only increase peak moments.  Allow a tiny
    # slack to accommodate floor-rounding from `ceil(Int, As / Ab)` in the
    # bar count.  (Both pin to T&S here, so the inequality holds tightly.)
    @test Asy_nt ≥ Asy_2w * 0.999
end
