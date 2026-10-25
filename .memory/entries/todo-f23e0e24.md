---
id: todo-f23e0e24
type: todo
project: menegroth
parent_id: plan-1fd821a4
title: 'Spread footing: bracket and bisect thickness'
node_label: 'Spread footing: bracket and bisect thickness'
tags: coordinator,eng-1a,spread-footing
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-6ba8dff8
created_at: '2026-10-25T13:38:39.980528+00:00'
updated_at: '2026-10-25T14:06:18.202168+00:00'
---
Replace the linear thickness scan in StructuralSizer/src/foundations/codes/aci/spread_footing.jl (the `for iter in 1:60` loop that does `h += h_incr`) with a bracket and bisection on punching and one-way shear. Round the accepted depth up to `depth_increment`. The accepted h must match the current linear scan. Keep the existing failure if the upper bound is still inadequate. Do not change flexure, bearing, or dowels, which run after the loop. Run only `julia scripts/runners/test_quiet.jl StructuralSizer foundations/test_spread_aci.jl foundations/test_spread_footing.jl`.
