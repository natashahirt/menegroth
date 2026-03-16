# Vault Analysis

> ```julia
> using StructuralSizer
> result = optimize_vault(8.0u"m", 0.5u"kN/m^2", 2.0u"kN/m^2";
>                         lambda_bounds=(8.0, 15.0),
>                         thickness_bounds=(50u"mm", 200u"mm"))
> result.rise
> result.thickness
> result.status
> ```

## Quick Start

```julia
using StructuralSizer

# Optimize vault geometry (finds best rise + thickness)
result = optimize_vault(6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2")
result.rise       # Optimal rise
result.thickness  # Optimal thickness
result.status     # :optimal, :feasible, :infeasible

# Optimize thickness for a fixed lambda
result = optimize_vault(6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2";
                        lambda=12.0, thickness_bounds=(50u"mm", 150u"mm"))

# Optimize rise for a fixed thickness
result = optimize_vault(6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2";
                        thickness=75u"mm", lambda_bounds=(10.0, 20.0))
```

## Overview

The vault module implements Haile's analytical method for unreinforced parabolic
vaults using three-hinge arch theory with elastic shortening correction.  The
analysis computes stresses and thrusts for both symmetric (full-span) and
asymmetric (half-span live) loading, and iterates to find the equilibrium rise
that accounts for axial shortening of the arch.

**Source:** `StructuralSizer/src/slabs/codes/vault/haile_unreinforced.jl`

## Key Types

- `VaultAnalysisMethod` — abstract type for vault analysis method selection.

See also `Vault`, `HaileAnalytical`, `ShellFEA`,
`VaultResult`, and `VaultOptions` in [Slab Types & Options](../types.md).

```@docs
VaultAnalysisMethod
```

## Functions

```@docs
vault_stress_symmetric
vault_stress_asymmetric
solve_equilibrium_rise
parabolic_arc_length
get_vault_properties
vault_volume_per_area
```

### Key Functions

| Function | Description | API Level |
|:---------|:-----------|:----------|
| `optimize_vault` | Find optimal geometry | **Public** |
| `_size_span_floor(::Vault)` | Evaluate fixed geometry | Internal (called from `size_slab!`) |
| `vault_stress_symmetric` | Stress/thrust under full UDL | Internal |
| `vault_stress_asymmetric` | Stress/thrust under half-span live | Internal |
| `solve_equilibrium_rise` | Elastic shortening iteration | Internal |

## Optimization API

### `optimize_vault(span, sdl, live; kwargs...)`

Find optimal vault geometry minimizing volume/weight/carbon while satisfying stress and deflection constraints.

**Rise specification** (choose one, or use default `λ ∈ (10, 20)`):

```julia
optimize_vault(span, sdl, live)                                # Default: λ ∈ (10, 20)
optimize_vault(span, sdl, live; lambda_bounds=(8.0, 15.0))     # Custom λ range
optimize_vault(span, sdl, live; rise_bounds=(0.5u"m", 1.5u"m")) # Absolute rise
optimize_vault(span, sdl, live; lambda=12.0)                   # Fixed λ, optimize t
optimize_vault(span, sdl, live; rise=0.6u"m")                  # Fixed rise, optimize t
```

**Thickness specification**:

```julia
optimize_vault(span, sdl, live; thickness_bounds=(50u"mm", 150u"mm"))
optimize_vault(span, sdl, live; thickness=75u"mm")  # Fixed t, optimize rise
```

**Objectives**: `MinVolume()` (default), `MinWeight()`, `MinCarbon()`, `MinCost()`

**Solvers**: `:grid` (default, robust grid search) or `:ipopt` (gradient-based, faster)

**Returns**:

```julia
(
    rise = 0.5u"m",           # Optimal rise
    thickness = 0.075u"m",    # Optimal thickness
    result = VaultResult(...), # Full analysis result
    objective_value = 0.314,  # Minimized objective
    status = :optimal,        # :optimal, :feasible, :infeasible
)
```

### Analytical API (Fixed Geometry)

For evaluating a specific geometry with both rise and thickness fixed, the
internal vault sizing path is used from the structure-level API.

```julia
opts = VaultOptions(
    lambda = 12.0,         # or rise = 0.5u"m"
    thickness = 75u"mm",
)

# Internal path triggered by structure-level sizing:
# size_slab!(struc, slab_idx; options=opts)
# (returns a VaultResult in slab.result)

# VaultResult fields
# result.thickness      # Shell thickness
# result.rise           # Final rise (after elastic shortening)
# result.thrust_dead    # Horizontal thrust (dead) [kN/m]
# result.thrust_live    # Horizontal thrust (live) [kN/m]
# result.σ_max          # Governing stress [MPa]
# result.governing_case # :symmetric or :asymmetric

# Design checks
# result.stress_check.ok       # Stress ≤ allowable?
# result.deflection_check.ok   # Rise reduction acceptable?
# is_adequate(result)          # All checks pass?
```

## Implementation Details

### Three-Hinge Parabolic Arch Theory

The vault is modeled as a three-hinge parabolic arch under uniform distributed
load.  For a span ``L``, rise ``f``, and thickness ``t``:

**Symmetric loading** (dead + live on full span):

Horizontal thrust:

```math
H = \frac{w \, L^2}{8 f}
```

Maximum compressive stress at crown:

```math
\sigma = \frac{H}{t \cdot b}
```

where ``w`` is the total load per unit area and ``b`` is the tributary depth.

**Asymmetric loading** (dead on full span, live on half span):
- Produces bending moments in the arch due to the antisymmetric live load
  component
- `vault_stress_asymmetric` computes the maximum combined stress including both
  axial and flexural effects
- Often governs for moderate live-to-dead ratios

### Elastic Shortening Iteration

The `solve_equilibrium_rise` function iterates to find the equilibrium rise
considering axial shortening of the arch:

1. Compute thrust and arc length for current rise
2. Calculate axial shortening:

```math
\Delta L = \frac{H \cdot S}{E \cdot A}
```

   where ``S`` is arc length and ``A = t \cdot b``
3. Reduce rise to account for shortening
4. Repeat until convergence (within `deflection_limit`)

The result reports `converged` status and iteration count in the
`convergence_check` field.

### Geometry Functions

- `parabolic_arc_length(span, rise)`: Arc length of the parabolic intrados,
  computed analytically
- `intrados(x, span, rise)`: Height of the inner surface at position ``x``
- `extrados(x, span, rise, thickness)`: Height of the outer surface
- `get_vault_properties(span, rise, thickness, trib_depth, rib_depth, rib_apex_rise)`:
  Returns arc length, shell volume, and rib volumes for material takeoff

### Vault Sizing Pipeline

The `_size_span_floor(::Vault, ...)` function:

1. Resolves rise from lambda (rise-to-span ratio) or explicit value
2. Optionally searches for minimum thickness via `_find_min_thickness`
3. Calls `solve_equilibrium_rise` for the final geometry
4. Evaluates symmetric and asymmetric stresses
5. Checks stress ratio, deflection, and convergence
6. Returns `VaultResult` with full geometry and check results

### NLP Optimization

The `VaultNLPProblem` (in `slabs/optimize/`) wraps the vault analysis for
continuous optimization of rise and/or thickness.  See
[Slab Optimization](../optimize.md) for details.

### Analysis Method

**Default**: `HaileAnalytical()` — closed-form 3-hinge parabolic arch. **Future**: `ShellFEA()` — shell finite element validation (placeholder).

### Allowable Stress

Default (unreinforced concrete practice):

```math
0.45\,f'_c
```

Override with `VaultOptions(allowable_stress=10.0)` (MPa).

### Thrust Integration

`VaultResult` provides `thrust_dead` and `thrust_live` as line loads (kN/m). These are applied to the Asap model via `slab_edge_line_loads`, where adjacent vault thrusts cancel at interior supports.

## Options & Configuration

See `VaultOptions` in [Slab Types & Options](../types.md) for full field documentation.

```julia
VaultOptions(
    # Rise: choose ONE (or use default lambda_bounds = (10, 20))
    lambda_bounds = (10.0, 20.0),
    rise_bounds = (0.5u"m", 1.5u"m"),
    lambda = 12.0,
    rise = 0.5u"m",

    # Thickness: bounds OR fixed (default: 2"–4")
    thickness_bounds = (2.0u"inch", 4.0u"inch"),
    thickness = 75u"mm",

    # Geometry
    trib_depth = 1.0u"m",
    rib_depth = 0.0u"m",
    rib_apex_rise = 0.0u"m",

    # Loading
    finishing_load = 0.0u"kN/m^2",

    # Design checks
    allowable_stress = nothing,  # Default: 0.45 fc'
    deflection_limit = nothing,  # Default: span/240
    check_asymmetric = true,

    # Optimization
    objective = MinVolume(),     # MinWeight, MinCarbon, MinCost
    solver = :grid,              # or :ipopt
    n_grid = 20,
    n_refine = 2,

    # Material
    material = NWC_4000,
)
```

Rise specification (four mutually exclusive forms):

| Parameter | Description |
|:----------|:------------|
| `lambda_bounds` | Span-to-rise ratio bounds (\(\lambda = \text{span}/\text{rise}\)), e.g., `(10.0, 20.0)` |
| `rise_bounds` | Explicit rise bounds in length units |
| `lambda` | Fixed rise-to-span ratio |
| `rise` | Fixed rise value |

Additional options:

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `thickness_bounds` | `(2.0u"inch", 4.0u"inch")` | Shell thickness bounds |
| `thickness` | `nothing` | Fixed thickness (skips optimization) |
| `allowable_stress` | ``0.45 f'_c`` | Maximum compressive stress |
| `deflection_limit` | ``L/240`` | Maximum allowable rise deflection |
| `check_asymmetric` | `true` | Include half-span live load case |
| `rib_depth` | `0.0` | Depth of stiffening ribs |
| `rib_apex_rise` | `0.0` | Rise of rib at apex |
| `finishing_load` | `0.0 kPa` | Additional finishing dead load |

## Limitations & Future Work

- **ShellFEA** analysis method is a placeholder—no FE validation is implemented.
- Only parabolic vault geometry is supported; catenary, circular, and pointed
  profiles require different analytical solutions.
- Reinforced vault design (with rebar or FRC) is not implemented.
- Lateral thrust from vaults is reported but must be resolved externally (by
  tie beams, buttresses, or the surrounding frame).
- Thermal effects and creep are not considered in the analysis.

## References

MATLAB implementation by Nebyu Haile (saved in `reference/`):
- `VaultStress.m` — Symmetric analysis
- `VaultStress_Asymmetric.m` — Asymmetric analysis
- `solveFullyCoupledRise.m` — Elastic shortening solver
