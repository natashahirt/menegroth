# Timber Materials

```@meta
CurrentModule = StructuralSizer
```

> ```julia
> using StructuralSizer
> # Define a custom timber material (no presets yet)
> timber = Timber(:douglas_fir, :no1, 12.4e9u"Pa", 6.9e9u"Pa",
>     7.6e6u"Pa", 5.2e6u"Pa", 1.0e6u"Pa", 7.6e6u"Pa", 4.3e6u"Pa",
>     500.0u"kg/m^3", 0.31)
> ```

## Overview

The `Timber` material type stores NDS reference design values for sawn lumber and engineered wood products. Reference values are unadjusted — adjustment factors (CD, CM, Ct, CL, CF, Ci, etc.) are applied at design check time per NDS 2018.

!!! note "Current Status"
    The `Timber` type is fully defined but **no presets are provided yet**. The NDS design checker is minimal. Full NDS 2018 implementation (sawn lumber, glulam, CLT) is planned for a future release.

## Key Types

```@docs
Timber
```

### Fields

| Field | Type | Description |
|:------|:-----|:------------|
| `species` | `Symbol` | Species group (e.g., `:douglas_fir`, `:southern_pine`) |
| `grade` | `Symbol` | Lumber grade (e.g., `:select_structural`, `:no1`, `:no2`) |
| `E` | Pressure | Reference modulus of elasticity |
| `Emin` | Pressure | Minimum E for stability (buckling) calculations |
| `Fb` | Pressure | Reference bending design value |
| `Ft` | Pressure | Reference tension parallel to grain |
| `Fv` | Pressure | Reference shear parallel to grain |
| `Fc` | Pressure | Reference compression parallel to grain |
| `Fc_perp` | Pressure | Reference compression perpendicular to grain |
| `ρ` | Density | Mass density |
| `ecc` | `Float64` | Embodied carbon [kgCO₂e/kg] |
| `cost` | `Float64` | Unit cost [\$/kg] (`NaN` if not set) |

## Implementation Details

- **Reference values**: All strength fields (`Fb`, `Ft`, `Fv`, `Fc`, `Fc_perp`) are NDS tabulated reference design values from NDS Supplement Tables 4A/4B/etc. These are **not** adjusted design values — multiply by the applicable adjustment factors for the specific loading and environmental conditions.
- **Emin**: The minimum modulus of elasticity is used in column stability calculations (NDS §3.7.1) and beam lateral stability (NDS §3.3.3). It accounts for the lower 5th percentile of the E distribution.
- **Embodied carbon**: Reference ECC values from ICE Database v4.1: general timber 0.31 kgCO₂e/kg, glulam 0.42 kgCO₂e/kg, CLT 0.44 kgCO₂e/kg.

## Options & Configuration

When presets are added, they will follow the same pattern as steel and concrete:

```julia
# Future presets (not yet implemented)
const Douglas_Fir_No1 = Timber(:douglas_fir, :no1, ...)
const Southern_Pine_No2 = Timber(:southern_pine, :no2, ...)
```

## Limitations & Future Work

- **No presets**: The timber.jl file is a stub. Species/grade presets from NDS Supplement tables need to be added.
- **NDS checker**: The design code checker for timber members is minimal. Full NDS 2018 implementation is planned, covering:
  - Bending (NDS §3.3): `Fb' = Fb × CD × CM × Ct × CL × CF × Cfu × Ci × Cr`
  - Compression (NDS §3.6–3.7): Column stability factor CP
  - Combined loading (NDS §3.9): Interaction equations
  - Connections (NDS Chapter 12): Bolts, lag screws, nails
- **Engineered wood**: Glulam and CLT have different property tables and adjustment factors. These will require separate type variants or additional fields.
