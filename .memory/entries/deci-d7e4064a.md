---
id: deci-d7e4064a
type: decision
project: menegroth
parent_id: plan-b10cde0c
title: Split warning narrows to stretched fractions; punching prediction backs off
  one step
node_label: Warning and overshoot decided
tags: warning,punching,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-da5e6261
created_at: '2026-11-08T20:03:50.012644+00:00'
updated_at: '2026-11-08T20:03:50.012644+00:00'
has_child_rationale: User answered the two open decisions in plan-b10cde0c
---
User decisions, 2026-11-08:

1. Moment-split warning (FEA design_approach=:frame). Fire only where the §13.6.4-§13.6.6 fractions are stretched: l2/l1 outside the table's 0.5-2.0 (the code clamps), a panel with beams that fails §13.6.1.6, or a non-rectangular panel. Cite §13.7.7.5 (aci-318-11 page 262). A failed §13.6.1.1 three-span check alone no longer triggers it.

2. Punching prediction. When the secant prediction picks a passing size, spend one more FEA confirm one size increment smaller, so the final columns match what the step-by-step walk would find. The confirm and the §11.11.7.1 check still decide.

Still open: whether one enter/exit trace pair per wall stage suits trace consumers (check during step 3).
