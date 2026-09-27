---
id: todo-0ff0efa9
type: todo
project: menegroth
parent_id: plan-a4de4826
title: Floor strip B at c_across and remap bearing A2
node_label: Floor strip B at c_across and remap bearing A2
tags: foundation-safety,p1,bearing,strip-axis
status: discarded
open_threads: 1
success: 'null'
files: StructuralSizer/src/foundations/codes/aci/strip_footing.jl@9690969
session_id: sess-a69a92aa
created_at: '2026-09-23T06:49:59.910734+00:00'
updated_at: '2026-09-27T17:22:11.904510+00:00'
---
Last extension. Critic P1s: (1) Step 7 bearing A2 still pairs named c2 with B; on Y-strip pass (c_along, c_across)=(named c2, named c1) into _bearing_check_footing. (2) Floor B_min at c_across_max so cant_trans cannot go negative. Do not reopen P2 mixed-band Mu, NLP evaluate Inf, or rule_of_thumb.
