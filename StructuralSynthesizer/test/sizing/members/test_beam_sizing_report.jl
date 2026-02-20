# ==============================================================================
# Beam Sizing Validation Report
# ==============================================================================
# This report validates beam sizing across four beam types:
#   1. RC Beams          (ACI 318-19)  — MIP catalog + NLP continuous
#   2. RC T-Beams        (ACI 318-19)  — MIP catalog + NLP continuous (fixed bf/hf)
#   3. Steel W Beams     (AISC 360-16) — MIP catalog + NLP continuous
#   4. Steel HSS Beams   (AISC 360-16) — MIP catalog + NLP continuous
#
# For each section the report:
#   a. Sizes via discrete MIP (optimize_discrete → catalog selection)
#   b. Sizes via continuous NLP (optimize_continuous → snapped + unsnapped)
#   c. Computes analytical capacity ratios (flexure, shear)
#   d. Compares across materials, approaches, & demand levels
#
# T-Beam additions (§9–§12):
#   - T-beam MIP & NLP sizing at two demand levels
#   - T-beam vs rectangular efficiency comparison
#   - Adversarial tributary flange width (moment-weighted average depth)
#   - ACI rectangular grid recovery and cap verification
#
# Deflection additions (§13–§14):
#   - Steel beam deflection: required_Ix_for_deflection + NLP Ix_min constraint
#   - RC T-beam deflection: design_tbeam_deflection (ACI §24.2, Ie with T-shape)
#   - Comparison of T-beam vs rectangular deflection behavior
#   - Auto-integrated deflection in NLP (Δ_LL + Δ_total constraints) and MIP (is_feasible)
#   - Also fixed cracked NA quadratic bug in cracked_moment_of_inertia_tbeam
#
# Torsion additions (§15):
#   - RC beam torsion: design_beam_torsion (ACI 318-19 §22.7)
#   - Compatibility vs equilibrium torsion modes
#   - T-beam torsion with limited flange overhang (§22.7.4.1)
#   - Steel W-shape torsion: design_w_torsion (AISC Design Guide 9)
#   - Steel HSS torsion: AISC H3-6 interaction (closed section)
#   - MIP checker integration (is_feasible rejects sections failing §22.7.7.1)
#   - NLP integration: torsion constraints in all 4 beam types (§15.3)
#
# Notes:
#   - RC beam NLP optimizes b, h, ρ with ACI 318 flexure + shear constraints.
#   - RC T-beam NLP optimizes bw, h, ρ with fixed bf/hf from slab sizing.
#   - Steel W beam NLP: dedicated AISC F2 (flexure + LTB) + G2 (shear).
#   - Steel HSS beam NLP: dedicated AISC F7 (flexure) + G4 (shear).
#   - NLP shown with snap=true (rounded to practical dims) and snap=false (raw).
#   - Deflection checks validated for steel beams (Ix_min) and RC T-beams (Ie).
#
# Format follows the EFM slab & column validation reports.
#
# Reference:
#   - StructurePoint spBeam for ACI 318 RC beam design
#   - AISC Steel Construction Manual 15th Ed.
#   - ACI 318-19 Table 6.3.2.1 (effective flange width)
# ==============================================================================

using Test
using Printf
using Dates
using Unitful
using Unitful: @u_str
using Asap
using Asap: TributaryPolygon

using StructuralSizer
import JuMP

# ─────────────────────────────────────────────────────────────────────────────
# Report helpers (consistent with column report)
# ─────────────────────────────────────────────────────────────────────────────

const BM_HLINE = "─"^78
const BM_DLINE = "═"^78

bm_section_header(title) = println("\n", BM_DLINE, "\n  ", title, "\n", BM_DLINE)
bm_sub_header(title)     = println("\n  ", BM_HLINE, "\n  ", title, "\n  ", BM_HLINE)
bm_note(msg)             = println("    → ", msg)

function bm_table_head(ref_label="Ref")
    @printf("    %-32s %12s %12s %8s %s\n",
            "Quantity", "Computed", ref_label, "Δ%", "")
    @printf("    %-32s %12s %12s %8s %s\n",
            "─"^32, "─"^12, "─"^12, "─"^8, "──")
end

"""Print one comparison row. Returns `true` when |δ| ≤ tol."""
function bm_compare(label, computed, reference; tol=0.10)
    v = Float64(computed)
    r = Float64(reference)
    δ = abs(r) > 1e-12 ? (v - r) / abs(r) : 0.0
    ok = abs(δ) ≤ tol
    flag = ok ? "✓" : (abs(δ) ≤ 2tol ? "~" : "✗")
    @printf("    %-32s %12.2f %12.2f %+7.1f%%  %s\n", label, v, r, 100δ, flag)
    return ok
end

# ─────────────────────────────────────────────────────────────────────────────
# 4-column summary table:  Demand | MIP | NLP(raw) | NLP(snap)
# ─────────────────────────────────────────────────────────────────────────────
_fv(x; d=1) = x === nothing ? "—" : string(round(Float64(x), digits=d))

function summary_head()
    @printf("    %-24s %9s %9s %9s %9s\n",
            "Quantity", "Demand", "MIP", "NLP(raw)", "NLP(snap)")
    @printf("    %-24s %9s %9s %9s %9s\n",
            "─"^24, "─"^9, "─"^9, "─"^9, "─"^9)
end

function summary_row(label, demand, mip, nlp_raw, nlp_snap; d=1)
    @printf("    %-24s %9s %9s %9s %9s\n",
            label, _fv(demand; d), _fv(mip; d), _fv(nlp_raw; d), _fv(nlp_snap; d))
end

function summary_row_s(label, d_s, m_s, r_s, s_s)
    @printf("    %-24s %9s %9s %9s %9s\n", label, d_s, m_s, r_s, s_s)
end

# Collect pass/fail per section
bm_step_status = Dict{String,String}()

# ─────────────────────────────────────────────────────────────────────────────
# Analytical capacity helpers
# ─────────────────────────────────────────────────────────────────────────────

"""
Compute ACI flexural capacity φMn (kip·ft) for an RCBeamSection.

Uses Whitney stress block approach:
  a  = As × fy / (0.85 f'c b)
  c  = a / β₁
  εt = 0.003 (d − c) / c
  φ  = strain-dependent per ACI Table 21.2.2
  Mn = As × fy × (d − a/2)
"""
function rc_beam_flexure(section::RCBeamSection, fc_psi, fy_psi)
    b_in  = ustrip(u"inch", section.b)
    d_in  = ustrip(u"inch", section.d)
    As_in = ustrip(u"inch^2", section.As)

    As_in > 0 || return (φMn_kipft=0.0, a_in=0.0, c_in=0.0, εt=0.0, φ=0.0)

    a_in = As_in * fy_psi / (0.85 * fc_psi * b_in)
    β1   = fc_psi ≤ 4000 ? 0.85 :
           fc_psi ≥ 8000 ? 0.65 :
           0.85 - 0.05 * (fc_psi - 4000) / 1000
    c_in = a_in / β1
    εt   = c_in > 0 ? 0.003 * (d_in - c_in) / c_in : 0.0

    φ = εt ≥ 0.005 ? 0.90 :
        εt ≤ 0.002 ? 0.65 :
        0.65 + 0.25 * (εt - 0.002) / 0.003

    Mn_lbin = As_in * fy_psi * (d_in - a_in / 2)
    φMn     = φ * Mn_lbin / 12_000.0   # kip·ft

    return (φMn_kipft=φMn, a_in=a_in, c_in=c_in, εt=εt, φ=φ)
end

"""
Compute ACI maximum shear capacity φVn_max (kip) for an RCBeamSection.

  Vc     = 2 λ √f'c bw d
  Vs_max = 8 √f'c bw d        (ACI §22.5.1.2)
  φVn    = 0.75 (Vc + Vs_max)
"""
function rc_beam_shear(section::RCBeamSection, fc_psi; λ=1.0)
    b_in = ustrip(u"inch", section.b)
    d_in = ustrip(u"inch", section.d)
    sqfc = sqrt(fc_psi)
    Vc   = 2 * λ * sqfc * b_in * d_in          # lb
    Vs_max = 8 * sqfc * b_in * d_in             # lb
    φVn  = 0.75 * (Vc + Vs_max) / 1000.0       # kip
    Vc_kip = Vc / 1000.0
    return (φVn_max_kip=φVn, Vc_kip=Vc_kip)
end

"""
Compute AISC strong-axis flexural + shear check for a steel beam section.
Strips all quantities to SI Float64 (N, N·m) before arithmetic.
Returns named tuple with utilization and component capacities.
"""
function steel_beam_utilization(section, material, Mu, Vu, geom; ϕ_b=0.9, ϕ_v=1.0)
    # Convert demands to SI Float64
    Mu_Nm = ustrip(u"N*m", Mu)
    Vu_N  = ustrip(u"N",   Vu)

    # Capacities in SI Float64
    ϕMnx_Nm = ustrip(u"N*m", get_ϕMn(section, material; Lb=geom.Lb, Cb=geom.Cb,
                                       axis=:strong, ϕ=ϕ_b))
    ϕVn_N   = ustrip(u"N",   get_ϕVn(section, material; axis=:strong, ϕ=ϕ_v))

    # Utilization ratios (plain Float64)
    util_M = Mu_Nm / ϕMnx_Nm
    util_V = Vu_N  / ϕVn_N
    util   = max(util_M, util_V)

    # Return with Unitful capacities for display
    ϕMnx = ϕMnx_Nm * u"N*m"
    ϕVn  = ϕVn_N   * u"N"
    return (utilization=util, ϕMnx=ϕMnx, ϕVn=ϕVn,
            util_M=util_M, util_V=util_V,
            adequate=util ≤ 1.0)
end

"""
Compute ACI flexural capacity φMn (kip·ft) for an RCTBeamSection.

Uses Whitney stress block with T-beam decomposition:
  Case 1 (a ≤ hf): rectangular behavior with flange width bf
  Case 2 (a > hf): T-beam Cf + Cw decomposition
"""
function rc_tbeam_flexure(section::RCTBeamSection, fc_psi, fy_psi)
    bw_in = ustrip(u"inch", section.bw)
    bf_in = ustrip(u"inch", section.bf)
    hf_in = ustrip(u"inch", section.hf)
    d_in  = ustrip(u"inch", section.d)
    As_in = ustrip(u"inch^2", section.As)

    As_in > 0 || return (φMn_kipft=0.0, a_in=0.0, c_in=0.0, εt=0.0, φ=0.0, case=:none)

    a_trial = As_in * fy_psi / (0.85 * fc_psi * bf_in)
    β1 = fc_psi ≤ 4000 ? 0.85 :
         fc_psi ≥ 8000 ? 0.65 :
         0.85 - 0.05 * (fc_psi - 4000) / 1000

    if a_trial ≤ hf_in
        a_in = a_trial
        c_in = a_in / β1
        εt = c_in > 0 ? 0.003 * (d_in - c_in) / c_in : 0.0
        Mn_lbin = As_in * fy_psi * (d_in - a_in / 2)
        case_sym = :flange
    else
        Cf_lb = 0.85 * fc_psi * (bf_in - bw_in) * hf_in
        Cw_lb = As_in * fy_psi - Cf_lb
        a_in = Cw_lb / (0.85 * fc_psi * bw_in)
        c_in = a_in / β1
        εt = c_in > 0 ? 0.003 * (d_in - c_in) / c_in : 0.0
        Mn_lbin = Cf_lb * (d_in - hf_in / 2) + Cw_lb * (d_in - a_in / 2)
        case_sym = :web
    end

    φ = εt ≥ 0.005 ? 0.90 :
        εt ≤ 0.002 ? 0.65 :
        0.65 + 0.25 * (εt - 0.002) / 0.003
    φMn = φ * Mn_lbin / 12_000.0

    return (φMn_kipft=φMn, a_in=a_in, c_in=c_in, εt=εt, φ=φ, case=case_sym)
end

"""
Compute ACI maximum shear capacity φVn_max (kip) for an RCTBeamSection.
Uses web width bw × d (not bf) per ACI 318-19 §22.5.
"""
function rc_tbeam_shear(section::RCTBeamSection, fc_psi; λ=1.0)
    bw_in = ustrip(u"inch", section.bw)
    d_in  = ustrip(u"inch", section.d)
    sqfc  = sqrt(fc_psi)
    Vc    = 2 * λ * sqfc * bw_in * d_in
    Vs_max = 8 * sqfc * bw_in * d_in
    φVn   = 0.75 * (Vc + Vs_max) / 1000.0
    Vc_kip = Vc / 1000.0
    return (φVn_max_kip=φVn, Vc_kip=Vc_kip)
end

"""Make a TributaryPolygon from boundary vertices in (s, d) space.
Used for adversarial tributary flange width tests in the report."""
function _report_make_trib(; s::Vector{Float64}, d::Vector{Float64},
                    local_edge_idx::Int = 1, beam_length::Float64 = 10.0)
    n = length(s)
    area_sd = 0.0
    for i in 1:n
        j = mod1(i + 1, n)
        area_sd += s[i] * d[j] - s[j] * d[i]
    end
    area_sd = abs(area_sd) / 2
    area_m2 = area_sd * beam_length
    TributaryPolygon(local_edge_idx, s, d, area_m2,
                     area_m2 / (beam_length * maximum(abs.(d); init=1.0)))
end

# ==============================================================================
@testset "Beam Sizing Validation Report" begin
# ==============================================================================

bm_section_header("BEAM SIZING VALIDATION REPORT")
println("  Generated: $(Dates.format(now(), "yyyy-mm-dd HH:MM"))  |  RC & steel beam sizing: MIP + NLP vs analytical capacity")

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  1.  INPUT SUMMARY                                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("1.0  Input Summary")

println("    Materials")
println("      Concrete : f'c = 4 000 psi  (NWC_4000, λ = 1.0)")
println("      Rebar    : fy  = 60 ksi     (Rebar_60)")
println("      Steel    : Fy  = 50 ksi     (A992_Steel)")
println()
println("    Demand Cases")
println("      RC Beam (mod)  : Mu = 120 kip·ft, Vu = 25 kip,  L = 6.0 m")
println("      RC Beam (hvy)  : Mu = 350 kip·ft, Vu = 60 kip,  L = 8.0 m")
println("      RC T-Beam (mod): Mu = 200 kip·ft, Vu = 40 kip,  L = 7.0 m  (bf=48\", hf=5\")")
println("      RC T-Beam (hvy): Mu = 400 kip·ft, Vu = 70 kip,  L = 9.0 m  (bf=60\", hf=6\")")
println("      Steel W Beam   : Mu = 150 kN·m,   Vu = 100 kN,  L = 8.0 m")
println("      Steel HSS Beam : Mu = 60 kN·m,    Vu = 80 kN,   L = 6.0 m")
println("      Deflection (W) : w_LL = 0.8 kip/ft, L = 25 ft  (steel W, L/360)")
println("      Deflection (T) : w_D = 1.2 kip/ft, w_L = 0.8 kip/ft, L = 25 ft  (T-beam, ACI §24.2)")

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  2.  RC BEAM — MODERATE LOAD  (ACI 318-19)                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("2.0  RC Beam — Moderate Load (ACI 318-19)")
println("    Mu = 120 kip·ft,  Vu = 25 kip,  L = 6.0 m")
bm_note("ACI 318-19: Whitney stress block (§22.2), concrete shear Vc + Vs (§22.5).")

Mu_mod = 120.0    # kip·ft
Vu_mod = 25.0     # kip
L_mod  = 6.0      # m
fc_psi = 4000.0
fy_psi = 60_000.0

# ── 2.1  MIP (Discrete Catalog) ──
println("\n  2.1  MIP (Discrete Catalog) Sizing")

rc_beam_mod = size_beams(
    [Mu_mod], [Vu_mod],
    [ConcreteMemberGeometry(L_mod)],
    ConcreteBeamOptions(grade=NWC_4000, rebar_grade=Rebar_60),
)
mod_sec  = rc_beam_mod.sections[1]
mod_area = ustrip(u"inch^2", section_area(mod_sec))

println("    Section : $(mod_sec.name)")
println("    b×h = $(ustrip(u"inch", mod_sec.b))\"×$(ustrip(u"inch", mod_sec.h))\",  d = $(round(ustrip(u"inch", mod_sec.d), digits=2))\",  As = $(round(ustrip(u"inch^2", mod_sec.As), digits=2)) in²")

# ── 2.2  NLP (Continuous Optimization) ──
println("\n  2.2  NLP (Continuous Optimization)")

rc_bm_nlp_base = (min_depth=12.0u"inch", max_depth=30.0u"inch",
                   min_width=10.0u"inch", max_width=24.0u"inch",
                   grade=NWC_4000, rebar_grade=Rebar_60, verbose=false)

rc_bm_nlp_snap = size_rc_beam_nlp(Mu_mod * 1.0u"kip*ft", Vu_mod * 1.0u"kip",
                                   NLPBeamOptions(; rc_bm_nlp_base..., snap=true))
rc_bm_nlp_raw  = size_rc_beam_nlp(Mu_mod * 1.0u"kip*ft", Vu_mod * 1.0u"kip",
                                   NLPBeamOptions(; rc_bm_nlp_base..., snap=false))

mod_nlp_area     = rc_bm_nlp_snap.area
mod_nlp_raw_area = rc_bm_nlp_raw.area

println("    Unsnapped : b=$(round(rc_bm_nlp_raw.b_final, digits=2))\", h=$(round(rc_bm_nlp_raw.h_final, digits=2))\"  →  A = $(round(mod_nlp_raw_area, digits=1)) in²")
println("    Snapped   : b=$(round(rc_bm_nlp_snap.b_final, digits=1))\", h=$(round(rc_bm_nlp_snap.h_final, digits=1))\"  →  A = $(round(mod_nlp_area, digits=1)) in²")
println("    ρ = $(round(rc_bm_nlp_snap.ρ_opt, digits=4)),  Status = $(rc_bm_nlp_snap.status)")

# ── 2.3  Comparison Summary ──
println("\n  2.3  Comparison Summary")

# Analytical capacities for each section
flex_mip   = rc_beam_flexure(mod_sec, fc_psi, fy_psi)
shear_mip  = rc_beam_shear(mod_sec, fc_psi)
flex_raw   = rc_beam_flexure(rc_bm_nlp_raw.section, fc_psi, fy_psi)
shear_raw  = rc_beam_shear(rc_bm_nlp_raw.section, fc_psi)
flex_snap  = rc_beam_flexure(rc_bm_nlp_snap.section, fc_psi, fy_psi)
shear_snap = rc_beam_shear(rc_bm_nlp_snap.section, fc_psi)

summary_head()
summary_row_s("Section", "—", string(mod_sec.name),
              "$(round(Int,rc_bm_nlp_raw.b_final))×$(round(Int,rc_bm_nlp_raw.h_final))",
              "$(round(Int,rc_bm_nlp_snap.b_final))×$(round(Int,rc_bm_nlp_snap.h_final))")
summary_row("Area (in²)",       nothing, mod_area, mod_nlp_raw_area, mod_nlp_area)
summary_row("φMn (kip·ft)",     Mu_mod,  flex_mip.φMn_kipft, flex_raw.φMn_kipft, flex_snap.φMn_kipft)
summary_row("φVn_max (kip)",    Vu_mod,  shear_mip.φVn_max_kip, shear_raw.φVn_max_kip, shear_snap.φVn_max_kip)
summary_row("Flexure util",     nothing, Mu_mod/flex_mip.φMn_kipft, Mu_mod/flex_raw.φMn_kipft, Mu_mod/flex_snap.φMn_kipft; d=3)
summary_row("Shear util",       nothing, Vu_mod/shear_mip.φVn_max_kip, Vu_mod/shear_raw.φVn_max_kip, Vu_mod/shear_snap.φVn_max_kip; d=3)
summary_row("εt",               nothing, flex_mip.εt, flex_raw.εt, flex_snap.εt; d=4)

flex_ok_mod  = Mu_mod / flex_mip.φMn_kipft ≤ 1.0
shear_ok_mod = Vu_mod / shear_mip.φVn_max_kip ≤ 1.0

println()
bm_note("Demand = factored load; MIP/NLP = φ-capacity. εt ≥ 0.005 → φ=0.9; snap rounds to 2\" increments.")

@testset "RC Beam — Moderate" begin
    @test flex_ok_mod
    @test shear_ok_mod
    @test mod_area > 0
    @test flex_mip.εt ≥ 0.004
    @test mod_nlp_area > 0
    @test mod_nlp_raw_area ≤ mod_nlp_area * 1.01
end
bm_step_status["RC Beam (mod)"] = (flex_ok_mod && shear_ok_mod) ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  3.  RC BEAM — HEAVY LOAD  (ACI 318-19)                                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("3.0  RC Beam — Heavy Load (ACI 318-19)")
println("    Mu = 350 kip·ft,  Vu = 60 kip,  L = 8.0 m")

Mu_hvy = 350.0
Vu_hvy = 60.0
L_hvy  = 8.0

# ── 3.1  MIP ──
println("\n  3.1  MIP (Discrete Catalog) Sizing")

rc_beam_hvy = size_beams(
    [Mu_hvy], [Vu_hvy],
    [ConcreteMemberGeometry(L_hvy)],
    ConcreteBeamOptions(grade=NWC_4000, rebar_grade=Rebar_60),
)
hvy_sec  = rc_beam_hvy.sections[1]
hvy_area = ustrip(u"inch^2", section_area(hvy_sec))

println("    Section : $(hvy_sec.name)")
println("    b×h = $(ustrip(u"inch", hvy_sec.b))\"×$(ustrip(u"inch", hvy_sec.h))\",  d = $(round(ustrip(u"inch", hvy_sec.d), digits=2))\",  As = $(round(ustrip(u"inch^2", hvy_sec.As), digits=2)) in²")

# ── 3.2  NLP ──
println("\n  3.2  NLP (Continuous Optimization)")

hvy_nlp_base = (min_depth=14.0u"inch", max_depth=36.0u"inch",
                min_width=12.0u"inch", max_width=24.0u"inch",
                grade=NWC_4000, rebar_grade=Rebar_60, verbose=false)

hvy_nlp_snap = size_rc_beam_nlp(Mu_hvy * 1.0u"kip*ft", Vu_hvy * 1.0u"kip",
                                NLPBeamOptions(; hvy_nlp_base..., snap=true))
hvy_nlp_raw  = size_rc_beam_nlp(Mu_hvy * 1.0u"kip*ft", Vu_hvy * 1.0u"kip",
                                NLPBeamOptions(; hvy_nlp_base..., snap=false))

hvy_nlp_area     = hvy_nlp_snap.area
hvy_nlp_raw_area = hvy_nlp_raw.area

println("    Unsnapped : b=$(round(hvy_nlp_raw.b_final, digits=2))\", h=$(round(hvy_nlp_raw.h_final, digits=2))\"  →  A = $(round(hvy_nlp_raw_area, digits=1)) in²")
println("    Snapped   : b=$(round(hvy_nlp_snap.b_final, digits=1))\", h=$(round(hvy_nlp_snap.h_final, digits=1))\"  →  A = $(round(hvy_nlp_area, digits=1)) in²")
println("    ρ = $(round(hvy_nlp_snap.ρ_opt, digits=4)),  Status = $(hvy_nlp_snap.status)")

# ── 3.3  Comparison Summary ──
println("\n  3.3  Comparison Summary")

flex_hvy_mip   = rc_beam_flexure(hvy_sec, fc_psi, fy_psi)
shear_hvy_mip  = rc_beam_shear(hvy_sec, fc_psi)
flex_hvy_raw   = rc_beam_flexure(hvy_nlp_raw.section, fc_psi, fy_psi)
shear_hvy_raw  = rc_beam_shear(hvy_nlp_raw.section, fc_psi)
flex_hvy_snap  = rc_beam_flexure(hvy_nlp_snap.section, fc_psi, fy_psi)
shear_hvy_snap = rc_beam_shear(hvy_nlp_snap.section, fc_psi)

summary_head()
summary_row_s("Section", "—", string(hvy_sec.name),
              "$(round(Int,hvy_nlp_raw.b_final))×$(round(Int,hvy_nlp_raw.h_final))",
              "$(round(Int,hvy_nlp_snap.b_final))×$(round(Int,hvy_nlp_snap.h_final))")
summary_row("Area (in²)",       nothing, hvy_area, hvy_nlp_raw_area, hvy_nlp_area)
summary_row("φMn (kip·ft)",     Mu_hvy,  flex_hvy_mip.φMn_kipft, flex_hvy_raw.φMn_kipft, flex_hvy_snap.φMn_kipft)
summary_row("φVn_max (kip)",    Vu_hvy,  shear_hvy_mip.φVn_max_kip, shear_hvy_raw.φVn_max_kip, shear_hvy_snap.φVn_max_kip)
summary_row("Flexure util",     nothing, Mu_hvy/flex_hvy_mip.φMn_kipft, Mu_hvy/flex_hvy_raw.φMn_kipft, Mu_hvy/flex_hvy_snap.φMn_kipft; d=3)
summary_row("Shear util",       nothing, Vu_hvy/shear_hvy_mip.φVn_max_kip, Vu_hvy/shear_hvy_raw.φVn_max_kip, Vu_hvy/shear_hvy_snap.φVn_max_kip; d=3)

flex_ok_hvy  = Mu_hvy / flex_hvy_mip.φMn_kipft ≤ 1.0
shear_ok_hvy = Vu_hvy / shear_hvy_mip.φVn_max_kip ≤ 1.0

@testset "RC Beam — Heavy" begin
    @test flex_ok_hvy
    @test shear_ok_hvy
    @test hvy_area > mod_area
    @test hvy_nlp_area > 0
    @test hvy_nlp_area > mod_nlp_area
end
bm_step_status["RC Beam (hvy)"] = (flex_ok_hvy && shear_ok_hvy) ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  4.  RC BEAM — CONCRETE STRENGTH COMPARISON                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("4.0  RC Beam — Concrete Strength Comparison")
bm_note("Same demand, f'c = 4000 vs 6000 psi → higher strength should allow smaller section.")

Mu_cmp = 200.0
Vu_cmp = 40.0
L_cmp  = 7.0

r4 = size_beams([Mu_cmp], [Vu_cmp], [ConcreteMemberGeometry(L_cmp)],
                ConcreteBeamOptions(grade=NWC_4000))
r6 = size_beams([Mu_cmp], [Vu_cmp], [ConcreteMemberGeometry(L_cmp)],
                ConcreteBeamOptions(grade=NWC_6000))

a4 = ustrip(u"inch^2", section_area(r4.sections[1]))
a6 = ustrip(u"inch^2", section_area(r6.sections[1]))

@printf("    %-18s  %-18s  %-10s\n", "Concrete Grade", "Section", "Area (in²)")
@printf("    %-18s  %-18s  %-10s\n", "─"^18, "─"^18, "─"^10)
@printf("    %-18s  %-18s  %10.1f\n", "NWC 4000 psi", string(r4.sections[1].name), a4)
@printf("    %-18s  %-18s  %10.1f\n", "NWC 6000 psi", string(r6.sections[1].name), a6)

println()
bm_note("Higher f'c → deeper stress block capacity → smaller or same section.")

@testset "RC Beam — Concrete Strength" begin
    @test a6 ≤ a4 * 1.05   # Higher f'c ⇒ ≤ same area
    @test a4 > 0
    @test a6 > 0
end
bm_step_status["RC f'c Study"] = a6 ≤ a4 * 1.05 ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  5.  STEEL W BEAM  (AISC 360-16)                                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("5.0  Steel W Beam — AISC 360-16")
bm_note("AISC checker (Pu=0 pure flexure); shear checked analytically post-selection.")

Mu_sw = 150.0u"kN*m"
Vu_sw = 100.0u"kN"
L_sw  = 8.0   # m
sw_geom = SteelMemberGeometry(L_sw; Kx=1.0, Ky=1.0)

# ── 5.1  MIP (Discrete Catalog) ──
println("\n  5.1  MIP (Discrete Catalog) Sizing")

sw_opts = SteelBeamOptions(
    section_type = :w,
    objective    = MinVolume(),
)

sw_mip = size_beams([Mu_sw], [Vu_sw], [sw_geom], sw_opts)
sw_sec  = sw_mip.sections[1]
sw_area = ustrip(u"inch^2", section_area(sw_sec))

println("    Section : $(sw_sec.name)")
println("    Area    : $(round(sw_area, digits=2)) in²")
println("    d       : $(round(ustrip(u"inch", section_depth(sw_sec)), digits=1))\"")

sw_chk = steel_beam_utilization(sw_sec, A992_Steel, Mu_sw, Vu_sw, sw_geom)
println("    Mu/φMn : $(round(sw_chk.util_M, digits=3)),  Vu/φVn : $(round(sw_chk.util_V, digits=3))  ($(sw_chk.adequate ? "✓ PASS" : "✗ FAIL"))")

# ── 5.2  NLP (Continuous Optimization) ──
println("\n  5.2  NLP (Continuous Optimization) Sizing")
bm_note("Steel W NLP: AISC F2 (flexure+LTB) + G2 (shear); MIP warm-start for convergence.")

sw_nlp_base = (min_depth = 8.0u"inch", max_depth = 24.0u"inch", verbose = false)

# Warm-start from MIP section dimensions
sw_x0 = [ustrip(u"inch", sw_sec.d), ustrip(u"inch", sw_sec.bf),
          ustrip(u"inch", sw_sec.tf), ustrip(u"inch", sw_sec.tw)]

sw_nlp = size_steel_w_beam_nlp(Mu_sw, Vu_sw, sw_geom,
                                NLPWOptions(; sw_nlp_base..., snap=true); x0=sw_x0)
sw_nlp_area = sw_nlp.area

sw_nlp_raw = size_steel_w_beam_nlp(Mu_sw, Vu_sw, sw_geom,
                                    NLPWOptions(; sw_nlp_base..., snap=false); x0=sw_x0)
sw_nlp_raw_area = sw_nlp_raw.area

println("    Unsnapped : d=$(round(sw_nlp_raw.d_final, digits=2))\", bf=$(round(sw_nlp_raw.bf_final, digits=2))\"  →  A = $(round(sw_nlp_raw_area, digits=2)) in²")
println("    Snapped   : d=$(round(sw_nlp.d_final, digits=1))\", bf=$(round(sw_nlp.bf_final, digits=1))\"  →  A = $(round(sw_nlp_area, digits=2)) in²")
println("    Status    : $(sw_nlp.status)")

# Analytical capacity for NLP sections (using .section field)
sw_nlp_chk     = steel_beam_utilization(sw_nlp.section, A992_Steel, Mu_sw, Vu_sw, sw_geom)
sw_nlp_raw_chk = steel_beam_utilization(sw_nlp_raw.section, A992_Steel, Mu_sw, Vu_sw, sw_geom)

# ── 5.3  Comparison Summary ──
println("\n  5.3  Comparison Summary")

summary_head()
summary_row_s("Section", "—", string(sw_sec.name),
              "d=$(round(sw_nlp_raw.d_final,digits=1))\"",
              "d=$(round(sw_nlp.d_final,digits=1))\"")
summary_row("Area (in²)",        nothing, sw_area, sw_nlp_raw_area, sw_nlp_area)
summary_row("φMnx (kN·m)",      ustrip(u"kN*m", Mu_sw),
             ustrip(u"kN*m", sw_chk.ϕMnx), ustrip(u"kN*m", sw_nlp_raw_chk.ϕMnx), ustrip(u"kN*m", sw_nlp_chk.ϕMnx))
summary_row("φVn (kN)",         ustrip(u"kN", Vu_sw),
             ustrip(u"kN", sw_chk.ϕVn), ustrip(u"kN", sw_nlp_raw_chk.ϕVn), ustrip(u"kN", sw_nlp_chk.ϕVn))
summary_row("Flexure util",     nothing, sw_chk.util_M, sw_nlp_raw_chk.util_M, sw_nlp_chk.util_M; d=3)
summary_row("Shear util",       nothing, sw_chk.util_V, sw_nlp_raw_chk.util_V, sw_nlp_chk.util_V; d=3)
summary_row("Weight (lb/ft)",   nothing, nothing, sw_nlp_raw.weight_per_ft, sw_nlp.weight_per_ft)

println()
bm_note("NLP = continuous I-shape (F2+G2); MIP = rolled W catalog. Demand = factored Mu/Vu.")

@testset "Steel W Beam" begin
    @test sw_chk.adequate
    @test sw_area > 0
    @test sw_chk.util_M ≤ 1.0
    @test sw_chk.util_V ≤ 1.0
    @test sw_nlp_area > 0
    @test sw_nlp_raw_area ≤ sw_nlp_area * 1.01
end
bm_step_status["Steel W Beam"] = sw_chk.adequate ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  6.  STEEL HSS BEAM  (AISC 360-16)                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("6.0  Steel HSS Rectangular Beam — AISC 360-16")
bm_note("HSS sections are compact for flexure — no LTB for closed sections.")

Mu_sh = 60.0u"kN*m"
Vu_sh = 80.0u"kN"
L_sh  = 6.0
sh_geom = SteelMemberGeometry(L_sh; Kx=1.0, Ky=1.0)

# ── 6.1  MIP (Discrete Catalog) ──
println("\n  6.1  MIP (Discrete Catalog) Sizing")

sh_opts = SteelBeamOptions(
    section_type = :hss,
    objective    = MinVolume(),
)

sh_mip = size_beams([Mu_sh], [Vu_sh], [sh_geom], sh_opts)
sh_sec  = sh_mip.sections[1]
sh_area = ustrip(u"inch^2", section_area(sh_sec))

println("    Section : $(sh_sec.name)")
println("    Area    : $(round(sh_area, digits=2)) in²")

sh_chk = steel_beam_utilization(sh_sec, A992_Steel, Mu_sh, Vu_sh, sh_geom)
println("    Mu/φMn : $(round(sh_chk.util_M, digits=3)),  Vu/φVn : $(round(sh_chk.util_V, digits=3))  ($(sh_chk.adequate ? "✓ PASS" : "✗ FAIL"))")

# ── 6.2  NLP (Continuous Optimization) ──
println("\n  6.2  NLP (Continuous Optimization) Sizing")
bm_note("Steel HSS NLP: AISC F7 (flexure) + G4 (shear), no LTB; MIP warm-start for convergence.")

sh_nlp_base = (min_outer = 4.0u"inch", max_outer = 12.0u"inch", verbose = false)

# Warm-start from MIP section dimensions
sh_x0 = [ustrip(u"inch", sh_sec.B), ustrip(u"inch", sh_sec.H), ustrip(u"inch", sh_sec.t)]

sh_nlp = size_steel_hss_beam_nlp(Mu_sh, Vu_sh,
                                  NLPHSSOptions(; sh_nlp_base..., snap=true); x0=sh_x0)
sh_nlp_area = sh_nlp.area

sh_nlp_raw = size_steel_hss_beam_nlp(Mu_sh, Vu_sh,
                                      NLPHSSOptions(; sh_nlp_base..., snap=false); x0=sh_x0)
sh_nlp_raw_area = sh_nlp_raw.area

println("    Unsnapped : $(round(sh_nlp_raw.B_final, digits=2))×$(round(sh_nlp_raw.H_final, digits=2))×$(round(sh_nlp_raw.t_final, digits=4))  →  A = $(round(sh_nlp_raw_area, digits=2)) in²")
println("    Snapped   : $(sh_nlp.B_final)×$(sh_nlp.H_final)×$(sh_nlp.t_final)  →  A = $(round(sh_nlp_area, digits=2)) in²")
println("    Status    : $(sh_nlp.status)")

# Analytical capacity for NLP sections (using .section field)
sh_nlp_chk     = steel_beam_utilization(sh_nlp.section, A992_Steel, Mu_sh, Vu_sh, sh_geom)
sh_nlp_raw_chk = steel_beam_utilization(sh_nlp_raw.section, A992_Steel, Mu_sh, Vu_sh, sh_geom)

# ── 6.3  Comparison Summary ──
println("\n  6.3  Comparison Summary")

summary_head()
summary_row_s("Section", "—", string(sh_sec.name),
              "$(round(sh_nlp_raw.B_final,digits=1))×$(round(sh_nlp_raw.H_final,digits=1))",
              "$(sh_nlp.B_final)×$(sh_nlp.H_final)")
summary_row("Area (in²)",        nothing, sh_area, sh_nlp_raw_area, sh_nlp_area)
summary_row("φMnx (kN·m)",      ustrip(u"kN*m", Mu_sh),
             ustrip(u"kN*m", sh_chk.ϕMnx), ustrip(u"kN*m", sh_nlp_raw_chk.ϕMnx), ustrip(u"kN*m", sh_nlp_chk.ϕMnx))
summary_row("φVn (kN)",         ustrip(u"kN", Vu_sh),
             ustrip(u"kN", sh_chk.ϕVn), ustrip(u"kN", sh_nlp_raw_chk.ϕVn), ustrip(u"kN", sh_nlp_chk.ϕVn))
summary_row("Flexure util",     nothing, sh_chk.util_M, sh_nlp_raw_chk.util_M, sh_nlp_chk.util_M; d=3)
summary_row("Shear util",       nothing, sh_chk.util_V, sh_nlp_raw_chk.util_V, sh_nlp_chk.util_V; d=3)
summary_row("Weight (lb/ft)",   nothing, nothing, sh_nlp_raw.weight_per_ft, sh_nlp.weight_per_ft)

println()
bm_note("HSS closed section: no LTB. NLP uses F7 (flex, incl. noncompact) + G4 (shear).")

@testset "Steel HSS Beam" begin
    @test sh_chk.adequate
    @test sh_area > 0
    @test sh_nlp_area > 0
    @test sh_nlp_raw_area ≤ sh_nlp_area * 1.01
end
bm_step_status["Steel HSS Beam"] = sh_chk.adequate ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  7.  PARAMETRIC: RC BEAM DEMAND SCALING                                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("7.0  Parametric Study — RC Beam Demand Scaling")
bm_note("Scales Mu from 80–350 kip·ft with Vu proportional, L = 6 m.")

Mu_levels = [80.0, 120.0, 200.0, 300.0, 350.0]
Vu_scale  = [15.0,  25.0,  40.0,  55.0,  60.0]

@printf("    %-10s  %-8s  %-18s  %-10s  %-10s  %-10s\n",
        "Mu(kip·ft)", "Vu(kip)", "Section", "Area(in²)", "Mu/φMn", "Vu/φVn")
@printf("    %-10s  %-8s  %-18s  %-10s  %-10s  %-10s\n",
        "─"^10, "─"^8, "─"^18, "─"^10, "─"^10, "─"^10)

prev_area = 0.0
monotonic = true

for (Mu_i, Vu_i) in zip(Mu_levels, Vu_scale)
    r = size_beams([Mu_i], [Vu_i], [ConcreteMemberGeometry(6.0)],
                   ConcreteBeamOptions(grade=NWC_4000, rebar_grade=Rebar_60))
    sec = r.sections[1]
    a   = ustrip(u"inch^2", section_area(sec))

    flex = rc_beam_flexure(sec, 4000.0, 60_000.0)
    shear = rc_beam_shear(sec, 4000.0)
    u_m  = Mu_i / flex.φMn_kipft
    u_v  = Vu_i / shear.φVn_max_kip

    @printf("    %10.0f  %8.0f  %-18s  %10.1f  %10.3f  %10.3f\n",
            Mu_i, Vu_i, sec.name, a, u_m, u_v)

    if a < prev_area - 1.0  # allow tiny tolerance for catalog discreteness
        monotonic = false
    end
    prev_area = a
end

println()
bm_note("Area should increase monotonically with demand; Mu/φMn ≤ 1.0 for all cases.")

@testset "RC Beam Demand Scaling" begin
    # Check the extremes
    r_lo = size_beams([80.0], [15.0], [ConcreteMemberGeometry(6.0)],
                      ConcreteBeamOptions(grade=NWC_4000))
    r_hi = size_beams([350.0], [60.0], [ConcreteMemberGeometry(6.0)],
                      ConcreteBeamOptions(grade=NWC_4000))
    a_lo = ustrip(u"inch^2", section_area(r_lo.sections[1]))
    a_hi = ustrip(u"inch^2", section_area(r_hi.sections[1]))
    @test a_hi ≥ a_lo   # Monotonicity
    @test a_lo > 0
end

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  8.  BATCH SIZING: MULTIPLE RC BEAMS                                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("8.0  Batch Sizing — Multiple RC Beams")
bm_note("Sizes 3 beams simultaneously via vectorized MIP to verify batch API.")

Mu_batch = [80.0, 150.0, 300.0]
Vu_batch = [20.0,  35.0,  55.0]
geom_batch = [ConcreteMemberGeometry(6.0) for _ in 1:3]

batch_result = size_beams(
    Mu_batch, Vu_batch, geom_batch,
    ConcreteBeamOptions(grade=NWC_4000, rebar_grade=Rebar_60),
)

@printf("    %-6s  %-10s  %-8s  %-18s  %-10s\n",
        "Beam", "Mu(kip·ft)", "Vu(kip)", "Section", "Area(in²)")
@printf("    %-6s  %-10s  %-8s  %-18s  %-10s\n",
        "─"^6, "─"^10, "─"^8, "─"^18, "─"^10)

batch_areas = Float64[]
for (i, sec) in enumerate(batch_result.sections)
    a = ustrip(u"inch^2", section_area(sec))
    push!(batch_areas, a)
    @printf("    %6d  %10.0f  %8.0f  %-18s  %10.1f\n",
            i, Mu_batch[i], Vu_batch[i], sec.name, a)
end

@testset "Batch RC Beam Sizing" begin
    @test all(a -> a > 0, batch_areas)
    @test batch_areas[3] ≥ batch_areas[1]  # Monotonicity
    @test length(batch_result.sections) == 3
end
bm_step_status["RC Batch"] = batch_areas[3] ≥ batch_areas[1] ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  9.  RC T-BEAM — MODERATE LOAD (ACI 318-19)                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("9.0  RC T-Beam — Moderate Load (ACI 318-19)")
println("    Mu = 200 kip·ft,  Vu = 40 kip,  L = 7.0 m")
println("    bf = 48\",  hf = 5\"  (from slab sizing / tributary polygon)")
bm_note("ACI 318-19: T-beam Whitney stress block (§22.2), shear uses bw (§22.5).")

Mu_t_mod = 200.0    # kip·ft
Vu_t_mod = 40.0     # kip
L_t_mod  = 7.0      # m
bf_t_mod = 48.0u"inch"
hf_t_mod = 5.0u"inch"

# ── 9.1  MIP (Discrete Catalog) ──
println("\n  9.1  MIP (Discrete Catalog) Sizing")

rc_tbeam_mod = size_tbeams(
    [Mu_t_mod], [Vu_t_mod],
    [ConcreteMemberGeometry(L_t_mod)],
    ConcreteBeamOptions(grade=NWC_4000, rebar_grade=Rebar_60);
    flange_width=bf_t_mod, flange_thickness=hf_t_mod,
)
t_mod_sec  = rc_tbeam_mod.sections[1]
t_mod_bw   = ustrip(u"inch", t_mod_sec.bw)
t_mod_h    = ustrip(u"inch", t_mod_sec.h)
t_mod_area = t_mod_bw * t_mod_h  # web area

println("    Section : $(t_mod_sec.name)")
println("    bw×h = $(t_mod_bw)\"×$(t_mod_h)\",  d = $(round(ustrip(u"inch", t_mod_sec.d), digits=2))\",  As = $(round(ustrip(u"inch^2", t_mod_sec.As), digits=2)) in²")
println("    bf = $(ustrip(u"inch", t_mod_sec.bf))\",  hf = $(ustrip(u"inch", t_mod_sec.hf))\"")

# ── 9.2  NLP (Continuous Optimization) ──
println("\n  9.2  NLP (Continuous Optimization)")

t_nlp_base = (min_depth=14.0u"inch", max_depth=30.0u"inch",
              min_width=10.0u"inch", max_width=20.0u"inch",
              grade=NWC_4000, rebar_grade=Rebar_60, verbose=false)

t_nlp_snap = size_rc_tbeam_nlp(Mu_t_mod * 1.0u"kip*ft", Vu_t_mod * 1.0u"kip",
                                bf_t_mod, hf_t_mod,
                                NLPBeamOptions(; t_nlp_base..., snap=true))
t_nlp_raw  = size_rc_tbeam_nlp(Mu_t_mod * 1.0u"kip*ft", Vu_t_mod * 1.0u"kip",
                                bf_t_mod, hf_t_mod,
                                NLPBeamOptions(; t_nlp_base..., snap=false))

t_mod_nlp_area     = t_nlp_snap.area_web
t_mod_nlp_raw_area = t_nlp_raw.area_web

println("    Unsnapped : bw=$(round(t_nlp_raw.bw_final, digits=2))\", h=$(round(t_nlp_raw.h_final, digits=2))\"  →  Web A = $(round(t_mod_nlp_raw_area, digits=1)) in²")
println("    Snapped   : bw=$(round(t_nlp_snap.bw_final, digits=1))\", h=$(round(t_nlp_snap.h_final, digits=1))\"  →  Web A = $(round(t_mod_nlp_area, digits=1)) in²")
println("    ρ = $(round(t_nlp_snap.ρ_opt, digits=4)),  Status = $(t_nlp_snap.status)")

# ── 9.3  Comparison Summary ──
println("\n  9.3  Comparison Summary")

flex_t_mip   = rc_tbeam_flexure(t_mod_sec, fc_psi, fy_psi)
shear_t_mip  = rc_tbeam_shear(t_mod_sec, fc_psi)
flex_t_raw   = rc_tbeam_flexure(t_nlp_raw.section, fc_psi, fy_psi)
shear_t_raw  = rc_tbeam_shear(t_nlp_raw.section, fc_psi)
flex_t_snap  = rc_tbeam_flexure(t_nlp_snap.section, fc_psi, fy_psi)
shear_t_snap = rc_tbeam_shear(t_nlp_snap.section, fc_psi)

summary_head()
summary_row_s("Section", "—", string(t_mod_sec.name),
              "bw=$(round(Int,t_nlp_raw.bw_final))×$(round(Int,t_nlp_raw.h_final))",
              "bw=$(round(Int,t_nlp_snap.bw_final))×$(round(Int,t_nlp_snap.h_final))")
summary_row("Web Area (in²)",    nothing, t_mod_area, t_mod_nlp_raw_area, t_mod_nlp_area)
summary_row("φMn (kip·ft)",      Mu_t_mod, flex_t_mip.φMn_kipft, flex_t_raw.φMn_kipft, flex_t_snap.φMn_kipft)
summary_row("φVn_max (kip)",     Vu_t_mod, shear_t_mip.φVn_max_kip, shear_t_raw.φVn_max_kip, shear_t_snap.φVn_max_kip)
summary_row("Flexure util",      nothing, Mu_t_mod/flex_t_mip.φMn_kipft, Mu_t_mod/flex_t_raw.φMn_kipft, Mu_t_mod/flex_t_snap.φMn_kipft; d=3)
summary_row("Shear util",        nothing, Vu_t_mod/shear_t_mip.φVn_max_kip, Vu_t_mod/shear_t_raw.φVn_max_kip, Vu_t_mod/shear_t_snap.φVn_max_kip; d=3)
summary_row("εt",                nothing, flex_t_mip.εt, flex_t_raw.εt, flex_t_snap.εt; d=4)
summary_row_s("Stress block",    "—", string(flex_t_mip.case), string(flex_t_raw.case), string(flex_t_snap.case))

flex_ok_t_mod  = Mu_t_mod / flex_t_mip.φMn_kipft ≤ 1.0
shear_ok_t_mod = Vu_t_mod / shear_t_mip.φVn_max_kip ≤ 1.0

println()
bm_note("'flange' = a ≤ hf (rect. with bf); 'web' = T-beam decomp. Web area only (slab counted separately).")

@testset "RC T-Beam — Moderate" begin
    @test flex_ok_t_mod
    @test shear_ok_t_mod
    @test t_mod_area > 0
    @test flex_t_mip.εt ≥ 0.004
    @test t_mod_nlp_area > 0
    @test t_mod_nlp_raw_area ≤ t_mod_nlp_area * 1.01
end
bm_step_status["RC T-Beam (mod)"] = (flex_ok_t_mod && shear_ok_t_mod) ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  10. RC T-BEAM — HEAVY LOAD (ACI 318-19)                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("10.0  RC T-Beam — Heavy Load (ACI 318-19)")
println("    Mu = 400 kip·ft,  Vu = 70 kip,  L = 9.0 m")
println("    bf = 60\",  hf = 6\"  (from slab sizing / tributary polygon)")

Mu_t_hvy = 400.0
Vu_t_hvy = 70.0
L_t_hvy  = 9.0
bf_t_hvy = 60.0u"inch"
hf_t_hvy = 6.0u"inch"

# ── 10.1  MIP ──
println("\n  10.1  MIP (Discrete Catalog) Sizing")

rc_tbeam_hvy = size_tbeams(
    [Mu_t_hvy], [Vu_t_hvy],
    [ConcreteMemberGeometry(L_t_hvy)],
    ConcreteBeamOptions(grade=NWC_4000, rebar_grade=Rebar_60);
    flange_width=bf_t_hvy, flange_thickness=hf_t_hvy,
)
t_hvy_sec  = rc_tbeam_hvy.sections[1]
t_hvy_bw   = ustrip(u"inch", t_hvy_sec.bw)
t_hvy_h    = ustrip(u"inch", t_hvy_sec.h)
t_hvy_area = t_hvy_bw * t_hvy_h

println("    Section : $(t_hvy_sec.name)")
println("    bw×h = $(t_hvy_bw)\"×$(t_hvy_h)\",  d = $(round(ustrip(u"inch", t_hvy_sec.d), digits=2))\",  As = $(round(ustrip(u"inch^2", t_hvy_sec.As), digits=2)) in²")
println("    bf = $(ustrip(u"inch", t_hvy_sec.bf))\",  hf = $(ustrip(u"inch", t_hvy_sec.hf))\"")

# ── 10.2  NLP ──
println("\n  10.2  NLP (Continuous Optimization)")

t_hvy_nlp_base = (min_depth=16.0u"inch", max_depth=36.0u"inch",
                   min_width=10.0u"inch", max_width=24.0u"inch",
                   grade=NWC_4000, rebar_grade=Rebar_60, verbose=false)

t_hvy_nlp_snap = size_rc_tbeam_nlp(Mu_t_hvy * 1.0u"kip*ft", Vu_t_hvy * 1.0u"kip",
                                     bf_t_hvy, hf_t_hvy,
                                     NLPBeamOptions(; t_hvy_nlp_base..., snap=true))
t_hvy_nlp_raw  = size_rc_tbeam_nlp(Mu_t_hvy * 1.0u"kip*ft", Vu_t_hvy * 1.0u"kip",
                                     bf_t_hvy, hf_t_hvy,
                                     NLPBeamOptions(; t_hvy_nlp_base..., snap=false))

t_hvy_nlp_area     = t_hvy_nlp_snap.area_web
t_hvy_nlp_raw_area = t_hvy_nlp_raw.area_web

println("    Unsnapped : bw=$(round(t_hvy_nlp_raw.bw_final, digits=2))\", h=$(round(t_hvy_nlp_raw.h_final, digits=2))\"  →  Web A = $(round(t_hvy_nlp_raw_area, digits=1)) in²")
println("    Snapped   : bw=$(round(t_hvy_nlp_snap.bw_final, digits=1))\", h=$(round(t_hvy_nlp_snap.h_final, digits=1))\"  →  Web A = $(round(t_hvy_nlp_area, digits=1)) in²")
println("    ρ = $(round(t_hvy_nlp_snap.ρ_opt, digits=4)),  Status = $(t_hvy_nlp_snap.status)")

# ── 10.3  Comparison Summary ──
println("\n  10.3  Comparison Summary")

flex_t_hvy_mip   = rc_tbeam_flexure(t_hvy_sec, fc_psi, fy_psi)
shear_t_hvy_mip  = rc_tbeam_shear(t_hvy_sec, fc_psi)
flex_t_hvy_raw   = rc_tbeam_flexure(t_hvy_nlp_raw.section, fc_psi, fy_psi)
shear_t_hvy_raw  = rc_tbeam_shear(t_hvy_nlp_raw.section, fc_psi)
flex_t_hvy_snap  = rc_tbeam_flexure(t_hvy_nlp_snap.section, fc_psi, fy_psi)
shear_t_hvy_snap = rc_tbeam_shear(t_hvy_nlp_snap.section, fc_psi)

summary_head()
summary_row_s("Section", "—", string(t_hvy_sec.name),
              "bw=$(round(Int,t_hvy_nlp_raw.bw_final))×$(round(Int,t_hvy_nlp_raw.h_final))",
              "bw=$(round(Int,t_hvy_nlp_snap.bw_final))×$(round(Int,t_hvy_nlp_snap.h_final))")
summary_row("Web Area (in²)",    nothing, t_hvy_area, t_hvy_nlp_raw_area, t_hvy_nlp_area)
summary_row("φMn (kip·ft)",      Mu_t_hvy, flex_t_hvy_mip.φMn_kipft, flex_t_hvy_raw.φMn_kipft, flex_t_hvy_snap.φMn_kipft)
summary_row("φVn_max (kip)",     Vu_t_hvy, shear_t_hvy_mip.φVn_max_kip, shear_t_hvy_raw.φVn_max_kip, shear_t_hvy_snap.φVn_max_kip)
summary_row("Flexure util",      nothing, Mu_t_hvy/flex_t_hvy_mip.φMn_kipft, Mu_t_hvy/flex_t_hvy_raw.φMn_kipft, Mu_t_hvy/flex_t_hvy_snap.φMn_kipft; d=3)
summary_row("Shear util",        nothing, Vu_t_hvy/shear_t_hvy_mip.φVn_max_kip, Vu_t_hvy/shear_t_hvy_raw.φVn_max_kip, Vu_t_hvy/shear_t_hvy_snap.φVn_max_kip; d=3)
summary_row("εt",                nothing, flex_t_hvy_mip.εt, flex_t_hvy_raw.εt, flex_t_hvy_snap.εt; d=4)
summary_row_s("Stress block",    "—", string(flex_t_hvy_mip.case), string(flex_t_hvy_raw.case), string(flex_t_hvy_snap.case))

flex_ok_t_hvy  = Mu_t_hvy / flex_t_hvy_mip.φMn_kipft ≤ 1.0
shear_ok_t_hvy = Vu_t_hvy / shear_t_hvy_mip.φVn_max_kip ≤ 1.0

@testset "RC T-Beam — Heavy" begin
    @test flex_ok_t_hvy
    @test shear_ok_t_hvy
    @test t_hvy_area > t_mod_area
    @test t_hvy_nlp_area > 0
    @test t_hvy_nlp_area > t_mod_nlp_area
end
bm_step_status["RC T-Beam (hvy)"] = (flex_ok_t_hvy && shear_ok_t_hvy) ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  11. RC T-BEAM vs RECTANGULAR COMPARISON                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("11.0  RC T-Beam vs Rectangular Beam — Efficiency Comparison")
bm_note("Same Mu/Vu → T-beam ≤ rect. web; wider flange → more compression zone → smaller web.")

Mu_cmp_t = 250.0
Vu_cmp_t = 45.0

cmp_opts_nlp = NLPBeamOptions(
    min_width=10.0u"inch", max_width=24.0u"inch",
    min_depth=14.0u"inch", max_depth=36.0u"inch",
    grade=NWC_4000, rebar_grade=Rebar_60, verbose=false, snap=true,
)

# Rectangular beam NLP
rect_cmp = size_rc_beam_nlp(Mu_cmp_t * 1.0u"kip*ft", Vu_cmp_t * 1.0u"kip", cmp_opts_nlp)

# T-beam NLP — narrow flange
t_narrow = size_rc_tbeam_nlp(Mu_cmp_t * 1.0u"kip*ft", Vu_cmp_t * 1.0u"kip",
                              24.0u"inch", 4.0u"inch", cmp_opts_nlp)

# T-beam NLP — wide flange
t_wide = size_rc_tbeam_nlp(Mu_cmp_t * 1.0u"kip*ft", Vu_cmp_t * 1.0u"kip",
                            60.0u"inch", 6.0u"inch", cmp_opts_nlp)

@printf("    %-28s  %10s  %10s  %10s  %10s\n",
        "Configuration", "bw (in)", "h (in)", "Web A(in²)", "ρ")
@printf("    %-28s  %10s  %10s  %10s  %10s\n",
        "─"^28, "─"^10, "─"^10, "─"^10, "─"^10)
@printf("    %-28s  %10.1f  %10.1f  %10.1f  %10.4f\n",
        "Rectangular", rect_cmp.b_final, rect_cmp.h_final, rect_cmp.area, rect_cmp.ρ_opt)
@printf("    %-28s  %10.1f  %10.1f  %10.1f  %10.4f\n",
        "T-beam (bf=24\", hf=4\")", t_narrow.bw_final, t_narrow.h_final, t_narrow.area_web, t_narrow.ρ_opt)
@printf("    %-28s  %10.1f  %10.1f  %10.1f  %10.4f\n",
        "T-beam (bf=60\", hf=6\")", t_wide.bw_final, t_wide.h_final, t_wide.area_web, t_wide.ρ_opt)

# Efficiency: wide T-beam should be more efficient
savings_narrow = (1 - t_narrow.area_web / rect_cmp.area) * 100
savings_wide   = (1 - t_wide.area_web / rect_cmp.area) * 100
println()
@printf("    Web area savings:  bf=24\" → %+.1f%%,  bf=60\" → %+.1f%%\n", savings_narrow, savings_wide)

println()
bm_note("T-beam web ≤ rect. area (flange provides compression); wider flange → shallower web.")

t_vs_rect_ok = t_wide.area_web ≤ rect_cmp.area * 1.05

@testset "RC T-Beam vs Rectangular" begin
    @test t_wide.area_web ≤ rect_cmp.area * 1.05
    @test savings_wide ≥ -5.0  # Wide T-beam is at least as efficient
    @test t_narrow.area_web ≤ rect_cmp.area * 1.10  # Narrow flange: modest benefit
end
bm_step_status["T vs Rect"] = t_vs_rect_ok ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  12. TRIBUTARY FLANGE WIDTH — ADVERSARIAL CASES                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("12.0  Tributary Flange Width — Adversarial Geometry Cases")
bm_note("Moment-weighted bf from TributaryPolygon (s,d) profiles; w(s)=4s(1−s) parabolic default.")

println()
@printf("    %-30s  %10s  %10s  %10s  %s\n",
        "Profile Shape", "Uniform", "Parabolic", "Δ(%)", "Notes")
@printf("    %-30s  %10s  %10s  %10s  %s\n",
        "─"^30, "─"^10, "─"^10, "─"^10, "─"^20)

trib_results = []

# Case A: Constant (rectangular) — baseline
trib_const = _report_make_trib(s=[0.0,1.0,1.0,0.0], d=[0.0,0.0,3.0,3.0])
d_u_A = moment_weighted_avg_depth(trib_const; moment_shape=:uniform)
d_p_A = moment_weighted_avg_depth(trib_const; moment_shape=:parabolic)
δ_A = abs(d_u_A) > 1e-12 ? (d_p_A - d_u_A) / d_u_A * 100 : 0.0
@printf("    %-30s  %10.3f  %10.3f  %+9.1f%%  %s\n",
        "Constant (d=3m)", d_u_A, d_p_A, δ_A, "Parabolic = uniform ✓")
push!(trib_results, (:constant, d_u_A, d_p_A))

# Case B: Pinched middle (worst case for positive moment)
trib_pinch = _report_make_trib(
    s=[0.0,0.5,1.0,1.0,0.5,0.0], d=[0.0,0.0,0.0,4.0,1.0,4.0])
d_u_B = moment_weighted_avg_depth(trib_pinch; moment_shape=:uniform)
d_p_B = moment_weighted_avg_depth(trib_pinch; moment_shape=:parabolic)
δ_B = abs(d_u_B) > 1e-12 ? (d_p_B - d_u_B) / d_u_B * 100 : 0.0
@printf("    %-30s  %10.3f  %10.3f  %+9.1f%%  %s\n",
        "Pinched (d=4→1→4)", d_u_B, d_p_B, δ_B, "Conservative ↓")
push!(trib_results, (:pinched, d_u_B, d_p_B))

# Case C: Bulging middle (best case for positive moment)
trib_bulge = _report_make_trib(
    s=[0.0,0.5,1.0,1.0,0.5,0.0], d=[0.0,0.0,0.0,1.0,4.0,1.0])
d_u_C = moment_weighted_avg_depth(trib_bulge; moment_shape=:uniform)
d_p_C = moment_weighted_avg_depth(trib_bulge; moment_shape=:parabolic)
δ_C = abs(d_u_C) > 1e-12 ? (d_p_C - d_u_C) / d_u_C * 100 : 0.0
@printf("    %-30s  %10.3f  %10.3f  %+9.1f%%  %s\n",
        "Bulging (d=1→4→1)", d_u_C, d_p_C, δ_C, "Beneficial ↑")
push!(trib_results, (:bulging, d_u_C, d_p_C))

# Case D: Step function (narrow at start, wide rest)
ε = 1e-4
trib_step = _report_make_trib(
    s=[0.0,0.2,0.2+ε,1.0, 1.0,0.2+ε,0.2,0.0],
    d=[0.0,0.0,0.0,  0.0, 5.0,5.0,  1.0,1.0])
d_u_D = moment_weighted_avg_depth(trib_step; moment_shape=:uniform)
d_p_D = moment_weighted_avg_depth(trib_step; moment_shape=:parabolic)
δ_D = abs(d_u_D) > 1e-12 ? (d_p_D - d_u_D) / d_u_D * 100 : 0.0
@printf("    %-30s  %10.3f  %10.3f  %+9.1f%%  %s\n",
        "Step (d=1 20%, d=5 80%)", d_u_D, d_p_D, δ_D, "Narrow at low-M end")
push!(trib_results, (:step, d_u_D, d_p_D))

# Case E: Asymmetric trapezoidal
trib_asym = _report_make_trib(s=[0.0,1.0,1.0,0.0], d=[0.0,0.0,6.0,2.0])
d_u_E = moment_weighted_avg_depth(trib_asym; moment_shape=:uniform)
d_p_E = moment_weighted_avg_depth(trib_asym; moment_shape=:parabolic)
δ_E = abs(d_u_E) > 1e-12 ? (d_p_E - d_u_E) / d_u_E * 100 : 0.0
@printf("    %-30s  %10.3f  %10.3f  %+9.1f%%  %s\n",
        "Trapezoid (d=2→6)", d_u_E, d_p_E, δ_E, "Linear → same avg")
push!(trib_results, (:trapezoid, d_u_E, d_p_E))

# ── 12.1  Full bf recovery: rectangular grid vs ACI standard ──
println()
bm_sub_header("12.1  ACI Rectangular Grid Recovery")
bm_note("Verify effective_flange_width_from_tributary matches standard ACI result for uniform grid.")

bw_rec   = 12.0u"inch"
hf_rec   = 5.0u"inch"
ln_rec   = 240.0u"inch"
d_each_m = ustrip(u"m", 24.0u"inch")

trib_l = _report_make_trib(s=[0.0,1.0,1.0,0.0], d=[0.0,0.0,d_each_m,d_each_m])
trib_r = _report_make_trib(s=[0.0,1.0,1.0,0.0], d=[0.0,0.0,d_each_m,d_each_m])

bf_tributary = effective_flange_width_from_tributary(
    bw=bw_rec, hf=hf_rec, ln=ln_rec,
    trib_left=trib_l, trib_right=trib_r,
)
bf_standard = effective_flange_width(bw=bw_rec, hf=hf_rec, sw=48.0u"inch", ln=ln_rec)

bf_trib_in = round(ustrip(u"inch", bf_tributary), digits=1)
bf_std_in  = round(ustrip(u"inch", bf_standard), digits=1)

@printf("    %-30s  %10.1f in\n", "Tributary-based bf", bf_trib_in)
@printf("    %-30s  %10.1f in\n", "Standard ACI bf", bf_std_in)

bf_recovery_ok = abs(bf_trib_in - bf_std_in) < 1.0
@printf("    %-30s  %10s\n", "Match", bf_recovery_ok ? "✓ PASS" : "✗ FAIL")

# ── 12.2  ACI Cap check ──
println()
bm_sub_header("12.2  ACI Cap Applied to Oversized Tributary")
bm_note("Large tributary polygon (d=2m ≈ 79\") with hf=4\" → cap at 8hf = 32\".")

bw_cap = 12.0u"inch"
hf_cap = 4.0u"inch"
ln_cap = 360.0u"inch"

trib_big = _report_make_trib(s=[0.0,1.0,1.0,0.0], d=[0.0,0.0,2.0,2.0])

bf_capped = effective_flange_width_from_tributary(
    bw=bw_cap, hf=hf_cap, ln=ln_cap,
    trib_left=trib_big, trib_right=trib_big,
)

bf_capped_in  = round(ustrip(u"inch", bf_capped), digits=1)
bf_cap_expect = 12.0 + 2 * 32.0  # 8hf = 32" each side
cap_ok = abs(bf_capped_in - bf_cap_expect) < 1.0

@printf("    %-30s  %10.1f in\n", "bf (tributary, capped)", bf_capped_in)
@printf("    %-30s  %10.1f in\n", "bf (expected, 8hf cap)", bf_cap_expect)
@printf("    %-30s  %10s\n", "ACI cap applied", cap_ok ? "✓ PASS" : "✗ FAIL")

trib_all_ok = bf_recovery_ok && cap_ok

# Pinched must be more conservative than uniform
pinch_conservative = d_p_B < d_u_B
# Bulging must be less conservative than uniform
bulge_beneficial   = d_p_C > d_u_C

@testset "Tributary Flange Width — Adversarial" begin
    @test d_p_A ≈ d_u_A atol=0.05            # Constant: same under any weighting
    @test pinch_conservative                   # Pinched: parabolic < uniform
    @test bulge_beneficial                     # Bulging: parabolic > uniform
    @test d_p_E ≈ d_u_E atol=0.05            # Trapezoid (linear): same average
    @test bf_recovery_ok                       # Grid recovery
    @test cap_ok                               # ACI cap
end
bm_step_status["Trib Flange"] = trib_all_ok && pinch_conservative && bulge_beneficial ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  13. STEEL BEAM DEFLECTION (Ix_min NLP CONSTRAINT)                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("13.0  Steel Beam Deflection — Ix_min NLP Constraint")
bm_note("L/360 → required Ix_min; NLP finds lightest section meeting strength + stiffness.")

# ── 13.1  required_Ix_for_deflection ──
println("\n  13.1  required_Ix_for_deflection")

w_LL_defl = 0.8u"kip/ft"
L_defl    = 25.0u"ft"
E_steel   = 29000.0ksi

Ix_ss   = required_Ix_for_deflection(w_LL_defl, L_defl, E_steel; support=:simply_supported)
Ix_cant = required_Ix_for_deflection(w_LL_defl, L_defl, E_steel; support=:cantilever)
Ix_cont = required_Ix_for_deflection(w_LL_defl, L_defl, E_steel; support=:both_ends_continuous)

Ix_ss_val   = round(ustrip(u"inch^4", Ix_ss), digits=1)
Ix_cant_val = round(ustrip(u"inch^4", Ix_cant), digits=1)
Ix_cont_val = round(ustrip(u"inch^4", Ix_cont), digits=1)

@printf("    %-35s  %10s  %s\n", "Support Condition", "Ix_min(in⁴)", "Notes")
@printf("    %-35s  %10s  %s\n", "─"^35, "─"^10, "─"^20)
@printf("    %-35s  %10.1f  %s\n", "Simply supported (5wL⁴/384EI)", Ix_ss_val, "L/360 default")
@printf("    %-35s  %10.1f  %s\n", "Cantilever (wL⁴/8EI)", Ix_cant_val, "Much stiffer req'd")
@printf("    %-35s  %10.1f  %s\n", "Both ends continuous (wL⁴/384EI)", Ix_cont_val, "Continuous frame")

println()
bm_note("Cantilever = $(round(Ix_cant_val / Ix_ss_val, digits=1))× SS; continuous = $(round(100*Ix_cont_val / Ix_ss_val, digits=0))% of SS.")

# ── 13.2  Steel W-beam NLP: strength-only vs strength+deflection ──
println("\n  13.2  W-beam NLP: Strength-Only vs Strength + Deflection")

Mu_defl = 200.0u"kip*ft"
Vu_defl = 40.0kip
geom_defl = SteelMemberGeometry(25.0u"ft"; Lb=25.0u"ft", Cb=1.0)
opts_defl = NLPWOptions(min_depth=12.0u"inch", max_depth=30.0u"inch", verbose=false)

r_strength = size_steel_w_beam_nlp(Mu_defl, Vu_defl, geom_defl, opts_defl)
r_defl_w   = size_steel_w_beam_nlp(Mu_defl, Vu_defl, geom_defl, opts_defl;
                                    Ix_min=1200.0u"inch^4")

@printf("    %-28s  %10s  %10s  %10s  %10s\n",
        "Configuration", "d (in)", "A (in²)", "Ix (in⁴)", "Status")
@printf("    %-28s  %10s  %10s  %10s  %10s\n",
        "─"^28, "─"^10, "─"^10, "─"^10, "─"^10)
@printf("    %-28s  %10.1f  %10.2f  %10.1f  %10s\n",
        "Strength only", r_strength.d_final, r_strength.area, r_strength.Ix, string(r_strength.status))
@printf("    %-28s  %10.1f  %10.2f  %10.1f  %10s\n",
        "Strength + Ix≥1200 in⁴", r_defl_w.d_final, r_defl_w.area, r_defl_w.Ix, string(r_defl_w.status))

defl_area_increase = (r_defl_w.area / r_strength.area - 1) * 100
println()
@printf("    Deflection constraint adds %+.1f%% steel area (deeper section for stiffness).\n", defl_area_increase)

defl_w_ok = r_strength.status in (:converged, :optimal) &&
            r_defl_w.status in (:converged, :optimal) &&
            r_defl_w.Ix >= 1200.0 * 0.95

@testset "Steel W Beam Deflection" begin
    @test r_strength.status in (:converged, :optimal)
    @test r_defl_w.status in (:converged, :optimal)
    @test r_defl_w.Ix >= 1200.0 * 0.95  # within 5% tolerance
    @test r_defl_w.area ≥ r_strength.area * 0.99  # deflection → more material
    @test Ix_cant_val > Ix_ss_val  # cantilever > simply supported
    @test Ix_cont_val < Ix_ss_val  # continuous < simply supported
end
bm_step_status["Steel Defl."] = defl_w_ok ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  14. RC T-BEAM DEFLECTION CHECK (ACI §24.2)                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("14.0  RC T-Beam Deflection Check (ACI §24.2)")
bm_note("ACI §24.2: Ig(T), Icr(T), Ie (Branson), Δ_LL, Δ_total. T-beam Ig > rect → less deflection.")

# ── 14.1  T-beam deflection — typical case ──
println("\n  14.1  T-Beam Deflection — Typical Case")

bw_d = 14.0u"inch"; bf_d = 48.0u"inch"; hf_d = 6.0u"inch"
h_d  = 24.0u"inch"; d_d  = 21.5u"inch"
As_d = 4.0u"inch^2"
fc_d = 4.0ksi; fy_d = 60.0ksi; Es_d = 29000.0ksi
L_d  = 25.0u"ft"
w_dead_d = 1.2u"kip/ft"; w_live_d = 0.8u"kip/ft"

t_defl = design_tbeam_deflection(
    bw_d, bf_d, hf_d, h_d, d_d, As_d,
    fc_d, fy_d, Es_d, L_d, w_dead_d, w_live_d;
    support=:simply_supported,
)

@printf("    %-30s  %12s  %s\n", "Property", "Value", "Unit")
@printf("    %-30s  %12s  %s\n", "─"^30, "─"^12, "─"^8)
@printf("    %-30s  %12.1f  %s\n", "Ig (T-shape)", ustrip(u"inch^4", t_defl.Ig), "in⁴")
@printf("    %-30s  %12.1f  %s\n", "Icr (T-shape)", ustrip(u"inch^4", t_defl.Icr), "in⁴")
@printf("    %-30s  %12.1f  %s\n", "Mcr", ustrip(u"kip*ft", t_defl.Mcr), "kip·ft")
@printf("    %-30s  %12.2f  %s\n", "ȳ (centroid from top)", ustrip(u"inch", t_defl.ȳ), "in")
@printf("    %-30s  %12.1f  %s\n", "Ie_D (dead only)", ustrip(u"inch^4", t_defl.Ie_D), "in⁴")
@printf("    %-30s  %12.1f  %s\n", "Ie_DL (dead+live)", ustrip(u"inch^4", t_defl.Ie_DL), "in⁴")
@printf("    %-30s  %12.4f  %s\n", "Δ_LL (live load)", ustrip(u"inch", t_defl.Δ_LL), "in")
@printf("    %-30s  %12.4f  %s\n", "Δ_total (long-term)", ustrip(u"inch", t_defl.Δ_total), "in")
@printf("    %-30s  %12.2f  %s\n", "λΔ (long-term factor)", t_defl.λΔ, "—")
@printf("    %-30s  %12s  %s\n", "L/360 limit", string(round(ustrip(u"inch", L_d / 360), digits=3)), "in")
@printf("    %-30s  %12s  %s\n", "Overall", t_defl.ok ? "✓ PASS" : "✗ FAIL", "")

# ── 14.2  T-beam vs rectangular deflection comparison ──
println("\n  14.2  T-Beam vs Rectangular Deflection Comparison")
bm_note("Same overall dimensions (bw, h, d, As), same loads. T-beam has flange.")

r_defl_rect = design_beam_deflection(
    bw_d, h_d, d_d, As_d,
    fc_d, fy_d, Es_d, L_d, w_dead_d, w_live_d,
)

@printf("    %-28s  %12s  %12s  %8s\n", "Property", "T-Beam", "Rectangular", "Δ%")
@printf("    %-28s  %12s  %12s  %8s\n", "─"^28, "─"^12, "─"^12, "─"^8)

Ig_t = ustrip(u"inch^4", t_defl.Ig)
Ig_r = ustrip(u"inch^4", r_defl_rect.Ig)
@printf("    %-28s  %12.1f  %12.1f  %+7.1f%%\n", "Ig (in⁴)", Ig_t, Ig_r, (Ig_t/Ig_r - 1)*100)

Icr_t = ustrip(u"inch^4", t_defl.Icr)
Icr_r = ustrip(u"inch^4", r_defl_rect.Icr)
@printf("    %-28s  %12.1f  %12.1f  %+7.1f%%\n", "Icr (in⁴)", Icr_t, Icr_r, (Icr_t/Icr_r - 1)*100)

Δ_LL_t = ustrip(u"inch", t_defl.Δ_LL)
Δ_LL_r = ustrip(u"inch", r_defl_rect.Δ_LL)
@printf("    %-28s  %12.4f  %12.4f  %+7.1f%%\n", "Δ_LL (in)", Δ_LL_t, Δ_LL_r, (Δ_LL_t/Δ_LL_r - 1)*100)

Δ_tot_t = ustrip(u"inch", t_defl.Δ_total)
Δ_tot_r = ustrip(u"inch", r_defl_rect.Δ_total)
@printf("    %-28s  %12.4f  %12.4f  %+7.1f%%\n", "Δ_total (in)", Δ_tot_t, Δ_tot_r, (Δ_tot_t/Δ_tot_r - 1)*100)

defl_reduction = (1 - Δ_LL_t / Δ_LL_r) * 100
println()
@printf("    T-beam flange reduces live-load deflection by %.0f%%.\n", defl_reduction)

# ── 14.3  Degenerate case: bf==bw matches rectangular ──
println("\n  14.3  Degenerate: bf == bw → Matches Rectangular")

b_deg = 14.0u"inch"; hf_deg = 24.0u"inch"
h_deg = 24.0u"inch"; d_deg = 21.5u"inch"; As_deg = 4.0u"inch^2"

t_deg = design_tbeam_deflection(b_deg, b_deg, hf_deg, h_deg, d_deg, As_deg,
    fc_d, fy_d, Es_d, L_d, w_dead_d, w_live_d)
r_deg = design_beam_deflection(b_deg, h_deg, d_deg, As_deg,
    fc_d, fy_d, Es_d, L_d, w_dead_d, w_live_d)

Ig_match    = isapprox(ustrip(u"inch^4", t_deg.Ig), ustrip(u"inch^4", r_deg.Ig); rtol=0.01)
Icr_match   = isapprox(ustrip(u"inch^4", t_deg.Icr), ustrip(u"inch^4", r_deg.Icr); rtol=0.01)
Δ_LL_match  = isapprox(ustrip(u"inch", t_deg.Δ_LL), ustrip(u"inch", r_deg.Δ_LL); rtol=0.02)

@printf("    %-28s  %12s\n", "Ig match", Ig_match ? "✓" : "✗")
@printf("    %-28s  %12s\n", "Icr match", Icr_match ? "✓" : "✗")
@printf("    %-28s  %12s\n", "Δ_LL match", Δ_LL_match ? "✓" : "✗")

defl_tbeam_ok = t_defl.ok && Ig_t > Ig_r && Δ_LL_t < Δ_LL_r && Ig_match && Icr_match

@testset "RC T-Beam Deflection" begin
    @test t_defl.ok
    @test Ig_t > Ig_r   # T-beam Ig > rectangular
    @test Icr_t > Icr_r # T-beam Icr > rectangular
    @test Δ_LL_t < Δ_LL_r  # T-beam deflects less
    @test defl_reduction > 0  # Positive benefit
    @test Ig_match
    @test Icr_match
    @test Δ_LL_match
end
bm_step_status["T-Beam Defl."] = defl_tbeam_ok ? "✓" : "✗"

# ── 14.1  Auto-Integrated Deflection in NLP / MIP ──────────────────────────
bm_sub_header("14.1  Auto-Integrated T-Beam Deflection — NLP & MIP")
bm_note("NLP: Δ_LL/L ≤ 1/360 + Δ_total/L ≤ 1/240 constraints. MIP: deflection in is_feasible filter.")

# -- NLP with and without deflection --
begin
    defl_Mu = 250.0kip * u"ft"
    defl_Vu = 50.0kip
    defl_bf = 48.0u"inch"; defl_hf = 6.0u"inch"
    defl_L  = 25.0u"ft"
    defl_wd = 1.2u"kip/ft"; defl_wl = 0.8u"kip/ft"
    defl_opts = NLPBeamOptions(min_depth=16.0u"inch", max_depth=30.0u"inch")

    r_str_only = size_rc_tbeam_nlp(defl_Mu, defl_Vu, defl_bf, defl_hf, defl_opts)
    r_with_defl = size_rc_tbeam_nlp(defl_Mu, defl_Vu, defl_bf, defl_hf, defl_opts;
        w_dead=defl_wd, w_live=defl_wl, L_span=defl_L)

    println("    NLP T-beam sizing: Mu=250 kip·ft, Vu=50 kip, bf=48\", hf=6\", L=25'")
    println("    Service: w_dead=1.2 kip/ft, w_live=0.8 kip/ft")
    println()
    println("    Case                bw (in)  h (in)  ρ       Web area (in²)  Status")
    println("    ─────────────────── ──────── ─────── ─────── ─────────────── ──────")
    @printf("    Strength-only       %6.1f   %6.1f   %.4f  %8.1f        %s\n",
        r_str_only.bw_final, r_str_only.h_final, r_str_only.ρ_opt, r_str_only.area_web, r_str_only.status)
    @printf("    + Deflection        %6.1f   %6.1f   %.4f  %8.1f        %s\n",
        r_with_defl.bw_final, r_with_defl.h_final, r_with_defl.ρ_opt, r_with_defl.area_web, r_with_defl.status)

    area_increase_nlp = (r_with_defl.area_web / r_str_only.area_web - 1) * 100
    @printf("    Area increase for stiffness: %+.1f%%\n", area_increase_nlp)
    println()

    # Verify the deflection-constrained section passes
    sec_d = r_with_defl.section
    defl_verify = design_tbeam_deflection(
        sec_d.bw, sec_d.bf, sec_d.hf, sec_d.h, sec_d.d, sec_d.As,
        4.0ksi, 60.0ksi, 29000.0ksi, defl_L, defl_wd, defl_wl)
    println("    Deflection verification of NLP result:")
    @printf("      Δ_LL   = %.4f in   (limit = L/360 = %.4f in)   %s\n",
        ustrip(u"inch", defl_verify.Δ_LL),
        ustrip(u"inch", defl_L) / 360,
        defl_verify.checks[:immediate_ll].ok ? "OK" : "FAIL")
    @printf("      Δ_total= %.4f in   (limit = L/240 = %.4f in)   %s\n",
        ustrip(u"inch", defl_verify.Δ_total),
        ustrip(u"inch", defl_L) / 240,
        defl_verify.checks[:total].ok ? "OK" : "FAIL")
    println()
end

# -- MIP with and without deflection --
begin
    mip_n = 2
    mip_Mu = [200.0, 300.0] .* u"kip*ft"
    mip_Vu = [40.0, 60.0] .* kip
    mip_geoms = [ConcreteMemberGeometry(25.0u"ft") for _ in 1:mip_n]
    mip_opts = ConcreteBeamOptions()
    mip_bf = 48.0u"inch"; mip_hf = 6.0u"inch"

    r_mip_str = size_tbeams(mip_Mu, mip_Vu, mip_geoms, mip_opts;
        flange_width=mip_bf, flange_thickness=mip_hf)
    r_mip_def = size_tbeams(mip_Mu, mip_Vu, mip_geoms, mip_opts;
        flange_width=mip_bf, flange_thickness=mip_hf,
        w_dead=1.0u"kip/ft", w_live=0.8u"kip/ft")

    println("    MIP T-beam sizing (2 beams): bf=48\", hf=6\", L=25'")
    println("    Service: w_dead=1.0 kip/ft, w_live=0.8 kip/ft")
    println()
    println("    Beam  Case             Section         bw×h (in²)")
    println("    ───── ──────────────── ─────────────── ──────────")
    for i in 1:mip_n
        s1 = r_mip_str.sections[i]
        s2 = r_mip_def.sections[i]
        a1 = ustrip(u"inch^2", s1.bw * s1.h)
        a2 = ustrip(u"inch^2", s2.bw * s2.h)
        @printf("    %d     Strength-only    %-15s  %6.0f\n", i, s1.name, a1)
        @printf("    %d     + Deflection     %-15s  %6.0f\n", i, s2.name, a2)
    end
    println()
end

# -- Test assertions for the auto-integrated deflection --
defl_auto_ok = true
@testset "Auto-integrated deflection — NLP" begin
    @test r_str_only.status in (:converged, :optimal)
    @test r_with_defl.status in (:converged, :optimal)
    @test r_with_defl.area_web >= r_str_only.area_web * 0.95
    @test defl_verify.ok == true
end
@testset "Auto-integrated deflection — MIP" begin
    @test r_mip_str.status == JuMP.MOI.OPTIMAL
    @test r_mip_def.status == JuMP.MOI.OPTIMAL
    for i in 1:mip_n
        sec = r_mip_def.sections[i]
        chk = design_tbeam_deflection(
            sec.bw, sec.bf, sec.hf, sec.h, sec.d, sec.As,
            4.0ksi, 60.0ksi, 29000.0ksi, 25.0u"ft", 1.0u"kip/ft", 0.8u"kip/ft")
        @test chk.ok == true
    end
end
bm_step_status["Defl. Auto NLP"] = r_with_defl.status in (:converged, :optimal) && defl_verify.ok ? "✓" : "✗"
bm_step_status["Defl. Auto MIP"] = r_mip_def.status == JuMP.MOI.OPTIMAL ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  15. RC BEAM TORSION DESIGN (ACI 318-19 §22.7)                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("15.0  RC Beam Torsion Design (ACI 318-19 §22.7)")
bm_note("Torsion: section props, Tth/Tcr, adequacy, At/s & Al reinf. Compat caps Tu at φ·Tcr; equil uses full Tu.")

# ── 15.0.1  Rectangular beam — moderate torsion (compatibility) ──
begin
    tor_bw = 14.0u"inch"; tor_h = 22.0u"inch"; tor_d = 19.5u"inch"
    tor_fc = 4.0ksi; tor_fy = 60.0ksi; tor_fyt = 60.0ksi
    tor_Tu = 120.0u"kip*inch"; tor_Vu = 40.0kip

    tor_compat = design_beam_torsion(
        tor_Tu, tor_Vu, tor_bw, tor_h, tor_d, tor_fc, tor_fy, tor_fyt;
        torsion_mode=:compatibility,
    )

    tor_equil = design_beam_torsion(
        tor_Tu, tor_Vu, tor_bw, tor_h, tor_d, tor_fc, tor_fy, tor_fyt;
        torsion_mode=:equilibrium,
    )

    println("  15.0.1  Rectangular Beam Torsion — Moderate Demand")
    println("    bw = 14\", h = 22\", d = 19.5\", f'c = 4000 psi, fy = fyt = 60 ksi")
    println("    Tu = 120 kip·in, Vu = 40 kip")
    println()

    @printf("    %-30s  %12s  %12s\n", "Property", "Compat.", "Equilib.")
    @printf("    %-30s  %12s  %12s\n", "─"^30, "─"^12, "─"^12)
    @printf("    %-30s  %12.1f  %12.1f\n", "Tth (kip·in)", tor_compat.Tth_kipin, tor_equil.Tth_kipin)
    @printf("    %-30s  %12.1f  %12.1f\n", "Tcr (kip·in)", tor_compat.Tcr_kipin, tor_equil.Tcr_kipin)
    @printf("    %-30s  %12.1f  %12.1f\n", "Tu_design (kip·in)", tor_compat.Tu_design_kipin, tor_equil.Tu_design_kipin)
    @printf("    %-30s  %12s  %12s\n", "Torsion required?", string(tor_compat.torsion_required), string(tor_equil.torsion_required))
    @printf("    %-30s  %12s  %12s\n", "Section adequate?", string(tor_compat.section_adequate), string(tor_equil.section_adequate))
    @printf("    %-30s  %12.3f  %12.3f\n", "Adequacy ratio", tor_compat.adequacy_ratio, tor_equil.adequacy_ratio)
    @printf("    %-30s  %12.4f  %12.4f\n", "At/s required (in²/in)", tor_compat.At_s_required, tor_equil.At_s_required)
    @printf("    %-30s  %12.4f  %12.4f\n", "At/s minimum (in²/in)", tor_compat.At_s_min, tor_equil.At_s_min)
    @printf("    %-30s  %12.3f  %12.3f\n", "Al required (in²)", tor_compat.Al_required, tor_equil.Al_required)
    @printf("    %-30s  %12.3f  %12.3f\n", "Al minimum (in²)", tor_compat.Al_min, tor_equil.Al_min)
    @printf("    %-30s  %12.2f  %12.2f\n", "s_max (in)", tor_compat.s_max_torsion, tor_equil.s_max_torsion)
    @printf("    %-30s  %12s  %12s\n", "Was capped?", string(tor_compat.was_capped), string(tor_equil.was_capped))
    println()
bm_note("Compat caps Tu at φ·Tcr (less reinf.); equilibrium designs for full Tu (conservative).")
end

# ── 15.0.2  T-beam torsion ──
begin
    ttor_bw = 12.0u"inch"; ttor_h = 24.0u"inch"; ttor_d = 21.5u"inch"
    ttor_bf = 48.0u"inch"; ttor_hf = 5.0u"inch"
    ttor_Tu = 150.0u"kip*inch"; ttor_Vu = 50.0kip

    ttor_result = design_beam_torsion(
        ttor_Tu, ttor_Vu, ttor_bw, ttor_h, ttor_d, tor_fc, tor_fy, tor_fyt;
        bf=ttor_bf, hf=ttor_hf,
        torsion_mode=:compatibility,
    )

    println("\n  15.0.2  T-Beam Torsion — Compatibility Mode")
    println("    bw = 12\", h = 24\", d = 21.5\", bf = 48\", hf = 5\"")
    println("    Tu = 150 kip·in, Vu = 50 kip")
    println()

    @printf("    %-30s  %12s\n", "Property", "Value")
    @printf("    %-30s  %12s\n", "─"^30, "─"^12)
    @printf("    %-30s  %12.1f\n", "Acp (in²)", ttor_result.Acp)
    @printf("    %-30s  %12.1f\n", "pcp (in)", ttor_result.pcp)
    @printf("    %-30s  %12.1f\n", "Tth (kip·in)", ttor_result.Tth_kipin)
    @printf("    %-30s  %12.1f\n", "Tcr (kip·in)", ttor_result.Tcr_kipin)
    @printf("    %-30s  %12.1f\n", "Tu_design (kip·in)", ttor_result.Tu_design_kipin)
    @printf("    %-30s  %12s\n", "Section adequate?", string(ttor_result.section_adequate))
    @printf("    %-30s  %12.3f\n", "Adequacy ratio", ttor_result.adequacy_ratio)
    @printf("    %-30s  %12.4f\n", "At/s required (in²/in)", ttor_result.At_s_required)
    @printf("    %-30s  %12.3f\n", "Al required (in²)", ttor_result.Al_required)
    println()
bm_note("T-beam Acp includes flange overhang (§22.7.4.1a); Aoh/ph from web rectangle only.")
end

# ── 15.0.3  Below threshold — torsion can be neglected ──
begin
    small_Tu = 10.0u"kip*inch"
    tor_below = design_beam_torsion(
        small_Tu, tor_Vu, tor_bw, tor_h, tor_d, tor_fc, tor_fy, tor_fyt;
        torsion_mode=:compatibility,
    )

    println("\n  15.0.3  Below Threshold — Torsion Neglected")
    @printf("    Tu = 10 kip·in,  Tth = %.1f kip·in → %s\n",
            tor_below.Tth_kipin,
            tor_below.torsion_required ? "REQUIRED" : "NEGLECTED (below threshold)")
end

tor_rc_ok = tor_compat.section_adequate && tor_equil.section_adequate &&
            ttor_result.section_adequate && !tor_below.torsion_required

@testset "RC Beam Torsion" begin
    @test tor_compat.section_adequate
    @test tor_equil.section_adequate
    @test tor_compat.torsion_required
    @test ttor_result.section_adequate
    @test !tor_below.torsion_required
    @test tor_compat.adequacy_ratio ≤ 1.0
    @test tor_equil.adequacy_ratio ≤ 1.0
    @test ttor_result.adequacy_ratio ≤ 1.0
    # Compatibility mode: At/s ≤ equilibrium At/s (capped Tu ≤ full Tu)
    @test tor_compat.At_s_required ≤ tor_equil.At_s_required + 1e-6
end
bm_step_status["RC Torsion"] = tor_rc_ok ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  15.1  STEEL W-SHAPE TORSION (AISC DESIGN GUIDE 9)                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("15.1  Steel W-Shape Torsion (AISC Design Guide 9)")
bm_note("W torsion: St. Venant + warping stresses; checks normal/shear yielding + interaction (DG9 §4.7.1).")

begin
    wtor_sec = W("W10X49")
    wtor_mat = A992_Steel
    wtor_Tu = 90.0u"kip*inch"
    wtor_Vu = 7.5kip
    wtor_Mu = 56.25u"kip*ft"  # 15 kip × 15 ft / 4
    wtor_L  = 15.0u"ft"

    wtor = design_w_torsion(wtor_sec, wtor_mat, wtor_Tu, wtor_Vu, wtor_Mu, wtor_L;
                            load_type=:concentrated_midspan)

    println("  15.1.1  DG9 Example 5.1 — W10×49, Concentrated Midspan Torque")
    println("    Section: W10×49,  L = 15 ft,  Fy = 50 ksi")
    println("    Tu = 90 kip·in,  Vu = 7.5 kip,  Mu = 56.25 kip·ft (= 675 kip·in)")
    println()

    @printf("    %-35s  %10s  %10s\n", "Property", "Midspan", "Support")
    @printf("    %-35s  %10s  %10s\n", "─"^35, "─"^10, "─"^10)
    @printf("    %-35s  %10.2f  %10.2f\n", "σ_w — warping normal (ksi)", wtor.σ_w_midspan_ksi, wtor.σ_w_support_ksi)
    @printf("    %-35s  %10.2f  %10.2f\n", "τ_t — pure torsional shear (ksi)", wtor.τ_t_midspan_ksi, wtor.τ_t_support_ksi)
    @printf("    %-35s  %10.2f  %10.2f\n", "τ_ws — warping shear (ksi)", wtor.τ_ws_midspan_ksi, wtor.τ_ws_support_ksi)
    @printf("    %-35s  %10s  %10.2f\n", "τ_b — flexural shear (ksi)", "—", wtor.τ_b_support_ksi)
    @printf("    %-35s  %10.2f  %10.2f\n", "f_un — combined normal (ksi)", wtor.f_un_midspan_ksi, wtor.f_un_support_ksi)
    @printf("    %-35s  %10.2f  %10.2f\n", "f_uv — combined shear (ksi)", wtor.f_uv_midspan_ksi, wtor.f_uv_support_ksi)
    println()
    @printf("    %-35s  %10.4f\n", "θ_max (rad)", wtor.θ_max_rad)
    @printf("    %-35s  %10.2f\n", "a — torsional parameter (in)", wtor.a_in)
    println()

    @printf("    %-35s  %10s  %10s\n", "Check", "Midspan", "Support")
    @printf("    %-35s  %10s  %10s\n", "─"^35, "─"^10, "─"^10)
    @printf("    %-35s  %10s  %10s\n", "Normal yielding (f_un ≤ φFy)",
            wtor.check_midspan.normal_ok ? "✓ PASS" : "✗ FAIL",
            wtor.check_support.normal_ok ? "✓ PASS" : "✗ FAIL")
    @printf("    %-35s  %10s  %10s\n", "Shear yielding (f_uv ≤ φ·0.6Fy)",
            wtor.check_midspan.shear_ok ? "✓ PASS" : "✗ FAIL",
            wtor.check_support.shear_ok ? "✓ PASS" : "✗ FAIL")
    @printf("    %-35s  %10.3f  %10.3f\n", "Interaction ratio",
            wtor.check_midspan.interaction_ratio, wtor.check_support.interaction_ratio)
    @printf("    %-35s  %10s  %10s\n", "Interaction check (≤ 1.0)",
            wtor.check_midspan.interaction_ok ? "✓ PASS" : "✗ FAIL",
            wtor.check_support.interaction_ok ? "✓ PASS" : "✗ FAIL")
    println()
    @printf("    %-35s  %10s\n", "Overall", wtor.ok ? "✓ PASS" : "✗ FAIL")
end

# ── 15.1.2  Heavier torsion on a lighter section ──
begin
    wtor2_sec = W("W12X26")
    wtor2_Tu = 60.0u"kip*inch"
    wtor2_Vu = 20.0kip
    wtor2_Mu = 80.0u"kip*ft"
    wtor2_L  = 20.0u"ft"

    wtor2 = design_w_torsion(wtor2_sec, wtor_mat, wtor2_Tu, wtor2_Vu, wtor2_Mu, wtor2_L;
                              load_type=:concentrated_midspan)

    println("\n  15.1.2  W12×26 — Higher Demand/Capacity Ratio")
    println("    Tu = 60 kip·in, Vu = 20 kip, Mu = 80 kip·ft, L = 20 ft")
    @printf("    Interaction midspan: %.3f,  support: %.3f  →  %s\n",
            wtor2.check_midspan.interaction_ratio,
            wtor2.check_support.interaction_ratio,
            wtor2.ok ? "✓ PASS" : "✗ FAIL")
end

tor_steel_ok = wtor.ok
@testset "Steel W-Shape Torsion" begin
    @test wtor.ok
    @test wtor.check_midspan.normal_ok
    @test wtor.check_midspan.shear_ok
    @test wtor.check_midspan.interaction_ok
    @test wtor.check_support.normal_ok
    @test wtor.check_support.shear_ok
    @test wtor.check_support.interaction_ok
    @test wtor.θ_max_rad > 0
    @test wtor.σ_b_ksi ≈ 12.36  atol=0.5  # 675 / 54.6
end
bm_step_status["Steel Torsion"] = tor_steel_ok ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  15.2  RC BEAM TORSION — MIP CHECKER INTEGRATION                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("15.2  RC Beam Torsion — MIP Checker Integration")
bm_note("is_feasible rejects sections failing torsion adequacy (§22.7.7.1) when Tu > Tth.")

begin
    # Size a beam with moderate torsion — should select a section that passes adequacy
    mip_tor_Mu = 150.0   # kip·ft
    mip_tor_Vu = 35.0    # kip
    mip_tor_Tu = 80.0    # kip·in

    mip_tor_result = size_beams(
        [mip_tor_Mu], [mip_tor_Vu],
        [ConcreteMemberGeometry(7.0)],
        ConcreteBeamOptions(grade=NWC_4000, rebar_grade=Rebar_60);
        Tu=[mip_tor_Tu],
    )
    mip_tor_sec = mip_tor_result.sections[1]
    mip_tor_area = ustrip(u"inch^2", section_area(mip_tor_sec))

    # Verify adequacy of the selected section
    d_stir = ustrip(u"inch", rebar(mip_tor_sec.stirrup_size).diameter)
    c_ctr = 1.5 + d_stir / 2
    mip_tor_props = torsion_section_properties(mip_tor_sec.b, mip_tor_sec.h, c_ctr * u"inch")
    mip_tor_Tth = threshold_torsion(mip_tor_props.Acp, mip_tor_props.pcp, 4000.0)
    mip_tor_adequate = torsion_section_adequate(
        mip_tor_Vu, mip_tor_Tu,
        ustrip(u"inch", mip_tor_sec.b), ustrip(u"inch", mip_tor_sec.d),
        mip_tor_props.Aoh, mip_tor_props.ph, 4000.0)
    mip_tor_ratio = torsion_adequacy_ratio(
        mip_tor_Vu, mip_tor_Tu,
        ustrip(u"inch", mip_tor_sec.b), ustrip(u"inch", mip_tor_sec.d),
        mip_tor_props.Aoh, mip_tor_props.ph, 4000.0)

    # Compare: same demand without torsion
    mip_notor_result = size_beams(
        [mip_tor_Mu], [mip_tor_Vu],
        [ConcreteMemberGeometry(7.0)],
        ConcreteBeamOptions(grade=NWC_4000, rebar_grade=Rebar_60),
    )
    mip_notor_sec = mip_notor_result.sections[1]
    mip_notor_area = ustrip(u"inch^2", section_area(mip_notor_sec))

    println("    Demand: Mu = 150 kip·ft, Vu = 35 kip, Tu = 80 kip·in")
    println()
    @printf("    %-28s  %12s  %12s\n", "Property", "With Tu", "Without Tu")
    @printf("    %-28s  %12s  %12s\n", "─"^28, "─"^12, "─"^12)
    @printf("    %-28s  %12s  %12s\n", "Section", string(mip_tor_sec.name), string(mip_notor_sec.name))
    @printf("    %-28s  %12.1f  %12.1f\n", "Area (in²)", mip_tor_area, mip_notor_area)
    @printf("    %-28s  %12s  %12s\n", "Torsion adequate?",
            mip_tor_adequate ? "✓" : "✗", "n/a")
    @printf("    %-28s  %12.3f  %12s\n", "Torsion adequacy ratio", mip_tor_ratio, "n/a")
    println()
    bm_note("Torsion demand may force selection of a larger section to satisfy §22.7.7.1.")
end

mip_tor_ok = mip_tor_adequate && mip_tor_area > 0 && mip_notor_area > 0

@testset "RC Torsion — MIP Checker" begin
    @test mip_tor_adequate
    @test mip_tor_ratio ≤ 1.0
    @test mip_tor_area > 0
    @test mip_notor_area > 0
    @test mip_tor_area ≥ mip_notor_area  # torsion may need larger section
end
bm_step_status["RC Tor. MIP"] = mip_tor_ok ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  15.3  TORSION NLP INTEGRATION                                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("15.3  Torsion NLP Integration — All Beam Types")
bm_note("Torsion NLP: RC=§22.7.7.1 interaction, W=DG9 §4.7.1, HSS=H3-6 closed. Added when Tu > 0.")

# ── 15.3.1  RC Beam NLP with torsion ──
begin
    nlp_tor_Mu = 150.0kip * u"ft"
    nlp_tor_Vu = 35.0kip
    nlp_tor_Tu = 80.0  # kip·in (raw)
    nlp_tor_opts = NLPBeamOptions(
        min_depth=14.0u"inch", max_depth=30.0u"inch",
        min_width=10.0u"inch", max_width=24.0u"inch",
    )

    nlp_tor_result = size_rc_beam_nlp(nlp_tor_Mu, nlp_tor_Vu, nlp_tor_opts; Tu=nlp_tor_Tu)
    nlp_notor_result = size_rc_beam_nlp(nlp_tor_Mu, nlp_tor_Vu, nlp_tor_opts)

    println("  15.3.1  RC Beam NLP — Strength + Torsion")
    println("    Demand: Mu = 150 kip·ft, Vu = 35 kip, Tu = 80 kip·in")
    println()
    @printf("    %-28s  %12s  %12s\n", "Property", "With Tu", "Without Tu")
    @printf("    %-28s  %12s  %12s\n", "─"^28, "─"^12, "─"^12)
    @printf("    %-28s  %12.1f  %12.1f\n", "b (in)", nlp_tor_result.b_final, nlp_notor_result.b_final)
    @printf("    %-28s  %12.1f  %12.1f\n", "h (in)", nlp_tor_result.h_final, nlp_notor_result.h_final)
    @printf("    %-28s  %12.1f  %12.1f\n", "Area (in²)", nlp_tor_result.area, nlp_notor_result.area)
    @printf("    %-28s  %12s  %12s\n", "Status", string(nlp_tor_result.status), string(nlp_notor_result.status))
    println()
    bm_note("Torsion demand may increase optimal section dimensions.")
end

# ── 15.3.2  Steel W Beam NLP with torsion ──
begin
    w_nlp_tor_Mu = 56.25u"kip*ft"
    w_nlp_tor_Vu = 7.5kip
    w_nlp_tor_Tu = 90.0  # kip·in (raw)
    w_nlp_tor_L  = 15.0u"ft"
    w_nlp_tor_geom = SteelMemberGeometry(15.0u"ft"; Lb=15.0u"ft", Cb=1.0)
    w_nlp_tor_opts = NLPWOptions(material=A992_Steel)

    w_nlp_tor = size_steel_w_beam_nlp(w_nlp_tor_Mu, w_nlp_tor_Vu, w_nlp_tor_geom, w_nlp_tor_opts;
                                       Tu=w_nlp_tor_Tu, L_span=w_nlp_tor_L)
    w_nlp_notor = size_steel_w_beam_nlp(w_nlp_tor_Mu, w_nlp_tor_Vu, w_nlp_tor_geom, w_nlp_tor_opts)

    println("\n  15.3.2  Steel W Beam NLP — Strength + Torsion (DG9)")
    println("    Demand: Mu = 56.25 kip·ft, Vu = 7.5 kip, Tu = 90 kip·in, L = 15 ft")
    println()
    @printf("    %-28s  %12s  %12s\n", "Property", "With Tu", "Without Tu")
    @printf("    %-28s  %12s  %12s\n", "─"^28, "─"^12, "─"^12)
    @printf("    %-28s  %12.2f  %12.2f\n", "Area (in²)", w_nlp_tor.area, w_nlp_notor.area)
    @printf("    %-28s  %12.1f  %12.1f\n", "Weight (plf)", w_nlp_tor.weight_per_ft, w_nlp_notor.weight_per_ft)
    @printf("    %-28s  %12s  %12s\n", "Status", string(w_nlp_tor.status), string(w_nlp_notor.status))
    println()
    bm_note("W-shape torsion uses DG9 midspan interaction (warping + pure torsion).")
end

# ── 15.3.3  Steel HSS Beam NLP with torsion ──
begin
    hss_nlp_tor_Mu = 40.0u"kip*ft"
    hss_nlp_tor_Vu = 10.0kip
    hss_nlp_tor_Tu = 50.0  # kip·in (raw)
    hss_nlp_tor_opts = NLPHSSOptions()  # Default A992 (Fy=50ksi, same as A500 Gr.B rect HSS)

    hss_nlp_tor = size_steel_hss_beam_nlp(hss_nlp_tor_Mu, hss_nlp_tor_Vu, hss_nlp_tor_opts; Tu=hss_nlp_tor_Tu)
    hss_nlp_notor = size_steel_hss_beam_nlp(hss_nlp_tor_Mu, hss_nlp_tor_Vu, hss_nlp_tor_opts)

    println("\n  15.3.3  Steel HSS Beam NLP — Strength + Torsion (AISC H3)")
    println("    Demand: Mu = 40 kip·ft, Vu = 10 kip, Tu = 50 kip·in")
    println()
    @printf("    %-28s  %12s  %12s\n", "Property", "With Tu", "Without Tu")
    @printf("    %-28s  %12s  %12s\n", "─"^28, "─"^12, "─"^12)
    @printf("    %-28s  %12.2f  %12.2f\n", "Area (in²)", hss_nlp_tor.area, hss_nlp_notor.area)
    @printf("    %-28s  %12.1f  %12.1f\n", "Weight (plf)", hss_nlp_tor.weight_per_ft, hss_nlp_notor.weight_per_ft)
    @printf("    %-28s  %12s  %12s\n", "Status", string(hss_nlp_tor.status), string(hss_nlp_notor.status))
    println()
bm_note("HSS torsion: H3-6 interaction (Mr/Mc + (Vr/Vc + Tr/Tc)²); closed section = pure shear flow.")
end

# ── 15.3.4  RC T-Beam NLP with torsion ──
begin
    tbeam_nlp_tor_Mu = 200.0kip * u"ft"
    tbeam_nlp_tor_Vu = 40.0kip
    tbeam_nlp_tor_Tu = 100.0  # kip·in (raw)
    tbeam_nlp_tor_opts = NLPBeamOptions(
        min_depth=16.0u"inch", max_depth=30.0u"inch",
        min_width=10.0u"inch", max_width=18.0u"inch",
    )
    tbeam_nlp_bf = 48.0u"inch"
    tbeam_nlp_hf = 5.0u"inch"

    tbeam_nlp_tor = size_rc_tbeam_nlp(tbeam_nlp_tor_Mu, tbeam_nlp_tor_Vu,
                                       tbeam_nlp_bf, tbeam_nlp_hf, tbeam_nlp_tor_opts; Tu=tbeam_nlp_tor_Tu)
    tbeam_nlp_notor = size_rc_tbeam_nlp(tbeam_nlp_tor_Mu, tbeam_nlp_tor_Vu,
                                         tbeam_nlp_bf, tbeam_nlp_hf, tbeam_nlp_tor_opts)

    println("\n  15.3.4  RC T-Beam NLP — Strength + Torsion")
    println("    Demand: Mu = 200 kip·ft, Vu = 40 kip, Tu = 100 kip·in")
    println("    bf = 48\", hf = 5\" (fixed)")
    println()
    @printf("    %-28s  %12s  %12s\n", "Property", "With Tu", "Without Tu")
    @printf("    %-28s  %12s  %12s\n", "─"^28, "─"^12, "─"^12)
    @printf("    %-28s  %12.1f  %12.1f\n", "bw (in)", tbeam_nlp_tor.bw_final, tbeam_nlp_notor.bw_final)
    @printf("    %-28s  %12.1f  %12.1f\n", "h (in)", tbeam_nlp_tor.h_final, tbeam_nlp_notor.h_final)
    @printf("    %-28s  %12.1f  %12.1f\n", "Web area (in²)", tbeam_nlp_tor.area_web, tbeam_nlp_notor.area_web)
    @printf("    %-28s  %12s  %12s\n", "Status", string(tbeam_nlp_tor.status), string(tbeam_nlp_notor.status))
    println()
    bm_note("T-beam torsion: Aoh/ph from web rectangle (stirrups in web only).")
end

nlp_tor_ok = (nlp_tor_result.status == :optimal || nlp_tor_result.status == :first_order) &&
             (w_nlp_tor.status == :optimal || w_nlp_tor.status == :first_order) &&
             (hss_nlp_tor.status == :optimal || hss_nlp_tor.status == :first_order) &&
             (tbeam_nlp_tor.status == :optimal || tbeam_nlp_tor.status == :first_order)

@testset "Torsion NLP Integration" begin
    @test nlp_tor_result.status in (:optimal, :first_order)
    @test nlp_notor_result.status in (:optimal, :first_order)
    @test nlp_tor_result.area > 0  # valid section found
    @test w_nlp_tor.status in (:optimal, :first_order)
    @test w_nlp_notor.status in (:optimal, :first_order)
    @test w_nlp_tor.area ≥ w_nlp_notor.area - 1.0  # torsion drives W-shape larger
    @test hss_nlp_tor.status in (:optimal, :first_order)
    @test hss_nlp_notor.status in (:optimal, :first_order)
    @test hss_nlp_tor.area ≥ hss_nlp_notor.area - 1.0  # torsion drives HSS larger
    @test tbeam_nlp_tor.status in (:optimal, :first_order)
    @test tbeam_nlp_notor.status in (:optimal, :first_order)
end
bm_step_status["Torsion NLP"] = nlp_tor_ok ? "✓" : "✗"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  16. DESIGN CODE FEATURES & LIMITATIONS                                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_sub_header("16.0  Feature Matrix")
println("    RC/RC-T: Whitney flex (§22.2), shear (§22.5), torsion (§22.7), deflection (§24.2), MIP+NLP, batch, snap")
println("    Steel W: AISC F2+LTB flex, G2 shear, DG9 torsion, Ix_min defl., MIP+NLP, warm-start, batch, snap")
println("    Steel HSS: AISC F7 flex (no LTB), G4 shear, H3-6 torsion, Ix_min defl., MIP+NLP, warm-start, batch, snap")

bm_sub_header("16.1  Shared Components")
println("    Unified API (optimize_discrete/optimize_continuous) + Ipopt NLP with smooth constraints.")
println("    RC: 3 vars (b,h,ρ); RC-T: 3 vars (bw,h,ρ) + fixed bf/hf; W: 4 vars (d,bf,tf,tw); HSS: 3 vars (B,H,t).")
println("    T-beam: minimizes web area bw×h; shear/ρ_min use bw; irregular bf via moment_weighted_avg_depth.")

bm_sub_header("16.2  Current Limitations & Future Work")
println("    Not yet: development length in sizing, composite/precast beams, flange transverse reinf. (§9.7.6.3).")
println("    Torsion NLP ensures adequacy only; detailed At/s & Al design is post-sizing.")

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  17. FINAL SUMMARY                                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
bm_section_header("BEAM SIZING REPORT — SUMMARY")

println("  Step                            Status")
println("  ────────────────────────────── ──────")
for (name, status) in sort(collect(bm_step_status))
    println("  $(rpad(name, 32)) $status")
end

all_pass = all(v == "✓" for v in values(bm_step_status))
println()
println("  Overall: $(all_pass ? "✓ ALL CHECKS PASSED" : "✗ SOME CHECKS FAILED")")
println()
bm_note("NLP: RC(b,h,ρ) + RC-T(bw,h,ρ,fixed bf/hf) + W(F2+G2+LTB) + HSS(F7+G4). Defl: Ix_min(steel), §24.2(RC-T). Torsion: §22.7/DG9/H3-6. Snap+raw shown.")
println(BM_DLINE)

@test all_pass

end  # @testset
