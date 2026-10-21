---
id: todo-6a3aad1a
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 5 — Unified Asap frame-shell model
node_label: 'P5: unified model'
tags: walls,phase,asap,unified-model,fem,todo
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-370815c5
created_at: '2026-10-21T02:13:06.879994+00:00'
updated_at: '2026-10-21T02:13:06.879994+00:00'
---
Refactor wall-panel/diaphragm assembly from fem_evaluator.jl into to_asap! (analyze/asap/utils.jl); one model for gravity+lateral, no double-counted stiffness/self-weight; separate topology construction from numeric updates and load solves; batched load-case solve/envelope; P-Δ + accidental torsion as explicit separately-fingerprinted solves. TWO MANDATORY GATES: unified-vs-isolated FEMLateralEvaluator equivalence, and gravity bit-identical non-regression when no lateral design requested.
