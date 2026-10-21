---
id: todo-701f6fca
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 9 — Special structural walls (ACI 318-19 §18.10)
node_label: 'P9: special walls'
tags: walls,phase,seismic,18.10,boundary-element,todo
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f764d548
created_at: '2026-10-21T02:13:27.749594+00:00'
updated_at: '2026-10-21T02:13:27.749594+00:00'
---
After §18.10 corpus promotion (Phase 2 gate), implement special.jl with explicit ordinary/special design context: special shear caps, displacement + stress boundary-element triggers, boundary extent, confinement, detailing. Ordinary-wall behavior unchanged; reject special-wall design when required seismic/detailing inputs absent. Clause-boundary tests + a special-wall published-example oracle. Relates to todo-w0000010.
