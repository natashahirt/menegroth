# ==============================================================================
# crit7 — ADVERSARIAL ATTACK on the plate_center / "EXACT corner-drift" fix
# ------------------------------------------------------------------------------
# Targets: StructuralSizer/src/walls/lateral_evaluator.jl
#          StructuralSizer/src/walls/layout_problem.jl
#
# Claim under attack (verbatim from the fix): the corner-drift / torsion
#   certification is "EXACT ... with NO slack ... correct even when the CR lies
#   OUTSIDE the plate", gated on a caller-supplied `plate_center` + `plan_halfwidth`,
#   and FAILS CLOSED when geometry is absent.
#
# FINDING (P1): the "exactness" is conditional on an UNVALIDATED precondition —
#   that `plate_center ± plan_halfwidth` ENCLOSES every drift-relevant point (the
#   diaphragm edges / occupants / all walls). There is NO runtime guard anywhere
#   that the rectangle encloses the walls. The 4-corner max is exact ONLY over
#   that rectangle (convexity of |disp(p)|²). If the caller supplies a rectangle
#   that UNDER-COVERS the real diaphragm — e.g. the CORE half-extent instead of
#   the FULL floor half-extent, a plausible wiring mistake with the two FREE
#   fields `plan_halfwidth`/`plate_center` — BOTH plate-anchored twist gates
#   (`corner_drift` AND the `res.torsion` amplification ratio) silently
#   under-state, the only plate-independent gate (`util_trans`) does not see
#   twist, and the FULL solve_wall_layout verdict FLIPS to feasible=true for a
#   building whose TRUE interstory drift at the real edge EXCEEDS the limit.
#
# Everything below calls the REAL exported functions and applies solve_wall_layout's
# EXACT survivor inequality (worst_util <= 1 + SURVIVOR_DRIFT_UTIL_TOL).
#
# Run:
#   julia --project=StructuralSizer scripts/runners/crit7_plate_enclosure_attack.jl
# ==============================================================================

using StructuralSizer
using Printf, LinearAlgebra

const SS       = StructuralSizer
const WallLine = SS.WallLine
const StoryLoad = SS.StoryLoad
const RDE      = SS.ReducedDiaphragmEvaluator
const dcid     = SS.direction_complete_interstory_drift
const eig_fn   = SS.eigenstructure_stability
const TOL      = 1.0 + SS.SURVIVOR_DRIFT_UTIL_TOL

# --- solve_wall_layout's EXACT lateral feasibility decision, from REAL outputs ---
# (worst of: corner_drift/DL, util_trans, util_tors, res.torsion/TL. Per-wall
#  shear is a separate capacity gate, handled in the end-to-end check below.)
function lateral_verdict(ev, walls, loads, DL, TL)
    res = SS.evaluate_lateral(ev, walls, loads)
    dc  = dcid(ev, walls, loads)
    eig = eig_fn(ev, walls, loads, DL)
    cd  = maximum(dc.corner_drift) / DL
    ut  = maximum(eig.util_trans)
    uto = maximum(eig.util_tors)
    tr  = maximum(res.torsion) / TL
    worst = max(cd, ut, uto, tr)
    (; worst, feasible = worst <= TOL, cd, ut, uto, tr, u = res.story_disp[1, :])
end

# Drift kernel over an arbitrary occupant rectangle (same kernel the production
# corner_drift loop runs) — used to read the TRUE edge drift of a solved state.
function corner_drift_at(u, center, hx, hy, h)
    cd = 0.0; pt = (0.0, 0.0)
    for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
        px = center[1] + sx * hx; py = center[2] + sy * hy
        d = hypot(u[1] - u[3] * py, u[2] + u[3] * px)
        d > cd && (cd = d; pt = (px, py))
    end
    return (h > 0 ? cd / h : 0.0), pt
end

# ==============================================================================
# SCENARIO (torsionally-soft offset core, rectangular floor)
#   REAL diaphragm:   x∈[-20,20], y∈[-10,10]  → plate_center=(0,0), halfwidth=(20,10)
#   Lateral system:   stiff-in-X / soft-in-Y shear core clustered at x=-15.
#   Load:             +Y story shear with x-eccentricity → diaphragm twists; the
#                     far RIGHT occupant edge x=+20 drifts most.
# ==============================================================================
const H=3.0; const DL=0.02; const TL=1.5; const ACC=0.05
const XC=-15.0
const PLATE_C=(0.0,0.0);  const PLATE_HW=(20.0,10.0)   # TRUE plate
const CORE_C=(XC,0.0);    const CORE_HW=(3.0,9.0)      # UNDER-covering (core only)
const KY=0.5*3e8;         const KX=4.0*3e8             # soft-Y / stiff-X core
const YSPAN=9.0;          const EXL=10.0               # load x-eccentricity

core_walls() = [
    WallLine(1, XC-3.0, -YSPAN, pi/2, KY, 1), WallLine(2, XC+3.0, -YSPAN, pi/2, KY, 1),
    WallLine(3, XC-3.0,  YSPAN, pi/2, KY, 1), WallLine(4, XC+3.0,  YSPAN, pi/2, KY, 1),
    WallLine(5, XC,     -YSPAN, 0.0,  KX, 1), WallLine(6, XC,      YSPAN, 0.0,  KX, 1)]
const walls = core_walls()

const EV_H = RDE(story_heights=[H], plan_halfwidth=PLATE_HW, plate_center=PLATE_C, accidental_ecc=ACC)
const EV_U = RDE(story_heights=[H], plan_halfwidth=CORE_HW,  plate_center=CORE_C,  accidental_ecc=ACC)

# Scale +Y load so the HONEST metric lands clearly over the limit (~1.25·DL):
# a genuinely NON-compliant building that MUST be rejected.
let Fy0=1.0e6
    b = lateral_verdict(EV_H, walls, [StoryLoad(1,0.0,Fy0,EXL,0.0)], DL, TL)
    global FY = Fy0 * (1.25 / b.cd)
end
const loads = [StoryLoad(1, 0.0, FY, EXL, 0.0)]

println("="^82)
println("crit7  P1 — plate UNDER-COVERAGE flips the FULL solve_wall_layout verdict")
println("            to feasible=true for an over-limit building (no enclosure guard)")
println("="^82)
@printf("Same walls, same +Y load Fy=%.4g N @ ex=%.0f.  Only the (unvalidated) plate\n", FY, EXL)
@printf("metadata differs between the two evaluators.\n\n")

vH = lateral_verdict(EV_H, walls, loads, DL, TL)
vU = lateral_verdict(EV_U, walls, loads, DL, TL)
trueU, ptU = corner_drift_at(vU.u, PLATE_C, PLATE_HW..., H)

@printf("HONEST plate  center=%s  halfwidth=%s   (encloses the real floor)\n", PLATE_C, PLATE_HW)
@printf("   corner_drift/DL=%.3f  res.torsion/TL=%.3f  util_trans=%.3f  util_tors=%.3f\n",
        vH.cd, vH.tr, vH.ut, vH.uto)
@printf("   worst_util=%.3f  →  VERDICT: %s\n\n",
        vH.worst, vH.feasible ? "feasible=TRUE" : "feasible=FALSE (correctly REJECTED)")

@printf("UNDER  plate  center=%s  halfwidth=%s   (core-only; under-covers x=±20)\n", CORE_C, CORE_HW)
@printf("   corner_drift/DL=%.3f  res.torsion/TL=%.3f  util_trans=%.3f  util_tors=%.3f\n",
        vU.cd, vU.tr, vU.ut, vU.uto)
@printf("   worst_util=%.3f  →  VERDICT: %s\n", vU.worst, vU.feasible ? "feasible=TRUE" : "feasible=FALSE")
@printf("   TRUE interstory drift of THIS certified state at real edge %s / DL = %.3f\n",
        ptU, trueU/DL)

println()
if vU.feasible && trueU/DL > 1.0 && !vH.feasible
    @printf(">>> SAFETY BREACH: identical walls+load; under-covering the plate certifies\n")
    @printf("    feasible=TRUE a building whose TRUE edge drift is %.2f·DL (%.0f%% over the\n",
            trueU/DL, (trueU/DL-1)*100)
    @printf("    ASCE 7-22 §12.12.1 limit). The plate-independent util_trans=%.3f never sees\n", vU.ut)
    @printf("    the twist; both plate-anchored gates (corner_drift, res.torsion) under-state.\n")
else
    println(">>> verdict did not flip at these magnitudes (see numbers).")
end

# ------------------------------------------------------------------------------
# END-TO-END via the REAL solve_wall_layout wrapper (densities pinned at ρ=1 so
# the optimizer returns exactly this layout; stiffness matched per candidate).
# ------------------------------------------------------------------------------
println("\n--- end-to-end: real solve_wall_layout(EV_U) on the identical layout ---")
# k is linear in thickness t, so t_max = k_target / k(t=1) hits the target stiffness.
k_at_unit_t(lw) = SS.wall_stiffness_from_thickness_si(1.0, lw, 25e9, 0.2, H; cracked=true, boundary=:cantilever)
function cand_for(w)
    # Short, thick piers maximize in-plane shear capacity (∝ t·lw) at the target
    # stiffness, so the SEPARATE shear-capacity gate is ample and the LATERAL
    # (drift/torsion) gates govern — isolating the attack from shear noise.
    lw = 1.0
    tmax = w.k / k_at_unit_t(lw)        # ρ=1 ⇒ k_max = tmax·k(t=1) = w.k
    SS.WallCandidate(w.id, w.x, w.y, w.θ, lw, H, 1, 25e9, 0.2, 80e6, 550e6, 2400.0, 0.1, tmax, 0.025)
end
try
    cands = [cand_for(w) for w in walls]
    probU = SS.WallLayoutNLPProblem(cands, EV_U, loads; objective=SS.MinCarbon(),
                                    drift_limit=DL, torsion_limit=TL, ρ_min=1.0, penal=1.0)
    rU = SS.solve_wall_layout(probU; solver=:ipopt, maxiter=50)
    @printf("   solve_wall_layout(EV_U) → feasible=%s  status=%s  worst_util=%.3f  (mode=%s)\n",
            rU.feasible, get(rU,:status,:ok), rU.revalidation.worst_util, rU.revalidation.failing.mode)
    # Read the TRUE edge drift of the layout the wrapper actually certified.
    wopt = SS._walls_from_density(probU, rU.minimizer)
    uu = SS.evaluate_lateral(EV_U, wopt, loads).story_disp[1,:]
    te,_ = corner_drift_at(uu, PLATE_C, PLATE_HW..., H)
    @printf("   TRUE edge drift of wrapper-certified layout / DL = %.3f\n", te/DL)
    if rU.feasible && te/DL > 1.0
        println("   >>> confirmed end-to-end: real wrapper returns feasible=TRUE on an over-limit layout.")
    end
catch e
    @printf("   (optimizer backend issue: %s) — real-function verdict above still stands.\n", sprint(showerror,e))
end

# ==============================================================================
# (E) origin invariance under JOINT translation (walls+loads+plate_center) — probe
# ==============================================================================
println("\n", "="^82)
println("(E)  origin invariance under joint translation (sanity probe)")
println("="^82)
off=(137.0,-89.0)
wT=[WallLine(w.id,w.x+off[1],w.y+off[2],w.θ,w.k,w.story) for w in walls]
lT=[StoryLoad(l.story,l.Fx,l.Fy,l.ex+off[1],l.ey+off[2]) for l in loads]
EV_HT=RDE(story_heights=[H],plan_halfwidth=PLATE_HW,plate_center=(PLATE_C.+off),accidental_ecc=ACC)
cd0=dcid(EV_H,walls,loads).corner_drift; cdT=dcid(EV_HT,wT,lT).corner_drift
@printf("   corner_drift invariant under joint translation? %s  (max|Δ|=%.2e)\n",
        isapprox(cd0,cdT;rtol=1e-9,atol=1e-12), maximum(abs.(cd0.-cdT)))

# ==============================================================================
# (F) over-rejection reach: no plate_center ⇒ fail-closed for a perfect symmetric core
# ==============================================================================
println("\n", "="^82)
println("(F)  P2 — fail-closed reach: a symmetric well-braced layout, NO plate_center")
println("="^82)
sym=[WallLine(1,0.0,-5.0,0.0,1e9,1),WallLine(2,0.0,5.0,0.0,1e9,1),
     WallLine(3,-5.0,0.0,pi/2,1e9,1),WallLine(4,5.0,0.0,pi/2,1e9,1)]
ev_noc=RDE(story_heights=[H],plan_halfwidth=(5.0,5.0),accidental_ecc=ACC)  # plate_center=nothing (DEFAULT)
vN=lateral_verdict(ev_noc,sym,[StoryLoad(1,5e4,5e4,0.0,0.0)],DL,TL)
@printf("   drift_slot(cd)=%.3g  res.torsion/TL=%.3g  util_tors=%.3g  (Inf ⇒ fail-closed)\n",
        vN.cd, vN.tr, vN.uto)
@printf("   Every caller that omits plate_center (the DEFAULT, incl. the repo's own\n")
@printf("   wall report/tests that construct RDE without it) now refuses outright.\n")

println("\nDONE")
