# Solver Trace (`TraceCollector`) Threading

The solver trace is the mechanism that makes design decisions explainable to downstream agents. A trace is a sequence of `TraceEvent`s emitted through a `TraceCollector` (`tc`) that is threaded through the design pipeline. When `tc === nothing`, `emit!` is a zero-cost no-op.

This page documents the **intended `tc` threading chain** from the building-level workflow down to the leaf sizing/optimizer functions. If a function in the chain fails to accept or forward `tc`, trace collection silently stops for everything below it.

## Core contract

- `tc` is passed as `tc::Union{Nothing, TraceCollector} = nothing`.
- Instrumentation uses `emit!(tc, layer, stage, element_id, event_type; kwargs...)`.
- Never guard `emit!` with `if tc !== nothing` — the `Nothing` method is already a no-op.
- Trace **at function/decision level**, not inside hot inner loops.

## Breadcrumb bundles (post-hoc microscope handles)

In addition to the regular decision trace (optimizer iterations, fallbacks, etc.), the pipeline emits **low-volume breadcrumb bundles** that make it possible to “zoom in later” during post-processing even if you didn’t know ahead of time which element you would want to inspect.

Current behavior:

- Breadcrumbs are emitted during `StructuralSynthesizer.capture_design(...)` after column/beam results have been populated.
- Breadcrumb events live at `layer = :workflow`, `stage = "breadcrumbs_members"`, `event_type = :decision`.
- A summary event is emitted per member type, plus up to a bounded number of per-group events.

Schema (stable contract, `version=1`):

- Group event: `data.breadcrumbs_kind == "member_group"`
  - `data.member_type`: `"beams"` or `"columns"`
  - `data.group_id`: `String` (the resolved `UInt64` group id)
  - `data.group_max_ratio`: `Float64`
  - `data.top_elements`: array of top‑k exemplars (default k=3), each with:
    - `element_id`: `"beam_<idx>"` or `"column_<idx>"`
    - `governing_check`: `String`
    - `governing_ratio`: `Float64`
    - `ok`: `Bool`
    - `lookup`: compact key used for post-hoc resolution:
      - `version`: `1`
      - `kind`: `"member"`
      - `member_type`: `"beam"` or `"column"`
      - `member_idx`: `Int` (1-based index into `struc.beams` / `struc.columns`)
      - `group_id`: `String` (same as above)

Post-hoc microscope:

- The API tool `explain_trace_lookup` accepts the `lookup` dict from a breadcrumb and reconstructs the inputs needed to run `StructuralSizer.explain_feasibility` for the designed section of that element.

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

