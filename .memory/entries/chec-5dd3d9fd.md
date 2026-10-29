---
id: chec-5dd3d9fd
type: checkpoint
project: menegroth
parent_id: plan-4b6f6344
title: Ordinary-wall demands and checks for one isolated pier
node_label: 'Ordinary-wall demands and checks for one isolated '
tags: walls,phase-7,checkpoint,ordinary-check,combinations
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-231ebea4
created_at: '2026-10-29T12:05:33.198913+00:00'
updated_at: '2026-10-29T12:05:33.198913+00:00'
---
Committed next: ordinary-wall demand path for one isolated pier. Unfactored gravity cases, strength combinations on concurrent pier (N, M, V), and the existing ACI shear, reinforcement, axial-flexure, and bearing checks. A failing given section is reported and not resized. Joined walls stay refused. The design_building wall stage and the lateral-approach sockets are not in this commit (plan-b0095736).

Also in the commit: wall mesh identity on the unified model, seismic demand gates that refuse rather than default the six provisions, and the ASCE 7-22 strength-combination factors used by the pier actions (including L = 0 on the 0.9D combinations, and Ev = 0.2 SDS D).

Left uncommitted on purpose: other agents' slab, deck, foundation, and design-workflow edits, and the deck-floor diaphragm helper.
