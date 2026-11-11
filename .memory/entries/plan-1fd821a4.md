---
id: plan-1fd821a4
type: plan
project: menegroth
parent_id: plan-a0000003
title: 'Faster sizing convergence: spread bisection, mat hoist, warm starts'
node_label: 'Sizing convergence: bisection + starts'
tags: sizing,performance,foundations,spread-footing,mat-footing,nlp,coordinator
status: active
open_threads: 4
success: 'null'
files: StructuralSizer/src/foundations/codes/aci/spread_footing.jl@e96053b, StructuralSizer/src/foundations/codes/aci/mat_winkler_fea.jl@e96053b,
  StructuralSizer/src/members/optimize/problems.jl@e96053b
session_id: sess-6ba8dff8
created_at: '2026-10-25T13:38:27.887809+00:00'
updated_at: '2026-10-25T20:47:50.108891+00:00'
has_child_rationale: User approved the graph for items 2, 1a, and 7.
---
Approved coordinator run for three items from the faster-sizing-convergence plan.

1. Spread footing: replace the linear thickness scan with bracket and bisection, rounded up to depth_increment. The accepted depth must match the linear scan.
2. Mat Winkler FEA: verify mesh, springs, loads, and the model are built once and only thickness is updated inside the loop. The hoist is already in the tree; fill a gap only if it is incomplete.
3. Starting points only, after the footing edits. Spread and mat seed h from a punching estimate, then the verified search still accepts the depth. RC column NLP adds a moment term to initial_guess. The closed form is not the design result.

Rigor low, one fix cycle, one pass. Engineers on Grok 4.7 high, serial because concurrent Julia precompile kills runs. Critic on GPT 5.6 Sol medium because the roster Opus model is not available in this session. Reviewer, tester, and bugbot skipped.
