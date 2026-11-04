---
id: anno-aa4df236
type: annotation
project: menegroth
parent_id: plan-8fcebf0f
title: Joined-wall plan is topology, not L/T/C/box named shapes
node_label: Arbitrary core plan
tags: walls,joined,core,octagon,parallelogram,plan
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e72f7859
created_at: '2026-11-04T16:02:15.467389+00:00'
updated_at: '2026-11-04T16:02:15.467389+00:00'
has_child_rationale: Cores may be parallelograms, octagons, or other arbitrary plan
  graphs
---
User: cores are not limited to L/T/C/box — parallelogram, octagon, or other closed/open plan graphs are in scope.

Implication: no named-shape branches. An assembly is the connected graph of wall lines on a story (ends meet, plus T-splits). Each edge is already an arbitrary (x1,y1)–(x2,y2) pier; in-plane checks use that pier's own tangent (`_pier_plan_axes`). A parallelogram or octagon is the same path as a rectangular box.

Tests: add a non-rectangular closed core (parallelogram or regular octagon) under torsion / one-axis load, not only an orthogonal box.

Geometry that does change: at a non-right corner the centerline overlap is (t_other/2)/sin(φ), where φ is the angle between the two centerlines. The chosen “half thickness” rule is that formula at φ = 90°. Using half-thickness at an acute parallelogram corner under-subtracts and is unconservative on lw. Pending user choice on the miter formula.

X-junctions (two interiors crossing) are still not in this slice unless asked.
