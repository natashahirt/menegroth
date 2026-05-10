# Slab Optimization

> ```julia
> using StructuralSizer
> result = optimize_vault(8.0u"m", 0.5u"kPa", 2.0u"kPa";
>             lambda_bounds=(10, 20), thickness_bounds=(0.05u"m", 0.20u"m"))
> result.rise       # optimized arch rise
> result.thickness   # optimized shell thickness
> ```

## Overview

The slab optimization module provides continuous (NLP) optimization for flat
plate and vault slab systems.  It wraps the structural design pipeline as
constraint functions and minimizes material volume (or other objectives) over
continuous design variables.

Two problem types are implemented:
- **`FlatPlateNLPProblem`**: 2D grid search over slab thickness and column
  size for flat plate design
- **`VaultNLPProblem`**: 1D or 2D optimization of vault rise and/or thickness

**Source:** `StructuralSizer/src/slabs/optimize/`

## Key Types

```@docs
FlatPlateNLPProblem
VaultNLPProblem
```

## Functions

### Vault Optimization

```@docs
optimize_vault
```

### Flat Plate Optimization

```@docs
size_flat_plate_optimized
```

### NLP Interface

```@docs
n_variables
variable_bounds
initial_guess
evaluate
objective_fn
constraint_fns
```

## Implementation Details

### FlatPlateNLPProblem

The flat plate optimization uses a 2D grid search over:
- ``h`` — slab thickness (inches)
- ``c`` — column dimension (inches)

For each ``(h, c)`` pair, the evaluator runs:
1. DDM moment analysis
2. Punching shear check at all columns
3. One-way shear check
4. Strip reinforcement design (trying multiple bar sizes)
5. Flexural adequacy check

The objective combines concrete volume (``h \times A_{\text{panel}}``) and
reinforcing steel volume (from the lightest feasible bar size), scaled by
configurable weights.

The problem implements the standard `AbstractNLPProblem` interface and is
solved via `optimize_continuous` (see [Optimization Solvers](../optimize/solvers.md)).

### VaultNLPProblem

The vault optimization solves for the minimum-volume shell geometry subject to
stress and convergence constraints:

**Variables:**
- Rise + thickness (2 variables)
- Rise only (thickness fixed, 1 variable)
- Thickness only (rise fixed, 1 variable)

**Objective:** Shell volume per plan area = ``t \times S / L`` where ``S`` is
the parabolic arc length.

**Constraints:**
1. Stress: ``\sigma_{\max} / \sigma_{\text{allow}} \leq 1``
2. Convergence: elastic shortening iteration must converge

The mode is auto-detected from which bounds/values are provided:
- `lambda_bounds`, `rise_bounds` → rise is a variable
- `thickness_bounds` → thickness is a variable
- Fixed `lambda`/`rise` *and* fixed `thickness` → throws an error (nothing to optimize)

### Solver Integration

Both problem types use `optimize_continuous` from the solver module, which
supports:
- Grid search with adaptive refinement (`_optimize_grid`)
- Ipopt via JuMP (gradient-based, with numeric central-difference gradients)
- Multi-start Ipopt for non-convex landscapes

## Options & Configuration

### FlatPlate Optimization (`size_flat_plate_optimized`)

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `h_max` | `nothing` | Optional slab-thickness upper bound (default is computed inside `FlatPlateNLPProblem`, typically ACI minimum thickness + 6"). |
| `c_min` | `nothing` | Optional minimum column dimension (default computed from span, typically span/15). |
| `c_max` | `nothing` | Optional maximum column dimension (defaults to `opts.max_column_size`). |
| `bar_sizes` | `[4, 5, 6, 7, 8]` | Candidate rebar sizes for the inner sweep. |
| `n_grid` | `20` | Grid resolution per dimension. |
| `n_refine` | `2` | Refinement iterations around the best point. |

### VaultNLPProblem

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `lambda_bounds` | `(10, 20)` | Span-to-rise ratio bounds (λ = span/rise) |
| `thickness_bounds` | `2 in – 4 in` | Shell thickness bounds (default when omitted) |
| `allowable_stress` | ``0.45 f'_c`` | Maximum compressive stress |
| `deflection_limit` | ``L/240`` | Maximum rise reduction from elastic shortening (default when omitted) |

### optimize_vault API

The `optimize_vault` function provides a high-level API that internally:
1. Resolves rise/thickness from mixed input formats
2. Detects the optimization mode (rise + thickness, rise only, or thickness only)
3. Builds and solves the `VaultNLPProblem`
4. Returns a `VaultResult` with full geometry and checks

## Limitations & Future Work

- `FlatPlateNLPProblem` uses DDM only—EFM and FEA are not available in the
  optimization wrapper.
- The flat plate evaluator does not iterate on deflection within each grid
  point; infeasible points are penalized but not grown.
- Vault optimization assumes parabolic geometry only.
- Multi-objective optimization (e.g., Pareto front of cost vs. carbon) is not
  yet implemented.
- The grid search is effective for 2D problems but does not scale to higher
  dimensions.
