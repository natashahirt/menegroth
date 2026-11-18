---
id: deci-c85e0d31
type: decision
project: menegroth
parent_id: deci-4632cb50
title: Solid-head checks read their demands from the building model
node_label: Solid-head checks read their demands from the buil
tags: waffle,solid-head,building-model,analysis
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-164e167b
created_at: '2026-11-18T16:04:56.301627+00:00'
updated_at: '2026-11-18T16:04:56.301627+00:00'
---
User decision 2026-11-18. The local arrangement grillage in `analyze_arrangement_grillage` supported each panel only on its column stubs and ignored the girders on the panel edges. On grid/x1y1 (columns 12 x 10 m, panels 6 x 5 m framed by girders) every panel hung from its one corner column, so the rib one-way shear at the head face read 2.3-3.3 while the building model gave those ribs small shear.

Rule: the design workflow reads demands from the full building model wherever that model exists. Local re-analysis models are not used when the building model has the members. This is more accurate and saves rebuilding models. An audit of the design workflow for other local models is part of this change.

Also: the head depth must not come from girders on the level (`_deepest_rib_section` picked a 33.8 in girder).
