---
id: expe-2c5f64c8
type: experiment
project: menegroth
parent_id: deci-ca79fdaf
title: 'Seed Asap solve: poker DL+edge and dining DL+edge (struts)'
node_label: 'Seed Asap solve: poker DL+edge and dining DL+edge '
tags: pokertable,asap,seed-solve
status: active
open_threads: 0
success: 'true'
files: StructuralStudies/src/pokertable/model.jl@ff9b92b, StructuralStudies/src/pokertable/geometry.jl@ff9b92b,
  StructuralStudies/src/pokertable/report.jl@ff9b92b, scripts/runners/pokertable_solve.jl@ff9b92b
session_id: sess-df71d44a
created_at: '2026-09-20T20:08:24.689058+00:00'
updated_at: '2026-09-20T20:08:24.689058+00:00'
results: '[{"metric": "poker_max_uz", "value": -0.697, "unit": "in", "split": "poker
  DL_edge struts coarse 5in mesh"}, {"metric": "poker_plus_apex_uz", "value": -0.004,
  "unit": "in", "split": "poker DL_edge struts"}, {"metric": "poker_sum_Rz", "value":
  568.8, "unit": "lbf", "split": "poker DL_edge struts"}, {"metric": "poker_al_mass",
  "value": 17.32, "unit": "lb", "split": "deployed members"}, {"metric": "dining_max_uz",
  "value": -0.876, "unit": "in", "split": "dining DL_edge at +x core edge"}, {"metric":
  "dining_sum_Rz", "value": 288.6, "unit": "lbf", "split": "dining DL_edge"}, {"metric":
  "dining_far_foot_mu", "value": 4.03, "unit": "1", "split": "dining DL_edge far feet"}]'
---
Seed mixed shell+frame solve now runs for both states.

Fixes that unblocked it:
- Unique Node objects before Asap.Model (duplicate A/S entries orphaned 6 free DOFs).
- Welded FixedFixed chassis (pin-ended X-base is a sway mechanism once end modules are off).
- Piano hinges at the 9 designed stations only (zipping independent Steiner points fought itself).

Poker (struts, D+250 lbf at +x apex + ~50 lbf rail): max uz -0.70 in at the long-edge midpoint; apex barely moves. No uplift. ΣRz = 569 lbf (a bit light vs ~700 lbf expected dead+live — RigidLink reduce still warns not-SPD / LDL). Aluminum 17 lb.

Dining (core only, D+250 lbf at +x edge): max uz -0.88 in at the loaded edge. ΣRz = 289 lbf matches ~294 expected. Far feet hold only 2.6 lbf (μ≈4) — 250 lbf on the dining edge nearly tips the 48 in foot spread.

Mesh is coarse (5 in). Materials are judgment (no NDS/APA/ADM).
