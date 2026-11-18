---
id: expe-a771f11b
type: experiment
project: menegroth
parent_id: deci-20346596
title: 30 in waffle stops at the solid cap with punching still about 3
node_label: '30 in waffle stops at the solid cap with punching '
tags: waffle,solid-head,qualification,grid/x1y1
status: active
open_threads: 0
success: 'false'
files: ''
session_id: sess-bf3b880a
created_at: '2026-11-18T00:59:52.829325+00:00'
updated_at: '2026-11-18T00:59:52.829325+00:00'
---
grid/x1y1, waffle with 30 in pans, after per-piece rib sizing. Head-face ribs are sized for Vu ≤ φVc, collinear pieces share the §8.13.2 width and a 6 in soffit step, and a tight void joins a head only along a shared edge. Growth stops at solid_fraction_max = 0.35.

The design does not pass. Each of the 16 bays has one solid head of 15 or 18 module bays. Every head stops at :solid_cap with steps = 0 on the last pass, so the cap is already binding. Column punching ratios are 2.26 to 3.33 (critical Slab 15, 3.331). Most rib pieces stayed T4x11 or T5x11; a few pieces at the heads are deeper (about 15 to 30 in). The member loop did not settle in 4 iterations.

Punching is not brought under 1 by solid area at this cap. The head depth is the deepest rib on the level, so an 11 in rib soffit is an 11 in head. A head deeper than the ribs, which the agreed hybrid allows, is not implemented.

Scene: viewer/public/sdf_grid_x1y1_variable_ribs.mgscene. Report: logs/sdf_rib_design/grid_x1y1_qualification/dense_waffle.txt.
