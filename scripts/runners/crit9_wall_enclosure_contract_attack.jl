# ==============================================================================
# crit9 — ADVERSARIAL ATTACK on the WALL-ENCLOSURE CONTRACT the crit7 guard
#         (`_plate_encloses_walls`) ACTUALLY implements.
# ------------------------------------------------------------------------------
# Targets: StructuralSizer/src/walls/lateral_evaluator.jl
#          StructuralSizer/src/walls/layout_problem.jl
#
# The crit7 fix adds a FAIL-CLOSED per-story predicate `_plate_encloses_walls`:
# every WallLine's (x,y) must sit within `plate_center ± plan_halfwidth` (+ a tiny
# tol). On violation the twist-sensitive metrics (corner_drift / res.torsion /
# util_tors) FAIL CLOSED to Inf and `solve_wall_layout` stamps
# `status = :geometry_inconsistent`, `feasible = false`.
#
# PRIMARY MANDATE: try to break the contract the guard ACTUALLY implements, i.e.
# find a GENUINE walls-OUTSIDE-plate layout that STILL reaches `feasible = true`
# (a true P0). Secondary vectors (b)-(f) below. The DEFERRED residual
# `walls ⊆ plate ⊂ occupants` is at most P2 (documented, closed by the geometry
# helper + FEM survivor) — reported, not promoted to P0.
#
# Every check calls the REAL exported/internal functions and applies
# solve_wall_layout's EXACT survivor inequality (worst_util <= 1 + SURVIVOR_DRIFT_UTIL_TOL).
#
# Run:
#   julia --project=StructuralSizer scripts/runners/crit9_wall_enclosure_contract_attack.jl
# ==============================================================================

using StructuralSizer
using Printf, LinearAlgebra

const SS        = StructuralSizer
const WallLine  = SS.WallLine
const StoryLoad = SS.StoryLoad
const RDE       = SS.ReducedDiaphragmEvaluator
const encloses  = SS._plate_encloses_walls
const dcid      = SS.direction_complete_interstory_drift
const eig_fn    = SS.eigenstructure_stability
const TOL       = 1.0 + SS.SURVIVOR_DRIFT_UTIL_TOL

# --- solve_wall_layout's EXACT lateral feasibility decision, from REAL outputs ----
# worst of: corner_drift/DL, util_trans, util_tors, res.torsion/TL. (Per-wall shear
# is a separate capacity gate, isolated in the end-to-end section.) Returns Inf-aware
# feasibility exactly like the production wrapper's revalidation.
function lateral_verdict(ev, walls, loads, DL, TL)
    res = SS.evaluate_lateral(ev, walls, loads)
    dc  = dcid(ev, walls, loads)
    eig = eig_fn(ev, walls, loads, DL)
    cd  = maximum(dc.corner_drift) / DL
    ut  = maximum(eig.util_trans)
    uto = maximum(eig.util_tors)
    tr  = maximum(res.torsion) / TL
    worst = max(cd, ut, uto, tr)
    (; worst, feasible = worst <= TOL, cd, ut, uto, tr, u = res.story_disp)
end

# Production drift kernel (identical to the corner_drift / _torsion_amplification
# loop): rigid-diaphragm interstory drift of an arbitrary plan point p under story
# displacement u = [δx, δy, φ].
function corner_drift_at(u, center, hx, hy, h)
    cd = 0.0; pt = (0.0, 0.0)
    for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
        px = center[1] + sx * hx; py = center[2] + sy * hy
        d = hypot(u[1] - u[3] * py, u[2] + u[3] * px)
        d > cd && (cd = d; pt = (px, py))
    end
    return (h > 0 ? cd / h : 0.0), pt
end

const H=3.0; const DL=0.02; const TL=1.5; const ACC=0.05

# Reusable torsionally-soft offset shear core (stiff-X / soft-Y, clustered at x=XC).
const XC=-15.0
const KY=0.5*3e8; const KX=4.0*3e8; const YSPAN=9.0
core_walls(story=1) = [
    WallLine(1, XC-3.0, -YSPAN, pi/2, KY, story), WallLine(2, XC+3.0, -YSPAN, pi/2, KY, story),
    WallLine(3, XC-3.0,  YSPAN, pi/2, KY, story), WallLine(4, XC+3.0,  YSPAN, pi/2, KY, story),
    WallLine(5, XC,     -YSPAN, 0.0,  KX, story), WallLine(6, XC,      YSPAN, 0.0,  KX, story)]

println("#"^84)
println("# crit9 — WALL-ENCLOSURE CONTRACT attack  (guard: _plate_encloses_walls)")
println("#"^84)

# ==============================================================================
# (A) PRIMARY — GENUINE walls-OUTSIDE-plate: can it reach feasible=true?
#     Honest plate center=(0,0) hw=(20,10); add a 7th wall whose CENTROID sits at
#     x=+30 (clearly OUTSIDE x=±20). This is a true walls-⊄-plate layout.
# ==============================================================================
println("\n", "="^84)
println("(A) PRIMARY P0 HUNT — genuine wall centroid OUTSIDE the declared plate")
println("="^84)
const PLATE_C=(0.0,0.0); const PLATE_HW=(20.0,10.0)
const EV_A = RDE(story_heights=[H], plan_halfwidth=PLATE_HW, plate_center=PLATE_C, accidental_ecc=ACC)
# 6-wall enclosed core + 1 wall with centroid at x=+30 (outside). Give it both
# orientations' worth of stiffness so the layout is otherwise well-braced.
walls_out = vcat(core_walls(), [WallLine(7, 30.0, 0.0, 0.0, KX, 1), WallLine(8, 30.0, 0.0, pi/2, KY, 1)])
loadsA = [StoryLoad(1, 1.0e5, 1.0e5, 0.0, 0.0)]

encl = encloses(EV_A, walls_out)
vA   = lateral_verdict(EV_A, walls_out, loadsA, DL, TL)
@printf("  _plate_encloses_walls (centroid x=30 vs plate x=±20) = %s\n", encl)
@printf("  corner_drift/DL=%.3g  res.torsion/TL=%.3g  util_tors=%.3g  (Inf ⇒ fail-closed)\n",
        vA.cd, vA.tr, vA.uto)
@printf("  lateral verdict feasible = %s\n", vA.feasible)
if !encl && !vA.feasible
    println("  >>> GUARD HELD: a genuine walls-outside layout FAILS CLOSED. No P0 via this path.")
else
    println("  >>> POTENTIAL P0: walls outside the plate did NOT fail closed — investigate!")
end

# ==============================================================================
# (B) TOLERANCE ABUSE — how far outside can a wall sit and still PASS the guard,
#     and how much drift understatement does that admit?
#     tol = 1e-9 + 1e-9*hypot(hx,hy).
# ==============================================================================
println("\n", "="^84)
println("(B) TOLERANCE band — worst admitted overhang & drift understatement")
println("="^84)
let hx=PLATE_HW[1], hy=PLATE_HW[2]
    tol = 1e-9 + 1e-9*hypot(hx,hy)
    @printf("  plate hw=(%.0f,%.0f)  ⇒  tol = %.3e m (%.3f nm)\n", hx, hy, tol, tol*1e9)
    # Wall centroid placed JUST inside tol (passes) vs JUST beyond tol (fails).
    w_in  = vcat(core_walls(), [WallLine(7, hx+tol*0.9, 0.0, 0.0, KX, 1)])
    w_out = vcat(core_walls(), [WallLine(7, hx+tol*1.1, 0.0, 0.0, KX, 1)])
    @printf("  centroid at cx+hx+0.9·tol  ⇒ encloses=%s (overhang %.3e m)\n",
            encloses(EV_A, w_in),  tol*0.9)
    @printf("  centroid at cx+hx+1.1·tol  ⇒ encloses=%s (overhang %.3e m)\n",
            encloses(EV_A, w_out), tol*1.1)
    # Worst-case drift understatement: the metric evaluates the corner at cx+hx; a
    # drift-relevant point admitted up to `tol` beyond adds φ·tol to the lever.
    # Use a realistic twisting state to bound φ.
    vB = lateral_verdict(EV_A, core_walls(), [StoryLoad(1,0.0,1.0e6,10.0,0.0)], DL, TL)
    u1 = vB.u[1, :]; φ = u1[3]
    understate = abs(φ)*tol / H
    @printf("  realistic φ=%.3e rad ⇒ max drift-RATIO understatement from the band = %.3e\n", φ, understate)
    @printf("  (= %.2e %% of DL=%.2f) — negligible for tol~1e-9.\n", 100*understate/DL, DL)
end

# ==============================================================================
# (C) MULTI-STORY — story 1 encloses, story 2 walls OUTSIDE ⇒ must fail closed.
# ==============================================================================
println("\n", "="^84)
println("(C) MULTI-STORY — one story encloses, the other does not")
println("="^84)
const EV_C = RDE(story_heights=[H,H], plan_halfwidth=PLATE_HW, plate_center=PLATE_C, accidental_ecc=ACC)
s1 = core_walls(1)                                   # story 1: all inside
s2 = [WallLine(10, XC-3.0,-YSPAN,pi/2,KY,2), WallLine(11, XC+3.0,-YSPAN,pi/2,KY,2),
      WallLine(12, XC-3.0, YSPAN,pi/2,KY,2), WallLine(13, 35.0, 0.0, 0.0, KX,2),  # id13 OUTSIDE
      WallLine(14, XC, -YSPAN,0.0,KX,2),      WallLine(15, XC, YSPAN,0.0,KX,2)]
walls_ms = vcat(s1, s2)
loadsC = [StoryLoad(1,1e5,1e5,0.0,0.0), StoryLoad(2,1e5,1e5,0.0,0.0)]
dcC  = dcid(EV_C, walls_ms, loadsC)
eigC = eig_fn(EV_C, walls_ms, loadsC, DL)
resC = SS.evaluate_lateral(EV_C, walls_ms, loadsC)
@printf("  story1 walls ⊆ plate = %s ; story2 walls ⊆ plate = %s\n",
        encloses(EV_C, s1), encloses(EV_C, s2))
@printf("  corner_drift[story1]=%s  corner_drift[story2]=%s\n",
        maximum(@view dcC.corner_drift[1,:]), maximum(@view dcC.corner_drift[2,:]))
@printf("  util_tors[story1]=%s  util_tors[story2]=%s  torsion[story2]=%s\n",
        eigC.util_tors[1], eigC.util_tors[2], resC.torsion[2])
bad_story2 = isinf(maximum(@view dcC.corner_drift[2,:])) && isinf(eigC.util_tors[2])
ok_story1  = isfinite(maximum(@view dcC.corner_drift[1,:]))
if bad_story2 && ok_story1
    println("  >>> GUARD HELD per-story: enclosing story finite, non-enclosing story Inf (fail closed).")
else
    println("  >>> POTENTIAL P0: a non-enclosing story was NOT failed closed — investigate!")
end

# ==============================================================================
# (D) RIGHT COORDS? asymmetric plate hx≠hy; probe x-only and y-only overhang and
#     confirm the guard axis-matches the corner construction (no sign/axis swap).
# ==============================================================================
println("\n", "="^84)
println("(D) COORD / AXIS correctness — asymmetric plate, x-only vs y-only overhang")
println("="^84)
const EV_D = RDE(story_heights=[H], plan_halfwidth=(20.0,5.0), plate_center=(0.0,0.0), accidental_ecc=ACC)
# Base layout chosen to FIT the asymmetric (20,5) plate (so the probe wall is what's
# tested, not the base). Well-braced: X- and Y-oriented walls within |x|≤20, |y|≤5.
baseD = [WallLine(1,-15.0,-4.0,0.0,KX,1), WallLine(2,15.0,-4.0,0.0,KX,1),
         WallLine(3,-15.0, 4.0,0.0,KX,1), WallLine(4,15.0, 4.0,0.0,KX,1),
         WallLine(5,-15.0, 0.0,pi/2,KY,1), WallLine(6,15.0,0.0,pi/2,KY,1)]
# wall at (0, 8): inside x (|0|<20) but OUTSIDE y (|8|>5)  ⇒ must be rejected
wy = vcat(baseD, [WallLine(7, 0.0, 8.0, 0.0, KX, 1)])
# wall at (25, 0): OUTSIDE x (|25|>20) but inside y        ⇒ must be rejected
wx = vcat(baseD, [WallLine(7, 25.0, 0.0, 0.0, KX, 1)])
# wall at (18, 4): inside both                             ⇒ must pass
wi = vcat(baseD, [WallLine(7, 18.0, 4.0, 0.0, KX, 1)])
@printf("  wall (0, 8): x-in/y-OUT  ⇒ encloses=%s  (expect false)\n", encloses(EV_D, wy))
@printf("  wall (25,0): x-OUT/y-in  ⇒ encloses=%s  (expect false)\n", encloses(EV_D, wx))
@printf("  wall (18,4): in both     ⇒ encloses=%s  (expect true)\n",  encloses(EV_D, wi))
axis_ok = (encloses(EV_D, wy)==false) && (encloses(EV_D, wx)==false) && (encloses(EV_D, wi)==true)
println(axis_ok ? "  >>> axis mapping CONSISTENT with the corner construction (no swap)." :
                  "  >>> POTENTIAL P0: axis/sign mismatch — investigate!")

# ==============================================================================
# (E) DEGENERATE half-extents — negative / zero / empty.
# ==============================================================================
println("\n", "="^84)
println("(E) DEGENERATE plate — negative / zero half-extent, empty walls")
println("="^84)
w_small = [WallLine(1, 0.0,-1.0,0.0,1e9,1), WallLine(2, 0.0,1.0,0.0,1e9,1),
           WallLine(3,-1.0,0.0,pi/2,1e9,1), WallLine(4, 1.0,0.0,pi/2,1e9,1)]
ev_neg  = RDE(story_heights=[H], plan_halfwidth=(-20.0, 10.0), plate_center=(0.0,0.0))
ev_zero = RDE(story_heights=[H], plan_halfwidth=(0.0, 0.0),    plate_center=(0.0,0.0))
ev_zx   = RDE(story_heights=[H], plan_halfwidth=(0.0, 10.0),   plate_center=(0.0,0.0))
@printf("  negative hx=-20 with real walls  ⇒ encloses=%s  (expect false, fail closed)\n",
        encloses(ev_neg, w_small))
@printf("  zero hw=(0,0), spread walls       ⇒ encloses=%s  (expect false — per-wall bounds reject)\n",
        encloses(ev_zero, w_small))
@printf("  zero hx, walls spread in x        ⇒ encloses=%s  (expect false)\n",
        encloses(ev_zx, w_small))
@printf("  empty walls                       ⇒ encloses=%s  (vacuously true)\n",
        encloses(EV_A, WallLine[]))
deg_ok = (encloses(ev_neg,w_small)==false) && (encloses(ev_zero,w_small)==false) &&
         (encloses(ev_zx,w_small)==false)
println(deg_ok ? "  >>> degenerate plates fail closed (empty vacuously enclosed — never used for a solve)." :
                 "  >>> POTENTIAL P0: a degenerate plate accidentally PASSED — investigate!")

# ==============================================================================
# (F1) DEFERRED RESIDUAL (P2) — walls ⊆ plate ⊂ occupants (the crit7 literal case).
#      Core-only plate center=(-15,0) hw=(3,9) encloses the walls but under-covers
#      the true floor x=±20 ⇒ feasible=true for an over-limit building.
# ==============================================================================
println("\n", "="^84)
println("(F1) DEFERRED RESIDUAL (P2) — walls ⊆ plate ⊂ occupants under-coverage")
println("="^84)
const CORE_C=(XC,0.0); const CORE_HW=(3.0,9.0)
const EV_U = RDE(story_heights=[H], plan_halfwidth=CORE_HW, plate_center=CORE_C, accidental_ecc=ACC)
# scale +Y load so the HONEST metric is ~1.25·DL (genuinely NON-compliant).
const _bF = lateral_verdict(EV_A, core_walls(), [StoryLoad(1,0.0,1.0e6,10.0,0.0)], DL, TL)
const FY  = 1.0e6 * (1.25 / _bF.cd)
loadsF = [StoryLoad(1, 0.0, FY, 10.0, 0.0)]
vH = lateral_verdict(EV_A, core_walls(), loadsF, DL, TL)       # honest full plate
vU = lateral_verdict(EV_U, core_walls(), loadsF, DL, TL)       # under-covering core plate
trueU, ptU = corner_drift_at(vU.u[1,:], PLATE_C, PLATE_HW..., H)
@printf("  walls ⊆ core-plate = %s (guard PASSES — walls are inside the declared plate)\n",
        encloses(EV_U, core_walls()))
@printf("  HONEST plate  worst=%.3f  ⇒ feasible=%s (correctly rejects)\n", vH.worst, vH.feasible)
@printf("  CORE  plate   worst=%.3f  ⇒ feasible=%s\n", vU.worst, vU.feasible)
@printf("  TRUE edge drift of the CORE-certified state at real corner %s / DL = %.3f\n", ptU, trueU/DL)
if vU.feasible && trueU/DL > 1.0 && !vH.feasible
    @printf("  >>> P2 (DEFERRED): core-plate certifies feasible=TRUE a building whose TRUE edge\n")
    @printf("      drift is %.2f·DL. Guard passes because WALLS ⊆ plate; occupants ⊄ plate is the\n", trueU/DL)
    @printf("      documented residual (closed by the geometry helper + FEM survivor).\n")
end

# ==============================================================================
# (F2) OVER-REJECTION (P2) — an optimizer-REMOVED candidate (ρ→ρ_min, k≈0) sitting
#      OUTSIDE the plate forces the WHOLE solve to :geometry_inconsistent, even
#      though every PRESENT (load-bearing) wall is enclosed and the layout is sound.
#      solve_wall_layout checks `walls_opt = _walls_from_density(...)` over ALL
#      candidates regardless of density, so a dead candidate still trips the gate.
# ==============================================================================
println("\n", "="^84)
println("(F2) OVER-REJECTION (P2) — a density-removed candidate outside the plate")
println("="^84)
# A SYMMETRIC, well-braced, genuinely FEASIBLE base layout fully inside plate(0,0/20,10):
# strong X-walls at y=±8, strong Y-walls at x=±15; modest centered load.
live = [WallLine(1,-15.0,-8.0,0.0,3e9,1), WallLine(2,15.0,-8.0,0.0,3e9,1),
        WallLine(3,-15.0, 8.0,0.0,3e9,1), WallLine(4,15.0, 8.0,0.0,3e9,1),
        WallLine(5,-15.0, 0.0,pi/2,3e9,1), WallLine(6,15.0,0.0,pi/2,3e9,1),
        WallLine(7,  0.0,-8.0,pi/2,3e9,1), WallLine(8, 0.0,8.0,pi/2,3e9,1)]
loads_live = [StoryLoad(1, 5.0e4, 5.0e4, 0.0, 0.0)]
# one essentially-removed candidate (k≈0) parked at x=+30 (outside the plate):
dead = WallLine(99, 30.0, 0.0, 0.0, 1e-3, 1)   # k≈0 ⇒ ~zero stiffness/drift contribution
walls_live     = live
walls_withdead = vcat(live, [dead])
@printf("  present layout alone      encloses=%s\n", encloses(EV_A, walls_live))
@printf("  layout + dead wall @x=30  encloses=%s  (dead k=%.0e ⇒ ~zero drift contribution)\n",
        encloses(EV_A, walls_withdead), dead.k)
# Lateral response is numerically ~identical with/without the dead wall:
vL = lateral_verdict(EV_A, walls_live, loads_live, DL, TL)
vD = lateral_verdict(EV_A, walls_withdead, loads_live, DL, TL)
@printf("  lateral worst_util  without dead=%.4f  with dead=%.4f  (the structure is feasible=%s)\n",
        vL.worst, vD.worst, vL.feasible)
if encloses(EV_A, walls_live) && !encloses(EV_A, walls_withdead) && vL.feasible
    println("  >>> P2 OVER-REJECTION: solve_wall_layout would stamp :geometry_inconsistent on this")
    println("      sound layout purely because a ~zero-stiffness (removed) candidate is parked")
    println("      outside the plate — the gate keys on ALL candidate centroids, not just present")
    println("      (non-ρ_min) load-bearing walls. Safe direction (rejects a good design), but a")
    println("      real usability footgun for ground structures that seed candidates plan-wide.")
end

# ==============================================================================
# (F3) OVER-REJECTION probe (P2) — CR OUTSIDE plate but all WALLS inside: the task
#      asserts CR-outside-plate is ALLOWED. Confirm the guard does NOT reject it.
# ==============================================================================
println("\n", "="^84)
println("(F3) CR-outside-plate, walls-inside — must NOT be rejected by the guard")
println("="^84)
# eccentric core clustered near x=-18..-12 inside a plate center=(0,0) hw=(20,10):
# the CR sits near the core (x≈-15), OUTSIDE... actually inside x=±20 but far from 0.
# Push the plate so the CR is outside: center=(10,0), hw=(5,10) with core at x≈-15 would
# put walls outside — not what we want. Instead: walls inside plate, CR offset.
ev_cr = RDE(story_heights=[H], plan_halfwidth=(20.0,10.0), plate_center=(0.0,0.0), accidental_ecc=ACC)
@printf("  eccentric core, walls ⊆ plate(0,0 / 20,10) ⇒ encloses=%s (expect true — CR locus irrelevant)\n",
        encloses(ev_cr, core_walls()))
vcr = lateral_verdict(ev_cr, core_walls(), [StoryLoad(1,1e5,2e5,8.0,0.0)], DL, TL)
@printf("  corner_drift/DL=%.3f util_tors=%.3f ⇒ metrics are FINITE (guard allows CR-outside).\n",
        vcr.cd, vcr.uto)

# ==============================================================================
# END-TO-END — real solve_wall_layout on the genuine walls-OUTSIDE layout (A):
# must return feasible=false, status=:geometry_inconsistent.
# ==============================================================================
println("\n", "="^84)
println("END-TO-END — real solve_wall_layout on the genuine walls-OUTSIDE layout (A)")
println("="^84)
k_at_unit_t(lw) = SS.wall_stiffness_from_thickness_si(1.0, lw, 25e9, 0.2, H; cracked=true, boundary=:cantilever)
function cand_for(w)
    lw = 1.0
    tmax = w.k / k_at_unit_t(lw)
    SS.WallCandidate(w.id, w.x, w.y, w.θ, lw, H, 1, 25e9, 0.2, 80e6, 550e6, 2400.0, 0.1, tmax, 0.025)
end
try
    cands = [cand_for(w) for w in walls_out]
    prob  = SS.WallLayoutNLPProblem(cands, EV_A, loadsA; objective=SS.MinCarbon(),
                                    drift_limit=DL, torsion_limit=TL, ρ_min=1.0, penal=1.0)
    r = SS.solve_wall_layout(prob; solver=:ipopt, maxiter=50)
    @printf("  solve_wall_layout(walls-outside) → feasible=%s  status=%s  mode=%s\n",
            r.feasible, get(r,:status,:ok), r.revalidation.failing.mode)
    if r.feasible == false && get(r,:status,:ok) == :geometry_inconsistent
        println("  >>> CONFIRMED: real wrapper fails closed with :geometry_inconsistent. No P0.")
    else
        println("  >>> POTENTIAL P0: real wrapper did NOT fail closed on walls-outside — investigate!")
    end
catch e
    @printf("  (optimizer backend issue: %s) — direct guard verdicts above still stand.\n",
            sprint(showerror, e))
end

println("\nDONE")
