---
id: deci-1a699cbf
type: decision
project: menegroth
parent_id: deci-8de1fa37
title: Conservative fail-safe corner-drift lever bound (reduced tier, no plate center)
node_label: fail-safe lever bound
tags: walls,phase1,stability,drift,torsion,eccentric-cr,fail-safe,conservative,safety,decision
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-05340f1b
created_at: '2026-10-21T23:17:12.916842+00:00'
updated_at: '2026-10-22T00:08:47.453461+00:00'
---
crit5 proved a P0 (reproducer scripts/runners/crit5_eccentric_core_corner_drift.jl): the max-corner drift anchors the 4 corners to the WALL CENTROID, not the true plate center. ReducedDiaphragmEvaluator (lateral_evaluator.jl:269-273) stores plan_halfwidth (plate SIZE) but NO plate center and NO center of mass — so for an eccentric service core (core clustered at x=-15 on a 40x20 plate, pc=CR=(-15,0), +Y load at CoM) the checked corner box shifts off the plate and the true far corner (20,-10) at 1.51xDL is never evaluated; constraint_fns/solve_wall_layout return feasible=TRUE. Root cause is a DATA-MODEL gap (Phase 3 territory): the reduced tier cannot locate the true occupant corners or the natural CoM->CR eccentricity.

USER CHOSE conservative_failsafe (in-scope, fail-SAFE; reduced tier is a fast filter, Phase 10 unified-FEM with true geometry is the authority). DESIGN (lateral_evaluator.jl + layout_problem.jl):
1. RIGOROUS LEVER BOUND from plan_halfwidth ALONE: r_bound = hypot(2*hx, 2*hy). Justification (frame-independent): the plate spans 2hx x 2hy; the CR lies within the convex hull of the walls, which lies within the plate; any two points in a 2hx x 2hy region are within hypot(2hx,2hy) of each other; therefore max|corner - CR| <= hypot(2hx,2hy) regardless of coordinate frame or where the plate sits. This NEVER under-states the true lever.
2. CONSERVATIVE CORNER DRIFT (replaces wall-centroid corner sampling): per story/direction, conservative_drift = (|CR_translation| + |phi|*r_bound)/h (triangle-inequality upper bound on |CR_translation + phi*zhat x (corner-CR)| over any corner at distance <= r_bound). Bound <= DL, swept over the direction-complete cases. Fail-safe: cannot under-state.
3. r_ref in the eigenstructure TORSIONAL floor := r_bound (conservative; requires more torsional stiffness).
4. RESTORE the torsion ratio res.torsion (delta_max/delta_avg, uncapped) as a feasibility GATE (not reporting-only) — crit5-P1: demoting it removed the one check catching the eccentric case (ratio 14.98 >> 1.5). Addresses the ASCE Type-1b irregularity concern; delta_max via r_bound so the ratio is conservative too.
5. Survivor re-validation re-checks conservative corner drift + eigenstructure floors (r_bound) + torsion ratio + per-wall shear; feasible=false on any violation.
6. DOCUMENT: reduced tier is a CONSERVATIVE fail-safe FILTER; plate center + CoM absent from the reduced data model (Phase 3); r_bound marked ENGINEERING JUDGMENT; Phase 10 FEM survivor check (true geometry) is the AUTHORITY and will accept eccentric layouts the conservative filter over-rejects. Verify: crit5 eccentric-core probe now INFEASIBLE (fail-safe); a well-braced symmetric/compact core still FEASIBLE (not over-rejected into universal infeasibility — for a centered core phi from accidental ecc is small so the 2x-inflated lever adds little to |CR_translation|); all prior probes (near-dead-Y, crit3 torsional, diagonal, crit4 eccentric) still rejected; 334 tests still pass. A fail-SAFE conservative bound cannot be attacked into RETURNING a bad layout — only into over-rejection (acceptable; FEM confirms). This should be the final Phase 1 stability round.
