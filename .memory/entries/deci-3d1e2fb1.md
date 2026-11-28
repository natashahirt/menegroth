---
id: deci-3d1e2fb1
type: decision
project: menegroth
parent_id: plan-c8115994
title: Design the core-corner columns, and draw the stored tributary split
node_label: Core columns and stored tributaries
tags: core,columns,tributary,flat-plate,scene
status: active
open_threads: 2
success: 'null'
files: scripts/runners/core_office_geometry.jl@4ecef8e, StructuralSynthesizer/src/scene/fields.jl@4ecef8e,
  StructuralSynthesizer/src/scene/components.jl@4ecef8e, StructuralSynthesizer/src/scene/variants.jl@4ecef8e,
  StructuralSynthesizer/test/core/test_core_shaft.jl@4ecef8e, viewer/src/detail-overlay.ts@4ecef8e,
  viewer/src/main.ts@4ecef8e, viewer/src/detail.ts@4ecef8e, docs/src/reference/scene_format.md@4ecef8e
session_id: sess-e94deb7b
created_at: '2026-11-07T22:29:52.664913+00:00'
updated_at: '2026-11-08T13:03:30.940313+00:00'
has_child_rationale: The office picture was painting straight-skeleton edge polygons
  as column and wall areas, and the four core-corner stacks had been removed from
  the column group so they were never designed.
---
The four core-corner stacks at (8, 8), (8, 16), (16, 8), and (16, 16), one per story, stay in the column group and are designed with the rest of the columns. The walls still own the bay edges. `core_office_skeleton` no longer calls `_drop_core_corner_columns!`. The 24 m panel that made ACI 318-11 §13.6.1.2 refuse direct design was that drop; the lobby span still refuses §13.6.1.3. The rest of deci-d04a388c (lobby, shafts, doors, diaphragm) stands.

A column-supported cell's tributary picture is the split `compute_column_tributaries!` already stored: `column_tributary_polygons` for each column, and `wall.tributary_widths` sampled into a plan loop for each wall. On a square bay with four columns and no wall that is four rectangles meeting at mid-bay. Beam-supported cells still draw the straight-skeleton edge polygons the beam design uses. Each loop carries `tributary_cell` (0-based), and a slab's `bind.cell_indices` lists the cells it owns. deci-cd0e9ce7 still governs how a wall's area is assigned in the analysis; the scene no longer repaints those edge polygons as columns on a flat plate.
