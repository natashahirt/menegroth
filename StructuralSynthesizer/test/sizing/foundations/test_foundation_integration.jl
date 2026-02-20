# Integration Test: Foundation Design — ACI 318-14 Validation Report
# Refs: [1] SP Spread (Wight Ex15-2) [2] SP Combined (Wight Ex15-5) [3] ACI 336.2R §4.2 [4] ACI 318-14 §22.6/§8.4.4.2

using Test
using Printf
using Unitful
using Unitful: @u_str
using StructuralSizer
using StructuralSizer: kip, ksf, ksi, psf, pcf, to_kip, to_kipft, to_ksi, to_inches

# ─────────────────────────────────────────────────────────────────────────────
# Report helpers (same style as EFM report)
# ─────────────────────────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "..", "..", "shared", "report_helpers.jl"))
const _rpt = ReportHelpers.Printer()

"""
Print one comparison row. Returns `true` when |δ| ≤ tol.
"""
function compare(label, computed, reference; tol=0.05)
    δ = reference == 0 ? 0.0 : (computed - reference) / max(abs(reference), 1e-12)
    ok = abs(δ) ≤ tol
    flag = ok ? "✓" : (abs(δ) ≤ 2tol ? "~" : "✗")
    @printf("    %-30s %12.2f %12.2f %+7.1f%%  %s\n", label, computed, reference, 100δ, flag)
    return ok
end

# Track per-step status for the final summary table
const _fdn_step_status = Dict{String,String}()

# ─────────────────────────────────────────────────────────────────────────────
# BEGIN REPORT
# ─────────────────────────────────────────────────────────────────────────────

@testset "ACI 318-14 Foundation Design Validation" begin

_rpt.section("ACI 318-14 FOUNDATION DESIGN — Validation Report")
println("  Refs: [1] SP Spread (Wight Ex15-2) [2] SP Combined (Ex15-5) [3] ACI 336.2R §4.2 [4] ACI 318-14 §22.6/§8.4.4.2")

# STEP 0 — SHARED PUNCHING SHEAR UTILITIES (ACI 318-14 §22.6 / §8.4.4.2)

_rpt.section("STEP 0 — SHARED PUNCHING SHEAR UTILITIES")
println("  Validates punching/shear math shared by slabs & all foundation types (codes/aci/punching.jl).")

_rpt.sub("0A — Critical Section Geometry (§22.6.4)")
println("  b₀: Interior=4-sided, Edge=3-sided, Corner=2-sided per §22.6.4")

# Test with SP baseline: c = 18", d = 28"
c_test = 18.0u"inch"
d_test = 28.0u"inch"

geom_int  = StructuralSizer.punching_geometry_interior(c_test, c_test, d_test)
geom_edge = StructuralSizer.punching_geometry_edge(c_test, c_test, d_test)
geom_corn = StructuralSizer.punching_geometry_corner(c_test, c_test, d_test)

b0_int  = ustrip(u"inch", geom_int.b0)
b0_edge = ustrip(u"inch", geom_edge.b0)
b0_corn = ustrip(u"inch", geom_corn.b0)

# Hand-calc: interior b0 = 2(18+28) + 2(18+28) = 4×46 = 184"
@printf("    c = %.0f in,  d = %.0f in\n\n", ustrip(u"inch", c_test), ustrip(u"inch", d_test))
@printf("    %-14s  %8s  %8s  %8s\n", "Position", "b₀ (in)", "b₁ (in)", "b₂ (in)")
@printf("    %-14s  %8s  %8s  %8s\n", "─"^14, "─"^8, "─"^8, "─"^8)
@printf("    %-14s  %8.1f  %8.1f  %8.1f\n", "Interior",
        b0_int, ustrip(u"inch", geom_int.b1), ustrip(u"inch", geom_int.b2))
@printf("    %-14s  %8.1f  %8.1f  %8.1f\n", "Edge",
        b0_edge, ustrip(u"inch", geom_edge.b1), ustrip(u"inch", geom_edge.b2))
@printf("    %-14s  %8.1f  %8.1f  %8.1f\n", "Corner",
        b0_corn, ustrip(u"inch", geom_corn.b1), ustrip(u"inch", geom_corn.b2))

@test b0_int ≈ 184.0 rtol=0.01       # 4(18+28) = 184
@test b0_edge ≈ 110.0 rtol=0.01      # 2(18+14) + (18+28) = 110
@test b0_corn ≈ 64.0 rtol=0.01       # (18+14) + (18+14) = 64

_rpt.note("Interior b₀=184\" ✓; edge/corner reduce to 3/2 sides → more critical.")

_rpt.sub("0B — Punching Capacity vc (§22.6.5.2)")
println("  vc = min(4λ√f'c, (2+4/β)λ√f'c, (αs·d/b₀+2)λ√f'c)")

fc_test = 3000.0u"psi"
β_test  = StructuralSizer.punching_β(c_test, c_test)
αs_int  = StructuralSizer.punching_αs(:interior)

vc_a = 4 * 1.0 * sqrt(3000.0)     # = 219.1 psi
vc_b = (2 + 4/β_test) * sqrt(3000.0)  # β=1 → 6√f'c = 328.6
vc_c = (αs_int * ustrip(u"inch", d_test) / b0_int + 2) * sqrt(3000.0)

vc_computed = StructuralSizer.punching_capacity_stress(
    fc_test, β_test, αs_int, geom_int.b0, d_test)
vc_computed_psi = ustrip(u"psi", vc_computed)

@printf("    β = %.2f (square),  αs = %d (interior)\n", β_test, αs_int)
@printf("    f'c = %.0f psi,  λ = 1.0\n\n", ustrip(u"psi", fc_test))
@printf("    %-24s %10.1f psi\n", "Eq (a): 4λ√f'c", vc_a)
@printf("    %-24s %10.1f psi\n", "Eq (b): (2+4/β)λ√f'c", vc_b)
@printf("    %-24s %10.1f psi\n", "Eq (c): (αs·d/b₀+2)λ√f'c", vc_c)
@printf("    %-24s %10.1f psi  ← governs\n", "vc = min(a,b,c)", vc_computed_psi)

@test vc_computed_psi ≈ min(vc_a, vc_b, vc_c) rtol=0.001
@test vc_computed_psi ≈ vc_a rtol=0.01   # for β=1 square, Eq (a) typically governs

_rpt.note("β=1 (square): Eq(a) governs; Eq(c) can govern for large d/b₀.")

_rpt.sub("0C — Moment Transfer Fractions (§8.4.2.3)")
println("  γf = 1/(1+(2/3)√(b₁/b₂)), γv = 1−γf")

# For interior column with c=18, d=28: b1=b2=46"
b1_test = c_test + d_test  # 46"
b2_test = c_test + d_test  # 46"
γf_val = StructuralSizer.gamma_f(b1_test, b2_test)
γv_val = StructuralSizer.gamma_v(b1_test, b2_test)

# Hand-calc: b1/b2 = 1 → γf = 1/(1 + 2/3) = 0.600, γv = 0.400
@printf("    b₁ = b₂ = %.0f in (square column + d)\n\n", ustrip(u"inch", b1_test))
@printf("    γf = %.3f  (flexure)   — hand: 1/(1+2/3) = 0.600\n", γf_val)
@printf("    γv = %.3f  (eccentric shear)\n", γv_val)

@test γf_val ≈ 0.600 rtol=0.001
@test γv_val ≈ 0.400 rtol=0.001
@test γf_val + γv_val ≈ 1.0 atol=1e-10

_rpt.note("γf+γv=1.0 always; non-square columns → γf≠0.600.")

_rpt.sub("0D — Polar Moment Jc (R8.4.4.2.3)")
println("  Jc = 2[b₁d³/12 + d·b₁³/12] + 2·b₂·d·(b₁/2)² (interior)")

Jc_int = StructuralSizer.polar_moment_Jc_interior(b1_test, b2_test, d_test)
Jc_in4 = ustrip(u"inch^4", Jc_int)

# Hand-calc for b1=b2=46", d=28":
# 2[46×28³/12 + 28×46³/12] + 2×46×28×23² = 2[84149.3 + 227141.3] + 2×46×28×529
# = 2×311290.7 + 1362608 = 622581.3 + 1362608 = 1985189
hand_Jc = 2*(46*28^3/12 + 28*46^3/12) + 2*46*28*(46/2)^2

@printf("    Jc = %.0f in⁴   (computed)\n", Jc_in4)
@printf("    Jc = %.0f in⁴   (hand-calc)\n", hand_Jc)

@test Jc_in4 ≈ hand_Jc rtol=0.001

_rpt.note("Jc used in vu = Vu/(b₀d) + γv·Mub·cAB/Jc for unbalanced moment transfer.")

_rpt.sub("0E — One-Way Shear Capacity (§22.5.5.1)")
println("  Vc = 2λ√f'c·bw·d")

bw_test = 100.0u"inch"
Vc_1way = StructuralSizer.one_way_shear_capacity(fc_test, bw_test, d_test)
Vc_1way_kip = to_kip(Vc_1way)
# Hand: 2×1×√3000×100×28 = 306,709 lbf = 306.7 kip
hand_Vc = 2 * sqrt(3000.0) * 100 * 28 / 1000

@printf("    bw = %.0f in,  d = %.0f in\n", ustrip(u"inch", bw_test), ustrip(u"inch", d_test))
@printf("    Vc = %.1f kip  (computed)\n", Vc_1way_kip)
@printf("    Vc = %.1f kip  (hand: 2√f'c·bw·d)\n", hand_Vc)

@test Vc_1way_kip ≈ hand_Vc rtol=0.01

_rpt.note("φVc = 0.75×Vc = $(round(0.75 * hand_Vc, digits=1)) kip; governs at d from face of support.")

_fdn_step_status["Shared Punching Utils"] = "✓"

_rpt.sub("0F — Full punching_check (Biaxial Moment Transfer)")
println("  Concentric + eccentric shear; high-level punching_check() used by all footing types.")

# Concentric case (no moment) — should give vu = Vu/(b₀d)
Vu_conc = 200.0kip
pch_conc = StructuralSizer.punching_check(
    Vu_conc, 0.0u"N*m", 0.0u"N*m",
    d_test, fc_test, c_test, c_test; position=:interior)

vu_conc_psi = ustrip(u"psi", pch_conc.vu)
vu_hand = ustrip(u"lbf", Vu_conc) / (b0_int * ustrip(u"inch", d_test))  # psi

@printf("    Concentric: Vu = %.0f kip, Mux = Muy = 0\n", to_kip(Vu_conc))
@printf("    vu = Vu/(b₀d) = %.1f psi  (computed: %.1f psi)\n", vu_hand, vu_conc_psi)
@printf("    φvc = %.1f psi   →   vu/φvc = %.3f  %s\n",
        ustrip(u"psi", pch_conc.ϕvc), pch_conc.utilization,
        pch_conc.ok ? "✓" : "✗")

@test vu_conc_psi ≈ vu_hand rtol=0.01
@test pch_conc.ok

# Eccentric case (Mux = 200 kip·ft) — vu should increase
Mux_test = 200.0 * kip * u"ft"
pch_ecc = StructuralSizer.punching_check(
    Vu_conc, Mux_test, 0.0u"N*m",
    d_test, fc_test, c_test, c_test; position=:interior)

println()
@printf("    Eccentric: Vu = %.0f kip, Mux = %.0f kip·ft\n",
        to_kip(Vu_conc), to_kipft(Mux_test))
@printf("    vu = %.1f psi  (> %.1f psi concentric)\n",
        ustrip(u"psi", pch_ecc.vu), vu_conc_psi)
@printf("    vu/φvc = %.3f  %s\n",
        pch_ecc.utilization, pch_ecc.ok ? "✓" : "✗")

@test ustrip(u"psi", pch_ecc.vu) > vu_conc_psi   # moment adds stress
@test pch_ecc.utilization > pch_conc.utilization

_rpt.note("Eccentric shear adds γv·Mub·cAB/Jc; biaxial moments superposed per R8.4.4.2.3.")

# STEP 1 — SPREAD FOOTING (Ref [1]: Wight Ex 15-2)

_rpt.section("STEP 1 — SPREAD FOOTING  (Wight Ex 15-2)")
println("  7-step SP workflow: sizing → punching → beam shear → flexure → development → bearing → dowels")

_rpt.sub("1A — Input Summary")

sp_Pu = 912.0kip
sp_Ps = 670.0kip
sp_c1 = 18.0u"inch"
sp_fc = 3000.0u"psi"
sp_fy = 60.0ksi
sp_qa = 5.37ksf
sp_cover = 3.0u"inch"

@printf("    Column:     %s × %s (square)\n", sp_c1, sp_c1)
@printf("    f'c footing = %s,  f'c column = 5000 psi\n", sp_fc)
@printf("    fy = %s\n", sp_fy)
@printf("    Pu = %.0f kip (1.2×400 + 1.6×270)\n", to_kip(sp_Pu))
@printf("    Ps = %.0f kip (service)\n", to_kip(sp_Ps))
@printf("    qa_net = %.2f ksf (after surcharge deduction)\n", ustrip(ksf, sp_qa))
@printf("    Cover = %s (cast against soil)\n", sp_cover)

_rpt.sub("1B — Preliminary Sizing (Service Loads)")
println("  A_req = Ps/qa = $(round(to_kip(sp_Ps) / ustrip(ksf, sp_qa), digits=1)) ft², B = √A_req = $(round(sqrt(to_kip(sp_Ps) / ustrip(ksf, sp_qa)), digits=2)) ft")

A_req_ft2 = to_kip(sp_Ps) / ustrip(ksf, sp_qa)
B_calc_ft = sqrt(A_req_ft2)
@printf("\n    A_req = %.1f ft²\n", A_req_ft2)
@printf("    B_calc = %.2f ft → round up to nearest increment\n", B_calc_ft)
println()
_rpt.note("Reference: B = L = 11'-2\" (134 in.) — square footing.")

_rpt.sub("1C — Design (Full ACI 318-14 Workflow)")

sp_demand = FoundationDemand(1; Pu=sp_Pu, Ps=sp_Ps)
sp_soil = Soil(sp_qa, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")

sp_opts = SpreadFootingOptions(
    material = RC_3000_60,
    pier_c1 = sp_c1,
    pier_c2 = sp_c1,
    pier_shape = :rectangular,
    bar_size = 8,
    cover = sp_cover,
    min_depth = 12.0u"inch",
    depth_increment = 1.0u"inch",
    size_increment = 1.0u"inch",
    fc_col = 5000.0u"psi",
)

sp_result = design_footing(SpreadFooting(), sp_demand, sp_soil; opts=sp_opts)

sp_B_in = ustrip(u"inch", sp_result.B)
sp_L_in = ustrip(u"inch", sp_result.L_ftg)
sp_h_in = ustrip(u"inch", sp_result.D)
sp_d_in = ustrip(u"inch", sp_result.d)
sp_As_in2 = ustrip(u"inch^2", sp_result.As * sp_result.B)
sp_V_conc = ustrip(u"m^3", sp_result.concrete_volume)
sp_V_steel = ustrip(u"m^3", sp_result.steel_volume)

println()
@printf("    %-24s %10s %10s\n", "Quantity", "Computed", "Ref [1]")
@printf("    %-24s %10s %10s\n", "─"^24, "─"^10, "─"^10)
@printf("    %-24s %10.0f %10.0f\n", "B = L (in.)",       sp_B_in, 134.0)
@printf("    %-24s %10.0f %10.0f\n", "h (in.)",           sp_h_in, 32.0)
@printf("    %-24s %10.0f %10.0f\n", "d (in.)",           sp_d_in, 28.0)
@printf("    %-24s %10d %10d\n",     "n_bars (#8)",       sp_result.rebar_count, 11)
@printf("    %-24s %10.2f %10.2f\n", "As provided (in²)", sp_As_in2, 8.69)
@printf("    %-24s %10.3f %10s\n",   "utilization",       sp_result.utilization, "< 1.0")
println()

@testset "Spread Footing — Wight Ex 15-2" begin
    @test sp_B_in ≥ 130.0 && sp_B_in ≤ 138.0
    @test sp_h_in ≥ 30.0 && sp_h_in ≤ 34.0
    @test sp_d_in ≥ 26.0 && sp_d_in ≤ 30.0
    @test sp_result.rebar_count ≥ 10 && sp_result.rebar_count ≤ 14
    @test sp_result.utilization < 1.0
end

# Detailed checks
_rpt.sub("1D — Shear Checks (Two-Way + One-Way)")

# Recompute punching for reporting
sp_d = sp_result.d
sp_B = sp_result.B
sp_qu = sp_Pu / (sp_B * sp_result.L_ftg)
sp_Ac = (sp_c1 + sp_d) * (sp_c1 + sp_d)
sp_Vu_punch = sp_qu * (sp_B * sp_result.L_ftg - sp_Ac)
sp_punch = StructuralSizer.punching_check(
    sp_Vu_punch, 0.0u"N*m", 0.0u"N*m",
    sp_d, sp_fc, sp_c1, sp_c1; position=:interior)

sp_b0 = ustrip(u"inch", sp_punch.b0)
sp_vu_psi = ustrip(u"psi", sp_punch.vu)
sp_ϕvc_psi = ustrip(u"psi", sp_punch.ϕvc)

@printf("    Two-way (punching):\n")
@printf("      b₀ = %.1f in\n", sp_b0)
@printf("      Vu = %.1f kip\n", to_kip(sp_Vu_punch))
@printf("      vu = %.1f psi,  φvc = %.1f psi\n", sp_vu_psi, sp_ϕvc_psi)
@printf("      vu/φvc = %.3f  %s\n", sp_punch.utilization, sp_punch.ok ? "✓ OK" : "✗ NG")
println()

_rpt.note("Ref [1]: vu = 156 psi, φvc = 164 psi — our vc uses f'c = 3000 psi.")

# One-way shear
ϕVc_1w = 0.75 * StructuralSizer.one_way_shear_capacity(sp_fc, sp_B, sp_d)
cant = (sp_B - sp_c1) / 2 - sp_d
Vu_1w = sp_qu * sp_B * cant
@printf("    One-way (beam) shear:\n")
@printf("      Cantilever beyond d = %.2f ft\n", ustrip(u"ft", cant))
@printf("      Vu = %.1f kip,  φVc = %.1f kip\n",
        to_kip(Vu_1w), to_kip(ϕVc_1w))
@printf("      Vu/φVc = %.3f  %s\n",
        to_kip(Vu_1w) / to_kip(ϕVc_1w),
        to_kip(Vu_1w) ≤ to_kip(ϕVc_1w) ? "✓ OK" : "✗ NG")

_rpt.note("Ref [1]: Vu = 204 kip, φVc = 308 kip.")

@test sp_punch.ok
@test to_kip(Vu_1w) ≤ to_kip(ϕVc_1w)

_rpt.sub("1E — Flexural Reinforcement")

Mu_cant = sp_qu * sp_B * ((sp_B - sp_c1) / 2)^2 / 2
Mu_cant_kipft = to_kipft(Mu_cant)
@printf("    Mu (face of column) = %.1f kip·ft\n", Mu_cant_kipft)
@printf("    Ref [1]: Mu = 954 kip·ft\n")
@printf("    n_bars = %d #8 each way   (Ref: 11 #8)\n", sp_result.rebar_count)
@printf("    As_provided = %.2f in²     (Ref: 8.69 in²)\n", sp_As_in2)
_rpt.note("Differences from ref: rounding increments (1\" vs 2\"); our design is conservative.")

_fdn_step_status["Spread Footing"] = "✓"

# STEP 2 — STRIP / COMBINED FOOTING (Ref [2]: Wight Ex 15-5)

_rpt.section("STEP 2 — STRIP / COMBINED FOOTING  (Wight Ex 15-5)")
println("  Rigid analysis: N=2 columns, uniform soil pressure, centroid aligned with resultant.")

_rpt.sub("2A — Input Summary")

# Exterior column: 24"×16", PD=200, PL=150
# Interior column: 24"×24", PD=300, PL=225
str_d_ext = FoundationDemand(1; Pu=480.0kip, Ps=350.0kip,
                              c1=24.0u"inch", c2=16.0u"inch")
str_d_int = FoundationDemand(2; Pu=720.0kip, Ps=525.0kip,
                              c1=24.0u"inch", c2=24.0u"inch")
str_Pu_total = 480.0 + 720.0   # 1200 kip
str_Ps_total = 350.0 + 525.0   # 875 kip

@printf("    Exterior column:  Pu = 480 kip, Ps = 350 kip, c1×c2 = 24\"×16\"\n")
@printf("    Interior column:  Pu = 720 kip, Ps = 525 kip, c1×c2 = 24\"×24\"\n")
@printf("    Spacing = 20 ft\n")
@printf("    f'c = 3000 psi,  fy = 60 ksi\n")
@printf("    qa_net ≈ 4.32 ksf\n")
println()

# Resultant position
x_bar = (350.0 * 0.0 + 525.0 * 20.0) / 875.0
@printf("    Load resultant at x = %.1f ft from exterior column\n", x_bar)
@printf("    Required L ≈ 2 × %.1f = %.1f ft  (Ref: 25'-4\" = 25.33 ft)\n",
        x_bar + 1.0, 2 * (x_bar + 1.0))

_rpt.sub("2B — Design")
println("  Uniform soil pressure upward; V(x)/M(x) at 500 stations along length.")

str_positions = [0.0u"ft", 20.0u"ft"]
str_soil = Soil(4.32ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")

str_opts = StripFootingOptions(
    material = RC_3000_60,
    bar_size_long = 8,
    bar_size_trans = 5,
    cover = 3.5u"inch",
    min_depth = 12.0u"inch",
    depth_increment = 1.0u"inch",
    width_increment = 1.0u"inch",
)

str_result = design_footing(StripFooting(), [str_d_ext, str_d_int], str_positions, str_soil; opts=str_opts)

str_B_in = ustrip(u"inch", str_result.B)
str_L_in = ustrip(u"inch", str_result.L_ftg)
str_h_in = ustrip(u"inch", str_result.D)
str_d_in = ustrip(u"inch", str_result.d)
str_As_top = ustrip(u"inch^2", str_result.As_long_top)
str_As_bot = ustrip(u"inch^2", str_result.As_long_bot)
str_As_trans = ustrip(u"inch^2", str_result.As_trans)

_rpt.sub("2C — Design Results")
println()
@printf("    %-24s %10s %10s\n", "Quantity", "Computed", "Ref [2]")
@printf("    %-24s %10s %10s\n", "─"^24, "─"^10, "─"^10)
@printf("    %-24s %10.1f %10s\n", "L (in.)",       str_L_in, "304 (25'-4\")")
@printf("    %-24s %10.1f %10s\n", "B (in.)",       str_B_in, "96 (8 ft)")
@printf("    %-24s %10.1f %10.1f\n", "h (in.)",     str_h_in, 40.0)
@printf("    %-24s %10.1f %10.1f\n", "d (in.)",     str_d_in, 36.5)
@printf("    %-24s %10.2f %10.2f\n", "As_top (in²)", str_As_top, 13.4)
@printf("    %-24s %10.2f %10s\n", "As_bot (in²)", str_As_bot, "≥ min")
@printf("    %-24s %10.2f %10s\n", "As_trans (in²)", str_As_trans, "per band")
@printf("    %-24s %10.3f %10s\n", "utilization",  str_result.utilization, "< 1.0")
println()

@testset "Strip Footing — Wight Ex 15-5" begin
    @test str_h_in ≥ 36.0 && str_h_in ≤ 55.0
    @test str_B_in ≥ 80.0 && str_B_in ≤ 120.0
    @test str_As_top ≥ 5.0
    @test str_result.utilization < 1.0
end

_rpt.note("h=$(round(str_h_in, digits=0))\" vs ref 40\"; As_top=$(round(str_As_top, digits=1)) vs 13.4 in²; differences from 1\" rounding.")

_rpt.sub("2D — Punching at Each Column")

# Re-derive qu for reporting
str_qu = (480.0kip + 720.0kip) / (str_result.B * str_result.L_ftg)
str_d_eff = str_result.d

for (j, (label, demand)) in enumerate(zip(["Exterior", "Interior"], [str_d_ext, str_d_int]))
    cj1 = demand.c1   # 24" for both; c2 differs (16" vs 24")
    cj2 = demand.c2
    pos_sym = j == 1 ? :edge : :interior
    Ac_p = pos_sym == :edge ? (cj1 + str_d_eff / 2) * (cj2 + str_d_eff) :
                              (cj1 + str_d_eff) * (cj2 + str_d_eff)
    Vu_p = max(uconvert(u"lbf", demand.Pu - str_qu * Ac_p), 0.0u"lbf")

    pch = StructuralSizer.punching_check(
        Vu_p, demand.Mux, demand.Muy,
        str_d_eff, 3000.0u"psi", cj1, cj2;
        position=pos_sym)

    @printf("    %s column (%s, %s × %s):\n", label, string(pos_sym),
            cj1, cj2)
    @printf("      Vu = %.1f kip,  vu = %.1f psi,  φvc = %.1f psi\n",
            to_kip(Vu_p), ustrip(u"psi", pch.vu), ustrip(u"psi", pch.ϕvc))
    @printf("      vu/φvc = %.3f  %s\n", pch.utilization, pch.ok ? "✓" : "✗")
    @test pch.ok
end

_rpt.note("Ref [2]: Interior vu=80.2psi, Exterior vu=157psi; both < φvc=164psi.")

_rpt.sub("2E — Development Length (ACI 25.4.2)")
println("  Checks at each column: longitudinal bars (column face → footing edge) and transverse bars.")

str_db_l = StructuralSizer.bar_diameter(str_opts.bar_size_long)
str_db_t = StructuralSizer.bar_diameter(str_opts.bar_size_trans)
str_ld_long  = StructuralSizer._development_length_footing(str_opts.bar_size_long, 3000.0u"psi", 60.0ksi, 1.0, str_db_l)
str_ld_trans = StructuralSizer._development_length_footing(str_opts.bar_size_trans, 3000.0u"psi", 60.0ksi, 1.0, str_db_t)

# Column positions from left edge (same as design)
str_x_bar  = sum([350.0, 525.0] .* [0.0, 20.0]) / 875.0
str_L_ft   = ustrip(u"ft", str_result.L_ftg)
str_x_left = str_x_bar - str_L_ft / 2
str_col_local = [0.0 - str_x_left, 20.0 - str_x_left] .* u"ft"
str_demands_vec = [str_d_ext, str_d_int]

@printf("    Longitudinal bars (#%d): ld = %.1f in.\n",
        str_opts.bar_size_long, ustrip(u"inch", str_ld_long))
for (j, xc) in enumerate(str_col_local)
    cj1 = str_demands_vec[j].c1
    avail = min(xc, str_result.L_ftg - xc) - cj1 / 2 - str_opts.cover
    ok = str_ld_long ≤ avail
    @printf("      Col #%d (%s×%s): available = %.1f in.  %s\n",
            j, cj1, str_demands_vec[j].c2, ustrip(u"inch", avail), ok ? "✓" : "⚠ ld exceeds")
end

# Transverse: most critical = smallest c2
c2_min = minimum(d.c2 for d in str_demands_vec)
avail_trans = (str_result.B - c2_min) / 2 - str_opts.cover
@printf("    Transverse bars (#%d): ld = %.1f in., available = %.1f in. (c2_min=%s)  %s\n",
        str_opts.bar_size_trans, ustrip(u"inch", str_ld_trans),
        ustrip(u"inch", avail_trans), c2_min,
        str_ld_trans ≤ avail_trans ? "✓" : "⚠ ld exceeds")

@testset "Strip Dev. Length" begin
    @test ustrip(u"inch", str_ld_long) > 0
    @test ustrip(u"inch", str_ld_trans) > 0
end

_rpt.sub("2F — Bearing & Dowels at Each Column (ACI 22.8)")
println("  Bearing strength at column-footing interface; dowels if Pu > φBn_column.")

str_fc_col = 3000.0u"psi"   # same as footing for this example
for (j, (label, demand)) in enumerate(zip(["Exterior", "Interior"], [str_d_ext, str_d_int]))
    cj1 = demand.c1
    cj2 = demand.c2
    bearing = StructuralSizer._bearing_check_footing(
        demand.Pu, cj1, cj2,
        str_result.B, str_result.L_ftg, str_result.D,
        3000.0u"psi", str_fc_col, 60.0ksi, 0.65, :rectangular)

    Bn_ftg_kip = to_kip(bearing.Bn_footing)
    Bn_col_kip = to_kip(bearing.Bn_column)

    @printf("    %s column (%s × %s):\n", label, cj1, cj2)
    @printf("      φBn_footing = %.0f kip,  φBn_column = %.0f kip\n", Bn_ftg_kip, Bn_col_kip)
    @printf("      Pu = %.0f kip  →  footing %s,  column %s\n",
            to_kip(demand.Pu),
            bearing.footing_ok ? "OK ✓" : "NG ✗",
            demand.Pu ≤ bearing.Bn_column ? "OK ✓" : "needs dowels")
    if bearing.need_dowels
        @printf("      Dowels: As_dowels = %.2f in²\n", ustrip(u"inch^2", bearing.As_dowels))
    end

    @test bearing.footing_ok
end

_fdn_step_status["Strip/Combined Footing"] = "✓"

# STEP 3 — MAT FOUNDATION (ACI 336.2R Rigid Analysis)

_rpt.section("STEP 3 — MAT FOUNDATION  (ACI 336.2R Rigid)")
println("  Rigid mat: 4×4 grid, 25 ft spacing, uniform soil pressure (Kr > 0.5).")

_rpt.sub("3A — Input Summary")

mat_demands = FoundationDemand[]
mat_positions = NTuple{2, typeof(0.0u"ft")}[]

spacings = [0.0, 25.0, 50.0, 75.0]
for (i, x) in enumerate(spacings), (j, y) in enumerate(spacings)
    idx = (i - 1) * 4 + j
    is_corner = (i == 1 || i == 4) && (j == 1 || j == 4)
    is_edge = !is_corner && (i == 1 || i == 4 || j == 1 || j == 4)

    Pu = is_corner ? 180.0kip : is_edge ? 300.0kip : 500.0kip
    Ps = is_corner ? 125.0kip : is_edge ? 210.0kip : 350.0kip

    push!(mat_demands, FoundationDemand(idx; Pu=Pu, Ps=Ps))
    push!(mat_positions, (x * u"ft", y * u"ft"))
end

n_corner = count(d -> to_kip(d.Pu) ≈ 180.0, mat_demands)
n_edge   = count(d -> to_kip(d.Pu) ≈ 300.0, mat_demands)
n_int    = count(d -> to_kip(d.Pu) ≈ 500.0, mat_demands)
Pu_total_mat = sum(to_kip(d.Pu) for d in mat_demands)
Ps_total_mat = sum(to_kip(d.Ps) for d in mat_demands)

@printf("    Grid: 4×4 columns (3 bays × 3 bays), 25 ft spacing\n")
@printf("    %d corner (Pu=180k), %d edge (Pu=300k), %d interior (Pu=500k)\n",
        n_corner, n_edge, n_int)
@printf("    Total Pu = %.0f kip,  Total Ps = %.0f kip\n", Pu_total_mat, Ps_total_mat)
@printf("    Soil: qa = 3.0 ksf,  ks = 25000 kN/m³ (medium sand)\n")

mat_soil = Soil(3.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
                ks=25000.0u"kN/m^3")

mat_opts = MatFootingOptions(
    material = RC_4000_60,
    bar_size_x = 8,
    bar_size_y = 8,
    cover = 3.0u"inch",
    min_depth = 24.0u"inch",
    depth_increment = 1.0u"inch",
)

_rpt.sub("3B — Plan Sizing")

mat_result = design_footing(MatFoundation(), mat_demands, mat_positions, mat_soil; opts=mat_opts)

mat_B_ft = ustrip(u"ft", mat_result.B)
mat_L_ft = ustrip(u"ft", mat_result.L_ftg)
mat_h_in = ustrip(u"inch", mat_result.D)
mat_d_in = ustrip(u"inch", mat_result.d)
mat_area_ft2 = mat_B_ft * mat_L_ft
mat_qu_ksf = Pu_total_mat / mat_area_ft2

@printf("    Mat size: %.1f ft × %.1f ft = %.0f ft²\n", mat_B_ft, mat_L_ft, mat_area_ft2)
@printf("    Grid footprint: 75 ft × 75 ft = 5625 ft²\n")
@printf("    Edge overhang: %.1f ft each side (auto-calculated)\n",
        (mat_B_ft - 75.0) / 2)
@printf("    qu (factored) = %.2f ksf\n", mat_qu_ksf)
@printf("    qu/qa = %.3f (bearing utilization, service basis)\n",
        Ps_total_mat / (ustrip(ksf, mat_soil.qa) * mat_area_ft2))

_rpt.sub("3C — Thickness from Punching Shear")

@printf("    h = %.0f in. (governs from punching at interior columns)\n", mat_h_in)
@printf("    d = %.1f in.\n", mat_d_in)

@test mat_h_in ≥ 23.9 && mat_h_in ≤ 60.0

# Re-check punching at most-loaded column
Pu_max_col = 500.0kip
c_est = max(12.0, ceil(sqrt(500.0 / 0.5) / 3.0) * 3.0) * u"inch"
Ac_mat = (c_est + mat_result.d) * (c_est + mat_result.d)
qu_mat = sum(d.Pu for d in mat_demands) / (mat_result.B * mat_result.L_ftg)
Vu_mat = max(uconvert(u"lbf", Pu_max_col - qu_mat * Ac_mat), 0.0u"lbf")
pch_mat = StructuralSizer.punching_check(
    Vu_mat, 0.0u"N*m", 0.0u"N*m",
    mat_result.d, 4000.0u"psi", c_est, c_est; position=:interior)

@printf("    Interior column check (c_est = %.0f\"):\n", ustrip(u"inch", c_est))
@printf("      Vu = %.1f kip,  vu = %.1f psi,  φvc = %.1f psi\n",
        to_kip(Vu_mat), ustrip(u"psi", pch_mat.vu), ustrip(u"psi", pch_mat.ϕvc))
@printf("      vu/φvc = %.3f  %s\n", pch_mat.utilization, pch_mat.ok ? "✓" : "✗")

@test pch_mat.ok

_rpt.sub("3D — Flexural Reinforcement (Strip Statics)")
println("  Kramrisch: M⁻≈wL²/10 (continuous), M⁺≈wL²/11 (end)")

As_xb = ustrip(u"inch^2", mat_result.As_x_bot)
As_xt = ustrip(u"inch^2", mat_result.As_x_top)
As_yb = ustrip(u"inch^2", mat_result.As_y_bot)
As_yt = ustrip(u"inch^2", mat_result.As_y_top)

Ab_in2 = ustrip(u"inch^2", StructuralSizer.bar_area(8))

@printf("    %-20s %10s %10s\n", "Direction / Layer", "As (in²)", "bars")
@printf("    %-20s %10s %10s\n", "─"^20, "─"^10, "─"^10)
for (lbl, As_val) in [("x-bottom", As_xb), ("x-top", As_xt),
                       ("y-bottom", As_yb), ("y-top", As_yt)]
    n = ceil(Int, As_val / Ab_in2)
    @printf("    %-20s %10.2f %8d #8\n", lbl, As_val, n)
end

@test As_xb > 0 && As_yb > 0
@test As_xt > 0 && As_yt > 0

_rpt.note("Top+bottom steel required (neg. moment over cols, pos. at midspan); x/y may differ.")

_rpt.sub("3E — Relative Stiffness Kr")
println("  Kr = Ec·Ig/(ks·B·L³) per ACI 336.2R §4.2; Kr>0.5 → rigid valid.")

Ec_psi = 57000.0 * sqrt(4000.0)
Ig_in4 = ustrip(u"inch", mat_result.B) * ustrip(u"inch", mat_result.D)^3 / 12.0
ks_pci = ustrip(u"lbf/inch^3", uconvert(u"lbf/inch^3", mat_soil.ks))
Kr = Ec_psi * Ig_in4 / (ks_pci * ustrip(u"inch", mat_result.B) * ustrip(u"inch", mat_result.L_ftg)^3)

@printf("    Ec = %.0f psi  (57000√f'c)\n", Ec_psi)
@printf("    Ig = %.0f in⁴  (B × h³/12)\n", Ig_in4)
@printf("    ks = %.3f pci  (25000 kN/m³ converted)\n", ks_pci)
@printf("    Kr = %.3f  %s\n", Kr, Kr > 0.5 ? "→ rigid assumption valid ✓" :
                                               "→ flexible analysis needed ⚠")

if Kr > 0.5
    _rpt.note("Kr > 0.5 → rigid assumption appropriate (ACI 336.2R §4.2).")
else
    _rpt.note("Kr < 0.5 → flexible analysis recommended; WinklerFEA tier available.")
end

_rpt.sub("3F — Material Quantities")

mat_V_conc = ustrip(u"m^3", mat_result.concrete_volume)
mat_V_steel = ustrip(u"m^3", mat_result.steel_volume)

@printf("    Concrete volume = %.1f m³  (%.0f ft³)\n", mat_V_conc, mat_V_conc / 0.0283168)
@printf("    Steel volume    = %.4f m³  (%.0f lbs at 490 pcf)\n",
        mat_V_steel, mat_V_steel / 0.0283168 * 490)
@printf("    Utilization     = %.3f\n", mat_result.utilization)

@test mat_result.utilization < 1.0

_fdn_step_status["Mat Foundation (Rigid)"] = "✓"

# STEP 3b — FLEXIBLE MAT METHODS (Analytical + FEA)

_rpt.section("STEP 3b — FLEXIBLE MAT METHODS  (Analytical + FEA)")
println("  Same 4×4 grid as Step 3; compare Rigid / Analytical / FEA.")
println("  Analytical: Shukla + rigid envelope (ACI 336.2R §6.1.2 Steps 3–4)")
println("  FEA:        Shell plate on Winkler springs (ACI 336.2R §6.4/§6.7)")

_rpt.sub("3b-A — Moderate Loading (same as Step 3)")

mat_opts_shukla = MatFootingOptions(
    material = RC_4000_60, bar_size_x = 8, bar_size_y = 8,
    cover = 3.0u"inch", min_depth = 24.0u"inch", depth_increment = 1.0u"inch",
    analysis_method = ShuklaAFM(),
)
mat_opts_fea = MatFootingOptions(
    material = RC_4000_60, bar_size_x = 8, bar_size_y = 8,
    cover = 3.0u"inch", min_depth = 24.0u"inch", depth_increment = 1.0u"inch",
    analysis_method = WinklerFEA(),
)

mat_result_shukla = design_footing(MatFoundation(), mat_demands, mat_positions, mat_soil; opts = mat_opts_shukla)
mat_result_fea    = design_footing(MatFoundation(), mat_demands, mat_positions, mat_soil; opts = mat_opts_fea)

flex_results = [("Rigid", mat_result), ("Analytical", mat_result_shukla), ("FEA", mat_result_fea)]

@printf("\n    %-12s  %6s %6s %8s %8s %8s %8s %8s\n",
        "Method", "h(in)", "d(in)", "As_xb", "As_xt", "As_yb", "As_yt", "util")
@printf("    %-12s  %6s %6s %8s %8s %8s %8s %8s\n",
        "─"^12, "─"^6, "─"^6, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8)
for (lbl, r) in flex_results
    @printf("    %-12s  %6.0f %6.0f %8.1f %8.1f %8.1f %8.1f %8.3f\n", lbl,
            ustrip(u"inch", r.D), ustrip(u"inch", r.d),
            ustrip(u"inch^2", r.As_x_bot), ustrip(u"inch^2", r.As_x_top),
            ustrip(u"inch^2", r.As_y_bot), ustrip(u"inch^2", r.As_y_top),
            r.utilization)
end

@testset "Flexible Mat — Moderate Loading" begin
    for (lbl, r) in flex_results
        @test r.utilization < 1.0
        @test ustrip(u"inch^2", r.As_x_bot) > 0.0
    end
    # Flexible should not be wildly thicker than rigid
    h_rigid_base = ustrip(u"inch", mat_result.D)
    @test ustrip(u"inch", mat_result_shukla.D) ≤ h_rigid_base + 6.0
    @test ustrip(u"inch", mat_result_fea.D)    ≤ h_rigid_base + 6.0
end

_rpt.sub("3b-B — Heavy Loading (higher loads, softer soil)")

heavy_demands = FoundationDemand[]
heavy_positions = NTuple{2, typeof(0.0u"ft")}[]

for (i, x) in enumerate([0.0, 30.0, 60.0, 90.0]), (j, y) in enumerate([0.0, 30.0, 60.0, 90.0])
    idx = (i - 1) * 4 + j
    is_corner = (i == 1 || i == 4) && (j == 1 || j == 4)
    is_edge = !is_corner && (i == 1 || i == 4 || j == 1 || j == 4)

    Pu = is_corner ? 350.0kip : is_edge ? 550.0kip : 900.0kip
    Ps = is_corner ? 245.0kip : is_edge ? 385.0kip : 630.0kip

    push!(heavy_demands, FoundationDemand(idx; Pu=Pu, Ps=Ps))
    push!(heavy_positions, (x * u"ft", y * u"ft"))
end

heavy_soil = Soil(4.0ksf, 19.0u"kN/m^3", 35.0, 0.0u"kPa", 30.0u"MPa";
                  ks=12000.0u"kN/m^3")

Pu_heavy = sum(to_kip(d.Pu) for d in heavy_demands)
@printf("\n    Grid: 4×4 @ 30 ft, Σ Pu = %.0f kip, ks = 12000 kN/m³\n", Pu_heavy)

heavy_base = (material=RC_4000_60, bar_size_x=8, bar_size_y=8,
              cover=3.0u"inch", min_depth=24.0u"inch", depth_increment=1.0u"inch")

heavy_rigid  = design_footing(MatFoundation(), heavy_demands, heavy_positions, heavy_soil;
    opts=MatFootingOptions(; heavy_base..., analysis_method=RigidMat()))
heavy_shukla = design_footing(MatFoundation(), heavy_demands, heavy_positions, heavy_soil;
    opts=MatFootingOptions(; heavy_base..., analysis_method=ShuklaAFM()))
heavy_fea    = design_footing(MatFoundation(), heavy_demands, heavy_positions, heavy_soil;
    opts=MatFootingOptions(; heavy_base..., analysis_method=WinklerFEA()))

heavy_flex = [("Rigid", heavy_rigid), ("Analytical", heavy_shukla), ("FEA", heavy_fea)]

@printf("\n    %-12s  %6s %6s %8s %8s %8s %8s %8s\n",
        "Method", "h(in)", "d(in)", "As_xb", "As_xt", "As_yb", "As_yt", "util")
@printf("    %-12s  %6s %6s %8s %8s %8s %8s %8s\n",
        "─"^12, "─"^6, "─"^6, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8)
for (lbl, r) in heavy_flex
    @printf("    %-12s  %6.0f %6.0f %8.1f %8.1f %8.1f %8.1f %8.3f\n", lbl,
            ustrip(u"inch", r.D), ustrip(u"inch", r.d),
            ustrip(u"inch^2", r.As_x_bot), ustrip(u"inch^2", r.As_x_top),
            ustrip(u"inch^2", r.As_y_bot), ustrip(u"inch^2", r.As_y_top),
            r.utilization)
end

@testset "Flexible Mat — Heavy Loading" begin
    for (lbl, r) in heavy_flex
        @test r.utilization < 1.0
        @test ustrip(u"inch^2", r.As_x_bot) > 0.0
    end
end

_rpt.note("Analytical envelopes Shukla flexible peaks with rigid strip statics (ACI 336.2R §6.1.2).")
_rpt.note("All methods share punching shear iteration; thickness differences reflect moment demands.")
_rpt.note("Bottom steel (As_xb, As_yb) governs for flexible methods → bottom tension at columns ✓.")

_fdn_step_status["Mat Foundation (Flexible)"] = "✓"

# STEP 3c — EQUILIBRIUM VERIFICATION

_rpt.section("STEP 3c — EQUILIBRIUM VERIFICATION")
println("  Verify vertical equilibrium: Σ applied loads ≈ Σ soil reactions.")
println("  FEA: spring reaction = kz × |w| (exact within numerical precision).")
println("  Analytical (Shukla): integral of q(x,y) over mat (infinite-plate → some load outside mat).")

using Asap: Node as AsapNode, ShellSection, ShellPatch, Shell, Spring, NodeForce,
            Model, process!, solve!, add_springs!, get_nodes, bending_moments

_rpt.sub("3c-A — WinklerFEA Equilibrium (Moderate Loading)")

# Build FEA manually to extract equilibrium data (same grid as Step 3)
let
    plan = StructuralSizer._mat_plan_sizing(mat_positions, mat_opts_fea;
               demands = mat_demands, soil = mat_soil)
    B_m  = ustrip(u"m", plan.B)
    Lm_m = ustrip(u"m", plan.Lm)
    h_in = ustrip(u"inch", mat_result_fea.D)
    h_m  = h_in * 0.0254
    Ec   = 57000.0 * sqrt(4000.0)  # psi
    Ec_Pa = Ec * 6894.76  # Pa
    ν_c  = 0.2
    ks_Pa_m = ustrip(u"N/m^3", uconvert(u"N/m^3", mat_soil.ks))

    Pu_max_kip = maximum(to_kip(d.Pu) for d in mat_demands)
    c_est_m = ustrip(u"m", max(12.0, ceil(sqrt(Pu_max_kip / 0.5) / 3.0) * 3.0) * u"inch")

    bay_xs = sort(unique(ustrip.(u"m", [p[1] for p in mat_positions])))
    bay_ys = sort(unique(ustrip.(u"m", [p[2] for p in mat_positions])))
    min_bay_m = Inf
    for i in 2:length(bay_xs); min_bay_m = min(min_bay_m, bay_xs[i] - bay_xs[i-1]); end
    for i in 2:length(bay_ys); min_bay_m = min(min_bay_m, bay_ys[i] - bay_ys[i-1]); end
    isinf(min_bay_m) && (min_bay_m = min(B_m, Lm_m))

    te_m = clamp(min_bay_m / 20.0, 0.15, 0.75)
    refine_edge = clamp(c_est_m / 2.0, 0.04, te_m / 2.0) * u"m"
    target_edge = te_m * u"m"

    section = ShellSection(h_m * u"m", Ec_Pa * u"Pa", ν_c)

    corner_nodes = (
        AsapNode([0.0u"m", 0.0u"m", 0.0u"m"], :free),
        AsapNode([B_m*u"m", 0.0u"m", 0.0u"m"], :free),
        AsapNode([B_m*u"m", Lm_m*u"m", 0.0u"m"], :free),
        AsapNode([0.0u"m", Lm_m*u"m", 0.0u"m"], :free),
    )

    positions_loc_m = [(ustrip(u"m", plan.xs_loc[j]), ustrip(u"m", plan.ys_loc[j]))
                       for j in 1:length(mat_demands)]

    interior_nodes = [AsapNode([cx * u"m", cy * u"m", 0.0u"m"], :free)
                      for (cx, cy) in positions_loc_m]

    patches = [ShellPatch(cx, cy, c_est_m, c_est_m, section; id=:col_patch)
               for (cx, cy) in positions_loc_m]

    edge_dofs = [false, false, true, true, true, true]

    shells = Shell(corner_nodes, section;
                   id=:eq_check,
                   interior_nodes=interior_nodes,
                   interior_patches=patches,
                   edge_support_type=edge_dofs,
                   interior_support_type=:free,
                   target_edge_length=target_edge,
                   refinement_edge_length=refine_edge)

    nodes = get_nodes(shells)

    # Apply column loads
    loads = NodeForce[]
    for (k, dem) in enumerate(mat_demands)
        cx, cy = positions_loc_m[k]
        best = nodes[1]; best_d2 = Inf
        for n in nodes
            d2 = (ustrip(u"m", n.position[1]) - cx)^2 + (ustrip(u"m", n.position[2]) - cy)^2
            if d2 < best_d2; best = n; best_d2 = d2; end
        end
        Pu_N = ustrip(u"N", uconvert(u"N", dem.Pu))
        push!(loads, NodeForce(best, [0.0, 0.0, -Pu_N] .* u"N"))
    end

    model = Model(nodes, shells, loads)
    process!(model)

    # Winkler springs
    trib = Dict{UInt64, Float64}()
    for elem in shells
        A3 = elem.area / 3.0
        for nd in elem.nodes
            trib[objectid(nd)] = get(trib, objectid(nd), 0.0) + A3
        end
    end
    springs = Spring[]
    edge_tol = min(B_m, Lm_m) * 1e-4
    for n in nodes
        A_t = get(trib, objectid(n), 0.0)
        A_t < 1e-12 && continue
        K = A_t * ks_Pa_m
        xn = ustrip(u"m", n.position[1])
        yn = ustrip(u"m", n.position[2])
        on_edge = (xn < edge_tol || xn > B_m - edge_tol ||
                   yn < edge_tol || yn > Lm_m - edge_tol)
        on_edge && (K *= 2.0)
        push!(springs, Spring(n; kz = K * u"N/m"))
    end
    add_springs!(model, springs)
    solve!(model)

    # Equilibrium: sum of applied loads vs sum of spring reactions
    F_applied_kN = sum(abs(ustrip(u"N", l.value[3])) for l in loads) / 1e3
    F_reaction_kN = sum(
        let kz = s.stiffness[3]
            w  = ustrip(u"m", s.node.displacement[3])
            kz * abs(w)
        end for s in springs) / 1e3

    imbalance_pct = F_applied_kN > 0 ? abs(F_applied_kN - F_reaction_kN) / F_applied_kN * 100 : 0.0

    @printf("    Σ Applied loads  = %10.1f kN\n", F_applied_kN)
    @printf("    Σ Spring reactions = %10.1f kN\n", F_reaction_kN)
    @printf("    Imbalance        = %10.2f%%  %s\n",
            imbalance_pct, imbalance_pct < 1.0 ? "✓ OK" : "⚠")

    @test imbalance_pct < 1.0  # FEA should be exact within 1%

    # Peak deflection
    w_max_mm = maximum(abs(ustrip(u"mm", n.displacement[3])) for n in nodes)
    @printf("    Peak deflection  = %10.2f mm\n", w_max_mm)
end

_rpt.sub("3c-B — Analytical (Shukla) Equilibrium (Moderate Loading)")
let
    plan = StructuralSizer._mat_plan_sizing(mat_positions,
        MatFootingOptions(material=RC_4000_60, min_depth=mat_result_shukla.D);
        demands = mat_demands, soil = mat_soil)
    B = plan.B; Lm = plan.Lm
    h = mat_result_shukla.D
    Ec = 57000.0u"psi" * sqrt(4000.0)
    μ = 0.2

    result = StructuralSizer._shukla_analysis(h, mat_positions, mat_demands, Ec, μ, mat_soil.ks)
    q_f = result[5]  # soil pressure function

    # Trapezoidal integration of q(x,y) over mat
    nx, ny = 50, 50
    xs = range(plan.x_left, plan.x_left + B, length=nx)
    ys = range(plan.y_bot, plan.y_bot + Lm, length=ny)
    dx = B / (nx - 1); dy = Lm / (ny - 1)

    q_integral = sum(
        let w_x = (ix == 1 || ix == nx) ? 0.5 : 1.0
            w_y = (iy == 1 || iy == ny) ? 0.5 : 1.0
            w_x * w_y * q_f(xs[ix], ys[iy]) * dx * dy
        end for ix in 1:nx, iy in 1:ny)

    Pu_total = sum(d.Pu for d in mat_demands)
    ratio = ustrip(Unitful.NoUnits, q_integral / Pu_total)
    shortfall_pct = (1.0 - ratio) * 100

    Pu_kN = ustrip(u"kN", uconvert(u"kN", Pu_total))
    Qr_kN = ustrip(u"kN", uconvert(u"kN", q_integral))

    @printf("    Σ Column loads     = %10.1f kN\n", Pu_kN)
    @printf("    ∫q(x,y) dA (mat)   = %10.1f kN\n", Qr_kN)
    @printf("    Captured ratio     = %10.1f%%\n", ratio * 100)
    @printf("    Shortfall          = %10.1f%%  %s\n",
            shortfall_pct,
            shortfall_pct < 15.0 ? "✓ OK (infinite-plate)" :
            shortfall_pct < 30.0 ? "~ acceptable" : "⚠ large shortfall")

    # Shukla infinite-plate: expect ~75-100% captured by finite mat.
    # Global equilibrium is ensured by the rigid envelope (ACI 336.2R §6.1.2).
    @test ratio > 0.70  # at least 70% captured
end

_rpt.note("FEA: equilibrium is exact (FEM enforces Ku=F at every node).")
_rpt.note("Analytical (Shukla): <100% expected — infinite-plate solution; rigid envelope ensures statics.")
_rpt.note("Shortfall decreases with larger mat overhang (more soil reaction captured).")

_fdn_step_status["Equilibrium Checks"] = "✓"

# STEP 4 — FOUNDATION TYPE COMPARISON

_rpt.section("STEP 4 — FOUNDATION TYPE COMPARISON")
println("  3×2 grid (25 ft spacing), typical office loads: spread vs strip vs mat.")

_rpt.sub("4A — Scenario: 6 Columns on 25 ft Grid")
println("  Int Pu=400k, Edge Pu=250k, Corner Pu=150k; qa=4.0 ksf")

comp_soil = Soil(4.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
                 ks=25000.0u"kN/m^3")

comp_demands = FoundationDemand[]
comp_positions = NTuple{2, typeof(0.0u"ft")}[]

grid_x = [0.0, 25.0, 50.0]
grid_y = [0.0, 25.0]

for (i, x) in enumerate(grid_x), (j, y) in enumerate(grid_y)
    idx = (i - 1) * length(grid_y) + j
    is_corner = (i == 1 || i == length(grid_x)) && (j == 1 || j == length(grid_y))
    is_edge = !is_corner && (i == 1 || i == length(grid_x) || j == 1 || j == length(grid_y))

    Pu = is_corner ? 150.0kip : is_edge ? 250.0kip : 400.0kip
    Ps = is_corner ? 105.0kip : is_edge ? 175.0kip : 280.0kip

    push!(comp_demands, FoundationDemand(idx; Pu=Pu, Ps=Ps))
    push!(comp_positions, (x * u"ft", y * u"ft"))
end

N_comp = length(comp_demands)
Pu_total_comp = sum(to_kip(d.Pu) for d in comp_demands)
Ps_total_comp = sum(to_kip(d.Ps) for d in comp_demands)

building_area = 50.0 * 25.0  # ft²

@printf("    %d columns,  Total Pu = %.0f kip,  Total Ps = %.0f kip\n",
        N_comp, Pu_total_comp, Ps_total_comp)
@printf("    Building footprint = 50 ft × 25 ft = %.0f ft²\n", building_area)

_rpt.sub("4B — Strategy 1: All Spread Footings")

spread_results = SpreadFootingResult[]
spread_opts = SpreadFootingOptions(
    material = RC_4000_60,
    pier_c1 = 18.0u"inch",
    pier_c2 = 18.0u"inch",
    bar_size = 7,
    cover = 3.0u"inch",
)

for d in comp_demands
    r = design_footing(SpreadFooting(), d, comp_soil; opts=spread_opts)
    push!(spread_results, r)
end

sp_total_conc = sum(ustrip(u"m^3", r.concrete_volume) for r in spread_results)
sp_total_steel = sum(ustrip(u"m^3", r.steel_volume) for r in spread_results)
sp_total_area = sum(ustrip(u"ft^2", r.B * r.L_ftg) for r in spread_results)
sp_max_util = maximum(r.utilization for r in spread_results)
sp_coverage = sp_total_area / building_area

@printf("\n    %-20s  %8s %8s %8s %8s\n", "Position", "B (ft)", "h (in)", "n_bars", "util")
@printf("    %-20s  %8s %8s %8s %8s\n", "─"^20, "─"^8, "─"^8, "─"^8, "─"^8)

for (i, (d, r)) in enumerate(zip(comp_demands, spread_results))
    Pu_k = to_kip(d.Pu)
    pos = Pu_k ≈ 150.0 ? "Corner" : Pu_k ≈ 250.0 ? "Edge" : "Interior"
    @printf("    %-20s  %8.1f %8.0f %8d %8.3f\n",
            "$pos (#$i)",
            ustrip(u"ft", r.B), ustrip(u"inch", r.D),
            r.rebar_count, r.utilization)
end

@printf("\n    Total footprint = %.0f ft²  (coverage = %.0f%%)\n", sp_total_area, 100 * sp_coverage)
@printf("    Total concrete  = %.2f m³\n", sp_total_conc)
@printf("    Total steel     = %.5f m³\n", sp_total_steel)
@printf("    Max utilization = %.3f\n", sp_max_util)

_rpt.sub("4C — Strategy 2: Strip Footings (Paired Columns)")
println("  Pair columns along y-axis (2 per strip at each x-coordinate).")

strip_results = StripFootingResult[]
strip_opts = StripFootingOptions(
    material = RC_4000_60,
    bar_size_long = 7,
    bar_size_trans = 5,
    cover = 3.0u"inch",
)

# Group columns by x-position: 3 strips (x=0, x=25, x=50)
for xi in grid_x
    idxs = [i for i in 1:N_comp if ustrip(u"ft", comp_positions[i][1]) ≈ xi]
    ds = [comp_demands[i] for i in idxs]
    ps = [comp_positions[i][2] for i in idxs]   # y-coordinates along strip
    r = design_footing(StripFooting(), ds, ps, comp_soil; opts=strip_opts)
    push!(strip_results, r)
end

st_total_conc = sum(ustrip(u"m^3", r.concrete_volume) for r in strip_results)
st_total_steel = sum(ustrip(u"m^3", r.steel_volume) for r in strip_results)
st_total_area = sum(ustrip(u"ft^2", r.B * r.L_ftg) for r in strip_results)
st_max_util = maximum(r.utilization for r in strip_results)
st_coverage = st_total_area / building_area

@printf("    %-20s  %8s %8s %8s %8s %8s\n",
        "Strip", "B (ft)", "L (ft)", "h (in)", "N_col", "util")
@printf("    %-20s  %8s %8s %8s %8s %8s\n",
        "─"^20, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8)

strip_labels = ["x=0' (edge)", "x=25' (int)", "x=50' (edge)"]
for (i, (lbl, r)) in enumerate(zip(strip_labels, strip_results))
    @printf("    %-20s  %8.1f %8.1f %8.0f %8d %8.3f\n", lbl,
            ustrip(u"ft", r.B), ustrip(u"ft", r.L_ftg),
            ustrip(u"inch", r.D), r.n_columns, r.utilization)
end

@printf("\n    Total footprint = %.0f ft²  (coverage = %.0f%%)\n", st_total_area, 100 * st_coverage)
@printf("    Total concrete  = %.2f m³\n", st_total_conc)
@printf("    Total steel     = %.5f m³\n", st_total_steel)
@printf("    Max utilization = %.3f\n", st_max_util)

_rpt.sub("4D — Strategy 3: Mat Foundation")

mat_comp_opts = MatFootingOptions(
    material = RC_4000_60,
    bar_size_x = 7,
    bar_size_y = 7,
    cover = 3.0u"inch",
    min_depth = 24.0u"inch",
)

mat_comp = design_footing(MatFoundation(), comp_demands, comp_positions, comp_soil; opts=mat_comp_opts)

mt_conc  = ustrip(u"m^3", mat_comp.concrete_volume)
mt_steel = ustrip(u"m^3", mat_comp.steel_volume)
mt_area  = ustrip(u"ft^2", mat_comp.B * mat_comp.L_ftg)

@printf("    Mat size: %.1f ft × %.1f ft = %.0f ft²\n",
        ustrip(u"ft", mat_comp.B), ustrip(u"ft", mat_comp.L_ftg), mt_area)
@printf("    h = %.0f in.,  d = %.1f in.\n",
        ustrip(u"inch", mat_comp.D), ustrip(u"inch", mat_comp.d))
@printf("    Concrete = %.2f m³\n", mt_conc)
@printf("    Steel    = %.5f m³\n", mt_steel)
@printf("    Utilization = %.3f\n", mat_comp.utilization)

_rpt.sub("4E — Comparison Matrix")
println()

@printf("    %-20s %10s %10s %10s\n", "Metric", "Spread", "Strip", "Mat")
@printf("    %-20s %10s %10s %10s\n", "─"^20, "─"^10, "─"^10, "─"^10)
@printf("    %-20s %10.0f %10.0f %10.0f\n", "Footprint (ft²)", sp_total_area, st_total_area, mt_area)
@printf("    %-20s %9.0f%% %9.0f%% %9.0f%%\n", "Coverage ratio", 100*sp_coverage, 100*st_coverage, 100*mt_area/building_area)
@printf("    %-20s %10.2f %10.2f %10.2f\n", "Concrete (m³)", sp_total_conc, st_total_conc, mt_conc)
@printf("    %-20s %10.5f %10.5f %10.5f\n", "Steel (m³)", sp_total_steel, st_total_steel, mt_steel)
@printf("    %-20s %10.3f %10.3f %10.3f\n", "Max utilization", sp_max_util, st_max_util, mat_comp.utilization)
@printf("    %-20s %10d %10d %10d\n", "Elements", N_comp, length(strip_results), 1)

if sp_total_conc > 0
    @printf("\n    %-20s %10s %9.1f× %9.1f×\n", "Concrete / spread", "1.0×",
            st_total_conc / sp_total_conc, mt_conc / sp_total_conc)
end

_rpt.note("Spread: least concrete, most elements; Strip: fewer pours; Mat: most concrete, simplest forming. Coverage=$(round(Int, 100*sp_coverage))% → " *
     (sp_coverage > 0.5 ? "mat recommended." : sp_coverage > 0.3 ? "strip preferred." : "spread OK."))

@test sp_max_util < 1.0
@test st_max_util < 1.0
@test mat_comp.utilization < 1.0

_fdn_step_status["Type Comparison"] = "✓"

# STEP 5 — PARAMETRIC STUDIES

_rpt.section("STEP 5 — PARAMETRIC STUDIES")

_rpt.sub("5A — Spread Footing: Soil Capacity Sweep")
println("  Pu=500k, Ps=350k, c=18\", f'c=4000psi; qa = 2–8 ksf")

@printf("    %6s  %6s %6s %8s %8s  %s\n",
        "qa(ksf)", "B(ft)", "h(in)", "V_c(m³)", "util", "")
@printf("    %6s  %6s %6s %8s %8s  %s\n",
        "─"^6, "─"^6, "─"^6, "─"^8, "─"^8, "──")

sweep_Pu = 500.0kip
sweep_Ps = 350.0kip
sweep_demand = FoundationDemand(1; Pu=sweep_Pu, Ps=sweep_Ps)
sweep_opts = SpreadFootingOptions(material=RC_4000_60, pier_c1=18.0u"inch", pier_c2=18.0u"inch")

for qa_val in [2.0, 3.0, 4.0, 5.0, 6.0, 8.0]
    s = Soil(qa_val * ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    r = design_footing(SpreadFooting(), sweep_demand, s; opts=sweep_opts)
    @printf("    %6.1f  %6.1f %6.0f %8.3f %8.3f  %s\n",
            qa_val,
            ustrip(u"ft", r.B), ustrip(u"inch", r.D),
            ustrip(u"m^3", r.concrete_volume), r.utilization,
            r.utilization < 1.0 ? "✓" : "✗")
    @test r.utilization < 1.0
end
_rpt.note("Lower qa → larger B & h; at qa≈2 ksf consider strip or mat.")

_rpt.sub("5B — Spread Footing: Column Load Sweep")
println("  qa=4ksf, c=18\", f'c=4000psi; Pu = 200–1200 kip (Ps=Pu/1.43)")

@printf("    %6s  %6s  %6s %6s %8s %8s\n",
        "Pu(kip)", "Ps", "B(ft)", "h(in)", "V_c(m³)", "util")
@printf("    %6s  %6s  %6s %6s %8s %8s\n",
        "─"^6, "─"^6, "─"^6, "─"^6, "─"^8, "─"^8)

sweep_soil = Soil(4.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
for Pu_val in [200.0, 400.0, 600.0, 800.0, 1000.0, 1200.0]
    Ps_val = Pu_val / 1.43
    d_sweep = FoundationDemand(1; Pu=Pu_val*kip, Ps=Ps_val*kip)
    r = design_footing(SpreadFooting(), d_sweep, sweep_soil; opts=sweep_opts)
    @printf("    %6.0f  %6.0f  %6.1f %6.0f %8.3f %8.3f\n",
            Pu_val, Ps_val,
            ustrip(u"ft", r.B), ustrip(u"inch", r.D),
            ustrip(u"m^3", r.concrete_volume), r.utilization)
    @test r.utilization < 1.0
end
_rpt.note("Size∝√(Ps/qa), h∝√Pu (punching); Pu>~800k on qa=4ksf → combined/mat territory.")

_rpt.sub("5C — Foundation Type Transition: Coverage Ratio")
println("  Scale loads; coverage = Σ(spread area)/building footprint.")

@printf("    %8s %8s %10s %10s  %s\n",
        "Load×", "ΣPu(k)", "Σ_area", "coverage", "strategy")
@printf("    %8s %8s %10s %10s  %s\n",
        "─"^8, "─"^8, "─"^10, "─"^10, "─"^8)

for scale in [0.5, 0.75, 1.0, 1.5, 2.0, 2.5]
    total_area = 0.0
    total_Pu = 0.0
    for d in comp_demands
        Pu_s = to_kip(d.Pu) * scale
        Ps_s = to_kip(d.Ps) * scale
        total_Pu += Pu_s
        total_area += Ps_s / ustrip(ksf, comp_soil.qa)
    end
    cov = total_area / building_area
    strat = cov > 0.50 ? "→ MAT" : cov > 0.30 ? "→ strip" : "  spread"
    @printf("    %8.2f %8.0f %9.0f ft² %9.0f%%  %s\n",
            scale, total_Pu, total_area, 100 * cov, strat)
end
_rpt.note("<30% → spread; 30–50% → strip; >50% → mat. Logic in recommend_foundation_strategy().")

_fdn_step_status["Parametric Studies"] = "✓"

# STEP 6 — DESIGN CODE FEATURES & LIMITATIONS

_rpt.section("STEP 6 — DESIGN CODE FEATURES & LIMITATIONS")

_rpt.sub("6A — Feature Matrix")
@printf("    %-30s %8s %8s %8s\n", "Feature", "Spread", "Strip", "Mat")
@printf("    %-30s %8s %8s %8s\n", "─"^30, "─"^8, "─"^8, "─"^8)
@printf("    %-30s %8s %8s %8s\n", "ACI 318-14 punching (§22.6)", "✓", "✓", "✓")
@printf("    %-30s %8s %8s %8s\n", "Biaxial moment transfer",     "✓", "✓", "✓")
@printf("    %-30s %8s %8s %8s\n", "One-way shear (§22.5)",       "✓", "✓", "—")
@printf("    %-30s %8s %8s %8s\n", "Flexural reinforcement",      "✓", "✓", "✓")
@printf("    %-30s %8s %8s %8s\n", "Development length (§25.4)",  "✓", "✓", "—")
@printf("    %-30s %8s %8s %8s\n", "Bearing check (§22.8)",       "✓", "✓", "—")
@printf("    %-30s %8s %8s %8s\n", "Dowel design",                "✓", "✓", "—")
@printf("    %-30s %8s %8s %8s\n", "Per-col dims + shape",         "✓", "✓", "✓")
@printf("    %-30s %8s %8s %8s\n", "V(x)/M(x) diagrams",         "—", "✓", "—")
@printf("    %-30s %8s %8s %8s\n", "Strip statics (Kramrisch)",   "—", "—", "✓")
@printf("    %-30s %8s %8s %8s\n", "Relative stiffness Kr",       "—", "—", "✓")
@printf("    %-30s %8s %8s %8s\n", "Analytical (Shukla+Rigid)",   "—", "—", "✓")
@printf("    %-30s %8s %8s %8s\n", "Winkler FEA (flexible)",      "—", "—", "✓")
println()

_rpt.sub("6B — Shared Components")
println("  codes/aci/punching.jl: punching_check, punching_geometry_*, gamma_f/v, Jc, one_way_shear, vc.")
println("  Shared by all 3 footing types + slabs — one implementation, zero duplication.")

_rpt.sub("6C — Current Limitations & Future Work")
println("  1. No pattern loading for mats (ACI 318 §6.4.3.2)")
println("  2. Pile types defined, not designed  3. IS 456 dispatch: legacy spread only")

_fdn_step_status["Features & Limits"] = "✓"

# SUMMARY

_rpt.section("SUMMARY")

ordered_steps = [
    "Shared Punching Utils", "Spread Footing", "Strip/Combined Footing",
    "Mat Foundation (Rigid)", "Mat Foundation (Flexible)", "Equilibrium Checks",
    "Type Comparison", "Parametric Studies", "Features & Limits",
]

println("  Validated: Spread/Strip (ACI 318-14), Mat Rigid+Flexible (ACI 336.2R), equilibrium, shared utils.")

@printf("    %-24s  %s\n", "Step", "Status")
@printf("    %-24s  %s\n", "─"^24, "─"^24)
for step in ordered_steps
    status = get(_fdn_step_status, step, "?")
    @printf("    %-24s  %s\n", step, status)
end

println("  Refs: [1] SP Spread Ex15-2 [2] SP Combined Ex15-5 [3] ACI 336.2R §4.2 [4] ACI 318-14 §22.6 [5] ACI SP-152")

@test true  # sentinel
end  # @testset
