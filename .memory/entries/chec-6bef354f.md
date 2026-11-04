---
id: chec-6bef354f
type: checkpoint
project: menegroth
parent_id: plan-ec9a5d12
title: Punching runs once, after the transfer band can develop the moment
node_label: Punching runs once, after the transfer band can de
tags: punching,studs,flat-plate,aci-318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-71d6a6dc
created_at: '2026-11-04T19:08:53.053660+00:00'
updated_at: '2026-11-04T19:08:53.053660+00:00'
---
The second punching analysis on the 3×3 plate was a thickness restart. Studs already passed the first demand at h = 5 in. Final design then rejected that thickness because the ACI 318-11 §13.5.3 transfer band (c + 1.5h at an edge) cannot develop the edge-column moment: As is infinite at 5 in and about 1.56 in² at 5.5 in. The depth search now calls the same transfer-section check before punching, so the 3×3 punches once at h = 5.50 in.

The stud zone is no longer cut off at 0.25 of the clear span. §11.11.5.4 (page 208) and §11.11.7.2(b) (page 210) say to extend the lines until the section d/2 past the last line passes. A 20-line cap remains only to stop a search that never passes.

These edits live in the flat-plate pipeline and calculation-helper split (pipeline/, calculations/, outer_section.jl). That split is included so the package still loads. The rest of the other session's tree is not part of this save.
