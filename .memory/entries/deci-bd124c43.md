---
id: deci-bd124c43
type: decision
project: menegroth
parent_id: plan-b2670c25
title: 'Eq. (13-7): evaluate the unbalanced pattern both ways; re-entrant corners
  take max(Eq. 13-7, 0.3 M0)'
node_label: 'Eq. (13-7): evaluate the unbalanced pattern both w'
tags: eq-13-7,ddm,engineering-judgment
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-fd0b7b43
created_at: '2026-10-14T19:25:02.380422+00:00'
updated_at: '2026-10-14T19:25:02.380422+00:00'
---
ACI 318-11 R13.6.9 (page 258) describes only one pattern: full D + 0.5L on the longer span, D only on the shorter. It does not cover a negative bracket (a heavier or wider shorter span), and ACI does not address re-entrant corners explicitly.
User decisions:
(1) Negative bracket: evaluate the Eq. (13-7) pattern both ways (D + 0.5L on each adjoining span in turn, D only on the other) under both §9.2.1 combinations and take the larger magnitude. Flag it ENGINEERING JUDGMENT. Replaces abs(Mu). Critic example: 130.4 vs 99.9 kip-ft.
(2) Re-entrant corner (L-plan): classify direction-aware (interior in a direction where the slab is continuous on both sides), then take max(Eq. 13-7, 0.3 M0) at re-entrant corners. Flag it ENGINEERING JUDGMENT.
