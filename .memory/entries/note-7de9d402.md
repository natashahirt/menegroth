---
id: note-7de9d402
type: note
project: menegroth
parent_id: plan-a4de4826
title: 'Defect 4: shared punching_check ignores unbalanced moment at corner columns'
node_label: D4 corner punching
tags: safety,punching,footings,aci-318-11
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/codes/aci/punching.jl@d70bce4
session_id: sess-611942f9
created_at: '2026-09-23T01:51:55.579778+00:00'
updated_at: '2026-09-23T01:51:55.579778+00:00'
---
punching.jl:442-444 uses vu = v_direct for :corner although its own comment says ACI 318-11 11.11.7.1 applies moment transfer to all columns. Used by mat and strip footings.
