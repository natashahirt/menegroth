---
id: todo-b31bdd84
type: todo
project: menegroth
parent_id: deci-f53d6337
title: 'Coordinated: flat-plate col_I_factor SSoT across FEA+EFM — [eng] sync+efm
  edit, [rev] blind, [crit] adversarial, [test] gate, [mem] record'
node_label: 'Coordinated: flat-plate col_I_factor SSoT'
tags: todo,coordinator,flat-plate,col_I_factor,SSoT,FEA,EFM
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-bb875624
created_at: '2026-10-21T23:39:14.861102+00:00'
updated_at: '2026-10-21T23:39:14.861102+00:00'
has_child_rationale: Plan checklist for the Change 1 coordinated graph
---
Graph (medium rigor) for Change 1 — make params.column_I_factor the SSoT for flat-plate columns across FEA + EFM.

- [eng] engineer: (1) design_types.jl resolve_floor_options — @set opts.col_I_factor = params.column_I_factor (FlatPlateOptions + FlatSlabOptions .base); (2) StructuralSizer efm.jl 3 derivation sites — cracked branch uses incoming col_I_factor instead of literal 0.70 (uncracked stays 1.0). Byte-exact no-op at default 0.70; cite ACI 318-11 §10.10.4.1. writes: StructuralSynthesizer/src/design_types.jl, StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm.jl
- [rev] reviewer (blind): no-op parity + correctness across FEA/EFM/DDM.
- [crit] critic: grown-column reconcile consistency (design_workflow.jl:966), FEA/EFM/DDM consistency, cracked_columns=false ⇒ 1.0 preserved, FlatSlabOptions .base handling, no stale-0.70 stub rebuild.
- [test] tester: extend verify_i_factor_threading.jl with flat-plate checks (FEA + EFM asap/cracked at non-default; no-op at default).
- [mem] memory: record subtree under deci-f53d6337.

Context: first StructuralSizer boundary crossing in this workstream (per 'do both' decision). Prior regression suite (4/4 gates) + frame gate (22/22) + reviewer all PASS before this change.
