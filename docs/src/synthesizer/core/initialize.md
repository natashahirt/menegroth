# Initialization

> ```julia
> struc = BuildingStructure(skeleton)
> initialize!(struc;
>     loads = office_loads, floor_type = :flat_plate,
>     floor_opts = FlatPlateOptions(method = DDM()),
> )
> estimate_column_sizes!(struc; fc = 4000psi)
> ```

## Overview

Initialization transforms a bare `BuildingStructure` (which has only a skeleton) into a fully populated structure with cells, slabs, segments, members, and initial column estimates. This is the first step in the design pipeline, called by `prepare!`.

## Functions

```@docs
initialize!
initialize_cells!
initialize_slabs!
initialize_segments!
initialize_members!
```

## Implementation Details

### initialize!

`initialize!(struc; loads, material, floor_type, floor_opts, tributary_axis, cell_groupings, slab_group_ids, braced_by_slabs)` orchestrates the full initialization sequence:

1. **`initialize_cells!`** — Creates a `Cell` for each face in the skeleton. Sets area, spans, loading (SDL, LL from `GravityLoads`), floor type, and position classification.

2. **`initialize_slabs!`** — Groups cells into `Slab` objects. By default, each cell becomes its own slab; custom groupings can merge multiple cells into a single slab for EFM analysis of multi-panel systems.

3. **`initialize_segments!`** — Creates a `Segment` for each beam/brace edge in the skeleton. Computes span length `L`, unbraced length `Lb`, and moment gradient factor `Cb`.

4. **`initialize_members!`** — Creates `Beam`, `Column`, and `Strut` objects from the skeleton edge groups:
   - Beams are created from `:beams` edges, with `classify_beam_role` assigning `:girder`, `:beam`, `:joist`, or `:infill` roles
   - Columns are created from `:columns` edges, with `classify_column_position` determining `:interior`, `:edge`, or `:corner`
   - Struts are created from `:braces` edges
   - `link_column_stack!` connects columns vertically for load accumulation
   - `compute_column_tributaries!` assigns tributary areas

5. **`build_slab_groups!`** — Groups slabs with identical properties for batch design.

6. **`build_cell_groups!`** — Groups cells with identical properties.

7. **`compute_cell_tributaries!`** — Computes and caches Voronoi tributary polygons for each cell edge.

### estimate_column_sizes!

`estimate_column_sizes!(struc; fc)` provides initial column dimensions using tributary area load accumulation:

- For each column, accumulates the tributary dead + live load from the column above down to the current story
- Estimates required area as `Pu / (0.4 * fc)` (rough axial capacity approximation)
- Sets `c1` and `c2` to the square root of the required area (square columns)
- These estimates are refined during the iterative design pipeline

## Options & Configuration

| Parameter | Description | Default |
|:----------|:------------|:--------|
| `loads` | `GravityLoads` — dead and live loads | `GravityLoads()` |
| `material` | `AbstractMaterial` for slab sizing and self-weight | `NWC_4000` |
| `floor_type` | `Symbol` (`:auto`, `:flat_plate`, `:vault`, etc.) | `:auto` |
| `floor_opts` | `AbstractFloorOptions` | `FlatPlateOptions()` |
| `tributary_axis` | Principal spanning direction for one-way systems | `nothing` (auto) |
| `cell_groupings` | Manual cell → slab mapping | Auto-detected |
| `slab_group_ids` | Manual slab group assignments | Auto-grouped |
| `braced_by_slabs` | Whether slabs brace beams laterally | `true` |

## Limitations & Future Work

- Initial column sizing uses a simplified axial-only estimate; moment demands from lateral loads or eccentricity are not considered until the FEM model is built.
- Cell groupings for multi-panel EFM analysis must be specified manually for non-rectangular layouts.
