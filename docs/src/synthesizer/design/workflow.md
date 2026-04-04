# Design Workflow & Pipeline

> ```julia
> struc  = BuildingStructure(skeleton)
> params = DesignParameters(loads = office_loads, floor = FlatPlateOptions())
> design = design_building(struc, params)
> design.summary.all_checks_pass  # true if all members adequate
> design.summary.embodied_carbon  # total kgCO₂e
> ```

## Overview

The design workflow orchestrates the full structural design of a building. The entry point is `design_building(struc, params)`, which prepares the structure, runs a configurable pipeline of sizing stages, captures the results into a `BuildingDesign`, and restores the structure to its original state.

The pipeline is built dynamically based on the floor type and design parameters, allowing different sequencing for flat plate systems (where columns depend on punching shear) versus beam-based systems (where iterative beam–column sizing is needed).

## Key Types

```@docs
PipelineStage
```

## Functions

```@docs
design_building
build_pipeline
prepare!
capture_design
```

## Implementation Details

### Pipeline Architecture

`build_pipeline(params)` returns a `Vector{PipelineStage}`, where each stage is:

```julia
struct PipelineStage
    fn::Function     # closure: (struc) -> nothing (params are captured)
    needs_sync::Bool # if true, sync_asap! is called after this stage
end
```

The pipeline runner iterates through stages, calling `stage.fn(struc)` (params are closed over when the stage is built) and optionally re-solving the FEM model with `sync_asap!` when `needs_sync == true`.

### Stages by Floor Type

**Flat plate / flat slab:**

| Stage | Function | Sync | Description |
|:------|:---------|:-----|:------------|
| 1 | `size_slabs!` | yes | Size all slabs (DDM, EFM, or FEA) |
| 2 | `_reconcile_columns!` | no | Grow columns if Asap axial > slab-design capacity (this stage self-syncs Asap when growth occurs) |
| 3 | `size_foundations!` | no | Size foundations (optional) |

**Beam-based systems (one-way, two-way, composite deck, timber):**

| Stage | Function | Sync | Description |
|:------|:---------|:-----|:------------|
| 1 | `size_slabs!` | yes | Size slabs to determine beam tributary loads |
| 2 | `_size_beams_columns!` | yes | Iterative beam and column sizing until convergence |
| 3 | `size_foundations!` | no | Size foundations (optional) |

**Vault:**

| Stage | Function | Sync | Description |
|:------|:---------|:-----|:------------|
| 1 | `size_slabs!` | yes | Size vault shells |
| 2 | `_size_beams_columns!` | yes | Size supporting members |
| 3 | `size_foundations!` | no | Size foundations (optional) |

### prepare!

`prepare!(struc, params)` runs the following sequence:

1. `initialize!(struc; ...)` — set up cells, slabs, segments, members
2. `estimate_column_sizes!(struc; fc)` — initial column sizing from tributary area
3. `to_asap!(struc; params)` — build Asap frame model and solve
4. `snapshot!(struc)` — save state for restoration (default key `:prepare`)

### capture_design

`capture_design(struc, params)` collects the current state of the structure into a `BuildingDesign`:
- Extracts `SlabDesignResult`, `ColumnDesignResult`, `BeamDesignResult`, `FoundationDesignResult` from each element
- Computes `DesignSummary` including material takeoffs and embodied carbon
- Records `compute_time_s` and timestamp
- Merges the optional **`tc`** trace into **`design.solver_trace`**; see [Solver trace threading](../../reference/solver_trace_threading.md)

### Snapshot / Restore

`design_building` uses the snapshot mechanism to leave `struc` unchanged:

1. `prepare!` calls `snapshot!(struc)` before any sizing (default key `:prepare`)
2. After `capture_design`, `restore!(struc; geometry_is_centerline=params.geometry_is_centerline)` reverts the structure
3. The caller can call `design_building` again with different parameters

### Pre-sizing validation (method applicability)

After `prepare!` builds the structure and analysis model, `design_building` runs `run_pre_sizing_validation(struc, params)` to check method applicability (DDM / EFM / FEA) for the selected floor system. If any slab panel is ineligible for its chosen method, `design_building` throws `PreSizingValidationError` (the HTTP API converts this into a 400 validation-style response).

### Uniform column sizing

If `params.uniform_column_sizing` is not `:off`, `design_building` performs a post-sizing harmonization pass via `harmonize_uniform_column_sizes!` **after** all sizing stages and **before** `capture_design`. This promotes columns within each group (per story or building-wide) to the governing size and re-solves the Asap model when any columns grow.

### P-Δ Second-Order Analysis

When second-order effects are significant, P-Δ analysis is triggered:
- **Trigger condition:** story drift ratio δs > 1.5 per ACI 318-11 §6.6.4.6.2 (§10.10 in older editions)
- **Method:** iterative geometric stiffness update via `p_delta_iterate!`
- **Implementation:** after each sizing pass, `compute_story_properties!` computes ΣPu, ΣPc, Vus, and Δo for each story, and the sway magnification factor δs = 1 / (1 - ΣPu/0.75ΣPc) per ACI 318-11 §10.10.7

### Column Reconciliation

In flat plate systems, `_reconcile_columns!` handles the circular dependency between column size and punching shear:
- After slab design, the punching shear check may assume a column size that the slab design requires
- If the Asap axial demand exceeds the slab-implied column capacity, the column is grown
- The FEM model is re-solved and slabs are re-checked

### compare_designs

`compare_designs(d1, d2)` produces a side-by-side comparison of two `BuildingDesign` objects, highlighting differences in member sizes, material quantities, embodied carbon, and pass/fail status. Useful for parameter studies.

### Solver trace (`TraceCollector`)

The **solver trace** is a structured timeline of solver/pipeline *decisions* (not every internal numeric step): which stage ran, whether the solver took a fallback, how iterations ended, or why a validation path failed. This makes runs explainable to users and to downstream tools (tiered summaries, chat, diagnostics).

- Pass an optional `tc = TraceCollector()` to `design_building(struc, params; tc=tc)`. Downstream code calls `StructuralSizer.emit!(tc, layer, stage, element_id, event_type; ...)` at meaningful points. If `tc === nothing`, those calls are no-ops.
- `capture_design` appends `tc.events` to `design.solver_trace` when `tc` is provided.
- The HTTP API always supplies a `TraceCollector()` so API runs have a populated solver trace for diagnostics and chat tooling.

For the full threading diagram, tier filters (`:summary` … `:full`), serialization helpers, and HTTP/LLM surfaces, see **[Solver trace threading](../../reference/solver_trace_threading.md)**.

## Options & Configuration

Key parameters affecting the pipeline:
- `params.floor` — determines which pipeline stages are built
- `params.max_iterations` — caps the iterative beam–column sizing loop
- `params.foundation_options` — controls whether foundations are sized
- `params.optimize_for` — objective function for section optimization (MinWeight, MinCarbon, etc.)

## Limitations & Future Work

- The pipeline is sequential; parallel sizing of independent stories is planned.
- Convergence of iterative beam–column sizing is monitored by section change but not formally proven to converge for all geometries.
- Lateral load stages (seismic, wind) are not yet integrated into the pipeline as explicit stages.

## References

- `StructuralSynthesizer/src/design_workflow.jl`
