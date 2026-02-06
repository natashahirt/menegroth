# Vault Analysis & Optimization

Unreinforced parabolic vault sizing using Haile's 3-hinge arch method, with built-in optimization for finding optimal geometry.

## Quick Start

```julia
using StructuralSizer

# Optimize vault geometry (finds best rise + thickness)
result = optimize_vault(6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2")
result.rise       # Optimal rise
result.thickness  # Optimal thickness
result.status     # :optimal, :feasible, :infeasible

# Evaluate fixed geometry
opts = FloorOptions(vault=VaultOptions(lambda=12.0, thickness=75u"mm"))
result = _size_span_floor(Vault(), 6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2"; options=opts)
is_adequate(result)  # All checks pass?
```

## Optimization API

### `optimize_vault(span, sdl, live; kwargs...)`

Find optimal vault geometry minimizing volume/weight/carbon while satisfying stress and deflection constraints.

**Rise specification** (choose ONE, or use default):
```julia
optimize_vault(span, sdl, live)                           # Default: λ ∈ (10, 20)
optimize_vault(span, sdl, live; lambda_bounds=(8.0, 15.0)) # Custom λ range
optimize_vault(span, sdl, live; rise_bounds=(0.5u"m", 1.5u"m")) # Absolute rise
optimize_vault(span, sdl, live; lambda=12.0)              # Fixed λ, optimize t
optimize_vault(span, sdl, live; rise=0.6u"m")             # Fixed rise, optimize t
```

**Thickness specification**:
```julia
optimize_vault(span, sdl, live)                            # Default: t ∈ (2", 4")
optimize_vault(span, sdl, live; thickness_bounds=(50u"mm", 150u"mm"))
optimize_vault(span, sdl, live; thickness=75u"mm")         # Fixed t, optimize rise
```

**Objectives**:
```julia
optimize_vault(span, sdl, live; objective=MinVolume())   # Default
optimize_vault(span, sdl, live; objective=MinWeight())   # Minimize weight
optimize_vault(span, sdl, live; objective=MinCarbon())   # Minimize EC
optimize_vault(span, sdl, live; objective=MinCost())     # Minimize cost
```

**Solvers**:
```julia
optimize_vault(...; solver=:grid)   # Grid search (default, robust)
optimize_vault(...; solver=:ipopt)  # Gradient-based (faster)
```

### Returns
```julia
(
    rise = 0.5u"m",           # Optimal rise
    thickness = 0.075u"m",    # Optimal thickness
    result = VaultResult(...), # Full analysis result
    objective_value = 0.314,  # Minimized volume/weight/carbon
    status = :optimal,        # :optimal, :feasible, :infeasible
)
```

## Analytical API

For evaluating a specific geometry (both rise AND thickness fixed):

```julia
opts = FloorOptions(vault=VaultOptions(
    lambda = 12.0,         # or rise = 0.5u"m"
    thickness = 75u"mm",
    material = NWC_4000,   # default
))

result = _size_span_floor(Vault(), span, sdl, live; options=opts)

# VaultResult fields
result.thickness         # Shell thickness
result.rise              # Final rise (after elastic shortening)
result.initial_rise      # Design rise (before shortening)
result.thrust_dead       # Horizontal thrust (dead) [kN/m]
result.thrust_live       # Horizontal thrust (live) [kN/m]
result.σ_max             # Governing stress [MPa]
result.governing_case    # :symmetric or :asymmetric

# Design checks
result.stress_check.ok       # Stress ≤ allowable?
result.deflection_check.ok   # Rise reduction acceptable?
is_adequate(result)          # All checks pass?
```

## Configuration via VaultOptions

```julia
VaultOptions(
    # Rise: choose ONE (or use default lambda_bounds = (10, 20))
    lambda_bounds = (10.0, 20.0),  # λ = span/rise
    rise_bounds = (0.5u"m", 1.5u"m"),
    lambda = 12.0,
    rise = 0.5u"m",
    
    # Thickness: bounds OR fixed (default: 2"–4")
    thickness_bounds = (2.0u"inch", 4.0u"inch"),
    thickness = 75u"mm",
    
    # Geometry
    trib_depth = 1.0u"m",       # Tributary depth / rib spacing
    rib_depth = 0.0u"m",        # Rib width (0 = no ribs)
    rib_apex_rise = 0.0u"m",    # Rib height above extrados
    
    # Loading
    finishing_load = 0.0u"kN/m^2",  # Topping/screed
    
    # Design checks
    allowable_stress = nothing,  # Default: 0.45 fc'
    deflection_limit = nothing,  # Default: span/240
    check_asymmetric = true,     # Check half-span live
    
    # Optimization
    objective = MinVolume(),     # MinWeight, MinCarbon, MinCost
    solver = :grid,              # or :ipopt
    n_grid = 20,                 # Grid points per dimension
    n_refine = 2,                # Refinement iterations
    
    # Material
    material = NWC_4000,         # Concrete for ρ, E, fc'
)
```

## Key Functions

| Function | Description | API Level |
| -------- | ----------- | --------- |
| `optimize_vault` | Find optimal geometry | **Public** |
| `_size_span_floor(::Vault)` | Evaluate fixed geometry | Internal |
| `vault_stress_symmetric` | Stress/thrust under full UDL | Internal |
| `vault_stress_asymmetric` | Stress/thrust under half-span live | Internal |
| `solve_equilibrium_rise` | Elastic shortening iteration | Internal |

## Analysis Method

**Default**: `HaileAnalytical()` — closed-form 3-hinge parabolic arch.

**Future**: `ShellFEA()` — shell finite element validation.

## Allowable Stress

Default: **0.45 × fc'** (unreinforced concrete practice).

Override: `VaultOptions(allowable_stress=10.0)` (MPa).

## Thrust Integration

`VaultResult` provides `thrust_dead` and `thrust_live` as line loads (kN/m). These are applied to the Asap model via `slab_edge_line_loads`, where adjacent vault thrusts cancel at interior supports.

## Reference

MATLAB implementation by Nebyu Haile (saved in `reference/`):
- `VaultStress.m` — Symmetric analysis
- `VaultStress_Asymmetric.m` — Asymmetric analysis  
- `solveFullyCoupledRise.m` — Elastic shortening solver
