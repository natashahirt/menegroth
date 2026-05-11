# Member Optimization

> ```julia
> using StructuralSizer
> using Unitful
>
> Pu = [500.0, 800.0] .* u"kN"
> Mux = [100.0, 150.0] .* u"kN*m"
> geoms = [SteelMemberGeometry(4.0u"m") for _ in 1:2]
>
> result = size_columns(Pu, Mux, geoms, SteelColumnOptions())
> result.sections
> ```

## Overview

The member optimization module provides methods for selecting the lightest (or cheapest, or lowest-carbon) structural section that satisfies all design code requirements. Three optimization strategies are available:

1. **Discrete MIP** — mixed-integer programming using JuMP + HiGHS/Gurobi, selecting from a catalog of discrete sections
2. **NLP** — nonlinear programming for continuous sizing (where supported) of member dimensions
3. **Binary search (utility)** — iterative lightest-feasible search over a catalog with no solver dependency (available via `optimize_binary_search`, but not automatically selected by `size_columns` / `size_beams`)

A unified API (`size_columns`, `size_beams`, `size_members`) dispatches based on the options type (and, where applicable, `opts.sizing_strategy`).

Source: `StructuralSizer/src/optimize/*.jl`, `StructuralSizer/src/members/optimize/*.jl`

## Key Types

### Options Types

```@docs
MemberOptions
BeamOptions
ColumnOptions
SteelMemberOptions
SteelColumnOptions
```

`SteelColumnOptions` configures steel column optimization:

| Field | Description |
|:------|:------------|
| `material` | Steel material (e.g. `A992_Steel`) |
| `materials` | Optional vector of steel grades for multi-material MIP (`nothing` for single material) |
| `section_type` | Section family symbol: `:w`, `:hss`, `:pipe`, `:w_and_hss` |
| `catalog` | Catalog selector: `:common`, `:preferred`, `:all` |
| `custom_catalog` | Optional custom section vector (overrides `catalog`) |
| `max_depth` | Maximum section depth (Length) |
| `n_max_sections` | Max unique sections across groups (0 = no limit) |
| `sizing_strategy` | `:discrete` (MIP) or `:nlp` (continuous; supported for `section_type in (:w, :hss)` only) |
| `objective` | `MinWeight()`, `MinVolume()`, `MinCost()`, `MinCarbon()` |
| `solver` | MIP optimizer selector: `:auto`, `:highs`, `:gurobi` |
| `time_limit_sec` | MIP solver time limit (seconds) for discrete sizing |

```@docs
SteelBeamOptions
```

`SteelBeamOptions` configures steel beam sizing. It shares the same catalog/material fields as `SteelColumnOptions`, and adds deflection and composite-beam settings:

| Field | Description |
|:------|:------------|
| `deflection_limit` | Live-load deflection limit ratio (default `1/360`; set to `nothing` to disable) |
| `total_deflection_limit` | Total-load deflection limit ratio (default `1/240`; set to `nothing` to disable) |
| `composite` | Enable composite beam sizing (AISC 360-16 Ch. I) |
| `time_limit_sec` | MIP solver time limit (seconds) for discrete sizing |

```@docs
ConcreteColumnOptions
```

`ConcreteColumnOptions` configures RC column optimization:

| Field | Description |
|:------|:------------|
| `material` | Concrete grade (e.g. `NWC_4000`) |
| `section_shape` | `:rect` or `:circular` |
| `rebar_material` | Rebar material |
| `sizing_strategy` | `:discrete` or `:nlp` |
| Other fields | Slenderness, biaxial, catalog parameters |

```@docs
ConcreteBeamOptions
```

`ConcreteBeamOptions` configures RC beam optimization:

| Field | Description |
|:------|:------------|
| `material` | Concrete grade |
| `rebar_material` | Rebar material |
| `catalog` | Beam section catalog |
| `deflection_limit` | L/Δ limit |
| Other fields | Design settings (e.g. T-beam routing via `include_flange`), catalog constraints, and solver limits |

```@docs
NLPColumnOptions
```

`NLPColumnOptions` configures continuous RC column sizing:

| Field | Description |
|:------|:------------|
| `material` | Concrete grade |
| `rebar_material` | Rebar material |
| `min_dim`, `max_dim` | Dimension bounds |
| `ρ_max` | Maximum reinforcement ratio |
| `solver` | NLP solver (e.g. Ipopt) |

```@docs
PixelFrameBeamOptions
PixelFrameColumnOptions
```

```@docs
NLPBeamOptions
NLPWOptions
NLPHSSOptions
```

### NLP Problem Types

```@docs
AbstractNLPProblem
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

```@docs
RCTBeamNLPProblem
WColumnNLPProblem
HSSColumnNLPProblem
SteelWBeamNLPProblem
SteelHSSBeamNLPProblem
```

### NLP Result Types

```@docs
RCColumnNLPResult
RCCircularNLPResult
RCBeamNLPResult
RCTBeamNLPResult
WColumnNLPResult
HSSColumnNLPResult
```

### Solver Types

The two solver strategies (`optimize_discrete` and `optimize_binary_search`) are documented below under [Discrete Optimization](#discrete-optimization).

## Functions

### Unified API

```@docs
size_columns
```

`size_columns(Pu, Mux, geometries, opts; Muy=...)` — size columns for the given demands. `Muy` defaults to a zero vector with the same units as `Mux`. Dispatches on `opts`:
- `SteelColumnOptions` → AISC checker + MIP, or NLP when `opts.sizing_strategy == :nlp` and `opts.section_type ∈ (:w, :hss)`
- `ConcreteColumnOptions` → ACI checker + MIP, or NLP when `opts.sizing_strategy == :nlp`
- `PixelFrameColumnOptions` → PixelFrame checker + MIP

```@docs
size_beams
```

`size_beams(Mu, Vu, geometries, opts; Nu=zeros_like(Vu), Tu=Float64[])` — size beams for the given demands. `Nu` and `Tu` are **vectors** (one per member); if `Tu` is omitted (empty), it is treated as zero torsion for all members. Dispatches on `opts`:
- `SteelBeamOptions` → AISC checker + MIP (and optional deflection constraints when analysis deflections are provided)
- `ConcreteBeamOptions` → ACI checker + MIP
- `PixelFrameBeamOptions` → PixelFrame checker + MIP

```@docs
size_members
```

`size_members(arg1, arg2, geometries, opts; ...)` — generic dispatch to `size_columns` or `size_beams` based on options type (concrete and PixelFrame options only).

### Discrete Optimization

See [Optimization Solvers](../optimize/solvers.md) for full solver docstrings.

`optimize_discrete(checker, demands, geometries, catalog, material; ...)` — formulates and solves a MIP:

**Decision variables:** binary `x[i,j]` = 1 if group `i` uses section `j`.

**Objective:** minimize `Σ_i Σ_j (c[j] × L[i]) x[i,j]` where `c[j]` is the objective coefficient (weight/cost/carbon per unit length) and `L[i]` is the member/group length extracted from `geometries[i].L`.

**Constraints:**
- Exactly one section per group: `Σ_j x[i,j] = 1`
- Feasibility is enforced by restricting each group’s decision set to its prefiltered feasible indices (sections that fail `is_feasible(...)` for that group are excluded).

**Optional global constraint:** when `n_max_sections > 0`, `optimize_discrete` adds auxiliary binaries that limit the total number of unique sections used across all groups in the call.

Options: `optimizer` (`:auto`, `:highs`, `:gurobi`), `mip_gap`, `time_limit_sec`, `output_flag`, `cache`, `n_max_sections`.

A multi-material overload accepts `(checker, demands, geometries, catalog, materials)` and uses `expand_catalog_with_materials` to create the Cartesian product.

`optimize_binary_search(checker, demands, geometries, catalog, material; objective, cache)` — sorts the catalog by objective (lightest first), then performs a per-group binary search for the lightest feasible section. No external solver needed.

### NLP Sizing

```@docs
size_rc_column_nlp
```

`size_rc_column_nlp(Pu, Mux, geometry, opts; Muy=0)` — continuous RC column sizing using NLP. Optimizes column dimensions and reinforcement ratio to minimize the chosen objective.

```@docs
size_rc_beam_nlp
```

`size_rc_beam_nlp(Mu, Vu, opts; Tu=0)` — continuous RC beam sizing using NLP.

### Catalog Utilities

`expand_catalog_with_materials(catalog, materials)` — creates the Cartesian product of sections × materials for multi-material optimization. Returns `(expanded_catalog, section_indices, material_indices)` for reconstructing the solution.

## Implementation Details

### MIP Formulation

The discrete optimization uses a mixed-integer program (MIP) where binary variables select one section per group from the catalog. Capacity checks are precomputed/cached by the checker (`precompute_capacities!`), and feasibility is evaluated per group to build the candidate set for the MIP:

1. `precompute_capacities!(checker, cache, catalog, material, objective)` fills the cache
2. For each group `i`, build the feasible index set `{j | is_feasible(...) == true}`
3. The MIP selects the minimum-cost feasible section per group, optionally limiting the number of unique sections via `n_max_sections`

This approach avoids nonlinear capacity constraints in the MIP, making it solvable by standard MIP solvers (HiGHS, Gurobi).

### Binary Search Strategy

Binary search sorts the catalog by objective value (e.g. weight per length), then finds the lightest feasible section per group. It is faster than MIP for independent groups but cannot enforce `n_max_sections` (unique-section limits) or solve coupled multi-group selection problems.

### NLP Formulation

The NLP approach treats column dimensions as continuous variables and solves:

```math
\begin{aligned}
\min_{b, h, \rho} \quad & b\,h \\
\text{s.t.}\quad & \phi P_n(b,h,\rho) \ge P_u \\
& \phi M_{nx}(b,h,\rho) \ge M_{ux} \\
& \phi M_{ny}(b,h,\rho) \ge M_{uy} \\
& \rho_{\min} \le \rho \le \rho_{\max} \\
& b_{\min} \le b \le b_{\max} \\
& h_{\min} \le h \le h_{\max}
\end{aligned}
```

After solving, the continuous solution is rounded to the nearest standard dimension and bar size.

### Section Grouping

In the MIP formulation, all members in a group share the same section (one set of binary variables). This models the practical constraint that beams on the same floor or columns on the same tier use the same section for fabrication economy.

## Options & Configuration

### Steel

```julia
using Unitful
opts = SteelColumnOptions(
    material = A992_Steel,
    section_type = :w,
    catalog = :preferred,
    max_depth = Inf * u"mm",
    n_max_sections = 0,
    objective = MinWeight(),
    solver = :auto,
)
```

### Concrete

```julia
opts = ConcreteColumnOptions(
    material = NWC_4000,
    rebar_material = Rebar_60,
    section_shape = :rect,
    sizing_strategy = :discrete
)
```

### Solver Selection

For discrete MIP: HiGHS (open-source) or Gurobi (commercial, faster for large problems). Set via the `optimizer` keyword on `optimize_discrete` or via the options field `opts.solver` (which is forwarded as `optimizer=...` internally).

For NLP: Ipopt (default) via the `solver` keyword in `NLPColumnOptions`.

## Limitations & Future Work

- Section grouping in MIP is per-call, not across multiple calls (e.g., cannot enforce same column size across multiple stories in one optimization).
- Multi-objective optimization (weight vs. carbon) is not directly supported; use post-processing to compare alternatives.
- The NLP formulation uses continuous relaxation and post-hoc rounding, which may not find the true discrete optimum.
- No automated load path optimization (e.g., tributary area redistribution).
- Seismic design requirements (strong-column-weak-beam, special detailing) are not enforced in the optimizer.
