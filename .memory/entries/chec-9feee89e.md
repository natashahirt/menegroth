---
id: chec-9feee89e
type: checkpoint
project: menegroth
parent_id: plan-a5444476
title: 'Step 3: a bay left out of the face polygons is a courtyard'
node_label: Courtyard is no slab
tags: courtyard,void,slab,edge_face_counts,outline
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/core/utils_building_skeleton.jl@e6f7281, StructuralSynthesizer/src/api/deserialize.jl@e6f7281,
  StructuralSynthesizer/src/walls_bridge.jl@e6f7281, StructuralSynthesizer/test/core/test_courtyard_void.jl@e6f7281,
  StructuralSynthesizer/test/runtests.jl@e6f7281
session_id: sess-fd6b1f11
created_at: '2026-10-29T20:18:04.480382+00:00'
updated_at: '2026-10-29T20:18:04.480382+00:00'
---
A detected face outside the :grade/:floor/:roof groups carries no slab. slab_face_indices returns nothing when those groups are empty, so today's no-polygons input still treats every closed loop as a slab. rebuild_geometry_cache! counts only slab faces, so a courtyard edge is a boundary (count 1) for cell position, column position, and bracing. json_to_skeleton rebuilds the cache after explicit face polygons. story_floor_outline drops non-slab faces, so a courtyard is a clockwise hole. Beam side profiles and tributary loads already iterate cells, so a cell-less bay adds no flange and no load.

Test: 3x3 bays, roof polygons omit the middle. 8 cells, courtyard edges count 1, courtyard columns are not interior, the four surrounding beams are one-sided, each courtyard edge carries one tributary, and the outline is an exterior loop plus a -36 m² hole. Regression: courtyard + walls bridge + ELF story cases, 148 passed.
