# Foundation Types

> ```julia
> initialize_supports!(struc)
> initialize_foundations!(struc)
> group_foundations_by_reaction!(struc; tolerance = 0.1)
> size_foundations_grouped!(struc; soil = medium_sand, concrete = NWC_4000)
> struc.foundations[1].result  # SpreadFootingResult
> ```

## Overview

Foundations terminate the vertical load path from columns to the ground. The synthesizer extracts support reactions from the Asap FEM model, creates `Foundation` objects, groups them by similar demand levels, and dispatches to StructuralSizer's `design_footing` for code-compliant sizing.

## Key Types

```@docs
Support
Foundation
FoundationGroup
```

## Functions

All foundation functions are documented on their canonical page: [Foundations Analysis](../analyze/foundations.md).

- `initialize_supports!` — create `Support` objects from Asap model restraints
- `initialize_foundations!` — create `Foundation` objects from supports
- `group_foundations_by_reaction!` — group foundations by similar demand levels
- `size_foundations_grouped!` — design footings for each foundation group
- `build_foundation_groups!` — cluster foundations by properties
- `support_demands` — extract reaction demands from supports

## Implementation Details

### Support

A `Support{T,F,M,L}` represents a single restrained vertex in the Asap model:

| Field | Description |
|:------|:------------|
| `vertex_idx` | Skeleton vertex index |
| `node_idx` | Asap model node index |
| `forces` | Reaction forces (Fx, Fy, Fz) from Asap solution |
| `moments` | Reaction moments (Mx, My, Mz) from Asap solution |
| `foundation_type` | `AbstractFoundation` subtype (e.g., `SpreadFooting`) |
| `c1`, `c2` | Column dimensions at the support (for punching perimeter) |
| `shape` | Column shape at support |

### Foundation

A `Foundation{T,R}` groups one or more supports into a single footing:
- `support_indices` — which supports this foundation serves
- `result::R` — design result (`AbstractFoundationResult` subtype, e.g., `SpreadFootingResult`)
- `foundation_type` — type of foundation (spread, strip, mat, pile)
- `group_id` — index into `foundation_groups`
- `volumes` — `MaterialVolumes` for embodied carbon

### FoundationGroup

`FoundationGroup` clusters foundations with similar demands (within `group_tolerance`) so that a single design can be applied to the group. This reduces computation for buildings with many identical column loads. Fields: `hash`, `foundation_indices`.

### FoundationDemand

`FoundationDemand` (defined in StructuralSizer) encapsulates the axial and moment demands passed to `design_footing`:
- Axial compression (factored)
- Biaxial moments (Mx, My)
- Column dimensions for punching shear perimeter

### Grouping Algorithm

`group_foundations_by_reaction!` sorts foundations by total factored axial load and groups those within a relative tolerance (default 10%). The governing (maximum) demand in each group is used for design, ensuring conservative results for all members of the group.

## Options & Configuration

Foundation parameters are specified via `FoundationParameters` in `DesignParameters`:

| Parameter | Description |
|:----------|:------------|
| `soil` | Soil bearing capacity and properties |
| `concrete` | Foundation concrete material |
| `rebar` | Foundation reinforcement material |
| `pier_width` | Minimum pier/pedestal width |
| `min_depth` | Minimum footing depth |
| `group_tolerance` | Demand similarity threshold for grouping (default 0.1) |

## Limitations & Future Work

- Only `SpreadFooting` is fully implemented for automated design; `StripFooting`, `MatFoundation`, and deep foundations (`DrilledShaft`, `DrivenPile`) have code-level support in StructuralSizer but are not yet integrated into the synthesizer pipeline.
- Combined footings for closely-spaced columns are not automatically detected.
