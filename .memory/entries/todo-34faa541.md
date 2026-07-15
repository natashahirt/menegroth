---
id: todo-34faa541
type: todo
project: menegroth
parent_id: plan-fda2651a
title: 'F6 — API / integration surface: expose new systems through REST API + schema
  + agent ontology'
node_label: 'F6: API/integration surface'
tags: todo,api,integration,schema,ontology,rest,phase-f
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:27:53.123113+00:00'
updated_at: '2026-07-15T02:27:53.123113+00:00'
has_child_rationale: The library already exceeds the API; every new system must be
  surfaced to be usable end-to-end
---
# F6 — API / integration surface

Cross-cutting integration debt: the REST API accepts only `flat_plate / flat_slab / one_way / vault` (`StructuralSynthesizer/src/api/constants.jl`) while the library defines many more floor/member/wall systems. Every capability built in Phases A–H is only reachable in-library until it's surfaced.

**Build (ongoing):** as each system lands, expose it through the API constants + request schema + `api/ontology.jl` provision-coverage tracking (`full`/`partial`/`stub`) + agent tool registry, plus docs. Treat this as a **standing checklist item per new system**, not a one-shot. **Couples to:** every phase; F1 matrix should track API-exposure status alongside design status.
