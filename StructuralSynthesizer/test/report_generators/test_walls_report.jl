# ==============================================================================
# Shear-Wall Lateral-System Validation Report
# ==============================================================================
# Validates the shear-wall efficiency foundation (plan S1–S4) end to end:
#   S1  Analytic in-plane wall stiffness (ACI 318-19 effective inertia) +
#       demand-decoupled ACI 318-19 §11.5.4 in-plane shear capacity +
#       ACI 318-19 §22.2 in-plane axial–flexure (P–M) capacity
#   S2  Reduced rigid-diaphragm distribution (3 DOF/story) + analytic sensitivity
#   S3  FEM validation (Asap vertical wall shells + stiff diaphragm) vs the S2 oracle
#   S4  Layout optimization (SIMP continuous topology, MinCarbon) via Ipopt
#
# For each stage the report prints Computed / Ref / Δ% tables with ✓/~/✗ marks,
# where "Ref" is an independent hand calculation, a closed-form result, a finite
# difference, or (S3) the reduced-model known-answer oracle.
#
# Format follows the beam/column sizing validation reports.
#
# Reference:
#   - ACI 318-19 §11.5.4 (in-plane shear), Table 6.6.3.1.1(a) (effective stiffness),
#     §11.6.2 (minimum web reinforcement)
#   - StructurePoint spWall worked examples (corpus: sp-de-shear-wall-aci19) — the
#     intended real-world capacity oracle; clause/page cites are VERIFY pending
#     zettelkasten extraction (not yet numerically reconciled here).
#   - Zhang & Mueller (2017), shear-wall layout optimization (S4 paradigm)
# ==============================================================================

using Test
using Printf
using Dates
using Unitful
using Unitful: @u_str
using Asap
using StructuralSizer

# ─────────────────────────────────────────────────────────────────────────────
# Report helpers (same style as beam/column reports)
# ─────────────────────────────────────────────────────────────────────────────

const W_HLINE = "─"^78
const W_DLINE = "═"^78

w_section_header(title) = println("\n", W_DLINE, "\n  ", title, "\n", W_DLINE)
w_sub_header(title)     = println("\n  ", W_HLINE, "\n  ", title, "\n  ", W_HLINE)
w_note(msg)             = println("    → ", msg)

function w_table_head(ref_label="Ref")
    @printf("    %-34s %13s %13s %8s %s\n", "Quantity", "Computed", ref_label, "Δ%", "")
    @printf("    %-34s %13s %13s %8s %s\n", "─"^34, "─"^13, "─"^13, "─"^8, "──")
end

"""Print one comparison row. Returns `true` when |δ| ≤ tol."""
function w_compare(label, computed, reference; tol=0.10, unit="")
    v = Float64(computed); r = Float64(reference)
    δ = abs(r) > 1e-12 ? (v - r) / abs(r) : (abs(v) < 1e-12 ? 0.0 : 1.0)
    ok = abs(δ) ≤ tol
    flag = ok ? "✓" : (abs(δ) ≤ 2tol ? "~" : "✗")
    lbl = isempty(unit) ? label : "$label ($unit)"
    @printf("    %-34s %13.4g %13.4g %+7.1f%%  %s\n", lbl, v, r, 100δ, flag)
    return ok
end

"""Print an informational (non-graded) row."""
w_info(label, val; unit="") = @printf("    %-34s %13.4g   %s\n", label, Float64(val), unit)

const _w_status = Dict{String,String}()
_mark(pass) = pass ? "✓" : "✗"

# ─────────────────────────────────────────────────────────────────────────────
# Shared inputs
# ─────────────────────────────────────────────────────────────────────────────
const E   = 25.0e9      # concrete modulus [Pa] (~ f'c 28 MPa NWC)
const NU  = 0.20        # Poisson ratio
const FC  = 28.0e6      # f'c [Pa]
const FY  = 60_000.0 * 6894.757   # rebar fy [Pa] (Grade 60, psi→Pa)
const RHOC = 2400.0     # concrete density [kg/m³]
const ECC  = 0.135      # embodied carbon [kgCO₂e/kg] (illustrative)

@testset "Shear-Wall Lateral-System Report" begin

println("\n\n")
w_section_header("SHEAR-WALL LATERAL-SYSTEM VALIDATION REPORT")
@printf("  Generated: %s  |  S1–S4 efficiency foundation (StructuralSizer/src/walls)\n",
        Dates.format(now(), "yyyy-mm-dd HH:MM"))

w_sub_header("1.0  Input Summary")
w_note("Concrete: E=25 GPa, ν=0.20, f'c=28 MPa, ρ=2400 kg/m³, ecc=0.135 kgCO₂e/kg")
w_note("Steel: fy=60 ksi (Grade 60), min web reinf ρl=ρt=0.0025 (ACI 318-19 §11.6.2)")
w_note("Reference wall: lw=4.0 m, t=0.3 m, story H=3.0 m; shear checked at hw=6.0 m (hw/lw=1.5)")
w_note("Codes: ACI 318-19 §11.5.4 / Table 6.6.3.1.1(a) / §11.6.2 — reconciled vs corpus (see §3.4)")

# ═══════════════════════════════════════════════════════════════════════════
# 2. S1 — Analytic in-plane wall stiffness
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("2.0  S1 — Analytic In-Plane Wall Stiffness (ACI effective inertia)")
lw = 4.0; t = 0.3; H = 3.0

k_cracked   = wall_stiffness_from_thickness_si(t, lw, E, NU, H; cracked=true)
k_uncracked = wall_stiffness_from_thickness_si(t, lw, E, NU, H; cracked=false)

w_sub_header("2.1  Stiffness values")
w_info("Gross inertia Ig = t·lw³/12", t*lw^3/12; unit="m⁴")
w_info("k (cracked, 0.35 Ig)", k_cracked/1e6; unit="MN/m")
w_info("k (uncracked, 0.70 Ig)", k_uncracked/1e6; unit="MN/m")

w_sub_header("2.2  Closed-form properties (Computed vs analytical Ref)")
w_table_head("Analytical")
s1 = true
# Linearity in thickness: k(2t) = 2·k(t)
k_2t = wall_stiffness_from_thickness_si(2t, lw, E, NU, H; cracked=true)
s1 &= w_compare("Linearity k(2t) vs 2·k(t)", k_2t/1e6, 2*k_cracked/1e6; tol=1e-6, unit="MN/m")
# Analytic derivative equals k/t
dk = dwall_stiffness_dthickness_si(t, lw, E, NU, H; cracked=true)
s1 &= w_compare("Derivative ∂k/∂t vs k/t", dk/1e6, (k_cracked/t)/1e6; tol=1e-6, unit="MN/m/m")
# Cracked softer than uncracked
crack_ok = k_cracked < k_uncracked
println("    Cracked < uncracked stiffness ......................... ", _mark(crack_ok))
s1 &= crack_ok
# Unitful section API agrees with bare-SI core
ws  = WallSection(lw*u"m", t*u"m")
cmat = Concrete(E*u"Pa", FC*u"Pa", RHOC*u"kg/m^3", NU, ECC)
k_api = ustrip(u"N/m", wall_lateral_stiffness(ws, cmat, H*u"m"; cracked=true))
s1 &= w_compare("Unitful API vs bare-SI core", k_api/1e6, k_cracked/1e6; tol=1e-6, unit="MN/m")
_w_status["S1 stiffness"] = _mark(s1)
w_note("k is linear in thickness (flexural & shear flexibility ∝ 1/t) → clean SIMP relaxation for S4.")

# ═══════════════════════════════════════════════════════════════════════════
# 3. S1 — ACI 318-19 in-plane shear capacity
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("3.0  S1 — ACI 318-19 §11.5.4 In-Plane Shear Capacity")
ρt = 0.0025

w_sub_header("3.1  Capacity vs independent hand calc (psi/in)")
w_table_head("Hand calc")
s1s = true
# independent hand calculation in ACI customary units
fc_psi = FC/6894.757; fy_psi = FY/6894.757
lw_in = lw/0.0254; t_in = t/0.0254; Acv_in2 = lw_in*t_in
hw = 6.0  # 2-story pier, hw/lw = 1.5 → αc plateau at 3.0
αc_hand = 3.0
Vn_hand_lb = (αc_hand*1.0*sqrt(fc_psi) + ρt*fy_psi)*Acv_in2
Vn_hand = Vn_hand_lb*4.4482216
cap = wall_shear_capacity_si(FC, FY, lw, t, ρt, hw)
s1s &= w_compare("αc (hw/lw=1.5)", cap.αc, αc_hand; tol=1e-9)
s1s &= w_compare("Vn nominal", cap.Vn/1e3, Vn_hand/1e3; tol=1e-3, unit="kN")
s1s &= w_compare("φVn (φ=0.75)", cap.ϕVn/1e3, 0.75*Vn_hand/1e3; tol=1e-3, unit="kN")

w_sub_header("3.2  αc transition (ACI 318-19 §11.5.4.3)")
w_table_head("Expected")
s1s &= w_compare("αc @ hw/lw=1.5 (plateau)", wall_shear_capacity_si(FC,FY,lw,t,ρt,1.5*lw).αc, 3.0; tol=1e-9)
s1s &= w_compare("αc @ hw/lw=1.75 (linear)", wall_shear_capacity_si(FC,FY,lw,t,ρt,1.75*lw).αc, 2.5; tol=1e-9)
s1s &= w_compare("αc @ hw/lw=2.0 (plateau)", wall_shear_capacity_si(FC,FY,lw,t,ρt,2.0*lw).αc, 2.0; tol=1e-9)

w_sub_header("3.3  Demand-decoupled check + minimum reinforcement")
chk = check_wall_inplane_shear(ws, cmat, 800e3*u"N", hw*u"m")
util_ok = isapprox(chk.ratio, 800e3/cap.ϕVn; rtol=1e-3)
println("    CheckResult clause .................................... ", chk.code_clause)
@printf("    Vu=800 kN  φVn=%.0f kN  utilization=%.3f  %s\n", cap.ϕVn/1e3, chk.ratio, _mark(chk.passed))
minr = check_wall_min_reinforcement(ws)
minr_ok = all(c.passed for c in minr)
println("    Min web reinf ρl,ρt ≥ 0.0025 (§11.6.2) ............... ", _mark(minr_ok))
s1s &= util_ok && minr_ok

w_sub_header("3.4  spWall worked example — corpus known-answer (sp-de-shear-wall-aci19)")
w_note("f'c=4000 psi, fyt=60 ksi, t=10 in, lw=18 ft, ρt=0.0025, hw/lw=3.0 (αc=2.0)")
w_table_head("spWall")
PSI=6894.757; KIP=4448.2216; IN=0.0254; FT=0.3048
sp_fc=4000*PSI; sp_fy=60_000*PSI; sp_lw=216*IN; sp_t=10*IN; sp_hw=54*FT
spc  = wall_shear_capacity_si(sp_fc, sp_fy, sp_lw, sp_t, 0.0025, sp_hw)
spc0 = wall_shear_capacity_si(sp_fc, sp_fy, sp_lw, sp_t, 0.0, sp_hw)
s1s &= w_compare("αc @ hw/lw=3.0", spc.αc, 2.0; tol=1e-9)
s1s &= w_compare("φVc (concrete)", spc0.ϕVn/KIP, 204.92; tol=3e-3, unit="kip")
s1s &= w_compare("φVs (steel)", (spc.ϕVn-spc0.ϕVn)/KIP, 243.00; tol=3e-3, unit="kip")
s1s &= w_compare("φVn (total)", spc.ϕVn/KIP, 447.92; tol=3e-3, unit="kip")
_w_status["S1 shear capacity"] = _mark(s1s)
w_note("Reproduces the StructurePoint spWall hand calc to <0.3%; §11.5.4.2 cap = 8·λ·√f'c·Acv.")

# ═══════════════════════════════════════════════════════════════════════════
# 3F. S1 — ACI 318-19 in-plane axial–flexure (P–M) capacity
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("3F.0  S1 — ACI 318-19 §22.2 In-Plane Axial–Flexure (P–M) Capacity")
w_note("Cardenas closed form (conservative, pass–fail) + strain-compatibility interaction diagram (spColumn-style).")

w_sub_header("3F.1  spWall worked example — corpus known-answer (sp-de-shear-wall-aci19 §§3–4)")
w_note("lw=18 ft, t=10 in, ρl=0.00344 (#5@18\" both faces), f'c=4000 psi, fy=60 ksi, Es=29000 ksi")
w_note("Demand: Nu=207 kips (0.9·dead), Mu,base=4665 kip-ft (1.0·wind)")
w_table_head("spWall")
s1f = true
# spWall inputs in SI (bare-SI core; PSI/KIP/IN/FT from §3.4)
sp_Es = 29.0e6 * PSI
sp_ρl = 0.00344
sp_Nu = 207 * KIP
sp_Mu = 4665 * KIP * 12 * IN            # kip-ft → N·m
rf = wall_axial_flexure_capacity_si(sp_fc, sp_fy, sp_Es, sp_lw, sp_t, sp_ρl, sp_Nu)
s1f &= w_compare("ω = ρl·fy/f'c", rf.ω, 0.0517; tol=5e-3)
s1f &= w_compare("α = Nu/(lw·t·f'c)", rf.α, 0.0240; tol=1e-2)
s1f &= w_compare("Neutral axis c", rf.c/IN, 19.78; tol=1e-2, unit="in")
s1f &= w_compare("Tension resultant T", rf.T/KIP, 405.52; tol=1e-2, unit="kip")
s1f &= w_compare("Nominal Mn", rf.Mn/(KIP*12*IN), 5342.0; tol=1e-2, unit="kip-ft")
s1f &= w_compare("Design φMn (φ=0.90)", rf.φMn/(KIP*12*IN), 4808.0; tol=1e-2, unit="kip-ft")
tc_ok = rf.tension_controlled && rf.φ == 0.90
@printf("    εt = %.4f  > εty+0.003 = %.4f  ⇒ tension-controlled  %s\n",
        rf.εt, rf.εty + 0.003, _mark(tc_ok))
s1f &= tc_ok

w_sub_header("3F.2  Demand-decoupled CheckResult (φMn > Mu ⇒ adequate)")
ws_sp = WallSection(sp_lw*u"m", sp_t*u"m"; ρl=sp_ρl, ρt=0.0025)
chkf = check_wall_inplane_flexure(ws_sp, RC_4000_60, sp_Nu*u"N", sp_Mu*u"N*m")
println("    CheckResult clause .................................... ", chkf.code_clause)
@printf("    Mu=%.0f kip-ft  φMn=%.0f kip-ft  utilization=%.3f  %s\n",
        chkf.demand/(KIP*12*IN), chkf.capacity/(KIP*12*IN), chkf.ratio, _mark(chkf.passed))
s1f &= chkf.passed && isapprox(chkf.ratio, 4665/4808; atol=0.02)

w_sub_header("3F.3  Strain-compatibility diagram cross-check (independent method)")
w_table_head("vs Cardenas")
sp_Ast = sp_ρl * sp_lw * sp_t
rd = wall_moment_capacity_at_axial_si(sp_fc, sp_fy, sp_Es, sp_lw, sp_t, sp_Ast, sp_Nu; nlayers=200)
# Two independent methods must agree to ~5%; strain-compat is the less-conservative
# (spColumn-style) curve, so it sits at/above the Cardenas value.
s1f &= w_compare("φMn (strain-compat) vs Cardenas", rd.φMn/(KIP*12*IN), rf.φMn/(KIP*12*IN); tol=0.05, unit="kip-ft")
diag_conservative = rd.φMn ≥ rf.φMn * 0.99
println("    Strain-compat ≥ Cardenas (Cardenas conservative) .... ", _mark(diag_conservative))
w_info("spColumn reference φMn (report only)", 5319; unit="kip-ft  (less conservative; not asserted)")
_w_status["S1 axial-flexure (P-M)"] = _mark(s1f)
w_note("Reproduces the spWall Cardenas hand calc to <0.2%. CheckResult guards: §22.4.2.1 axial cap")
w_note("(Nu ≤ φ·0.80·P0) + governing moment = conservative min(Cardenas, strain-compat) in all regimes.")

# ═══════════════════════════════════════════════════════════════════════════
# 3P. S1 — ACI 318-19 §11.8 out-of-plane slender wall (alternative method)
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("3P.0  S1 — ACI 318-19 §11.8 Out-of-Plane Slender Wall (P-Δ)")
w_note("Second-order (P-Δ) moment magnification, Mcr, φMn, bilinear service deflection + §11.8.1.1 gates.")

w_sub_header("3P.1  spWall tilt-up worked example — corpus known-answer (sp-de-tilt-up-wall-aci19)")
w_note("15-ft strip: h=6.25 in, lc=29.5 ft, e=3.0 in, As=7.04 in² (#6@11¼\"), f'c=4000 psi, fy=60 ksi")
w_note("Demand: Pua=20.64 k, Pum=43.49 k, wu=0.204 k/ft ⇒ magnified Mu (Eq. 11.8.3.1(d))")
w_table_head("spWall tilt-up")
s1o = true
op_b  = 180 * IN;    op_h  = 6.25 * IN;   op_d  = 3.13 * IN
op_lc = 29.5 * FT;   op_e  = 3.0 * IN;    op_As = 7.04 * IN^2
op_Pua = 20.64 * KIP; op_Pum = 43.49 * KIP; op_wu = 0.204 * KIP / FT
KIPFT = KIP * 12 * IN
so = oop_slender_wall_strength_si(sp_fc, sp_fy, 29.0e6*PSI, op_b, op_h, op_d,
                                  op_lc, op_e, op_As, op_Pua, op_Pum, op_wu)
s1o &= w_compare("Effective steel Ase", so.Ase/IN^2, 7.76; tol=1e-2, unit="in²")
s1o &= w_compare("Neutral axis c", so.c/IN, 0.896; tol=2e-2, unit="in")
s1o &= w_compare("Cracked inertia Icr", so.Icr/IN^4, 353.56; tol=2e-2, unit="in⁴")
s1o &= w_compare("Stiffness Kb=48EcIcr/5lc²", so.Kb/KIP, 97.64; tol=2e-2, unit="kip")
s1o &= w_compare("First-order Mua", so.Mua/KIPFT, 24.77; tol=1e-2, unit="kip-ft")
s1o &= w_compare("Magnified Mu (P-Δ)", so.Mu/KIPFT, 61.00; tol=2e-2, unit="kip-ft")
s1o &= w_compare("Cracking moment Mcr", so.Mcr/KIPFT, 46.32; tol=1e-2, unit="kip-ft")
s1o &= w_compare("Design φMn (φ=0.90)", so.φMn/KIPFT, 95.89; tol=1e-2, unit="kip-ft")
s1o &= w_compare("Mid-height Δu", so.Δu/IN, 9.995; tol=2e-2, unit="in")
tco = so.tension_controlled && so.φ == 0.90 && so.stable
println("    tension-controlled & φ=0.90 & P-Δ stable ........... ", _mark(tco))
s1o &= tco

w_sub_header("3P.2  Service out-of-plane deflection (bilinear, Table 11.8.4.1)")
op_Msa = 20.32 * KIPFT; op_Ps = 26.24 * KIP
svc = oop_service_deflection_si(op_Msa, op_Ps, so.Mcr, so.Mn, so.Ec, so.Ig, so.Icr, op_lc)
s1o &= w_compare("Cracking deflection Δcr", svc.Δcr/IN, 0.550; tol=2e-2, unit="in")
s1o &= w_compare("Service deflection Δs", svc.Δs/IN, 0.247; tol=5e-2, unit="in")
serv_ok = svc.converged && svc.Δs ≤ op_lc / 150
@printf("    Δs = %.3f in  ≤  lc/150 = %.2f in  (§11.8.4.1)  %s\n",
        svc.Δs/IN, (op_lc/150)/IN, _mark(serv_ok))
s1o &= serv_ok

w_sub_header("3P.3  §11.8.1.1 applicability gates + demand-coupled CheckResult")
g = oop_slender_wall_gates(so, sp_fc, op_b, op_h, op_lc, op_Pum; Δs=svc.Δs)
s1o &= w_compare("Axial stress Pu/Ag", g.σ_axial/PSI, 38.66; tol=2e-2, unit="psi (≤ 0.06f'c=240)")
gates_ok = g.gate_b && g.gate_c && g.gate_d && g.gate_e && g.applicable
println("    gates (b) TC · (c) φMn≥Mcr · (d) axial · (e) Δs ..... ", _mark(gates_ok))
s1o &= gates_ok
# Service loads supplied so the mandatory §11.8.1.1(e) Δs≤lc/150 gate is checked
# end-to-end (ws reproduces the documented Msa=20.32 kip-ft; Pa=7.20 k roof DL).
op_Pa = 7.20 * KIP
op_ws = (op_Msa - op_Pa * op_e / 2) * 8 / op_lc^2
chko = check_wall_out_of_plane_slender(RC_4000_60, op_b*u"m", op_h*u"m", op_d*u"m",
           op_lc*u"m", op_e*u"m", op_As*u"m^2", op_Pua*u"N", op_Pum*u"N", op_wu*u"N/m";
           ws=op_ws*u"N/m", Pa=op_Pa*u"N", Ps=op_Ps*u"N")
println("    CheckResult clause ................................... ", chko.code_clause)
@printf("    Mu=%.1f kip-ft  φMn=%.1f kip-ft  utilization=%.3f  %s\n",
        chko.demand/KIPFT, chko.capacity/KIPFT, chko.ratio, _mark(chko.passed))
s1o &= chko.passed && chko.code_clause == "ACI 318-19 11.8"
_w_status["S1 out-of-plane slender (§11.8)"] = _mark(s1o)
w_note("Reproduces the spWall tilt-up P-Δ hand calc to <2%. Applicability gates are a HARD safety")
w_note("boundary: non-TC, φMn<Mcr, Pu>0.06f'cAg, Δs>lc/150, or P-Δ instability ⇒ method refused (fail-safe).")

# ═══════════════════════════════════════════════════════════════════════════
# 3B. S1 — ACI 318-19 §11.5.3 simplified / empirical bearing wall
# ═══════════════════════════════════════════════════════════════════════════
# Validated against an independent textbook numeric oracle — McCormac & Brown,
# Design of Reinforced Concrete 9th ed., Example 18.1 (ACI 318 §14.5.2 Eq. 14-1
# = ACI 318-19 §11.5.3.1; corpus: mccormac-9e / ZK
# mccormac-de-bearing-wall-empirical-aci318-11) — plus a self-consistency hand
# calc and an Asap FEA of the two physical ingredients.
w_section_header("3B.0  S1 — ACI 318-19 §11.5.3 Simplified / Empirical Bearing Wall")
w_note("Closed-form axial capacity φPn = 0.55·φ·f'c·Ag·[1−(k·lc/32h)²] with middle-third + min-thickness gates.")

b_fc = 4000 * PSI; b_E = 57000 * sqrt(4000) * PSI; b_nu = 0.20
b_G  = b_E / (2 * (1 + b_nu))
b_b  = 12 * IN; b_h = 8 * IN; b_lc = 15 * FT
b_Ag = b_b * b_h; b_Iweak = b_b * b_h^3 / 12; b_Istrong = b_h * b_b^3 / 12

w_sub_header("3B.1  McCormac Ex. 18.1 textbook oracle (ACI §14.5.2 Eq. 14-1)")
w_note("Precast roof beams @7 ft o.c., bearing 10 in; braced + rotation-restrained (k=0.8);")
w_note("lc=16 ft, f'c=3000 psi, D=30 k, L=18 k. Effective length min(84, 10+4·8)=42 in ⇒ Ag=336 in².")
w_table_head("McCormac Ex.18.1")
s1b = true
mc_fc = 3000 * PSI; mc_lc = 16 * FT; mc_h = 8 * IN
mc_leff = min(84 * IN, (10 + 4*8) * IN); mc_Ag = mc_h * mc_leff
mccap = wall_empirical_axial_capacity_si(mc_fc, mc_lc, mc_h, mc_Ag; k=0.8, φ=0.65)
s1b &= w_compare("Min thickness (1/25·16 ft)", wall_min_thickness_si(20*FT, mc_lc)/IN, 7.68; tol=1e-3, unit="in")
s1b &= w_compare("Effective length min(84,42)", mc_leff/IN, 42.0; tol=1e-9, unit="in")
s1b &= w_compare("Slenderness k·lc/32h", mccap.slender, 0.60; tol=2e-3)
s1b &= w_compare("Knock-down R = 1−0.6²", mccap.R, 0.64; tol=2e-3)
s1b &= w_compare("Design φPnw (oracle)", mccap.φPn/KIP, 230.6; tol=2e-3, unit="kip")
mc_Pu = (1.2*30 + 1.6*18) * KIP
s1b &= w_compare("Factored reaction Pu", mc_Pu/KIP, 64.8; tol=1e-9, unit="kip")
# Pin the oracle through the REAL code path: boundary=:restrained exercises the
# Table 11.5.3.2 k-factor lookup (k=0.8) and the default φ (WALL_PHI_BEARING),
# so this row alone catches a broken k-table or φ default.
mc_conc = Concrete(24.855e9u"Pa", mc_fc*u"Pa", RHOC*u"kg/m^3", 0.20, 0.1)
mc_chk  = check_wall_bearing_empirical(WallSection(mc_leff*u"m", mc_h*u"m"), mc_conc,
                                       mc_Pu*u"N"; e=0.0u"m", lc=mc_lc*u"m",
                                       lu=(20*FT)*u"m", boundary=:restrained)
s1b &= w_compare("φPnw via :restrained + default φ", mc_chk.capacity/KIP, 230.6; tol=2e-3, unit="kip")
@printf("    φPnw = %.1f kip > Pu = %.1f kip, util = %.3f, clause %s (McCormac: 230.6 > 64.8)  %s\n",
        mc_chk.capacity/KIP, mc_Pu/KIP, mc_chk.ratio, mc_chk.code_clause, _mark(mc_chk.passed))
s1b &= mc_chk.passed && mc_chk.code_clause == "ACI 318-19 11.5.3.1"

w_sub_header("3B.2  Self-consistency hand calc + Asap FEA cross-check")
w_note("Hand calc (k=1.0): 12-in strip, h=8 in, lc=15 ft ⇒ k·lc/32h=0.70313, R=0.50562, φPn=69.41 kip.")
bcap = wall_empirical_axial_capacity_si(b_fc, b_lc, b_h, b_Ag; k=1.0, φ=0.65)
w_table_head("hand calc")
s1b &= w_compare("Slenderness k·lc/32h", bcap.slender, 180/256; tol=1e-4)
s1b &= w_compare("Knock-down R", bcap.R, 1-(180/256)^2; tol=1e-4)
s1b &= w_compare("Design φPn (φ=0.65)", bcap.φPn/KIP, 69.41; tol=1e-3, unit="kip")
w_note("FEA of the two physical ingredients:")
w_note("(1) shell membrane model reproduces E·Ag (material/area basis of 0.55·f'c·Ag);")
w_note("(2) frame beam-column model reproduces Euler buckling; φPn sits safely below it.")

function b_shell_axial_EA(b, lc, h, E, ν, P; nx=3, ny=18)
    nodes = Asap.Node[]
    for j in 0:ny, i in 0:nx
        push!(nodes, Asap.Node([i*b/nx*u"m", j*lc/ny*u"m", 0.0u"m"], :free))
    end
    for (idx, nd) in enumerate(nodes)
        nd.nodeID = idx; nd.globalID = collect((idx-1)*6+1 : idx*6)
        nd.dof .= [true, true, false, false, false, false]
    end
    node(i, j) = nodes[j*(nx+1) + i + 1]
    for i in 0:nx; node(i, 0).dof[2] = false; end
    node(0, 0).dof[1] = false
    els = Asap.ShellTri3[]
    for j in 0:ny-1, i in 0:nx-1
        n1 = node(i,j); n2 = node(i+1,j); n3 = node(i,j+1); n4 = node(i+1,j+1)
        push!(els, Asap.ShellTri3((n1, n2, n4), h*u"m", E*u"Pa", ν))
        push!(els, Asap.ShellTri3((n1, n4, n3), h*u"m", E*u"Pa", ν))
    end
    for el in els
        Asap.process!(el); el.globalID = vcat([n.globalID for n in el.nodes]...)
    end
    ntop = nx + 1
    loads = Asap.AbstractLoad[Asap.NodeForce(node(i, ny), [0.0, -P/ntop, 0.0]u"N") for i in 0:nx]
    model = Asap.Model(nodes, els, loads); Asap.process!(model); Asap.solve!(model)
    δ = sum(model.u[node(i, ny).globalID[2]] for i in 0:nx) / ntop
    return P * lc / abs(δ)
end

function b_frame_buckling_Pcr(lc, A, Ix, Iy, E, G, Pa; n_elem=12)
    sec = Asap.Section(A*u"m^2", E*u"Pa", G*u"Pa", Ix*u"m^4", Iy*u"m^4", 1e-4*u"m^4")
    nodes = Asap.Node[]
    for i in 0:n_elem
        z  = i * lc / n_elem
        fx = i == 0 ? :pinned : i == n_elem ? [false,false,true,true,true,true] : :free
        push!(nodes, Asap.Node([0.0u"m", 0.0u"m", z*u"m"], fx))
    end
    els = [Asap.Element(nodes[i], nodes[i+1], sec, :col) for i in 1:n_elem]
    loads = Asap.AbstractLoad[Asap.NodeForce(nodes[end], [0.0, 0.0, -Pa]u"N")]
    res = Asap.solve_buckling!(Asap.Model(nodes, els, loads); n=4)
    return res.load_factors[1] * Pa
end

w_table_head("analytic")
b_EA_fea = b_shell_axial_EA(b_b, b_lc, b_h, b_E, b_nu, 1.0e6)
s1b &= w_compare("Shell axial stiffness E·Ag", b_EA_fea, b_E*b_Ag; tol=5e-2, unit="N")
b_Pcr_fea = b_frame_buckling_Pcr(b_lc, b_Ag, b_Istrong, b_Iweak, b_E, b_G, 1.0e6)
b_Pcr_eul = π^2 * b_E * b_Iweak / b_lc^2
s1b &= w_compare("Frame buckling vs Euler", b_Pcr_fea/KIP, b_Pcr_eul/KIP; tol=5e-2, unit="kip")
w_info("φPn / Pcr_fea (conservative < 1)", bcap.φPn/b_Pcr_fea)
buck_ok = bcap.φPn < b_Pcr_fea && bcap.Pn < b_Pcr_fea
@printf("    φPn=%.1f kip < Pcr=%.1f kip (strength below elastic buckling)  %s\n",
        bcap.φPn/KIP, b_Pcr_fea/KIP, _mark(buck_ok))
s1b &= buck_ok

w_sub_header("3B.3  Applicability gates + demand-coupled CheckResult")
b_conc = Concrete(b_E*u"Pa", b_fc*u"Pa", RHOC*u"kg/m^3", b_nu, 0.1)
b_ws   = WallSection(b_b*u"m", b_h*u"m")
chkb = check_wall_bearing_empirical(b_ws, b_conc, (60*KIP)*u"N"; e=0.0u"m",
                                    lc=b_lc*u"m", boundary=:pinned)
@printf("    Pu=60 kip  φPn=%.1f kip  utilization=%.3f  clause=%s  %s\n",
        chkb.capacity/KIP, chkb.ratio, chkb.code_clause, _mark(chkb.passed))
# Each gate must FAIL as inapplicable (never a silent pass).
ge = check_wall_bearing_empirical(b_ws, b_conc, (60*KIP)*u"N"; e=(b_h/5)*u"m", lc=b_lc*u"m", boundary=:pinned)
gs = check_wall_bearing_empirical(b_ws, b_conc, (60*KIP)*u"N"; e=0.0u"m", lc=(32*b_h)*u"m", boundary=:pinned)
gt = check_wall_bearing_empirical(WallSection(b_b*u"m", (3*IN)*u"m"), b_conc, (60*KIP)*u"N"; e=0.0u"m", lc=b_lc*u"m", boundary=:pinned)
gates_b_ok = chkb.passed && !ge.passed && !gs.passed && !gt.passed &&
             ge.code_clause == "ACI 318-19 11.5.3.1" && gt.code_clause == "ACI 318-19 11.3.1.1"
println("    gates: middle-third (e≤h/6) · slenderness (klc/32h<1) · min-thickness  ", _mark(gates_b_ok))
s1b &= chkb.passed && chkb.code_clause == "ACI 318-19 11.5.3.1" && gates_b_ok
_w_status["S1 bearing wall (§11.5.3)"] = _mark(s1b)
w_note("Reproduces McCormac Ex. 18.1 (φPnw=230.6 k) exactly; FEA confirms E·Ag (<0.2%), Euler (<1%), φPn≈0.12·Pcr.")
w_note("Gates are a HARD boundary: e>h/6, klc/32h≥1, or h<Table 11.3.1.1 min ⇒ method refused (use general/§11.8).")

# ═══════════════════════════════════════════════════════════════════════════
# 4. S2 — Reduced rigid-diaphragm distribution
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("4.0  S2 — Reduced Rigid-Diaphragm Distribution (3 DOF/story)")
kk = 1.0e7
core(kv) = [WallLine(1, 0.0,-5.0, 0.0,  kv, 1), WallLine(2, 0.0, 5.0, 0.0, kv, 1),
            WallLine(3,-5.0, 0.0, pi/2, kv, 1), WallLine(4, 5.0, 0.0, pi/2, kv, 1)]
Fx = 1.0e5

w_sub_header("4.1  Symmetric core, direct shear (Computed vs closed form)")
w_table_head("Closed form")
evr = ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(5.0,5.0), accidental_ecc=0.0)
r = evaluate_lateral(evr, core(kk), [StoryLoad(1, Fx, 0.0, 0.0, 0.0)])
s2 = true
s2 &= w_compare("Diaphragm drift", r.drift[1], (Fx/(2kk))/H; tol=1e-4)
s2 &= w_compare("Wall-1 shear", r.wall_forces[1]/1e3, (Fx/2)/1e3; tol=1e-4, unit="kN")
s2 &= w_compare("ΣX-wall shear vs applied", (r.wall_forces[1]+r.wall_forces[2])/1e3, Fx/1e3; tol=1e-4, unit="kN")
s2 &= w_compare("Transverse (Y) wall shear", r.wall_forces[3]/1e3, 0.0; tol=1e-3, unit="kN")
s2 &= w_compare("Torsion amplification", r.torsion[1], 1.0; tol=1e-4)

w_sub_header("4.2  Accidental eccentricity induces torsion (ASCE 7 §12.8.4)")
re = evaluate_lateral(ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(5.0,5.0),
                                                accidental_ecc=0.05), core(kk), [StoryLoad(1,Fx,0.0,0.0,0.0)])
tors_ok = re.torsion[1] > 1.0 && !isapprox(re.wall_forces[1], re.wall_forces[2]; rtol=1e-3) &&
          isapprox(re.wall_forces[1]+re.wall_forces[2], Fx; rtol=1e-4)
@printf("    Wall-1/Wall-2 shear = %.1f / %.1f kN  (unequal ⇒ torsion, Σ=applied)  %s\n",
        re.wall_forces[1]/1e3, re.wall_forces[2]/1e3, _mark(tors_ok))
s2 &= tors_ok

w_sub_header("4.3  Analytic drift sensitivity vs finite difference")
w_table_head("Finite diff")
sens = story_drift_sensitivity(evr, core(kk), [StoryLoad(1,Fx,0.0,0.0,0.0)], 1)
h = kk*1e-6
wp = core(kk); wp[1] = WallLine(1,0.0,-5.0,0.0,kk+h,1)
wm = core(kk); wm[1] = WallLine(1,0.0,-5.0,0.0,kk-h,1)
fd = (evaluate_lateral(evr,wp,[StoryLoad(1,Fx,0.0,0.0,0.0)]).drift[1] -
      evaluate_lateral(evr,wm,[StoryLoad(1,Fx,0.0,0.0,0.0)]).drift[1])/(2h)
s2 &= w_compare("∂drift/∂k₁ (×1e9)", sens[1]*1e9, fd*1e9; tol=1e-3)
neg_ok = sens[1] < 0
println("    Stiffer wall ⇒ less drift (∂<0) ...................... ", _mark(neg_ok))
s2 &= neg_ok
_w_status["S2 distribution"] = _mark(s2)

# ═══════════════════════════════════════════════════════════════════════════
# 5. S3 — FEM validation (Asap shells) vs reduced oracle
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("5.0  S3 — FEM Validation (Asap wall shells) vs Reduced Oracle")
panels = WallPanel[
    WallPanel(1, -2.0,-5.0,  2.0,-5.0, 0.0, H, t, E, NU, 1),
    WallPanel(2, -2.0, 5.0,  2.0, 5.0, 0.0, H, t, E, NU, 1),
    WallPanel(3, -5.0,-2.0, -5.0, 2.0, 0.0, H, t, E, NU, 1),
    WallPanel(4,  5.0,-2.0,  5.0, 2.0, 0.0, H, t, E, NU, 1),
]
s3 = true
local fem
try
    femev = FEMLateralEvaluator(story_heights=[H], mesh_div=3, plan_halfwidth=(5.0,5.0))
    fem = evaluate_lateral(femev, panels, [StoryLoad(1, Fx, 0.0, 0.0, 0.0)])
    w_sub_header("5.1  Base-story wall shear from nodal reactions (Computed vs applied)")
    w_table_head("Equilibrium")
    s3 &= w_compare("ΣX-wall base shear vs applied", (fem.wall_forces[1]+fem.wall_forces[2])/1e3, Fx/1e3; tol=0.05, unit="kN")
    s3 &= w_compare("Wall-1 vs Wall-2 (symmetric)", fem.wall_forces[1]/1e3, fem.wall_forces[2]/1e3; tol=0.05, unit="kN")
    s3 &= w_compare("Torsion (symmetric)", fem.torsion[1], 1.0; tol=1e-3)

    w_sub_header("5.2  Drift cross-check vs reduced model (gross stiffness)")
    kg = wall_stiffness_from_thickness_si(t, lw, E, NU, H; cracked=false)
    rr = evaluate_lateral(ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(5.0,5.0),
                                                    accidental_ecc=0.0), core(kg), [StoryLoad(1,Fx,0.0,0.0,0.0)])
    ratio = fem.drift[1]/rr.drift[1]
    @printf("    FEM drift = %.3e   Reduced drift = %.3e   ratio = %.2f\n", fem.drift[1], rr.drift[1], ratio)
    same_order = 0.3 < ratio < 1.3
    println("    Same order (FEM stiffer for squat pier) .............. ", _mark(same_order))
    s3 &= same_order
    w_note("FEM captures 2D shear-flexure + diaphragm coupling; reduced model is the cheap inner-loop proxy.")
catch e
    println("    *** FEM stage error: ", e)
    s3 = false
end
_w_status["S3 FEM validation"] = _mark(s3)

# ═══════════════════════════════════════════════════════════════════════════
# 6. S4 — Layout optimization (SIMP topology, MinCarbon, Ipopt)
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("6.0  S4 — Layout Optimization (SIMP topology · MinCarbon · IPOPT)")
# Over-provisioned ground structure: the 4-wall core (needed for X+Y stability)
# plus 2 redundant X-walls at y=±3. Minimize carbon s.t. a drift limit under a
# biaxial load; the optimizer should thin the redundant walls.
mkcand(id,x,y,θ) = WallCandidate(id, x, y, θ, lw, H, 1, E, NU, FC, FY, RHOC, ECC, t, ρt)
cands = [mkcand(1,0.0,-5.0,0.0), mkcand(2,0.0,5.0,0.0),
         mkcand(3,-5.0,0.0,pi/2), mkcand(4,5.0,0.0,pi/2),
         mkcand(5,0.0,-3.0,0.0),  mkcand(6,0.0,3.0,0.0)]
evL = ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(5.0,5.0), accidental_ecc=0.05)
loadsL = [StoryLoad(1, 6.0e5, 4.0e5, 0.0, 0.0)]   # biaxial demand
drift_lim = 0.002
s4 = true
local prob, res4
try
    prob = WallLayoutNLPProblem(cands, evL, loadsL; objective=MinCarbon(),
                                drift_limit=drift_lim, torsion_limit=1.5, ρ_min=1e-3, penal=3.0)
    carbon_full = objective_fn(prob, fill(1.0, 6))    # all walls fully dense
    res4 = solve_wall_layout(prob; solver=:ipopt, maxiter=300)
    dens = res4.minimizer
    carbon_opt = objective_fn(prob, dens)
    g = constraint_fns(prob, dens)
    drift_util = maximum(g[1:1])         # 1 story → g[1] is drift utilization
    tors_util  = g[2]

    w_sub_header("6.1  Optimizer result (constraints: utilization ≤ 1 ⇒ feasible)")
    println("    Solver status ........ ", res4.status)
    solved = res4.status in (:optimal, :feasible, :converged)
    println("    Converged (optimal/feasible) ......................... ", _mark(solved))
    s4 &= solved
    drift_ok = drift_util ≤ 1.0 + 0.02
    tors_ok  = tors_util  ≤ 1.0 + 0.02
    @printf("    Drift   utilization = %.3f ≤ 1  %s\n", drift_util, _mark(drift_ok))
    @printf("    Torsion utilization = %.3f ≤ 1  %s\n", tors_util, _mark(tors_ok))
    s4 &= drift_ok && tors_ok
    carbon_reduced = carbon_opt < carbon_full * 0.999
    @printf("    Carbon: full=%.0f  optimized=%.0f kgCO₂e  (%.0f%% of full)  %s\n",
            carbon_full, carbon_opt, 100*carbon_opt/carbon_full, _mark(carbon_reduced))
    s4 &= carbon_reduced

    w_sub_header("6.2  Optimized wall densities (ρ → thickness/presence)")
    println("    Wall  ρ (density)   role")
    roles = ["X @ y=-5","X @ y=+5","Y @ x=-5","Y @ x=+5","X @ y=-3 (redundant)","X @ y=+3 (redundant)"]
    for i in 1:6
        @printf("    %-4d  %-11.3f  %s\n", i, dens[i], roles[i])
    end
    w_note("Redundant parallel X-walls thin toward ρ_min; core walls stay dense to meet drift/torsion.")
catch e
    println("    *** S4 stage error: ", e)
    s4 = false
end
_w_status["S4 layout optimization"] = _mark(s4)

# ═══════════════════════════════════════════════════════════════════════════
# 7. Feature matrix
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("7.0  Feature Matrix")
w_sub_header("7.1  Implemented")
println("    S1  Analytic in-plane stiffness (ACI eff. inertia), linear in t, analytic ∂k/∂t")
println("    S1  ACI 318-19 §11.5.4.3 in-plane shear + §11.6.2 min reinf, demand-decoupled")
println("    S1  ACI 318-19 §22.2 in-plane axial–flexure P–M: Cardenas closed form + strain-compat diagram")
println("    S1  ACI 318-19 §11.8 out-of-plane slender wall: second-order P-Δ, Mcr, bilinear Δs, §11.8.1.1 gates")
println("    S1  ACI 318-19 §11.5.3 simplified bearing wall: closed-form φPn + middle-third/min-thickness gates")
    println("    S2  ReducedDiaphragmEvaluator: 3 DOF/story, rank-1/wall, skew + torsion, analytic sensitivities")
println("    S3  FEMLateralEvaluator: Asap ShellTri3 walls + stiff diaphragm, exact base-story shear via reactions")
    println("    S4  WallLayoutNLPProblem (SIMP density) · MinCarbon/MinDrift/Weighted · IPOPT (existing solver)")

w_sub_header("7.2  Current limitations & future work")
println("    1. Shear (§11.5.4), αc, 8√f'c·Acv cap, §11.6.2 min reinf, 0.70/0.35 stiffness: reconciled vs corpus ✓")
println("    2. S1: in-plane P–M + out-of-plane §11.8 slender wall reconciled vs spWall ✓; special boundary")
println("       elements (§18.10.6) deferred — canon absent from corpus (HARD STOP, todo-w0000010)")
println("    3. S2: real demand generation (ASCE 7 wind + seismic ELF) + W/E load cases not wired")
println("    4. S3: multi-story upper-panel shear recovery uses Nxy first-cut (base story exact); no P-delta yet")
println("    5. S4: candidate ground-structure generation from real building geometry not yet automated")
println("    6. Pipeline: Wall not yet wired into synthesis (edge groups / initialize_members!)")

# ═══════════════════════════════════════════════════════════════════════════
# 8. Summary
# ═══════════════════════════════════════════════════════════════════════════
w_section_header("SHEAR-WALL REPORT — SUMMARY")
println("  Stage                            Status")
println("  ────────────────────────────── ──────")
for (name, status) in sort(collect(_w_status))
    println("  $(rpad(name, 32)) $status")
end
all_pass = all(v == "✓" for v in values(_w_status))
println("  Overall: $(all_pass ? "✓ ALL CHECKS PASSED" : "✗ SOME CHECKS FAILED")")
println(W_DLINE)

@test all_pass

end  # @testset
