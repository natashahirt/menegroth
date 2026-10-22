---
id: todo-c7d0e4c1
type: todo
project: menegroth
parent_id: deci-592222ad
title: '[pre-ribbed] Defect 4: ACI 318-11 §11.11.7.1 biaxial eccentric punching at
  corner/edge columns'
node_label: '[pre-ribbed] Defect 4: ACI 318-11 §11.11.7.1 biaxi'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-dc9dca9d
created_at: '2026-10-22T16:02:57.592300+00:00'
updated_at: '2026-10-22T16:02:57.592300+00:00'
---
Thread the secondary unbalanced moment Muy through the punching check and compute combined eccentric shear γv·M·c/Jc about BOTH axes (PCA EB712 Fig.16-13 Case D). Turn all 16 test_corner_punching.jl oracles green; verify the footing punching path. Core edit in StructuralSizer/src/codes/aci/punching.jl. Lead task of the pre-ribbed run.
