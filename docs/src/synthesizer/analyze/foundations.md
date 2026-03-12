# Foundation Analysis

> ```julia
> initialize_supports!(struc)
> initialize_foundations!(struc)
> group_foundations_by_reaction!(struc; tolerance = 0.1)
> size_foundations_grouped!(struc;
>     soil = medium_sand, concrete = NWC_4000, rebar = Rebar_60)
> ```

## Overview

Foundation analysis extracts support reactions from the Asap FEM model, creates foundation objects, groups them by similar demand levels, and dispatches to StructuralSizer's foundation design routines. The grouping mechanism avoids redundant design calculations for buildings with many columns at similar load levels.

**Source:** `StructuralSynthesizer/src/analyze/foundations/*.jl`

## Functions

```@docs
initialize_supports!
support_demands
initialize_foundations!
size_foundations!
size_foundations_grouped!
group_foundations_by_reaction!
build_foundation_groups!
foundation_summary
foundation_group_summary
```

## Implementation Details

### Support Initialization

`initialize_supports!(struc)` extracts reaction forces and moments from the solved Asap model for each restrained vertex. Each support stores:
- `vertex_idx` and `node_idx` for cross-referencing
- `forces` (Fx, Fy, Fz) — factored reactions from the governing load combination
- `moments` (Mx, My, Mz) — factored reaction moments
- `c1`, `c2`, `shape` — column dimensions at the support for punching perimeter

### Foundation Grouping

`group_foundations_by_reaction!(struc; tolerance)` groups foundations by similar axial demands:

1. Sort foundations by total factored axial load (Fz)
2. Starting from the highest load, group foundations within `tolerance` (default 10%) of the group's maximum load
3. The governing demand (maximum in the group) is used for design

This is conservative: all foundations in a group are sized for the worst-case demand. For a typical 5-story, 3×3 bay building, grouping reduces the number of foundation designs from ~16 to ~3–5.

### Foundation Sizing

`size_foundations_grouped!(struc; soil, concrete, rebar, ...)` designs all foundation groups:

1. For each group, constructs a `FoundationDemand` from the governing support reactions
2. Calls `StructuralSizer.design_footing(::SpreadFooting, demand; ...)` per ACI 318-11:
   - Bearing pressure check against soil capacity
   - One-way shear: §11.11.1.2
   - Two-way (punching) shear: §11.11.3
   - Flexure: Whitney stress block
3. Assigns the result to all foundations in the group
4. Updates `MaterialVolumes` for embodied carbon

### Demand Extraction

`support_demands(struc)` computes `FoundationDemand` for each support:
- Axial: vertical reaction from gravity load combinations
- Moments: base moments from frame action and eccentricity
- Column dimensions: used for punching shear perimeter

## Options & Configuration

Foundation sizing is controlled by `FoundationParameters` in `DesignParameters`:

| Parameter | Description | Default |
|:----------|:------------|:--------|
| `soil` | Soil bearing capacity and type | Required |
| `concrete` | Foundation concrete material | `NWC_4000` |
| `rebar` | Foundation reinforcement | `Rebar_60` |
| `pier_width` | Minimum pedestal width | 12 in |
| `min_depth` | Minimum footing depth | 12 in |
| `group_tolerance` | Demand similarity threshold | 0.10 |

## Limitations & Future Work

- Only `SpreadFooting` is fully integrated; strip footings, mat foundations, and deep foundations are available in StructuralSizer but require manual invocation.
- Foundation design uses single-column reactions; combined footings for closely-spaced columns are not automatically detected.
- Uplift and lateral soil reactions are not considered.
