---
id: todo-f82c296c
type: todo
project: menegroth
parent_id: todo-9160f206
title: A1.2 — Resolve Asap k_joist element stiffness kernel
node_label: 'A1.2: Asap k_joist'
tags: todo,joists,asap,stiffness,fem,phase-a
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-252d7a06
created_at: '2026-07-15T01:15:44.697501+00:00'
updated_at: '2026-07-15T01:15:44.697501+00:00'
has_child_rationale: The FE model is ill-posed until the joist element has a defined
  stiffness
---
# A1.2 — Asap k_joist stiffness

`k_joist` may be undefined in the Asap model (documented in `scripts/runners/run_phase7_asap_smoke.jl`), leaving the joist element without a well-defined stiffness. Define the joist stiffness (equivalent flexural/axial properties for an open-web joist, or the appropriate release+section) so `to_asap!` produces a solvable model. **Couples to:** A1.1 (selected joist → its stiffness) and the `:joist` release handling in `members/defaults.jl`.
