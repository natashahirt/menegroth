---
id: plan-2a1aa684
type: plan
project: menegroth
parent_id: deci-bad8d293
title: 'F2 follow-up: resolve the three residual enclosure-guard P2s (endpoint check
  + 2 doc fixes)'
node_label: 'F2 follow-up: resolve the three residual enclosure'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@7847655, StructuralSizer/src/walls/layout_problem.jl@7847655
session_id: sess-fdd3423a
created_at: '2026-10-22T14:30:49.014407+00:00'
updated_at: '2026-10-22T14:30:49.014407+00:00'
---
Addresses the three P2 findings the critic left open after the F2 P0 fix (note-2db2d960):

P2-2 (real logic tightening) ENDPOINT-AWARE enclosure check: the gate checks wall CENTROIDS only (pre-existing crit8 residual), so a long wall body can overhang the plate while its centroid sits inside. WallLine carries no length, so thread an OPTIONAL id->half-length map `wall_half_lengths::Union{Nothing,AbstractDict{Int,Float64}}=nothing` from the optimizer (c.lw/2) through the same 5 functions as active_ids (evaluate_lateral, direction_complete_interstory_drift, eigenstructure_stability, _evaluate_lateral_or_singular, constraint_fns/objective_fn/solve_wall_layout). When supplied, require BOTH endpoints (x,y)+/-(lw/2)(cos,sin) inside the plate (convex rectangle => both endpoints in => whole body in; strictly MORE conservative, never over-rejects a genuinely-inside wall). Default nothing = today's centroid-only (one-shot/FEM/test paths unchanged).

P2-1 (doc) document in _active_candidate_ids that masking on the DIMENSIONLESS rho^penal fraction assumes non-pathological per-candidate k_max, and the absolute-stiffness/occupancy question is delegated to the FEM survivor. Explicitly do NOT adopt the critic's k_i < 1e-6*Sigma_k suggestion -- that is the relative-stiffness trap (one stiff inside wall inflates Sigma_k and masks a real outside wall -> fail-open).

P2-3 (doc) correct the empty-after-mask comment in _plate_encloses_walls: the scale-invariant rcond singular guard alone would NOT catch a uniformly-softened-but-well-conditioned story; the real backstop for a LOADED all-masked story is the load-dependent eigenstructure translational floor util_trans.

Coordinator cycle: engineer (all 3) + reviewer + critic (attack: does endpoint-checking over-reject legitimate perimeter/edge-aligned walls? new hole? consistency of half_lengths threading?) + tester. Files: lateral_evaluator.jl, layout_problem.jl, test_walls.jl.
