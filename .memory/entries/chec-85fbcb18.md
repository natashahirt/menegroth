---
id: chec-85fbcb18
type: checkpoint
project: menegroth
parent_id: plan-c431a82d
title: Special-wall web shortfall thickens that pier only
node_label: web shortfall thickens that pier
tags: special-walls,aci-318,18.10.6.4,thickness
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-5428603b
created_at: '2026-11-11T16:05:46.664719+00:00'
updated_at: '2026-11-11T16:05:46.664719+00:00'
---
A required special-boundary element now moves thickness, and only the pier whose web is the compression zone.

ACI 318-19 §18.10.6.4(b) (corpus: aci-318-19, page 327): the compression-zone width is at least hu/16 where §18.10.6.2 or §18.10.6.3 requires an element. The 12 in. floor in §18.10.6.4(c) stays closed because a single critical section is not stated. The decision stores thickness_shortfall_m as how far the web is below that width. When the flange is the compression face, the width is bf and the shortfall on the web is zero: this jump does not resize the flange.

propose_wall_thicknesses raises that pier to the next inch that covers the shortfall, after the ordinary group proposal, and not above the 36 in. ceiling. A neighbor and a row with no decision stay. The jump has to be on. Reinforcement is unchanged. §18.10.6.2 stays closed.

Tests: analyze/test_wall_thickness_jump.jl 314/314, logs/test_StructuralSynthesizer_20261111_105740.log. analyze/test_special_boundary_stage.jl 76/76, logs/test_StructuralSynthesizer_20261111_105956.log. A 4 m story with a 0.30 m web has no shortfall; an 8 m story shortfalls by 0.20 m and the zone length does not move. A 0.20 m web shortfalls by 0.05 m; the same web with a flange in compression shortfalls by zero and has a lower fiber stress. The proposal moves only the pier that carries the shortfall, including under grouping :all.

Still out: the displacement route, boundary bars, §18.10.6.4(h)–(k), edges around openings, SDC D–F, and coupling beams.
