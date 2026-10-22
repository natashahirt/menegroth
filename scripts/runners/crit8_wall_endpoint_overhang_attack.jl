# ==============================================================================
# crit8 — ADVERSARIAL ATTACK on the crit7 ENCLOSURE GUARD (`_plate_encloses_walls`)
# ------------------------------------------------------------------------------
# Targets: StructuralSizer/src/walls/lateral_evaluator.jl
#          StructuralSizer/src/walls/layout_problem.jl
#
# The crit7 fix added `_plate_encloses_walls(ev, walls_s)` whose DOCSTRING claims it
# "enforces the CHECKABLE proxy WALLS ⊆ plate ... when any story's walls fall OUTSIDE
# the plate, the twist-sensitive metrics FAIL CLOSED". The known/conceded residual is
# `walls ⊆ plate ⊂ occupants` (caller declares a plate smaller than the occupant floor
# while the WALLS themselves are inside it — delegated to the FEM authority).
#
# NEW, DISTINCT HOLE (crit8): the guard does NOT enforce "WALLS ⊆ plate". It keys on
# `WallLine.x, y` — the wall CENTROID — but a `WallLine`/`WallCandidate` is a PIER with a
# finite length `lw` and orientation `θ`. A wall whose CENTROID is strictly inside the
# plate can have its physical BODY (and its end) protruding OUTSIDE the plate. The guard
# passes ("walls ⊆ plate" by its own wording is FALSE — a wall is not inside the plate),
# the exact four-corner metric is evaluated only over `plate_center ± (hx,hy)`, and the
# TRUE drift at the wall's protruding end (a real structural point) EXCEEDS the limit.
#
# This is NOT the conceded residual: the thing outside the plate is a WALL, whose extent
# is CHEAPLY computable from the fields the candidate already carries (x, y, θ, lw). The
# guard SHOULD check wall ENDPOINTS, not just the centroid. It does not.
#
# Everything below calls the REAL exported functions and applies solve_wall_layout's EXACT
# lateral survivor inequality (worst_util <= 1 + SURVIVOR_DRIFT_UTIL_TOL).
#
# Run:
#   julia --project=StructuralSizer scripts/runners/crit8_wall_endpoint_overhang_attack.jl
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
# (worst of: corner_drift/DL, util_trans, util_tors, res.torsion/TL. Per-wall shear is
#  a separate capacity gate, confirmed ample in the end-to-end check.)
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

# Production drift kernel (identical to the corner_drift / _torsion_amplification loops):
# rigid-diaphragm interstory drift of an arbitrary plan point p under story displacement u.
drift_at(u, px, py, h) = h > 0 ? hypot(u[1] - u[3]*py, u[2] + u[3]*px) / h : 0.0

# Max drift over the FOUR declared-plate corners (what the certification actually bounds).
function plate_corner_drift(u, center, hx, hy, h)
    cd = 0.0; pt = (0.0, 0.0)
    for sx in (-1.0, 1.0), sy in (-1.0, 1.0)
        px = center[1] + sx*hx; py = center[2] + sy*hy
        d = drift_at(u, px, py, h); d > cd && (cd = d; pt = (px, py))
    end
    return cd/ (h>0 ? 1.0 : 1.0), cd, pt  # cd already divided by h
end

# Max drift over every WALL ENDPOINT (p = centroid ± (lw/2)·(cosθ, sinθ)) — the TRUE
# drift-relevant structural extent the guard SILENTLY ignores by keying on centroids only.
function wall_endpoint_drift(u, walls, lw, h)
    wd = 0.0; pt = (0.0, 0.0); wid = 0
    for w in walls
        L = lw[w.id]
        for s in (-1.0, 1.0)
            px = w.x + s*(L/2)*cos(w.θ); py = w.y + s*(L/2)*sin(w.θ)
            d = drift_at(u, px, py, h); d > wd && (wd = d; pt = (px, py); wid = w.id)
        end
    end
    return wd, pt, wid
end

const H=3.0; const DL=0.02; const TL=1.5; const ACC=0.05

# ==============================================================================
# SCENARIO — a COMPACT cluster of wall CENTROIDS wrapped by an honest tight plate,
# defeated by long wall BODIES that reach far past that plate.
#   Declared plate:  center (0,0), halfwidth (HX,HY)  → wraps the wall CENTROIDS tightly
#                    so the plate-corner torsion ratio δmax/δavg stays UNDER torsion_limit
#                    (the gate that caught a high-twist layout) while plate-corner drift
#                    stays UNDER DL — i.e. the tier CERTIFIES it.
#   Lateral system:  near-symmetric X+Y core (CR ≈ origin) so twist is MODEST (small φ);
#                    a small genuine +x load eccentricity supplies just enough φ that the
#                    FAR wall ends drift over the limit without tripping the torsion ratio.
#   Protruding walls: two long horizontal (θ=0) piers, CENTROIDS (0, ±4) STRICTLY inside
#                    the plate, physical length lw=20 ⇒ ENDS at x=±10 — far beyond the
#                    plate, far from the CR, so their true drift exceeds DL.
# The attack is reachability: find the load eccentricity `ex` where the tier says feasible
# but a wall END is over DL. We SCAN `ex` and report the breach.
# ==============================================================================
const HX=5.0; const HY=5.0; const PC=(0.0,0.0)

# Build from REAL WallCandidates (pick physical thickness, DERIVE stiffness) so the
# separate per-wall shear-capacity gate is consistent with a real pier and does NOT mask
# the lateral breach. Long X piers (θ=0) at (0,±4) span x∈[-10,10] (ENDS 5 m past the
# plate); Y piers (θ=90) at (±4,0) set the +Y drift. All CENTROIDS strictly inside (±5,±5).
#   WallCandidate(id, x, y, θ, lw, height, story, E, ν, fc, fy, ρc, ecc, t_max, ρt)
const EV = RDE(story_heights=[H], plan_halfwidth=(HX,HY), plate_center=PC, accidental_ecc=ACC)
mk(id,x,y,θ,lw,t) = SS.WallCandidate(id, x, y, θ, lw, H, 1, 25e9, 0.2, 80e6, 550e6, 2400.0, 0.1, t, 0.025)
# id1 = long X pier at y=0 (θ=0): its arm about the origin is −y = 0, so it carries ~ZERO
#       in-plane shear under a +Y base shear (the shear gate cannot mask it); its BODY still
#       reaches x=±10, 5 m past the plate. id2,3 = slender Y piers that carry the base shear
#       (flexure-governed so they reach the drift limit WITHOUT a shear-capacity violation).
const CANDS = [
    mk(1, 0.0,  0.0, 0.0,  20.0, 0.30),                                      # long X pier (overhang, ~0 shear)
    mk(2, 4.0,  0.0, pi/2,  1.0, 0.50), mk(3,-4.0,  0.0, pi/2,  1.0, 0.50)]  # slender Y piers (carry Fy)
const LW = Dict(c.id => c.lw for c in CANDS)
# WallLines (ρ=1) with stiffness DERIVED from the candidate thickness — the physical pier.
const walls = [WallLine(c.id, c.x, c.y, c.θ, SS._candidate_kmax(c), c.story) for c in CANDS]
const KXv = SS._candidate_kmax(CANDS[1])   # representative long-X pier stiffness
const KYv = SS._candidate_kmax(CANDS[3])   # representative Y pier stiffness
const YS  = 5.0                            # y-spread used by the (E) line-plate probe

println("="^84)
println("crit8  — enclosure guard keys on wall CENTROID; long wall BODIES protrude past")
println("         the plate, the exact metric under-states, verdict stays feasible")
println("="^84)

# (0) GUARD: does `_plate_encloses_walls` pass for this layout?
g = encloses(EV, walls)
@printf("\n(0) Guard `_plate_encloses_walls` (WALLS ⊆ plate?) -> %s\n", g)
@printf("    all wall CENTROIDS strictly inside plate (±%.0f, ±%.0f), margin ≥ 1.0 ≫ tol\n", HX, HY)
@printf("    wall 1 (lw=%.0f, θ=0, centroid (0,0)) physical ENDS at x=±%.0f  (%.0f m OUTSIDE the\n",
        LW[1], LW[1]/2, LW[1]/2 - HX)
@printf("    plate edge x=%.0f)\n", HX)
@printf("    => guard passes, yet a WALL is NOT ⊆ plate (its body overhangs). The\n")
@printf("       docstring invariant 'WALLS ⊆ plate' is FALSE but uncaught.\n")

# Scan the load eccentricity `ex`; at each, auto-scale Fy so the DECLARED (plate-corner)
# corner_drift = 0.98·DL (a CERTIFIED layout), then read the TRUE wall-end drift.
println("\n(1) SCAN load eccentricity ex (Fy auto-scaled so declared corner_drift=0.98·DL):")
@printf("    %4s | %8s %8s %8s %8s | %10s %9s | %s\n",
        "ex", "cd/DL", "tors/TL", "u_trans", "u_tors", "wallEnd/DL", "feasible", "verdict")
function scan_breach(g)
    best = nothing
    for ex in 0.0:0.5:5.0
        l0 = [StoryLoad(1,0.0,1.0e6,ex,0.0)]
        b0 = lateral_verdict(EV, walls, l0, DL, TL)
        b0.cd <= 0 && continue
        Fy = 1.0e6 * (0.98 / b0.cd)
        ld = [StoryLoad(1,0.0,Fy,ex,0.0)]
        v  = lateral_verdict(EV, walls, ld, DL, TL)
        wd, wpt, wid = wall_endpoint_drift(v.u, walls, LW, H)
        breach = g && v.feasible && wd/DL > 1.0
        @printf("    %4.1f | %8.3f %8.3f %8.3f %8.3f | %10.3f %9s | %s\n",
                ex, v.cd, v.tr, v.ut, v.uto, wd/DL, v.feasible,
                breach ? "*** BREACH ***" : (v.feasible ? "feasible, end<DL" : "rejected"))
        if breach && (best === nothing || wd/DL > best.wd/DL)
            best = (; ex, Fy, v, wd, wpt, wid)
        end
    end
    return best
end
best = scan_breach(g)

if best !== nothing
    b = best
    println()
    @printf(">>> SAFETY BREACH (NEW, distinct from walls⊆plate⊂occupants):\n")
    @printf("    ex=%.1f, Fy=%.4g N.  u = [δx=%.3e, δy=%.3e, φ=%.3e]\n",
            b.ex, b.Fy, b.v.u[1], b.v.u[2], b.v.u[3])
    @printf("    DECLARED corner_drift/DL=%.3f  tors/TL=%.3f  u_trans=%.3f  u_tors=%.3f -> feasible=TRUE\n",
            b.v.cd, b.v.tr, b.v.ut, b.v.uto)
    @printf("    TRUE drift at WALL END %s (wall id %d)/DL = %.3f  (%.0f%% OVER the limit)\n",
            b.wpt, b.wid, b.wd/DL, (b.wd/DL-1)*100)
    @printf("    The tier certifies feasible=TRUE, but the end of shear wall %d — %.1f m outside\n",
            b.wid, b.wpt[1]-HX)
    @printf("    the declared plate — exceeds ASCE 7-22 §12.12.1. The overhang is CHEAPLY\n")
    @printf("    computable from WallCandidate.(x,y,θ,lw); the guard checks only the centroid.\n")
    global FLIP_EX = b.ex; global FLIP_FY = b.Fy
else
    println("\n>>> no breach found in the ex scan (torsion ratio or drift always gated).")
    global FLIP_EX = 2.0; global FLIP_FY = 1.0e7
end

# (2) END-TO-END via REAL solve_wall_layout at the breaching config (same physical piers).
println("\n--- end-to-end: real solve_wall_layout at the breaching config ---")
try
    loads = [StoryLoad(1, 0.0, FLIP_FY, FLIP_EX, 0.0)]
    prob  = SS.WallLayoutNLPProblem(CANDS, EV, loads; objective=SS.MinCarbon(),
                                    drift_limit=DL, torsion_limit=TL, ρ_min=1.0, penal=1.0)
    r = SS.solve_wall_layout(prob; solver=:ipopt, maxiter=50)
    @printf("    solve_wall_layout -> feasible=%s  status=%s  worst_util=%.3f  (mode=%s)\n",
            r.feasible, get(r,:status,:ok), r.revalidation.worst_util, r.revalidation.failing.mode)
    wopt = SS._walls_from_density(prob, r.minimizer)
    uu = SS.evaluate_lateral(EV, wopt, loads).story_disp[1,:]
    wde,wpte,_ = wall_endpoint_drift(uu, wopt, LW, H)
    @printf("    TRUE wall-end drift of wrapper-certified layout at %s / DL = %.3f\n", wpte, wde/DL)
    if r.feasible && wde/DL > 1.0
        println("    >>> confirmed end-to-end: real wrapper returns feasible=TRUE, wall end over limit.")
    end
catch e
    @printf("    (optimizer backend issue: %s) — metric-level verdict above still stands.\n",
            sprint(showerror,e))
end

# ==============================================================================
# (A) TOLERANCE ABUSE — is a tol-sized overhang ever enough to flip a verdict?
# ==============================================================================
println("\n", "="^84)
println("(A)  tolerance abuse: max drift under-statement a tol-sized overhang can buy")
println("="^84)
# tol = 1e-9 + 1e-9·hypot(hx,hy). Shift a wall CENTROID exactly tol beyond the +x edge.
tolv = 1e-9 + 1e-9*hypot(HX,HY)
walls_tol = vcat(walls[1:3], [WallLine(4, HX+tolv, 0.0, pi/2, KYv, 1)])  # id4 centroid a hair out
loads_tol = [StoryLoad(1, 0.0, FLIP_FY, FLIP_EX, 0.0)]
g_tol = encloses(EV, walls_tol)
vt = lateral_verdict(EV, walls_tol, loads_tol, DL, TL)
# extra drift from the tol overhang vs the plate edge, at the solved state:
d_edge = drift_at(vt.u, HX,       0.0, H)
d_over = drift_at(vt.u, HX+tolv,  0.0, H)
@printf("    tol = %.3e m.  centroid at x = hx+tol passes guard? %s\n", tolv, g_tol)
@printf("    drift(x=hx)=%.6e   drift(x=hx+tol)=%.6e   Δ(drift/DL)=%.3e\n",
        d_edge/DL, d_over/DL, (d_over-d_edge)/DL)
@printf("    => a tol-sized overhang buys ~%.1e of drift/DL — categorically NEGLIGIBLE;\n",
        (d_over-d_edge)/DL)
@printf("       cannot flip a verdict (confirms (a) is NOT the hole).\n")

# ==============================================================================
# (E) ZERO / TINY HALF-EXTENT RELAXATION — plan_halfwidth = (0, hy) passes the guard
#     for a line of wall centroids, but horizontal wall BODIES span the zeroed axis.
# ==============================================================================
println("\n", "="^84)
println("(E)  zero half-extent relaxation: (0, hy) plate passes; occupants/bodies span x")
println("="^84)
# All wall CENTROIDS on the line x=0 (so the per-wall x-bound [cx-0-tol, cx+0+tol] passes),
# mixed θ for a stable, twisting layout. Horizontal (θ=0) walls have BODIES spanning x.
wallsE = [
    WallLine(1, 0.0, -YS, pi/2, KYv, 1), WallLine(2, 0.0,  YS, pi/2, KYv, 1),   # Y piers on the line
    WallLine(3, 0.0, -YS, 0.0,  KXv, 1), WallLine(4, 0.0,  YS, 0.0,  KXv, 1),   # X piers on the line
    WallLine(5, 0.0,  0.0, 0.0,  KXv, 1)]                                       # extra X pier (twist)
const LWE = Dict(1=>4.0,2=>4.0,3=>12.0,4=>12.0,5=>12.0)   # X walls physically span x∈[-6,6]
EVE = RDE(story_heights=[H], plan_halfwidth=(0.0, HY), plate_center=(0.0,0.0), accidental_ecc=ACC)
gE = encloses(EVE, wallsE)
# load: +Y with y-eccentricity to twist about the line
let Fy0=1.0e6
    bE = lateral_verdict(EVE, wallsE, [StoryLoad(1,2.0e5,Fy0,0.0,3.0)], DL, TL)
    global FYE = Fy0 * (0.98 / max(bE.cd, 1e-9))
end
loadsE = [StoryLoad(1, 2.0e5, FYE, 0.0, 3.0)]
vE = lateral_verdict(EVE, wallsE, loadsE, DL, TL)
wdE, wptE, widE = wall_endpoint_drift(vE.u, wallsE, LWE, H)
@printf("    plan_halfwidth=(0, %.0f) passes guard (all centroids on x=0)? %s\n", HY, gE)
@printf("    DECLARED corner_drift/DL=%.3f (corners at x=0 only)  worst_util=%.3f -> %s\n",
        vE.cd, vE.worst, vE.feasible ? "feasible=TRUE" : "feasible=FALSE")
@printf("    TRUE drift at wall END %s (x-span body, id %d)/DL = %.3f\n", wptE, widE, wdE/DL)
if gE && vE.feasible && wdE/DL > 1.0
    @printf("    >>> zero-x plate certifies feasible=TRUE; a horizontal wall body at x=%.1f\n", wptE[1])
    @printf("        drifts %.2f·DL. The relaxation (zero defers to per-wall bounds) + centroid\n", wdE/DL)
    @printf("        keying lets a spread X-system hide under a declared zero x-extent.\n")
else
    @printf("    (no flip here: declared cd/DL=%.3f wall-end/DL=%.3f)\n", vE.cd, wdE/DL)
end

println("\nDONE")
