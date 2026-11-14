---
id: chec-bef6b94a
type: checkpoint
project: menegroth
parent_id: plan-fb88f88d
title: Center solid head is symmetric; mirror beams still differ
node_label: Symmetric one-bay heads
tags: waffle,solid-head,punching
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f6d2bf0e
created_at: '2026-11-14T16:37:57.832108+00:00'
updated_at: '2026-11-14T16:37:57.832108+00:00'
---
A moment stress under 2% of Vu/(b0 d) names no punching face (moment_names_a_face). That 2% is the same engineering judgment as the rib band, not an ACI factor. vu and the pass/fail ratio are unchanged (ACI 318-11 R11.11.7.2, aci-318-11, page 210).

Growth of a building head follows the column face, and the step is kept only when the column punching ratio falls. A rib that is further over its own ratio does not choose the side and does not keep the step.

The 30 in waffle (637.5 s) has a center head symmetric about (12, 10): x 11.29–12.71 m, y 9.40–10.60 m. It is the bay around the column, not the old one-module step to the southwest. Edge and corner heads are mirrors. Slab 15 punching_shear_slab is 6.90. Sizing did not settle.

Beam 38 (x = 6 m, y = 5.3–9.7 m) is T10x18-bf21-2#5 at 95.2 kip·ft. Beam 30, its mirror, is T10x16-bf10-2#5 at 65.3 kip·ft. The whole x = 6 line is 18 in deep and x = 18 is 16 in. The demands differ, so this is not the flange formula alone. The flange formula was not changed.
