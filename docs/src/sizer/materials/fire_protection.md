# Fire Protection

> ```julia
> using StructuralSizer
> fp      = SFRM(15.0)     # 15 pcf spray-applied fireproofing
> coating = compute_surface_coating(fp, 2.0, 57.0, 48.0)  # 2-hr, W=57 plf, heated perimeter D=48 in
> coating.thickness_in      # SFRM thickness per UL X772
> ```

## Overview

Fire protection in StructuralSizer covers two domains:

1. **Steel fire protection** — spray-applied fire-resistive material (SFRM) and intumescent coatings, sized via UL listing equations
2. **Concrete fire resistance** — minimum cover, thickness, and dimension provisions per ACI 216.1-14

Steel fire protection is modeled as an input type (what the user specifies) and an output type (the computed coating applied to the member). Concrete fire resistance is handled through helper functions that return minimum dimensions — no physical coating is applied.

## Key Types

```@docs
FireProtection
NoFireProtection
SFRM
IntumescentCoating
CustomCoating
SurfaceCoating
```

### Input Types (User-Facing)

| Type | Description | Default Density |
|:-----|:------------|:----------------|
| `NoFireProtection()` | No coating applied | — |
| `SFRM(density_pcf)` | Spray-applied fire-resistive material | 15.0 pcf |
| `IntumescentCoating(density_pcf)` | Thin-film intumescent (mastic) | 6.0 pcf |
| `CustomCoating(thickness_in, density_pcf, name)` | User-specified, bypasses calculation | — |

### Output Type

`SurfaceCoating` stores the resolved coating after applying the UL listing equation:

| Field | Type | Description |
|:------|:-----|:------------|
| `thickness_in` | `Float64` | Coating thickness (inches) |
| `density_pcf` | `Float64` | Dry density (pcf) |
| `name` | `String` | Description (e.g., `"SFRM (15 pcf)"`) |

## Steel Fire Protection Functions

```@docs
sfrm_thickness_x772
intumescent_thickness_n643
compute_surface_coating
```

### compute\_surface\_coating Dispatch

`compute_surface_coating(fp, fire_rating, W_plf, perimeter_in)` dispatches on the `FireProtection` subtype:

| Input Type | Behavior |
|:-----------|:---------|
| `NoFireProtection` | Returns zero-thickness coating |
| `SFRM` | Computes thickness via `sfrm_thickness_x772` using W/D ratio |
| `IntumescentCoating` | Looks up thickness via `intumescent_thickness_n643` table |
| `CustomCoating` | Returns user-specified thickness directly |

## Concrete Fire Resistance Functions (ACI 216.1-14)

```@docs
min_thickness_fire
min_cover_fire_slab
min_cover_fire_beam
min_cover_fire_column
min_dimension_fire_column
```

### Summary Table

| Function | ACI 216.1-14 Reference | Returns |
|:---------|:-----------------------|:--------|
| `min_thickness_fire(rating, agg)` | Table 4.2 | Minimum slab thickness for fire rating |
| `min_cover_fire_slab(rating, agg; restrained)` | Table 4.3.1.1 | Minimum rebar cover for slab |
| `min_cover_fire_beam(rating, width; restrained)` | Table 4.3.1.2 | Minimum rebar cover for beam |
| `min_cover_fire_column(rating)` | §4.5.3 | Minimum rebar cover for column |
| `min_dimension_fire_column(rating, agg)` | Table 4.5.1a | Minimum column dimension |

## Embodied Carbon Functions

```@docs
exposed_perimeter
coating_volume
coating_mass
coating_ec
```

### Embodied Carbon Accounting

| Function | Returns |
|:---------|:--------|
| `exposed_perimeter(section; exposure)` | Heated perimeter of a section (m) — `PA` for 3-sided, `PB` for 4-sided |
| `coating_volume(section, coating, L; exposure)` | Volume of coating (m³) |
| `coating_mass(section, coating, L; exposure)` | Mass of coating (kg) |
| `coating_ec(section, coating, L; exposure, ecc)` | Embodied carbon (kgCO₂e) |

**Note:** `exposed_perimeter` (and therefore `coating_volume`, `coating_mass`, and `coating_ec`) is currently implemented for `ISymmSection` (W-shapes) only.

The `exposure` keyword controls which perimeter is used:
- `:three_sided` (default, beams) — top flange against deck, `PA` perimeter
- `:four_sided` (columns) — full contour, `PB` perimeter

The default ECC for SFRM is `ECC_SFRM = 0.85` kgCO₂e/kg (CLF baseline for cementitious fireproofing).

## Implementation Details

### UL X772 — SFRM for Steel Members

The SFRM thickness equation from UL Design X772:

```math
h = \frac{R}{1.05\,(W/D) + 0.61}
```

where:
- `h` = required SFRM thickness (inches)
- `R` = fire rating (hours, 1–4)
- `W` = member weight per unit length (lb/ft)
- `D` = heated perimeter (inches)

The W/D ratio captures the thermal mass of the steel section — heavier sections with less exposed surface require less insulation. This equation applies to 4-sided exposure (columns) and is conservative for 3-sided exposure (beams with deck above).

### UL N643 — Intumescent Coating for Steel Beams

Intumescent thickness is determined by table lookup from UL Design N643, interpolating on W/D ratio and fire rating. Intumescent coatings are much thinner than SFRM (~0.04"–0.25" vs. 0.5"–3"+) but more expensive per unit area.

### ACI 216.1-14 — Concrete Fire Resistance

Concrete fire resistance is governed by:
- **Slab thickness** (Table 4.2): Thicker slabs act as better thermal barriers. Carbonate aggregate provides ~15% better fire resistance than siliceous.
- **Rebar cover** (Tables 4.3.1.1, 4.3.1.2; and §4.5.3 for columns): Minimum concrete cover protects reinforcement from reaching critical temperature (~1000°F for conventional rebar).
- **Column dimensions** (Table 4.5.1a): Minimum column width ensures the core remains cool enough to carry load.

`AggregateType` affects `min_thickness_fire`, `min_cover_fire_slab` (unrestrained table), and `min_dimension_fire_column`. `min_cover_fire_beam` depends on beam width and restrained/unrestrained configuration, and `min_cover_fire_column` is independent of aggregate type.

## Options & Configuration

| Option | Description |
|:-------|:------------|
| `SFRM(15.0)` | Standard density (most common) |
| `SFRM(22.0)` | Medium density (better adhesion) |
| `SFRM(40.0)` | High density (blast/impact resistance) |
| `IntumescentCoating(6.0)` | Standard intumescent |
| `restrained` kwarg | `true` for restrained assemblies (lower cover requirements) |

## Limitations & Future Work

- **Fire ratings**: `sfrm_thickness_x772` accepts any positive `fire_rating` (hours). `intumescent_thickness_n643` is table-based and currently supports 1, 1.5, and 2 hour ratings for the unrestrained-beam table (and up to 3 hours for the restrained table). `compute_surface_coating(IntumescentCoating, ...)` currently uses the unrestrained table (`restrained=false`).
- **Concrete spalling**: ACI 216.1-14 spalling provisions (supplementary reinforcement for covers > 2.5") are not modeled.
- **Composite fire resistance**: Fire resistance of composite steel-concrete members (AISC Design Guide 19 Chapter 5) is not yet implemented.
- **Cost model**: Fire protection cost (installed \$/ft²) is not tracked. Only embodied carbon is computed.
