# Member Analysis

> ```julia
> size_beams!(struc, beam_opts)
> size_columns!(struc, col_opts)
> compute_story_properties!(struc)
> p_delta_iterate!(struc; params = design_params)
> ```

## Overview

Member analysis extracts demands from the Asap FEM model and sizes beams and columns using StructuralSizer's optimization framework. For steel members, this uses AISC 360 mixed-integer programming. For RC members, this uses ACI 318 interaction diagrams. The module also computes story-level properties for P-Δ second-order analysis.

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

`size_steel_members!(struc; catalog, member_edge_group, resolution)` sizes steel beams and columns via the AISC 360-16 optimization framework:

1. Extracts demands (Mu, Vu, Pu, Tu) from the Asap model for each member group
2. Filters the section catalog (W shapes, HSS, pipe) to candidate sections
3. Runs the `AISCChecker` to verify each candidate against:
   - Flexure: AISC 360-16 §F2–F8
   - Shear: AISC 360-16 §G2–G6
   - Compression: AISC 360-16 §E3
   - Tension: AISC 360-16 §D2
   - Combined: AISC 360-16 §H1 (P-M interaction)
   - Torsion: AISC DG9
4. Selects the optimal section per the objective function (MinWeight, MinCarbon, etc.)

**Automatic solver selection:** The solver is chosen based on `n_max_sections`:
- `n_max_sections == 0` (default) — uses `optimize_binary_search`, which sorts the catalog by weight and binary-searches for the lightest feasible section per group. This is fast and has no solver dependencies.
- `n_max_sections > 0` — uses `optimize_discrete` (MIP via JuMP/HiGHS or Gurobi), which can enforce shared-section constraints across groups.

Both solvers produce identical per-group results when there are no shared-section constraints.

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

`compute_story_properties!(struc)` computes sway magnification parameters per ACI 318-11 §10.10.7 for each story:

| Property | Description | Reference |
|:---------|:------------|:----------|
| ΣPu | Total factored axial load in story | §10.10.7 |
| ΣPc | Total critical buckling load in story | §10.10.7, §19.2.2.1 |
| Vus | Factored story shear | §6.6.4.4.4 |
| Δo | First-order story drift | Analysis |
| δs | Sway magnification factor = 1 / (1 - ΣPu / 0.75ΣPc) | §10.10.7 |

### P-Δ Iteration

`p_delta_iterate!(struc)` implements iterative P-Δ second-order analysis:

1. Compute story properties (ΣPu, ΣPc, Vus, Δo)
2. If δs > 1.5 for any story, perform geometric stiffness iteration
3. Update member forces with amplified moments
4. Re-check column adequacy with amplified demands

The trigger threshold δs > 1.5 follows ACI 318-11 §6.6.4.6.2, which limits the moment magnifier method and requires more rigorous analysis when exceeded.

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