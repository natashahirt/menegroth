using StructuralSizer
using Unitful
using Test
using Printf

# =============================================================================
# Mat Foundation Method Comparison — ACI 336.2R / ACI 318-14
# =============================================================================
#
# Two production analysis methods:
#   Analytical  — Shukla (1984) + rigid envelope (ACI 336.2R §6.1.2 Steps 3–4)
#   FEA         — Shell plate on Winkler springs (ACI 336.2R §6.4/§6.7)
#
# Rigid is also run standalone for reference / comparison.
#
# Scenario A: Moderate office loading (3×3 bays, 25 ft, ~5000 kip total)
# Scenario B: Heavy high-rise loading (3×3 bays, 30 ft, ~11000 kip total)
# Scenario C: Very heavy / punching-governed (30 ft, ~14000 kip total)
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Build a 4×4 column grid with given spacing and load levels."""
function build_grid(spacing_ft, Pu_corner, Pu_edge, Pu_interior,
                    Ps_corner, Ps_edge, Ps_interior)
    demands = FoundationDemand[]
    positions = NTuple{2, typeof(0.0u"ft")}[]
    n = 4
    for (i, x) in enumerate(range(0.0, step=spacing_ft, length=n))
        for (j, y) in enumerate(range(0.0, step=spacing_ft, length=n))
            idx = (i - 1) * n + j
            is_corner = (i == 1 || i == n) && (j == 1 || j == n)
            is_edge = !is_corner && (i == 1 || i == n || j == 1 || j == n)

            Pu = is_corner ? Pu_corner : is_edge ? Pu_edge : Pu_interior
            Ps = is_corner ? Ps_corner : is_edge ? Ps_edge : Ps_interior

            push!(demands, FoundationDemand(idx; Pu=Pu, Ps=Ps))
            push!(positions, (x * u"ft", y * u"ft"))
        end
    end
    return demands, positions
end

"""Run all three methods on a scenario and return results dict."""
function run_all_methods(demands, positions, soil; min_depth=24.0u"inch")
    base = (material=RC_4000_60, bar_size_x=8, bar_size_y=8,
            cover=3.0u"inch", min_depth=min_depth,
            depth_increment=1.0u"inch")

    r_rigid  = design_footing(MatFoundation(), demands, positions, soil;
        opts=MatFootingOptions(; base..., analysis_method=RigidMat()))

    r_shukla = design_footing(MatFoundation(), demands, positions, soil;
        opts=MatFootingOptions(; base..., analysis_method=ShuklaAFM()))

    r_fea    = design_footing(MatFoundation(), demands, positions, soil;
        opts=MatFootingOptions(; base..., analysis_method=WinklerFEA()))

    return Dict("Rigid" => r_rigid, "Analytical" => r_shukla, "FEA" => r_fea)
end

"""Print a comparison table."""
function print_comparison(results; label="")
    println("\n  ┌─────────────────────────────────────────────────────────────────────────────────────────┐")
    @printf("  │ %-87s │\n", label)
    println("  ├───────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┤")
    println("  │ Method    │  h (in.) │  d (in.) │ As_xb    │ As_xt    │ As_yb    │ As_yt    │ util     │")
    println("  ├───────────┼──────────┼──────────┼──────────┼──────────┼──────────┼──────────┼──────────┤")
    for (name, r) in sort(collect(results); by=x->x[1])
        h  = round(ustrip(u"inch", r.D), digits=1)
        d  = round(ustrip(u"inch", r.d), digits=1)
        axb = round(ustrip(u"inch^2", r.As_x_bot), digits=1)
        axt = round(ustrip(u"inch^2", r.As_x_top), digits=1)
        ayb = round(ustrip(u"inch^2", r.As_y_bot), digits=1)
        ayt = round(ustrip(u"inch^2", r.As_y_top), digits=1)
        u  = round(r.utilization, digits=3)
        @printf("  │ %-9s │ %8.1f │ %8.1f │ %8.1f │ %8.1f │ %8.1f │ %8.1f │ %8.3f │\n",
                name, h, d, axb, axt, ayb, ayt, u)
    end
    println("  └───────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘")
end

"""Sanity checks on a MatFootingResult."""
function check_result(r, min_plan_ft; label="")
    B_ft = ustrip(u"ft", r.B)
    L_ft = ustrip(u"ft", r.L_ftg)
    h_in = ustrip(u"inch", r.D)

    @test B_ft ≥ min_plan_ft
    @test L_ft ≥ min_plan_ft
    @test 23.9 ≤ h_in ≤ 96.0
    @test r.utilization < 1.0
    @test ustrip(u"inch^2", r.As_x_bot) > 0.0
    @test ustrip(u"inch^2", r.As_y_bot) > 0.0

    # Volume consistency
    V_exp = B_ft * L_ft * (h_in / 12.0) * 0.0283168
    V_act = ustrip(u"m^3", r.concrete_volume)
    @test abs(V_act - V_exp) / V_exp < 0.01
end

# =============================================================================
# SCENARIO A — Moderate Office Loading
# =============================================================================
# 3 bays × 3 bays @ 25 ft, medium sand
# Interior 500 kip, Edge 300 kip, Corner 180 kip

println("="^90)
println("SCENARIO A — Moderate Office Loading  (3×3 bays, 25 ft, Σ Pu ≈ 5100 kip)")
println("="^90)

demands_A, positions_A = build_grid(25.0,
    180.0kip, 300.0kip, 500.0kip,
    125.0kip, 210.0kip, 350.0kip)

soil_A = Soil(3.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
              ks=25000.0u"kN/m^3")

@printf("  %d columns, Σ Pu = %.0f kip, Σ Ps = %.0f kip\n",
        length(demands_A),
        sum(to_kip(d.Pu) for d in demands_A),
        sum(to_kip(d.Ps) for d in demands_A))
@printf("  Soil: qa = 3.0 ksf, ks = 25000 kN/m³\n")

results_A = run_all_methods(demands_A, positions_A, soil_A)
print_comparison(results_A; label="Scenario A — Moderate Office Loading")

@testset "Scenario A — Moderate" begin
    for (name, r) in results_A
        @testset "$name" begin
            check_result(r, 75.0; label=name)
        end
    end

    # Flexible methods should produce ≤ rigid thickness + 6 in. tolerance
    h_rigid = ustrip(u"inch", results_A["Rigid"].D)
    @test ustrip(u"inch", results_A["Analytical"].D) ≤ h_rigid + 6.0
    @test ustrip(u"inch", results_A["FEA"].D)         ≤ h_rigid + 6.0

    # Analytical envelope ≥ Rigid for every face (by construction)
    @test ustrip(u"inch^2", results_A["Analytical"].As_x_bot) ≥
          ustrip(u"inch^2", results_A["Rigid"].As_x_bot) - 0.1
    @test ustrip(u"inch^2", results_A["Analytical"].As_x_top) ≥
          ustrip(u"inch^2", results_A["Rigid"].As_x_top) - 0.1
end

# =============================================================================
# SCENARIO B — Heavy High-Rise Loading
# =============================================================================
# 3 bays × 3 bays @ 30 ft, stiff clay
# Interior 900 kip, Edge 550 kip, Corner 350 kip
# Softer soil (ks = 12000 kN/m³) → lower Kr → flexible methods should diverge

println("\n" * "="^90)
println("SCENARIO B — Heavy High-Rise Loading  (3×3 bays, 30 ft, Σ Pu ≈ 9600 kip)")
println("="^90)

demands_B, positions_B = build_grid(30.0,
    350.0kip, 550.0kip, 900.0kip,
    245.0kip, 385.0kip, 630.0kip)

soil_B = Soil(4.0ksf, 19.0u"kN/m^3", 35.0, 0.0u"kPa", 30.0u"MPa";
              ks=12000.0u"kN/m^3")

@printf("  %d columns, Σ Pu = %.0f kip, Σ Ps = %.0f kip\n",
        length(demands_B),
        sum(to_kip(d.Pu) for d in demands_B),
        sum(to_kip(d.Ps) for d in demands_B))
@printf("  Soil: qa = 4.0 ksf, ks = 12000 kN/m³ (softer → Kr lower)\n")

results_B = run_all_methods(demands_B, positions_B, soil_B)
print_comparison(results_B; label="Scenario B — Heavy High-Rise Loading")

@testset "Scenario B — Heavy" begin
    for (name, r) in results_B
        @testset "$name" begin
            check_result(r, 90.0; label=name)
        end
    end

    h_rigid_B = ustrip(u"inch", results_B["Rigid"].D)
    @test ustrip(u"inch", results_B["Analytical"].D) ≤ h_rigid_B + 6.0
    @test ustrip(u"inch", results_B["FEA"].D)         ≤ h_rigid_B + 6.0

    # Analytical envelope ≥ Rigid for every face
    @test ustrip(u"inch^2", results_B["Analytical"].As_x_bot) ≥
          ustrip(u"inch^2", results_B["Rigid"].As_x_bot) - 0.1
    @test ustrip(u"inch^2", results_B["Analytical"].As_x_top) ≥
          ustrip(u"inch^2", results_B["Rigid"].As_x_top) - 0.1
end

# =============================================================================
# SCENARIO C — Very Heavy / Punching-Governed
# =============================================================================
# Same grid as B but 50% higher loads → forces thickness iteration to climb

println("\n" * "="^90)
println("SCENARIO C — Very Heavy / Punching-Governed  (3×3 bays, 30 ft, Σ Pu ≈ 14400 kip)")
println("="^90)

demands_C, positions_C = build_grid(30.0,
    525.0kip, 825.0kip, 1350.0kip,
    368.0kip, 578.0kip,  945.0kip)

soil_C = Soil(5.0ksf, 20.0u"kN/m^3", 35.0, 0.0u"kPa", 35.0u"MPa";
              ks=15000.0u"kN/m^3")

@printf("  %d columns, Σ Pu = %.0f kip, Σ Ps = %.0f kip\n",
        length(demands_C),
        sum(to_kip(d.Pu) for d in demands_C),
        sum(to_kip(d.Ps) for d in demands_C))
@printf("  Soil: qa = 5.0 ksf, ks = 15000 kN/m³\n")

results_C = run_all_methods(demands_C, positions_C, soil_C; min_depth=30.0u"inch")
print_comparison(results_C; label="Scenario C — Very Heavy / Punching-Governed")

@testset "Scenario C — Very Heavy" begin
    for (name, r) in results_C
        @testset "$name" begin
            check_result(r, 90.0; label=name)
        end
    end
end

# =============================================================================
# SCENARIO D — Flexure-Governed (thick mat, punching trivial)
# =============================================================================
# Same loads as Scenario A but min_depth = 48" → punching utility ≪ 1.
# This isolates flexural reinforcement differences between methods.
# With punching not driving h, method-specific moment fields dominate.

println("\n" * "="^90)
println("SCENARIO D — Flexure-Governed  (same as A, min_depth = 48 in.)")
println("="^90)
println("  Forces punching to be trivially satisfied; h=48\" for all methods.")
println("  Differences in As now reflect only moment field quality.\n")

results_D = run_all_methods(demands_A, positions_A, soil_A; min_depth=48.0u"inch")
print_comparison(results_D; label="Scenario D — Flexure-Governed (h forced to 48 in.)")

@testset "Scenario D — Flexure" begin
    for (name, r) in results_D
        @testset "$name" begin
            # h should stay at min_depth since punching is trivially OK
            @test ustrip(u"inch", r.D) ≈ 48.0  atol=1.0
            @test r.utilization < 0.5  # punching should be very low
            @test ustrip(u"inch^2", r.As_x_bot) > 0.0
        end
    end

    # Analytical ≥ Rigid on every face (envelope property)
    @test ustrip(u"inch^2", results_D["Analytical"].As_x_bot) ≥
          ustrip(u"inch^2", results_D["Rigid"].As_x_bot) - 0.1
    @test ustrip(u"inch^2", results_D["Analytical"].As_x_top) ≥
          ustrip(u"inch^2", results_D["Rigid"].As_x_top) - 0.1
end

# =============================================================================
# SUMMARY REPORT
# =============================================================================

println("\n" * "="^90)
println("SUMMARY — Mat Foundation Method Comparison Report")
println("="^90)

println("""
  Production Analysis Methods:
    1. Analytical  — Shukla (1984) + rigid envelope (ACI 336.2R §6.1.2 Steps 3–4)
    2. FEA         — Shell plate on Winkler springs (ACI 336.2R §6.4/§6.7)
    (RigidMat shown for reference only)

  Design Checks (all methods):
    ✓ Two-way punching shear with biaxial moment transfer (ACI 318 §22.6)
    ✓ Bearing pressure ≤ qa (service loads)
    ✓ Flexural reinforcement — 4 layers (x-bot, x-top, y-bot, y-top)
    ✓ Minimum temperature/shrinkage steel (ACI 7.6.1.1)
    ✓ Concrete & steel volume computation

  Analytical-specific:
    ✓ Kelvin-Bessel functions Z₃, Z₃', Z₄, Z₄' (SpecialFunctions.besselk)
    ✓ Subgrade modulus from soil.ks or Shukla chart + ACI 336.2R Eq. 3-8
    ✓ Continuous moment field M(x,y) sampled for flexible peaks
    ✓ Rigid strip statics for baseline moments (satisfies global statics)
    ✓ Face-by-face envelope: max(Shukla, Rigid) per ACI 336.2R §6.1.2
    ✓ Bearing check at columns, corners, and center from q(x,y) = ks·δ(x,y)

  FEA-specific:
    ✓ Delaunay mesh with Ruppert refinement (same as slab FEA)
    ✓ ShellPatch at each column for mesh conformity + local refinement
    ✓ Adaptive target edge: clamp(min_bay/20, 0.15, 0.75) m
    ✓ Winkler springs: Voronoi tributary area × ks (ACI 336.2R Fig 6.8)
    ✓ Edge spring doubling (ACI 336.2R §6.9)
    ✓ Column loads at nearest node (ShellPatch guarantees column nodes)
    ✓ In-plane DOFs pinned on boundary (no membrane mechanism)
    ✓ Column-strip moment integration (analogous to slab FEA _integrate_at):
      - δ-band at column faces + midspan along span (max(c, L/20, 0.25m))
      - Column strip in transverse direction (DDM: half the min span)
      - Area-weighted average Mxx/m within strip × full mat width for total As
      - Captures moment concentration near columns; differentiates from rigid
""")

println("  All scenarios passed. ✓")
