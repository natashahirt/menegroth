---
id: deci-2d7ffd9a
type: decision
project: menegroth
parent_id: plan-5d8af001
title: 'Run 3 post-fix critic FAIL: target= subset-targeting reaches the ''unreachable''
  mixed slab level (exact-first violation) — fix cycle launched'
node_label: 'Run 3 post-fix critic FAIL: target= subset-targeti'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_graph/scheduler.jl@79245e3, StructuralSynthesizer/src/design_graph/session.jl@79245e3,
  StructuralSynthesizer/src/core/snapshot.jl@f2c376f, StructuralSynthesizer/src/design_workflow.jl@f2c376f,
  scripts/runners/verify_design_graph_incremental.jl@f2c376f, StructuralSynthesizer/test/design_graph/test_design_graph_incremental.jl@8a6aad6
session_id: sess-a2772d28
created_at: '2026-07-14T15:47:41.968878+00:00'
updated_at: '2026-07-14T15:47:41.968878+00:00'
---
Run 3 (barrier/level sync + fine per-slab nodes, exact-first 'Option B' foundation) passed its blind reviewer + all four gates (15/15, 17/17, 50/50, 207/207), but an adversarial POST-FIX critic re-attack FALSIFIED the fix's load-bearing safety claim.

P1 (safety): The 'mixed clean/dirty slab level UNREACHABLE end-to-end' certification (in snapshot.jl, scheduler.jl, design_workflow.jl, verify_design_graph_incremental.jl, test) is FALSE. The reviewer's unreachability proof covered only PARAM-driven dirtiness (all slab nodes share one param_slice). It missed MEMOIZATION-STATE dirtiness: fine slab nodes are EDGELESS ROOTS, so the exported target= kwarg on run_target!/DesignSession/redesign memoizes ONLY the targeted slab; a later run-to-terminal yields a genuine MIXED slab level that runs the partial-restore overlay, serving a slab sized in the WRONG monotonic-column-growth context => incremental redesign SILENTLY DIVERGES from from-scratch. _adopt_larger_column! can also downgrade a fresh heavier column section to a stale lighter one on a dimensional tie (no capacity comparison). Repro: run_target!(target=slab_node_key(2)); run_target!(target=terminal).

HELD UP: slab-order eachindex determinism, single-per-level barrier sync, design_building all-dirty byte-identity, trace envelope, _col_cache purity. design_building itself stays byte-identical; defect is only on the incremental redesign path.

FIX CYCLE (extended on dag-run-3, after task-31368a1d): fix-eng (opus, make exact-first TRUE by construction: reject partial-slab targets OR co-schedule all slab roots + baseline-restore; harden _adopt_larger_column! with capacity comparison; fix stale vault comments; add target= repro test + reverse/mixed-dim column tests; all 4 gates green) -> fix-crit (re-attack the same vector) + fix-tst (gate run). True independent per-slab variation + order-independent grow-then-size DEFERRED to Run 4 (Option A). Coordinator cleaned up an abandoned foreign run (run-2f22ec24) whose zombie write-lease had blocked eng-groups ~6h after an MCP restart.
