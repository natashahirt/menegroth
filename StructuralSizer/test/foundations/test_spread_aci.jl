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

# Set up demand (column geometry on demand — single source of truth)
demand = FoundationDemand(1; Pu=912.0kip, Ps=670.0kip,
    c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)

# Set up soil (net allowable = 5370 psf = 5.37 ksf)
soil = Soil(5.37ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")

# Set up options matching the reference problem
opts = SpreadParams(
    material = RC_3000_60,
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

# The thickness search must accept the same grid point the linear scan
# accepted: h_k = min_depth + k·depth_increment, k = 0..59, and the same
# nonconvergence error when nothing on that grid passes.
function _spread_depth_opts(; min_depth=12.0u"inch", depth_increment=1.0u"inch",
                            size_increment=1.0u"inch")
    SpreadParams(
        material = RC_3000_60,
        bar_size = 8,
        cover = 3.0u"inch",
        min_depth = min_depth,
        depth_increment = depth_increment,
        size_increment = size_increment,
        fc_col = 5000.0u"psi",
    )
end

"""Thickness after `k` successive additions of `incr`, matching the scan grid."""
function _spread_grid_h(min_depth, incr, k::Int)
    h = min_depth
    for _ in 1:k
        h += incr
    end
    return h
end

@testset "Spread footing thickness grid" begin
    # Reference case. Scan accepted 31 in (k = 19 on a 1 in grid); d = h − 3.5 in.
    @test uconvert(u"inch", result.D) ≈ 31.0u"inch" atol=1e-6u"inch"
    @test uconvert(u"inch", result.d) ≈ 27.5u"inch" atol=1e-6u"inch"
    @test result.rebar_count == 11

    # h_0 already passes → return it, do not step to the next increment.
    r_min = design_footing(SpreadFooting(), demand, soil;
                           opts=_spread_depth_opts(min_depth=36.0u"inch"))
    @test uconvert(u"inch", r_min.D) ≈ 36.0u"inch" atol=1e-6u"inch"

    # Coarser and finer increments: first passing grid point, not a value between steps.
    r_2 = design_footing(SpreadFooting(), demand, soil;
                         opts=_spread_depth_opts(depth_increment=2.0u"inch"))
    @test uconvert(u"inch", r_2.D) ≈ 32.0u"inch" atol=1e-6u"inch"
    r_half = design_footing(SpreadFooting(), demand, soil;
                            opts=_spread_depth_opts(depth_increment=0.5u"inch"))
    @test uconvert(u"inch", r_half.D) ≈ 31.0u"inch" atol=1e-6u"inch"

    # Biaxial moment and a circular column: accepted depth stays on the scan's answer.
    demand_e = FoundationDemand(1; Pu=912.0kip, Ps=670.0kip,
        Mux=400.0kip * u"ft", Muy=250.0kip * u"ft",
        c1=16.0u"inch", c2=24.0u"inch", shape=:rectangular)
    r_e = design_footing(SpreadFooting(), demand_e, soil; opts=_spread_depth_opts())
    @test uconvert(u"inch", r_e.D) ≈ 38.0u"inch" atol=1e-6u"inch"
    @test uconvert(u"inch", r_e.B) ≈ 155.0u"inch" atol=1e-6u"inch"

    demand_c = FoundationDemand(1; Pu=912.0kip, Ps=670.0kip,
        c1=18.0u"inch", c2=18.0u"inch", shape=:circular)
    r_c = design_footing(SpreadFooting(), demand_c, soil; opts=_spread_depth_opts())
    @test uconvert(u"inch", r_c.D) ≈ 36.0u"inch" atol=1e-6u"inch"

    # 60 steps of 0.1 in never reach a passing thickness. Error text uses the
    # post-increment h, and the trace keeps the nonconvergence fields.
    h_fail = _spread_grid_h(12.0u"inch", 0.1u"inch", 60)
    tc = StructuralSizer.TraceCollector()
    err = try
        design_footing(SpreadFooting(), demand, soil;
                       opts=_spread_depth_opts(depth_increment=0.1u"inch"), tc=tc)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test err.msg == "Spread footing depth did not converge after 60 iterations (h=$h_fail). " *
                     "Check bearing pressure, column dimensions, or increase max depth."
    fails = filter(ev -> ev.event_type == :failure, tc.events)
    @test length(fails) == 1
    @test fails[1].data["reason"] == "depth_iteration_nonconvergence"
    @test fails[1].data["h_in"] ≈ ustrip(u"inch", h_fail)
    @test fails[1].data["last_punch_ok"] == false
    @test fails[1].data["last_punch_ratio"] isa Float64
    @test fails[1].data["last_one_way_ok"] isa Bool
    @test count(ev -> ev.event_type == :enter, tc.events) == 1

    # Every grid point is below the 4 in effective-depth gate. Shear is not
    # run; the failure still reports the same reason with punch unset.
    h_shallow = _spread_grid_h(6.0u"inch", 0.01u"inch", 60)
    tc_shallow = StructuralSizer.TraceCollector()
    err_shallow = try
        design_footing(SpreadFooting(), demand, soil;
                       opts=_spread_depth_opts(min_depth=6.0u"inch",
                                               depth_increment=0.01u"inch"),
                       tc=tc_shallow)
        nothing
    catch e
        e
    end
    @test err_shallow isa ErrorException
    @test err_shallow.msg == "Spread footing depth did not converge after 60 iterations (h=$h_shallow). " *
                             "Check bearing pressure, column dimensions, or increase max depth."
    fails_shallow = filter(ev -> ev.event_type == :failure, tc_shallow.events)
    @test length(fails_shallow) == 1
    @test fails_shallow[1].data["reason"] == "depth_iteration_nonconvergence"
    @test fails_shallow[1].data["last_punch_ok"] == false
    @test fails_shallow[1].data["last_punch_ratio"] === nothing
    @test fails_shallow[1].data["last_one_way_ok"] == false

    # A target at or below min_depth does not raise the first grid index.
    # A target past the 60-point grid clamps to the last index.
    @test StructuralSizer._spread_depth_index(12.0u"inch", 1.0u"inch", 6.0u"inch") == 0
    @test StructuralSizer._spread_depth_index(12.0u"inch", 1.0u"inch", 12.0u"inch") == 0
    @test StructuralSizer._spread_depth_index(12.0u"inch", 1.0u"inch", 1000.0u"inch") == 59

    # Zero load: minimum thickness already passes. Still a real footing.
    demand_0 = FoundationDemand(1; Pu=0.0kip, Ps=0.0kip,
        c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
    r0 = design_footing(SpreadFooting(), demand_0, soil; opts=_spread_depth_opts())
    @test uconvert(u"inch", r0.D) ≈ 12.0u"inch" atol=1e-6u"inch"
    @test r0.B == r0.L_ftg
    @test r0.rebar_count >= 2
    @test r0.concrete_volume > 0.0u"m^3"
end

@testset "Footing flexure is tension-controlled (ACI 318-11 §10.3.4)" begin
    SS = StructuralSizer
    fc3, fy60 = 3000.0u"psi", 60000.0u"psi"
    b, d = 134.0u"inch", 28.0u"inch"

    # Reference Mu = 954 kip-ft on the 134 in footing at d = 28 in: As_required = 7.76 in².
    @test ustrip(u"inch^2", SS._footing_tension_As(954.0kip * u"ft", b, d, fc3, fy60, 0.9)) ≈
          7.76 rtol = 0.01

    # εt = 0.005 ⇒ c/d = 3/8, ω = 0.85·β₁·3/8, Rn = ω·f'c·(1 − ω/1.7); β₁ = 0.85 at 3 ksi.
    ω = 0.85 * 0.85 * 0.375
    Mu_tc = 0.9 * ω * fc3 * (1 - ω / 1.7) * b * d^2
    @test isfinite(SS._footing_tension_As(0.999 * Mu_tc, b, d, fc3, fy60, 0.9))
    @test isinf(SS._footing_tension_As(1.01 * Mu_tc, b, d, fc3, fy60, 0.9))
    @test_throws ErrorException SS._flexural_steel_footing(1.01 * Mu_tc, b, d, fc3, fy60, 0.9)

    # With a small ϕ_flexure (a lever to make flexure govern) the depth search
    # adds thickness past the 31 in shear answer until flexure passes.
    opts_f = SpreadParams(material = RC_3000_60, bar_size = 8, cover = 3.0u"inch",
                          min_depth = 12.0u"inch", depth_increment = 1.0u"inch",
                          size_increment = 1.0u"inch", fc_col = 5000.0u"psi",
                          ϕ_flexure = 0.12)
    r_f = design_footing(SpreadFooting(), demand, soil; opts = opts_f)
    @test r_f.D > 31.0u"inch"
    qu = 912.0kip / (r_f.B * r_f.L_ftg)
    Mu = qu * r_f.B * ((r_f.L_ftg - 18.0u"inch") / 2)^2 / 2
    @test SS._footing_flexure_ok(((Mu, r_f.B),), r_f.d, fc3, fy60, 0.12)
    @test !SS._footing_flexure_ok(((Mu, r_f.B),), r_f.d - 1.0u"inch", fc3, fy60, 0.12)
end
