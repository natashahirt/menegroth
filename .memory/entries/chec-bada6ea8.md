---
id: chec-bada6ea8
type: checkpoint
project: menegroth
parent_id: plan-1fd821a4
title: Sizing convergence run stopped after the column warm-start re-review
node_label: Sizing convergence run stopped after the column wa
tags: coordinator,sizing,checkpoint,column-nlp,spread-footing
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-fd18d272
created_at: '2026-10-25T15:15:58.096210+00:00'
updated_at: '2026-10-25T15:15:58.096210+00:00'
---
Coordinator run run-a286eea4 finished at the one-cycle cap. Spread footing thickness now bisects the same 60-point grid. The mat Winkler hoist was already correct and was left in place. Spread and mat searches seed from an ACI 318-11 Eq. (11-33) punching estimate without raising the minimum accepted depth. The RC column NLP solves from both the moment seed and the axial-only seed and keeps the better acceptable section. Default tests: spread 77, then footing+column 232, then column 112.

First critic P0 was real: the moment seed alone returned an infeasible 14×14 where the axial seed returned an optimal 8×24. The fix addresses that on the reported cases.

Second critic still FAILed. The selector treats Ipopt `:converged` (iteration-limit or slow-progress) as acceptable without a constraint check. With maxiter=1 and snap=false on the 500 kip / 50 kip-ft / 200 kip-ft case, the returned section has biaxial utilization 1.049. The footing-diff P0 is not a defect: those edits are the approved bisection and punching seeds, not the column fix. Negative Muy still does not open the biaxial constraint (`Muy > 0` only); that gate was already there.

Stopped at max_extensions=1. Work is uncommitted. Next step, if approved: reject `:converged` unless the section satisfies the NLP constraints, and assert capacity in the column test.
