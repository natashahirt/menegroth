---
id: deci-1d3a040b
type: decision
project: menegroth
parent_id: plan-adfe2e3a
title: Columns and walls share each cell's straight-skeleton edge polygons
node_label: Skeleton supports
tags: slabs,walls,columns,tributary,straight-skeleton
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-8f6d4b5d
created_at: '2026-11-08T21:12:02.075888+00:00'
updated_at: '2026-11-08T22:21:29.471081+00:00'
invalidates: deci-01b4dd14
---
User decision (Nov 8): replace the larger-region rule (corner Voronoi vs parabola, wall gets the complement) with the straight-skeleton edge polygons that beams already use (`compute_cell_tributaries!`).

Per cell (or per part of a cell cut by an interior wall):
- An edge covered by walls goes to those walls, clipped to each wall's extent.
- Every other edge polygon is halved at the edge midpoint (cut along the slicing direction: perpendicular to the edge for two-way, the span axis for one-way). Each half goes to the support at its corner: the column there, else a wall ending at or passing through that corner (one along an edge of the cell first).
- A corner with no column and no wall: that half goes to the nearest support around the cell boundary, and the edge is flagged as overhanging.
- Areas come from the edge's load profile (so openings are net); polygons are the clipped outlines.

West bay beside the core (8 m square, wall on one edge, columns at the two far corners): each column 16 m², wall 32 m², same totals as v6 but drawn as triangles and trapezoids. Wall-end punching uses these wall areas directly; no envelope with the previous rule.

Walls store share polygons per cell instead of width laws; the tee split clips those polygons. All tributary code moves into `StructuralSynthesizer/src/analyze/tributaries/`.
