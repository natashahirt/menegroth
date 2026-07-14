---
id: deci-cd04174b
type: decision
project: menegroth
parent_id: plan-5d8af001
title: DesignGraph differential verify gate (permanent, Run 1)
node_label: DesignGraph differential verify gate (permanent, R
tags: verify-gate,exact-first,testing,design-dag
status: active
open_threads: 0
success: 'null'
files: scripts/runners/verify_design_graph.jl@ec066ec, StructuralSynthesizer/test/design_graph/test_design_graph_equivalence.jl@ec066ec,
  StructuralSynthesizer/test/design_graph/test_design_graph_topology.jl@ec066ec, StructuralSynthesizer/test/runtests.jl@ec066ec
session_id: sess-56f6ac71
created_at: '2026-07-14T03:05:51.667321+00:00'
updated_at: '2026-07-14T03:05:51.667321+00:00'
---
Run 1 established the permanent differential verification gate for the Incremental Design DAG. This is the **EXACT-FIRST GATE** every later phase (Runs 2-6) MUST pass before its changes are accepted.

## Artifacts
- `scripts/runners/verify_design_graph.jl` — standalone differential harness.
- `StructuralSynthesizer/test/design_graph/test_design_graph_equivalence.jl`
- `StructuralSynthesizer/test/design_graph/test_design_graph_topology.jl`
- Wired into `StructuralSynthesizer/test/runtests.jl` under a `'Design Graph'` testset.

## What it checks
Diffs **graph-vs-independent-legacy** on 15 engineering invariants at `rtol=1e-8` / `atol=1e-10`:
slab h, M0, punch ratio, deflection ratio, As, column dims, embodied-carbon total + per area, foundation dims + utilization.

Across THREE cases:
1. **flat-plate DDM**
2. **vault / beam-column** — exercises `_size_beams_columns!` and the `needs_sync=true` stage-2 branch
3. **`uniform_column_sizing=:per_story`** — the harmonize path

Plus a **diamond topological-order** unit test.

## Current status (all green)
- All three cases PASS (15/15 each)
- Topology 6/6
- Equivalence 59/59
- Existing `test_design_api` 66/66 (no regression)

Files: scripts/runners/verify_design_graph.jl, StructuralSynthesizer/test/design_graph/test_design_graph_equivalence.jl, StructuralSynthesizer/test/design_graph/test_design_graph_topology.jl, StructuralSynthesizer/test/runtests.jl
