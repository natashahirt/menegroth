---
id: expe-195aab32
type: experiment
project: menegroth
parent_id: deci-52e08be1
title: Dense waffle passes after discrete sizing requires As,min
node_label: Dense waffle passes; Beam 1144 cleared
tags: waffle,grid/x1y1,min-reinforcement,aci-318-11
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-f69b61ca
created_at: '2026-11-25T16:29:21.722782+00:00'
updated_at: '2026-11-25T16:29:21.722782+00:00'
has_child_rationale: The building check that chec-f5532534 left open.
invalidates: expe-007fc1db
---
grid/x1y1 dense waffle (30 in pans) after discrete sizing requires As,min. The building passed. All 16 solid heads passed on the first cast (stop=passed, steps=0, ok=true). The summary says all checks pass. The closest element is Column 5, column shear, ratio 1.0. Beam 1144 is T7x29-bf15-1#8, flexure ratio 0.64, shear ratio 0.09, and it is not the failure. Design time was 1820 s. Report: logs/sdf_rib_design/grid_x1y1_qualification/dense_waffle.txt.

This replaces the 19 Nov result in which the same building failed on Beam 1144, minimum reinforcement, ratio 1.0.
