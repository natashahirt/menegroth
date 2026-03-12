# Size Dispatch

> ```julia
> # struc must be prepared first: prepare!(struc, params)
> design = BuildingDesign(struc, params)
> size!(design; max_iterations = 3, convergence_tol = 0.05)
> design.summary.all_checks_pass
> ```

## Overview

`size!` is the top-level sizing dispatcher that iteratively sizes beams and columns until demand convergence, then optionally sizes foundations. It calls `size_beams!`, `size_columns!`, `sync_asap!`, and `size_foundations!` directly — it does **not** use `build_pipeline`.

## Functions

```@docs
size!
```

## Implementation Details

### Dispatch Logic

`size!(design::BuildingDesign)` performs:

1. Extracts beam and column options from `design.params`
2. For each iteration (up to `max_iterations`):
   - Calls `size_beams!(struc, beam_opts)` to size all beams
   - Calls `size_columns!(struc, col_opts)` to size all columns
   - Calls `sync_asap!(struc)` to re-solve the FEM model with updated sections
   - Compares demand envelopes between iterations; stops if change < `convergence_tol`
3. After convergence, optionally calls `size_foundations!(struc, ...)` if `size_foundations == true`

### Floor Type Dispatch

The pipeline stages differ by floor type:

| Floor Type | Slab Sizing | Member Sizing | Foundation Sizing |
|:-----------|:------------|:--------------|:-----------------|
| `FlatPlate` / `FlatSlab` | DDM, EFM, or FEA | Column reconciliation | Optional |
| `OneWay` / `TwoWay` | Per-cell slab design | Iterative beam + column | Optional |
| `CompositeDeck` | Steel deck tables | AISC beam optimization | Optional |
| `Vault` | Shell/analytical | Supporting member sizing | Optional |
| `CLT` / `NLT` / `DLT` | Timber panel design | Timber/steel beam sizing | Optional |

### Convergence

For iterative stages (beam–column sizing), convergence is checked by comparing section assignments between iterations. The loop terminates when:
- No section changes occur between iterations, OR
- `max_iterations` is reached

The `convergence_tol` parameter controls the maximum relative demand change between iterations that qualifies as convergence.

## Options & Configuration

| Parameter | Description | Default |
|:----------|:------------|:--------|
| `max_iterations` | Maximum beam/column sizing iterations | `3` |
| `convergence_tol` | Max demand change for convergence (fraction) | `0.05` |
| `size_foundations` | Whether to include foundation sizing | `true` |
| `verbose` | Print iteration progress | `true` |

## Limitations & Future Work

- Convergence is not formally guaranteed for all building geometries; in rare cases, section oscillation can occur between two close sizes.
- Parallel sizing of independent stories within a single iteration is planned but not yet implemented.
