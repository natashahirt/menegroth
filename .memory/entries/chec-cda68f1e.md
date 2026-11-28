---
id: chec-cda68f1e
type: checkpoint
project: menegroth
parent_id: plan-b10cde0c
title: 'Analysis counts: FEA rebuilds and updates, and each update_analysis! change'
node_label: Analysis counters landed
tags: analysis,fea,trace
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-da5e6261
created_at: '2026-11-08T20:16:19.569479+00:00'
updated_at: '2026-11-08T20:16:19.569479+00:00'
has_child_rationale: Step 1 of the counters-driver-punching plan
---
Step 1 of plan-b10cde0c. No files pinned.

FEAModelCache.n_rebuilds and n_updates count a mesh build and a section/load update. _reset_fea_cache! keeps both, so a column growth that forces a remesh still adds up. size_flat_plate! writes fea_rebuilds and fea_updates on the success exit and on a non_convergence failure.

update_analysis! takes tc and emits one :decision with the change (:loads, :stiffness, :geometry) before doing the work. A symbol outside those three throws and emits nothing. The beam/column loop, the columns-only re-solve, and apply_wall_thickness! pass tc through. Fire-coating solves and uniform-column harmonization still call Asap directly: coating loads are written onto the model and sync_asap! would rebuild loads without them, and harmonization uses values_only.

Checks: StructuralSizer slabs/test_iteration_budget.jl 29/29 (a reset keeps 3 rebuilds and 4 updates). StructuralSynthesizer design_graph/test_support_match.jl 8/8. Both --fresh.

Not done: the one-off baselines (wall jump, honeycomb, 3x3). Those are the next measurement, and the 3x3 is about half an hour. Then the shared settle! driver.
