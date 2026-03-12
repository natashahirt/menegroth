# Member Optimization

> ```julia
> using StructuralSizer
> opts = SteelColumnOptions(material=A992_Steel)
> results = size_columns(Pu, Mux, geometries, opts)
> println("Selected: $(results.sections[1].name)")
> ```

## Overview

The member optimization module provides methods for selecting the lightest (or cheapest, or lowest-carbon) structural section that satisfies all design code requirements. Three optimization strategies are available:

1. **Discrete MIP** — mixed-integer programming using JuMP + HiGHS/Gurobi, selecting from a catalog of discrete sections
2. **Binary search** — iterative lightest-feasible search per member group, no solver dependency
3. **NLP** — nonlinear programming for continuous sizing (RC sections with continuous dimensions)

A unified API (`size_columns`, `size_beams`, `size_members`) dispatches to the appropriate strategy based on the options type.

Source: `StructuralSizer/src/optimize/*.jl`, `StructuralSizer/src/members/optimize/*.jl`

## Key Types

### Options Types

```@docs
SteelColumnOptions
```

`SteelColumnOptions` (alias for `SteelMemberOptions`) configures steel column optimization:

| Field | Description |
|:------|:------------|
| `material` | Steel material (e.g. `A992_Steel`) |
| `catalog` | Catalog symbol: `:common`, `:preferred`, `:all` |
| `Cb` | Moment gradient factor |
| `deflection_limit` | L/Δ limit (or `nothing`) |
| `max_depth` | Maximum section depth |
| `prefer_penalty` | Penalty for non-preferred sections |

```@docs
SteelBeamOptions
```

Alias for `SteelMemberOptions`, same configuration as columns.

```@docs
ConcreteColumnOptions
```

`ConcreteColumnOptions` configures RC column optimization:

| Field | Description |
|:------|:------------|
| `grade` | Concrete grade (e.g. `NWC_4000`) |
| `section_shape` | `:rect`, `:square`, `:rectangular`, or `:circular` |
| `rebar_grade` | Rebar material |
| `sizing_strategy` | `:catalog` or `:nlp` |
| Other fields | Slenderness, biaxial, catalog parameters |

```@docs
ConcreteBeamOptions
```

`ConcreteBeamOptions` configures RC beam optimization:

| Field | Description |
|:------|:------------|
| `grade` | Concrete grade |
| `rebar_grade` | Rebar material |
| `catalog` | Beam section catalog |
| `deflection_limit` | L/Δ limit |
| Other fields | Design parameters for flexure, shear, torsion |

```@docs
NLPColumnOptions
```

`NLPColumnOptions` configures continuous RC column sizing:

| Field | Description |
|:------|:------------|
| `grade` | Concrete grade |
| `rebar_grade` | Rebar material |
| `min_dim`, `max_dim` | Dimension bounds |
| `ρ_max` | Maximum reinforcement ratio |
| `solver` | NLP solver (e.g. Ipopt) |

### NLP Problem Types

```@docs
RCColumnNLPProblem
```

Formulates the continuous column sizing as an NLP: minimize cross-sectional area subject to P-M interaction, ACI detailing rules, and dimension bounds.

```@docs
RCCircularNLPProblem
```

Formulates the continuous circular column sizing as an NLP: minimize cross-sectional area subject to P-M interaction and ACI detailing rules.

```@docs
RCBeamNLPProblem
```

Formulates the continuous beam sizing: minimize weight subject to flexure, shear, and deflection constraints.

### Solver Types

The two solver strategies (`optimize_discrete` and `optimize_binary_search`) are documented below under [Discrete Optimization](#discrete-optimization).

## Functions

### Unified API

```@docs
size_columns
```

`size_columns(Pu, Mux, geometries, opts; Muy=0)` — size columns for the given demands. Dispatches on `opts`:
- `SteelColumnOptions` → AISC checker + MIP or binary search
- `ConcreteColumnOptions` → ACI checker + MIP, binary search, or NLP
- `PixelFrameColumnOptions` → PixelFrame checker + MIP

```@docs
size_beams
```

`size_beams(Mu, Vu, geometries, opts; Nu=0, Tu=0)` — size beams for the given demands. Dispatches on `opts`:
- `SteelBeamOptions` → AISC checker + MIP or binary search
- `ConcreteBeamOptions` → ACI checker + MIP or binary search
- `PixelFrameBeamOptions` → PixelFrame checker + MIP

```@docs
size_members
```

`size_members(demands, geometries, opts)` — generic dispatch to `size_columns` or `size_beams` based on options type.

### Discrete Optimization

```@docs
optimize_discrete
```

`optimize_discrete(checker, demands, geometries, catalog, material; ...)` — formulates and solves a MIP:

**Decision variables:** binary `x[j]` = 1 if section `j` is selected (shared across all members in the group).

**Objective:** minimize `Σ c[j] x[j]` where `c[j]` is the objective coefficient (weight, cost, or carbon).

**Constraints:**
- Exactly one section selected: `Σ x[j] = 1`
- Feasibility: `x[j] = 0` for all sections that fail any member's capacity check

Options: `optimizer` (HiGHS or Gurobi), `mip_gap`, `time_limit_sec`, `n_max_sections`.

A multi-material overload accepts `(checker, demands, geometries, catalog, materials)` and uses `expand_catalog_with_materials` to create the Cartesian product.

```@docs
optimize_binary_search
```

`optimize_binary_search(checker, demands, geometries, catalog, material; objective, cache)` — sorts the catalog by objective (lightest first), then binary searches for the lightest section that is feasible for all members. No external solver needed.

### NLP Sizing

```@docs
size_rc_column_nlp
```

`size_rc_column_nlp(Pu, Mux, geometry, opts; Muy=0)` — continuous RC column sizing using NLP. Optimizes column dimensions (b, h) and reinforcement (bar_size, n_bars) to minimize area.

```@docs
size_rc_beam_nlp
```

`size_rc_beam_nlp(Mu, Vu, opts; Tu=0)` — continuous RC beam sizing using NLP.

### Catalog Utilities

```@docs
expand_catalog_with_materials
```

`expand_catalog_with_materials(catalog, materials)` — creates the Cartesian product of sections × materials for multi-material optimization. Returns `(expanded_catalog, section_indices, material_indices)` for reconstructing the solution.

## Implementation Details

### MIP Formulation

The discrete optimization uses a mixed-integer program (MIP) where binary variables select one section from the catalog. The key insight is that capacity checks are **precomputed** for all (section, demand) pairs before the MIP is formulated. This converts the nonlinear capacity check into a set of linear feasibility constraints:

1. `precompute_capacities!(checker, cache, catalog, material, objective)` fills the cache
2. For each member `i` and section `j`: if `is_feasible(checker, cache, j, ..., demand_i, geometry_i) == false`, add constraint `x[j] = 0`
3. The MIP is then purely linear: select the minimum-cost feasible section

This approach avoids nonlinear capacity constraints in the MIP, making it solvable by standard MIP solvers (HiGHS, Gurobi).

### Binary Search Strategy

Binary search sorts the catalog by objective value (e.g. weight per length), then finds the lightest section that passes all capacity checks for all members in the group. This is `O(n log m)` where `n` = number of members and `m` = catalog size. It is faster than MIP for small problems but cannot handle section grouping constraints or multi-objective tradeoffs.

### NLP Formulation

The NLP approach treats column dimensions as continuous variables and solves:

```
minimize   b × h           (cross-sectional area)
subject to ϕPn ≥ Pu        (axial capacity)
           ϕMnx ≥ Mux      (moment capacity, x-axis)
           ϕMny ≥ Muy      (moment capacity, y-axis)
           ρ_min ≤ ρ ≤ ρ_max  (reinforcement ratio limits)
           b_min ≤ b ≤ b_max  (dimension bounds)
```

After solving, the continuous solution is rounded to the nearest standard dimension and bar size.

### Section Grouping

In the MIP formulation, all members in a group share the same section (one set of binary variables). This models the practical constraint that beams on the same floor or columns on the same tier use the same section for fabrication economy.

## Options & Configuration

### Steel

```julia
opts = SteelColumnOptions(
    material = A992_Steel,
    catalog = :preferred,
    Cb = 1.0,
    deflection_limit = nothing,
    max_depth = Inf,
    prefer_penalty = 1.0
)
```

### Concrete

```julia
opts = ConcreteColumnOptions(
    grade = NWC_4000,
    rebar_grade = Rebar_60,
    section_shape = :rect,
    sizing_strategy = :catalog
)
```

### Solver Selection

For discrete MIP: HiGHS (open-source, default) or Gurobi (commercial, faster for large problems). Set via the `optimizer` keyword.

For NLP: Ipopt (default) via the `solver` keyword in `NLPColumnOptions`.

## Limitations & Future Work

- Section grouping in MIP is per-call, not across multiple calls (e.g., cannot enforce same column size across multiple stories in one optimization).
- Multi-objective optimization (weight vs. carbon) is not directly supported; use post-processing to compare alternatives.
- The NLP formulation uses continuous relaxation and post-hoc rounding, which may not find the true discrete optimum.
- No automated load path optimization (e.g., tributary area redistribution).
- Seismic design requirements (strong-column-weak-beam, special detailing) are not enforced in the optimizer.
