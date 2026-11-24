---
id: expe-cecbd296
type: experiment
project: menegroth
parent_id: plan-0b622f2c
title: 'Coupled MIP warm start (seeds z) + part-count Pareto front: every warm solve
  matches cold optimum, ×1.69 single-section material penalty'
node_label: Coupled MIP warm start (seeds z) + part-count Pare
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/optimize/solvers/discrete/backends.jl@004d681, StructuralSizer/src/optimize/solvers/discrete/model.jl@004d681,
  StructuralSizer/test/optimize/test_coupled_warm_start.jl@004d681, StructuralSizer/test/runtests.jl@004d681,
  scripts/runners/relaxation_partcount_pareto.jl@004d681
session_id: sess-f3546484
created_at: '2026-11-24T19:37:15.121051+00:00'
updated_at: '2026-11-24T19:37:15.121051+00:00'
---
Extended optimize_discrete's mip_start to the section-count-capped regime (n_max_sections>0), which the model previously refused to warm-start because the coupling binaries z (section-used indicators) were unseeded. New _apply_mip_start!(x, z, feasible, mip_start, n_sections) overload seeds z[j]=1 for every section used by the (feasible) seeded x and 0 otherwise — consistent with sum_i x[i,j] <= n_groups*z[j] and sum_j z[j] <= n_max. Pure set_start_value hint: an over-rich seed (>n_max distinct) is infeasible and the solver discards it (no-op), never changing the optimum.

Correctness nuance: for n_max>0 the solution is extracted with plain argmax (the reflection-invariant tie-break is n_max==0-only), so with degenerate optima a warm start preserves the OBJECTIVE but not necessarily the exact assignment. Tests/runner assert equal objective (rtol 1e-6), not byte-identical indices.

Part-count Pareto runner (scripts/runners/relaxation_partcount_pareto.jl): 283-section W catalog, 16 deflection-governed groups (unconstrained uses 15 distinct). Sweep n_max=1..10, each seeded by continuation from the k-1 design. Results: front strictly monotone (vol down as parts up), every warm solve matched the cold optimum, single-section penalty x1.69 (3.629 vs 2.145 m^3). Coupled-warm aggregate speedup only x1.13 here (16-group instances solve ~300ms; k=1->2 seed deliberately poor, x0.56) — the large warm-start wins (x15/x56) stay on the separable problem. Primary value: proven-correct coupling-aware warm start + a genuine fabrication-economy vs material-efficiency Pareto trade-off.

23/23 new unit tests green (test/optimize/test_coupled_warm_start.jl). n_max==0 path byte-identical (change guarded behind mip_start!==nothing).
