# Member Analysis

> ```julia
> using StructuralSynthesizer
> using Unitful
> using Asap
>
> # Minimal structure for member analysis (small grid, 1 story)
> skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
> struc = BuildingStructure(skel)
>
> # Build + solve the first-order model
> initialize!(struc; floor_type = :flat_plate)
> to_asap!(struc)
> Asap.process!(struc.asap_model)
> Asap.solve!(struc.asap_model)
>
> # Size steel members and run story/P-Δ utilities
> beam_opts = SteelBeamOptions(deflection_limit = 1/360)
> col_opts  = SteelColumnOptions()
> size_beams!(struc, beam_opts)
> size_columns!(struc, col_opts)
> compute_story_properties!(struc)
> p_delta_iterate!(struc)
> ```

## Overview

Member analysis extracts demands from the Asap FEM model and sizes beams and columns using StructuralSizer’s catalog-based sizing APIs. Steel members are checked per AISC 360 via `AISCChecker` (with optional deflection constraints). RC members are sized using ACI 318 checks via StructuralSizer’s concrete checkers (catalog-based MIP and/or continuous NLP, depending on options). The module also computes story-level properties used by the P-Δ second-order iteration utilities.

**Source:** `StructuralSynthesizer/src/analyze/members/*.jl`

## Functions

### Sizing

```@docs
size_beams!
size_columns!
size_steel_members!
size_members!
estimate_column_sizes!
```

### Story Properties

```@docs
compute_story_properties!
p_delta_iterate!
```

### Grouping & Demands

```@docs
member_group_demands
build_member_groups!
group_collinear_members!
```

### Classification & Structural Offsets

```@docs
classify_column_position
is_exterior_support
update_bracing!
update_structural_offsets!
structural_center_xy_m
```

## Implementation Details

### Steel Member Sizing

`size_steel_members!` is a steel-only sizing helper that sizes one edge group (`:beams`, `:columns`, or `:struts`) from a steel section catalog:

1. Extracts group demands from the Asap model (axial, flexure, shear, and optionally deflection envelopes when available)
2. Builds `SteelMemberGeometry` for each group (L, Lb, K, Cb)
3. Checks feasibility with `StructuralSizer.AISCChecker` (shear, flexure, compression/tension, and P–M interaction; with optional LL / total deflection limits when provided)
4. Selects the minimum-objective feasible section (e.g., `MinWeight`, `MinCarbon`)

**Automatic solver selection (`size_steel_members!`):** The solver is chosen based on `n_max_sections`:
- `n_max_sections == 0` (default) — uses `optimize_binary_search`, which sorts the catalog by weight and binary-searches for the lightest feasible section per group. This is fast and has no solver dependencies.
- `n_max_sections > 0` — uses `optimize_discrete` (MIP via JuMP/HiGHS or Gurobi), which can enforce shared-section constraints across groups.

Both solvers produce identical per-group results when there are no shared-section constraints.

For the primary dispatchers `size_beams!` and `size_columns!`, steel sizing routes through StructuralSizer’s `size_beams` / `size_columns` APIs (discrete catalog MIP, with optional `n_max_sections` constraints controlled by the options).

### Collinear Member Grouping

When `DesignParameters.collinear_grouping = true`, `size_beams!` and `size_columns!` automatically call `group_collinear_members!` before sizing. This detects chains of members that share a node and have parallel direction vectors, and assigns them a common `group_id`. The optimizer then assigns a single section to the entire chain, producing uniform member sizes along continuous lines — a common constructability requirement.

### RC Column Sizing

RC columns use ACI 318-11 interaction diagram checks:
- Axial: ACI 318-11 §10.3.6.2
- Slenderness: ACI 318-11 §10.10 (magnification factor method)
- Biaxial interaction: P-Mx-My interaction surface

### RC Beam Sizing

RC beams use ACI 318-11:
- Flexure: §9.5 / §10.2 (Whitney stress block)
- Shear: §11.2 (Vc), §11.4 (Vs)
- T-beam flange width: §8.12.2
- Effective moment of inertia: Eq. 9-10 (Branson)

### compute_story_properties!

`compute_story_properties!(struc)` computes and assigns story-level properties to each column (stored on `col.story_properties`) for sway / P-Δ workflows:

| Property | Description | Reference |
|:---------|:------------|:----------|
| ΣPu | Sum of factored axial loads on all columns in the story | Analysis / moment magnification inputs |
| ΣPc | Sum of estimated critical buckling loads (initially based on simplified stiffness until final sections are known) | Moment magnification inputs |
| Vus | Factored story shear (from analysis when available; otherwise an estimate) | Moment magnification inputs |
| Δo | First-order inter-story drift extracted from the solved model (fallback used if unsolved) | Analysis |
| lc | Story height proxy (average column length in story) | Analysis |

### P-Δ Iteration

`p_delta_iterate!(struc)` performs an elastic P-Δ second-order iteration on the existing Asap model:

1. Extracts current story drifts and column axial forces from the solved model
2. Applies equivalent lateral P-Δ forces at each story level using \(F_{P\Delta} = \Sigma P_u \, \Delta / l_c\)
3. Re-solves and repeats until drifts converge (or `max_iter` is reached)
4. Flags stories whose second-order drift amplification exceeds the implementation’s 1.4 ratio check

This utility is intended to provide a practical second-order amplification loop for frame analysis; it does not replace a full nonlinear second-order analysis when required by the governing code provisions.

### Member Group Demands

`member_group_demands(struc, group)` extracts the governing demand envelope from the Asap model for a member group, considering all load combinations. Returns the critical (Mu, Vu, Pu, Tu) that governs the design.

### Structural Column Offsets

When `DesignParameters.geometry_is_centerline = false` (the default), edge and corner columns are offset inward from their architectural vertex positions to their structural centerlines. This is handled by `update_structural_offsets!`, which:

1. Identifies boundary edges adjacent to each non-interior column
2. Computes the inward-pointing normal for each boundary edge using the CCW face-winding invariant of the `BuildingSkeleton`
3. Deduplicates parallel normals (dot product > 0.95) so straight building edges contribute a single offset direction
4. Shifts the column inward by half the column dimension along each unique normal

The offset is stored as `col.structural_offset :: NTuple{2, Float64}` in meters. It is applied in `to_asap!` when building the frame analysis model — both endpoints of each column edge shift by the same amount, and beams framing into the column vertex shift with it.

The offset is recomputed automatically when column dimensions change (after `estimate_column_sizes!`, `_reconcile_columns!`, and `restore!`). The `structural_center_xy_m(skel, col)` accessor returns the offset position.

See also: [Structural Column Offsets](../../api/schema.md#structural-column-offsets) in the API Schema docs.

## Options & Configuration

| Parameter | Description |
|:----------|:------------|
| `catalog` | Section catalog for steel optimization (e.g., W shapes up to W36) |
| `member_edge_group` | Which edge group to size (`:beams` or `:columns`) |
| `resolution` | Optimization resolution — number of candidate sections to evaluate |
| `geometry_is_centerline` | When `false` (default), edge/corner columns are offset inward from architectural vertices. When `true`, all offsets are zero. |

## Limitations & Future Work

- Steel member sizing uses discrete catalog optimization; custom section proportioning is not supported.
- Composite beam design (AISC 360 Chapter I) is available in StructuralSizer but not yet integrated into the synthesizer pipeline.
- Column biaxial bending uses simplified Bresler reciprocal method; fiber analysis is planned.
- Collinear grouping currently uses a geometric tolerance (`tol`) on the cross product of direction vectors; near-parallel members at small angles may not be grouped.
- When `geometry_is_centerline = true`, the slab boundary stops at the column centerline rather than extending outward to the building face. Outward slab extension for centerline input is a planned enhancement.