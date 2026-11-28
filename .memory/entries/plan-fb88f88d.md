---
id: plan-fb88f88d
type: plan
project: menegroth
parent_id: plan-1e34d0a9
title: A moment under 2% of direct shear names no punching face
node_label: 2% punching face band
tags: waffle,solid-head,punching,aci-318
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-7cc6f39a
created_at: '2026-11-14T15:19:19.070249+00:00'
updated_at: '2026-11-14T16:37:57.832108+00:00'
has_child_rationale: Confirmed implementation of the face band under the edge-beam
  and solid-head phase
---
Leave vu, φvc, and the pass/fail ratio on ACI 318-11 R11.11.7.2 (aci-318-11, page 210). A head still grows only when column punching fails. A named face still adds one bay. No face still adds one ring. No mirror constraint and no flange-width change.

In the three direction helpers in punching.jl, a moment stress γv Mu c / Jc under 2% of the direct shear Vu/(b0 d) names no face. Interior needs both axes over that bar. Edge and corner use the same bar on each axis moment term. The 2% is the same engineering judgment as the rib band in _one_way_growth_direction, not a code factor. The general critical-section engine gets the same bar on each principal moment so a noise moment does not name a face there either.

Tests: the 200 kip / 80 kip·ft / 40 kip·ft interior case still names its corner. A new interior case near 556 kip and 1 kip·ft on both axes names no direction, and its stress still includes the moment. An edge case with about 20 in of eccentricity still names a face. The rib-hogging direction (1, 0) stays.

Then rerun only the 30 in waffle with the scene. The center head should match across x = 12 m and y = 10 m. Beam 30 and beam 38 should leave with the same stem, bars, and flange. If the head is symmetric and the flanges still disagree, stop and treat that as a flange-width bug.
