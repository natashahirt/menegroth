# Foundation Types

> ```julia
> using StructuralSizer
> using Unitful
> soil = medium_sand
> demand = FoundationDemand(1; Pu=500.0kip, Ps=400.0kip, Mux=100.0kip * u"ft")
> opts   = SpreadFootingOptions(pier_c1=24u"inch", pier_c2=24u"inch", pier_shape=:rectangular)
> result = design_footing(SpreadFooting(), demand, soil; opts=opts)
> footprint_area(result)  # ft²
> utilization(result)     # bearing utilization ratio
> ```

## Overview

The foundation module provides design for shallow and deep foundation systems.
The abstract hierarchy separates foundation types, soil models, demand inputs,
and result structures with a common interface for volume and utilization queries.

**Source:** `StructuralSizer/src/foundations/`

For docstring-level API documentation of individual types and functions, see the
code-specific pages:

- [ACI Foundation Design](codes/aci.md) — spread, strip, and mat footing design per ACI 318 / ACI 336.2R
- [IS Foundation Design](codes/is.md) — spread footing design per IS 456

The hierarchy:

```
AbstractFoundation
├── AbstractShallowFoundation
│   ├── SpreadFooting
│   ├── CombinedFooting
│   ├── StripFooting
│   └── MatFoundation
└── AbstractDeepFoundation
    ├── DrivenPile
    ├── DrilledShaft
    └── Micropile
```

## Key Types

### Abstract Hierarchy

`AbstractFoundation` is the root type.  `AbstractShallowFoundation` and
`AbstractDeepFoundation` are the two branches.  See the tree above for the
full hierarchy.

### Shallow Foundation Types

```@docs
SpreadFooting
StripFooting
MatFoundation
```

- **`SpreadFooting`** — isolated pad footing under a single column.
- **`CombinedFooting`** — footing supporting two or more columns (design not yet implemented).
- **`StripFooting`** — continuous strip footing along a column line.
- **`MatFoundation`** — full-building mat (raft) foundation.

See [ACI Foundation Design](codes/aci.md) for full docstrings.

### Deep Foundation Types

- **`DrivenPile`**, **`DrilledShaft`**, **`Micropile`** — type stubs for future
  deep foundation design (no design implementations yet).

### Soil Model

The `Soil` struct stores geotechnical parameters used for bearing, subgrade
reaction, and pile capacity calculations.  See the table below for fields.

```@docs
Soil
loose_sand
medium_sand
dense_sand
soft_clay
stiff_clay
hard_clay
```

### Soil Presets

Six preset soils are provided (see table below).  Import them directly:
`loose_sand`, `medium_sand`, `dense_sand`, `soft_clay`, `stiff_clay`, `hard_clay`.

### Demand

`FoundationDemand` wraps the column-to-foundation interface including factored
and service loads, moments, shears, and column geometry.

```@docs
FoundationDemand
```

### Result Types

`AbstractFoundationResult` is the base result type.  Concrete subtypes:

- **`SpreadFootingResult`**, **`StripFootingResult`**, **`MatFootingResult`** —
  see [ACI Foundation Design](codes/aci.md).
- **`CombinedFootingResult`**, **`PileCapResult`** — defined but not yet
  produced by any design function.

### Mat Analysis Methods

`AbstractMatMethod` is the base for mat analysis strategies:

- **`RigidMat`** — rigid mat, uniform pressure (ACI 336.2R §4.2).
- **`ShuklaAFM`** — Shukla approximate flexible method (ACI 336.2R §6.1.2).
- **`WinklerFEA`** — FEA plate on Winkler springs (ACI 336.2R §6.4).

See [ACI Foundation Design](codes/aci.md) for full docstrings.

## Functions

### Common Interface

The following functions operate on any `AbstractFoundationResult`:

- `footprint_area(result)` — plan area of the foundation.
- `footing_length(result)` / `footing_width(result)` — plan dimensions.
- `utilization(result)` — governing utilization ratio (max of bearing, punching, shear, flexure).
- Concrete and rebar volumes are available from the result fields.

### Design Entry Point

- **`design_footing`** — main design entry point; dispatches on foundation type.
  See [ACI Foundation Design](codes/aci.md) and [IS Foundation Design](codes/is.md).
- **`recommend_foundation_strategy`** — computes coverage ratio and recommends
  `:spread`, `:strip`, or `:mat`.  See [ACI Foundation Design](codes/aci.md).

### Type Mapping

- `foundation_type(sym)` — convert a `Symbol` to its `AbstractFoundation` subtype.
- `foundation_symbol(f)` — convert an `AbstractFoundation` instance to its `Symbol`.

## Implementation Details

### Soil Model

The `Soil` struct stores geotechnical parameters:

| Field | Symbol | Description |
|:------|:-------|:------------|
| `qa` | ``q_a`` | Allowable bearing pressure |
| `γ` | ``\gamma`` | Soil unit weight |
| `ϕ` | ``\phi`` | Friction angle |
| `c` | ``c`` | Cohesion |
| `Es` | ``E_s`` | Soil elastic modulus |
| `qs` | ``q_s`` | Unit skin friction (piles) |
| `qp` | ``q_p`` | Unit end bearing (piles) |
| `ks` | ``k_s`` | Modulus of subgrade reaction |

Six preset soils are provided from Bowles (1996) Table 9-1 and ACI 336.2R:

| Preset | ``q_a`` | ``\phi`` | ``k_s`` |
|:-------|:--------|:---------|:--------|
| `loose_sand` | 75 kPa | 28° | 5 000 kN/m³ |
| `medium_sand` | 150 kPa | 32° | 25 000 kN/m³ |
| `dense_sand` | 300 kPa | 38° | 100 000 kN/m³ |
| `soft_clay` | 50 kPa | 0° | 12 000 kN/m³ |
| `stiff_clay` | 150 kPa | 0° | 50 000 kN/m³ |
| `hard_clay` | 300 kPa | 0° | 150 000 kN/m³ |

### Foundation Demand

`FoundationDemand` wraps the column-to-foundation interface:

- Factored loads: ``P_u, M_{ux}, M_{uy}, V_{ux}, V_{uy}``
- Service load: ``P_s`` (for bearing check)
- Column dimensions: ``c_1, c_2`` and shape (`:rectangular`, `:circular`)

### Foundation Strategy Recommendation

`recommend_foundation_strategy` computes the coverage ratio:

```math
R = \frac{\sum_i P_{s,i} / q_a}{\text{total footprint}}
```

and recommends `:spread` (R < 0.3), `:strip` (0.3 ≤ R < threshold), or `:mat`
(R ≥ threshold, default 0.5).

### Result Interface

All result types implement a common interface:
- `concrete_volume`: Total concrete volume
- `steel_volume`: Total rebar volume
- `footprint_area`: Plan area of the foundation
- `utilization`: Governing utilization ratio (max of bearing, punching, shear, flexure)

## Options & Configuration

The option structs configure code-specific design parameters:

- **`SpreadFootingOptions`** — cover, bar size, pier shape, strength reduction factors.
- **`StripFootingOptions`** — similar to spread footing options, for continuous strips.
- **`MatFootingOptions`** — analysis method selection, cover, bar sizes, minimum thickness, and optional edge overhang.
- **`FoundationOptions`** — top-level container selecting code, strategy, and mat coverage threshold.

See [ACI Foundation Design](codes/aci.md) for full docstrings and default values.

```@docs
SpreadFootingOptions
StripFootingOptions
MatFootingOptions
FoundationOptions
```

Key `SpreadFootingOptions` fields:

| Field | Default | Description |
|:------|:--------|:------------|
| `material` | `RC_4000_60` | Concrete + rebar material bundle |
| `cover` | 3 in. | Clear cover to reinforcement (cast against soil) |
| `bar_size` | 8 | Rebar bar size (#8, etc.) |
| `pier_shape` | `:rectangular` | Pier/column shape (`:rectangular` or `:circular`) |
| `pier_c1` | 18 in. | Pier dimension parallel to footing length (or diameter) |
| `pier_c2` | 18 in. | Pier dimension parallel to footing width (ignored for `:circular`) |
| `min_depth` | 12 in. | Minimum footing thickness before iteration |
| `size_increment` | 3 in. | Round plan dimensions up to this increment |
| `ϕ_flexure` | 0.90 | Flexure strength reduction factor (ACI 318-11 §9.3.2) |
| `ϕ_shear` | 0.75 | Shear strength reduction factor (ACI 318-11 §9.3.2) |
| `ϕ_bearing` | 0.65 | Bearing strength reduction factor |
| `objective` | `MinVolume()` | Optimization objective for sizing (volume/quantity) |

`MatFootingOptions` selects the analysis method:

| Method | Description |
|:-------|:------------|
| `RigidMat()` | Rigid mat, uniform pressure (ACI 336.2R §4.2) |
| `ShuklaAFM()` | Shukla approximate flexible method (ACI 336.2R §6.1.2) |
| `WinklerFEA()` | FEA plate on Winkler springs (ACI 336.2R §6.4) |

## Limitations & Future Work

- Deep foundation types (`DrivenPile`, `DrilledShaft`, `Micropile`) are defined
  but have **no design implementations**.
- `CombinedFooting` design is not implemented.
- Mat foundation design assumes a rectangular plan; irregular shapes require
  custom meshing.
- Soil–structure interaction beyond Winkler springs (e.g., elastic half-space,
  finite element soil models) is not supported.
- Lateral load effects on foundations (overturning, sliding) are not checked.
