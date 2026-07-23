---
id: expe-0c354bfe
type: experiment
project: menegroth
parent_id: deci-51acee72
title: Review found & fixed a safety-critical cross-family miscitation (two fix cycles)
node_label: 'Review: 2 fix cycles'
tags: review,safety-critical,miscitation,cross-family,fix-cycle,systematic-fix
status: active
open_threads: 0
success: 'true'
files: ''
session_id: sess-44762bde
created_at: '2026-07-23T16:48:02.793370+00:00'
updated_at: '2026-07-23T16:48:02.793370+00:00'
has_child_rationale: Records the adversarial review outcome that hardened the grounding
  layer
---
Two corrective fix cycles (rigor=medium, extensions_used=2/3).

### Cycle 1 — SAFETY defect on the BEAM path
Steel **beam** checks silently mis-cited **concrete (ACI)**: a compound `code_clause` string like `"AISC 360-22 Chapter F / ACI 318-19 §9.5"` fell through the material normalization and resolved to the ACI branch — i.e. a steel member surfaced a concrete citation. This is exactly the cross-family violation the design forbids. Also caught in cycle 1:
- A `citation_id` **collision**: `§22.6` (punching shear) reused across column / slab / foundation checks produced colliding ids.
- **Non-canonical JSON ordering** in the export (broke the content-hash guarantee).

### Cycle 2 — SAME defect class on the COLUMN path
The cycle-1 fix was a symptom fix: the identical cross-family fall-through existed on the **column** path. Lesson: *symptom fix vs systematic fix*. Resolved with a material-aware `_column_code_clauses` plus a full **4-path audit** (beam / column / slab / foundation) to confirm no other path could cross families.

Agent traces: rev e94c6e8d, crit 2d68663c (cycle 1); rev2 34ca8b3c, crit2 4f50a07c (cycle 2 trigger); eng_fix 4ec81af9, eng_fix2 c7ddb753; final rev3 163f9a3f PASS, crit3 f8108a4a CONCERN (P2-only).
