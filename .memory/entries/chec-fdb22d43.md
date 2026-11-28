---
id: chec-fdb22d43
type: checkpoint
project: menegroth
parent_id: plan-0e3e4710
title: Rib deflection comes from the grillage frame
node_label: rib deflection
tags: deflection,waffle,aci-318,grillage
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-4dfaa5a4
created_at: '2026-11-09T01:12:00.486033+00:00'
updated_at: '2026-11-09T01:12:00.486033+00:00'
---
Rib service deflection is the grillage frame's elastic sag, scaled by Ie_frame/Ie at dead, sustained, and dead-plus-live. ACI 318-11 §9.5.2.3 Eq. (9-8) supplies Ie. §9.5.2.5 Eq. (9-11) supplies λΔ. The limits are the beam checker's Table 9.5(b) symbols. The strength-model I_factor is not an argument, and the simply-supported beam formula is not the grillage number.

A uniform simply-supported rib recovers 5wL^4/384EI at the mid node. A 2 by 2 rectangle reports a positive sag on each of its six ribs. The story shell stays off.

Tests: StructuralSizer slabs/test_rib_deflection.jl 12/12 (logs/test_StructuralSizer_20261108_200017.log) and StructuralSynthesizer analyze/test_rib_grillage.jl 285/285 (logs/test_StructuralSynthesizer_20261108_200020.log). Ie is still an input; placed bars are the next source of As.
