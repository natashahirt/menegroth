---
id: plan-f32eff7f
type: plan
project: menegroth
parent_id: deci-e2344cc5
title: 'F2 fix: active-wall mask for the enclosure proxy (stop over-rejecting sound
  layouts with removed candidates outside the plate)'
node_label: 'F2 fix: active-wall mask for the enclosure proxy ('
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@2a0b2c4, StructuralSizer/src/walls/layout_problem.jl@2a0b2c4
session_id: sess-d5d2bc96
created_at: '2026-10-22T13:39:18.026461+00:00'
updated_at: '2026-10-22T13:39:18.026461+00:00'
---
GOAL: close guard F2 (crit2) — the enclosure proxy _plate_encloses_walls runs over ALL candidates (incl. density-removed ones at rho_min), so a removed phantom candidate parked outside the plate over-rejects an otherwise-sound layout with :geometry_inconsistent. Over-rejection is safe but distorts the optimizer.

SAFE DESIGN (user-approved): the OPTIMIZER (which knows densities + rho_min) passes an explicit ACTIVE-WALL MASK to the enclosure check; the check skips ONLY walls the optimizer has driven to the SIMP void floor rho_min (truly removed, within numerical tol). NEVER infer 'removed' from stiffness in the evaluator — a relative-stiffness threshold is UNSAFE (one very stiff inside wall could push a genuinely real outside wall below the threshold and silently skip it, understating drift). Active = density meaningfully above rho_min; the most conservative version skips a wall ONLY if rho <= rho_min*(1+tol) (fully removed), so a real wall above the floor is always checked.

SCOPE (2 files): 
- lateral_evaluator.jl: _plate_encloses_walls + the three call sites (evaluate_lateral torsion, direction_complete_interstory_drift, eigenstructure_stability) accept an optional active mask (default nothing = all active, preserving the one-shot CHECK path and FEM tier). 
- layout_problem.jl: constraint_fns + solve_wall_layout gate compute the active mask from densities (x / result.minimizer vs rho_min) and pass it through.

EXPECTED: crit9 scenario (removed candidate outside plate) now passes the geometry gate and is judged on active-wall drift; a GENUINE active wall outside the plate still fails closed :geometry_inconsistent; one-shot check path + FEM tier unaffected. Coordinator cycle: engineer + reviewer + critic (attack the mask: can a real wall be masked inactive?) + tester. Then re-run 428 + add F2 tests.
