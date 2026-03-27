# menegroth

> ```julia
> using StructuralSynthesizer
> using Unitful
> skeleton = gen_medium_office(30.0u"ft", 30.0u"ft", 13.0u"ft", 3, 3, 5)
> struc    = BuildingStructure(skeleton)
> result   = design_building(struc, DesignParameters(loads = office_loads))
> ```

## Overview

**menegroth** is an end-to-end building generation and structural design platform. It produces fully sized structural systems — beams, columns, slabs, and foundations — from a parametric building skeleton, complete with embodied carbon accounting and fire protection sizing.

The platform consists of two Julia packages plus an HTTP API:

| Package | Purpose | Key Entry Points |
|:--------|:--------|:-----------------|
| **StructuralSynthesizer** | Building-level workflows: geometry generation, tributary analysis, design pipelines, post-processing, and the HTTP API | `gen_medium_office`, `design_building`, `DesignParameters` |
| **StructuralSizer** | Component-level structural design: materials, loads, sections, design code checks (AISC 360, ACI 318, NDS), slab design, foundation design, and optimization | `A992_Steel`, `LoadCombination`, `FlatPlateOptions` |
| **Asap** | Units, type aliases, and finite element analysis (FEM) | `kip`, `ksi`, `psf`, `Model`, `solve!` |
| **StructuralPlots** | Makie themes, color palettes, figure utilities for publication-quality plots | `sp_light`, `sp_dark`, `fullwidth` |
| **StructuralStudies** | Parametric research studies built on StructuralSizer + StructuralPlots | — |

**Dependency chain:** `Asap` → `StructuralSizer` → `StructuralSynthesizer`

## How It Works

1. **Generate** a building skeleton (`BuildingSkeleton`) with plan dimensions, bay counts, and story heights.
2. **Wrap** the skeleton in a `BuildingStructure` that holds cells, members, slabs, and analysis caches.
3. **Design** the structure with `design_building`, which runs a multi-stage pipeline: initialize cells, estimate column sizes, build the FEM model, size beams/columns/slabs/foundations, and compute embodied carbon.
4. **Inspect** the returned `BuildingDesign` for member sizes, slab thicknesses, foundation dimensions, total weight, and embodied carbon breakdown.

## Documentation Sections

- **[Getting Started](getting_started.md)** — installation, first design, running the API
- **StructuralSizer**
  - [Overview](sizer/overview.md) — architecture, module organization, dispatch model
  - Materials — [Steel](sizer/materials/steel.md), [Concrete](sizer/materials/concrete.md), [FRC](sizer/materials/frc.md), [Timber](sizer/materials/timber.md), [Fire Protection](sizer/materials/fire_protection.md)
  - Loads — [Combinations](sizer/loads/combinations.md), [Gravity Loads](sizer/loads/gravity.md), [Pattern Loading](sizer/loads/pattern_loading.md)
  - Members — sections, design code checks, optimization
  - Slabs — flat plate / flat slab, waffle, hollow core, steel deck, vaults
  - Foundations — spread footings, piles
  - Optimization — solvers, objectives
- **StructuralSynthesizer**
  - Overview — building types, design workflow, tributary analysis
  - Generate — DOE building generators
  - Analyze — FEM integration, member/slab/foundation analysis
  - Post-Processing — embodied carbon, reports
- **[HTTP API](api/overview.md)** — endpoints, schema, deployment
- **Reference** — design codes index, [solver trace threading](reference/solver_trace_threading.md), type hierarchy

## Test Coverage

| Area | Tests | Status |
|------|-------|--------|
| Steel members (AISC) | AISC Design Examples validated | Full |
| RC columns (ACI) | StructurePoint validated (rect + circular + biaxial + slenderness) | Full |
| RC beams (ACI) | 106 tests, 3 StructurePoint examples (simply supported, cantilever, doubly reinforced) | Full |
| Flat plates | DDM + EFM + FEA validated | In Progress |
| Vaults | Validated against MATLAB (Haile) | Full |
| Foundations (ACI) | StructurePoint validated (spread, strip, mat) | Full |
| Foundations (IS 456) | Basic validation | Full |
| PixelFrame | 222 tests (capacities + checker + MIP) | Full |
| Tributaries | Edge + Voronoi + strip geometry | Full |
| Optimization | Column MIP + multi-material | Full |

## Safety-Critical Software

!!! warning "Structural Engineering Code"
    This codebase is used for **structural engineering design**. Incorrect code can lead to
    unsafe designs. Every calculation is treated as safety-critical:

    - All design code implementations cite specific clause numbers (e.g., AISC 360-16 §F2, ACI 318-19 §22.2).
    - Unit consistency is enforced via [Unitful.jl](https://github.com/PainterQubits/Unitful.jl) throughout.
    - Embodied carbon coefficients are sourced from the ICE Database v4.1.
    - Results should always be verified by a licensed professional engineer.
