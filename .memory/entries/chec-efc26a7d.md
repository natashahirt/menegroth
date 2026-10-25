---
id: chec-efc26a7d
type: checkpoint
project: menegroth
parent_id: plan-1fd821a4
title: Converged-section gate landed; Sol critic found a bar-cap miss
node_label: 'Converged-section gate landed; Sol critic found a '
tags: coordinator,column-nlp,converged,checkpoint
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-3ca774e4
created_at: '2026-10-25T20:28:08.443247+00:00'
updated_at: '2026-10-25T20:28:08.443247+00:00'
---
Forced cycle for the RC column `:converged` gate is done. A `:converged` stop is kept only when `constraint_fns` at `(b_final, h_final, ρ_opt)` is within each upper bound by 1e-4. The one-iteration 500 kip / 50 kip-ft / 200 kip-ft section at biaxial utilization 1.049 is now `:infeasible`. The default 1000 kip / 500 kip-ft section stays `:converged` at utilization 0.73. Column tests passed 129 of 129.

Sol critic FAIL, highest finding P1, so no automatic fix. The gate checks continuous `ρ_opt`, not the bars actually placed. A 20×20 in section with #8 bars and `ρ_opt=0.08` hits the 32-bar cap (`section.ρg=0.0632`): the gate sees utilization 0.994 and keeps status `:converged`, while the returned section is at 1.001. The footing diff the critic flagged is the earlier approved bisection and punching seeds, not this gate.

Work remains uncommitted. Next step, if approved: evaluate the gate at the returned section's actual reinforcement ratio and add that 20×20 regression.
