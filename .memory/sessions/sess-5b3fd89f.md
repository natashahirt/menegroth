---
id: sess-5b3fd89f
project: menegroth
started_at: '2026-11-03T12:29:25.195607+00:00'
ended_at: '2026-11-03T16:05:36.297761+00:00'
title: Drop-edge punching uses the clipped drop outline for every column (+2 more)
summary: 'Drop-edge punching uses the clipped drop outline for every column (+2 more)

  Auto-closed after inactivity. 3 created, 29 accessed.'
kind: session
entries_created: '[{"id": "deci-b0702614", "title": "Drop-edge punching uses the clipped
  drop outline for every column", "type": "decision"}, {"id": "deci-9d0e38ed", "title":
  "Shell drop patch is the clipped drop outline", "type": "decision"}, {"id": "plan-3986c866",
  "title": "Beams in the panel shell: whole-story model, offset webs, tributary beam
  design kept", "type": "plan"}]'
entries_accessed: '[{"id": "plan-b6ff71fd", "title": "Phase 3 implementation: wall
  storage, :walls member init, enclosure at initialize!", "type": "plan"}, {"id":
  "todo-5b263929", "title": "Phase 3 \u2014 Wall + wall-result data model", "type":
  "todo"}, {"id": "plan-6fa91d7d", "title": "Phase 7 scope: one ordinary wall, analyzed
  demands, existing checks", "type": "plan"}, {"id": "deci-fe873f83", "title": "Wall
  storage, :walls initialization, and nearest-elevation story matching", "type": "decision"},
  {"id": "todo-2f10ae03", "title": "FOLLOW-UP p11-followup-orthogonal-l2-axis: default
  level-N joist axis rotation", "type": "todo"}, {"id": "chec-63a9c0fb", "title":
  "Phase 7 demand slice: extra wind directions, combination factors, seismic drift
  check", "type": "checkpoint"}, {"id": "deci-bf3759a9", "title": "Wall groups share
  a mark only when the reinforcement matches", "type": "decision"}, {"id": "plan-b45b0d7f",
  "title": "Ordinary-wall stage in design_building for one isolated pier", "type":
  "plan"}, {"id": "chec-1f998dac", "title": "Walls assemble into the building model
  without invented supports", "type": "checkpoint"}, {"id": "deci-7144bc3d", "title":
  "Two-way ln is the long span along the reinforcement axes; steel \u03b1f follows
  composite action", "type": "decision"}, {"id": "plan-66418349", "title": "General
  punching near openings: plan-frame sections, local column strips, drop-edge cut",
  "type": "plan"}, {"id": "note-335a8cee", "title": "OPEN DESIGN Q: edge-column punching
  uses governing max(|Mux|,|Muy|), not additive biaxial \u2014 less conservative",
  "type": "note"}, {"id": "note-4bd021ce", "title": "Critic findings on committed
  Defect 4 punching: [P1] edge governing-max unconservative (ACI silent on biaxial),
  [P1] centroid eccentricity e off by d/2 vs cited spSlab example", "type": "note"},
  {"id": "chec-de1ad096", "title": "Stud objective uses the designed count; transverse
  cover is a hard check", "type": "checkpoint"}, {"id": "todo-e903a5ae", "title":
  "Todo: Fix face-vertex topology bug during framing edge-splitting", "type": "todo"},
  {"id": "chec-f716673e", "title": "Corner-punching oracle green: 3x3 spans, method-matched
  DDM, 85/85", "type": "checkpoint"}, {"id": "expe-213d6f86", "title": "FEA unbalanced
  moment: point-node stub + flexible column patch is mesh-dependent and ~2x lower
  at edge columns than a rigid footprint", "type": "experiment"}, {"id": "deci-209e1f2f",
  "title": "General corner critical section via half-plane clipping: handles any free-edge
  angle, fixes re-entrant b0 over-count, conservative transfer sign", "type": "decision"},
  {"id": "deci-525bb8d3", "title": "Column :corner means two non-collinear free edges,
  not two graph edges", "type": "decision"}, {"id": "deci-351c8ff9", "title": "A non-rectangular
  panel uses the existing area shell", "type": "decision"}, {"id": "deci-e75b0003",
  "title": "Plan review: span line and supports come first, and panels report not
  analyzed", "type": "decision"}, {"id": "plan-c7b78612", "title": "One-way panel:
  shared checks, then coefficients, strip, and shell", "type": "plan"}, {"id": "deci-95394b04",
  "title": "Two-way on beams: beams go in the shell, DDM beam cases come next, and
  thickness is fixed", "type": "decision"}, {"id": "chec-2d7f148e", "title": "Phase
  5d: stiffness token witnesses wall shell geometry (loads_only cannot go stale)",
  "type": "checkpoint"}, {"id": "todo-w0000004", "title": "S3: FEM lateral analysis
  (Asap vertical wall shells + diaphragms)", "type": "todo"}, {"id": "plan-35f67705",
  "title": "Floor coverage: beamless, steel deck, then concrete ribs", "type": "plan"},
  {"id": "expe-6a5c4d65", "title": "Equilibrated drilling penalty passes shell oracles
  and wall story cuts", "type": "experiment"}, {"id": "note-5d07a70a", "title": "Rib-network
  frame exists; the slab panel is undesigned", "type": "note"}, {"id": "todo-da4af973",
  "title": "B2 \u2014 Two-way (beam-supported) slab sizing pipeline", "type": "todo"}]'
entries_modified: '[]'
---
session
Drop-edge punching uses the clipped drop outline for every column (+2 more)
Auto-closed after inactivity. 3 created, 29 accessed.
Drop-edge punching uses the clipped drop outline for every column Shell drop patch is the clipped drop outline Beams in the panel shell: whole-story model, offset webs, tributary beam design kept Phase 3 implementation: wall storage, :walls member init, enclosure at initialize! Phase 3 — Wall + wall-result data model Phase 7 scope: one ordinary wall, analyzed demands, existing checks Wall storage, :walls initialization, and nearest-elevation story matching FOLLOW-UP p11-followup-orthogonal-l2-axis: default level-N joist axis rotation Phase 7 demand slice: extra wind directions, combination factors, seismic drift check Wall groups share a mark only when the reinforcement matches Ordinary-wall stage in design_building for one isolated pier Walls assemble into the building model without invented supports Two-way ln is the long span along the reinforcement axes; steel αf follows composite action General punching near openings: plan-frame sections, local column strips, drop-edge cut OPEN DESIGN Q: edge-column punching uses governing max(|Mux|,|Muy|), not additive biaxial — less conservative Critic findings on committed Defect 4 punching: [P1] edge governing-max unconservative (ACI silent on biaxial), [P1] centroid eccentricity e off by d/2 vs cited spSlab example Stud objective uses the designed count; transverse cover is a hard check Todo: Fix face-vertex topology bug during framing edge-splitting Corner-punching oracle green: 3x3 spans, method-matched DDM, 85/85 FEA unbalanced moment: point-node stub + flexible column patch is mesh-dependent and ~2x lower at edge columns than a rigid footprint General corner critical section via half-plane clipping: handles any free-edge angle, fixes re-entrant b0 over-count, conservative transfer sign Column :corner means two non-collinear free edges, not two graph edges A non-rectangular panel uses the existing area shell Plan review: span line and supports come first, and panels report not analyzed One-way panel: shared checks, then coefficients, strip, and shell Two-way on beams: beams go in the shell, DDM beam cases come next, and thickness is fixed Phase 5d: stiffness token witnesses wall shell geometry (loads_only cannot go stale) S3: FEM lateral analysis (Asap vertical wall shells + diaphragms) Floor coverage: beamless, steel deck, then concrete ribs Equilibrated drilling penalty passes shell oracles and wall story cuts Rib-network frame exists; the slab panel is undesigned B2 — Two-way (beam-supported) slab sizing pipeline
