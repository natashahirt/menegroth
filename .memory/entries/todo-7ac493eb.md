---
id: todo-7ac493eb
type: todo
project: menegroth
parent_id: deci-e2344cc5
title: 'Still deferred: Phase 3/6 bridge wiring and ASCE 7-22 §12.7.2 seismic weight'
node_label: 'Still deferred: Phase 3/6 bridge wiring and ASCE 7'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f3dde776
created_at: '2026-10-22T15:52:29.356186+00:00'
updated_at: '2026-10-22T15:52:29.356186+00:00'
---
Still open after Guard F2, the crit8 endpoint check, and the walls_bridge doc nits all shipped:

1. PHASE 3/6 BRIDGE. The production building→evaluator path must populate Wall.x1..y2 from the same skeleton vertex_coords the plate helper reads (they are currently disjoint sources). Wire story_plate_geometry(...; walls=...) into the bridge so the enclosure assertion runs at construction. story.faces must be the complete story floor — the walls⊆plate⊆occupants residual relies on that plus Phase 10 FEM authority. Blocked on Phase 3 (walls are not yet on BuildingStructure).

2. ASCE 7-22 §12.7.2 effective seismic weight. effective_seismic_weight currently applies only the dead-load core. Items 1/2/4/3/5/6 (storage 25% live, partition 0.48 kN/m² min, flat-roof snow above 2.16 kN/m² at 15%, equipment/landscaping/fluids) need per-area data Cell does not carry. Caller must augment sdl until occupancy category and snow live on Cell. This is a Phase 6 demand input, not a Phase 3 blocker.
