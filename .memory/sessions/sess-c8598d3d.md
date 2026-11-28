---
id: sess-c8598d3d
project: menegroth
started_at: '2026-11-08T12:24:32.763483+00:00'
ended_at: '2026-11-08T13:03:26.289985+00:00'
title: Mat flexural development, and load the T-beam flange check that already exists
  (+1 more)
summary: 'Mat flexural development, and load the T-beam flange check that already
  exists (+1 more)

  Auto-closed after topic shift. 2 created, 56 accessed.'
kind: session
entries_created: '[{"id": "plan-12232ba0", "title": "Mat flexural development, and
  load the T-beam flange check that already exists", "type": "plan"}, {"id": "plan-ba9ac0e8",
  "title": "Incremental walls see a thickness change; diagnose the two flat-plate
  test failures", "type": "plan"}]'
entries_accessed: '[{"id": "plan-9768ec38", "title": "Close the wall-support gaps:
  support moments, wall out-of-plane, openings, flexible diaphragm", "type": "plan"},
  {"id": "note-5422387f", "title": "Wall moment is no longer labeled as a column moment",
  "type": "note"}, {"id": "todo-5b263929", "title": "Phase 3 \u2014 Wall + wall-result
  data model", "type": "todo"}, {"id": "deci-bfa4c684", "title": "Wall supports in
  direct design and the equivalent frame", "type": "decision"}, {"id": "deci-b34e4300",
  "title": "Wall-end punching, \u00a713.7 refusal, and Table 9.5(c) at a wall", "type":
  "decision"}, {"id": "plan-b45b0d7f", "title": "Ordinary-wall stage in design_building
  for one isolated pier", "type": "plan"}, {"id": "plan-b6ff71fd", "title": "Phase
  3 implementation: wall storage, :walls member init, enclosure at initialize!", "type":
  "plan"}, {"id": "deci-531636c3", "title": "Grade wall bases are fixed in all six
  degrees of freedom", "type": "decision"}, {"id": "plan-7f7bfe8c", "title": "Walls
  as slab supports: open core gap, support list, FEA wall supports, DDM spans/moments,
  load split, punching at wall ends", "type": "plan"}, {"id": "chec-bce1127a", "title":
  "design_building runs ordinary-wall checks when lateral design is requested", "type":
  "checkpoint"}, {"id": "deci-a1809fe5", "title": "Core foundation seam: rigid mat
  restrains the wall base; reactions go to the existing mat", "type": "decision"},
  {"id": "deci-6544575b", "title": "Footing flexure must be tension-controlled; failed
  checks are violations or errors, not warnings", "type": "decision"}, {"id": "deci-92382f3b",
  "title": "Low-rise spread buildings may add a rigid mat under the core as one strategy",
  "type": "decision"}, {"id": "chec-c2cb35bb", "title": "Commit audit correctness
  fixes: tension-controlled flexure and fail-closed checks", "type": "checkpoint"},
  {"id": "plan-1fd821a4", "title": "Faster sizing convergence: spread bisection, mat
  hoist, warm starts", "type": "plan"}, {"id": "plan-ff3de633", "title": "Split foundation
  utilities into focused move-only files", "type": "plan"}, {"id": "deci-67cf61cb",
  "title": "Default: grade core walls share a mat; an isolated wall gets a strip footing",
  "type": "decision"}, {"id": "todo-562ec7a4", "title": "Write AISC 360-16 \u00a7F4;
  the long-span fire-rating beam stays failing", "type": "todo"}, {"id": "deci-3b8356ad",
  "title": "A door or window does not open a cell; the mat still covers that wall",
  "type": "decision"}, {"id": "todo-b31bdd84", "title": "Coordinated: flat-plate col_I_factor
  SSoT across FEA+EFM \u2014 [eng] sync+efm edit, [rev] blind, [crit] adversarial,
  [test] gate, [mem] record", "type": "todo"}, {"id": "note-621eb77e", "title": "Saved
  core office design is archive version 1 and the current code cannot read it", "type":
  "note"}, {"id": "anno-03543523", "title": "Node rotations stay out of the scene;
  the design archive does not store them either", "type": "annotation"}, {"id": "plan-04899673",
  "title": "Verify the core office foundations, add mat wall dowels, and make development
  length a limit state", "type": "plan"}, {"id": "todo-86ac8265", "title": "B5 \u2014
  Hollow-core & precast plank floor sizing", "type": "todo"}, {"id": "chec-123913d0",
  "title": "Variant scenes are written, tested, and switchable in the viewer", "type":
  "checkpoint"}, {"id": "deci-251b85d0", "title": "Construction stage uses SEI/ASCE
  37-02 (flagged older edition); C_P defaults to medium duty 50 psf", "type": "decision"},
  {"id": "plan-11f26f2d", "title": "4. Capability roadmap \u2014 toward full building
  simulation (DOE typologies)", "type": "plan"}, {"id": "plan-a09110a3", "title":
  "Rich design archive so a scene can be rebuilt without re-running design", "type":
  "plan"}, {"id": "note-a5b7e562", "title": "Core office checks still open: wall-load
  ratio, column steel under 1%, service SPD warning", "type": "note"}, {"id": "todo-810324d4",
  "title": "H3 \u2014 Seismic detailing: AISC 341-16 capacity design + AISC 358 connections",
  "type": "todo"}, {"id": "deci-8e147ceb", "title": "Slab stores the column and wall
  tributary polygons, curves included", "type": "decision"}, {"id": "deci-cd0e9ce7",
  "title": "Wall slab area is the straight-skeleton edge polygon, not nearest-distance",
  "type": "decision"}, {"id": "note-b52eaf4b", "title": "Flexible diaphragm keeps
  each wall''s tributary complement", "type": "note"}, {"id": "deci-3d1e2fb1", "title":
  "Design the core-corner columns, and draw the stored tributary split", "type": "decision"},
  {"id": "chec-85eecada", "title": "Tributary profiles conserve net floor area, including
  openings", "type": "checkpoint"}, {"id": "deci-01b4dd14", "title": "Column keeps
  the larger region; the wall gets the complement, with exact quadratic fixed-end
  forces", "type": "decision"}, {"id": "note-d8c45f71", "title": "Grade wall bases
  are held only at grid support vertices", "type": "note"}, {"id": "deci-619a24bf",
  "title": "CompositeContext requirements: irregular tributary areas + manual override",
  "type": "decision"}, {"id": "chec-bb25c8fe", "title": "Detail sheet overlays the
  stored analysis colors", "type": "checkpoint"}, {"id": "deci-63970067", "title":
  "Wall footing architecture: legged rigid wall footings, cell mats with walls, fallback
  to Winkler", "type": "decision"}, {"id": "chec-02a852b1", "title": "Placed bars
  report both areas and stop at wall openings", "type": "checkpoint"}, {"id": "plan-94cccece",
  "title": "Slab visualization: sized section on the solver mid-plane", "type": "plan"},
  {"id": "plan-a0000005", "title": "Plots / Visualization / Studies", "type": "plan"},
  {"id": "deci-f3a4d0fd", "title": "Floor type sets reinforcement direction; framing
  sets the slab''s supports", "type": "decision"}, {"id": "plan-3986c866", "title":
  "Beams in the panel shell: whole-story model, offset webs, tributary beam design
  kept", "type": "plan"}, {"id": "note-5d07a70a", "title": "Rib-network frame exists;
  the slab panel is undesigned", "type": "note"}, {"id": "deci-8e83377c", "title":
  "Use each material density and store slab extras on the element volumes", "type":
  "decision"}, {"id": "deci-2941c900", "title": "Analysis slab stays on the architectural
  face; the column center stays inboard", "type": "decision"}, {"id": "todo-8f5ba09e",
  "title": "B3 \u2014 Waffle / joist-slab analysis & design pipeline", "type": "todo"},
  {"id": "todo-5b438560", "title": "B1 \u2014 One-way slab + supporting-beam sizing
  pipeline", "type": "todo"}, {"id": "deci-e75b0003", "title": "Plan review: span
  line and supports come first, and panels report not analyzed", "type": "decision"},
  {"id": "deci-46d3782b", "title": "Wall face shear, strip split, and short walls
  in direct design", "type": "decision"}, {"id": "plan-c8115994", "title": "Robust
  wall and core pipeline: flexible-floor decisions, walls as slab supports, thickness
  loop and speed, special walls", "type": "plan"}, {"id": "deci-2ce30b6f", "title":
  "Input lines are column centerlines; the slab edge extends to the largest column
  face on each exterior line", "type": "decision"}, {"id": "plan-66418349", "title":
  "General punching near openings: plan-frame sections, local column strips, drop-edge
  cut", "type": "plan"}, {"id": "expe-d1706e61", "title": "Open core floor: equivalent
  frame next to the shell", "type": "experiment"}]'
entries_modified: '[]'
---
session
Mat flexural development, and load the T-beam flange check that already exists (+1 more)
Auto-closed after topic shift. 2 created, 56 accessed.
Mat flexural development, and load the T-beam flange check that already exists Incremental walls see a thickness change; diagnose the two flat-plate test failures Close the wall-support gaps: support moments, wall out-of-plane, openings, flexible diaphragm Wall moment is no longer labeled as a column moment Phase 3 — Wall + wall-result data model Wall supports in direct design and the equivalent frame Wall-end punching, §13.7 refusal, and Table 9.5(c) at a wall Ordinary-wall stage in design_building for one isolated pier Phase 3 implementation: wall storage, :walls member init, enclosure at initialize! Grade wall bases are fixed in all six degrees of freedom Walls as slab supports: open core gap, support list, FEA wall supports, DDM spans/moments, load split, punching at wall ends design_building runs ordinary-wall checks when lateral design is requested Core foundation seam: rigid mat restrains the wall base; reactions go to the existing mat Footing flexure must be tension-controlled; failed checks are violations or errors, not warnings Low-rise spread buildings may add a rigid mat under the core as one strategy Commit audit correctness fixes: tension-controlled flexure and fail-closed checks Faster sizing convergence: spread bisection, mat hoist, warm starts Split foundation utilities into focused move-only files Default: grade core walls share a mat; an isolated wall gets a strip footing Write AISC 360-16 §F4; the long-span fire-rating beam stays failing A door or window does not open a cell; the mat still covers that wall Coordinated: flat-plate col_I_factor SSoT across FEA+EFM — [eng] sync+efm edit, [rev] blind, [crit] adversarial, [test] gate, [mem] record Saved core office design is archive version 1 and the current code cannot read it Node rotations stay out of the scene; the design archive does not store them either Verify the core office foundations, add mat wall dowels, and make development length a limit state B5 — Hollow-core & precast plank floor sizing Variant scenes are written, tested, and switchable in the viewer Construction stage uses SEI/ASCE 37-02 (flagged older edition); C_P defaults to medium duty 50 psf 4. Capability roadmap — toward full building simulation (DOE typologies) Rich design archive so a scene can be rebuilt without re-running design Core office checks still open: wall-load ratio, column steel under 1%, service SPD warning H3 — Seismic detailing: AISC 341-16 capacity design + AISC 358 connections Slab stores the column and wall tributary polygons, curves included Wall slab area is the straight-skeleton edge polygon, not nearest-distance Flexible diaphragm keeps each wall's tributary complement Design the core-corner columns, and draw the stored tributary split Tributary profiles conserve net floor area, including openings Column keeps the larger region; the wall gets the complement, with exact quadratic fixed-end forces Grade wall bases are held only at grid support vertices CompositeContext requirements: irregular tributary areas + manual override Detail sheet overlays the stored analysis colors Wall footing architecture: legged rigid wall footings, cell mats with walls, fallback to Winkler Placed bars report both areas and stop at wall openings Slab visualization: sized section on the solver mid-plane Plots / Visualization / Studies Floor type sets reinforcement direction; framing sets the slab's supports Beams in the panel shell: whole-story model, offset webs, tributary beam design kept Rib-network frame exists; the slab panel is undesigned Use each material density and store slab extras on the element volumes Analysis slab stays on the architectural face; the column center stays inboard B3 — Waffle / joist-slab analysis & design pipeline B1 — One-way slab + supporting-beam sizing pipeline Plan review: span line and supports come first, and panels report not analyzed Wall face shear, strip split, and short walls in direct design Robust wall and core pipeline: flexible-floor decisions, walls as slab supports, thickness loop and speed, special walls Input lines are column centerlines; the slab edge extends to the largest column face on each exterior line General punching near openings: plan-frame sections, local column strips, drop-edge cut Open core floor: equivalent frame next to the shell
