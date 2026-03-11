# Slab Analysis

> ```julia
> initialize_cells!(struc; loads = office_loads, floor_type = FlatPlate)
> initialize_slabs!(struc)
> compute_cell_tributaries!(struc)
> size_slabs!(struc, params)
> ```

## Overview

Slab analysis dispatches each slab to the appropriate analysis method based on its floor type. For flat plates, this means DDM, EFM, or FEA. For beam-based systems, it computes tributary widths for beam load collection. The module also handles cell initialization, slab grouping, and tributary computation.

**Source:** `StructuralSynthesizer/src/analyze/slabs/*.jl`

## Functions

### Initialization

```@docs
compute_slab_parallel_batches!
```

### Analysis

```@docs
update_slab_volumes!
slab_summary
```

## Implementation Details

### Analysis Method Dispatch

Slab analysis routes to different methods based on the `floor_type` and `floor_options`:

| Floor Type | Method | Code Reference | Description |
|:-----------|:-------|:---------------|:------------|
| `FlatPlate` | `DDM()` | ACI 318-11 §13.6 | Direct Design Method — static moment distribution |
| `FlatPlate` | `EFM()` | ACI 318-11 §13.7 | Equivalent Frame Method — frame analysis |
| `FlatPlate` | `FEA()` | — | Finite element slab analysis |
| `FlatPlate` | `RuleOfThumb()` | — | Quick estimate from span/thickness tables |
| `FlatSlab` | Same as FlatPlate | ACI 318-11 §13.6/§13.7 | Adds drop panel design |
| `OneWay` | Beam theory | ACI 318-11 §9.5 | One-way slab spanning to beams |
| `CompositeDeck` | Deck tables | AISC Manual | Steel deck + concrete topping |
| `Vault` | `HaileAnalytical` or `ShellFEA` | Research | Thin-shell vault analysis |
| `CLT`/`NLT`/`DLT` | Panel design | NDS | Mass timber panel design |

### Cell Grid Construction

For DDM and EFM, cells must be organized into structured grids. The process:

1. `build_cell_grid(cell_indices, get_centroid)` arranges cells into a `CellGrid`
2. Grid rows and columns correspond to frame lines in X and Y
3. The grid enables span identification and column/middle strip assignment

### Tributary Width Computation

For beam-based systems, slab analysis computes tributary widths that determine the distributed load on each beam:

1. Voronoi decomposition splits each cell's area between its edges
2. The tributary width for each edge determines the beam's distributed load
3. Results are cached in the `TributaryCache` for reuse across iterations

### Slab Grouping

`build_slab_groups!` identifies slabs with identical properties (spans, loads, floor type, position) and assigns them to groups. Only the governing slab in each group is fully analyzed; results are applied to all group members. This significantly reduces computation for regular grid buildings.

### Parallel Batching

`compute_slab_parallel_batches!` identifies slabs that can be sized independently (no shared column dependencies) and organizes them into parallel batches for potential concurrent execution.

## Options & Configuration

| Option | Description |
|:-------|:------------|
| `floor_type` | `AbstractFloorSystem` subtype |
| `floor_opts.method` | Analysis method for flat plates and flat slabs (DDM, EFM, FEA, RuleOfThumb) |
| `floor_opts.deflection_limit` | L/n deflection limit |
| `floor_opts.punching_strategy` | Punching shear strategy (increase thickness, add studs, use drop panels) |

## Limitations & Future Work

- FEA slab analysis creates a separate shell model per slab; a unified building-level slab FEA is planned.
- Post-tensioned slab analysis (PTBanded) is defined as a type but not fully implemented.
- Mixed floor types within a single story are supported but require manual cell grouping.
