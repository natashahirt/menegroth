---
id: chec-7d2064fa
type: checkpoint
project: menegroth
parent_id: plan-4caf2683
title: Column trim and copied flat-plate mesh are in
node_label: Column trim and copied flat-plate mesh are in
tags: columns,flat-plate,story-shell,foundations,checkpoint
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/asap/asap/flat_plate_shells.jl@b733b2d, StructuralSynthesizer/src/analyze/asap/asap/model_sync.jl@b733b2d,
  StructuralSynthesizer/src/analyze/members/members/size_beams.jl@b733b2d, StructuralSynthesizer/src/analyze/members/members/size_columns.jl@b733b2d,
  StructuralSynthesizer/src/workflow/graph_builder.jl@b733b2d, StructuralSynthesizer/src/workflow/member_iteration.jl@b733b2d,
  StructuralSynthesizer/src/workflow/pipeline_spec.jl@b733b2d, StructuralSynthesizer/test/analyze/test_flat_plate_building_fea.jl@b733b2d,
  StructuralSynthesizer/test/analyze/test_frame_section_floors.jl@b733b2d, StructuralSynthesizer/test/analyze/test_section_floor.jl@b733b2d
session_id: sess-df7afd0f
created_at: '2026-11-25T16:40:35.753654+00:00'
updated_at: '2026-11-25T16:40:35.753654+00:00'
---
Flat-plate columns trim once after the grow-only settle and keep the lighter design only when it converges, no column is unresolved, and no slab got thicker. A wall that fails frame P-M submits that section as a floor and does not assign a replacement. A copied analysis model rebuilds the flat-plate mesh when the layout map is missing, so a design session's footings match the stage loop. Story-shell columns trim once after the shell settles, and a floor with no beams gets the same free passes, floor, and one trim. The story-shell trim is kept only when the shell of the new columns still passes.

Checked: flat-plate member stage 299/299, frame-section floors 173/173, design-graph equivalence 59/59, copied-mesh test 46/46, one-way story shell 22/22.
