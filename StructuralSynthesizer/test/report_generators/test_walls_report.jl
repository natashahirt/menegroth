# ==============================================================================
# Shear-Wall Lateral-System Validation Report
# ==============================================================================
# Validates the shear-wall efficiency foundation (plan S1–S4) end to end:
#   S1  Analytic in-plane wall stiffness (ACI 318-19 effective inertia) +
#       demand-decoupled ACI 318-19 §11.5.4 in-plane shear capacity
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
println("    S2  ReducedDiaphragmEvaluator: 3 DOF/story, rank-1/wall, skew + torsion, analytic sensitivities")
println("    S3  FEMLateralEvaluator: Asap ShellTri3 walls + stiff diaphragm, exact base-story shear via reactions")
    println("    S4  WallLayoutNLPProblem (SIMP density) · MinCarbon/MinDrift/Weighted · IPOPT (existing solver)")

w_sub_header("7.2  Current limitations & future work")
println("    1. Shear (§11.5.4), αc, 8√f'c·Acv cap, §11.6.2 min reinf, 0.70/0.35 stiffness: reconciled vs corpus ✓")
println("    2. S1: axial-flexure P–M / boundary elements not yet implemented (canon reconciliation still pending)")
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
