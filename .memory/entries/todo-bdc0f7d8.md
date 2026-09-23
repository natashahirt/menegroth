---
id: todo-bdc0f7d8
type: todo
project: menegroth
parent_id: plan-a4de4826
title: Thread strip_axis through transverse steel and NLP transfer
node_label: Thread strip_axis through transverse steel and NLP
tags: foundation-safety,p1,strip-transverse,nlp-transfer
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/foundations/codes/aci/strip_footing.jl@0ed55e4, StructuralSizer/src/slabs/optimize/flat_plate_problem.jl@0ed55e4
session_id: sess-a69a92aa
created_at: '2026-09-23T06:28:27.621284+00:00'
updated_at: '2026-09-23T06:28:27.621284+00:00'
---
Critic P1s after production strip_axis: (1) Steps 5–6 still use named c2 as across-strip, so a Y-strip 12×36 understates Mu_trans ~4×. (2) NLP never calls governing_transfer_reinforcement, so size_flat_plate_optimized can mark a thickness feasible that _run_final_design would reject. Thread strip_axis through transverse cantilever/band_w/ld; add transfer As to NLP and treat Inf as infeasible. P2 IS/diagonal tie: report only.
