---
id: plan-16bebf1b
type: plan
project: menegroth
parent_id: plan-267f93b4
title: 'Overnight: scenes on full buildings, shrink-and-verify, grade walls, phase
  6'
node_label: Scenes and phase 6
tags: scene,shrink,grade-walls,joint-search,two-way,mat
status: active
open_threads: 2
success: 'null'
files: ''
session_id: sess-7ea87ccc
created_at: '2026-11-14T11:51:07.802331+00:00'
updated_at: '2026-11-14T15:08:59.966809+00:00'
---
Confirmed 2026-11-14. Work stays on row-f-nlp in /tmp/menegroth-rowf. Main checkout is not edited.

1. Full building runs write a scene by default. Restore the scene include and have the comparison runner call build_scene after each successful design.
2. Column shrink-and-verify after the beam/column loop settles, including punching.
3. Grade walls: WallLineDemand from the wall stage into the wall-strip designer and mat walls=.
4. Rest of phase 6: directional per-group wall drift, foundation grouping by concurrent demands, whole-section stacking, and the carbon joint-search scan as the flat-plate default.
5. Add a two-way building and a mat building with a core to the comparison cases, and run them.

Left out on purpose, unchanged: sliding, partial contact, the 25% overturning reduction, the Ev=0 exception, the 0.5 L live-load factor, and qa increases. Those change foundation sizes and still need a clause reading before any formula is written.

Do not pass files to memory records. Do not commit StructuralSynthesizer/src/scene until the user asks, but do load it so designs can write scenes.
