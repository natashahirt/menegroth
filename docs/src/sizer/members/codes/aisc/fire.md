# AISC Fire Protection

> ```julia
> using StructuralSizer
> fp = SFRM()
> coating = compute_surface_coating(fp, 2.0, 22.0, 45.3)
> println("SFRM thickness = $(coating.thickness_in) in")
> ```

## Overview

This module computes fire protection coating thicknesses for steel members. It supports spray-applied fire-resistive material (SFRM) using the UL X772 equation, intumescent coatings using the UL N643 table, and custom user-defined coatings. Fire ratings from 1 to 4 hours are supported.

The fire protection calculation uses the W/D ratio (section weight per unit length divided by the heated perimeter), a standard parameter in AISC Design Guide 19 and UL fire rating assemblies.

Source: `StructuralSizer/src/materials/fire_protection.jl` (types), `StructuralSizer/src/codes/aisc/fire.jl` (calculations)

## Key Types

All fire protection types (`FireProtection`, `NoFireProtection`, `SFRM`, `IntumescentCoating`, `CustomCoating`, `SurfaceCoating`) are documented on the [Fire Protection](../../../materials/fire_protection.md) materials page.

| Type | Description |
|:-----|:------------|
| `FireProtection` | Abstract base type for fire protection strategies |
| `NoFireProtection` | No coating applied |
| `SFRM` | Spray-applied fire-resistive material (default density 15.0 pcf) |
| `IntumescentCoating` | Intumescent (reactive) coating (default density 6.0 pcf) |
| `CustomCoating` | User-defined coating with explicit thickness, density, and name |
| `SurfaceCoating` | Output type from `compute_surface_coating` carrying resolved thickness, density, and name |

## Functions

### Coating Thickness Calculations

The coating calculation functions (`sfrm_thickness_x772`, `intumescent_thickness_n643`, `compute_surface_coating`) are documented on the [Fire Protection](../../../materials/fire_protection.md) materials page.

`sfrm_thickness_x772(fire_rating, W_D)` — SFRM thickness per UL X772 assembly:

`h = R / (1.05 × W/D + 0.61)`

where `R` is the fire rating in hours and `W/D` is in lb/ft per inch. The result is clamped to a minimum of 0.25 inches per UL listing requirements.

`intumescent_thickness_n643(fire_rating, W_D; restrained=false)` — intumescent coating thickness per UL N643 assembly (Carboline Thermo-Sorb E). Uses piecewise-linear interpolation of the published W/D vs. thickness table for each fire rating. The `restrained` flag selects between restrained and unrestrained assembly tables.

### Dispatch Function

`compute_surface_coating(fp, fire_rating, W_plf, perimeter_in)` — computes the required coating for a given fire protection type. Dispatches on `fp`:

| `fp` Type | Behavior |
|:----------|:---------|
| `NoFireProtection` | Returns zero thickness |
| `SFRM` | Calls `sfrm_thickness_x772` |
| `IntumescentCoating` | Calls `intumescent_thickness_n643` |
| `CustomCoating` | Returns the user-specified thickness directly |

Arguments:
- `fire_rating` — fire rating in hours (1, 1.5, 2, 3, or 4)
- `W_plf` — section weight per unit length in lb/ft
- `perimeter_in` — heated (exposed) perimeter in inches

### Exposed Perimeter

`exposed_perimeter` is documented on the [Fire Protection](../../../materials/fire_protection.md) materials page.

`exposed_perimeter(s::ISymmSection; exposure=:three_sided)` — returns the heated perimeter:
- `:three_sided` → `PA` (beams with top flange protected by slab)
- `:four_sided` → `PB` (columns, fully exposed)

These values are stored on `ISymmSection` from the AISC database and correspond to the contour perimeters in AISC Design Guide 19.

## Implementation Details

### W/D Ratio

The W/D ratio is the key parameter for fire protection thickness. `W` is the weight per unit length (lb/ft) and `D` is the heated perimeter (inches). A higher W/D means more thermal mass per unit surface area, requiring less coating for the same fire rating.

For beams, the 3-sided perimeter (`PA`) is used because the top flange is shielded by the concrete slab. For columns, the 4-sided perimeter (`PB`) is used.

### UL X772 (SFRM)

The X772 equation is a single closed-form expression relating fire rating, W/D, and SFRM thickness. It was derived from fire test data and is applicable to cementitious and fiber SFRM products. The minimum thickness of 0.25 inches ensures adequate coverage over the full member surface.

### UL N643 (Intumescent)

The N643 assembly uses tabulated data rather than a closed-form equation because intumescent coatings have a nonlinear relationship between thickness and W/D. The implementation stores the tables and uses linear interpolation between tabulated W/D values. Extrapolation beyond the table range uses the nearest endpoint value.

## Options & Configuration

Fire protection type is selected by constructing the appropriate `FireProtection` subtype:

```julia
fp = SFRM(density_pcf=15.0)           # standard density SFRM
fp = IntumescentCoating()               # default density intumescent
fp = CustomCoating(0.5, 12.0, "Custom") # 0.5" at 12 pcf
fp = NoFireProtection()                 # no coating
```

Fire ratings: `1.0`, `1.5`, `2.0`, `3.0`, `4.0` hours are supported. The choice of restrained vs. unrestrained assembly (for intumescent) affects the required thickness.

## Limitations & Future Work

- `exposed_perimeter` is only implemented for `ISymmSection`. HSS sections would need their own perimeter calculations.
- Only UL X772 (SFRM) and UL N643 (intumescent) assemblies are implemented. Other UL designs (D902, etc.) are not included.
- Board-type fire protection (e.g. gypsum enclosures) is not modeled.
- Cost estimation for fire protection is not included.
