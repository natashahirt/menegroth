---
id: note-1fd50b69
type: note
project: menegroth
parent_id: deci-b5e461d3
title: rib_head_stirrups now defaults to true
node_label: rib_head_stirrups now defaults to true
tags: waffle,solid-head,stirrups
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design/parameters.jl@764bc9d
session_id: sess-fdaca98e
created_at: '2026-11-19T14:36:41.155026+00:00'
updated_at: '2026-11-19T14:36:41.155026+00:00'
---
`DesignParameters.rib_head_stirrups` now defaults to true. A rib framing into a solid head is sized with stirrups (ACI 318-11 §11.1.1, Vn = Vc + Vs; §8.13.8 keeps the joist Vc increase), and the head grows for punching and hogging. `false` still sizes the piece for Vu ≤ φVc on concrete alone and lets rib shear grow the head. The sentence in deci-b5e461d3 that says the default is false is the earlier judgment.
