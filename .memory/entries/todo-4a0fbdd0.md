---
id: todo-4a0fbdd0
type: todo
project: menegroth
parent_id: plan-68155c81
title: A8 — Consolidated serviceability suite (drift, deflection, vibration, long-term,
  crack control)
node_label: 'A8: Serviceability suite'
tags: todo,serviceability,drift,deflection,vibration,creep,crack,phase-a
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:26:47.100399+00:00'
updated_at: '2026-07-15T02:26:47.100399+00:00'
has_child_rationale: Serviceability checks are scattered; consolidate into one suite
  with consistent limits
---
# A8 — Consolidated serviceability suite

Serviceability checks exist in pieces (slab deflection, wall drift, A7 vibration) but there's no unified suite with consistent limits. Consolidate: **lateral drift** (wind H/400–H/600, seismic per ASCE 7 §12.12), **deflection** (immediate + long-term), **floor vibration** (A7, DG11), **long-term creep/shrinkage** effects, and **crack control** (ACI 318 distribution of reinforcement). 

**Build:** a serviceability acceptance layer that pulls limits from ASCE 7 App. C + material codes, applied uniformly across members/slabs/frames. **Canon:** ASCE 7 App. C serviceability, ACI 318 deflection/crack, AISC DG3 (drift/serviceability). **Couples to:** A3/A5 (drift), A7 (vibration), Phase H/wall program (lateral drift).
