# Asap FEM Integration

> ```julia
> to_asap!(struc; params = design_params)
> struc.asap_model  # Asap.Model — solved frame model
> sync_asap!(struc; params = design_params)  # re-solve after section changes
> build_analysis_model!(design; load_combination = :service)
> ```

## Overview

The Asap integration module bridges the `BuildingStructure` with the [Asap](https://github.com/natashahirt/Asap.jl) finite element package (local fork at `external/Asap`). It creates frame models from the structure's members and supports, applies gravity loads, solves for forces and displacements, and provides utilities for re-solving after section changes and building visualization models.

**Source:** `StructuralSynthesizer/src/analyze/asap/*.jl`

## Functions

```@docs
to_asap!
sync_asap!
build_analysis_model!
create_slab_diaphragm_shells
add_coating_loads!
```

## Implementation Details

### to_asap!

`to_asap!(struc; params, diaphragms, shell_props)` builds a complete Asap frame model:

1. **Create nodes** — one Asap node per skeleton vertex, with support conditions at ground-level vertices
2. **Create frame elements** — one Asap frame element per beam/column/strut segment:
   - Section properties (A, Ix, Iy, J) from member section assignments
   - Material properties (E, G, ρ) from member materials or `params.default_frame_*`
   - Stiffness reduction factors: `params.column_I_factor` (default 0.70 per ACI 318-11 §10.10.4.1) and `params.beam_I_factor` (default 0.35)
3. **Apply loads** — gravity loads from cells converted to distributed loads on beam elements:
   - Self-weight of members
   - Tributary-width distributed dead and live loads on beams
   - Coating/fireproofing loads if applicable (`add_coating_loads!`)
4. **Solve** — calls `Asap.solve!` for the assembled model
5. Stores the model in `struc.asap_model`

### sync_asap!

`sync_asap!(struc; params)` updates the existing Asap model after section changes without rebuilding from scratch:

1. Updates section properties for all elements whose sections have changed
2. Updates slab self-weights (which may change if slab thickness changed)
3. Recalculates tributary loads
4. Re-solves the model

This is more efficient than `to_asap!` for iterative design because the topology is unchanged.

### Pattern Loading

When `params.pattern_loading == true`, the analysis applies pattern loading per ACI 318-11 §13.7.6:
- Factored dead load on all spans
- Factored live load on alternate spans to maximize positive and negative moments
- The pattern loading threshold is L/D > 0.5 per ACI 318-11 §13.7.6.2

### build_analysis_model!

`build_analysis_model!(design; load_combination, mesh_density, frame_groups, ...)` creates a combined frame + shell model for visualization:

- Frame elements with actual section dimensions
- Shell elements for sized slabs with correct thickness
- Solves under the specified load combination (`:service`, `:ultimate`, or custom)
- Used for deflection visualization and draping

### Draping

`compute_draped_displacements(design)` interpolates total and local bending displacements across slab surfaces for deflected shape visualization. It separates global column shortening from local slab bending to show realistic deflected shapes.

### Diaphragm Modeling

`create_slab_diaphragm_shells(struc, slab, nodes; E, ν, t_factor)` creates shell elements representing the in-plane stiffness of the slab diaphragm. These are used for lateral load distribution when `params.diaphragm_mode` is enabled.

## Options & Configuration

| Parameter | Description | Default |
|:----------|:------------|:--------|
| `column_I_factor` | Stiffness reduction for columns (ACI 318-11 §10.10.4.1) | 0.70 |
| `beam_I_factor` | Stiffness reduction for beams | 0.35 |
| `diaphragm_mode` | Diaphragm modeling approach | `:none` |
| `diaphragm_E` | Diaphragm elastic modulus | Concrete E |
| `diaphragm_ν` | Diaphragm Poisson's ratio | 0.2 |
| `pattern_loading` | Enable pattern loading | `false` |

## Limitations & Future Work

- Only frame elements are used for the primary analysis model; shell elements are added only for visualization and diaphragm stiffness.
- Dynamic analysis (modal, response spectrum) is not yet supported.
- Asap model updates via `sync_asap!` do not update topology; adding/removing members requires a full `to_asap!` rebuild.
