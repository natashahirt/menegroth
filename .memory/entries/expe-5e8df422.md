---
id: expe-5e8df422
type: experiment
project: menegroth
parent_id: deci-82d2484a
title: 'Carbon sweep: column EC nonzero and concrete plus rebar equals the total'
node_label: 'Carbon sweep: column EC nonzero and concrete plus '
tags: embodied-carbon,sweep,flat-plate,ddm,fea
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-5e83f3f4
created_at: '2026-10-27T17:37:09.551088+00:00'
updated_at: '2026-10-27T17:37:09.551088+00:00'
---
Warm sweep of the 20 ft, 8×5 bay flat plate (3 and 6 stories, DDM and FEA) into logs/sweep_carbon.csv. All four cases status=ok and all_checks_pass=true. Column EC is now about 11–13% of the total (was 0). Concrete plus rebar equals the building total on every row; structural steel is 0 (no steel members) and foundations are 0 (the spec does not design them). Punching still governs, ratios 0.935 (DDM) and 0.990 (FEA). Design times were 188–289 s per building. Wall clock was 8452 s because one worker waited 7800 s on a StructuralSynthesizer precompile held by another process; design wall after workers were ready was about 530 s. Gurobi was unavailable on one worker and that worker used HiGHS.
