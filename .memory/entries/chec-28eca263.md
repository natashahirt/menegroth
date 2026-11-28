---
id: chec-28eca263
type: checkpoint
project: menegroth
parent_id: plan-2d4158d0
title: Sizing loops stop on growth; slab commit reuses a matching proposal
node_label: Growth budgets landed
tags: iteration,flat-plate,design-graph,analysis
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a26abed3
created_at: '2026-11-08T15:50:28.759279+00:00'
updated_at: '2026-11-08T15:50:28.759279+00:00'
has_child_rationale: First slice of the iterative-design plan is in and unit-tested
---
Implemented the control-flow slice of plan-2d4158d0. No files pinned.

Done:
- `growth_steps` / `monotone_budget` in StructuralSizer. A still-growing flat plate (outer, Phase A depth, Phase B punching) may take one step per remaining increment, at least `max_iterations`, and at most the caller's count when that count is larger. Ceiling 48 does not reduce an explicit request. Exhaustion still returns `failure_reason = non_convergence` and adds `stop = :budget`; thickness past ln/10 returns `stop = :at_limit`. `floor_design_failure` puts that stop on the diagnostic. Status stays NOT_CONVERGED, so a non-converged floor is still not installed.
- Slab `code_version` is `:slab_sizing_v2`, so incremental memos from before the budget change are not reused.
- Commit reuses a slab proposal when every column that proposal sized still has that c1, c2, shape, and section. A larger envelope column still redesigns.
- `update_analysis!(struc, :loads | :stiffness | :geometry)`. Beam/column iteration uses `:stiffness`. Wall thickness apply uses `:geometry` (same `to_asap!` rebuild). Other `sync_asap!` / `to_asap!` call sites are unchanged.
- Design-signature comparison reports every mismatched key, sorted.

Checks: StructuralSizer slabs/test_iteration_budget.jl 24/24. StructuralSynthesizer design_graph/test_support_match.jl 6/6. Both `--fresh`.

Not done: shared `iterate_monotone` driver, removing wall-jump recursion, per-stage analysis counters, the 3×3 individual FEA punching fixture, the incremental signature mismatch run, and any new punching equation (still needs corpus sign-off). Punching still predicts a column against frozen demand and confirms with a re-solve.
