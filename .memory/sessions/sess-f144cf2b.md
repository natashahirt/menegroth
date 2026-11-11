---
id: sess-f144cf2b
project: menegroth
started_at: '2026-10-26T17:14:51.743870+00:00'
ended_at: '2026-10-26T17:26:53.751342+00:00'
title: Revisit iterative sizing when perimeter frames or braces are added
summary: 'Revisit iterative sizing when perimeter frames or braces are added

  Auto-closed after topic shift. 1 created, 1 modified, 45 accessed.'
kind: session
entries_created: '[{"id": "note-8072f72a", "title": "Revisit iterative sizing when
  perimeter frames or braces are added", "type": "note"}]'
entries_accessed: '[{"id": "todo-a398f5f2", "title": "Phase 6 \u2014 ASCE 7-22 lateral
  demand", "type": "todo"}, {"id": "todo-76ac2b1c", "title": "E7 \u2014 Ingest & wire
  full ASCE 7-22 wind/seismic/snow provisions", "type": "todo"}, {"id": "plan-68155c81",
  "title": "Phase A \u2014 Analysis engine: loads, load paths, lateral & serviceability",
  "type": "plan"}, {"id": "todo-2d975e87", "title": "A3.1 \u2014 Wind MWFRS pressures
  \u2192 story forces (ASCE 7 Ch. 26\u201330)", "type": "todo"}, {"id": "deci-61485816",
  "title": "Phase 6d applies seismic ELF to rigid-diaphragm masters; wind and geometric
  P-delta stay out", "type": "decision"}, {"id": "chec-b73d936d", "title": "ELF drift
  load, story shear, and corrected NEHRP oracles checked", "type": "checkpoint"},
  {"id": "todo-7ac493eb", "title": "Still deferred: Phase 3/6 bridge wiring and ASCE
  7-22 \u00a712.7.2 seismic weight", "type": "todo"}, {"id": "chec-3262f25a", "title":
  "Phase 2: unshored composite beams checked under SEI/ASCE 37-02 pre-cure load",
  "type": "checkpoint"}, {"id": "todo-4a0fbdd0", "title": "A8 \u2014 Consolidated
  serviceability suite (drift, deflection, vibration, long-term, crack control)",
  "type": "todo"}, {"id": "todo-310559df", "title": "A3 \u2014 ASCE 7 lateral demand
  generation (wind pressures + seismic) & diaphragm assembly", "type": "todo"}, {"id":
  "chec-1f998dac", "title": "Walls assemble into the building model without invented
  supports", "type": "checkpoint"}, {"id": "todo-2c5824f0", "title": "D3 \u2014 Masonry
  (TMS 402): CMU/brick bearing & shear walls, lintels", "type": "todo"}, {"id": "plan-77fbce0e",
  "title": "Phase D \u2014 Members, walls, light framing & new material systems",
  "type": "plan"}, {"id": "plan-d0c5bff3", "title": "Phase 5 layout: four runs from
  frame placeholders to one frame-shell model", "type": "plan"}, {"id": "chec-186cbf54",
  "title": "Phase 5b shells in, stopped on an upper-floor fixity P1", "type": "checkpoint"},
  {"id": "note-be7048ad", "title": "crit8 (P1): enclosure guard checks wall CENTROID,
  not body \u2014 endpoint overhang flips solve_wall_layout to feasible=TRUE at 1.18\u00b7DL",
  "type": "note"}, {"id": "todo-e56a47f1", "title": "D2.3 \u2014 CFS shear walls /
  lateral (AISI S400 sheathed-wall tables)", "type": "todo"}, {"id": "deci-w0000006",
  "title": "Decision: design the wall/lateral stack for efficient layout optimization
  upfront", "type": "decision"}, {"id": "plan-a2a6128f", "title": "Plan: complete
  concrete wall system (unified frame-shell, ASCE 7-22, performance-aware)", "type":
  "plan"}, {"id": "deci-cc000003", "title": "BuildingStructure (reusable) vs BuildingDesign
  (per param set); snapshot/restore", "type": "decision"}, {"id": "anno-29c4a332",
  "title": "P0 (pre-existing): column_I_factor + beam_I_factor unregistered with incremental
  engine \u2014 default REST /design path silently drops the knob, returns stale 0.70
  design", "type": "annotation"}, {"id": "deci-8299ff3e", "title": "Threaded ACI 318-11
  \u00a710.10.4.1 cracking factors (beam_I_factor/column_I_factor) end-to-end; knobs
  now honored, byte-exact no-op at defaults", "type": "decision"}, {"id": "plan-f6511c0b",
  "title": "Run 5 / Phase B: activate per-group overrides in the real pipeline (de-risk
  first)", "type": "plan"}, {"id": "deci-c6a62e21", "title": "Phase B build scope
  refined by recon2: minimal StructuralSizer feasible kwarg + steel-beam-only + conditional
  guard", "type": "decision"}, {"id": "todo-5b438560", "title": "B1 \u2014 One-way
  slab + supporting-beam sizing pipeline", "type": "todo"}, {"id": "todo-da4af973",
  "title": "B2 \u2014 Two-way (beam-supported) slab sizing pipeline", "type": "todo"},
  {"id": "plan-a0000003", "title": "StructuralSizer - sizing & design codes", "type":
  "plan"}, {"id": "plan-a0000005", "title": "Plots / Visualization / Studies", "type":
  "plan"}, {"id": "deci-1ccd0262", "title": "A1 reverted: loads_only=true swap in
  _solve_load_case! kept for a future paired-solve investigation", "type": "decision"},
  {"id": "chec-896de033", "title": "Phase 2 framing and project configuration progress",
  "type": "checkpoint"}, {"id": "plan-93ed2402", "title": "Plan: Integrate Phase 5
  Framing Population", "type": "plan"}, {"id": "chec-b956583b", "title": "Phase 5
  Framing Integration Complete (with follow-up bug identified)", "type": "checkpoint"},
  {"id": "plan-ad399e86", "title": "Framing load-path fidelity + waffle via integrated
  ribs", "type": "plan"}, {"id": "chec-h0000002", "title": "Epoch 1: Origins - building
  geometry & face-finding (Dec 2025)", "type": "checkpoint"}, {"id": "deci-5439ec6a",
  "title": "Framed-slab load routing: strip fast-path restricted to true joist-frame
  rectangles (per-member exact)", "type": "decision"}, {"id": "deci-b2d74031", "title":
  "Scoped floor-overrides INHERIT params.column_I_factor \u2014 col_I_factor is a
  column-type property, orthogonal to floor-zone system", "type": "decision"}, {"id":
  "plan-93430266", "title": "Wave 3: flat-plate column grouping (D-series) \u2014
  revised scope", "type": "plan"}, {"id": "note-cb000002", "title": "StructuralSizer
  design-code coverage map", "type": "note"}, {"id": "todo-8f5ba09e", "title": "B3
  \u2014 Waffle / joist-slab analysis & design pipeline", "type": "todo"}, {"id":
  "todo-dd3699c1", "title": "Waffle rib grid first-cut + integrated T-beam ribs",
  "type": "todo"}, {"id": "todo-4691abda", "title": "B7 \u2014 One-way joist / pan-joist
  (ribbed) slab (ACI 318 \u00a78.13 / 318-19 \u00a79.8)", "type": "todo"}, {"id":
  "deci-3a2bf98e", "title": "Composite beam checks finish before the ribbed-floor
  steel arm", "type": "decision"}, {"id": "deci-dc24c1ed", "title": "PIVOT: reduced
  tier cannot certify eccentric drift without plate geometry \u2014 do the data-model
  fix (plumb plate center + CoM)", "type": "decision"}, {"id": "todo-8da49024", "title":
  "B8 \u2014 Nervi / isostatic-ribbed slab design (promote run_nervi_vis.jl geometry
  to a sizing pipeline)", "type": "todo"}, {"id": "deci-080a7905", "title": "Phase
  11 follow-ups: per-slab boundary fix + centralized _volume_key helper", "type":
  "decision"}]'
entries_modified: '[{"id": "plan-cecee16b", "title": "Phase H \u2014 Steel lateral-force-resisting
  systems (braced & moment frames)", "type": "plan"}]'
---
session
Revisit iterative sizing when perimeter frames or braces are added
Auto-closed after topic shift. 1 created, 1 modified, 45 accessed.
Revisit iterative sizing when perimeter frames or braces are added Phase 6 — ASCE 7-22 lateral demand E7 — Ingest & wire full ASCE 7-22 wind/seismic/snow provisions Phase A — Analysis engine: loads, load paths, lateral & serviceability A3.1 — Wind MWFRS pressures → story forces (ASCE 7 Ch. 26–30) Phase 6d applies seismic ELF to rigid-diaphragm masters; wind and geometric P-delta stay out ELF drift load, story shear, and corrected NEHRP oracles checked Still deferred: Phase 3/6 bridge wiring and ASCE 7-22 §12.7.2 seismic weight Phase 2: unshored composite beams checked under SEI/ASCE 37-02 pre-cure load A8 — Consolidated serviceability suite (drift, deflection, vibration, long-term, crack control) A3 — ASCE 7 lateral demand generation (wind pressures + seismic) & diaphragm assembly Walls assemble into the building model without invented supports D3 — Masonry (TMS 402): CMU/brick bearing & shear walls, lintels Phase D — Members, walls, light framing & new material systems Phase 5 layout: four runs from frame placeholders to one frame-shell model Phase 5b shells in, stopped on an upper-floor fixity P1 crit8 (P1): enclosure guard checks wall CENTROID, not body — endpoint overhang flips solve_wall_layout to feasible=TRUE at 1.18·DL D2.3 — CFS shear walls / lateral (AISI S400 sheathed-wall tables) Decision: design the wall/lateral stack for efficient layout optimization upfront Plan: complete concrete wall system (unified frame-shell, ASCE 7-22, performance-aware) BuildingStructure (reusable) vs BuildingDesign (per param set); snapshot/restore P0 (pre-existing): column_I_factor + beam_I_factor unregistered with incremental engine — default REST /design path silently drops the knob, returns stale 0.70 design Threaded ACI 318-11 §10.10.4.1 cracking factors (beam_I_factor/column_I_factor) end-to-end; knobs now honored, byte-exact no-op at defaults Run 5 / Phase B: activate per-group overrides in the real pipeline (de-risk first) Phase B build scope refined by recon2: minimal StructuralSizer feasible kwarg + steel-beam-only + conditional guard B1 — One-way slab + supporting-beam sizing pipeline B2 — Two-way (beam-supported) slab sizing pipeline StructuralSizer - sizing & design codes Plots / Visualization / Studies A1 reverted: loads_only=true swap in _solve_load_case! kept for a future paired-solve investigation Phase 2 framing and project configuration progress Plan: Integrate Phase 5 Framing Population Phase 5 Framing Integration Complete (with follow-up bug identified) Framing load-path fidelity + waffle via integrated ribs Epoch 1: Origins - building geometry & face-finding (Dec 2025) Framed-slab load routing: strip fast-path restricted to true joist-frame rectangles (per-member exact) Scoped floor-overrides INHERIT params.column_I_factor — col_I_factor is a column-type property, orthogonal to floor-zone system Wave 3: flat-plate column grouping (D-series) — revised scope StructuralSizer design-code coverage map B3 — Waffle / joist-slab analysis & design pipeline Waffle rib grid first-cut + integrated T-beam ribs B7 — One-way joist / pan-joist (ribbed) slab (ACI 318 §8.13 / 318-19 §9.8) Composite beam checks finish before the ribbed-floor steel arm PIVOT: reduced tier cannot certify eccentric drift without plate geometry — do the data-model fix (plumb plate center + CoM) B8 — Nervi / isostatic-ribbed slab design (promote run_nervi_vis.jl geometry to a sizing pipeline) Phase 11 follow-ups: per-slab boundary fix + centralized _volume_key helper Phase H — Steel lateral-force-resisting systems (braced & moment frames)
