---
id: sess-a28c7ea7
project: menegroth
started_at: '2026-10-26T20:07:46.448797+00:00'
ended_at: '2026-10-26T20:43:51.042857+00:00'
title: ASCE 7-22 strength combinations use 0.3S, 0.15S, and separate Ev (+1 more)
summary: 'ASCE 7-22 strength combinations use 0.3S, 0.15S, and separate Ev (+1 more)

  Auto-closed after topic shift. 2 created, 29 accessed.'
kind: session
entries_created: '[{"id": "deci-bbb47b20", "title": "ASCE 7-22 strength combinations
  use 0.3S, 0.15S, and separate Ev", "type": "decision"}, {"id": "plan-4b6f6344",
  "title": "Phase 7 wall demand plan: pier/assembly identity, free-body cuts, equilibrium
  gates, basic-case combinations", "type": "plan"}]'
entries_accessed: '[{"id": "anno-29c4a332", "title": "P0 (pre-existing): column_I_factor
  + beam_I_factor unregistered with incremental engine \u2014 default REST /design
  path silently drops the knob, returns stale 0.70 design", "type": "annotation"},
  {"id": "deci-8299ff3e", "title": "Threaded ACI 318-11 \u00a710.10.4.1 cracking factors
  (beam_I_factor/column_I_factor) end-to-end; knobs now honored, byte-exact no-op
  at defaults", "type": "decision"}, {"id": "todo-b31bdd84", "title": "Coordinated:
  flat-plate col_I_factor SSoT across FEA+EFM \u2014 [eng] sync+efm edit, [rev] blind,
  [crit] adversarial, [test] gate, [mem] record", "type": "todo"}, {"id": "expe-213d6f86",
  "title": "FEA unbalanced moment: point-node stub + flexible column patch is mesh-dependent
  and ~2x lower at edge columns than a rigid footprint", "type": "experiment"}, {"id":
  "deci-f53d6337", "title": "Resolved deferred I_factor decisions: flat-plate SSoT
  = sync BOTH FEA+EFM (incl. StructuralSizer efm.jl); FRC/PixelFrame = HOLD (no RC
  knob without fib basis)", "type": "decision"}, {"id": "chec-9b29a05a", "title":
  "Change 1 COMPLETE (GREEN): flat-plate col_I_factor is now a Single Source of Truth
  across FEA + EFM + incremental engine \u2014 gate 49/49", "type": "checkpoint"},
  {"id": "chec-13346513", "title": "Pre-cure moment scales the uniform analysis dead-load
  field", "type": "checkpoint"}, {"id": "note-28c24a30", "title": "Code-steward close-out
  verdict: gravity consolidation SOUND (citations + SSoT owners verified); FAIL on
  1 introduced P1 (\u00a713.5.3 transfer-reinf assembly duplicated) + 1 P2 (col_I_factor
  silent overwrite) \u2192 folded into pre-ribbed", "type": "note"}, {"id": "deci-b2d74031",
  "title": "Scoped floor-overrides INHERIT params.column_I_factor \u2014 col_I_factor
  is a column-type property, orthogonal to floor-zone system", "type": "decision"},
  {"id": "plan-6fa91d7d", "title": "Phase 7 scope: one ordinary wall, analyzed demands,
  existing checks", "type": "plan"}, {"id": "todo-w0000004", "title": "S3: FEM lateral
  analysis (Asap vertical wall shells + diaphragms)", "type": "todo"}, {"id": "chec-028f596c",
  "title": "Phase 5c: _mesh_wall_shells validated vs isolated FEMLateralEvaluator
  (exact under matched diaphragm)", "type": "checkpoint"}, {"id": "deci-2c1bee70",
  "title": "Phase 6 open decision: which diaphragm model governs wall drift (true
  rigid link vs FEM stiff-shell)", "type": "decision"}, {"id": "chec-2d7f148e", "title":
  "Phase 5d: stiffness token witnesses wall shell geometry (loads_only cannot go stale)",
  "type": "checkpoint"}, {"id": "chec-1f998dac", "title": "Walls assemble into the
  building model without invented supports", "type": "checkpoint"}, {"id": "todo-6a3aad1a",
  "title": "Phase 5 \u2014 Unified Asap frame-shell model", "type": "todo"}, {"id":
  "todo-5b263929", "title": "Phase 3 \u2014 Wall + wall-result data model", "type":
  "todo"}, {"id": "anno-72358c23", "title": "Asap.Model does not unique duplicate
  Node objects \u2014 orphan free DOFs", "type": "annotation"}, {"id": "chec-6e06a1aa",
  "title": "Commit: ASCE 7-22 diaphragm idealizations and FEM rigid-link mode", "type":
  "checkpoint"}, {"id": "plan-a2a6128f", "title": "Plan: complete concrete wall system
  (unified frame-shell, ASCE 7-22, performance-aware)", "type": "plan"}, {"id": "expe-8e19c706",
  "title": "Section-cut fix vs StructurePoint: DDM matches; rigid FEA doubles exterior
  M- and agrees with a 0.15 m mesh on transfer moments", "type": "experiment"}, {"id":
  "chec-8b9b7f71", "title": "Asr is the steel at one section inside the effective
  width", "type": "checkpoint"}, {"id": "plan-779905d4", "title": "Slab thickness
  study: consistent deflection reporting, pattern loading, and the 5 in floor", "type":
  "plan"}, {"id": "plan-d72e497e", "title": "Flat-plate sizing speed-up plan (journal-paper
  solver time)", "type": "plan"}, {"id": "expe-b14193ea", "title": "FEA flat-plate
  mesh convergence: M\u207b mesh dependence is from section-cut band \u03b4=max(3h,c),
  not the FE field", "type": "experiment"}, {"id": "note-7de9d402", "title": "Defect
  4: shared punching_check ignores unbalanced moment at corner columns", "type": "note"},
  {"id": "deci-0bd60d85", "title": "Final fix round scope: judgment-call resolutions,
  full suites, trace audit, later citation sweep", "type": "decision"}, {"id": "deci-009b31dd",
  "title": "Concrete T-beams use the steel per-station flange width", "type": "decision"},
  {"id": "plan-93430266", "title": "Wave 3: flat-plate column grouping (D-series)
  \u2014 revised scope", "type": "plan"}]'
entries_modified: '[]'
---
session
ASCE 7-22 strength combinations use 0.3S, 0.15S, and separate Ev (+1 more)
Auto-closed after topic shift. 2 created, 29 accessed.
ASCE 7-22 strength combinations use 0.3S, 0.15S, and separate Ev Phase 7 wall demand plan: pier/assembly identity, free-body cuts, equilibrium gates, basic-case combinations P0 (pre-existing): column_I_factor + beam_I_factor unregistered with incremental engine — default REST /design path silently drops the knob, returns stale 0.70 design Threaded ACI 318-11 §10.10.4.1 cracking factors (beam_I_factor/column_I_factor) end-to-end; knobs now honored, byte-exact no-op at defaults Coordinated: flat-plate col_I_factor SSoT across FEA+EFM — [eng] sync+efm edit, [rev] blind, [crit] adversarial, [test] gate, [mem] record FEA unbalanced moment: point-node stub + flexible column patch is mesh-dependent and ~2x lower at edge columns than a rigid footprint Resolved deferred I_factor decisions: flat-plate SSoT = sync BOTH FEA+EFM (incl. StructuralSizer efm.jl); FRC/PixelFrame = HOLD (no RC knob without fib basis) Change 1 COMPLETE (GREEN): flat-plate col_I_factor is now a Single Source of Truth across FEA + EFM + incremental engine — gate 49/49 Pre-cure moment scales the uniform analysis dead-load field Code-steward close-out verdict: gravity consolidation SOUND (citations + SSoT owners verified); FAIL on 1 introduced P1 (§13.5.3 transfer-reinf assembly duplicated) + 1 P2 (col_I_factor silent overwrite) → folded into pre-ribbed Scoped floor-overrides INHERIT params.column_I_factor — col_I_factor is a column-type property, orthogonal to floor-zone system Phase 7 scope: one ordinary wall, analyzed demands, existing checks S3: FEM lateral analysis (Asap vertical wall shells + diaphragms) Phase 5c: _mesh_wall_shells validated vs isolated FEMLateralEvaluator (exact under matched diaphragm) Phase 6 open decision: which diaphragm model governs wall drift (true rigid link vs FEM stiff-shell) Phase 5d: stiffness token witnesses wall shell geometry (loads_only cannot go stale) Walls assemble into the building model without invented supports Phase 5 — Unified Asap frame-shell model Phase 3 — Wall + wall-result data model Asap.Model does not unique duplicate Node objects — orphan free DOFs Commit: ASCE 7-22 diaphragm idealizations and FEM rigid-link mode Plan: complete concrete wall system (unified frame-shell, ASCE 7-22, performance-aware) Section-cut fix vs StructurePoint: DDM matches; rigid FEA doubles exterior M- and agrees with a 0.15 m mesh on transfer moments Asr is the steel at one section inside the effective width Slab thickness study: consistent deflection reporting, pattern loading, and the 5 in floor Flat-plate sizing speed-up plan (journal-paper solver time) FEA flat-plate mesh convergence: M⁻ mesh dependence is from section-cut band δ=max(3h,c), not the FE field Defect 4: shared punching_check ignores unbalanced moment at corner columns Final fix round scope: judgment-call resolutions, full suites, trace audit, later citation sweep Concrete T-beams use the steel per-station flange width Wave 3: flat-plate column grouping (D-series) — revised scope
