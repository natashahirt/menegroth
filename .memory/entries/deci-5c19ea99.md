---
id: deci-5c19ea99
type: decision
project: menegroth
parent_id: plan-388839c8
title: 'P1-4: FEA D/L load cases reuse the CHOLMOD factor; oracle exact on one slab'
node_label: 'P1-4: FEA D/L load cases reuse the CHOLMOD factor;'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/load_cases.jl@ebef9c6,
  scripts/runners/verify_fea_loads_only_oracle.jl@ebef9c6
session_id: sess-e6058341
created_at: '2026-10-22T18:38:11.997645+00:00'
updated_at: '2026-10-22T18:38:11.997645+00:00'
---
P1-4 landed in StructuralSizer flat-plate FEA load cases only. `_solve_load_case!` and both restore branches of `_solve_dl_cases!` now call `Asap.update!(; loads_only=true)` instead of `values_only=true`. Those sites change AreaLoad pressure only; K is the already-factored shell stiffness. `model.jl`'s mesh-reuse update stays `values_only=true` because it assigns new column-stub and edge-beam sections before the update.

Oracle: scripts/runners/verify_fea_loads_only_oracle.jl, one 20 ft × 16 ft bay, 8 in slab, 1.5 m target edge, no drop panel and no edge beam. ORACLE_EXIT=0. Initial qu solve, dead qD, live qL after qD, and the factored restore (copy u, update, post_process, no third solve) all matched with |Δu|max = |ΔR|max = |ΔM|max = 0. The 2026-07 A1 revert (deci-1ccd0262, ~0.02% moment drift on an older Asap SHA) does not reproduce on this fixture.

Not covered: drop panels, edge beams, pattern-resolve, or a second thickness iteration. Those still go through the values_only section update in model.jl when the mesh is reused.
