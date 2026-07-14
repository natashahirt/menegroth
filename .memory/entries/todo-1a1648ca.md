---
id: todo-1a1648ca
type: todo
project: menegroth
parent_id: plan-68155c81
title: 'A6 — Roof loads: snow, rain, roof live (ASCE 7) + roof load path'
node_label: 'A6: Roof loads (snow/rain)'
tags: todo,snow,rain,roof-live,asce7,loads,phase-a
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-71279841
created_at: '2026-07-14T01:35:06.989193+00:00'
updated_at: '2026-07-14T01:35:06.989193+00:00'
has_child_rationale: Roof-governed low-rise DOE types need snow/rain/drift loads that
  don't exist yet
---
# A6 — Roof loads & load path

Gravity loads distinguish `roof_LL`/`roof_SDL` (`StructuralSizer/src/loads/gravity.jl`) but there is **no snow (ASCE 7 Ch. 7), rain (Ch. 8), or drift/unbalanced** load generation. Warehouses, retail, schools, and cold-climate residential are roof-governed.

**Build:** flat & sloped roof snow (pf, Ce, Ct, Is, drifts at parapets/steps), rain/ponding, roof live-load reduction; apply to the roof framing produced by Phase C. **Depends on:** Phase E7 (ASCE 7-22 Ch. 7/8 canon). **Couples to:** Phase C (roof systems that carry these loads).
