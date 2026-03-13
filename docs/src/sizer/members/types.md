# Member Types & Demands

> ```julia
> using StructuralSizer
> demand = MemberDemand(1, 200u"kip", 0u"kip", 150u"kip*ft", 0u"kip*ft",
>     -100u"kip*ft", 150u"kip*ft", 0u"kip*ft", 0u"kip*ft",
>     30u"kip", 0u"kip", 0u"kip*ft", 0.5u"inch", 100u"inch^4", true)
> geom = SteelMemberGeometry(12u"ft", 12u"ft", 1.0, 1.0, 1.0, true)
> ```

## Overview

The member types module defines the data structures that represent **demands** (factored load effects) and **geometry** (unbraced lengths, effective length factors, boundary conditions) for structural members. These types form the inputs to all capacity checkers and optimization routines.

All demand types subtype `AbstractDemand` and all geometry types subtype `AbstractMemberGeometry`, both declared in `StructuralSizer/src/types.jl`.

## Key Types

### Demand Types

**`MemberDemand{T}`**

`MemberDemand{T}` is the unified demand envelope for steel and general framing members (beams, columns, beam-columns). It carries:

| Field | Description |
|:------|:------------|
| `member_idx` | Index into the member list |
| `Pu_c`, `Pu_t` | Factored compression / tension (always positive magnitudes) |
| `Mux`, `Muy` | Strong-axis and weak-axis moment envelopes |
| `M1x`, `M2x` | Smaller / larger end moments, strong axis (for B1 amplification) |
| `M1y`, `M2y` | Smaller / larger end moments, weak axis (for B1 amplification) |
| `Vu_strong`, `Vu_weak` | Strong-axis and weak-axis shear |
| `Tu` | Factored torsion (set to 0 when torsion is not present) |
| `δ_max_LL`, `δ_max_total`, `I_ref` | Max live-load deflection, max total deflection, and reference moment of inertia from analysis (for deflection scaling) |
| `transverse_load` | Whether transverse loading exists between supports (affects Cm) |

**`RCColumnDemand{T}`**

`RCColumnDemand{T}` is the demand for reinforced concrete columns per ACI 318. It includes biaxial moments and the sustained load ratio `βdns` used in slenderness magnification:

| Field | Description |
|:------|:------------|
| `Pu` | Factored axial load (positive = compression) |
| `Mux`, `Muy` | Maximum moments about x and y axes |
| `M1x`, `M2x`, `M1y`, `M2y` | End moments for Cm calculation |
| `βdns` | Ratio of sustained factored axial load to total (always `Float64`) |

**`RCBeamDemand{T}`**

`RCBeamDemand{T}` is the demand for reinforced concrete beams (flexure, shear, torsion, optional axial):

| Field | Description |
|:------|:------------|
| `Mu` | Factored moment |
| `Vu` | Factored shear |
| `Nu` | Factored axial compression (0 for pure beams) |
| `Tu` | Factored torsion (0 = no torsion demand) |

### Geometry Types

**`SteelMemberGeometry{T<:Unitful.Length}`**

`SteelMemberGeometry{T<:Unitful.Length}` carries the geometric parameters needed for AISC 360 capacity checks:

| Field | Description |
|:------|:------------|
| `L` | Total member length |
| `Lb` | Unbraced length for lateral-torsional buckling |
| `Cb` | Moment gradient factor (1.0 = uniform moment) |
| `Kx`, `Ky` | Effective length factors for strong and weak axis |
| `braced` | Whether the frame is braced against sidesway |

**`ConcreteMemberGeometry{T<:Unitful.Length}`**

`ConcreteMemberGeometry{T<:Unitful.Length}` carries the geometric parameters needed for ACI 318 slenderness checks:

| Field | Description |
|:------|:------------|
| `L` | Span length |
| `Lu` | Unsupported length for slenderness |
| `k` | Effective length factor |
| `braced` | Whether the frame is braced against sidesway |

**`TimberMemberGeometry`**

`TimberMemberGeometry` carries geometric parameters for NDS timber member checks. All lengths are in meters (`Float64`):

| Field | Description |
|:------|:------------|
| `L` | Total member length [m] |
| `Lu` | Unbraced length for beam stability [m] |
| `Le` | Effective column length [m] |
| `support` | Boundary condition: `:pinned`, `:fixed`, or `:cantilever` |

### Checker Interfaces

**`AbstractCapacityChecker`**

`AbstractCapacityChecker` is the base type for all design code capacity checkers. Any concrete checker must implement:

- `create_cache(checker, n_sections)` — allocate a checker-specific capacity cache
- `precompute_capacities!(checker, cache, catalog, material, objective)` — fill the cache with capacity values for each catalog section
- `is_feasible(checker, cache, j, section, material, demand, geometry)` — return `true` if section `j` satisfies all limit states
- `get_objective_coeff(checker, cache, j)` — return the optimization objective coefficient (e.g. weight, cost)

Optional: `get_feasibility_error_msg(checker, demand, geometry)` for diagnostic messages.

**`AbstractCapacityCache`**

`AbstractCapacityCache` is the base type for checker-specific caches that store precomputed capacity values, avoiding redundant calculations during optimization.

## Functions

- `create_cache(checker, n_sections)` — allocate a checker-specific capacity cache.
- `precompute_capacities!(checker, cache, catalog, material, objective)` — fill the cache with capacity values for each catalog section.
- `is_feasible(checker, cache, j, section, material, demand, geometry)` — return `true` if section `j` satisfies all limit states.
- `get_objective_coeff(checker, cache, j)` — return the optimization objective coefficient (e.g. weight, cost).
- `get_feasibility_error_msg(checker, demand, geometry)` — return a diagnostic message when feasibility fails.

## Implementation Details

The demand and geometry types are **parametric** on their numeric type `T`. Steel and concrete demands use `Unitful` quantities (e.g. `kip`, `kip*ft`) throughout, ensuring dimensional consistency at compile time. `TimberMemberGeometry` uses bare `Float64` values in meters by convention.

The `MemberDemand` type stores both envelope moments (`Mux`, `Muy`) and end moments (`M1x`, `M2x`, `M1y`, `M2y`). The end moments are needed for computing the equivalent uniform moment factor `Cm` in AISC §C2 / Appendix 8 moment amplification. The `transverse_load` flag switches Cm to 1.0 per AISC A-8-4.

The `AbstractCapacityChecker` / `AbstractCapacityCache` interface follows a two-phase pattern:
1. **Precompute**: fill the cache with capacities for all sections in the catalog (done once).
2. **Query**: the MIP solver calls `is_feasible` and `get_objective_coeff` repeatedly during branch-and-bound.

This separation keeps the solver loop fast by avoiding repeated capacity computations.

## Options & Configuration

Demand and geometry types are constructed directly — they have no configuration options beyond their fields. The checker interface is configured through concrete checker types (e.g. `AISCChecker`, `ACIColumnChecker`) which carry resistance factors and design preferences.

## Limitations & Future Work

- `TimberMemberGeometry` does not carry units (uses raw `Float64` in meters), unlike the steel and concrete geometry types.
- There is no `PixelFrameDemand` type; PixelFrame members reuse `MemberDemand` or `RCBeamDemand`.
- The `AbstractCapacityChecker` interface does not yet support multi-objective optimization (e.g. Pareto weight vs. carbon).
