---
id: sess-6e64c23b
project: menegroth
started_at: '2026-11-08T23:36:38.849728+00:00'
ended_at: '2026-11-09T00:02:41.160960+00:00'
title: Column sizing cleanups done before v7
summary: 'Column sizing cleanups done before v7

  Auto-closed after topic shift. 1 created, 20 accessed.'
kind: session
entries_created: '[{"id": "chec-0a276e4e", "title": "Column sizing cleanups done before
  v7", "type": "checkpoint"}]'
entries_accessed: '[{"id": "deci-1d3a040b", "title": "Columns and walls share each
  cell''s straight-skeleton edge polygons", "type": "decision"}, {"id": "deci-f4db3f27",
  "title": "Flat plates raise \u03b3f by ACI 318-11 \u00a713.5.3.3 (a) and (b) at
  the column face, on by default", "type": "decision"}, {"id": "expe-213d6f86", "title":
  "FEA unbalanced moment: point-node stub + flexible column patch is mesh-dependent
  and ~2x lower at edge columns than a rigid footprint", "type": "experiment"}, {"id":
  "note-335a8cee", "title": "OPEN DESIGN Q: edge-column punching uses governing max(|Mux|,|Muy|),
  not additive biaxial \u2014 less conservative", "type": "note"}, {"id": "todo-e903a5ae",
  "title": "Todo: Fix face-vertex topology bug during framing edge-splitting", "type":
  "todo"}, {"id": "deci-525bb8d3", "title": "Column :corner means two non-collinear
  free edges, not two graph edges", "type": "decision"}, {"id": "expe-2c5f64c8", "title":
  "Seed Asap solve: poker DL+edge and dining DL+edge (struts)", "type": "experiment"},
  {"id": "deci-2ce30b6f", "title": "Input lines are column centerlines; the slab edge
  extends to the largest column face on each exterior line", "type": "decision"},
  {"id": "note-4bd021ce", "title": "Critic findings on committed Defect 4 punching:
  [P1] edge governing-max unconservative (ACI silent on biaxial), [P1] centroid eccentricity
  e off by d/2 vs cited spSlab example", "type": "note"}, {"id": "deci-209e1f2f",
  "title": "General corner critical section via half-plane clipping: handles any free-edge
  angle, fixes re-entrant b0 over-count, conservative transfer sign", "type": "decision"},
  {"id": "plan-0e3e4710", "title": "Solid heads, punching, rib deflection, NLP ribs,
  API counts, and bar takeoff", "type": "plan"}, {"id": "deci-f4b19375", "title":
  "Punching outside a solid head uses rib webs plus one-way rib shear; the 1.10 factor
  is one-way only", "type": "decision"}, {"id": "note-bcccfa14", "title": "Drop-panel
  size and rib deflection stiffness, ACI 318-11", "type": "note"}, {"id": "deci-61ec0b4b",
  "title": "Solid-head mass is the projection below the topping", "type": "decision"},
  {"id": "plan-35f67705", "title": "Floor coverage: beamless, steel deck, then concrete
  ribs", "type": "plan"}, {"id": "plan-66418349", "title": "General punching near
  openings: plan-frame sections, local column strips, drop-edge cut", "type": "plan"},
  {"id": "deci-f3a4d0fd", "title": "Floor type sets reinforcement direction; framing
  sets the slab''s supports", "type": "decision"}, {"id": "plan-94cccece", "title":
  "Slab visualization: sized section on the solver mid-plane", "type": "plan"}, {"id":
  "plan-159c1800", "title": "Flat-plate sizing without the ratchet: slab thickness
  is the outer search, columns re-derived at each thickness", "type": "plan"}, {"id":
  "deci-b0702614", "title": "Drop-edge punching uses the clipped drop outline for
  every column", "type": "decision"}]'
entries_modified: '[]'
---
session
Column sizing cleanups done before v7
Auto-closed after topic shift. 1 created, 20 accessed.
Column sizing cleanups done before v7 Columns and walls share each cell's straight-skeleton edge polygons Flat plates raise γf by ACI 318-11 §13.5.3.3 (a) and (b) at the column face, on by default FEA unbalanced moment: point-node stub + flexible column patch is mesh-dependent and ~2x lower at edge columns than a rigid footprint OPEN DESIGN Q: edge-column punching uses governing max(|Mux|,|Muy|), not additive biaxial — less conservative Todo: Fix face-vertex topology bug during framing edge-splitting Column :corner means two non-collinear free edges, not two graph edges Seed Asap solve: poker DL+edge and dining DL+edge (struts) Input lines are column centerlines; the slab edge extends to the largest column face on each exterior line Critic findings on committed Defect 4 punching: [P1] edge governing-max unconservative (ACI silent on biaxial), [P1] centroid eccentricity e off by d/2 vs cited spSlab example General corner critical section via half-plane clipping: handles any free-edge angle, fixes re-entrant b0 over-count, conservative transfer sign Solid heads, punching, rib deflection, NLP ribs, API counts, and bar takeoff Punching outside a solid head uses rib webs plus one-way rib shear; the 1.10 factor is one-way only Drop-panel size and rib deflection stiffness, ACI 318-11 Solid-head mass is the projection below the topping Floor coverage: beamless, steel deck, then concrete ribs General punching near openings: plan-frame sections, local column strips, drop-edge cut Floor type sets reinforcement direction; framing sets the slab's supports Slab visualization: sized section on the solver mid-plane Flat-plate sizing without the ratchet: slab thickness is the outer search, columns re-derived at each thickness Drop-edge punching uses the clipped drop outline for every column
