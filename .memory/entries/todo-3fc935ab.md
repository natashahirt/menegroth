---
id: todo-3fc935ab
type: todo
project: menegroth
parent_id: plan-67a1e4f7
title: G4 — Geotechnical inputs & global stability (bearing/settlement, overturning/uplift/sliding)
node_label: 'G4: Geotech & stability'
tags: todo,foundations,geotechnical,bearing,overturning,uplift,sliding,stability,phase-g
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:26:02.255201+00:00'
updated_at: '2026-07-15T02:26:02.255201+00:00'
has_child_rationale: The link between the lateral system and the foundation; currently
  bearing is a stub input
---
# G4 — Geotechnical inputs & global stability

The interface between soil, the lateral system, and the foundation. `api/ontology.jl` marks foundation bearing as a **stub**. This todo makes geotech a first-class input and adds the whole-building stability checks that gravity-only design never needed.

**Build:** allowable/factored soil bearing + settlement inputs (as parameters, since no soil standard is in corpus), and **global stability** — overturning, uplift/net-tension at foundations, and sliding — driven by the lateral demands (Phase A3) and the LFRS reactions (wall program, Phase H). Includes foundation net-tension → pile uplift (G1) and tilt-up/retaining-wall stability (overlaps `plan-w0000001` retaining-wall todo).

**Canon gap:** geotechnical capacity has no standard in corpus — treat soil parameters as engineering-judgment inputs, clearly flagged. **Couples to:** G1–G3, A3/A4, Phase H, wall program.
