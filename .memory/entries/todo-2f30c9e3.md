---
id: todo-2f30c9e3
type: todo
project: menegroth
parent_id: plan-3dbc321c
title: 'C1 — Steel joists & joist girders: catalogs + SJI capacity checks'
node_label: 'C1: Steel joists/girders (SJI)'
tags: todo,sji,joist,joist-girder,steel,roof,floor,phase-c
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9bb4d72a
created_at: '2026-07-14T01:36:38.350391+00:00'
updated_at: '2026-07-14T01:36:38.350391+00:00'
has_child_rationale: Open-web steel joists + joist girders are the backbone of low-rise
  steel roofs/floors
---
# C1 — Steel joists & joist girders (SJI)

Open-web steel joists (K/LH/DLH series) and joist girders carry most low-rise steel **roofs** and many floors. The framing hierarchy can place them (Phase A1) but there is **no SJI catalog or capacity check** (`slabs/codes/steel/joist_roof.jl`: `TODO: Load SJI joist tables`).

**Build:** SJI standard load tables (safe uniform load vs. span by designation) + joist-girder selection (panel-point loads), plus the SJI/AISC checks for special load cases. Shared by roof (Phase C2 deck) and floor (Phase A1/A2) joists. **Depends on:** Phase E5 (SJI canon). **Oracle:** SJI table values for a standard K-series joist.
