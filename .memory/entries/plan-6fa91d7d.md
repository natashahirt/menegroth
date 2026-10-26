---
id: plan-6fa91d7d
type: plan
project: menegroth
parent_id: todo-39adc6c6
title: 'Phase 7 scope: one ordinary wall, analyzed demands, existing checks'
node_label: 'P7 scope: one ordinary wall'
tags: walls,phase-7,scope,ordinary,drift,combinations,plan
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-15a7322a
created_at: '2026-10-26T17:27:12.892727+00:00'
updated_at: '2026-10-26T17:27:12.892727+00:00'
---
Phase 7 is the next implementation phase. It is the vertical slice in todo-3b10ee83: one solid ordinary wall, one simple building, one seismic direction and the two perpendicular wind principal axes, from `:walls` geometry through the unified rigid-diaphragm model to serialized wall results. Openings, §18.10, layout search, leaning walls, sloped-roof wind, and the perimeter-frame iteration (note-8072f72a) stay out.

First slice, before any wall size changes:
1. Commit the Chapter 27 wind work already written.
2. Add extra wind directions. The two Figure 27.3-8 principal axes stay perpendicular by default. Additional directions are Case 1 and Case 2 of their own, and a caller can override the perpendicular check explicitly.
3. Apply ASCE 7-22 §2.3.1 to the story results that already exist. ELF and Chapter 27 forces stay as computed. The combination supplies the 1.0W and 1.0E factors and the gravity factors that go with them: 1.2D + 1.0W + L, 0.9D + 1.0W, 1.2D + 1.0E + L + 0.2S, 0.9D + 1.0E. Gravity-only combinations already in the pipeline are unchanged.
4. Judge seismic design story drift against `allowable_story_drift` (Table 12.12-1). Risk category and the drift system are required arguments. Wind displacement is reported. A wind drift limit is not invented; Table 12.12-1 is seismic.

Then the wall stage, on `design_building` / the design graph:
- Run only when the building has walls and the caller asked for lateral design. A gravity-only building is unchanged.
- Demands come from the unified frame-shell model. The walls-only reduced evaluator is not the authority for this slice. No fixed core/perimeter split.
- Check each ordinary wall with the existing checkers: in-plane shear, minimum reinforcement, in-plane flexure (P–M), bearing, and out-of-plane where the demand exists.
- Fill `BuildingDesign.walls`. `WallCheckRecord` is currently only story, direction, and combination. This phase adds the governing check, demand, capacity, and clause. One record per wall, story, direction, and combination.
- Drift from step 4 is stored on the design with the seismic case that produced it.
- Missing site, seismic, or wind inputs throw. Nothing is inferred.
- Trace the stage. A fixture covers one wall from `:walls` geometry to the serialized records, and the gravity-only path still passes.

Sizing in this slice is check-and-report for a given wall section. Searching thickness, length, or layout is Phase 10. If the given section fails, the record says so.
