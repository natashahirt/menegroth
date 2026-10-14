---
id: todo-7fd5e693
type: todo
project: menegroth
parent_id: plan-b2670c25
title: 'Pre-ribbed-floor cleanup: functional gaps, cosmetic/diagnostic fixes, duplication'
node_label: 'Pre-ribbed-floor cleanup: functional gaps, cosmeti'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-df7830b3
created_at: '2026-10-14T18:38:46.857477+00:00'
updated_at: '2026-10-14T18:38:46.857477+00:00'
---
The user approved all of these before ribbed-floor work.
Functional gaps: design_building passes a Bool composite sentinel instead of a real CompositeContext (no slab/anchor builder on that path); rule-of-thumb can still emit slab_result on an Inf transfer when the caller ignores `converged`.
Cosmetic/diagnostic: explain_feasibility reports the wrong governing check (unsigned pm_interaction passes while flexure_neg fails) and labels sentinel hogging 'I3.2b'; tie visualization falls to :x on Dx == Dy.
Duplication: B1 amplification block x4 in checker.jl (extract _b1_amplified_moments); ROT secondary-moment copy; unused l2/qL args in the old Eq. 13-7 helper; _support_positions_along_axis duplicates _support_span_xy_m; _pattern_demand_cases builds its list twice.
