# Optimization Solvers

> ```julia
> using StructuralSizer
> result = optimize_discrete(checker, demands, geometries, catalog, material;
>             objective=MinWeight())
> result.sections    # optimal section per group
> result.objective   # total objective value
> ```

## Overview

The optimization solver module provides three solver backends for structural
member sizing:

- **MIP (Mixed-Integer Programming)**: Discrete section selection from a catalog
  using JuMP with HiGHS (default) or Gurobi (optional).
- **Binary Search**: Catalog-based search for the lightest feasible section per
  demand group, with no solver dependency.
- **NLP (Nonlinear Programming)**: Continuous optimization for problems with
  smooth design variables, using Ipopt or grid search.

All solvers share the `AbstractCapacityChecker` interface for feasibility
evaluation and objective computation.

**Source:** `StructuralSizer/src/optimize/solvers/`

## Key Types

- `AbstractCapacityChecker` — base type for all design code capacity checkers (see [Member Types](../members/types.md)).
- `AbstractCapacityCache` — base type for checker-specific precomputed capacity caches.
- `AbstractMemberGeometry` — base type for member geometry data (unbraced lengths, effective length factors).
- `AbstractNLPProblem` — base type for continuous NLP optimization problems (flat plate, vault).

## Functions

### MIP Solver

- `optimize_discrete(checker, demands, geometries, catalog, material; ...)` — solve a mixed-integer program for discrete section selection from a catalog.

### Binary Search Solver

- `optimize_binary_search(checker, demands, geometries, catalog, material; ...)` — solver-free catalog search for the lightest feasible section per demand group.

### NLP Solver

- `optimize_continuous(problem; ...)` — solve a continuous NLP problem implementing the `AbstractNLPProblem` interface.

## Implementation Details

### MIP Discrete Optimization

`optimize_discrete(checker, demands, geometries, catalog, material; ...)` solves
a mixed-integer program:

**Decision variables:** Binary ``x_{ij} \in \{0, 1\}`` — section ``j``
assigned to group ``i``.

**Objective:** Minimize ``\sum_i \sum_j c_j \cdot x_{ij}`` where ``c_j`` is the
objective coefficient for section ``j`` (weight, volume, cost, or carbon).

**Constraints:**
- Assignment: ``\sum_j x_{ij} = 1`` for each group ``i``
- Feasibility: ``x_{ij} = 0`` for infeasible (section, demand) pairs
- Group linking: Optional constraint that all members in a group share the same
  section

Pre-computation: `precompute_capacities!` evaluates all (section, demand) pairs
up front and marks infeasible combinations.

**Solver selection:**
- HiGHS (default): Open-source, no license required.  The `_HAS_GUROBI` flag
  is checked at module load time.
- Gurobi (optional): Faster for large problems.  Thread-local environments via
  `_get_gurobi_env()` with automatic warmup via `_warmup_jump_solvers()`.

**Multi-material:** An overload accepts a vector of materials and expands the
catalog to (section × material) pairs via `expand_catalog_with_materials`.

### Binary Search

`optimize_binary_search(checker, demands, geometries, catalog, material; ...)`
provides a solver-free alternative:

1. Sort catalog by objective value (ascending)
2. For each demand group, binary search for the lightest feasible section
3. Return the result with per-group section assignments

This is faster than MIP for simple problems (no group-linking constraints) and
has zero solver dependencies.

!!! note "Default in StructuralSynthesizer"
    The `size_steel_members!` pipeline in StructuralSynthesizer automatically
    selects binary search when `n_max_sections == 0` (no shared-section constraint)
    and falls back to MIP when `n_max_sections > 0`. This makes binary search the
    default solver for most steel sizing workflows.

### NLP Continuous Optimization

`optimize_continuous(problem; ...)` solves continuous NLP problems that implement
the `AbstractNLPProblem` interface:

**Solvers:**
- `:grid` — Grid search with adaptive refinement.  `n_grid` points per
  dimension, `n_refine` levels of zoom around the best point.
- `:ipopt` — Gradient-based via JuMP/Ipopt.  Gradients computed by central
  finite differences (`_numeric_gradient`, step ``\varepsilon = 10^{-6}``).
- `:multistart_ipopt` — Multiple random starting points to escape local minima.
- `:nlopt`, `:nonconvex` — Placeholders for future solvers.

The objective is mapped through `_convert_objective` which converts raw volume
to the selected objective type (weight, cost, carbon) using material densities
and emission factors.

## Options & Configuration

### MIP Options

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `objective` | `MinWeight()` | Optimization objective |
| `n_max_sections` | `nothing` | Limit on candidate sections per group |
| `optimizer` | `:auto` | `:auto`, `:highs`, or `:gurobi` |
| `time_limit` | `60.0` | MIP solver time limit (seconds) |
| `mip_gap` | `0.01` | Relative optimality gap |

### Binary Search Options

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `objective` | `MinWeight()` | Sorting criterion |
| `cache` | `nothing` | Pre-computed capacity cache |

### NLP Options

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `solver` | `:grid` | `:grid`, `:ipopt`, `:multistart_ipopt` |
| `n_grid` | `20` | Grid points per dimension |
| `n_refine` | `2` | Grid refinement iterations |
| `maxiter` | `500` | Ipopt iteration limit |
| `tol` | `1e-6` | Ipopt convergence tolerance |
| `x0` | `nothing` | Initial guess (Ipopt) |
| `n_multistart` | `10` | Number of starts (multistart) |

## Limitations & Future Work

- Gurobi requires a valid license; the fallback to HiGHS is automatic but
  may be slower for large problems (> 1000 groups).
- NLP gradients are computed by finite differences, which is slow and
  inaccurate for high-dimensional problems.  Automatic differentiation
  (ForwardDiff.jl) integration is planned.
- The grid search scales as ``O(n^d)`` and is practical only for ≤ 3
  design variables.
- Group-linking constraints in MIP are optional; when disabled, each member
  is sized independently (faster but may produce non-uniform member groups).
- The NLopt and NonConvex backends are stub implementations.
