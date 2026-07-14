---
id: todo-da4af973
type: todo
project: menegroth
parent_id: plan-1b964170
title: B2 — Two-way (beam-supported) slab sizing pipeline
node_label: 'B2: Two-way slab pipeline'
tags: todo,two-way,slab,aci,ddm,efm,pipeline,phase-b
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0b14e919
created_at: '2026-07-14T01:36:05.964881+00:00'
updated_at: '2026-07-14T01:36:05.964881+00:00'
has_child_rationale: Beam-supported two-way slabs reuse flat-plate DDM/EFM machinery
---
# B2 — Two-way slab pipeline

`TwoWay` has thickness init only; no `_size_slab!`. Unlike flat plate (beamless), this is the **beam-supported** two-way system. Much of the flat-plate DDM/EFM machinery (`slabs/codes/concrete/flat_plate/analysis/`) generalizes — the difference is beam stiffness in the frame and distribution of moments to beams vs. slab strips.

**Build:** extend DDM/EFM for beam-supported panels (ACI moment distribution to column/middle strips + beams), edge-beam torsion, then reuse punching/deflection checks. **Depends on:** B1 (beam hand-off). **Corpus:** ACI 318 (ingested).
