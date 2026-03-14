# Beam, Column, Strut

> ```julia
> struc = BuildingStructure(skeleton)
> initialize!(struc; loads = office_loads, floor_type = :flat_plate)
> col = struc.columns[1]
> col.base.section       # current section assignment
> member_length(col)     # total member length
> all_members(struc)     # iterate over all beams, columns, struts
> ```

## Overview

Beams, columns, and struts are the linear structural members of a `BuildingStructure`. They all share a common `MemberBase` that stores segment indices, length, buckling parameters, section assignment, and material volumes. Each member type adds domain-specific fields.

## Key Types

```@docs
MemberBase
Beam
Column
Strut
MemberGroup
```

## Functions

```@docs
all_members
```

Related functions documented on their canonical pages:

- `initialize_segments!` — create `Segment` objects from skeleton edges (see [Initialize](../core/initialize.md))
- `initialize_members!` — create `Beam`, `Column`, `Strut` objects (see [Initialize](../core/initialize.md))
- `classify_column_position` — classify columns as interior/edge/corner (see [Members](../analyze/members.md))
- `group_collinear_members!` — merge aligned segments into members (see [Members](../analyze/members.md))
- `build_member_groups!` — cluster members by section requirements (see [Members](../analyze/members.md))
- `update_bracing!` — update bracing flags after analysis (see [Members](../analyze/members.md))
- `member_group_demands` — extract governing demands per group (see [Members](../analyze/members.md))

## Implementation Details

### AbstractMember

All members share the abstract base `AbstractMember{T}`. The concrete types wrap a `MemberBase{T}` with additional fields.

### MemberBase

`MemberBase{T}` stores:

| Field | Type | Description |
|:------|:-----|:------------|
| `segment_indices` | `Vector{Int}` | Indices into `struc.segments` |
| `L` | `T` | Total member length |
| `Lb` | `T` | Unbraced length for buckling |
| `Kx`, `Ky` | `Float64` | Effective length factors |
| `Cb` | `Float64` | Moment gradient coefficient (AISC §F1) |
| `group_id` | `Int` | Index into `member_groups` |
| `section` | `Union{AbstractSection, Nothing}` | Current section assignment |
| `pixel_design` | optional | PixelFrame design result |
| `volumes` | `MaterialVolumes` | Material quantities for EC |

### Beam

`Beam{T}` extends `MemberBase` with:
- `tributary_width` — tributary width for load collection from slabs
- `role` — `:girder`, `:beam`, `:joist`, or `:infill` (classified by `classify_beam_role`)

### Column

`Column{T}` extends `MemberBase` with:

| Field | Description |
|:------|:------------|
| `vertex_idx` | Skeleton vertex at column location |
| `c1`, `c2` | Cross-section dimensions (depth, width) |
| `shape` | `:rectangular` or `:circular` |
| `θ` | Rotation angle of section |
| `concrete` | `Concrete` material |
| `story` | Story index |
| `position` | `:interior`, `:edge`, or `:corner` (from `classify_column_position`) |
| `boundary_edge_dirs` | Edge directions at boundary for punching shear |
| `boundary_inward_normals` | Unit vectors pointing from boundary edges toward slab interior (for structural offset computation) |
| `structural_offset` | `(dx, dy)` offset in meters from architectural vertex to structural centerline |
| `braced` | Whether column is braced against sway |
| `story_properties` | Sway magnification data (ΣPu, ΣPc, Vus, Δo) per ACI 318-11 §10.10.7 |
| `tributary_cell_indices` | Cell indices contributing load |
| `tributary_cell_areas` | Tributary areas per cell |
| `column_above` | Index of column at story above (for load accumulation) |

### Strut

`Strut{T}` extends `MemberBase` with:
- `brace_type` — `:tension_only`, `:compression_only`, or `:both`

### MemberGroup

`MemberGroup` clusters members with identical section requirements for efficient batch optimization. Fields: `hash`, `member_indices`, `section`.

### Column Position Classification

`classify_column_position` uses the skeleton's `edge_face_counts` to determine whether a column vertex is interior (4 faces), edge (2-3 faces), or corner (1 face). This classification drives moment transfer fractions in flat plate design per ACI 318-11 §13.5.3.

## Options & Configuration

Member behavior is controlled by `DesignParameters`:
- `columns` — column material type (`:rc`, `:steel`), shape, bracing
- `beams` — beam material type, section catalog
- `fire_rating` — fire resistance requirement affecting minimum dimensions

## Limitations & Future Work

- Struts are defined but lateral bracing design is simplified; full brace-frame interaction is not yet implemented.
- Column shape is uniform per building; mixed rectangular/circular columns within a structure are not supported.
