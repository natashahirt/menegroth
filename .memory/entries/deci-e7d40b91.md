---
id: deci-e7d40b91
type: decision
project: menegroth
parent_id: plan-ad399e86
title: Drop-panel weight reaches the building model as column-top nodal dead load,
  from the sizer's drop outline
node_label: 'Drop weight: nodal, one outline'
tags: drop-panel,flat-slab,self-weight,load-path,composite,fire-coating
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-78ed7ea6
created_at: '2026-11-09T17:13:04.125994+00:00'
updated_at: '2026-11-09T17:13:04.125994+00:00'
---
User decision 2026-11-09.

- Drop projection weight (h_drop x clipped outline area x rho g) is a -Z `Asap.NodeForce` with id `:drop_panel_self_weight` at each column-top node. Slab `self_weight` stays gamma*h over the panel, so there is no double count. Limitation: frame moments from the part of the drop lying in the span are not represented.
- One outline everywhere: `StructuralSizer.column_drop_panel_areas` (the `_column_drop_outline` the sizer, punching check and FEA patch use). The synthesizer's takeoff, frame load, ELF weight, foundation service dead, gravity basic D, pattern dead and the story-stability axial fallback all read `drop_panel_column_volumes` / `drop_panel_weights_by_vertex`. The old bounding-box trim (`_slab_bbox_m`, `_trimmed_drop_extents_m`) was removed.
- Dead factor helper renamed `_self_weight_dead_factor` (walls and drops).
- Composite unshored split: fire coating (`FIRE_COATING_LOAD_ID`) is dead on the bare steel (user: applied before the slab is composite). Drop loads are dead there too.
- Preliminary column sizing (`estimate_column_sizes!`) needs no drop term: it runs before slab sizing, when no drop exists.

Tests written, not yet run: `StructuralSynthesizer/test/analyze/test_drop_panel_loads.jl`.
