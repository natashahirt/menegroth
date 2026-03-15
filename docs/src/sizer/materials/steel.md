# Steel Materials

```@meta
CurrentModule = StructuralSizer
```

> ```julia
> using StructuralSizer
> steel = A992_Steel          # ASTM A992: Fy = 50 ksi, Fu = 65 ksi
> rebar = Rebar_60            # ASTM A615 Grade 60: Fy = 60 ksi
> stud  = Stud_51             # ASTM A1044 headed stud: Fy = 51 ksi
> ```

## Overview

Steel materials in StructuralSizer are parametric types built on `Metal{K, T_P, T_D}`, where the type parameter `K` distinguishes structural steel from reinforcing steel. Two type aliases provide the primary user-facing interface:

- **`StructuralSteel`** — hot-rolled wide-flange, HSS, and similar sections
- **`RebarSteel`** — reinforcing bars and headed studs

All presets are `const` instances registered in a global name registry for display purposes.

## Key Types

```@docs
Metal
```

### Type Aliases

| Alias | Type Tag | Use |
|:------|:---------|:----|
| `StructuralSteel{T_P, T_D}` | `Metal{StructuralSteelType, T_P, T_D}` | Wide-flange, HSS, pipe |
| `RebarSteel{T_P, T_D}` | `Metal{RebarType, T_P, T_D}` | Reinforcing bars, studs |

### Fields

| Field | Type | Description |
|:------|:-----|:------------|
| `E` | Pressure | Young's modulus |
| `G` | Pressure | Shear modulus |
| `Fy` | Pressure | Yield strength |
| `Fu` | Pressure | Ultimate strength |
| `ρ` | Density | Mass density |
| `ν` | `Float64` | Poisson's ratio |
| `ecc` | `Float64` | Embodied carbon coefficient [kgCO₂e/kg] |
| `cost` | `Float64` | Unit cost [\$/kg] (`NaN` if not set) |

## Structural Steel Presets

| Preset | Standard | Fy | Fu | E | ecc |
|:-------|:---------|:---|:---|:--|:----|
| `A992_Steel` | ASTM A992 (USA) | 345 MPa (50 ksi) | 450 MPa (65 ksi) | 200 GPa | 1.61 |
| `S355_Steel` | EN 10025 S355 (EU) | 355 MPa | 510 MPa | 210 GPa | 1.61 |

## Rebar Presets

| Preset | Standard | Fy | Fu | ecc |
|:-------|:---------|:---|:---|:----|
| `Rebar_40` | ASTM A615 Gr. 40 | 276 MPa (40 ksi) | 414 MPa (60 ksi) | 1.72 |
| `Rebar_60` | ASTM A615 Gr. 60 | 414 MPa (60 ksi) | 620 MPa (90 ksi) | 1.72 |
| `Rebar_75` | ASTM A615 Gr. 75 | 517 MPa (75 ksi) | 689 MPa (100 ksi) | 1.72 |
| `Rebar_80` | ASTM A615 Gr. 80 | 552 MPa (80 ksi) | 724 MPa (105 ksi) | 1.72 |

## Stud Preset

| Preset | Standard | Fy | Fu | ecc |
|:-------|:---------|:---|:---|:----|
| `Stud_51` | ASTM A1044 | 351.6 MPa (51 ksi) | 448.2 MPa (65 ksi) | 1.72 |

`Stud_51` is used for headed shear stud reinforcement in punching shear checks (ACI 318 §22.6) and composite deck connections.

## Functions

```@docs
material_name
```

`register_material!(name, mat)` — registers a material instance in the global name registry. Used internally by preset constructors.

## Implementation Details

- **Parametric type**: `Metal{K, T_P, T_D}` is parametric over the pressure unit type `T_P` and density unit type `T_D`. This allows presets to be defined in any consistent unit system (GPa/kg·m⁻³ or ksi/pcf) while Unitful handles conversions.
- **Type tags**: `StructuralSteelType` and `RebarType` are empty structs used solely for dispatch. Capacity functions such as `get_ϕMn`, `get_ϕVn`, and `get_ϕPn` dispatch differently based on whether the material is structural steel or rebar.
- **Name registry**: `register_material!` stores a `UInt → String` mapping keyed by `objectid`. The `material_name` function looks up this registry and falls back to type-specific formatting (e.g., `"Steel (Fy=50 ksi)"`) for unregistered instances.
- **Embodied carbon**: ECC values are from the ICE Database v4.1 (Oct 2025). Steel sections use 1.61 kgCO₂e/kg; rebar uses 1.72 kgCO₂e/kg, reflecting the higher energy intensity of bar production.
- **Cost field**: The `cost` field defaults to `NaN` and is only required when using `MinCost` optimization objectives.

## Limitations & Future Work

- **Stainless steel**: No stainless steel presets are defined. Add via `StructuralSteel(E, G, Fy, Fu, ρ, ν, ecc)` with appropriate properties.
- **Temperature dependence**: Material properties are room-temperature values. High-temperature reduction factors for fire analysis are handled separately in the fire protection module.
- **Weldability**: No weldability or toughness (CVN) properties are tracked.
