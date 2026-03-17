# BuildingStructure

> ```julia
> using StructuralSynthesizer
> using Unitful
> skeleton = gen_medium_office(30.0u"ft", 30.0u"ft", 13.0u"ft", 3, 3, 5)
> struc = BuildingStructure(skeleton)
> length(struc.columns)  # number of columns
> length(struc.beams)     # number of beams
> struc.asap_model        # Asap FEM model (nothing until to_asap!)
> ```

## Overview

`BuildingStructure` wraps a `BuildingSkeleton` with all the structural data needed for analysis and design. While the skeleton is purely geometric, the structure holds cells, slabs, segments, beams, columns, struts, supports, foundations, tributary caches, and the Asap FEM model.

`BuildingStructure` is **mutable** — it is modified in-place during the design pipeline. Functions like `initialize!`, `to_asap!`, `size_beams!`, and `size_columns!` all mutate the structure. The snapshot/restore mechanism preserves state across multiple design runs.

## Key Types

```@docs
AbstractBuildingStructure
BuildingStructure
```

## Functions

Construct a `BuildingStructure` by passing a `BuildingSkeleton`:

```julia
struc = BuildingStructure(skeleton)
```

This allocates all internal containers (cells, members, slabs, caches) and prepares the structure for the design pipeline.

## Implementation Details

### Fields

The structure contains the following major field groups:

| Field Group | Fields | Purpose |
|:------------|:-------|:--------|
| Geometry | `skeleton` | Underlying `BuildingSkeleton` |
| Cells & Slabs | `cells`, `cell_groups`, `slabs`, `slab_groups`, `slab_parallel_batches` | Floor-level structural data |
| Members | `segments`, `beams`, `columns`, `struts`, `member_groups` | Linear structural members |
| Foundations | `supports`, `foundations`, `foundation_groups` | Vertical load path termination |
| Site | `site` | `SiteConditions` for seismic/wind |
| Caches | `_tributary_caches`, `_analysis_caches` | Cached tributary and analysis results |
| Analysis | `asap_model`, `cell_tributary_loads`, `cell_dead_loads`, `cell_live_loads` | FEM model and load vectors |
| Snapshots | `_snapshots` | Design state snapshots for restore |

### Mutability Contract

The structure is designed to be mutated by the design pipeline in a specific order:

1. `initialize!` — populates cells, slabs, segments, members from skeleton geometry
2. `estimate_column_sizes!` — sets initial column cross-section dimensions
3. `to_asap!` — builds the Asap FEM model and solves for initial forces
4. Sizing stages — modify section properties, slab results, foundation results
5. `sync_asap!` — re-solves the FEM model after section changes

The `design_building` function takes a snapshot before step 1 and restores after capturing results, so the structure is effectively unchanged after a design run.

### Tributary Cache

The `_tributary_caches` field stores a `TributaryCache` that avoids recomputing Voronoi tributary areas during iterative design. See [Tributary Cache](tributary_cache.md) for details.

## Limitations & Future Work

- Only one `asap_model` is stored at a time; multiple simultaneous analyses require manual model management.
- The `site` field (`SiteConditions`) is populated but lateral analysis uses simplified story-level magnification factors rather than full dynamic response.
