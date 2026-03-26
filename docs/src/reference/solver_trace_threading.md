# Solver Trace (`TraceCollector`) Threading

The solver trace is the mechanism that makes design decisions explainable to downstream agents. A trace is a sequence of `TraceEvent`s emitted through a `TraceCollector` (`tc`) that is threaded through the design pipeline. When `tc === nothing`, `emit!` is a zero-cost no-op.

This page documents the **intended `tc` threading chain** from the building-level workflow down to the leaf sizing/optimizer functions. If a function in the chain fails to accept or forward `tc`, trace collection silently stops for everything below it.

## Core contract

- `tc` is passed as `tc::Union{Nothing, TraceCollector} = nothing`.
- Instrumentation uses `emit!(tc, layer, stage, element_id, event_type; kwargs...)`.
- Never guard `emit!` with `if tc !== nothing` — the `Nothing` method is already a no-op.
- Trace **at function/decision level**, not inside hot inner loops.

## StructuralSynthesizer → StructuralSizer (building-level workflow)

Entry points:

- `StructuralSynthesizer.design_building(struc, params; tc=tc)`
- `StructuralSynthesizer.design_building(struc; tc=tc, kwargs...)` (keyword convenience wrapper)

Threading chain:

1. `design_building` emits `:pipeline` events for the overall run and passes `tc` into `build_pipeline`.
2. `build_pipeline(params; tc=tc)` builds stage closures that **close over** `tc`.
3. Each stage closure calls into sizing routines and forwards `tc` via keyword argument where supported.

Key pipeline stages (typical):

- Slabs: `StructuralSizer.size_slabs!(struc; ... , tc=tc)`  
  - Per-slab dispatch: `StructuralSizer.size_slab!(...)` → `_size_slab!(...)` → method pipelines (e.g. `size_flat_plate!`) with `tc` passed through.
- Members: `size_beams!` / `size_columns!` / `size_members!` in Synthesizer analysis utilities (these already accept and emit trace events) ultimately call StructuralSizer’s member sizing APIs with `tc`.
- Foundations: `size_foundations!` stage(s) (some deeper helpers may not yet be traced; see the audit report).

## StructuralSizer slab sizing chain

Public entrypoints (emit and accept `tc`):

- `StructuralSizer.size_slabs!(struc; ... , tc=tc)`
- `StructuralSizer.size_slab!(struc, slab_idx; ... , tc=tc)`

Dispatch chain:

- `size_slab!` determines `ft = floor_type(slab.floor_type)` and calls:
  - `_size_slab!(ft, struc, slab, slab_idx; ... , tc=tc)`
  - which calls the method-specific pipeline (e.g. `size_flat_plate!(...; tc=tc)`).

## StructuralSizer member sizing chain

Public entrypoints (emit and accept `tc`):

- `StructuralSizer.size_columns(...; tc=tc)`
- `StructuralSizer.size_beams(...; tc=tc)`
- `StructuralSizer.size_members(...; tc=tc)` (dispatcher)

Leaf optimizer chain:

- Discrete catalog sizing forwards `tc` into:
  - `StructuralSizer.optimize_discrete(...; tc=tc)`
  - which emits `:optimizer` decisions (solver selection, feasibility screening, outcome).

## Optimizer alternatives (where tracing should land)

The codebase contains other solver backends (e.g. binary search, continuous/NLP). These should follow the same convention:

- Accept `tc` as a kwarg (default `nothing`)
- Emit a small set of `:enter`/`:decision`/`:exit`/`:failure` events
- Forward `tc` into any downstream decisions that already trace (or add trace events at the boundary)

If you add a new optimization backend, update this page to keep the documented threading chain accurate.

