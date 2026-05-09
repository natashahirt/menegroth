# Solver trace threading

The **solver trace** is a structured log of *decision points* in the sizing pipeline: which strategy ran, when a fallback fired, how an iteration ended, or why validation failed. It is **not** a dump of every numerical step—the goal is to make solver behavior legible to humans and to **LLM assistants** (chat tools, `GET /diagnose`, tiered trace payloads).

Implementation lives in `StructuralSizer/src/trace/trace.jl` (`TraceEvent`, `TraceCollector`, `emit!`, tier filters, serialization). The **design workflow** threads an optional collector through `design_building` and stores the result on the returned **`BuildingDesign`** in the **`solver_trace`** field.

## What gets recorded: `TraceEvent`

Each event has:

| Field | Meaning |
|:------|:--------|
| `timestamp` | Seconds since trace start |
| `layer` | One of **`:pipeline`**, **`:workflow`**, **`:sizing`**, **`:optimizer`**, **`:checker`**, **`:slab`** |
| `stage` | Human-readable label (e.g. `"design_building"`, `"size_slabs!"`) |
| `element_id` | Optional scope (e.g. slab index); may be empty |
| `event_type` | **`:enter`**, **`:exit`**, **`:decision`**, **`:iteration`**, **`:fallback`**, **`:failure`** |
| `data` | Keyword payload as a `Dict` (ratios, reasons, flags, counts) |

## `TraceCollector` and `emit!`

- Create a collector with `TraceCollector()` and pass it as **`tc`** into `design_building(struc, params; tc=tc)` (and through downstream calls that accept `tc`).
- At decision points, code calls **`emit!(tc, layer, stage, element_id, event_type; kwargs...)`**; each keyword becomes an entry in `data`.
- If **`tc === nothing`**, `emit!` is a **no-op**—no events and negligible cost, so call sites do not need `if tc !== nothing` guards.

```@docs
TraceCollector
emit!
TraceEvent
TracedFunctionMeta
```

## `@traced` and `TRACE_REGISTRY`

The **`@traced`** macro **does not** rewrite the function body. It only registers a **contract** in **`TRACE_REGISTRY`**: function name, layer, which `event_type`s the implementation should emit, and an optional **companion** symbol (e.g. post-hoc explainers). That supports automated trace-coverage audits and keeps obligations visible in source.

Where **`@traced` conflicts with docstrings**, the same metadata can be registered **manually** (see slab sizing: `TRACE_REGISTRY[(...)] = TracedFunctionMeta(...)`).

## End-to-end flow

1. **`design_building(struc, params; tc=tc)`** emits pipeline **`:enter`** / **`:exit`** around the full run (with timing metadata on exit).
2. **`build_pipeline(params; tc=tc)`** *composes* the stage vector (slabs, reconcile, beams/columns, foundations, …). Each stage closure captures `params` and (when provided) threads **`tc`** into the routines that emit events (for example `size_slabs!`).
3. **`design_building`** executes the returned stages, calling each `stage.fn(struc)` and then (when `stage.needs_sync`) calling `sync_asap!(struc; params=params)`.
4. **`capture_design(struc, params; tc=tc, ...)`** copies accumulated events onto **`design.solver_trace`**.

So the trace is a linear **`Vector{TraceEvent}`** attached to the returned **`BuildingDesign`**, suitable for JSON serialization or LLM-facing summaries.

## Breadcrumbs when `tc` is not passed

**`capture_design`** is written so that **some** trace is still useful when the caller never passed a collector (typical for HTTP/API paths that do not yet thread `tc` everywhere):

- A temporary `TraceCollector` may be used so **`_emit_member_breadcrumbs!`** can append **low-volume** “post-processing” events after results exist (e.g. top exemplars by ratio), without re-running checkers.
- Those events are merged into **`design.solver_trace`** alongside any events from a real **`tc`**.

If **`solver_trace` is empty**, the design may have been produced outside this path, or tracing was not enabled for that client.

## Tiers, filters, and LLM-oriented output

**`TRACE_TIERS`** (`:summary`, `:failures`, `:decisions`, `:full`) control how much detail is exposed: e.g. summary focuses on pipeline/workflow **enter/exit**; broader tiers include **failure**, **fallback**, **decision**, and **iteration** events across layers.

Helpers **`filter_trace`**, **`serialize_trace_event`**, and **`build_stage_timeline`** turn raw events into JSON-friendly structures. The HTTP agent layer uses **`agent_solver_trace`** (see `StructuralSynthesizer/src/api/agent_tools.jl`) to return a **tiered** dict (with hints to request a deeper tier or a narrower element/layer filter).

The versioned **`GET /schema/llm_contract`** response includes **`trace_tiers`** and **`trace_layers`** so clients know the vocabulary.

```@docs
filter_trace
```

## See also

- [Design workflow & pipeline](../synthesizer/design/workflow.md) — entry point `design_building` and pipeline stages
- `StructuralSynthesizer/src/api/agent_tools.jl` — `agent_solver_trace`
- `StructuralSizer/src/trace/trace.jl` — definitions and filters
