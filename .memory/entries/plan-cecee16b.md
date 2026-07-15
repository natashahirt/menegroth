---
id: plan-cecee16b
type: plan
project: menegroth
parent_id: plan-11f26f2d
title: Phase H — Steel lateral-force-resisting systems (braced & moment frames)
node_label: 'Phase H: Steel LFRS'
tags: roadmap,steel,lfrs,braced-frame,moment-frame,aisc-341,drift,phase-h
status: active
open_threads: 4
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:23:47.825710+00:00'
updated_at: '2026-07-15T02:28:59.495725+00:00'
has_child_rationale: The concrete shear-wall program has no steel counterpart; steel
  braced/moment frames are the LFRS for most steel DOE buildings
related_to: plan-w0000001,todo-310559df
---
# Phase H — Steel lateral-force-resisting systems

**Gap identified 2026-07-14.** The lateral subsystem today is concrete-only (shear-wall program `plan-w0000001`, S1–S4). Steel buildings (most DOE offices, schools, retail) resist lateral load with **braced frames or moment frames**, and none of that is designed — `Strut` exists as a type with **no sizer**, and AISC 341 seismic detailing (ingested in E8) has no implementation.

Modeled as a **scope ladder** mirroring the wall program, so the first step stays small while the architecture is worked out. It consumes the lateral demands from Phase A3 and the assembled model / diaphragm from A3.3/A4, and shares the second-order machinery of A5.

**Scope ladder:**
- **H1** — Braced frames (concentric CBF, eccentric EBF, buckling-restrained BRBF), demand-as-input first.
- **H2** — Moment frames (member design + panel zones + drift).
- **H3** — Seismic detailing: AISC 341-16 capacity design + AISC 358 prequalified connections.
- **H4** — Integrated stability/drift + lateral-system selection.

**Canon:** AISC 360-16 (member design — have it), AISC 341-16 + 358 (E8 ingestion). **Related:** `plan-w0000001` (concrete-wall peer program), Phase A3/A4/A5, Phase D5 (connections).
