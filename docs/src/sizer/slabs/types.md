# Slab Types & Options

> ```julia
> using StructuralSizer
> ft = FlatPlate()
> spanning_behavior(ft)                # BeamlessSpanning()
> min_thickness(ft, 8.0u"m")           # ACI minimum slab thickness
> ```

## Overview

Every floor system in StructuralSizer inherits from `AbstractFloorSystem`,
which branches into three material families—concrete, steel, and timber—plus
special-purpose types for vaults and user-defined geometries.  Each type carries a
[`SpanningBehavior`](@ref) trait that controls how tributary loads are distributed
to the supporting structure.

The hierarchy:

```
AbstractFloorSystem
├── AbstractConcreteSlab
│   ├── OneWay, TwoWay, FlatPlate, FlatSlab
│   ├── PTBanded, Waffle, HollowCore, Grade
│   ├── Vault
│   └── ShapedSlab (custom geometry)
├── AbstractSteelFloor
│   ├── CompositeDeck, NonCompositeDeck
│   └── JoistRoofDeck
└── AbstractTimberFloor
    ├── CLT, DLT, NLT
    └── MassTimberJoist
```

The module defines a uniform result interface: any `AbstractFloorResult`
exposes `self_weight`, `total_depth`, `volume_per_area`, and `material_volumes`,
regardless of the underlying system.

**Source:** `StructuralSizer/src/slabs/types.jl`

## Slab Sizing API

### API Hierarchy

```
size_slabs!(struc; options)          # Size all slabs in structure
└── size_slab!(struc, idx; options)  # Size single slab (scripting/debug)
    └── _size_slab!(floor_type, ...) # Type-dispatched implementation
        ├── FlatPlate / FlatSlab → size_flat_plate!()
        ├── Vault → optimize_vault() or _size_span_floor()
        └── (others) → not yet implemented
```

### Quick Start

```julia
using StructuralSizer

# Configure a flat-plate design option set
opts = FlatPlateOptions(method=DDM())
floor_symbol(FlatPlate())   # :flat_plate

# Standalone vault optimization
result = optimize_vault(6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2")
```

### Floor Type Status

| Type | Status | Description |
|:-----|:-------|:------------|
| `FlatPlate` | ✅ Full | Two-way flat plate (ACI 318 DDM/EFM/FEA) |
| `Vault` | ✅ Full | Unreinforced parabolic vault (Haile method) |
| `FlatSlab` | ✅ Full | Flat plate with drop panels (shared ACI 318 pipeline) |
| `TwoWay` | ⚠️ Stub | Two-way slab with beams |
| `OneWay` | ⚠️ Stub | One-way slab |
| `Waffle` | ⚠️ Stub | Two-way joist system |
| `PTBanded` | ⚠️ Stub | Post-tensioned banded |

### Configuration via AbstractFloorOptions

Each floor system has its own options type inheriting from `AbstractFloorOptions`:

```julia
FlatPlateOptions(method=DDM(), ...)      # Flat plate / flat slab / waffle / PT
OneWayOptions(material=RC_4000_60, ...)  # One-way slab settings
VaultOptions(lambda_bounds=(10, 20), ...)# Vault-specific settings
CompositeDeckOptions(...)                # Composite steel deck
TimberOptions(...)                       # Timber panel floors
```

Pass the appropriate options type to `size_slabs!` or `size_slab!` — the slab's floor type determines dispatch.

### Adding New Floor Types

1. Define type in `types.jl` (e.g., `struct MyFloor <: AbstractFloorSystem end`)
2. Add options struct in `options.jl` if needed
3. Implement `_size_slab!(::MyFloor, struc, slab, idx; options, ...)` in `sizing.jl`
4. Or implement `_size_span_floor(::MyFloor, span, sdl, live; ...)` for span-based sizing

### File Structure

```
slabs/
├── types.jl            # Floor type definitions, result structs
├── options.jl          # AbstractFloorOptions, FlatPlateOptions, OneWayOptions, VaultOptions
├── sizing.jl           # Main API: size_slabs!, size_slab!, _size_slab!
├── utils/              # ACI strip geometry, tributary helpers
├── optimize/           # Vault NLP optimization
│   ├── api.jl          # optimize_vault()
│   └── problems.jl     # VaultNLPProblem
└── codes/
    ├── concrete/
    │   ├── flat_plate/  # DDM, EFM, pipeline, calculations
    │   └── sizing.jl    # _size_span_floor for CIP types
    └── vault/
        └── haile_unreinforced.jl
```

## Key Types

### Abstract Hierarchy

```@docs
AbstractFloorSystem
AbstractConcreteSlab
AbstractSteelFloor
AbstractTimberFloor
SpanningBehavior
OneWaySpanning
TwoWaySpanning
BeamlessSpanning
```

- `AbstractFloorSystem` — top-level abstract type for all floor/slab systems.
- `AbstractConcreteSlab <: AbstractFloorSystem` — base type for cast-in-place and precast concrete slabs.
- `AbstractSteelFloor <: AbstractFloorSystem` — base type for steel deck floor systems.
- `AbstractTimberFloor <: AbstractFloorSystem` — base type for mass timber and joist floor systems.

### Concrete Slab Types

- `OneWay` — one-way spanning CIP concrete slab.
- `TwoWay` — two-way spanning CIP concrete slab with beams.
- `FlatPlate` — beamless two-way CIP slab (no drop panels).
- `FlatSlab` — beamless two-way CIP slab with drop panels.
- `PTBanded` — post-tensioned banded slab.
- `Waffle` — waffle (ribbed) slab.
- `HollowCore` — precast prestressed hollow core plank.
- `Grade` — slab-on-grade (no structural sizing).

```@docs
OneWay
TwoWay
FlatPlate
FlatSlab
PTBanded
Waffle
HollowCore
Vault
Grade
ShapedSlab
```

### Steel Floor Types

- `CompositeDeck` — composite steel deck with concrete topping.
- `NonCompositeDeck` — steel deck without composite action.
- `JoistRoofDeck` — open-web steel joist roof system with metal deck.

```@docs
CompositeDeck
NonCompositeDeck
JoistRoofDeck
```

### Timber Floor Types

- `CLT` — cross-laminated timber panel.
- `DLT` — dowel-laminated timber panel.
- `NLT` — nail-laminated timber panel.
- `MassTimberJoist` — traditional timber joist with subfloor panel.

```@docs
CLT
DLT
NLT
MassTimberJoist
```

### Special Types

- `Vault` — vault / shell floor system (parabolic arch geometry).
- `ShapedSlab` — user-defined slab geometry with custom `sizing_fn`.

### Support & Spanning Enums

- `SupportCondition` — enum for one-way slab support conditions: `SIMPLE`, `ONE_END_CONT`, `BOTH_ENDS_CONT`, `CANTILEVER`.
- `LoadDistributionType` — enum for load distribution method: `DISTRIBUTION_ONE_WAY`, `DISTRIBUTION_TWO_WAY`, `DISTRIBUTION_POINT`, `DISTRIBUTION_CUSTOM`.

```@docs
SupportCondition
LoadDistributionType
```

### Analysis Method Types

```@docs
FlatPlateAnalysisMethod
DDM
EFM
FEA
RuleOfThumb
HaileAnalytical
ShellFEA
```

### Result Types

- `AbstractFloorResult` — base type for all floor sizing results.
- `CIPSlabResult` — result for cast-in-place concrete slabs (one-way, two-way, flat plate, waffle, PT banded).
- `ProfileResult` — result for precast profile-based slabs (hollow core).
- `CompositeDeckResult` — result for composite steel deck systems.
- `JoistDeckResult` — result for steel joist roof deck systems.
- `TimberPanelResult` — result for mass timber panel systems (CLT, DLT, NLT).
- `TimberJoistResult` — result for timber joist systems.
- `VaultResult` — result for vault/shell floor systems.
- `ShapedSlabResult` — result for user-defined shaped slabs.
- `FlatPlatePanelResult` — detailed per-panel result for flat plate design (moments, reinforcement, punching).

```@docs
AbstractFloorResult
CIPSlabResult
ProfileResult
CompositeDeckResult
JoistDeckResult
TimberPanelResult
TimberJoistResult
VaultResult
ShapedSlabResult
FlatPlatePanelResult
```

### Punching & Reinforcement Results

```@docs
PunchingCheckResult
ShearStudDesign
ClosedStirrupDesign
ShearCapDesign
ColumnCapitalDesign
StripReinforcement
```

### Structural Effects

Vault-type floor systems produce lateral thrust forces that must be resisted by the supporting
structure. The `has_structural_effects` and `apply_effects!` functions check for and apply these
effects during the design pipeline.

## Functions

### Spanning Behavior Queries

```@docs
spanning_behavior
is_one_way
is_two_way
is_beamless
requires_column_tributaries
```

### Result Accessors

```@docs
self_weight
total_depth
volume_per_area
material_volumes
```

### Structural Effects

```@docs
has_structural_effects
apply_effects!
```

### Load Distribution

```@docs
load_distribution
get_gravity_loads
default_tributary_axis
resolve_tributary_axis
```

### Type ↔ Symbol Mapping

```@docs
floor_type
floor_symbol
infer_floor_type
```

### Adequacy Checks

```@docs
is_adequate
deflection_ok
punching_ok
max_punching_ratio
deflection_ratio
```

## Implementation Details

The type hierarchy uses Julia's abstract-type dispatch for code reuse.  Singleton
types (e.g. `FlatPlate()`, `CLT()`) carry no data and act as dispatch tags; all
configuration lives in the corresponding `Options` struct (see below).

`SpanningBehavior` is a **trait** attached via `spanning_behavior(ft)`.  The
mapping is:

| Slab type       | Behavior            |
|:----------------|:--------------------|
| `OneWay`        | `OneWaySpanning()`  |
| `TwoWay`        | `TwoWaySpanning()`  |
| `FlatPlate`     | `BeamlessSpanning()`|
| `FlatSlab`      | `BeamlessSpanning()`|
| `Waffle`        | `TwoWaySpanning()`  |
| `PTBanded`      | `TwoWaySpanning()`  |
| `Vault`         | `OneWaySpanning()`  |
| `CLT`           | `OneWaySpanning()`  |
| `CompositeDeck` | `OneWaySpanning()`  |
| `ShapedSlab`    | `TwoWaySpanning()`  |

`material_volumes` returns a `Dict{Symbol,Length}` keyed by material
(`:concrete`, `:steel`, `:timber`), computed from result fields via internal
`_volume_impl` dispatch on `Val(mat)`.  For `FlatPlatePanelResult`, rebar volume
is estimated from designed reinforcement with a 10% lap-splice allowance.

All result types are parametric on length (`L`) and force (`F`) unit types,
preserving Unitful dimensional safety throughout the pipeline.

The `floor_type_map` and `floor_symbol_map` dictionaries provide O(1) conversion
between `Symbol` keys (used in JSON/serialization) and dispatch-tag instances.
`infer_floor_type` returns `:one_way` when `max(span_x, span_y) / min(span_x, span_y) > 2`.

## Options & Configuration

```@docs
AbstractFloorOptions
FlatPlateOptions
FlatSlabOptions
OneWayOptions
VaultOptions
CompositeDeckOptions
TimberOptions
```

`FlatPlateOptions` is the most complex, exposing analysis method selection
(`DDM`, `EFM`, `FEA`, `RuleOfThumb`), punching resolution strategy
(`:grow_columns`, `:reinforce_first`, `:reinforce_last`), deflection limit,
and fire rating overrides. Convergence tolerances (`max_iterations`,
`column_tol`, `h_increment`) are pipeline keyword arguments (internal `size_flat_plate!` path), not fields on the options struct.

`FlatSlabOptions` composes a `FlatPlateOptions` internally, adding drop panel
geometry controls (`h_drop`, `a_drop_ratio`).

`VaultOptions` accepts rise specification in four forms—`lambda_bounds`,
`rise_bounds`, fixed `lambda`, or fixed `rise`—plus thickness bounds and
analysis toggles.

## Limitations & Future Work

- `HollowCore`, `CompositeDeck`, `NonCompositeDeck`, `JoistRoofDeck`, `CLT`,
  `DLT`, `NLT`, and `MassTimberJoist` sizing functions are **stubs** that raise
  no-op results (they are skipped by `size_slabs!` / `size_slab!`). Catalog-based selection is planned.
- `PTBanded` uses heuristic thickness from PTI DC20.9; full tendon design is not
  yet implemented.
- `Grade` (slab-on-grade) has no structural sizing—thickness is user-specified.
- The `ShapedSlab` escape hatch relies on the user supplying a correct
  `sizing_fn`; no internal validation is performed on the returned result.
- `required_materials` for `ShapedSlab` returns an empty tuple—the user must
  track materials manually.
