---
id: expe-bb4a4037
type: experiment
project: menegroth
parent_id: deci-0cc5ee80
title: D/A1 with the slab joined to the walls does not pass
node_label: D/A1 with the slab joined to the walls does not pa
tags: sdc,D/A1,story-shell,second-order
status: active
open_threads: 0
success: 'false'
files: ''
session_id: sess-74524385
created_at: '2026-11-16T12:38:08.029491+00:00'
updated_at: '2026-11-16T12:38:08.029491+00:00'
has_child_rationale: The joined slab edge changed the wall gravity path and the ground-story
  second-order moment.
---
Reran the five-story D/A1 building after the slab edge was joined to the wall instead of fixed in space. Scene overwritten at viewer/public/sdc-d-a1.mgscene. Design does not pass. Summary: col 24×24 ρ 0.0542, beam h 36 in Vu 191 kip, slab 15 in, drift 0.21, wall t 35 in ρl 0.0065, δDE within 89 over 8 unchecked 0. Governing check is Wall 20 story 0, combination QE_negy_minus_pos30x, second-order moment ratio 2.21. ACI 318-19 §6.2.5.3 (aci-318-19, PDF page 72) limits Mu including second-order effects to 1.4 times the first-order Mu. The previous fixed-edge D/A1 passed at wall t 30 in with the column shear at 1.00. Columns, beams, slab, drift, and ρl are otherwise the same line.
