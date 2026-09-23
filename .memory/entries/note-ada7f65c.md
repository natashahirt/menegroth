---
id: note-ada7f65c
type: note
project: menegroth
parent_id: plan-a4de4826
title: 'Defect 2: pattern-loading envelope never reaches member sizing'
node_label: D2 patterns ignored
tags: safety,pattern-loading,asap,member-demands
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/asap/utils.jl@d70bce4, external/Asap/src/Analysis/force_displacement.jl@d70bce4
session_id: sess-bff66da0
created_at: '2026-09-23T01:51:50.573033+00:00'
updated_at: '2026-09-23T01:51:50.573033+00:00'
---
_solve_with_patterns! writes a per-DOF abs envelope into el.forces, but member_group_demands calls Asap.ElementForceAndDisplacement which recomputes forces from the full-load node displacements (force_displacement.jl:32-50). Pattern effects are silently dropped for beams/columns. The per-DOF envelope is also non-concurrent.
