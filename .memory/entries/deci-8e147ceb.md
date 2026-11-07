---
id: deci-8e147ceb
type: decision
project: menegroth
parent_id: deci-3d1e2fb1
title: Slab stores the column and wall tributary polygons, curves included
node_label: Tributary polygons on the slab
tags: slabs,tributary,walls,columns,parabola,scene
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/building_types/cells.jl@2e40033, StructuralSynthesizer/src/analyze/members/members/column_tributaries.jl@2e40033,
  StructuralSynthesizer/src/scene/fields.jl@4ecef8e, StructuralSynthesizer/test/analyze/test_support_regions.jl@2e40033,
  StructuralSynthesizer/test/core/test_core_shaft.jl@2e40033, docs/src/reference/scene_format.md@2e40033
session_id: sess-e94deb7b
created_at: '2026-11-07T22:41:41.739439+00:00'
updated_at: '2026-11-07T22:41:41.739439+00:00'
has_child_rationale: The column-and-wall split, including parabolic edges, is already
  computed. The picture should copy those loops from the slab instead of rebuilding
  them.
---
`compute_column_tributaries!` writes each column share and each wall share onto the slab that owns the cell, in `slab.tributary_polygons` (`SlabTributaryPolygon`: cell, `:column` or `:wall`, owner index, plan vertices in metres).

A column loop is the polygon `split_cell_supports` already sampled, so a parabolic boundary is in the vertex list. A wall loop is the stored width law. A straight piece is a quadrilateral. A parabolic piece `w = a s² + b s + c` is sampled so the sagitta stays within 1 mm. A beam-supported cell with no wall is not copied; its picture stays the edge polygons.

The scene copies `slab.tributary_polygons` and does not rebuild the loops. On the 8 m cell with one far column and a wall, the wall loop passes through the parabola (`w(4) = 5`), not the straight chord.
