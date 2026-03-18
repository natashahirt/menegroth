# Tributary Area Accessors

> ```julia
> using StructuralSynthesizer
> using Unitful
>
> skel = gen_medium_office(30.0u"ft", 30.0u"ft", 13.0u"ft", 3, 3, 2)
> struc = BuildingStructure(skel)
> initialize!(struc; floor_type=:flat_plate)
> compute_cell_tributaries!(struc)
>
> col = struc.columns[1]
> A_trib = column_tributary_area(struc, col)
> by_cell = column_tributary_by_cell(struc, col)
> polys = column_tributary_polygons(struc, col)
> ```

## Overview

Tributary area accessors provide convenient functions to query the cached Voronoi tributary results for columns and cell edges. These functions **read from** the `TributaryCache` stored in the `BuildingStructure` and return `nothing`/empty results if tributaries have not been computed yet. Compute and populate the cache with `compute_cell_tributaries!(struc)` before calling the accessors.

## Key Types

```@docs
TributaryPolygon
VertexTributary
TributaryBuffers
```

## Functions

### Column Tributaries

```@docs
column_tributary_area
column_tributary_by_cell
column_tributary_polygons
```

### Cell / Edge Tributaries

```@docs
cell_edge_tributaries
cell_strip_geometry
has_cell_tributaries
```

### Cache Management

```@docs
tributary_cache_key
get_cached_column_tributary
cache_column_tributary!
get_cached_edge_tributaries
cache_edge_tributaries!
clear_geometry_caches!
```

## Implementation Details

### Column Tributary Area

`column_tributary_area(struc, col)` returns the total tributary area for a column by summing contributions from all adjacent cells. The tributary area is computed using Voronoi decomposition of each cell's face polygon around the column vertex.

### Per-Cell Breakdown

`column_tributary_by_cell(struc, col)` returns a `Dict{Int, AreaQuantity}` mapping cell indices to their tributary area contributions. This is used for:
- Load accumulation on columns (dead load × tributary area)
- Initial column sizing estimates
- Punching shear tributary area computation

### Column Tributary Polygons

`column_tributary_polygons(struc, col)` returns the raw Voronoi polygon vertices for each contributing cell. These are used for visualization and for computing strip geometries.

### Cell Edge Tributaries

`cell_edge_tributaries(struc, cell)` returns the tributary widths along each edge of a cell. These widths determine how much load each edge's beam collects from the slab. For two-way systems, the tributary width varies along the edge based on the Voronoi partition.

### Cell Strip Geometry

`cell_strip_geometry(struc, cell)` returns the column strip / middle strip split per ACI 318-11 §13.6.4. The strip geometry defines:
- Column strip width: the lesser of `l₂/2` or `l₁/4` on each side of the column centerline
- Middle strip: the remainder between column strips

This is used by DDM and EFM for moment distribution.

### Caching Strategy

All tributary computations use a two-level cache:

1. **Check cache** — `get_cached_*` returns the cached result or `nothing`
2. **Compute and store** — if not cached, compute the tributary and call `cache_*!`

The cache key (`TributaryCacheKey`) ensures that different spanning behaviors and axis orientations maintain separate cache entries. Caches persist across design iterations since tributary geometry depends only on the skeleton, not on section sizes.

## Limitations & Future Work

- Voronoi tributary computation assumes convex cell polygons; non-convex cells may produce incorrect tributary areas.
- Strip geometry is only computed for two-way systems (DDM/EFM); one-way systems use simpler half-span tributary widths.
