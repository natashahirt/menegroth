# =============================================================================
# Integration Test: Flat Plate EFM Pipeline — StructurePoint Validation Report
# =============================================================================
#
# This test traces every step of the EFM calculation chain, printing a
# human-readable report that compares each intermediate result against the
# StructurePoint reference values.
#
# Reference: DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14
#            StructurePoint spSlab v10.00
#
# Geometry (3-span × 2-bay flat plate floor):
#   - Interior equivalent frame in E-W direction
#   - Span l1 = 18 ft (E-W)    Tributary width l2 = 14 ft (N-S)
#   - Column: 16" × 16" square  Story height: 9 ft
#   - Slab: 7 in (SP result)
#
# Loads:  SDL = 20 psf   LL = 50 psf   qu = 193 psf (factored, SP given)
#
# SP Reference Values:
#   - Stiffnesses:  SP Table 2 (section properties and EFM stiffnesses)
#   - M₀:          ACI 8.10.3.2 (qu × l₂ × ln² / 8 = 93.82 k-ft)
#   - EFM moments:  SP Table 5 (centerline), Table 6 (face-of-support)
#   - Reinforcement: SP Table 7 (face-of-support column-strip, b=84 in, d=5.75 in)
# =============================================================================

using Test
using Printf
using Unitful
using Unitful: @u_str
using Asap

using Logging

using StructuralSizer
using StructuralSynthesizer

# ─────────────────────────────────────────────────────────────────────────────
# Report helpers
# ─────────────────────────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "..", "..", "shared", "report_helpers.jl"))
const _rpt = ReportHelpers.Printer()

function table_head()
    @printf("    %-30s %12s %12s %8s %s\n",
            "Quantity", "Computed", "SP Ref", "Δ%", "")
    @printf("    %-30s %12s %12s %8s %s\n",
            "─"^30, "─"^12, "─"^12, "─"^8, "──")
end

"""
Print one comparison row.  Returns `true` when |δ| ≤ tol.
The Δ% is signed so you can see over (+) vs under (−).
"""
function compare(label, computed, reference, unit; tol=0.05)
    v = ustrip(unit, computed)
    r = ustrip(unit, reference)
    δ = (v - r) / max(abs(r), 1e-12)
    ok = abs(δ) ≤ tol
    flag = ok ? "✓" : (abs(δ) ≤ 2tol ? "~" : "✗")
    @printf("    %-30s %12.2f %12.2f %+7.1f%%  %s\n", label, v, r, 100δ, flag)
    return ok
end

# Track per-step status for the final summary table
const _step_status = Dict{String,String}()

# ─────────────────────────────────────────────────────────────────────────────
# Inputs & SP Reference
# ─────────────────────────────────────────────────────────────────────────────

@testset "Flat Plate & Flat Slab — Design Validation" begin

_rpt.section("FLAT PLATE & FLAT SLAB DESIGN VALIDATION")
println("  Ref: DE-Two-Way-Flat-Plate (ACI 318-14), spSlab v10.00")
println("  Flat slab (drop panel) provisions per ACI 318-19 §8.2.4")

# ── Geometry ──
l1    = 18.0u"ft"
l2    = 14.0u"ft"
c_col = 16.0u"inch"
H     = 9.0u"ft"
h     = 7.0u"inch"

# ── Loads ──
sdl = 20.0u"psf"
ll  = 50.0u"psf"
qu  = 193.0u"psf"       # SP given factored load

# ── Materials ──
fc_slab = 4000u"psi"
fc_col  = 6000u"psi"
fy      = 60u"ksi"
wc      = 150.0                                             # pcf
Ecs     = wc^1.5 * 33 * sqrt(ustrip(u"psi", fc_slab)) * u"psi"
Ecc     = wc^1.5 * 33 * sqrt(ustrip(u"psi", fc_col)) * u"psi"

# ── Derived geometry ──
ln = l1 - c_col  # clear span

_rpt.sub("INPUT SUMMARY")
@printf("    Panel:         l₁ = %-8s  l₂ = %s\n", l1, l2)
@printf("    Column:        %s × %s (square)\n", c_col, c_col)
@printf("    Story height:  H  = %s\n", H)
@printf("    Slab:          h  = %s\n", h)
@printf("    Clear span:    lₙ = l₁ − c = %.3f ft\n", ustrip(u"ft", ln))
println()
@printf("    Loads:         SDL = %-8s  LL = %-8s  qᵤ = %s\n", sdl, ll, qu)
@printf("    f'c (slab) = %-10s  f'c (col) = %-10s  fy = %s\n", fc_slab, fc_col, fy)
@printf("    Ec  (slab) = %.0f psi    Ec  (col) = %.0f psi\n",
        ustrip(u"psi", Ecs), ustrip(u"psi", Ecc))

# ── SP reference values ──
# Section properties & stiffnesses: SP Table 2 (exact formulas)
# M₀: ACI 8.10.3.2 formula (qu × l₂ × ln² / 8)
# EFM moments: SP Table 5 (centerline) → Table 6 (face-of-support)
# Column-strip moments & As: SP Table 7 (face-of-support, b=84 in, d=5.75 in)
sp = (
    # Table 2 — Section properties
    Is  = 4802u"inch^4",           Ic  = 5461u"inch^4",
    C   = 1325u"inch^4",
    # Table 2 — EFM stiffnesses
    Ksb = 351.77e6u"lbf*inch",     Kc  = 1125.59e6u"lbf*inch",
    Kt  = 367.48e6u"lbf*inch",     Kec = 554.07e6u"lbf*inch",
    # ACI 8.10.3.2
    M0  = 93.82u"kip*ft",
    # Table 5 — EFM centerline moments (end span, full frame width)
    M_neg_ext = 46.65u"kip*ft",    M_pos = 44.94u"kip*ft",
    M_neg_int = 83.91u"kip*ft",
    # Table 7 — Face-of-support column-strip moments & reinforcement
    M_neg_ext_cs = 32.42u"kip*ft", M_pos_cs     = 26.96u"kip*ft",
    M_neg_int_cs = 50.24u"kip*ft",
    As_neg_ext_cs = 1.28u"inch^2", As_pos_cs     = 1.06u"inch^2",
    As_neg_int_cs = 2.02u"inch^2",
)

# ── FEA MODEL — build once, use throughout ──
fea_struc = with_logger(NullLogger()) do
    _skel = gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
    _struc = BuildingStructure(_skel)
    _opts = FlatPlateOptions(
        material = RC_4000_60,
        method = FEA(),
        cover = 0.75u"inch",
        bar_size = 5,
    )
    initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c_fea in _struc.cells
        c_fea.sdl = uconvert(u"kN/m^2", sdl)
        c_fea.live_load = uconvert(u"kN/m^2", ll)
    end
    for col_fea in _struc.columns
        col_fea.c1 = 16.0u"inch"
        col_fea.c2 = 16.0u"inch"
    end
    to_asap!(_struc)
    _struc
end

fea_slab = fea_struc.slabs[1]
fea_cell_set = Set(fea_slab.cell_indices)
fea_columns = StructuralSizer.find_supporting_columns(fea_struc, fea_cell_set)

fea_fc = 4000.0u"psi"
fea_γ  = RC_4000_60.concrete.ρ
fea_ν  = RC_4000_60.concrete.ν
fea_wc = ustrip(StructuralSizer.pcf, fea_γ)
fea_Ecs = StructuralSizer.Ec(fea_fc, fea_wc)

fea_result = StructuralSizer.run_moment_analysis(
    StructuralSizer.FEA(), fea_struc, fea_slab, fea_columns,
    h, fea_fc, fea_Ecs, fea_γ; ν_concrete=fea_ν, verbose=false
)

# Extract FEA scalars for use throughout the report
M0_fea        = ustrip(u"kip*ft", fea_result.M0)
M_neg_ext_fea = ustrip(u"kip*ft", fea_result.M_neg_ext)
M_pos_fea     = ustrip(u"kip*ft", fea_result.M_pos)
M_neg_int_fea = ustrip(u"kip*ft", fea_result.M_neg_int)
qu_fea_psf    = ustrip(u"psf", fea_result.qu)
l1_fea_ft     = ustrip(u"ft", fea_result.l1)
l2_fea_ft     = ustrip(u"ft", fea_result.l2)
ln_fea_ft     = ustrip(u"ft", fea_result.ln)

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0  Load Baseline — SP Given vs FEA Computed
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 0 — LOAD BASELINE: SP vs FEA")
println("  SP qᵤ=193 psf (given). Computed: 1.2(SDL+SW)+1.6(LL).")

# Compute SW using traditional 150 pcf and NWC_4000 density (2380 kg/m³ ≈ 148.6 pcf)
γ_150 = 150.0u"pcf"
γ_mat = RC_4000_60.concrete.ρ
γ_mat_pcf = ustrip(StructuralSizer.pcf, γ_mat)

sw_150 = StructuralSizer.slab_self_weight(h, γ_150)
sw_mat = StructuralSizer.slab_self_weight(h, γ_mat)

qD_150 = sdl + sw_150
qD_mat = sdl + sw_mat
qu_150 = 1.2 * qD_150 + 1.6 * ll
qu_mat = 1.2 * qD_mat + 1.6 * ll

println("    Computed qᵤ by density:")
@printf("    a) wc = 150 pcf (ACI traditional):  SW = %.1f psf → qᵤ = %.0f psf\n",
        ustrip(u"psf", sw_150), ustrip(u"psf", qu_150))
@printf("    b) wc = %.1f pcf (NWC_4000 ρ):     SW = %.1f psf → qᵤ = %.0f psf  ← FEA uses this\n",
        γ_mat_pcf, ustrip(u"psf", sw_mat), ustrip(u"psf", qu_mat))
println()

@printf("    %-20s %10s %10s %10s\n", "", "SP Given", "150 pcf", "NWC_4000")
@printf("    %-20s %10s %10s %10s\n", "─"^20, "─"^10, "─"^10, "─"^10)
@printf("    %-20s %10.0f %10.0f %10.0f\n", "qᵤ (psf)", ustrip(u"psf", qu), ustrip(u"psf", qu_150), qu_fea_psf)
println()

M0_sp_kf = ustrip(u"kip*ft", sp.M0)
@printf("    %-20s %10s %10s %10s\n", "", "SP (M₀)", "FEA (M₀)", "FEA span")
@printf("    %-20s %10s %10s %10s\n", "─"^20, "─"^10, "─"^10, "─"^10)
@printf("    %-20s %10.2f %10.2f %s\n", "M₀ (kip·ft)", M0_sp_kf, M0_fea,
        @sprintf("l₁=%.0f′ l₂=%.0f′ lₙ=%.1f′", l1_fea_ft, l2_fea_ft, ln_fea_ft))
println()

_rpt.note("SP qᵤ lower than computed — likely different SW assumption. All methods share l₁, l₂, M₀ baseline.")

@test qu_fea_psf > 0
@test M0_fea > 0
_step_status["Load Baseline"] = "✓"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1  Section Properties (SP Table 2, left columns)
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 1 — SECTION PROPERTIES  (SP Table 2)")
println("  Is = l₂·h³/12,  Ic = c₁·c₂³/12,  C = Σ(1−0.63x/y)x³y/3 (ACI 8.10.5.2)")

Is = StructuralSizer.slab_moment_of_inertia(l2, h)
Ic = StructuralSizer.column_moment_of_inertia(c_col, c_col)
C  = StructuralSizer.torsional_constant_C(h, c_col)

table_head()
ok1 = compare("Is  (slab I)",      Is, sp.Is, u"inch^4"; tol=0.01)
ok2 = compare("Ic  (column I)",    Ic, sp.Ic, u"inch^4"; tol=0.01)
ok3 = compare("C   (torsional)",   C,  sp.C,  u"inch^4"; tol=0.05)

@test ok1;  @test ok2;  @test ok3
_step_status["Section Properties"] = all((ok1, ok2, ok3)) ? "✓" : "✗"

_rpt.note("C tolerance wider — SP may use different rectangle decomposition for torsional strip.")

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2  EFM Stiffnesses (SP Table 2, right columns)
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 2 — EFM STIFFNESSES  (SP Table 2)")
println("  Ksb (PCA A7), Kc, Kt, Kec = 1/(1/ΣKc+1/ΣKt).  Interior: ΣKc=2Kc, ΣKt=2Kt.")

Ksb = StructuralSizer.slab_beam_stiffness_Ksb(Ecs, Is, l1, c_col, c_col)
Kc  = StructuralSizer.column_stiffness_Kc(Ecc, Ic, H, h)
Kt  = StructuralSizer.torsional_member_stiffness_Kt(Ecs, C, l2, c_col)
Kec = StructuralSizer.equivalent_column_stiffness_Kec(2Kc, 2Kt)

table_head()
ok1 = compare("Ksb (slab-beam)",      Ksb, sp.Ksb, u"lbf*inch"; tol=0.01)
ok2 = compare("Kc  (column)",         Kc,  sp.Kc,  u"lbf*inch"; tol=0.01)
ok3 = compare("Kt  (torsional)",      Kt,  sp.Kt,  u"lbf*inch"; tol=0.01)
ok4 = compare("Kec (equiv. column)",  Kec, sp.Kec, u"lbf*inch"; tol=0.01)

@test ok1;  @test ok2;  @test ok3;  @test ok4
_step_status["EFM Stiffnesses"] = all((ok1, ok2, ok3, ok4)) ? "✓" : "✗"

αec = ustrip(u"lbf*inch", Kec) / (2 * ustrip(u"lbf*inch", Ksb))
@printf("\n    αec = Kec / ΣKsb = %.3f\n", αec)
_rpt.note("αec < 1 → 'soft' column; slab attracts more moment at support.")

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3  Total Static Moment (ACI 8.10.3.2)
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 3 — TOTAL STATIC MOMENT  (ACI 8.10.3.2)")
println("  M₀ = qᵤ·l₂·lₙ²/8")

M0 = StructuralSizer.total_static_moment(qu, l2, ln)

table_head()
ok_m0 = compare("M₀ (static moment)", M0, sp.M0, u"kip*ft"; tol=0.01)
@test ok_m0
_step_status["Static Moment"] = ok_m0 ? "✓" : "✗"

_rpt.note("One EFM strip (l₂=$l2). FEA M₀ = $(@sprintf("%.2f", M0_fea)) kip·ft (slightly different qᵤ).")

# ── STEP 4 — Method Comparison (DDM / MDDM / EFM / FEA) ──

_rpt.section("STEP 4 — METHOD COMPARISON: DDM vs MDDM vs EFM vs FEA")

l2_l1 = round(ustrip(u"ft", l2) / ustrip(u"ft", l1), digits=2)
println("  l₂/l₁ = $l2_l1   (αf = 0, no beams, no edge beam)")
println()

# ── 4A: DDM hand-calc (ACI Table 8.10.4.2 coefficients × M₀) ──
_rpt.sub("4A — DDM Hand-Calc (ACI Table 8.10.4.2)")
println("  Longitudinal coefficients × M₀ (end span, no edge beam):")

M_neg_ext_ddm = 0.26 * M0
M_pos_ddm     = 0.52 * M0
M_neg_int_ddm = 0.70 * M0

@printf("    %-24s %6s %12s\n", "Location", "Coeff", "kip·ft")
@printf("    %-24s %6s %12s\n", "─"^24, "─"^6, "─"^12)
@printf("    %-24s %6.2f %12.2f\n", "Ext. negative", 0.26, ustrip(u"kip*ft", M_neg_ext_ddm))
@printf("    %-24s %6.2f %12.2f\n", "Positive",      0.52, ustrip(u"kip*ft", M_pos_ddm))
@printf("    %-24s %6.2f %12.2f\n", "Int. negative",  0.70, ustrip(u"kip*ft", M_neg_int_ddm))
println()

# Transverse to column strip: ACI 8.10.5 (100% / 60% / 75%)
cs_frac_ext = 1.00;  cs_frac_pos = 0.60;  cs_frac_int = 0.75
cs_ext_ddm = cs_frac_ext * M_neg_ext_ddm
cs_pos_ddm = cs_frac_pos * M_pos_ddm
cs_int_ddm = cs_frac_int * M_neg_int_ddm

@printf("    Transverse to CS (column strip):  100%% ext neg, 60%% pos, 75%% int neg\n")
@printf("    %-24s %12.2f → CS %12.2f kip·ft\n", "Ext. negative",
        ustrip(u"kip*ft", M_neg_ext_ddm), ustrip(u"kip*ft", cs_ext_ddm))
@printf("    %-24s %12.2f → CS %12.2f kip·ft\n", "Positive",
        ustrip(u"kip*ft", M_pos_ddm), ustrip(u"kip*ft", cs_pos_ddm))
@printf("    %-24s %12.2f → CS %12.2f kip·ft\n", "Int. negative",
        ustrip(u"kip*ft", M_neg_int_ddm), ustrip(u"kip*ft", cs_int_ddm))

# ── 4B: DDM Computed — validate distribute_moments_aci() ──
_rpt.sub("4B — DDM Computed (distribute_moments_aci)")
println("  distribute_moments_aci(M₀, :end_span, $l2_l1) — should match 4A:")

ddm_comp = StructuralSizer.distribute_moments_aci(M0, :end_span, Float64(l2_l1))

@printf("    %-24s %12s %12s %12s\n", "Location", "Hand-Calc", "Computed", "Match?")
@printf("    %-24s %12s %12s %12s\n", "─"^24, "─"^12, "─"^12, "─"^12)

ddm_cs_ext_v = ustrip(u"kip*ft", ddm_comp.column_strip.ext_neg)
ddm_cs_pos_v = ustrip(u"kip*ft", ddm_comp.column_strip.pos)
ddm_cs_int_v = ustrip(u"kip*ft", ddm_comp.column_strip.int_neg)

@printf("    %-24s %12.2f %12.2f %12s\n", "CS ext neg",
        ustrip(u"kip*ft", cs_ext_ddm), ddm_cs_ext_v,
        abs(ustrip(u"kip*ft", cs_ext_ddm) - ddm_cs_ext_v) < 0.01 ? "✓" : "✗")
@printf("    %-24s %12.2f %12.2f %12s\n", "CS positive",
        ustrip(u"kip*ft", cs_pos_ddm), ddm_cs_pos_v,
        abs(ustrip(u"kip*ft", cs_pos_ddm) - ddm_cs_pos_v) < 0.01 ? "✓" : "✗")
@printf("    %-24s %12.2f %12.2f %12s\n", "CS int neg",
        ustrip(u"kip*ft", cs_int_ddm), ddm_cs_int_v,
        abs(ustrip(u"kip*ft", cs_int_ddm) - ddm_cs_int_v) < 0.01 ? "✓" : "✗")
println()

# Validate function matches hand-calc
@test ustrip(u"kip*ft", ddm_comp.column_strip.ext_neg) ≈ ustrip(u"kip*ft", cs_ext_ddm) atol=0.01
@test ustrip(u"kip*ft", ddm_comp.column_strip.pos)     ≈ ustrip(u"kip*ft", cs_pos_ddm) atol=0.01
@test ustrip(u"kip*ft", ddm_comp.column_strip.int_neg) ≈ ustrip(u"kip*ft", cs_int_ddm) atol=0.01

_rpt.note("Exact match confirms distribute_moments_aci correctness.")

# ── 4C: MDDM Computed — simplified coefficients ──
_rpt.sub("4C — MDDM Computed (distribute_moments_mddm)")
println("  Pre-combined coefficients from Supplementary Document Table S-1:")

mddm = StructuralSizer.distribute_moments_mddm(M0, :end_span)

mddm_cs_ext_v = ustrip(u"kip*ft", mddm.column_strip.ext_neg)
mddm_cs_pos_v = ustrip(u"kip*ft", mddm.column_strip.pos)
mddm_cs_int_v = ustrip(u"kip*ft", mddm.column_strip.int_neg)
mddm_ms_ext_v = ustrip(u"kip*ft", mddm.middle_strip.ext_neg)
mddm_ms_pos_v = ustrip(u"kip*ft", mddm.middle_strip.pos)
mddm_ms_int_v = ustrip(u"kip*ft", mddm.middle_strip.int_neg)

@printf("    %-24s %6s %12s %12s\n", "Location", "Coeff", "CS (kip·ft)", "MS (kip·ft)")
@printf("    %-24s %6s %12s %12s\n", "─"^24, "─"^6, "─"^12, "─"^12)
@printf("    %-24s %6.3f %12.2f %12.2f\n", "Ext. negative",
        0.27, mddm_cs_ext_v, mddm_ms_ext_v)
@printf("    %-24s %6.3f %12.2f %12.2f\n", "Positive",
        0.345, mddm_cs_pos_v, mddm_ms_pos_v)
@printf("    %-24s %6.3f %12.2f %12.2f\n", "Int. negative",
        0.55, mddm_cs_int_v, mddm_ms_int_v)
println()
_rpt.note("MDDM coefficients differ slightly from DDM — different source derivation.")

# ── 4D: EFM Computed — Hardy Cross with our stiffness values ──
_rpt.sub("4D — EFM Computed (Hardy Cross Moment Distribution)")
println("  Hardy Cross with Step 2 stiffnesses. FEM = m·qu·l₂·l₁² (PCA m=0.08429).")

FEM = StructuralSizer.fixed_end_moment_FEM(qu, l2, l1)
DF_ext_val = StructuralSizer.distribution_factor_DF(Ksb, Kec; is_exterior=true)
DF_int_val = StructuralSizer.distribution_factor_DF(Ksb, Kec; is_exterior=false)
COF_val    = StructuralSizer.carryover_factor_COF()

@printf("    FEM    = %.2f kip·ft\n", ustrip(u"kip*ft", FEM))
@printf("    DF_ext = %.4f   (Ksb / (Ksb + Kec))\n", DF_ext_val)
@printf("    DF_int = %.4f   (Ksb / (2Ksb + Kec))\n", DF_int_val)
@printf("    COF    = %.3f   (non-prismatic carry-over)\n", COF_val)
println()

# Hardy Cross iteration for symmetric 3-span EFM frame
# Track slab member-end moments AND column moments at each joint.
# Unbalanced = sum(slab ends + column) at each joint.
FEM_kf = ustrip(u"kip*ft", FEM)
slab_m = [[FEM_kf, -FEM_kf], [FEM_kf, -FEM_kf], [FEM_kf, -FEM_kf]]
col_m  = [0.0, 0.0, 0.0, 0.0]   # EC moments at joints 1–4
DF_col_int = 1.0 - 2.0 * DF_int_val   # column share at interior joint

for _ in 1:20
    # Joint 1 (exterior): slab[1][1] + col[1]
    unbal = slab_m[1][1] + col_m[1]
    d_s = -DF_ext_val * unbal
    slab_m[1][1] += d_s;   col_m[1] -= (1.0 - DF_ext_val) * unbal
    slab_m[1][2] += COF_val * d_s

    # Joint 4 (exterior, symmetric): slab[3][2] + col[4]
    unbal = slab_m[3][2] + col_m[4]
    d_s = -DF_ext_val * unbal
    slab_m[3][2] += d_s;   col_m[4] -= (1.0 - DF_ext_val) * unbal
    slab_m[3][1] += COF_val * d_s

    # Joint 2 (interior): slab[1][2] + slab[2][1] + col[2]
    unbal = slab_m[1][2] + slab_m[2][1] + col_m[2]
    d_s = -DF_int_val * unbal
    slab_m[1][2] += d_s;   slab_m[2][1] += d_s
    col_m[2] -= DF_col_int * unbal
    slab_m[1][1] += COF_val * d_s
    slab_m[2][2] += COF_val * d_s

    # Joint 3 (interior, symmetric): slab[2][2] + slab[3][1] + col[3]
    unbal = slab_m[2][2] + slab_m[3][1] + col_m[3]
    d_s = -DF_int_val * unbal
    slab_m[2][2] += d_s;   slab_m[3][1] += d_s
    col_m[3] -= DF_col_int * unbal
    slab_m[2][1] += COF_val * d_s
    slab_m[3][2] += COF_val * d_s
end

# Extract span 1 centerline moments
M_neg_ext_efm_c = abs(slab_m[1][1])
M_neg_int_efm_c = abs(slab_m[1][2])
# Positive from statics: M₀_ctc = qu·l₂·l₁²/8 (center-to-center span)
M0_ctc = ustrip(u"kip*ft", qu * l2 * l1^2 / 8)
M_pos_efm_c = M0_ctc - (M_neg_ext_efm_c + M_neg_int_efm_c) / 2

@printf("    Converged (20 iterations):\n")
@printf("    %-24s %12s %12s %8s\n", "Location", "Computed", "SP Ref", "Δ%")
@printf("    %-24s %12s %12s %8s\n", "─"^24, "─"^12, "─"^12, "─"^8)

efm_sp = [ustrip(u"kip*ft", sp.M_neg_ext), ustrip(u"kip*ft", sp.M_pos), ustrip(u"kip*ft", sp.M_neg_int)]
efm_c  = [M_neg_ext_efm_c, M_pos_efm_c, M_neg_int_efm_c]
for (lbl, c_val, r_val) in zip(["Ext. negative CL","Positive CL","Int. negative CL"], efm_c, efm_sp)
    δ = (c_val - r_val) / max(abs(r_val), 1e-12)
    flag = abs(δ) ≤ 0.05 ? "✓" : (abs(δ) ≤ 0.10 ? "~" : "✗")
    @printf("    %-24s %12.2f %12.2f %+7.1f%% %s\n", lbl, c_val, r_val, 100δ, flag)
end
println()
_rpt.note("Hardy Cross reproduces SP Table 5 — stiffness chain validated.")

@test abs(M_neg_ext_efm_c - ustrip(u"kip*ft", sp.M_neg_ext)) / ustrip(u"kip*ft", sp.M_neg_ext) < 0.05
@test abs(M_neg_int_efm_c - ustrip(u"kip*ft", sp.M_neg_int)) / ustrip(u"kip*ft", sp.M_neg_int) < 0.05

# ── 4E: EFM ASAP Solver — structural frame analysis ──
_rpt.sub("4E — EFM ASAP Solver (Structural Frame Analysis)")
println("  Direct stiffness method with EFM stiffnesses. Linear-elastic 2D frame.")

# Build EFMSpanProperties for 3 identical spans (SP example)
l1_in = uconvert(u"inch", l1)
l2_in = uconvert(u"inch", l2)
ln_in = uconvert(u"inch", ln)
h_in  = uconvert(u"inch", h)
c_in  = uconvert(u"inch", c_col)

Is_in4   = uconvert(u"inch^4", Is)
Ksb_inlb = uconvert(u"lbf*inch", Ksb)

spans_asap = [
    StructuralSizer.EFMSpanProperties(
        i, i, i+1,
        l1_in, l2_in, ln_in,
        h_in, c_in, c_in, c_in, c_in,
        Is_in4, Ksb_inlb,
        0.08429, 0.507, 4.127
    ) for i in 1:3
]

# Interior frame line → all joints have torsional arms both sides
joint_positions_asap = [:interior, :interior, :interior, :interior]

qu_psf = uconvert(u"lbf/ft^2", qu)
model_asap, span_elements_asap, joint_Kec_asap = StructuralSizer.build_efm_asap_model(
    spans_asap, joint_positions_asap, qu_psf;
    column_height = H,
    Ecs = Ecs,
    Ecc = Ecc,
    ν_concrete = 0.20,
    ρ_concrete = 2380.0u"kg/m^3",
    k_col = 4.74
)
StructuralSizer.solve_efm_frame!(model_asap)

# Extract span moments
asap_moments = StructuralSizer.extract_span_moments(
    model_asap, span_elements_asap, spans_asap; qu=qu)

M_neg_ext_asap = ustrip(u"kip*ft", asap_moments[1].M_neg_left)
M_pos_asap     = ustrip(u"kip*ft", asap_moments[1].M_pos)
M_neg_int_asap = ustrip(u"kip*ft", asap_moments[1].M_neg_right)

@printf("    3-span frame:  %d slab elements + %d column stubs\n",
        length(span_elements_asap), length(joint_positions_asap))
@printf("    Kec at joints: %s × 10⁶ in-lb\n",
        join([string(round(ustrip(u"lbf*inch", k)/1e6, digits=1)) for k in joint_Kec_asap], ", "))
println()

@printf("    %-24s %10s %10s %10s %10s %8s\n",
        "Location", "ASAP", "Hardy-X", "SP Ref", "FEA†", "Δ%(ASAP)")
@printf("    %-24s %10s %10s %10s %10s %8s\n",
        "─"^24, "─"^10, "─"^10, "─"^10, "─"^10, "─"^8)

for (lbl, asap_v, hc_v, sp_v, fea_v) in [
    ("Ext. negative CL", M_neg_ext_asap, M_neg_ext_efm_c, ustrip(u"kip*ft", sp.M_neg_ext), M_neg_ext_fea),
    ("Positive CL",      M_pos_asap,     M_pos_efm_c,     ustrip(u"kip*ft", sp.M_pos),     M_pos_fea),
    ("Int. negative CL", M_neg_int_asap, M_neg_int_efm_c, ustrip(u"kip*ft", sp.M_neg_int), M_neg_int_fea)]
    δ = (asap_v - sp_v) / max(abs(sp_v), 1e-12)
    flag = abs(δ) ≤ 0.05 ? "✓" : (abs(δ) ≤ 0.10 ? "~" : "✗")
    @printf("    %-24s %10.2f %10.2f %10.2f %10.2f %+7.1f%% %s\n", lbl, asap_v, hc_v, sp_v, fea_v, 100δ, flag)
end
println()
_rpt.note("† FEA uses different M₀ baseline (see Step 0). ASAP and HC should match SP Table 5.")

# Also extract interior span results for completeness
if length(asap_moments) >= 2
    M_neg_int_s2 = ustrip(u"kip*ft", asap_moments[2].M_neg_left)
    M_pos_s2     = ustrip(u"kip*ft", asap_moments[2].M_pos)
    println()
    @printf("    Interior span (ASAP): M⁻ = %.2f  M⁺ = %.2f  kip·ft\n", M_neg_int_s2, M_pos_s2)
end

@test abs(M_neg_ext_asap - ustrip(u"kip*ft", sp.M_neg_ext)) / ustrip(u"kip*ft", sp.M_neg_ext) < 0.05
@test abs(M_neg_int_asap - ustrip(u"kip*ft", sp.M_neg_int)) / ustrip(u"kip*ft", sp.M_neg_int) < 0.05
@test abs(M_pos_asap - ustrip(u"kip*ft", sp.M_pos)) / ustrip(u"kip*ft", sp.M_pos) < 0.05

# ── 4F: Side-by-side method comparison matrix ──
_rpt.sub("4F — Method Comparison Matrix (Column-Strip Moments)")
println("  CS fractions (ACI 8.10.5): 100%/60%/75%.  † FEA qᵤ per NWC_4000 density.")

# EFM CS moments (from SP centerline × ACI transverse fractions)
cs_ext_efm = cs_frac_ext * ustrip(u"kip*ft", sp.M_neg_ext)
cs_pos_efm = cs_frac_pos * ustrip(u"kip*ft", sp.M_pos)
cs_int_efm = cs_frac_int * ustrip(u"kip*ft", sp.M_neg_int)

# EFM Computed CS moments (from our Hardy Cross)
cs_ext_efm_c = cs_frac_ext * M_neg_ext_efm_c
cs_pos_efm_c = cs_frac_pos * M_pos_efm_c
cs_int_efm_c = cs_frac_int * M_neg_int_efm_c

# EFM ASAP CS moments (from ASAP solver)
cs_ext_asap = cs_frac_ext * M_neg_ext_asap
cs_pos_asap = cs_frac_pos * M_pos_asap
cs_int_asap = cs_frac_int * M_neg_int_asap

# FEA CS moments
cs_ext_fea = cs_frac_ext * M_neg_ext_fea
cs_pos_fea = cs_frac_pos * M_pos_fea
cs_int_fea = cs_frac_int * M_neg_int_fea

@printf("    %-14s %7s %7s %7s %7s %7s %7s %7s\n",
        "Location", "DDM", "DDM(fn)", "MDDM", "EFM(HC)", "EFM(AS)", "EFM(SP)", "FEA†")
@printf("    %-14s %7s %7s %7s %7s %7s %7s %7s\n",
        "─"^14, "─"^7, "─"^7, "─"^7, "─"^7, "─"^7, "─"^7, "─"^7)

# Centerline moments (full frame width)
M0_kf = ustrip(u"kip*ft", M0)
@printf("    %-14s %7.1f %7s %7s %7.1f %7.1f %7.1f %7.1f\n",
        "CL Ext neg", ustrip(u"kip*ft", M_neg_ext_ddm), "—", "—",
        M_neg_ext_efm_c, M_neg_ext_asap, ustrip(u"kip*ft", sp.M_neg_ext), M_neg_ext_fea)
@printf("    %-14s %7.1f %7s %7s %7.1f %7.1f %7.1f %7.1f\n",
        "CL Positive", ustrip(u"kip*ft", M_pos_ddm), "—", "—",
        M_pos_efm_c, M_pos_asap, ustrip(u"kip*ft", sp.M_pos), M_pos_fea)
@printf("    %-14s %7.1f %7s %7s %7.1f %7.1f %7.1f %7.1f\n",
        "CL Int neg", ustrip(u"kip*ft", M_neg_int_ddm), "—", "—",
        M_neg_int_efm_c, M_neg_int_asap, ustrip(u"kip*ft", sp.M_neg_int), M_neg_int_fea)
@printf("    %-14s %7s %7s %7s %7s %7s %7s %7s\n",
        "", "─"^7, "─"^7, "─"^7, "─"^7, "─"^7, "─"^7, "─"^7)

# Column-strip moments
@printf("    %-14s %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f\n",
        "CS Ext neg", ustrip(u"kip*ft", cs_ext_ddm), ddm_cs_ext_v,
        mddm_cs_ext_v, cs_ext_efm_c, cs_ext_asap, cs_ext_efm, cs_ext_fea)
@printf("    %-14s %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f\n",
        "CS Positive", ustrip(u"kip*ft", cs_pos_ddm), ddm_cs_pos_v,
        mddm_cs_pos_v, cs_pos_efm_c, cs_pos_asap, cs_pos_efm, cs_pos_fea)
@printf("    %-14s %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f\n",
        "CS Int neg", ustrip(u"kip*ft", cs_int_ddm), ddm_cs_int_v,
        mddm_cs_int_v, cs_int_efm_c, cs_int_asap, cs_int_efm, cs_int_fea)
println()

# M₀ baseline row
@printf("    %-14s %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f\n",
        "M₀ basis", M0_kf, M0_kf, M0_kf, M0_kf, M0_kf, M0_kf, M0_fea)
@printf("    %-14s %7.0f %7.0f %7.0f %7.0f %7.0f %7.0f %7.0f\n",
        "qᵤ basis (psf)", ustrip(u"psf",qu), ustrip(u"psf",qu), ustrip(u"psf",qu),
        ustrip(u"psf",qu), ustrip(u"psf",qu), ustrip(u"psf",qu), qu_fea_psf)
println()

_rpt.note("DDM(fn) validates distribute_moments_aci. EFM(HC)=Hardy Cross, EFM(AS)=ASAP.")
_rpt.note("FEA† captures two-way action: M < M₀ per direction. EFM ~2× ext neg vs DDM.")

# ── 4G: Face-of-support design moments ──
_rpt.sub("4G — Face-of-Support Design Moments (SP Table 7)")
println("  M_face = M_cl − V×min(c/2, 0.175·l₁).  Positive unchanged at midspan.")

# Shear at support ≈ qu × l2 × ln / 2
V_support = qu * l2 * ln / 2
V_kf = ustrip(u"kip*ft", V_support * 1u"ft")  # dummy conversion for face_of_support fn

# Face-of-support using our function — apply to EFM CS moments
cs_ext_efm_q = cs_frac_ext * sp.M_neg_ext
cs_pos_efm_q = cs_frac_pos * sp.M_pos
cs_int_efm_q = cs_frac_int * sp.M_neg_int

@printf("    %-24s %10s %10s %10s\n", "Location", "EFM CS CL", "SP Face", "FEA CS†")
@printf("    %-24s %10s %10s %10s\n", "─"^24, "─"^10, "─"^10, "─"^10)
@printf("    %-24s %10.2f %10.2f %10.2f\n", "Ext. negative",
        ustrip(u"kip*ft", cs_ext_efm_q), ustrip(u"kip*ft", sp.M_neg_ext_cs), cs_ext_fea)
@printf("    %-24s %10.2f %10.2f %10.2f\n", "Positive",
        ustrip(u"kip*ft", cs_pos_efm_q), ustrip(u"kip*ft", sp.M_pos_cs), cs_pos_fea)
@printf("    %-24s %10.2f %10.2f %10.2f\n", "Int. negative",
        ustrip(u"kip*ft", cs_int_efm_q), ustrip(u"kip*ft", sp.M_neg_int_cs), cs_int_fea)
println()
_rpt.note("Face-of-support governs reinforcement. † FEA extracted at column face directly.")

# ── 4H: FEA Per-Column Demands (M⁻, Vu, Mub) ──
_rpt.sub("4H — FEA Per-Column Demands")
println("  M⁻ = max section moment (skeleton-edge), Vu = stub axial, Mub = unbalanced (ACI 8.4.4.2)")

@printf("    %-5s  %-10s  %10s  %10s  %12s\n", "Col", "Position", "M⁻ (kip·ft)", "Vu (kip)", "Mub (kip·ft)")
@printf("    %-5s  %-10s  %10s  %10s  %12s\n", "─"^5, "─"^10, "─"^10, "─"^10, "─"^12)
for (i, col_fea_i) in enumerate(fea_columns)
    Mn_i = ustrip(u"kip*ft", fea_result.column_moments[i])
    Vu_i = ustrip(u"kip", fea_result.column_shears[i])
    Mub_i = ustrip(u"kip*ft", fea_result.unbalanced_moments[i])
    @printf("    %-5d  %-10s  %10.1f  %10.1f  %12.1f\n", i, string(col_fea_i.position), Mn_i, Vu_i, Mub_i)
end
println()


# Two-way load sharing ratio: FEA ∑/M₀
fea_sum = M_pos_fea + (M_neg_ext_fea + M_neg_int_fea) / 2
fea_ratio = fea_sum / M0_fea * 100
@printf("    Load sharing:  ∑(FEA moments) / M₀ = %.1f%%\n", fea_ratio)
_rpt.note("FEA ∑/M₀ < 100% — two-way action distributes load in both directions.")

@test M0_fea > 0
@test M_pos_fea > 0
@test length(fea_result.column_shears) == length(fea_columns)
@test all(ustrip.(u"kip", fea_result.column_shears) .> 0)

_step_status["Method Comparison"] = "✓"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5  Effective Depth
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 5 — EFFECTIVE DEPTH")
println("  d_avg = h − cover − db.  cover=0.75\" (ACI 20.6.1.3.1), db=#5=0.625\".")

d = StructuralSizer.effective_depth(h; cover=0.75u"inch", bar_diameter=0.625u"inch")

d1 = h - 0.75u"inch" - 0.625u"inch" / 2   # top layer
d2 = h - 0.75u"inch" - 3 * 0.625u"inch" / 2  # bottom layer
@printf("    d₁ = %.3f in − 0.750 in − 0.625/2 in = %.4f in  (top layer)\n",
        ustrip(u"inch", h), ustrip(u"inch", d1))
@printf("    d₂ = %.3f in − 0.750 in − 3×0.625/2 in = %.4f in  (bottom layer)\n",
        ustrip(u"inch", h), ustrip(u"inch", d2))
@printf("    d_avg = (%.4f + %.4f) / 2 = %.4f in\n",
        ustrip(u"inch", d1), ustrip(u"inch", d2), ustrip(u"inch", d))

# SP uses d_avg = 5.75 in (#4 bars); our #5 bars give slightly different d_avg
d_sp = 5.75u"inch"
@printf("    SP uses d_avg = %.2f in (with #4 bars, db=0.5\")\n", ustrip(u"inch", d_sp))

@test d > 0u"inch"
_step_status["Effective Depth"] = "✓"
_rpt.note("SP uses #4 bars → d=5.75\"; our #5 bars → d=$(round(ustrip(u"inch", d), digits=3))\".")

# ── STEP 6 — Reinforcement (SP Table 7) ──

_rpt.section("STEP 6 — FLEXURAL REINFORCEMENT  (SP Table 7)")
println("  Whitney block: Mu = φ·As·fy·(d−a/2), φ=0.9.  b_cs = l₂/2 = $(uconvert(u"inch", l2/2)), d=5.75\".")

b_cs = l2 / 2

# Compute As from SP's face-of-support CS moments (using SP's d_avg)
As_neg_ext = StructuralSizer.required_reinforcement(sp.M_neg_ext_cs, b_cs, d_sp, fc_slab, fy)
As_pos     = StructuralSizer.required_reinforcement(sp.M_pos_cs,     b_cs, d_sp, fc_slab, fy)
As_neg_int = StructuralSizer.required_reinforcement(sp.M_neg_int_cs, b_cs, d_sp, fc_slab, fy)

As_min = StructuralSizer.minimum_reinforcement(b_cs, h, fy)

As_neg_ext_final = max(As_neg_ext, As_min)
As_pos_final     = max(As_pos,     As_min)
As_neg_int_final = max(As_neg_int, As_min)

@printf("    As,min = %.3f in²  (ACI 8.6.1.1 — 0.0018 × b × h)\n\n",
        ustrip(u"inch^2", As_min))

_rpt.sub("Column-Strip As  (b = l₂/2 = 84 in, d = 5.75 in)")
@printf("    %-30s %10s %10s %10s\n",
        "Location", "As,req", "As,min", "As,used")
@printf("    %-30s %10s %10s %10s\n", "─"^30, "─"^10, "─"^10, "─"^10)
@printf("    %-30s %10.3f %10.3f %10.3f\n",
        "Ext. negative", ustrip(u"inch^2", As_neg_ext),
        ustrip(u"inch^2", As_min), ustrip(u"inch^2", As_neg_ext_final))
@printf("    %-30s %10.3f %10.3f %10.3f\n",
        "Positive", ustrip(u"inch^2", As_pos),
        ustrip(u"inch^2", As_min), ustrip(u"inch^2", As_pos_final))
@printf("    %-30s %10.3f %10.3f %10.3f\n",
        "Int. negative", ustrip(u"inch^2", As_neg_int),
        ustrip(u"inch^2", As_min), ustrip(u"inch^2", As_neg_int_final))

println()
_rpt.sub("Computed As  vs SP Table 7")
table_head()
ok1 = compare("As⁻ ext CS", As_neg_ext_final, sp.As_neg_ext_cs, u"inch^2"; tol=0.10)
ok2 = compare("As⁺ pos CS", As_pos_final,     sp.As_pos_cs,     u"inch^2"; tol=0.10)
ok3 = compare("As⁻ int CS", As_neg_int_final,  sp.As_neg_int_cs, u"inch^2"; tol=0.10)

@test ok1;  @test ok2;  @test ok3
_step_status["Reinforcement"] = all((ok1, ok2, ok3)) ? "✓" : "✗"

_rpt.note("Small As differences due to iterative solver precision in required_reinforcement.")

# ── FEA Reinforcement (from FEA CS moments, using SP's d for comparability) ──
_rpt.sub("FEA Reinforcement (CS moments from FEA, d = 5.75 in)")

As_neg_ext_fea_v = StructuralSizer.required_reinforcement(cs_ext_fea * u"kip*ft", b_cs, d_sp, fc_slab, fy)
As_pos_fea_v     = StructuralSizer.required_reinforcement(cs_pos_fea * u"kip*ft", b_cs, d_sp, fc_slab, fy)
As_neg_int_fea_v = StructuralSizer.required_reinforcement(cs_int_fea * u"kip*ft", b_cs, d_sp, fc_slab, fy)

As_neg_ext_fea_final = max(As_neg_ext_fea_v, As_min)
As_pos_fea_final     = max(As_pos_fea_v,     As_min)
As_neg_int_fea_final = max(As_neg_int_fea_v, As_min)

@printf("    %-24s %10s %10s %10s %10s\n",
        "Location", "SP As", "EFM As", "FEA As", "FEA/SP")
@printf("    %-24s %10s %10s %10s %10s\n", "─"^24, "─"^10, "─"^10, "─"^10, "─"^10)

for (lbl, sp_As, efm_As, fea_As) in [
    ("Ext. negative", sp.As_neg_ext_cs, As_neg_ext_final, As_neg_ext_fea_final),
    ("Positive",      sp.As_pos_cs,     As_pos_final,     As_pos_fea_final),
    ("Int. negative", sp.As_neg_int_cs, As_neg_int_final, As_neg_int_fea_final)]
    sp_v = ustrip(u"inch^2", sp_As)
    efm_v = ustrip(u"inch^2", efm_As)
    fea_v_as = ustrip(u"inch^2", fea_As)
    ratio = sp_v > 0 ? fea_v_as / sp_v : 0.0
    @printf("    %-24s %10.3f %10.3f %10.3f %9.2f×\n", lbl, sp_v, efm_v, fea_v_as, ratio)
end
println()
_rpt.note("FEA M₀ differs from SP → different As. Two-way action → less steel.")

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7  Punching Shear Check (ACI 22.6)
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 7 — PUNCHING SHEAR  (ACI 22.6)")
println("  Interior column, d/2 from face.  b₀=2(c₁+d)+2(c₂+d), Vu=qᵤ(At−Ac).")

b0 = StructuralSizer.punching_perimeter(c_col, c_col, d)
Vc = StructuralSizer.punching_capacity_interior(b0, d, fc_slab;
         c1=c_col, c2=c_col, position=:interior)

Vu_punch = StructuralSizer.punching_demand(qu, l1 * l2, c_col, c_col, d)

# Strip to common force unit before ratio
Vu_kip = ustrip(u"kip", uconvert(u"kip", Vu_punch))
Vc_kip = ustrip(u"kip", uconvert(u"kip", Vc))
φVc_kip = 0.75 * Vc_kip
ratio_punch = Vu_kip / φVc_kip

@printf("    b₀      = 2(%.2f + %.3f) + 2(%.2f + %.3f) = %.2f in\n",
        ustrip(u"inch", c_col), ustrip(u"inch", d),
        ustrip(u"inch", c_col), ustrip(u"inch", d), ustrip(u"inch", b0))
@printf("    Vc      = %.1f kip\n", Vc_kip)
@printf("    φVc     = %.1f kip   (φ = 0.75)\n", φVc_kip)
@printf("    Vu      = %.1f kip\n", Vu_kip)
pass_punch = ratio_punch ≤ 1.0
@printf("    Vu/φVc  = %.3f%s\n", ratio_punch, pass_punch ? "   ✓ PASS" : "   ✗ FAIL")

@test pass_punch
@test ratio_punch < 1.0

# ── FEA Punching Comparison ──

_rpt.sub("FEA Punching Shear Comparison")

Vu_fea_max = maximum(ustrip.(u"kip", fea_result.column_shears))
Vu_code    = Vu_kip
ratio_fea_punch = Vu_fea_max / φVc_kip

@printf("    %-24s %10s %10s\n", "", "Code", "FEA max")
@printf("    %-24s %10s %10s\n", "─"^24, "─"^10, "─"^10)
@printf("    %-24s %10.1f %10.1f\n", "Vu (kip)", Vu_code, Vu_fea_max)
@printf("    %-24s %10.1f %10s\n", "φVc (kip)", φVc_kip, "—")
@printf("    %-24s %10.3f %10.3f\n", "Vu/φVc", ratio_punch, ratio_fea_punch)
println()

_rpt.note("FEA Vu from stub axial forces — more accurate for irregular layouts.")

_step_status["Punching Shear"] = pass_punch ? "✓" : "✗"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8  Deflection (SP Section 6)
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 8 — DEFLECTION CHECK  (ACI 24.2 / SP Section 6)")
println("  Branson Ie, weighted (ACI 435R-95), λ_Δ=ξ/(1+50ρ') with ξ=2.0.")

Ig = l2 * h^3 / 12
fr_val = StructuralSizer.fr(fc_slab)
Mcr = StructuralSizer.cracking_moment(fr_val, Ig, h)

Es_rebar = 29000u"ksi"
As_min_defl = StructuralSizer.minimum_reinforcement(l2, h, fy)

# ── Midspan: service positive moment ──
Ma_mid = sp.M_pos / 1.4
Icr_mid = StructuralSizer.cracked_moment_of_inertia(As_min_defl, l2, d, Ecs, Es_rebar)
Ie_mid = StructuralSizer.effective_moment_of_inertia(Mcr, Ma_mid, Ig, Icr_mid)

# ── Support: service negative moment (envelope of ext/int) ──
M_neg_max = max(sp.M_neg_ext, sp.M_neg_int)
Ma_sup = M_neg_max / 1.4
As_neg = max(StructuralSizer.required_reinforcement(M_neg_max, l2, d, fc_slab, fy),
             As_min_defl)
Icr_sup = StructuralSizer.cracked_moment_of_inertia(As_neg, l2, d, Ecs, Es_rebar)
Ie_sup = StructuralSizer.effective_moment_of_inertia(Mcr, Ma_sup, Ig, Icr_sup)

# ── ACI 435R-95 weighted average ──
Ie = StructuralSizer.weighted_effective_Ie(Ie_mid, Ie_sup, Ie_sup; position=:exterior)

λ_Δ = StructuralSizer.long_term_deflection_factor(2.0, 0.0)
Δ_limit = StructuralSizer.deflection_limit(l1, :total)

mid_cracked = Ma_mid > Mcr
sup_cracked = Ma_sup > Mcr

println()
@printf("    Ig = %.0f in⁴    fr = %.1f psi    Mcr = %.1f kip·ft\n",
        ustrip(u"inch^4", Ig), ustrip(u"psi", fr_val), ustrip(u"kip*ft", Mcr))
@printf("    Ma_mid = %.1f kip·ft (%s)    Ma_sup = %.1f kip·ft (%s)\n",
        ustrip(u"kip*ft", Ma_mid), mid_cracked ? "cracked" : "uncracked",
        ustrip(u"kip*ft", Ma_sup), sup_cracked ? "cracked" : "uncracked")
@printf("    Icr_mid = %.0f    Ie_mid/Ig = %.3f    Icr_sup = %.0f    Ie_sup/Ig = %.3f\n",
        ustrip(u"inch^4", Icr_mid), ustrip(u"inch^4", Ie_mid)/ustrip(u"inch^4", Ig),
        ustrip(u"inch^4", Icr_sup), ustrip(u"inch^4", Ie_sup)/ustrip(u"inch^4", Ig))
@printf("    Weighted Ie (ACI 435R-95) = %.0f in⁴    Ie/Ig = %.3f\n",
        ustrip(u"inch^4", Ie), ustrip(u"inch^4", Ie) / ustrip(u"inch^4", Ig))

@test ustrip(u"inch^4", Ie) >= ustrip(u"inch^4", Icr_mid)
@test ustrip(u"inch^4", Ie) <= ustrip(u"inch^4", Ig)

@printf("    λ_Δ = %.2f  (ξ=2.0, ρ'=0)    Δ_limit = L/240 = %.3f in\n", λ_Δ, ustrip(u"inch", Δ_limit))

@test λ_Δ ≈ 2.0 rtol=0.01
@test Δ_limit ≈ l1 / 240 rtol=0.01
_step_status["Deflection"] = "✓"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 9  Column Axial Load
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 9 — COLUMN AXIAL LOAD")
println("  Pu = qᵤ × At,  At = l₁ × l₂.")

At = l1 * l2
Pu = qu * At

@printf("    At = %.1f ft × %.1f ft = %.1f ft²\n",
        ustrip(u"ft", l1), ustrip(u"ft", l2), ustrip(u"ft^2", At))
@printf("    Pu = %.0f psf × %.1f ft² = %.1f kip\n",
        ustrip(u"psf", qu), ustrip(u"ft^2", At), ustrip(u"kip", Pu))

@test ustrip(u"kip", Pu) ≈ 48.6 rtol=0.05
_step_status["Column Axial Load"] = "✓"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 10  Integrity Reinforcement (ACI 8.7.4.2)
# ═════════════════════════════════════════════════════════════════════════════

_rpt.section("STEP 10 — INTEGRITY REINFORCEMENT  (ACI 8.7.4.2)")
println("  As,integ = 2(qD+qL)·At / (φ·fy),  φ=0.9.  Continuous bottom steel.")

sw = StructuralSizer.slab_self_weight(h, 150.0u"pcf")
qD = sdl + sw
qL = ll

integrity = StructuralSizer.integrity_reinforcement(At, qD, qL, fy)

@printf("    Self-weight   = %.1f psf\n", ustrip(u"psf", sw))
@printf("    qD            = SDL + SW = %.1f + %.1f = %.1f psf\n",
        ustrip(u"psf", sdl), ustrip(u"psf", sw), ustrip(u"psf", qD))
@printf("    qL            = %.1f psf\n", ustrip(u"psf", qL))
@printf("    Pu,integrity  = %.1f kip\n", ustrip(u"kip", integrity.Pu_integrity))
@printf("    As,integrity  = %.3f in²\n", ustrip(u"inch^2", integrity.As_integrity))

@test ustrip(u"inch^2", integrity.As_integrity) > 0.3
@test ustrip(u"inch^2", integrity.As_integrity) < 3.0
_step_status["Integrity Rebar"] = "✓"

# ── 10B: Demo — integrity bump of bottom steel ──
_rpt.sub("10B — Integrity Bump Demo (large tributary area)")

# Large panel: 25×20 ft → At = 500 ft²  (forces integrity to govern)
demo_At    = 25.0u"ft" * 20.0u"ft"
demo_h     = 8.0u"inch"
demo_d     = demo_h - 0.75u"inch" - 0.3125u"inch"  # cover + db/2
demo_fc    = 4000.0u"psi"
demo_fy    = 60.0u"ksi"
demo_sdl   = 30.0u"psf"
demo_ll    = 100.0u"psf"
demo_sw    = StructuralSizer.slab_self_weight(demo_h, 150.0u"pcf")
demo_qD    = demo_sdl + demo_sw
demo_cs_w  = 20.0u"ft" / 2    # column strip = l₂/2

# Flexural positive moment for column strip (typical: 0.35 M₀ × 0.60)
demo_qu  = 1.2 * demo_qD + 1.6 * demo_ll
demo_ln  = 25.0u"ft" - 16.0u"inch"
demo_M0  = demo_qu * 20.0u"ft" * demo_ln^2 / 8
demo_Mpos_cs = 0.35 * demo_M0 * 0.60  # positive moment, column strip share

# Flexural design → bar selection
As_flex  = StructuralSizer.required_reinforcement(demo_Mpos_cs, demo_cs_w, demo_d, demo_fc, demo_fy)
As_min   = StructuralSizer.minimum_reinforcement(demo_cs_w, demo_h, demo_fy)
As_flex_design = max(As_flex, As_min)
flex_bars = StructuralSizer.select_bars(As_flex_design, demo_cs_w)

# Integrity requirement
demo_integ = StructuralSizer.integrity_reinforcement(demo_At, demo_qD, demo_ll, demo_fy)
integ_check = StructuralSizer.check_integrity_reinforcement(flex_bars.As_provided, demo_integ.As_integrity)

@printf("    Panel:         25×20 ft   At = %.0f ft²\n", ustrip(u"ft^2", demo_At))
@printf("    Slab:          h = %.1f in   d = %.2f in\n", ustrip(u"inch", demo_h), ustrip(u"inch", demo_d))
@printf("    Loads:         SDL = %.0f psf   LL = %.0f psf   qu = %.1f psf\n",
        ustrip(u"psf", demo_sdl), ustrip(u"psf", demo_ll), ustrip(u"psf", demo_qu))
@printf("    M₀             = %.1f kip·ft\n", ustrip(u"kip*ft", demo_M0))
@printf("    M⁺(cs)         = 0.35×0.60×M₀ = %.1f kip·ft\n", ustrip(u"kip*ft", demo_Mpos_cs))
println()
@printf("    Flexural As    = %.3f in²  (governs over As,min = %.3f in²)\n",
        ustrip(u"inch^2", As_flex_design), ustrip(u"inch^2", As_min))
@printf("    Flex bars      = %d #%d @ %.1f in   → As,prov = %.3f in²\n",
        flex_bars.n_bars, flex_bars.bar_size,
        ustrip(u"inch", flex_bars.spacing),
        ustrip(u"inch^2", flex_bars.As_provided))
println()
@printf("    Pu,integrity   = %.1f kip\n", ustrip(u"kip", demo_integ.Pu_integrity))
@printf("    As,integrity   = %.3f in²\n", ustrip(u"inch^2", demo_integ.As_integrity))
@printf("    Check          = %s  (util = %.2f)\n",
        integ_check.ok ? "PASS" : "FAIL — integrity governs",
        integ_check.utilization)

if !integ_check.ok
    # Bump: re-select bars to satisfy integrity
    bumped_bars = StructuralSizer.select_bars(demo_integ.As_integrity, demo_cs_w)
    println()
    @printf("    ⇒ Bumped bars  = %d #%d @ %.1f in   → As,prov = %.3f in²\n",
            bumped_bars.n_bars, bumped_bars.bar_size,
            ustrip(u"inch", bumped_bars.spacing),
            ustrip(u"inch^2", bumped_bars.As_provided))
    Δ_pct = (ustrip(u"inch^2", bumped_bars.As_provided) /
             ustrip(u"inch^2", flex_bars.As_provided) - 1) * 100
    @printf("    ΔAs            = +%.1f%%\n", Δ_pct)
    @test ustrip(u"inch^2", bumped_bars.As_provided) >= ustrip(u"inch^2", demo_integ.As_integrity)
end

@test !integ_check.ok  # confirm this demo triggers the bump

# ── STEP 11 — Parametric Sensitivity ──

_rpt.section("STEP 11 — PARAMETRIC SENSITIVITY STUDIES")

# ── 11A: Slab Thickness Sweep ──
_rpt.sub("11A — Slab Thickness (h) vs Punching, Reinforcement & Deflection")
h_min_in = round(ustrip(u"inch", ln / 30), digits=1)
println("  h: 5.5–9\", h_min=ln/30=$(h_min_in)\". SP baseline inputs.")

h_trials = [5.5, 6.0, 6.5, 7.0, 7.5, 8.0, 8.5, 9.0]u"inch"
γ_mass = 150.0u"pcf"
Es_rebar = 29000u"ksi"

Δ_lim_11a = ustrip(u"inch", l1 / 240)
@printf("  Limits:  Vu/φVc ≤ 1.0  (punching)    Δ_LT ≤ L/240 = %.2f in  (deflection)\n",
        Δ_lim_11a)
@printf("  Δ_LT = (1 + λΔ) × Δi = 3 × Δi   (λΔ = 2.0, ρ' = 0, ≥ 5 yr)\n\n")

@printf("    %5s  %5s  %7s  %7s  %7s  %7s  %8s  %5s  %5s\n",
        "h(in)", "d(in)", "qu(psf)", "Vu/φVc", "As,min", "Ie/Ig", "Δ_LT", "Punch", "Defl")
@printf("    %5s  %5s  %7s  %7s  %7s  %7s  %8s  %5s  %5s\n",
        "─"^5, "─"^5, "─"^7, "─"^7, "─"^7, "─"^7, "─"^8, "─"^5, "─"^5)

for h_t in h_trials
    # Derived quantities
    d_t  = StructuralSizer.effective_depth(h_t; cover=0.75u"inch", bar_diameter=0.625u"inch")
    sw_t = StructuralSizer.slab_self_weight(h_t, γ_mass)
    qu_t = 1.2 * (sdl + sw_t) + 1.6 * ll

    # Punching shear
    b0_t = StructuralSizer.punching_perimeter(c_col, c_col, d_t)
    Vc_t = StructuralSizer.punching_capacity_interior(b0_t, d_t, fc_slab;
               c1=c_col, c2=c_col, position=:interior)
    Vu_t = StructuralSizer.punching_demand(qu_t, l1 * l2, c_col, c_col, d_t)
    ratio_t = ustrip(u"lbf", Vu_t) / (0.75 * ustrip(u"lbf", Vc_t))

    # Reinforcement
    As_min_t = StructuralSizer.minimum_reinforcement(l2 / 2, h_t, fy)

    # Deflection — weighted effective Ie (ACI 435R-95)
    Ig_t   = l2 * h_t^3 / 12
    Mcr_t  = StructuralSizer.cracking_moment(StructuralSizer.fr(fc_slab), Ig_t, h_t)
    As_defl_t = StructuralSizer.minimum_reinforcement(l2, h_t, fy)

    # Midspan Ie (service positive)
    Ma_mid_t  = sp.M_pos / 1.4
    Icr_mid_t = StructuralSizer.cracked_moment_of_inertia(As_defl_t, l2, d_t, Ecs, Es_rebar)
    Ie_mid_t  = StructuralSizer.effective_moment_of_inertia(Mcr_t, Ma_mid_t, Ig_t, Icr_mid_t)

    # Support Ie (service negative)
    M_neg_max_t = max(sp.M_neg_ext, sp.M_neg_int)
    Ma_sup_t    = M_neg_max_t / 1.4
    As_neg_t    = max(StructuralSizer.required_reinforcement(M_neg_max_t, l2, d_t, fc_slab, fy),
                      As_defl_t)
    Icr_sup_t   = StructuralSizer.cracked_moment_of_inertia(As_neg_t, l2, d_t, Ecs, Es_rebar)
    Ie_sup_t    = StructuralSizer.effective_moment_of_inertia(Mcr_t, Ma_sup_t, Ig_t, Icr_sup_t)

    # Weighted average
    Ie_t  = StructuralSizer.weighted_effective_Ie(Ie_mid_t, Ie_sup_t, Ie_sup_t; position=:exterior)
    Ie_Ig = ustrip(u"inch^4", Ie_t) / ustrip(u"inch^4", Ig_t)

    # Total long-term deflection: Δ_LT = (1 + λΔ) × Δi
    w_serv = (sdl + sw_t + ll) * l2  # service load per unit length
    Δi_t = StructuralSizer.immediate_deflection(w_serv, l1, Ecs, Ie_t)
    Δi_in = ustrip(u"inch", Δi_t)
    Δ_LT = (1.0 + 2.0) * Δi_in  # (1 + λΔ) × Δi

    punch_ok = ratio_t ≤ 1.0
    defl_ok  = Δ_LT < Δ_lim_11a
    mark = h_t == 7.0u"inch" ? " ◂" : ""

    @printf("    %5.1f  %5.2f  %7.0f  %7.3f  %7.3f  %7.3f  %8.3f  %3s    %3s%s\n",
            ustrip(u"inch", h_t), ustrip(u"inch", d_t), ustrip(u"psf", qu_t),
            ratio_t, ustrip(u"inch^2", As_min_t), Ie_Ig, Δ_LT,
            punch_ok ? "✓" : "✗", defl_ok ? "✓" : "✗", mark)
end
println()
_rpt.note("◂ = SP baseline (h=7\").  Thicker → better punching & deflection.")

# ── 11B: Column Size Sweep ──
_rpt.sub("11B — Column Size (c) vs Stiffness & Punching")
println("  c: 12–24\" (square). h=7\", H=9 ft.")

c_trials = [12.0, 14.0, 16.0, 18.0, 20.0, 24.0]u"inch"

@printf("    %5s  %7s  %10s  %10s  %6s  %7s\n",
        "c(in)", "ln(ft)", "Kec(M·in)", "αec", "Vu/φVc", "DF_ext")
@printf("    %5s  %7s  %10s  %10s  %6s  %7s\n",
        "─"^5, "─"^7, "─"^10, "─"^10, "─"^6, "─"^7)

for c_t in c_trials
    ln_t = l1 - c_t
    Ic_t = StructuralSizer.column_moment_of_inertia(c_t, c_t)
    C_t  = StructuralSizer.torsional_constant_C(h, c_t)
    Kc_t = StructuralSizer.column_stiffness_Kc(Ecc, Ic_t, H, h)
    Kt_t = StructuralSizer.torsional_member_stiffness_Kt(Ecs, C_t, l2, c_t)
    Kec_t = StructuralSizer.equivalent_column_stiffness_Kec(2Kc_t, 2Kt_t)
    αec_t = ustrip(u"lbf*inch", Kec_t) / (2 * ustrip(u"lbf*inch", Ksb))

    DF_ext_t = StructuralSizer.distribution_factor_DF(Ksb, Kec_t; is_exterior=true)

    # Punching with baseline d
    b0_t = StructuralSizer.punching_perimeter(c_t, c_t, d)
    Vc_t = StructuralSizer.punching_capacity_interior(b0_t, d, fc_slab;
               c1=c_t, c2=c_t, position=:interior)
    Vu_t = StructuralSizer.punching_demand(qu, l1 * l2, c_t, c_t, d)
    ratio_t = ustrip(u"lbf", Vu_t) / (0.75 * ustrip(u"lbf", Vc_t))

    @printf("    %5.0f  %7.2f  %10.1f  %10.3f  %6.3f  %7.4f\n",
            ustrip(u"inch", c_t), ustrip(u"ft", ln_t),
            ustrip(u"lbf*inch", Kec_t) / 1e6, αec_t, ratio_t, DF_ext_t)
end
println()
_rpt.note("Larger c → Kec↑, αec↑, b₀↑ → better punching. c=16\" is SP baseline.")

# ── 11C: Reinforcement Level vs Deflection ──
_rpt.sub("11C — Reinforcement Level vs Effective Stiffness & Deflection")
println("  As: 0.5–3.0×As_min. h=7\", d=5.75\". More steel → higher Icr → less deflection.")

As_base = StructuralSizer.minimum_reinforcement(l2, h, fy)  # full-width As_min
Ig_base = l2 * h^3 / 12
fr_base = StructuralSizer.fr(fc_slab)
Mcr_base = StructuralSizer.cracking_moment(fr_base, Ig_base, h)
Ma_mid_base = sp.M_pos / 1.4
M_neg_max_base = max(sp.M_neg_ext, sp.M_neg_int)
Ma_sup_base = M_neg_max_base / 1.4
w_base   = (sdl + StructuralSizer.slab_self_weight(h, γ_mass) + ll) * l2
d_sp_val = 5.75u"inch"

As_multipliers = [0.5, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0]

@printf("    %7s  %8s  %10s  %9s  %9s  %7s  %8s  %8s\n",
        "As/Amin", "As(in²)", "Icr(in⁴)", "Ie_mid/Ig", "Ie_sup/Ig", "Ie/Ig", "Δi(in)", "Δ_LT(in)")
@printf("    %7s  %8s  %10s  %9s  %9s  %7s  %8s  %8s\n",
        "─"^7, "─"^8, "─"^10, "─"^9, "─"^9, "─"^7, "─"^8, "─"^8)

for mult in As_multipliers
    As_t  = mult * As_base
    Icr_mid_t = StructuralSizer.cracked_moment_of_inertia(As_t, l2, d_sp_val, Ecs, Es_rebar)

    # Midspan Ie
    Ie_mid_t = StructuralSizer.effective_moment_of_inertia(Mcr_base, Ma_mid_base, Ig_base, Icr_mid_t)

    # Support Ie (scale neg steel proportionally)
    As_neg_t = max(StructuralSizer.required_reinforcement(M_neg_max_base, l2, d_sp_val, fc_slab, fy),
                   As_t)
    Icr_sup_t = StructuralSizer.cracked_moment_of_inertia(As_neg_t, l2, d_sp_val, Ecs, Es_rebar)
    Ie_sup_t = StructuralSizer.effective_moment_of_inertia(Mcr_base, Ma_sup_base, Ig_base, Icr_sup_t)

    # Weighted average
    Ie_t = StructuralSizer.weighted_effective_Ie(Ie_mid_t, Ie_sup_t, Ie_sup_t; position=:exterior)
    Ie_Ig = ustrip(u"inch^4", Ie_t) / ustrip(u"inch^4", Ig_base)

    Δi_t = StructuralSizer.immediate_deflection(w_base, l1, Ecs, Ie_t)
    Δi_in = ustrip(u"inch", Δi_t)
    Δ_lt = 2.0 * Δi_in + Δi_in  # total ≈ (1 + λΔ) × Δi

    Ie_mid_Ig = ustrip(u"inch^4", Ie_mid_t) / ustrip(u"inch^4", Ig_base)
    Ie_sup_Ig = ustrip(u"inch^4", Ie_sup_t) / ustrip(u"inch^4", Ig_base)

    @printf("    %7.2f  %8.2f  %10.0f  %9.3f  %9.3f  %7.3f  %8.4f  %8.4f\n",
            mult, ustrip(u"inch^2", As_t), ustrip(u"inch^4", Icr_mid_t),
            Ie_mid_Ig, Ie_sup_Ig, Ie_Ig, Δi_in, Δ_lt)
end
println()
let Δ_lim_in = round(ustrip(u"inch", l1/240), digits=2)
    _rpt.note("Δ_LT=(1+λΔ)×Δi, λΔ=2.0. Δ_limit=L/240=$(Δ_lim_in)\". Weighted Ie includes support cracking.")
end

# ── 11D: Column Shape — Square vs Circular ──
_rpt.sub("11D — Column Shape: Square vs Circular (Same Area)")
println("  c_eq=D√(π/4)≈0.886D. h=7\", d=5.75\". Compare b₀ and Ic.")

D_trials = [12.0, 14.0, 16.0, 18.0, 20.0, 24.0]u"inch"

@printf("    %4s  %5s  ┃ %9s  %9s  %6s ┃ %9s  %9s  %6s ┃ %6s  %6s\n",
        "D", "c_eq",
        "b₀(sq)", "b₀(cir)", "Δb₀%",
        "Ic(sq)", "Ic(cir)", "ΔIc%",
        "Vu/φVc", "Vu/φVc")
@printf("    %4s  %5s  ┃ %9s  %9s  %6s ┃ %9s  %9s  %6s ┃ %6s  %6s\n",
        "(in)", "(in)",
        "(in)", "(in)", "",
        "(in⁴)", "(in⁴)", "",
        "sq", "cir")
@printf("    %4s  %5s  ┃ %9s  %9s  %6s ┃ %9s  %9s  %6s ┃ %6s  %6s\n",
        "─"^4, "─"^5,
        "─"^9, "─"^9, "─"^6,
        "─"^9, "─"^9, "─"^6,
        "─"^6, "─"^6)

for D_t in D_trials
    c_eq = StructuralSizer.equivalent_square_column(D_t)
    c_eq_in = ustrip(u"inch", c_eq)
    D_in = ustrip(u"inch", D_t)

    # Punching perimeters
    b0_sq  = StructuralSizer.punching_perimeter(c_eq, c_eq, d; shape=:rectangular)
    b0_cir = StructuralSizer.punching_perimeter(D_t, D_t, d; shape=:circular)
    b0_sq_in  = ustrip(u"inch", b0_sq)
    b0_cir_in = ustrip(u"inch", b0_cir)
    Δb0_pct = (b0_cir_in - b0_sq_in) / b0_sq_in * 100

    # Moment of inertia
    Ic_sq  = StructuralSizer.column_moment_of_inertia(c_eq, c_eq; shape=:rectangular)
    Ic_cir = StructuralSizer.column_moment_of_inertia(D_t, D_t; shape=:circular)
    Ic_sq_in4  = ustrip(u"inch^4", Ic_sq)
    Ic_cir_in4 = ustrip(u"inch^4", Ic_cir)
    ΔIc_pct = (Ic_cir_in4 - Ic_sq_in4) / Ic_sq_in4 * 100

    # Punching shear ratio — square (equivalent)
    Vc_sq = StructuralSizer.punching_capacity_interior(b0_sq, d, fc_slab;
                c1=c_eq, c2=c_eq, position=:interior, shape=:rectangular)
    Vu_sq = StructuralSizer.punching_demand(qu, l1*l2, c_eq, c_eq, d; shape=:rectangular)
    ratio_sq = ustrip(u"lbf", Vu_sq) / (0.75 * ustrip(u"lbf", Vc_sq))

    # Punching shear ratio — circular (actual)
    Vc_cir = StructuralSizer.punching_capacity_interior(b0_cir, d, fc_slab;
                 c1=D_t, c2=D_t, position=:interior, shape=:circular)
    Vu_cir = StructuralSizer.punching_demand(qu, l1*l2, D_t, D_t, d; shape=:circular)
    ratio_cir = ustrip(u"lbf", Vu_cir) / (0.75 * ustrip(u"lbf", Vc_cir))

    @printf("    %4.0f  %5.1f  ┃ %9.1f  %9.1f  %+5.1f%% ┃ %9.0f  %9.0f  %+5.1f%% ┃ %6.3f  %6.3f\n",
            D_in, c_eq_in,
            b0_sq_in, b0_cir_in, Δb0_pct,
            Ic_sq_in4, Ic_cir_in4, ΔIc_pct,
            ratio_sq, ratio_cir)
end
println()
_rpt.note("Circular b₀~14% less, Ic~4.5% less than equivalent square. Net effect moderate.")

# Validate that circular and square are reasonably close for baseline 16" column
let D_base = 16.0u"inch",
    c_eq_base = StructuralSizer.equivalent_square_column(D_base),
    b0_sq_base  = StructuralSizer.punching_perimeter(c_eq_base, c_eq_base, d; shape=:rectangular),
    b0_cir_base = StructuralSizer.punching_perimeter(D_base, D_base, d; shape=:circular),
    Ic_sq_base  = StructuralSizer.column_moment_of_inertia(c_eq_base, c_eq_base; shape=:rectangular),
    Ic_cir_base = StructuralSizer.column_moment_of_inertia(D_base, D_base; shape=:circular)

    # b₀ difference should be moderate (< 15%)
    Δb0 = abs(ustrip(u"inch", b0_cir_base) - ustrip(u"inch", b0_sq_base)) / ustrip(u"inch", b0_sq_base)
    @test Δb0 < 0.15
    compare("b₀ (circular vs eq. square)", b0_cir_base, b0_sq_base, u"inch"; tol=0.15)

    # Ic difference should be moderate (< 25%)
    ΔIc = abs(ustrip(u"inch^4", Ic_cir_base) - ustrip(u"inch^4", Ic_sq_base)) / ustrip(u"inch^4", Ic_sq_base)
    @test ΔIc < 0.25
    compare("Ic (circular vs eq. square)", Ic_cir_base, Ic_sq_base, u"inch^4"; tol=0.25)
end

_step_status["Sensitivity Studies"] = "✓"

# ── STEP 12 — Full Sizing (All 5 Methods) ──

_rpt.section("STEP 12 — FULL SIZING: DDM vs MDDM vs EFM-HC vs EFM-AP vs FEA")
println("  75×60 ft, 3×3 bays, SDL=30 psf, LL=100 psf, 12\" initial columns.")

# ─── Helper: build a fresh structure for a given method ───
sz_Lx = 75.0u"ft"
sz_Ly = 60.0u"ft"
sz_H  = 10.0u"ft"
sz_sdl = 30.0u"psf"
sz_ll  = 100.0u"psf"
sz_c0  = 12.0u"inch"   # initial column size (small → forces iteration)

function _build_sizing_struc(method_obj)
    _skel = gen_medium_office(sz_Lx, sz_Ly, sz_H, 3, 3, 1)
    _struc = BuildingStructure(_skel)
    _opts = FlatPlateOptions(
        material = RC_4000_60,
        method = method_obj,
        cover = 0.75u"inch",
        bar_size = 5,
    )
    initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c_i in _struc.cells
        c_i.sdl = uconvert(u"kN/m^2", sz_sdl)
        c_i.live_load = uconvert(u"kN/m^2", sz_ll)
    end
    for col_i in _struc.columns
        col_i.c1 = sz_c0
        col_i.c2 = sz_c0
    end
    to_asap!(_struc)
    return (_struc, _opts)
end

# ─── Run sizing for each method ───
sizing_data = Dict{Symbol, Any}()
methods_ordered = [:ddm, :mddm, :efm_hc, :efm_asap, :fea]
method_objects = Dict(
    :ddm      => DDM(),
    :mddm     => DDM(:simplified),
    :efm_hc   => EFM(:moment_distribution),
    :efm_asap => EFM(:asap),
    :fea      => FEA(),
)
method_labels = Dict(
    :ddm      => "DDM",
    :mddm     => "MDDM",
    :efm_hc   => "EFM-HC",
    :efm_asap => "EFM-AP",
    :fea      => "FEA",
)
for method_sym in methods_ordered
    struc_m, opts_m = with_logger(NullLogger()) do
        _build_sizing_struc(method_objects[method_sym])
    end
    StructuralSizer.size_slabs!(struc_m; options=opts_m, max_iterations=30)
    slab_m = struc_m.slabs[1]
    res = slab_m.result
    sizing_data[method_sym] = (struc=struc_m, result=res)
end

n_methods = length(methods_ordered)

# Helper: find strip reinforcement by location symbol
function _find_strip(reinf_vec, loc::Symbol)
    idx = findfirst(r -> r.location == loc, reinf_vec)
    isnothing(idx) ? nothing : reinf_vec[idx]
end

# Helper: total provided rebar
function _total_As(res)
    total = 0.0
    for sr in res.column_strip_reinf
        total += ustrip(u"inch^2", sr.As_provided)
    end
    for sr in res.middle_strip_reinf
        total += ustrip(u"inch^2", sr.As_provided)
    end
    total
end

# ─── 12A: Slab Thickness & Geometry ───
_rpt.sub("12A — Slab Thickness & Geometry")

# Header
@printf("    %-18s", "")
for m in methods_ordered; @printf("  %8s", method_labels[m]); end
println()
@printf("    %-18s", "─"^18)
for _ in methods_ordered; @printf("  %8s", "─"^8); end
println()
# h
@printf("    %-18s", "h (in)")
for m in methods_ordered; @printf("  %8.1f", ustrip(u"inch", sizing_data[m].result.thickness)); end
println()
# M0
@printf("    %-18s", "M₀ (kip·ft)")
for m in methods_ordered; @printf("  %8.1f", ustrip(u"kip*ft", sizing_data[m].result.M0)); end
println()
# l1
@printf("    %-18s", "l₁ (ft)")
for m in methods_ordered; @printf("  %8.1f", ustrip(u"ft", sizing_data[m].result.l1)); end
println()
# l2
@printf("    %-18s", "l₂ (ft)")
for m in methods_ordered; @printf("  %8.1f", ustrip(u"ft", sizing_data[m].result.l2)); end
println()
println()
# SW
@printf("    %-18s", "SW (psf)")
for m in methods_ordered; @printf("  %8.1f", ustrip(u"psf", sizing_data[m].result.self_weight)); end
println()
# Total As
@printf("    %-18s", "ΣAs (in²)")
for m in methods_ordered; @printf("  %8.2f", _total_As(sizing_data[m].result)); end
println()
println()

# ─── 12B: Column-Strip Reinforcement ───
_rpt.sub("12B — Column-Strip Reinforcement")

@printf("    %-18s", "Location")
for m in methods_ordered; @printf("  %10s", method_labels[m]); end
println()
@printf("    %-18s", "─"^18)
for _ in methods_ordered; @printf("  %10s", "─"^10); end
println()
for (loc_sym, loc_label) in [(:ext_neg, "Ext. negative"), (:pos, "Positive"), (:int_neg, "Int. negative")]
    @printf("    %-18s", "$loc_label As")
    for m in methods_ordered
        sr = _find_strip(sizing_data[m].result.column_strip_reinf, loc_sym)
        As = isnothing(sr) ? 0.0 : ustrip(u"inch^2", sr.As_provided)
        @printf("  %10.3f", As)
    end
    println()
    @printf("    %-18s", "  bar / spacing")
    for m in methods_ordered
        sr = _find_strip(sizing_data[m].result.column_strip_reinf, loc_sym)
        if isnothing(sr)
            @printf("  %10s", "—")
        else
            @printf("  #%d @ %4.1f\"", sr.bar_size, ustrip(u"inch", sr.spacing))
        end
    end
    println()
end
println()

# ─── 12C: Middle-Strip Reinforcement ───
_rpt.sub("12C — Middle-Strip Reinforcement")

@printf("    %-18s", "Location")
for m in methods_ordered; @printf("  %10s", method_labels[m]); end
println()
@printf("    %-18s", "─"^18)
for _ in methods_ordered; @printf("  %10s", "─"^10); end
println()
for (loc_sym, loc_label) in [(:ext_neg, "Ext. negative"), (:pos, "Positive"), (:int_neg, "Int. negative")]
    @printf("    %-18s", "$loc_label As")
    for m in methods_ordered
        sr = _find_strip(sizing_data[m].result.middle_strip_reinf, loc_sym)
        As = isnothing(sr) ? 0.0 : ustrip(u"inch^2", sr.As_provided)
        @printf("  %10.3f", As)
    end
    println()
    @printf("    %-18s", "  bar / spacing")
    for m in methods_ordered
        sr = _find_strip(sizing_data[m].result.middle_strip_reinf, loc_sym)
        if isnothing(sr)
            @printf("  %10s", "—")
        else
            @printf("  #%d @ %4.1f\"", sr.bar_size, ustrip(u"inch", sr.spacing))
        end
    end
    println()
end
println()

# ─── 12D: Design Checks ───
_rpt.sub("12D — Design Checks")

@printf("    %-22s", "")
for m in methods_ordered; @printf("  %8s", method_labels[m]); end
println()
@printf("    %-22s", "─"^22)
for _ in methods_ordered; @printf("  %8s", "─"^8); end
println()
@printf("    %-22s", "Punch Vu/φVc (max)")
for m in methods_ordered; @printf("  %8.3f", sizing_data[m].result.punching_check.max_ratio); end
println()
@printf("    %-22s", "Punching pass?")
for m in methods_ordered; @printf("  %8s", sizing_data[m].result.punching_check.ok ? "✓" : "✗"); end
println()
@printf("    %-22s", "Δ_check (in)")
for m in methods_ordered; @printf("  %8.3f", ustrip(u"inch", sizing_data[m].result.deflection_check.Δ_check)); end
println()
@printf("    %-22s", "Δ_limit (in)")
for m in methods_ordered; @printf("  %8.3f", ustrip(u"inch", sizing_data[m].result.deflection_check.Δ_limit)); end
println()
@printf("    %-22s", "Δ/Δ_limit")
for m in methods_ordered; @printf("  %8.3f", sizing_data[m].result.deflection_check.ratio); end
println()
@printf("    %-22s", "Deflection pass?")
for m in methods_ordered; @printf("  %8s", sizing_data[m].result.deflection_check.ok ? "✓" : "✗"); end
println()
println()

# ─── 12E: Column Sizes (after pipeline convergence) ───
_rpt.sub("12E — Column Sizes After Convergence")

@printf("    %-22s", "Position")
for m in methods_ordered; @printf("  %10s", method_labels[m]); end
println()
@printf("    %-22s", "─"^22)
for _ in methods_ordered; @printf("  %10s", "─"^10); end
println()
for (pos_sym, pos_label) in [(:interior, "Interior"), (:edge, "Edge"), (:corner, "Corner")]
    @printf("    %-22s", pos_label)
    for m in methods_ordered
        pos_cols = filter(c -> c.position == pos_sym, sizing_data[m].struc.columns)
        if isempty(pos_cols)
            @printf("  %10s", "—")
        else
            c1 = ustrip(u"inch", pos_cols[1].c1)
            c2 = ustrip(u"inch", pos_cols[1].c2)
            @printf("  %4.0f×%4.0f\"", c1, c2)
        end
    end
    println()
end
println()

# ─── 12F: Compact Summary ───
_rpt.sub("12F — One-Line Summary")
println()
@printf("    %-6s │ %4s │ %6s │ %6s │ %6s │ %8s │ %8s │ %s\n",
        "Method", "h\"", "M₀", "ΣAs", "Vu/φVc", "Δ/Δ_lim", "Int col", "Status")
@printf("    %-6s │ %4s │ %6s │ %6s │ %6s │ %8s │ %8s │ %s\n",
        "─"^6, "─"^4, "─"^6, "─"^6, "─"^6, "─"^8, "─"^8, "─"^8)
for m in methods_ordered
    res = sizing_data[m].result
    struc_m = sizing_data[m].struc
    h_in = ustrip(u"inch", res.thickness)
    M0_kf = ustrip(u"kip*ft", res.M0)
    total_As = _total_As(res)
    punch = res.punching_check.max_ratio
    defl = res.deflection_check.ratio
    int_cols = filter(c -> c.position == :interior, struc_m.columns)
    col_str = isempty(int_cols) ? "—" : "$(round(Int, ustrip(u"inch", int_cols[1].c1)))\""
    ok = res.punching_check.ok && res.deflection_check.ok
    @printf("    %-6s │ %4.1f │ %6.1f │ %6.2f │ %6.3f │ %8.3f │ %8s │ %s\n",
            method_labels[m], h_in, M0_kf, total_As, punch, defl, col_str, ok ? "✓ PASS" : "✗ FAIL")
end
println()

_rpt.note("Same geometry/loads/materials for all methods — differences arise only from analysis method.")

# ─── 12G: Per-Position Punching Demands ───
_rpt.sub("12G — Per-Position Punching Demands (Frame of Reference)")

# Use the first method's result for panel geometry reference
ref_res = sizing_data[:ddm].result
ref_l1 = ustrip(u"ft", ref_res.l1)
ref_l2 = ustrip(u"ft", ref_res.l2)
ref_qu = ustrip(u"psf", ref_res.qu)
panel_ft2 = ref_l1 * ref_l2
@printf("  Panel = %.0f × %.0f ft², qᵤ = %.0f psf.  Vu,trib = qᵤ × At.\n", ref_l1, ref_l2, ref_qu)

trib_at = Dict(:interior => panel_ft2, :edge => panel_ft2 / 2.0, :corner => panel_ft2 / 4.0)

@printf("    %-10s │ %7s │", "Position", "At(ft²)")
for m in methods_ordered; @printf(" %8s", method_labels[m]); end
@printf(" │ %8s\n", "Trib Vu")
@printf("    %-10s │ %7s │", "─"^10, "─"^7)
for _ in methods_ordered; @printf(" %8s", "─"^8); end
@printf(" │ %8s\n", "─"^8)

for (pos_sym, pos_label) in [(:interior, "Interior"), (:edge, "Edge"), (:corner, "Corner")]
    At = trib_at[pos_sym]
    Vu_trib = ref_qu * At / 1000.0  # kip

    @printf("    %-10s │ %7.0f │", pos_label, At)
    for m in methods_ordered
        details = sizing_data[m].result.punching_check.details
        pos_ratios = Float64[]
        for (col_idx, pr) in details
            if sizing_data[m].struc.columns[col_idx].position == pos_sym
                push!(pos_ratios, pr.ratio)
            end
        end
        if isempty(pos_ratios)
            @printf(" %8s", "—")
        else
            @printf(" %8.3f", maximum(pos_ratios))
        end
    end
    @printf(" │ %7.1f k\n", Vu_trib)
end
println()

_rpt.note("Max Vu/φVc per position. Trib Vu = simple hand-calc reference.")

# ─── 12H: Interpretation — What the Differences Mean ───
_rpt.sub("12H — Interpretation: Why Methods Differ")
println("  DDM vs MDDM: slightly different coefficients (small rebar impact).")
println("  EFM-HC vs EFM-AP: iteration vs direct stiffness (<2% difference).")
println("  FEA: two-way action → lower bending, possible higher punching at some columns.")

@test all(sizing_data[m].result.punching_check.ok for m in methods_ordered)

_step_status["Full Sizing"] = "✓"

# ── STEP 13 — Flat Slab with Drop Panels ──

_rpt.section("STEP 13 — FLAT SLAB WITH DROP PANELS (ACI §8.2.4)")

# ── 13A: Minimum Thickness — Flat Plate vs Flat Slab ──
_rpt.sub("13A — Minimum Thickness: Flat Plate vs Flat Slab (ACI 8.3.1.1)")
println("  FP: ln/30, ln/33.  FS: ln/33, ln/36.  Drop panels → ~9% thinner.")

ln_trials = [15.0, 18.0, 20.0, 22.0, 25.0]u"ft"

@printf("    %6s  %7s  %7s  %7s  %7s  %8s\n",
        "ln(ft)", "FP ext", "FP int", "FS ext", "FS int", "Savings")
@printf("    %6s  %7s  %7s  %7s  %7s  %8s\n",
        "─"^6, "─"^7, "─"^7, "─"^7, "─"^7, "─"^8)

for ln_t in ln_trials
    fp_ext = StructuralSizer.min_thickness(StructuralSizer.FlatPlate(), ln_t; discontinuous_edge=true)
    fp_int = StructuralSizer.min_thickness(StructuralSizer.FlatPlate(), ln_t; discontinuous_edge=false)
    fs_ext = StructuralSizer.min_thickness(StructuralSizer.FlatSlab(), ln_t; discontinuous_edge=true)
    fs_int = StructuralSizer.min_thickness(StructuralSizer.FlatSlab(), ln_t; discontinuous_edge=false)

    savings = (1.0 - ustrip(u"inch", fs_ext) / ustrip(u"inch", fp_ext)) * 100

    @printf("    %6.0f  %6.1f\"  %6.1f\"  %6.1f\"  %6.1f\"  %7.0f%%\n",
            ustrip(u"ft", ln_t),
            ustrip(u"inch", fp_ext), ustrip(u"inch", fp_int),
            ustrip(u"inch", fs_ext), ustrip(u"inch", fs_int), savings)
end
println()
_rpt.note("Savings = (FP−FS)/FP. 9-10% reduction is the primary economic driver.")

# Validate
@test StructuralSizer.min_thickness(StructuralSizer.FlatSlab(), 18.0u"ft") <
      StructuralSizer.min_thickness(StructuralSizer.FlatPlate(), 18.0u"ft")

# ── 13B: Drop Panel Geometry (ACI 8.2.4) ──
_rpt.sub("13B — Drop Panel Geometry (ACI 8.2.4)")
println("  h_drop ≥ h/4, a_drop ≥ l/6.")

h_trials_dp = [6.0, 7.0, 8.0, 9.0, 10.0, 12.0]u"inch"

@printf("    %6s  %9s  %9s  %10s  %7s\n",
        "h_slab", "h/4 min", "h_drop", "h_total", "Check")
@printf("    %6s  %9s  %9s  %10s  %7s\n",
        "─"^6, "─"^9, "─"^9, "─"^10, "─"^7)

for h_t in h_trials_dp
    h_drop = StructuralSizer.auto_size_drop_depth(h_t)
    h_min_drop = h_t / 4
    h_total = h_t + h_drop
    ok = h_drop >= h_min_drop

    @printf("    %5.1f\"  %8.2f\"  %8.2f\"  %9.2f\"  %5s\n",
            ustrip(u"inch", h_t),
            ustrip(u"inch", h_min_drop),
            ustrip(u"inch", h_drop),
            ustrip(u"inch", h_total),
            ok ? "✓" : "✗")
end
println()

# Show plan extent example for SP geometry
l1_dp = 18.0u"ft";  l2_dp = 14.0u"ft"
a1 = l1_dp / 6;  a2 = l2_dp / 6
println("  For SP baseline (l₁=18', l₂=14'):")
@printf("    a_drop_1 = l₁/6 = %.2f ft = %.1f in   → full extent = %.1f in (%.1f ft)\n",
        ustrip(u"ft", a1), ustrip(u"inch", a1), ustrip(u"inch", 2*a1), ustrip(u"ft", 2*a1))
@printf("    a_drop_2 = l₂/6 = %.2f ft = %.1f in   → full extent = %.1f in (%.1f ft)\n",
        ustrip(u"ft", a2), ustrip(u"inch", a2), ustrip(u"inch", 2*a2), ustrip(u"ft", 2*a2))
println()
_rpt.note("Drop extends l/6 from column center in each direction.")

@test all(StructuralSizer.auto_size_drop_depth(h_t) >= h_t / 4 for h_t in h_trials_dp)

# ── 13C: Edge Beam βt Effect on DDM Moments ──
_rpt.sub("13C — Edge Beam βt Effect on DDM Moments (ACI 8.10.4.2 / 8.10.5.2)")
println("  βt = edge beam torsional stiffness ratio. Higher → more moment to exterior.")

M0_βt = sp.M0  # use SP baseline M₀ = 93.82 kip-ft
βt_trials = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5]

@printf("    %4s  %8s  %8s  %8s  %10s  %12s\n",
        "βt", "ext_neg", "pos", "int_neg", "CS ext frac", "CS ext neg")
@printf("    %4s  %8s  %8s  %8s  %10s  %12s\n",
        "─"^4, "─"^8, "─"^8, "─"^8, "─"^10, "─"^12)

for βt_v in βt_trials
    coeffs = StructuralSizer.aci_ddm_longitudinal_with_edge_beam(βt_v)
    cs_frac = StructuralSizer.aci_col_strip_ext_neg_fraction(βt_v)
    cs_ext = cs_frac * coeffs.ext_neg * ustrip(u"kip*ft", M0_βt)

    @printf("    %4.1f  %7.3f×  %7.3f×  %7.3f×  %9.0f%%  %10.1f k·ft\n",
            βt_v, coeffs.ext_neg, coeffs.pos, coeffs.int_neg, 100*cs_frac, cs_ext)
end
println()
_rpt.note("βt=0→26% M₀ ext neg, βt≥2.5→30% but 75% to CS. Net: less rebar at exterior.")

# Validate monotonic behavior
@test StructuralSizer.aci_ddm_longitudinal_with_edge_beam(2.5).ext_neg >
      StructuralSizer.aci_ddm_longitudinal_with_edge_beam(0.0).ext_neg
@test StructuralSizer.aci_col_strip_ext_neg_fraction(2.5) <
      StructuralSizer.aci_col_strip_ext_neg_fraction(0.0)

# ── 13D: Compression Steel (ρ') Effect on Deflection ──
_rpt.sub("13D — Compression Steel (ρ') Effect on Long-Term Deflection")
println("  λ_Δ = ξ/(1+50ρ'), ξ=2.0. Top bars as compression steel → less creep.")

ρ_trials = [0.0, 0.001, 0.002, 0.005, 0.010, 0.020]

@printf("    %6s  %6s  %10s  %10s\n",
        "ρ'", "λ_Δ", "Δ_LT/Δ_LT₀", "Reduction")
@printf("    %6s  %6s  %10s  %10s\n",
        "─"^6, "─"^6, "─"^10, "─"^10)

λ_Δ_0 = StructuralSizer.long_term_deflection_factor(2.0, 0.0)
for ρ_v in ρ_trials
    λ_Δ_v = StructuralSizer.long_term_deflection_factor(2.0, ρ_v)
    ratio = λ_Δ_v / λ_Δ_0
    reduction = (1.0 - ratio) * 100

    @printf("    %6.3f  %6.3f  %9.0f%%  %9.0f%%\n",
            ρ_v, λ_Δ_v, 100*ratio, reduction)
end
println()
_rpt.note("ρ'=0.005→20% reduction, ρ'=0.010→33%. Pipeline estimates from CS neg steel.")

@test StructuralSizer.long_term_deflection_factor(2.0, 0.01) <
      StructuralSizer.long_term_deflection_factor(2.0, 0.0)

# ── 13E: Full Pipeline — Flat Plate vs Flat Slab ──
_rpt.sub("13E — Full Sizing: Flat Plate vs Flat Slab (DDM)")
println("  Same 75×60 ft building from Step 12. Flat plate vs flat slab (with drops).")

# Build flat slab structure (same geometry as Step 12)
fs_struc, fs_opts = with_logger(NullLogger()) do
    _skel = gen_medium_office(sz_Lx, sz_Ly, sz_H, 3, 3, 1)
    _struc = BuildingStructure(_skel)
    _opts = FlatSlabOptions(
        base = FlatPlateOptions(
            material = RC_4000_60,
            method = DDM(),
            cover = 0.75u"inch",
            bar_size = 5,
        ),
    )
    initialize!(_struc; floor_type=:flat_slab, floor_opts=_opts)
    for c_i in _struc.cells
        c_i.sdl = uconvert(u"kN/m^2", sz_sdl)
        c_i.live_load = uconvert(u"kN/m^2", sz_ll)
    end
    for col_i in _struc.columns
        col_i.c1 = sz_c0
        col_i.c2 = sz_c0
    end
    to_asap!(_struc)
    (_struc, _opts)
end

StructuralSizer.size_slabs!(fs_struc; options=fs_opts, max_iterations=30)
fs_slab = fs_struc.slabs[1]
fs_res = fs_slab.result
fs_dp = fs_slab.drop_panel

# Pull flat plate DDM result from Step 12
fp_res = sizing_data[:ddm].result
fp_struc = sizing_data[:ddm].struc

# Side-by-side comparison
@printf("    %-24s %12s %12s %10s\n",
        "Metric", "Flat Plate", "Flat Slab", "Δ%")
@printf("    %-24s %12s %12s %10s\n",
        "─"^24, "─"^12, "─"^12, "─"^10)

h_fp = ustrip(u"inch", fp_res.thickness)
h_fs = ustrip(u"inch", fs_res.thickness)
@printf("    %-24s %11.1f\" %11.1f\" %+9.0f%%\n",
        "Slab thickness h", h_fp, h_fs, (h_fs/h_fp - 1)*100)

if !isnothing(fs_dp)
    @printf("    %-24s %12s %11.2f\" %10s\n",
            "Drop panel depth", "—",
            ustrip(u"inch", fs_dp.h_drop), "n/a")
    h_total_fs = h_fs + ustrip(u"inch", fs_dp.h_drop)
    @printf("    %-24s %12s %11.2f\" %10s\n",
            "Total depth at column", "—", h_total_fs, "n/a")
    @printf("    %-24s %12s %10.1f\"×%.1f\" %8s\n",
            "Drop panel plan", "—",
            ustrip(u"inch", StructuralSizer.drop_extent_1(fs_dp)),
            ustrip(u"inch", StructuralSizer.drop_extent_2(fs_dp)), "")
end

M0_fp = ustrip(u"kip*ft", fp_res.M0)
M0_fs = ustrip(u"kip*ft", fs_res.M0)
@printf("    %-24s %11.1f %11.1f %+9.0f%%\n",
        "M₀ (kip·ft)", M0_fp, M0_fs, (M0_fs/M0_fp - 1)*100)

sw_fp = ustrip(u"psf", fp_res.self_weight)
sw_fs = ustrip(u"psf", fs_res.self_weight)
@printf("    %-24s %11.1f %11.1f %+9.0f%%\n",
        "Self-weight (psf)", sw_fp, sw_fs, (sw_fs/sw_fp - 1)*100)

As_fp = _total_As(fp_res)
As_fs = _total_As(fs_res)
@printf("    %-24s %11.2f %11.2f %+9.0f%%\n",
        "ΣAs (in²)", As_fp, As_fs, (As_fs/As_fp - 1)*100)

punch_fp = fp_res.punching_check.max_ratio
punch_fs = fs_res.punching_check.max_ratio
@printf("    %-24s %11.3f %11.3f %+9.0f%%\n",
        "Max Vu/φVc", punch_fp, punch_fs, (punch_fs/punch_fp - 1)*100)

defl_fp = fp_res.deflection_check.ratio
defl_fs = fs_res.deflection_check.ratio
@printf("    %-24s %11.3f %11.3f %+9.0f%%\n",
        "Δ/Δ_limit", defl_fp, defl_fs, (defl_fs/defl_fp - 1)*100)

# Column sizes
fp_int_cols = filter(c -> c.position == :interior, fp_struc.columns)
fs_int_cols = filter(c -> c.position == :interior, fs_struc.columns)
if !isempty(fp_int_cols) && !isempty(fs_int_cols)
    c_fp = round(Int, ustrip(u"inch", fp_int_cols[1].c1))
    c_fs = round(Int, ustrip(u"inch", fs_int_cols[1].c1))
    @printf("    %-24s %11d\" %11d\" %+9.0f%%\n",
            "Interior column", c_fp, c_fs, (c_fs/c_fp - 1)*100)
end
println()

_rpt.note("Lower h → less SW → lower M₀ → less rebar. Punching checked at column face AND drop edge.")

@test fs_res.punching_check.ok
@test fs_res.deflection_check.ok
@test h_fs <= h_fp  # flat slab should be at least as thin

# ── 13F: Dual Punching Shear Check ──
_rpt.sub("13F — Flat Slab Dual Punching Shear Check (ACI 22.6)")
println("  Check 1: column face (total depth).  Check 2: drop edge (slab depth only).")

if !isnothing(fs_dp)
    h_slab_fs = fs_res.thickness
    h_total_fs_q = StructuralSizer.total_depth_at_drop(h_slab_fs, fs_dp)
    d_slab_fs = StructuralSizer.effective_depth(h_slab_fs; cover=0.75u"inch", bar_diameter=0.625u"inch")
    d_total_fs = StructuralSizer.effective_depth(h_total_fs_q; cover=0.75u"inch", bar_diameter=0.625u"inch")

    @printf("    h_slab = %.1f in    h_drop = %.2f in    h_total = %.2f in\n",
            ustrip(u"inch", h_slab_fs), ustrip(u"inch", fs_dp.h_drop),
            ustrip(u"inch", h_total_fs_q))
    @printf("    d_slab = %.2f in   d_total = %.2f in\n",
            ustrip(u"inch", d_slab_fs), ustrip(u"inch", d_total_fs))
    @printf("    Drop extent: %.1f\" × %.1f\" (plan)\n\n",
            ustrip(u"inch", StructuralSizer.drop_extent_1(fs_dp)),
            ustrip(u"inch", StructuralSizer.drop_extent_2(fs_dp)))

    # Show punching for a representative interior column
    fs_cols = filter(c -> c.position == :interior, fs_struc.columns)
    if !isempty(fs_cols)
        sample_col = fs_cols[1]
        c1_v = ustrip(u"inch", sample_col.c1)

        # Column face check: b₀ based on (c + d_total)
        b0_col = StructuralSizer.punching_perimeter(sample_col.c1, sample_col.c2, d_total_fs)
        # Drop edge check: b₀ based on (2×a_drop + d_slab)
        b1_drop = 2 * fs_dp.a_drop_1 + d_slab_fs
        b2_drop = 2 * fs_dp.a_drop_2 + d_slab_fs
        b0_drop = 2 * (b1_drop + b2_drop)

        @printf("    Interior column (%.0f\" sq):\n", c1_v)
        @printf("      Column face:  b₀ = %.1f in  (d = %.2f in, total depth)\n",
                ustrip(u"inch", b0_col), ustrip(u"inch", d_total_fs))
        @printf("      Drop edge:    b₀ = %.1f in  (d = %.2f in, slab depth only)\n",
                ustrip(u"inch", b0_drop), ustrip(u"inch", d_slab_fs))
        println()
        _rpt.note("Both checks must pass; governing section depends on geometry.")
    end
end

_step_status["Flat Slab"] = "✓"

# ── STEP 14 — Pattern Loading ──

_rpt.section("STEP 14 — PATTERN LOADING  (ACI 318-19 §6.4.3)")
println("  Checkerboard patterns for worst-case forces. Skip if L/D ≤ 0.75.")

# ─── 14A: L/D Ratio Check ─────────────────────────────────────────────────
_rpt.sub("14A — L/D Ratio Check (ACI §6.4.3.3)")
println("  Pattern loading required when L/D > 0.75.")

# Build structures for both scenarios
pat_sdl_heavy = 20.0u"psf"   # lower SDL → higher L/D
pat_ll_heavy  = 150.0u"psf"  # high LL to guarantee L/D > 0.75

pat_struc_heavy = with_logger(NullLogger()) do
    _skel = gen_medium_office(sz_Lx, sz_Ly, sz_H, 3, 3, 1)
    _struc = BuildingStructure(_skel)
    _opts = FlatPlateOptions(material=RC_4000_60, method=DDM(), cover=0.75u"inch", bar_size=5)
    initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c_i in _struc.cells
        c_i.sdl = uconvert(u"kN/m^2", pat_sdl_heavy)
        c_i.live_load = uconvert(u"kN/m^2", pat_ll_heavy)
    end
    for col_i in _struc.columns; col_i.c1 = sz_c0; col_i.c2 = sz_c0; end
    _struc
end

# Compute L/D for the heavy-LL scenario (SDL=30, LL=100, SW depends on initial h)
# After initialize!, cells have self_weight from the initial slab thickness estimate
ld_ratios_heavy = Float64[]
for cell in pat_struc_heavy.cells
    cell.floor_type == :grade && continue
    D = ustrip(u"Pa", cell.sdl + cell.self_weight)
    D < 1e-12 && continue
    L = ustrip(u"Pa", cell.live_load)
    push!(ld_ratios_heavy, L / D)
end

ld_max_heavy = maximum(ld_ratios_heavy)
ld_min_heavy = minimum(ld_ratios_heavy)
ld_mean_heavy = sum(ld_ratios_heavy) / length(ld_ratios_heavy)

# Light-LL scenario: SDL=100 psf, LL=30 psf → should be L/D < 0.75
pat_struc_light = with_logger(NullLogger()) do
    _skel = gen_medium_office(sz_Lx, sz_Ly, sz_H, 3, 3, 1)
    _struc = BuildingStructure(_skel)
    _opts = FlatPlateOptions(material=RC_4000_60, method=DDM(), cover=0.75u"inch", bar_size=5)
    initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c_i in _struc.cells
        c_i.sdl = uconvert(u"kN/m^2", 100.0u"psf")
        c_i.live_load = uconvert(u"kN/m^2", 30.0u"psf")
    end
    for col_i in _struc.columns; col_i.c1 = sz_c0; col_i.c2 = sz_c0; end
    _struc
end

ld_ratios_light = Float64[]
for cell in pat_struc_light.cells
    cell.floor_type == :grade && continue
    D = ustrip(u"Pa", cell.sdl + cell.self_weight)
    D < 1e-12 && continue
    L = ustrip(u"Pa", cell.live_load)
    push!(ld_ratios_light, L / D)
end

ld_max_light = maximum(ld_ratios_light)

@printf("    %-28s %10s %10s %10s %10s\n",
        "Scenario", "SDL(psf)", "LL(psf)", "max L/D", "Pattern?")
@printf("    %-28s %10s %10s %10s %10s\n",
        "─"^28, "─"^10, "─"^10, "─"^10, "─"^10)
@printf("    %-28s %10.0f %10.0f %10.2f %10s\n",
        "Heavy LL (SDL=20, LL=150)", ustrip(u"psf", pat_sdl_heavy), ustrip(u"psf", pat_ll_heavy),
        ld_max_heavy, ld_max_heavy > 0.75 ? "YES" : "no")
@printf("    %-28s %10.0f %10.0f %10.2f %10s\n",
        "Light LL (SDL=100, LL=30)", 100.0, 30.0, ld_max_light,
        ld_max_light > 0.75 ? "YES" : "no")
println()
_rpt.note("Heavy: L/D≈$(round(ld_mean_heavy,digits=2))→patterns required. Light: L/D≈$(round(ld_max_light,digits=2))→skipped.")

@test ld_max_heavy > 0.75
@test ld_max_light < 0.75

# ─── 14B: Checkerboard Partition ───────────────────────────────────────────
_rpt.sub("14B — Checkerboard Cell Partition")
println("  Centroid grid parity → sets A and B.")

# Build and solve with pattern loading
pat_params = DesignParameters(pattern_loading = :checkerboard)
pat_struc = with_logger(NullLogger()) do
    _skel = gen_medium_office(sz_Lx, sz_Ly, sz_H, 3, 3, 1)
    _struc = BuildingStructure(_skel)
    _opts = FlatPlateOptions(material=RC_4000_60, method=DDM(), cover=0.75u"inch", bar_size=5)
    initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c_i in _struc.cells
        c_i.sdl = uconvert(u"kN/m^2", pat_sdl_heavy)
        c_i.live_load = uconvert(u"kN/m^2", pat_ll_heavy)
    end
    for col_i in _struc.columns; col_i.c1 = sz_c0; col_i.c2 = sz_c0; end
    to_asap!(_struc; params=pat_params)
    _struc
end

set_a, set_b = StructuralSynthesizer._checkerboard_partition(pat_struc)
non_grade = [i for (i, c) in enumerate(pat_struc.cells) if c.floor_type != :grade]

@printf("    Non-grade cells: %d\n", length(non_grade))
@printf("    Set A (even):    %d cells  →  %s\n", length(set_a), sort(set_a))
@printf("    Set B (odd):     %d cells  →  %s\n", length(set_b), sort(set_b))
println()

@test !isempty(set_a)
@test !isempty(set_b)
@test sort(vcat(set_a, set_b)) == sort(non_grade)

_rpt.note("3×3 grid → balanced split (4 vs 5 or 5 vs 4).")

# ─── 14C: Force Comparison — Pattern vs No-Pattern ─────────────────────────
_rpt.sub("14C — Element Force Comparison: Pattern vs No-Pattern")

# No-pattern baseline (same loads as pattern case for fair comparison)
base_params = DesignParameters(pattern_loading = :none)
base_struc = with_logger(NullLogger()) do
    _skel = gen_medium_office(sz_Lx, sz_Ly, sz_H, 3, 3, 1)
    _struc = BuildingStructure(_skel)
    _opts = FlatPlateOptions(material=RC_4000_60, method=DDM(), cover=0.75u"inch", bar_size=5)
    initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c_i in _struc.cells
        c_i.sdl = uconvert(u"kN/m^2", pat_sdl_heavy)
        c_i.live_load = uconvert(u"kN/m^2", pat_ll_heavy)
    end
    for col_i in _struc.columns; col_i.c1 = sz_c0; col_i.c2 = sz_c0; end
    to_asap!(_struc; params=base_params)
    sync_asap!(_struc; params=base_params)
    _struc
end

# Pattern loading
sync_asap!(pat_struc; params=pat_params)

# Compare frame element forces
base_els = base_struc.asap_model.frame_elements
pat_els  = pat_struc.asap_model.frame_elements
n_els = length(base_els)

# Collect per-element max |force| for moments (DOFs 5,6,11,12) and axials (DOFs 1,7)
# Frame element DOFs: [N1 V1y V1z M1x M1y M1z N2 V2y V2z M2x M2y M2z]
moment_dofs = [5, 6, 11, 12]
axial_dofs  = [1, 7]
shear_dofs  = [2, 3, 8, 9]

# Collect max across all elements
base_max_moment = 0.0; pat_max_moment = 0.0
base_max_axial  = 0.0; pat_max_axial  = 0.0
base_max_shear  = 0.0; pat_max_shear  = 0.0

# Per-element comparison: count how many have increased forces
n_moment_increase = 0
n_axial_increase  = 0
n_shear_increase  = 0
total_moment_increase_pct = 0.0

for i in 1:n_els
    bf = base_els[i].forces
    pf = pat_els[i].forces
    
    bm = maximum(abs(bf[k]) for k in moment_dofs if k <= length(bf))
    pm = maximum(abs(pf[k]) for k in moment_dofs if k <= length(pf))
    base_max_moment = max(base_max_moment, bm)
    pat_max_moment  = max(pat_max_moment, pm)
    if pm > bm + 1e-6
        n_moment_increase += 1
        total_moment_increase_pct += (pm - bm) / max(bm, 1e-12) * 100
    end
    
    ba = maximum(abs(bf[k]) for k in axial_dofs if k <= length(bf))
    pa = maximum(abs(pf[k]) for k in axial_dofs if k <= length(pf))
    base_max_axial = max(base_max_axial, ba)
    pat_max_axial  = max(pat_max_axial, pa)
    if pa > ba + 1e-6; n_axial_increase += 1; end
    
    bs = maximum(abs(bf[k]) for k in shear_dofs if k <= length(bf))
    ps = maximum(abs(pf[k]) for k in shear_dofs if k <= length(pf))
    base_max_shear = max(base_max_shear, bs)
    pat_max_shear  = max(pat_max_shear, ps)
    if ps > bs + 1e-6; n_shear_increase += 1; end
end

avg_moment_pct = n_moment_increase > 0 ? total_moment_increase_pct / n_moment_increase : 0.0

@printf("    %-28s %12s %12s %8s\n",
        "Force Type", "No Pattern", "Pattern", "Δ%")
@printf("    %-28s %12s %12s %8s\n",
        "─"^28, "─"^12, "─"^12, "─"^8)
@printf("    %-28s %12.0f %12.0f %+7.1f%%\n",
        "Max moment (N·m)",
        base_max_moment, pat_max_moment,
        (pat_max_moment / max(base_max_moment, 1e-12) - 1) * 100)
@printf("    %-28s %12.0f %12.0f %+7.1f%%\n",
        "Max axial (N)",
        base_max_axial, pat_max_axial,
        (pat_max_axial / max(base_max_axial, 1e-12) - 1) * 100)
@printf("    %-28s %12.0f %12.0f %+7.1f%%\n",
        "Max shear (N)",
        base_max_shear, pat_max_shear,
        (pat_max_shear / max(base_max_shear, 1e-12) - 1) * 100)
println()

@printf("    %-28s %8s\n", "Elements with ↑ moment:", "$n_moment_increase / $n_els")
@printf("    %-28s %8s\n", "Elements with ↑ axial:",  "$n_axial_increase / $n_els")
@printf("    %-28s %8s\n", "Elements with ↑ shear:",  "$n_shear_increase / $n_els")
if n_moment_increase > 0
    @printf("    %-28s %7.1f%%\n", "Avg moment increase:", avg_moment_pct)
end
println()

_rpt.note("Pattern envelope ≥ single-solve. Typical increase: 5-15% on moments.")

@test pat_max_moment >= base_max_moment - 1.0  # envelope should be ≥ base (with tolerance)

# ─── 14D: Pattern Loading Modes Summary ────────────────────────────────────
_rpt.sub("14D — Pattern Loading Modes (DesignParameters.pattern_loading)")
println()
@printf("    %-14s  %-60s\n", "Mode", "Behavior")
@printf("    %-14s  %-60s\n", "─"^14, "─"^60)
@printf("    %-14s  %-60s\n", ":none",
        "Single solve with full D+L. No patterns. (Default)")
@printf("    %-14s  %-60s\n", ":auto",
        "Skip if L/D ≤ 0.75 for all cells; else run checkerboard.")
@printf("    %-14s  %-60s\n", ":checkerboard",
        "Always run checkerboard patterns regardless of L/D.")
println()
_rpt.note("Recommended: :auto for production use. :checkerboard for conservative. :none for speed.")

# ─── 14E: :auto vs :checkerboard Side-by-Side ─────────────────────────────
_rpt.sub("14E — :auto vs :checkerboard (Same Geometry)")
println("  When L/D > 0.75, :auto triggers patterns → identical to :checkerboard.")

auto_params = DesignParameters(pattern_loading = :auto)
auto_struc = with_logger(NullLogger()) do
    _skel = gen_medium_office(sz_Lx, sz_Ly, sz_H, 3, 3, 1)
    _struc = BuildingStructure(_skel)
    _opts = FlatPlateOptions(material=RC_4000_60, method=DDM(), cover=0.75u"inch", bar_size=5)
    initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c_i in _struc.cells
        c_i.sdl = uconvert(u"kN/m^2", pat_sdl_heavy)
        c_i.live_load = uconvert(u"kN/m^2", pat_ll_heavy)
    end
    for col_i in _struc.columns; col_i.c1 = sz_c0; col_i.c2 = sz_c0; end
    to_asap!(_struc; params=auto_params)
    sync_asap!(_struc; params=auto_params)
    _struc
end

# Compare :auto vs :checkerboard max moments
auto_max_moment = maximum(maximum(abs(el.forces[k]) for k in moment_dofs if k <= length(el.forces))
                          for el in auto_struc.asap_model.frame_elements)

@printf("    %-20s %12s %12s %12s\n",
        "Mode", ":none", ":auto", ":checkerboard")
@printf("    %-20s %12s %12s %12s\n",
        "─"^20, "─"^12, "─"^12, "─"^12)
@printf("    %-20s %12.0f %12.0f %12.0f\n",
        "Max moment (N·m)", base_max_moment, auto_max_moment, pat_max_moment)
@printf("    %-20s %12.0f %12.0f %12.0f\n",
        "Max axial (N)", base_max_axial,
        maximum(maximum(abs(el.forces[k]) for k in axial_dofs if k <= length(el.forces))
                for el in auto_struc.asap_model.frame_elements),
        pat_max_axial)
println()

# :auto should match :checkerboard for this case (L/D > 0.75)
auto_vs_pat = abs(auto_max_moment - pat_max_moment) / max(pat_max_moment, 1e-12)
@printf("    :auto vs :checkerboard difference: %.2f%%\n", auto_vs_pat * 100)
println()
_rpt.note("L/D>0.75 → :auto = :checkerboard. L/D≤0.75 → :auto = :none.")

@test auto_vs_pat < 0.01  # should be identical (same geometry, same patterns)

_step_status["Pattern Loading"] = "✓"

# ── DESIGN CODE FEATURES & LIMITATIONS ──

_rpt.section("DESIGN CODE FEATURES & LIMITATIONS")

_rpt.sub("13A — Feature Matrix")
println()
println("    Feature                          DDM       EFM       FEA")
println("    ────────────────────────────── ──────── ──────── ────────")
println("    Total static moment M₀              ✓        ✓        ✓")
println("    Longitudinal distribution            ✓        —        —")
println("      (ACI Table 8.10.4.2 coeffs)")
println("    Frame analysis (stiffness)           —        ✓        —")
println("      (Kec, Ks, COF, FEM)")
println("    2D shell FEA (Tri3 mesh)             —        —        ✓")
println("    Transverse distribution               ✓        ✓        ✓")
println("      (ACI 8.10.5 col/mid strip)")
println("    Multi-span frame analysis            ✓        ✓        ✓")
println("    Irregular grid support               —        —        ✓")
println("    Punching shear (§22.6)               ✓        ✓        ✓")
println("    Unbalanced moment transfer           ✓        ✓        ✓")
println("    Two-way deflection (§24.2)           ✓        ✓        ✓")
println("    Direct FEA displacement              —        —        ✓")
println("      (Ig/Ie cracking correction)")
println("    One-way shear (§22.5)                ✓        ✓        ✓")
println("    Reinforcement design                 ✓        ✓        ✓")
println("    Integrity rebar (§8.7.4.2)           ✓        ✓        ✓")
println("    Pattern loading (§6.4.3)             ✓        ✓        ✓")
println("    Headed shear studs                   ✓        ✓        ✓")
println("    Slab thickness iteration             ✓        ✓        ✓")
println("    Column P-M co-design                 ✓        ✓        ✓")
println("    Auto-fallback to FEA                 ✓        ✓        —")
println("    Applicability checks                 ✓        ✓        —")
println("      (DDM 7-rule / EFM 3-rule)")
println("    ── Flat Slab / Drop Panel ──")
println("    Drop panel geometry (§8.2.4)         ✓        ✓        ✓")
println("    Auto-size drop depth & extent        ✓        ✓        ✓")
println("    Dual punching check (col+drop)       ✓        ✓        ✓")
println("    Weighted self-weight (slab+drop)     ✓        ✓        ✓")
println("    Flat slab min h (Table 8.3.1.1)      ✓        ✓        ✓")
println("    ── Edge Beam / βt ──")
println("    Edge beam βt computation             ✓        —        —")
println("    βt user override (edge_beam_βt)      ✓        —        —")
println("    Compression steel ρ' for λΔ          ✓        ✓        ✓")
println()

_rpt.sub("13B — Shared Components")
println("    Shared pipeline: MomentAnalysisResult → punching → deflection → shear → rebar")
println("    Shared ACI: punching (§22.6), γf/γv (§8.4.2.3), one-way Vc (§22.5), Mcr/Ie (§24.2)")

_rpt.sub("13C — Limitations")
println("    1. FEA: point-spring supports  2. HC: limited stiff-frame convergence")
println("    3. Mxy diagnostic only  4. Perp. FEA M not fed to rebar  5. No cracked-section FEA")
println("    6. Pattern forces not yet fed back into slab sizing")

# ── SUMMARY ──

_rpt.section("SUMMARY")
ordered_steps = [
    "Load Baseline", "Section Properties", "EFM Stiffnesses", "Static Moment",
    "Method Comparison", "Effective Depth", "Reinforcement",
    "Punching Shear", "Deflection", "Column Axial Load", "Integrity Rebar",
    "Sensitivity Studies", "Full Sizing", "Flat Slab", "Pattern Loading",
]
println("  Validated: DDM, MDDM, EFM(HC/ASAP), FEA(Shell), flat slab, pattern loading.")
println()

@printf("    %-24s  %s\n", "Step", "Status")
@printf("    %-24s  %s\n", "─"^24, "─"^24)
for step in ordered_steps
    status = get(_step_status, step, "?")
    @printf("    %-24s  %s\n", step, status)
end

println()
println("  Reference: DE-Two-Way-Flat-Plate (ACI 318-14), spSlab v10.00")
println("  Geometry:  l₁=$l1 × l₂=$l2  h=$h  c=$c_col  H=$H")
println("  Loads:     SDL=$sdl  LL=$ll  qᵤ=$qu")

@test true  # sentinel
end
