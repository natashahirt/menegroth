# Embodied Carbon

> ```julia
> ec = compute_building_ec(struc)
> ec.total_ec             # total building embodied carbon [kgCO₂e]
> ec.ec_per_floor_area     # intensity [kgCO₂e/m²]
>
> # Pretty-printed summary (returns the same BuildingECResult)
> ec_summary(struc; du = imperial)
> ```

## Overview

The embodied carbon (EC) module computes the total greenhouse gas emissions (kgCO₂e) associated with the structural materials in a building design. It operates on `MaterialVolumes` attached to each structural element — slabs, beams, columns, and foundations — and applies emission coefficients (`ecc`) embedded in the StructuralSizer material presets.

At the calculation boundary, every material is treated consistently as:

```math
\mathrm{EC} = \sum_i \left(V_i \, \rho_i \, \mathrm{ecc}_i\right)
```

where \(V\) is volume (m³), \(\rho\) is density (kg/m³), and `ecc` is kgCO₂e/kg.

Concrete preset ECC values are anchored to the empirical median of the dataset described canonically by [`ECC_PROVENANCE_NOTE`](@ref) (single source of truth — refresh that constant when the dataset is updated, and every docstring / docs page that interpolates it follows along). For inclusion criteria, per-bucket counts, and composition tagging see `StructuralSizer/src/materials/ecc/data/README.md`.

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
to_dict
```

## Implementation Details

### element_ec

`element_ec(volumes::MaterialVolumes)` computes the embodied carbon for a single element from its material volumes:

| Term | Meaning | Units |
|:-----|:--------|:------|
| `vol` | Material volume stored in `MaterialVolumes` | m³ |
| `mat.ρ` | Material density | kg/m³ |
| `mat.ecc` | Material embodied carbon coefficient | kgCO₂e/kg |

Returns a `Float64` in kgCO₂e.

### compute_building_ec

`compute_building_ec(struc::BuildingStructure)` aggregates EC across all elements:

1. **Slabs** — EC from concrete, rebar, and steel deck in each slab's `volumes`
2. **Members** — EC from steel sections (beams, columns, struts) via `compute_element_ec_member`
3. **Foundations** — EC from foundation concrete and rebar
4. **Fireproofing** — EC from SFRM or intumescent coating (only when design parameters are provided)

Returns a `BuildingECResult` with the total and per-element-type breakdown.

### ElementECResult

Stores the EC result for a single element:
- Element type (`:slab`, `:beam`, `:column`, `:strut`, `:foundation`)
- Element index (within that element vector)
- EC value in kgCO₂e
- Total material volume (m³) and mass (kg) for that element (summing across materials)

### BuildingECResult

Aggregates all element results:
- `slabs`, `members`, `foundations` — vectors of `ElementECResult`
- `slab_ec`, `member_ec`, `foundation_ec`, `fireproofing_ec`, `total_ec` — subtotals and grand total [kgCO₂e]
- `floor_area` — total floor area [m²]
- `ec_per_floor_area` — intensity [kgCO₂e/m²]

### Fireproofing EC

Fireproofing EC is included when `compute_building_ec(struc, params)` is called (internally used by `ec_summary(design)`):
- SFRM (sprayed fire-resistive material): per UL X772 thickness tables
- Intumescent coating: per UL N643 thickness tables
- Material density × coverage area × ECC

### ec_summary

`ec_summary(design)` (or `ec_summary(struc; du=..., params=...)`) prints a formatted summary and returns the computed `BuildingECResult`:
- Total building EC
- EC per unit floor area (kgCO₂e/m² or kgCO₂e/ft²)
- Breakdown by element type (slabs, beams, columns, foundations, fireproofing)
- Percentage of total for each element type

### to_dict

`to_dict(::BuildingECResult; du=imperial)` and `to_dict(::ElementECResult)` produce JSON-friendly `Dict{String, Any}` views with all Unitful quantities stripped to numeric scalars. Use these when serializing EC results for an HTTP payload, CSV export, or history snapshot — the raw `BuildingECResult` struct carries `Unitful` floor-area / mass quantities that JSON3 cannot encode directly.

Field naming: EC values are always reported as `*_kgco2e` (unit baked into the key), so downstream consumers do not need to track an implicit unit convention. Floor area is converted to the requested display unit (`du.units[:area]`) and tagged with an explicit `floor_area_unit` string; the canonical kgCO₂e/m² intensity is also retained alongside the display-unit intensity.

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
