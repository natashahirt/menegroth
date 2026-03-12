# Embodied Carbon

> ```julia
> ec = compute_building_ec(struc)
> ec.total_kgCO2e        # total building embodied carbon
> ec.by_element_type      # breakdown by element type
> summary = ec_summary(design; du = imperial)
> ```

## Overview

The embodied carbon (EC) module computes the total greenhouse gas emissions (kgCO₂e) associated with the structural materials in a building design. It operates on `MaterialVolumes` attached to each structural element — slabs, beams, columns, and foundations — and applies emission coefficients (ECC) from material presets sourced from the ICE Database v4.1.

**Source:** `StructuralSynthesizer/src/postprocess/ec.jl`

## Key Types

```@docs
MaterialVolumes
VolumeType
ElementECResult
BuildingECResult
```

## Functions

```@docs
element_ec
compute_building_ec
ec_summary
```

## Implementation Details

### element_ec

`element_ec(volumes::MaterialVolumes)` computes the embodied carbon for a single element from its material volumes:

| Material | Input | ECC Unit | Source |
|:---------|:------|:---------|:-------|
| Concrete | `concrete_m3` | kgCO₂e / m³ | Material preset (varies by fc′) |
| Steel | `steel_kg` | kgCO₂e / kg | Material preset (structural steel) |
| Rebar | `rebar_kg` | kgCO₂e / kg | Material preset (reinforcing steel) |
| Timber | `timber_m3` | kgCO₂e / m³ | Material preset (glulam, CLT, etc.) |

Returns a `Float64` in kgCO₂e.

### compute_building_ec

`compute_building_ec(struc::BuildingStructure)` aggregates EC across all elements:

1. **Slabs** — EC from concrete, rebar, and steel deck in each slab's `volumes`
2. **Members** — EC from steel sections (beams, columns, struts) via `compute_element_ec_member`
3. **Foundations** — EC from foundation concrete and rebar
4. **Fireproofing** — EC from SFRM or intumescent coating via `_compute_fireproofing_ec`

Returns a `BuildingECResult` with the total and per-element-type breakdown.

### ElementECResult

Stores the EC result for a single element:
- Element type (`:slab`, `:beam`, `:column`, `:foundation`, `:fireproofing`)
- Element index
- EC value in kgCO₂e
- Material breakdown

### BuildingECResult

Aggregates all element results:
- `total_kgCO2e` — grand total
- `by_element_type` — dictionary mapping element type to subtotal
- `elements` — vector of individual `ElementECResult`s

### Fireproofing EC

`_compute_fireproofing_ec(struc)` accounts for the embodied carbon of fire protection materials:
- SFRM (sprayed fire-resistive material): per UL X772 thickness tables
- Intumescent coating: per UL N643 thickness tables
- Material density × coverage area × ECC

### ec_summary

`ec_summary(design; du)` produces a formatted summary string:
- Total building EC
- EC per unit floor area (kgCO₂e/m² or kgCO₂e/ft²)
- Breakdown by element type (slabs, beams, columns, foundations, fireproofing)
- Percentage of total for each element type

## Options & Configuration

EC coefficients are embedded in the material presets. To customize:
- Define custom materials with specific ECC values
- Pass custom materials via `MaterialOptions` in `DesignParameters`

The optimization objective `MinCarbon` uses these same ECC values during section selection to minimize total embodied carbon rather than weight.

## Limitations & Future Work

- ECC values are static; lifecycle analysis (cradle-to-grave) is not included.
- Transportation and construction process emissions are not modeled.
- Only structural materials are counted; MEP, cladding, and interior finishes are excluded.
- Regional ECC variation (e.g., recycled steel fraction) is not yet supported.
