# StructuralSynthesizer Overview

> ```julia
> using StructuralSynthesizer
> using Unitful
> skeleton = gen_medium_office(30.0u"ft", 30.0u"ft", 13.0u"ft", 3, 3, 5)
> struc    = BuildingStructure(skeleton)
> design   = design_building(struc, DesignParameters(loads = office_loads))
> ```

## Overview

**StructuralSynthesizer** is the building-level design workflow package. It sits on top of **StructuralSizer** and re-exports everything from it via `@reexport`, so a single `using StructuralSynthesizer` gives access to materials, loads, sections, code checks, slab design, and foundation design alongside the building-level pipeline.

The package also depends on:

| Dependency | Role |
|:-----------|:-----|
| **Asap** | Finite element analysis — frame models, shell elements, units + type aliases (re-exported via `StructuralSizer`) |
| **Meshes.jl** | Geometry primitives — `Point`, `Segment`, `Ngon` for vertices, edges, faces |
| **Graphs.jl** | Connectivity graph of the structural skeleton |
| **Unitful.jl** | Compile-time unit checking throughout |

## Module Organization

The package is organized into the following submodules, included in order:

| Module | Purpose | Key Files |
|:-------|:--------|:----------|
| `building_types` | Core data structures for skeletons, structures, cells, members, foundations | `skeleton.jl`, `structure.jl`, `cells.jl`, `members.jl`, `foundations.jl` |
| `design_types` | Design parameters, material options, result types, `BuildingDesign` | `design_types.jl` |
| `core` | Initialization, sizing dispatch, tributary accessors, snapshots | `initialize.jl`, `size.jl`, `tributary_accessors.jl`, `snapshot.jl` |
| `design_workflow` | Multi-stage pipeline: `design_building`, `build_pipeline`, `prepare!` | `design_workflow.jl` |
| `geometry` | Frame line extraction, slab validation and decomposition | `frame_lines.jl`, `slab_validation.jl` |
| `generate` | Parametric building generators (DOE) | `doe/medium_office.jl` |
| `analyze` | FEM integration (Asap), member/slab/foundation analysis | `asap/`, `members/`, `slabs/`, `foundations/` |
| `postprocess` | Embodied carbon computation, engineering reports | `ec.jl`, `engineering_report.jl` |
| `api` | HTTP API routes, JSON serialization, validation | `routes.jl`, `schema.jl`, `serialize.jl` |

## Key Workflow

The typical design workflow follows four steps:

1. **Generate** — Create a `BuildingSkeleton` with `gen_medium_office` (or from API JSON).
2. **Wrap** — Construct a `BuildingStructure` from the skeleton, which allocates cells, members, slabs, and caches.
3. **Design** — Call `design_building(struc, params)`, which runs:
   - `prepare!` — initialize cells, estimate column sizes, build Asap model, snapshot
   - Pipeline stages — size slabs → size beams/columns (iterative) → size foundations
   - `capture_design` — collect all results into a `BuildingDesign`
   - Restore — return `struc` to its pre-design state via snapshot
4. **Inspect** — Query the `BuildingDesign` for member sizes, slab thicknesses, embodied carbon, and pass/fail status.

## Key Types

- `BuildingSkeleton` — geometry container (vertices, edges, faces)
- `BuildingStructure` — structural data wrapper
- `DesignParameters` — design configuration
- `BuildingDesign` — results container

```@docs
AbstractStructuralSynthesizer
PreSizingValidationError
```

## Key Functions

- `gen_medium_office` — parametric building generator
- `design_building` — main design entry point
- `prepare!` — initialization + FEM model setup
- `capture_design` — collect results into BuildingDesign

## Implementation Details

The `@reexport using StructuralSizer` directive in `StructuralSynthesizer.jl` means that all exports from `StructuralSizer` — materials, sections, load types, design code functions — are available directly from `StructuralSynthesizer`. The synthesizer extends several `StructuralSizer` functions for its own wrapper types (e.g., `self_weight`, `total_depth`, and `structural_effects` are extended for `Slab`).

The design pipeline uses a snapshot/restore pattern so that `design_building` is non-destructive: the `BuildingStructure` is returned to its original state after design, while the `BuildingDesign` captures all results. This allows multiple `design_building` calls on the same structure with different parameters.

## Limitations & Future Work

- Currently only `gen_medium_office` is implemented as a building generator; more building archetypes (residential towers, warehouses, parking structures) are planned.
- Lateral load analysis (seismic, wind) uses simplified story-level properties rather than full 3D dynamic analysis.
- Eurocode 2 and Eurocode 3 code checks are planned but not yet implemented.
