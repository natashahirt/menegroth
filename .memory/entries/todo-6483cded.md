---
id: todo-6483cded
type: todo
project: menegroth
parent_id: plan-77fbce0e
title: D5 — Connection design module (AISC Ch. J base/bolted/welded; wood/CFS fasteners)
node_label: 'D5: Connections'
tags: todo,connections,aisc-j,base-plate,bolts,welds,nds-fasteners,phase-d
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ead030cd
created_at: '2026-07-14T01:42:08.048885+00:00'
updated_at: '2026-07-14T01:42:08.048885+00:00'
has_child_rationale: No connection design exists; connections govern lateral systems
  and trusses
---
# D5 — Connection design

There is **no connection design module** — only analysis idealizations (releases, seat eccentricity in `members/defaults.jl`). Connections govern braced/moment frames, trusses, and every material's lateral system.

**Build:** AISC 360-16 **Ch. J** bolted/welded connections (shear tabs, end plates, moment connections), column **base plates** (AISC DG1), and HSS connections (Ch. K — **already in corpus**, see `.zettelkasten/aisc-360-16/`). Add wood (NDS Ch. 11–12 lateral/withdrawal) and CFS (AISI) fasteners for D1/D2. For seismic, prequalified connections need AISC 358 (Phase E8). **Couples to:** C4 (trusses), and every lateral typology.
