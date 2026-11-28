---
id: chec-aaaa6fcb
type: checkpoint
project: menegroth
parent_id: chec-03dc3063
title: 'Scene builder: resolve=false (visualize a with-links/per-case solution) +
  include_shells (walls/slabs on the bare path)'
node_label: 'Scene enablers: resolve + include_shells'
tags: scene,mgscene,rigid-diaphragm,shells,walls,visualization,build_scene
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/scene/build.jl@0ed307d, StructuralSynthesizer/test/visualization/test_scene.jl@0ed307d
session_id: sess-aa5cdd5a
created_at: '2026-11-24T12:14:15.162707+00:00'
updated_at: '2026-11-24T12:14:15.162707+00:00'
has_child_rationale: Unblocks visualizing rigid-diaphragm and per-load-case solutions,
  and rendering a hand-built model's RC walls
---
Two opt-in, default-off kwargs on `build_scene(model::Asap.Model; …)` (and through `export_scene`), so all existing callers (design pipeline + 657 scene tests) stay byte-identical:

- **`resolve=false`**: skip the builder's own linkless `solve!` for the `:solved` stage and draw the nodal displacements the caller already produced. Needed because `_prepare_model!` always re-solved linkless — which (a) is SINGULAR for a rigid-diaphragm master/slave model and (b) discards a with-links or specific-load-case solution. Now the caller does `solve!(model, links)` + `post_process!` and passes `resolve=false`.
- **`include_shells=true`**: append shell (wall/slab) triangle geometry (`shell_faces`/`shell_kind`/`shell_thickness` + surface stress/axial if solved) for a hand-built model carrying `model.shell_elements`. The bare path otherwise draws only frame centerlines and silently drops shells; the design-pipeline builders add shells in `_with_building_buffers`, so this is off by default to avoid double-emit.

Reuses `_shell_faces(model)` (classifies by shell.id → :wall/:slab). Tests (657/657): include_shells emits exactly the 2 wall triangles with kind codes + round-trips; resolve=false draws a tampered/foreign solution while resolve=true re-solves over it.

Purpose: enable the Stage-A rigid-diaphragm RC-shear-wall-core dual high-rise run to be visualized (walls render; the condensed-solver deflection is shown as-is).
