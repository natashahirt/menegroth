---
id: deci-edeed997
type: decision
project: menegroth
parent_id: plan-1fd821a4
title: 'One more cycle: reject infeasible :converged column sections'
node_label: 'One more cycle: reject infeasible :converged colum'
tags: coordinator,column-nlp,converged
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-bfff975d
created_at: '2026-10-25T20:02:55.127911+00:00'
updated_at: '2026-10-25T20:02:55.127911+00:00'
has_child_rationale: User approved a forced extension for the converged-status constraint
  check.
---
The user approved one more cycle past the soft cap. Scope is only the RC column NLP selector: a `:converged` Ipopt stop (iteration limit or slow progress) may be kept only when the returned section satisfies the NLP constraints. Add a regression that the maxiter=1, snap=false, 500 kip / 50 kip-ft / 200 kip-ft case does not come back as an acceptable section with biaxial utilization about 1.05. Do not revert the footing bisection or punching seeds. Do not change the existing `Muy > 0` biaxial gate in this cycle. Critic is GPT 5.6 Sol medium.
