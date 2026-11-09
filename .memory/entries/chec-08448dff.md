---
id: chec-08448dff
type: checkpoint
project: menegroth
parent_id: plan-0e3e4710
title: Rib-bay scene stores solid-head punching
node_label: rib-bay scene
tags: solid-head,punching,rib-bay,scene
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6a407f88
created_at: '2026-11-09T03:01:13.152489+00:00'
updated_at: '2026-11-09T03:01:13.152489+00:00'
---
Each slab whose level-1 grillage has a solid head now gets the released-corner rectangle check on SlabDesignResult: punching_max_ratio, punching_ok, and punching_vu_max_psi. The head is the size already cut into the frame; it is not grown. Corner rotation is released, so the unbalanced moment is zero, and a column shared with the next bay is not given that bay's load. The scene clause is ACI 318-11 §11.11.1.2.

viewer/public/rib_bay.mgscene was regenerated (six variants). The two 4-bay designs show the check on all four slabs (one-way ratio 0.211, two-way 0.202, both governed by rib-web punching and passed). Solid-head pieces extrude as rectangles. The scene frame includes joists, because a solid-head cut leaves vertices that only the ribs touch; an unused free node made the model singular.

Placed bars for the topping and the solid head, and the fresh seven-system regression, were not started.
