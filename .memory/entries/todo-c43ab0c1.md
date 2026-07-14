---
id: todo-c43ab0c1
type: todo
project: menegroth
parent_id: plan-97498959
title: E8 — Ingest AISC 341/358 (seismic) + reconcile ACI 318-11→19 edition drift
node_label: 'E8: Seismic canon + ACI edition'
tags: todo,corpus,ingest,aisc-341,aisc-358,aci-318-19,seismic,phase-e
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4ae8c09e
created_at: '2026-07-14T01:43:37.834470+00:00'
updated_at: '2026-07-14T01:43:37.834470+00:00'
has_child_rationale: Seismic detailing and consistent ACI edition are needed for hospitals/high
  seismic and to remove mixed-edition risk
---
# E8 — Seismic detailing canon + ACI edition reconciliation

Two canon-hygiene items:
1. **AISC 341-16 (Seismic Provisions) + AISC 358 (prequalified moment connections)** — not implemented; needed for moment/braced-frame seismic detailing (hospitals, high SDC) and D5 seismic connections. Add to corpus → ingest.
2. **ACI 318 edition drift** — the code currently mixes 318-11 and 318-19 (`note-cb000002`, capability map). `corpus.mdc` forbids mixing editions in one derivation. Decide the canonical edition (recommend 318-19), confirm it is fully ingested, and track reconciliation of existing 318-11 implementations. Include ACI 318 Ch. 18 (earthquake-resistant structures) for special walls/frames (ties to `plan-w0000001` todo-w0000010).

**Unblocks:** seismic typologies (F5 hospital), special detailing, and removes a standing safety risk.
