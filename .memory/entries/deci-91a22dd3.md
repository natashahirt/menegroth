---
id: deci-91a22dd3
type: decision
project: menegroth
parent_id: plan-382ddd12
title: 'Stage E design: one parametric DualSystem(row) covering BOTH Table 12.2-1
  Section D (SMF) and E (IMF); SDC-driven auto-selector + validated user override'
node_label: 'Stage E design: one parametric DualSystem(row) cov'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-3506aa6c
created_at: '2026-11-23T11:47:26.243795+00:00'
updated_at: '2026-11-23T11:47:26.243795+00:00'
---
User direction: implement both dual-system ductility classes cleanly and let the building's seismic requirements choose, with a user override.

DECISION (clean/general, reuses existing row-as-data pattern):
1. ONE parametric `DualSystem` LateralSystem carrying (moment-frame subsystem, wall/core subsystem, Table 12.2-1 row). Section D vs E is simply the row symbol (:D.. special moment frame vs :E.. intermediate moment frame) — no separate types per ductility class or material. Subsumes InteractiveShearWallFrameSystem (row F) as the RC/RC ordinary special-case.
2. A PURE selector drives the pick from seismic requirements: site seismicity + risk category -> SDS/SD1 -> SDC (ASCE 7 §11.6) -> Table 12.2-1 permission matrix (allowed rows at that SDC + height) -> choose lowest-cost permitted row. High SDC/height -> only Section D survives; low SDC -> E (or simpler) permitted & cheaper.
3. USER OVERRIDE wins as the selection but is VALIDATED against the same Table 12.2-1 permission matrix (refuse/warn on an impermissible choice, e.g. Section E IMF dual at 40 stories in SDC D). Preserves the existing 'no silent default' philosophy: name a row (validated) OR explicitly opt into auto-selection.
4. GENERALIZATION: the selector is not dual-specific — it is 'given SDC/height/materials, pick or validate a Table 12.2-1 row'; WallsSeismicSystem and DualSystem are just row families it ranges over.

D vs E explained: both are dual systems (two subsystems share lateral load; moment frame must independently resist >=25% of design seismic force, ASCE 7-22 §12.2.5.1, PDF p.177). Difference = ductility/detailing class of the backup moment frame: D = Special moment frame (higher R, generally no height limit, all SDCs); E = Intermediate moment frame (lower R/Cd, height-limited, often not permitted in SDC D/E/F at height). Recommendation for a 20-40 story steel-frame+concrete-core high-rise: Section D (steel SMF + special RC shear walls, or composite special shear walls if core has embedded steel).

SAFETY-CRITICAL SIGN-OFF (pending, not a blocker to type design): Table 12.2-1 permission matrix + R/Cd/Ω0 values are code-derived and did NOT OCR from the corpus (table pages render as two-column placeholders). Must transcribe the relevant rows from the rendered page with clause/page citations and get user sign-off before they drive sizing.

SEQUENCING: Step 1 (nt/lt decomposition refactor) is independent and proceeds now. DualSystem + selector is Stage E, after Stage D wiring.
