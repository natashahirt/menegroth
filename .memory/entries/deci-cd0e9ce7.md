---
id: deci-cd0e9ce7
type: decision
project: menegroth
parent_id: plan-7f7bfe8c
title: Wall slab area is the straight-skeleton edge polygon, not nearest-distance
node_label: Skeleton wall tributary
tags: slabs,walls,tributary,straight-skeleton
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7cfe7560
created_at: '2026-11-05T01:26:43.504267+00:00'
updated_at: '2026-11-05T01:26:43.504267+00:00'
has_child_rationale: User chose the beam tributary rule over a parabolic nearest-support
  split.
---
Wall slab area comes from Asap `get_tributary_polygons` (isotropic straight skeleton), one polygon per cell edge, the same polygons beams already use. A wall owns the polygon of each edge it lies on. Every other edge is not a support: its polygon is split between the columns at its corners. The pieces sum to the cell, so a corner with no column no longer drops its area.

On an 8 m square bay with a wall on one side and columns at the two far corners, the wall polygon is the triangle to the center: 16 m². Each column gets 24 m². The boundary is straight. The parabolic nearest-distance split (wall about 35 m², each column about 15 m²) was rejected.

Do not sample the wall into points for `compute_voronoi_tributaries`. Column areas change only when this split is wired in, together with slab supports that actually hold the slab on the walls.
