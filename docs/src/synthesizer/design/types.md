# Design Types & Parameters

> ```julia
> params = DesignParameters(
>     loads = GravityLoads(floor_LL = 50psf, roof_LL = 20psf),
>     materials = MaterialOptions(concrete = fc4000, steel = A992),
>     floor = FlatPlateOptions(method = DDM()),
> )
> modified = with(params; fire_rating = 2.0u"hr")
> ```

## Overview

Design types define the inputs to and outputs from the structural design pipeline. `DesignParameters` encapsulates all user-configurable options — loads, materials, floor system, member types, fire rating, and optimization objective. `BuildingDesign` wraps the structure with all design results, summary statistics, and metadata.

## Key Types

```@docs
DesignParameters
MaterialOptions
FoundationParameters
DisplayUnits
BuildingDesign
SlabDesignResult
ColumnDesignResult
BeamDesignResult
FoundationDesignResult
PunchingDesignResult
DesignSummary
```

## Functions

```@docs
with
compare_designs
```

## Implementation Details

### DesignParameters

`DesignParameters` is the master configuration struct with the following fields:

| Field | Type | Description |
|:------|:-----|:------------|
| `name` | `String` | Design name / identifier |
| `description` | `String` | Optional description |
| `loads` | `GravityLoads` | Floor, roof, and grade loading |
| `materials` | `MaterialOptions` | Material selections for concrete, rebar, steel, timber |
| `fire_rating` | `TimeQuantity` | Required fire resistance (drives ACI 216.1 checks) |
| `fire_protection` | `FireProtection` | Fire protection type for steel members (SFRM, intumescent) |
| `columns` | options | Column type and configuration |
| `beams` | options | Beam type and configuration |
| `floor` | `AbstractFloorOptions` | Floor system options (method, deflection limit, punching strategy) |
| `tributary_axis` | `Symbol` | Principal axis for one-way spanning |
| `foundation_options` | `FoundationParameters` | Soil, concrete, rebar, depth, grouping tolerance |
| `collinear_grouping` | `Bool` | When `true`, detect collinear members sharing a node with aligned direction and assign a shared group\_id before sizing (default `false`) |
| `deflection_limit` | `Float64` | L/n deflection limit |
| `optimize_for` | `AbstractObjective` | Optimization objective (MinWeight, MinVolume, MinCost, MinCarbon) |
| `load_combinations` | `Vector{LoadCombination}` | Load combinations per ASCE 7 §2.3.1 |
| `pattern_loading` | `Bool` | Enable pattern loading per ACI 318-11 §13.7.6 |
| `diaphragm_mode` | `Symbol` | Diaphragm stiffness model |
| `diaphragm_E`, `diaphragm_ν` | `Float64` | Diaphragm elastic properties |
| `default_frame_E`, `default_frame_G`, `default_frame_ρ` | quantities | Default frame material properties |
| `column_I_factor`, `beam_I_factor` | `Float64` | Stiffness reduction factors per ACI 318-11 §10.10.4.1 |
| `max_iterations` | `Int` | Maximum design iterations |
| `display_units` | `DisplayUnits` | Imperial or metric formatting |

### MaterialOptions

Groups material selections:
- `concrete` — `Concrete` material for RC members
- `rebar` — `RebarSteel` material
- `steel` — `StructuralSteel` for steel members
- `timber` — `Timber` material
- `slab`, `column`, `beam` — per-element material overrides

### FoundationParameters

| Field | Description |
|:------|:------------|
| `soil` | Soil type and bearing capacity |
| `options` | Foundation type options |
| `concrete` | Foundation concrete |
| `rebar` | Foundation rebar |
| `pier_width` | Minimum pier width |
| `min_depth` | Minimum footing depth |
| `group_tolerance` | Demand similarity for grouping (default 0.1) |

### BuildingDesign

`BuildingDesign{T,A,P}` is the complete output of `design_building`:

| Field | Description |
|:------|:------------|
| `structure` | The `BuildingStructure` (snapshot of designed state) |
| `params` | `DesignParameters` used |
| `slabs` | `Vector{SlabDesignResult}` |
| `columns` | `Vector{ColumnDesignResult}` |
| `beams` | `Vector{BeamDesignResult}` |
| `foundations` | `Vector{FoundationDesignResult}` |
| `summary` | `DesignSummary` |
| `asap_model` | Solved Asap model |
| `created` | Timestamp |
| `compute_time_s` | Wall-clock time |

### DesignSummary

| Field | Description |
|:------|:------------|
| `concrete_volume` | Total concrete volume |
| `steel_weight` | Total structural steel weight |
| `rebar_weight` | Total rebar weight |
| `timber_volume` | Total timber volume |
| `embodied_carbon` | Total kgCO₂e |
| `cost_estimate` | Estimated cost |
| `all_checks_pass` | `Bool` — all members adequate |
| `critical_element` | Element with highest demand/capacity ratio |
| `critical_ratio` | Governing demand/capacity ratio |

### `with` Helper

The `with(params; kwargs...)` function creates a modified copy of `DesignParameters` with specified fields changed, leaving all other fields unchanged. This is useful for parameter studies:

```julia
base = DesignParameters(loads = office_loads)
study = [with(base; fire_rating = r) for r in [1.0u"hr", 1.5u"hr", 2.0u"hr"]]
```

## Options & Configuration

### DisplayUnits

`DisplayUnits` controls how results are formatted in reports and summaries. Two presets are available:
- `imperial` — feet, inches, kips, psi
- `metric` — meters, millimeters, kN, MPa

## Limitations & Future Work

- `cost_estimate` uses simplified unit rates; detailed cost estimation with regional pricing is planned.
- `load_combinations` default to ASCE 7 §2.3.1; ASD combinations and Eurocode combinations are planned.
