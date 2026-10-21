---
id: note-bc80b418
type: note
project: menegroth
parent_id: deci-1f380940
title: Eigenstructure floors folded into existing drift/torsion constraint slots (n_constraints
  pinned)
node_label: Eigenstructure floors folded into existing drift/t
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@e368911
session_id: sess-73ecdb30
created_at: '2026-10-21T14:55:44.713213+00:00'
updated_at: '2026-10-21T14:55:44.713213+00:00'
---
Implemented the reduced-tier eigenstructure stability gate in lateral_evaluator.jl (`eigenstructure_stability`: closed-form `_translational_block_spectrum` lambda_min(K_tt) + Schur-complement `_torsional_stiffness_cr` K_theta_cr) and wired it into layout_problem.jl.

KEY DESIGN CONSTRAINT: test_walls.jl line 600 pins `n_constraints == 2*nstory + nWalls`, and the test file is out of write scope. So the two per-story stability floors could NOT be added as new constraint slots. They are FOLDED into existing slots via `max`: drift slot = max(direction-complete drift util, util_trans); torsion slot = max(res.torsion/limit, util_tors). Keeps the constraint vector length unchanged while enforcing stability smoothly (util_trans gives a clean lambda_min gradient; util_tors gives the 1/K_theta_cr gradient the saturating amplification ratio lacked).

Survivor re-validation in solve_wall_layout now re-checks the FULL set (drift + res.torsion + eig floors + per-wall shear), fixing round-3's drift-only hole. `failing` is priority-ordered (drift->torsion->eig->shear) so the near-dead-Y test's `failing.direction == :Y` contract (util_trans and +Y drift tie exactly) is preserved.

Floors: k_req_trans = F_s/(h*DL); k_req_tors = F_s*e_acc*r_ref/(h*DL), with r_ref = hypot(hx,hy) and e_acc = accidental_ecc*max(Lx,Ly) (both ENGINEERING JUDGMENT, reuse evaluate_lateral's accidental_ecc, no invented ASCE magnitude). F_s~0 handled by load-independent mechanism guards (lambda_min_tt<=rcond*lambda_max_tt, and K_theta_cr<=rcond*lambda_max*L_ref^2 throw) + the demoted rcond backstop. All 252 wall tests pass; crit3 solve returns feasible=false, well-braced passes at D=5 and D=500.

Residual for critic: floors applied to decomposed sub-blocks (K_tt spectrum, condensed K_theta_cr), not to the smallest eigenvalue of the full non-dimensionalized 3x3 - a strongly coupled translation-twist mode at a very eccentric CR could in principle sit slightly below an exact full-3x3 target while both decomposed floors pass; Phase 10 unified-FEM survivor cross-check remains the final authority.
