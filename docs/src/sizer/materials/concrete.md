# Concrete Materials

> ```julia
> using StructuralSizer
> conc = NWC_4000              # 4000 psi normal-weight concrete
> rc   = RC_4000_60            # 4000 psi concrete + Grade 60 rebar
> rc.concrete.fc′              # → 4000 psi
> rc.rebar.Fy                  # → 414 MPa (60 ksi)
> ```

## Overview

Concrete materials in StructuralSizer cover three categories:

1. **`Concrete`** — plain concrete defined by compressive strength, elastic modulus, density, and aggregate type
2. **`ReinforcedConcreteMaterial`** — a concrete + rebar pair for RC design
3. **Earthen materials** — low-strength concrete variants for masonry/vault analysis

All presets compute elastic modulus per ACI 318-11 §8.5.1. The `AggregateType` enum controls fire resistance calculations (ACI 216.1-14).

## Key Types

```@docs
AbstractMaterial
Concrete
ReinforcedConcreteMaterial
AggregateType
```

### Concrete Fields

| Field | Type | Description |
|:------|:-----|:------------|
| `E` | Pressure | Young's modulus |
| `fc′` | Pressure | 28-day compressive strength |
| `ρ` | Density | Mass density |
| `ν` | `Float64` | Poisson's ratio |
| `εcu` | `Float64` | Ultimate compressive strain (default 0.003 per ACI 318) |
| `ecc` | `Float64` | Embodied carbon [kgCO₂e/kg] |
| `cost` | `Float64` | Unit cost [\$/kg] (`NaN` if not set) |
| `λ` | `Float64` | Lightweight factor (1.0 NWC, 0.75–0.85 LWC per ACI 318-11 §8.6.1) |
| `aggregate_type` | `AggregateType` | Aggregate classification for fire resistance |
| `color` | `Union{Nothing, String}` | Optional display color hex string (e.g., `"#C8C8C8"`) |

### ReinforcedConcreteMaterial Fields

| Field | Type | Description |
|:------|:-----|:------------|
| `concrete` | `Concrete` | Base concrete material |
| `rebar` | `RebarSteel` | Longitudinal reinforcement |
| `transverse` | `RebarSteel` | Transverse reinforcement (defaults to same as `rebar`) |

## Standard Concrete Presets

| Preset | fc′ | Ec | ρ | ecc | Notes |
|:-------|:----|:---|:--|:----|:------|
| `NWC_3000` | 3000 psi | ACI §8.5.1 | 2380 kg/m³ | 0.130 | Low strength |
| `NWC_4000` | 4000 psi | ACI §8.5.1 | 2380 kg/m³ | 0.138 | Standard |
| `NWC_5000` | 5000 psi | ACI §8.5.1 | 2385 kg/m³ | 0.155 | Higher strength |
| `NWC_6000` | 6000 psi | ACI §8.5.1 | 2385 kg/m³ | 0.173 | High strength |

```@docs
NWC_3000
NWC_4000
NWC_5000
NWC_6000
NWC_GGBS
NWC_PFA
```

### Low-Carbon Alternatives

| Preset | fc′ | ecc | Notes |
|:-------|:----|:----|:------|
| `NWC_GGBS` | 4000 psi | 0.099 | 50% GGBS cement replacement |
| `NWC_PFA` | 4000 psi | 0.112 | 30% PFA (fly ash) replacement |

## Reinforced Concrete Presets

| Preset | Concrete | Rebar | Use Case |
|:-------|:---------|:------|:---------|
| `RC_3000_60` | NWC_3000 | Rebar_60 | Footings, slabs-on-grade |
| `RC_4000_60` | NWC_4000 | Rebar_60 | Standard RC frames |
| `RC_5000_60` | NWC_5000 | Rebar_60 | Mid-rise columns |
| `RC_6000_60` | NWC_6000 | Rebar_60 | High-rise columns |
| `RC_5000_75` | NWC_5000 | Rebar_75 | High-strength RC |
| `RC_6000_75` | NWC_6000 | Rebar_75 | High-strength RC |
| `RC_GGBS_60` | NWC_GGBS | Rebar_60 | Low-carbon RC |

```@docs
RC_3000_60
RC_4000_60
RC_5000_60
RC_6000_60
RC_5000_75
RC_6000_75
RC_GGBS_60
```

## Earthen Material Presets

For unreinforced vault and masonry analysis. Properties derived from BasePlotsWithLim.m reference data.

| Preset | E | fc′ | ρ | ecc | Notes |
|:-------|:--|:----|:--|:----|:------|
| `Earthen_500` | 500 MPa | 0.5 MPa | 2000 kg/m³ | 0.01 | Unfired earth |
| `Earthen_1000` | 1 GPa | 1.0 MPa | 2000 kg/m³ | 0.01 | Rammed earth |
| `Earthen_2000` | 2 GPa | 2.0 MPa | 2000 kg/m³ | 0.02 | Stabilized earth |
| `Earthen_4000` | 4 GPa | 4.0 MPa | 2000 kg/m³ | 0.05 | Compressed earth blocks |
| `Earthen_8000` | 8 GPa | 8.0 MPa | 2000 kg/m³ | 0.10 | Fired clay brick |

```@docs
Earthen_500
Earthen_1000
Earthen_2000
Earthen_4000
Earthen_8000
```

Earthen materials use `εcu = 0.002` (lower than the ACI 318 default of 0.003).

## Functions

```@docs
concrete_fc
concrete_fc_mpa
concrete_E
concrete_wc
```

`material_name` is documented on the [Steel](steel.md) materials page.

## Implementation Details

- **Elastic modulus**: Standard concrete presets compute `Ec` via the simplified ACI relationship `Ec(fc) = 57,000 √f'c` (psi units) for normal-weight concrete. When unit weight matters (e.g., lightweight concrete), use the general form `Ec(fc, wc_pcf) = 33 wc^{1.5} √f'c` (with `wc_pcf` in pcf) via the exported overload `Ec(fc, wc_pcf)`.
- **Aggregate type**: Defaults to `siliceous`. Fire resistance functions (`min_thickness_fire`, `min_cover_fire_slab`, etc.) dispatch on `AggregateType` — carbonate aggregates provide better fire resistance than siliceous.
- **Name registry**: Like steel, concrete presets are registered via `register_material!` for display. Unregistered instances fall back to `"Concrete (XXXX psi)"` formatting.
- **Embodied carbon**: ECC values from ICE Database v4.1 (Oct 2025). Values range from 0.01 kgCO₂e/kg for unfired earth to 0.173 kgCO₂e/kg for 6000 psi OPC concrete. GGBS and PFA replacements reduce ECC by ~28% and ~19% respectively.
- **Unit weight helpers**: `concrete_wc` converts mass density to weight density (lbf/ft³) by multiplying by gravitational acceleration.

## Limitations & Future Work

- **Lightweight concrete**: Only the `λ` factor and `AggregateType` enum support lightweight concrete. Full LWC presets with adjusted Ec formulas are not yet provided.
- **High-strength concrete**: Presets go up to 6000 psi. For higher strengths (8000–12000 psi), create instances manually and consider reducing `εcu` below 0.003.
- **Creep and shrinkage**: Not modeled. Long-term deflection calculations use ACI 318 multipliers externally.
