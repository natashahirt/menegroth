---
id: plan-5d8af001
type: plan
project: menegroth
parent_id: plan-a0000004
title: 'Phase: Incremental Design DAG Engine'
node_label: 'Phase: Incremental Design DAG Engine'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-117507fd
created_at: '2026-07-14T01:40:05.128293+00:00'
updated_at: '2026-07-14T01:40:05.128293+00:00'
---
Reframe the linear design pipeline (design_building -> build_pipeline stages) as an extensible, content-addressed dependency DAG with demand-driven incremental recomputation. A variation (e.g. slab-type swap) recomputes only the dirty sub-graph, bit-identically to the full pipeline. Executed as SIX CHAINED COORDINATOR RUNS, each gated by a differential verify harness (exact-first, per code-accuracy.mdc). Plan file: .cursor/plans/incremental_design_dag_ac828b0c.plan.md. User approved fully autonomous overnight execution. Scope decided with user: (1) general engine + prove on building-scale sweep; (2) exact-first correctness; (3) fine nodes collapsed by SlabGroup/MemberGroup identity; (4) extensible for future material systems/elements; (5) DAG as materialization of the engineering workflow enabling feedback loops + checkpoints. Levers A-E folded in; F + surrogate tier tabled as backlog.
