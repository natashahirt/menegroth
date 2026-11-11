---
id: sess-f89cd62c
project: menegroth
started_at: '2026-11-08T21:29:44.518080+00:00'
ended_at: '2026-11-08T22:21:24.292453+00:00'
title: Solid heads, punching, rib deflection, NLP ribs, API counts, and bar takeoff
  (+2 more)
summary: 'Solid heads, punching, rib deflection, NLP ribs, API counts, and bar takeoff
  (+2 more)

  Auto-closed after topic shift. 3 created, 19 accessed.'
kind: session
entries_created: '[{"id": "plan-0e3e4710", "title": "Solid heads, punching, rib deflection,
  NLP ribs, API counts, and bar takeoff", "type": "plan"}, {"id": "deci-f4b19375",
  "title": "Punching outside a solid head uses rib webs plus one-way rib shear; the
  1.10 factor is one-way only", "type": "decision"}, {"id": "note-bcccfa14", "title":
  "Drop-panel size and rib deflection stiffness, ACI 318-11", "type": "note"}]'
entries_accessed: '[{"id": "chec-0482ba24", "title": "3x3 individual FEA plate finishes
  after columns reach the size cap", "type": "checkpoint"}, {"id": "deci-639b8726",
  "title": "A column on a wall line is not a member; the wall carries that slab",
  "type": "decision"}, {"id": "deci-b2d74031", "title": "Scoped floor-overrides INHERIT
  params.column_I_factor \u2014 col_I_factor is a column-type property, orthogonal
  to floor-zone system", "type": "decision"}, {"id": "chec-9b29a05a", "title": "Change
  1 COMPLETE (GREEN): flat-plate col_I_factor is now a Single Source of Truth across
  FEA + EFM + incremental engine \u2014 gate 49/49", "type": "checkpoint"}, {"id":
  "plan-93430266", "title": "Wave 3: flat-plate column grouping (D-series) \u2014
  revised scope", "type": "plan"}, {"id": "note-5422387f", "title": "Wall moment is
  no longer labeled as a column moment", "type": "note"}, {"id": "deci-e9ea33af",
  "title": "Beamless two-way becomes a flat plate; a broken beam grid throws", "type":
  "decision"}, {"id": "expe-d1706e61", "title": "Open core floor: equivalent frame
  next to the shell", "type": "experiment"}, {"id": "plan-7f7bfe8c", "title": "Walls
  as slab supports: open core gap, support list, FEA wall supports, DDM spans/moments,
  load split, punching at wall ends", "type": "plan"}, {"id": "deci-d259f689", "title":
  "Shared-column floors size in two levels", "type": "decision"}, {"id": "deci-1d3a040b",
  "title": "Columns and walls share each cell''s straight-skeleton edge polygons",
  "type": "decision"}, {"id": "deci-cd0e9ce7", "title": "Wall slab area is the straight-skeleton
  edge polygon, not nearest-distance", "type": "decision"}, {"id": "deci-8e147ceb",
  "title": "Slab stores the column and wall tributary polygons, curves included",
  "type": "decision"}, {"id": "deci-3d1e2fb1", "title": "Design the core-corner columns,
  and draw the stored tributary split", "type": "decision"}, {"id": "deci-2ce30b6f",
  "title": "Input lines are column centerlines; the slab edge extends to the largest
  column face on each exterior line", "type": "decision"}, {"id": "deci-01b4dd14",
  "title": "Column keeps the larger region; the wall gets the complement, with exact
  quadratic fixed-end forces", "type": "decision"}, {"id": "chec-9feee89e", "title":
  "Step 3: a bay left out of the face polygons is a courtyard", "type": "checkpoint"},
  {"id": "plan-b6ff71fd", "title": "Phase 3 implementation: wall storage, :walls member
  init, enclosure at initialize!", "type": "plan"}, {"id": "deci-8c540598", "title":
  "Park the office core-corner columns in the absent group", "type": "decision"}]'
entries_modified: '[]'
---
session
Solid heads, punching, rib deflection, NLP ribs, API counts, and bar takeoff (+2 more)
Auto-closed after topic shift. 3 created, 19 accessed.
Solid heads, punching, rib deflection, NLP ribs, API counts, and bar takeoff Punching outside a solid head uses rib webs plus one-way rib shear; the 1.10 factor is one-way only Drop-panel size and rib deflection stiffness, ACI 318-11 3x3 individual FEA plate finishes after columns reach the size cap A column on a wall line is not a member; the wall carries that slab Scoped floor-overrides INHERIT params.column_I_factor — col_I_factor is a column-type property, orthogonal to floor-zone system Change 1 COMPLETE (GREEN): flat-plate col_I_factor is now a Single Source of Truth across FEA + EFM + incremental engine — gate 49/49 Wave 3: flat-plate column grouping (D-series) — revised scope Wall moment is no longer labeled as a column moment Beamless two-way becomes a flat plate; a broken beam grid throws Open core floor: equivalent frame next to the shell Walls as slab supports: open core gap, support list, FEA wall supports, DDM spans/moments, load split, punching at wall ends Shared-column floors size in two levels Columns and walls share each cell's straight-skeleton edge polygons Wall slab area is the straight-skeleton edge polygon, not nearest-distance Slab stores the column and wall tributary polygons, curves included Design the core-corner columns, and draw the stored tributary split Input lines are column centerlines; the slab edge extends to the largest column face on each exterior line Column keeps the larger region; the wall gets the complement, with exact quadratic fixed-end forces Step 3: a bay left out of the face polygons is a courtyard Phase 3 implementation: wall storage, :walls member init, enclosure at initialize! Park the office core-corner columns in the absent group
