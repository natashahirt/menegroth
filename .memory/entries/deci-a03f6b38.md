---
id: deci-a03f6b38
type: decision
project: menegroth
parent_id: plan-5d8af001
title: DesignGraph node-interface contract (Run 1)
node_label: DesignGraph node-interface contract (Run 1)
tags: design-dag,designgraph,architecture,structuralsynthesizer
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_graph/_design_graph.jl@cb45d7a, StructuralSynthesizer/src/design_graph/node.jl@cb45d7a,
  StructuralSynthesizer/src/design_graph/graph.jl@cb45d7a, StructuralSynthesizer/src/design_graph/executor.jl@cb45d7a,
  StructuralSynthesizer/src/design_workflow.jl@cb45d7a, StructuralSynthesizer/src/StructuralSynthesizer.jl@cb45d7a
session_id: sess-56f6ac71
created_at: '2026-07-14T03:05:32.510138+00:00'
updated_at: '2026-07-14T03:05:32.510138+00:00'
---
Run 1 of the Incremental Design DAG effort established the node-interface contract that Runs 2-6 build on. This entry captures the API so a future session can extend it without re-reading the code.

## New module: `StructuralSynthesizer/src/design_graph/`
Files: `_design_graph.jl` (module glue/includes), `node.jl`, `graph.jl`, `executor.jl`.

## Node interface
Abstract `DesignNode` with the interface:
- `node_key(node)::NodeKey`
- `dependencies(node)::Vector{NodeKey}`
- `needs_sync(node)::Bool`
- `run!(node, struc, params, ctx)`

Concrete `StageNode` wraps a closure plus a `needs_sync` flag.

`NodeKey` is a `Symbol` alias **for now** (intended to become a content-addressed key in Run 2).

## Graph + execution
- `DesignGraph` container.
- Deterministic Kahn `topological_order` — ties broken by insertion index.
- `execute_graph!(g, struc, params; ctx=nothing)` runs nodes in topo order, calling `run!` then `needs_sync(node) && sync_asap!`, reproducing the legacy loop.
- The `ctx` arg is a **reserved seam** for Run 2 caching/fingerprinting.

## Integration
`design_building` now calls `build_design_graph` (derived 1:1 from `build_pipeline` stages, a linear chain) and `execute_graph!`. `prepare!`/validation/harmonize/capture/`build_analysis_model!`/`restore!` are unchanged. `build_pipeline`/`PipelineStage` were LEFT INTACT so `_run_method` and existing callers/tests still work.

## KNOWN LIMITATIONS carried forward (coordinator decision)
- **(Run 2)** Positional `stage_N` NodeKeys are param-dependent and MUST be replaced with content-stable identities before caching keys off `NodeKey`.
- **(Run 3)** Per-node `needs_sync::Bool` cannot express a single barrier-sync-after-a-wave, so it must become a level/barrier sync (or an explicit sync node) before per-group fine nodes are added.

Files: StructuralSynthesizer/src/design_graph/_design_graph.jl, StructuralSynthesizer/src/design_graph/node.jl, StructuralSynthesizer/src/design_graph/graph.jl, StructuralSynthesizer/src/design_graph/executor.jl, StructuralSynthesizer/src/design_workflow.jl, StructuralSynthesizer/src/StructuralSynthesizer.jl
