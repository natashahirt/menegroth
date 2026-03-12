# Cells, Slabs & Stories

> ```julia
> struc = BuildingStructure(skeleton)
> initialize!(struc; loads = office_loads, floor_type = :flat_plate)
> struc.cells[1].area        # tributary area of first cell
> struc.slabs[1].floor_type  # FlatPlate, Vault, CompositeDeck, etc.
> struc.slabs[1].result      # AbstractFloorResult after sizing
> ```

## Overview

Cells and slabs model the floor system at the building level. A **Cell** represents a single floor panel (one face of the skeleton) with its loading, spans, and floor type. Cells are grouped into **Slabs** for design — a slab may contain one or more cells that share a common structural system. **Stories** organize cells and members by elevation.

## Key Types

```@docs
Story
SiteConditions
Cell
CellGroup
Slab
SlabGroup
Segment
```

## Functions

- `initialize_cells!` — create `Cell` objects from skeleton faces (canonical: [Initialize](../core/initialize.md))
- `initialize_slabs!` — group cells into `Slab` objects (canonical: [Initialize](../core/initialize.md))
- `build_slab_groups!` — cluster slabs by properties for batch design
- `build_cell_groups!` — cluster cells by properties
- `compute_cell_tributaries!` — compute tributary areas for load distribution
- `update_slab_volumes!` — update material volumes after slab sizing (canonical: [Slabs](../analyze/slabs.md))

## Implementation Details

### Story

A `Story{T}` stores:
- `elevation::T` — Z coordinate of the story level
- `vertices`, `edges`, `faces` — indices into the skeleton arrays for elements at this level

Stories are inferred from unique vertex Z coordinates by `rebuild_stories!`.

### SiteConditions

`SiteConditions` holds site-specific parameters for lateral load analysis:
- Seismic: `Ss`, `S1`, `site_class`, `risk_category`
- Wind: `wind_speed`, `exposure_category`, `topographic_factor`
- Other: `soil`, `ground_snow_load`

### Cell

Each `Cell{T,A,P}` corresponds to one face of the skeleton and stores:
- `face_idx` — index into the skeleton's face array
- `area` — face area (tributary area for loading)
- `spans::SpanInfo{T}` — clear spans in principal directions
- `sdl`, `live_load`, `self_weight` — loading intensities (force/area)
- `floor_type` — the `AbstractFloorSystem` subtype (e.g., `FlatPlate`, `CompositeDeck`)
- `position` — `:interior`, `:edge`, or `:corner` classification

### CellGroup

`CellGroup` clusters cells with identical properties (same spans, loads, floor type) via a hash for efficient batch design. Fields: `hash::UInt64`, `cell_indices::Vector{Int}`.

### Slab

A `Slab{T}` groups one or more cells into a designable unit:
- `cell_indices` — which cells this slab covers
- `result::AbstractFloorResult` — design result from StructuralSizer (e.g., `FlatPlatePanelResult`)
- `floor_type` — structural system type
- `spans::SpanInfo{T}` — governing span dimensions
- `position` — edge classification for moment distribution
- `group_id` — index into `slab_groups` for batch processing
- `volumes` — `MaterialVolumes` for embodied carbon accounting
- `drop_panel` — drop panel dimensions (flat slab only)
- `design_details` — detailed design output

### SlabGroup

`SlabGroup` groups slabs with similar properties (`hash`, `slab_indices`) to avoid redundant design calculations.

### Segment

A `Segment{T}` represents a single span of a member between supports:
- `edge_idx` — skeleton edge index
- `L` — segment length
- `Lb` — unbraced length for lateral-torsional buckling
- `Cb` — moment gradient factor

## Options & Configuration

Cell initialization is controlled by the arguments to `initialize!`:
- `loads` — `GravityLoads` specifying floor/roof/grade dead and live loads
- `floor_type` — `Symbol` (`:auto`, `:flat_plate`, `:vault`, etc.)
- `floor_opts` — `AbstractFloorOptions` subtype with method-specific settings
- `tributary_axis` — principal axis for one-way spanning behavior
- `cell_groupings` — optional manual cell grouping overrides

## Limitations & Future Work

- Cells are assumed to have uniform loading within each face. Variable-intensity loads (e.g., corridor vs. office) require manual cell grouping.
- Mixed floor types within a single story are supported via cell groupings but are not automatically detected.
