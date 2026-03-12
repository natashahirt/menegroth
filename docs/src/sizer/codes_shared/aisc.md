# AISC Shared Utilities

> ```julia
> using StructuralSizer
> t_sfrm = sfrm_thickness_x772(2, 1.5)         # 2-hr rating, W/D=1.5
> t_intum = intumescent_thickness_n643(1, 2.0)  # 1-hr rating, W/D=2.0
> coating = compute_surface_coating(fp, fire_rating, W_plf, perimeter_in)
> ```

## Overview

The shared AISC module provides fire protection utilities used across all steel
section types (W-shapes, HSS, angles, etc.).  Fire protection thickness is
computed from UL-listed assemblies and AISC Design Guide 19, and applied as a
`SurfaceCoating` to steel members.

**Source:** `StructuralSizer/src/codes/aisc/fire.jl`

## Key Types

No public types are defined here.  The `SurfaceCoating` type and
`FireProtection` type are defined in the materials module.

## Functions

The fire protection functions (`sfrm_thickness_x772`, `intumescent_thickness_n643`, `compute_surface_coating`) are documented on the [Fire Protection](../materials/fire_protection.md) materials page.

## Implementation Details

### SFRM Thickness (UL Design No. X772)

Spray-applied fire-resistive material (SFRM) thickness is computed from UL
Design No. X772 for contour-sprayed steel members.  The thickness depends on
the fire rating (hours) and the section's weight-to-heated-perimeter ratio
``W/D`` (lb/ft / in.).

Higher ``W/D`` ratios (heavier sections relative to exposed surface) require
less SFRM for the same fire rating.

### Intumescent Coating (UL Design No. N643)

Intumescent paint thickness is interpolated from UL Design No. N643 tables.
The tables provide thickness (mils) as a function of ``W/D`` for 1-hour and
2-hour ratings, with separate tables for restrained and unrestrained
assemblies.

Interpolation uses piecewise-linear interpolation (`_interp_table`) between
tabulated ``W/D`` breakpoints.

### Surface Coating Assembly

`compute_surface_coating(fp, fire_rating, W_plf, perimeter_in)` dispatches on
the `FireProtection` type to compute the appropriate coating:

1. Compute ``W/D = W_{\text{plf}} / \text{perimeter}``
2. Look up or interpolate the required thickness
3. Return a `SurfaceCoating` with thickness, density, and cost data

## Options & Configuration

Fire protection type is set at the member level via `FireProtection`:

| Type | Description | Reference |
|:-----|:------------|:----------|
| `SFRM()` | Spray-applied fire-resistive material | UL X772 |
| `IntumescentCoating()` | Intumescent paint | UL N643 |
| `NoFireProtection()` | No fire protection | — |

The fire rating (hours: 0, 1, 2, 3, 4) and assembly restraint condition
(restrained/unrestrained) are specified per AISC Design Guide 19.

## Limitations & Future Work

- Only UL X772 (SFRM) and UL N643 (intumescent) assemblies are implemented.
  Additional UL designs (e.g., membrane protection, concrete encasement) are
  planned.
- Box-column and built-up section ``W/D`` calculations are not automated.
- Cost data for fire protection materials is approximate and should be
  calibrated to project-specific pricing.
- Tabulated values are for specific products; manufacturer variations may
  require custom tables.
