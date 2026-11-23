---
id: deci-4a4f60e5
type: decision
project: menegroth
parent_id: plan-cecee16b
title: 'LFRS build sequencing: MF-first (finish sway pipeline) → drift-driver → shared
  axial sizer → explicit-truss layer → SJI; serialize, do NOT one-shot'
node_label: 'LFRS build sequencing: MF-first (finish sway pipel'
tags: sequencing,lfrs,phase-h,phase-c,roadmap,moment-frame,braced-frame,truss,axial-member,coordinator
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4fae1b60
created_at: '2026-11-23T17:48:47.157039+00:00'
updated_at: '2026-11-23T17:48:47.157039+00:00'
has_child_rationale: Resolves the two 'LEFT OPEN' sequencing questions on deci-ff84d1d8;
  user accepted the recommended order
---
Resolves the two sequencing questions left open on deci-ff84d1d8. Agreed with user 2026-11-23.

**Decision on (i) MF-first vs axial/truss-layer-first → MF-FIRST.** Member sizing is NOT the risk (Beam/Column beam-column checks + sway/2nd-order machinery — StoryStability, B1/B2, δs — already exist checker-side). The two unproven pieces are (a) lateral demand extraction→sizing (WS1 pipeline-side: story_stability_records → member stage `story=` + `lt` demand; pending) and (b) system selection + drift-as-driver (WS2; in progress). A moment frame reuses tagged Beam/Column with ZERO new primitives / assembly / Asap behavior, so it is the minimal surface that still exercises both risks end-to-end. Build the axial/truss layer AFTER the demand pipeline is validated, not against an unproven one.

**Decision on (ii) SJI vs engineered explicit → ENGINEERED EXPLICIT FIRST** (conditional on staying pointed at steel high-rise). Critical-path truss work for high-rise is explicit + shared axial sizer (braced cores, outrigger/belt, transfer trusses) — same code as H1 braced frames. SJI joists are black-box + table-lookup, a gravity/floor convenience off the high-rise critical path; add later as a cheaper table-lookup strategy on the same Truss owner. CAVEAT: if the near-term target shifts to low-rise steel (warehouses/long-span roofs), SJI dominates volume and jumps the queue.

**Agreed ordered sequence:**
1. Finish WS1 pipeline-side + WS2 selection → MF / dual (MF + RC core) high-rise standing & validated (no new primitives).
2. Drift-as-driver (H4) on the now-working pipeline.
3. Shared axial-member sizer (AISC Ch. E compression + Ch. D tension) — pure StructuralSizer, no assembly yet; existing Strut braces use it as simple members. Do the cheap :braces→:struts rename here, before refs accumulate.
4. Explicit-truss / braced-frame assembly layer (Truss owner, topology on :struts, pinned-element solve, force recovery) → unlocks H1 braced frames + C4 engineered trusses + transfer/outrigger together. Defer tension/comp-only Asap until a slender CBF needs it.
5. SJI joists as a table-lookup strategy on the Truss owner.

**Explicitly SERIALIZE, do NOT attempt steps 1–5 in one parallel push:** steps 3–4 build on the demand pipeline that step 1 validates; parallelizing re-introduces the exact risk MF-first is meant to retire. Parallelism belongs WITHIN a step (e.g. step 1's subtasks), not across steps.
