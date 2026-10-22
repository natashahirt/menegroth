---
id: deci-bad8d293
type: decision
project: menegroth
parent_id: plan-f32eff7f
title: Active-wall-ID mask + penalized-stiffness-fraction activity test (Guard F2
  P0 fix)
node_label: Active-wall-ID mask + penalized-stiffness-fraction
tags: guard-f2, walls, lateral, enclosure, fail-open, p0
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@7847655, StructuralSizer/src/walls/layout_problem.jl@7847655,
  StructuralSizer/test/walls/test_walls.jl@7847655
session_id: sess-fdd3423a
created_at: '2026-10-22T14:28:56.119843+00:00'
updated_at: '2026-10-22T14:28:56.119843+00:00'
---
Guard F2: stop the reduced-tier enclosure proxy from over-rejecting a sound wall layout when a density-removed candidate sits outside the plate.

DESIGN: An explicit set of ACTIVE candidate ids is threaded from the optimizer into the reduced-tier enclosure proxy `_plate_encloses_walls` (lateral_evaluator.jl). The evaluator skips any WallLine whose id is not in the set; `active_ids===nothing` means all-active, keeping the one-shot CHECK path and the FEM tier byte-for-byte unchanged. The set is computed in layout_problem.jl by `_active_candidate_ids` and threaded through evaluate_lateral / direction_complete_interstory_drift / eigenstructure_stability / _evaluate_lateral_or_singular / constraint_fns / objective_fn and the solve_wall_layout final gate + survivor re-validation.

ACTIVITY TEST (the key decision): 'removed/active' is judged on the PENALIZED stiffness fraction, PER-WALL ABSOLUTE — a candidate is ACTIVE iff (clamp(x[i], rho_min, 1.0))^penal > ACTIVE_STIFFNESS_FRACTION_FLOOR (=1e-6). This degrades to 'all active' as rho_min->1 and never to 'all removed'.

P0 LESSON (absolute vs linear threshold): the FIRST implementation used a LINEAR-density threshold `rho > rho_min*(1+1e-6)`. The critic broke this as a P0 FAIL-OPEN: rho_min is an unvalidated free constructor arg, and the repo's own crit7/8/9 attack scripts set rho_min=1.0, where every density pins at the floor -> empty active set -> _plate_encloses_walls vacuously true -> the enclosure guard silently disables itself -> a fully-dense load-bearing wall OUTSIDE the plate escapes the only runtime enclosure check -> corner-drift/torsion certification fails OPEN. The absolute rho^penal test fixes this.

WHY STIFFNESS IS NEVER INFERRED IN THE EVALUATOR: a relative (compare-to-other-walls) stiffness threshold inside the evaluator could let one very stiff inside wall mask a real outside wall. The activity test is therefore per-wall absolute, never relative — it is NOT the relative-stiffness trap.

ALSO ADDED: WallLayoutNLPProblem constructor validation (0<rho_min<=1, penal>=1, global candidate-id uniqueness); restored the inverted-plate (hx<0||hy<0) fail-closed BEFORE the mask skip.

OUTCOME: Reviewer PASS; Critic CONCERN (P0 confirmed CLOSED by running the real functions; only P2 fragile-assumption findings remain); Tester PASS 468/468 wall tests (baseline 428; +23 P0 regression assertions at rho_min in {0.5,1.0,1e-3}; corrected one stale pre-existing testset-D assertion).
