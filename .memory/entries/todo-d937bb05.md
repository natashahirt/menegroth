---
id: todo-d937bb05
type: todo
project: menegroth
parent_id: plan-3dbc321c
title: C4 — Steel trusses (member assemblies + joint design)
node_label: 'C4: Steel trusses'
tags: todo,steel,truss,aisc,connections,phase-c
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9bb4d72a
created_at: '2026-07-14T01:36:50.092200+00:00'
updated_at: '2026-07-14T01:36:50.092200+00:00'
has_child_rationale: Long-span steel roofs/floors use trusses assembled from AISC
  members
---
# C4 — Steel trusses

Long-span steel roofs and transfer levels use trusses (Warren/Pratt/Vierendeel). We have AISC 360-16 member checks (tension Ch. D, compression Ch. E, HSS) — this todo assembles them into a **truss** with the framing model and adds joint/panel-point design.

**Build:** truss topology in the skeleton/framing model, member force recovery from Asap, member selection reusing AISC checks, and connection design at joints (gusset/HSS — corpus already has AISC Ch. K HSS-to-HSS truss connections, see `.zettelkasten/aisc-360-16/`). **Couples to:** D5 (connections), Phase C5 (metal buildings).
