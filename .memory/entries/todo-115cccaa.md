---
id: todo-115cccaa
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 10 — Layout optimization + survivor FEM verification
node_label: 'P10: layout + survivors'
tags: walls,phase,layout,optimization,survivor,fem,todo
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-f764d548
created_at: '2026-10-21T02:13:31.591826+00:00'
updated_at: '2026-10-21T04:06:30.870388+00:00'
---
Deterministic candidate wall-line generation from real building geometry under analyze/lateral/, fed to layout_problem.jl. Reduced evaluator stays in the optimization loop; every selected layout re-solved in the unified Asap model and rechecked against full ACI. Acceptance thresholds for drift, torsion, equilibrium, reduced-vs-FEM discrepancy, and all wall checks; reject rather than silently accept failed survivors. Relates to todo-w0000005 / w0000004.
