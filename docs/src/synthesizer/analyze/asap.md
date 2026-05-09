# Asap FEM Integration

> ```julia
> using StructuralSynthesizer
> using Unitful
>
> skel = gen_medium_office(30u"m", 20u"m", 3u"m", 3, 2, 2)
> struc = BuildingStructure(skel)
> params = DesignParameters()
>
> to_asap!(struc; params = params)
> struc.asap_model  # Asap.Model — solved frame model (placeholder sections until sizing)
>
> # Re-solve after section/loads change (topology unchanged)
> sync_asap!(struc; params = params)
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
   - Initial section properties use a **placeholder** `Asap.Section` (topology-first). Sizing/reconciliation stages later overwrite element sections with sized properties.
   - Material properties (E, G, ρ) use `params.default_frame_*` before member sizing assigns section-specific properties.
3. **Apply loads** — gravity loads from cells converted to `Asap.TributaryLoad`s on frame elements:
   - Tributary-width distributed dead/live pressures factored by the governing `LoadCombination`
   - Structural effects that are expressed as line loads (e.g., vault lateral thrust) when present in slab results
4. **Solve** — calls `Asap.solve!` for the assembled model
5. Stores the model in `struc.asap_model`

Notes:

- `to_asap!` returns a **frame-only** `Asap.Model`. Shell elements created for diaphragm modeling are not currently coupled into `struc.asap_model` (use `build_analysis_model!` for the frame+shell visualization/deflection model).
- Fire protection self-weight is added by calling `add_coating_loads!(struc, params; ...)` **after** member sizing assigns sections, then re-solving (typically via `sync_asap!`).

### sync_asap!

`sync_asap!(struc; params)` updates the existing Asap model after section changes without rebuilding from scratch:

1. Assumes element sections have already been updated by sizing routines
2. Updates slab self-weights (which may change if slab thickness changed)
3. Recalculates tributary loads / pressures
4. Calls `Asap.update!` / `Asap.process!`, then re-solves the model

This is more efficient than `to_asap!` for iterative design because the topology is unchanged.

### Pattern Loading

When `params.pattern_loading` is not `:none`, the analysis applies pattern loading per ACI 318-11 §13.7.6:
- Factored dead load on all spans
- Factored live load is partitioned into two **checkerboard** patterns across non-grade cells (plus the full-live-load case) to envelope member forces.
- In `:auto` mode, pattern loading runs only when any non-grade cell satisfies \(L/D > 0.75\) (ACI 318-11 §13.7.6.2). Use `:checkerboard` to force pattern loading regardless of \(L/D\).

### build_analysis_model!

`build_analysis_model!(design; load_combination, mesh_density, frame_groups, ...)` creates a combined frame + shell model for visualization:

- Frame elements with actual section dimensions
- Shell elements for sized slabs with correct thickness
- Solves under the specified `LoadCombination` (for example `service` or `strength_1_2D_1_6L`)
- Used for deflection visualization and draping

If `build_analysis_model!` fails, `design_building` logs a warning and the design still completes;
visualization consumers should fall back to the frame-only model.

### Draping

`StructuralSynthesizer.compute_draped_displacements(design)` (internal, unexported) interpolates total and local bending displacements across slab surfaces for deflected shape visualization. It separates global column shortening from local slab bending to show realistic deflected shapes.

### Diaphragm Modeling

`create_slab_diaphragm_shells(struc, slab, nodes; E, ν, t_factor)` creates shell elements representing the in-plane stiffness of the slab diaphragm.

At the moment:

- `to_asap!` may construct diaphragm shells for `:rigid` / `:shell` modes, but the returned `struc.asap_model` remains frame-only.
- `build_analysis_model!` is the supported path for a frame+shell model used in visualization/deflection analysis.

## Options & Configuration

| Parameter | Description | Default |
|:----------|:------------|:--------|
| `column_I_factor` | Stiffness reduction for columns (ACI 318-11 §10.10.4.1) | 0.70 |
| `beam_I_factor` | Stiffness reduction for beams | 0.35 |
| `diaphragm_mode` | Diaphragm modeling approach | `:none` |
| `diaphragm_E` | Diaphragm elastic modulus override (used when diaphragm shells are created) | `nothing` |
| `diaphragm_ν` | Diaphragm Poisson's ratio | 0.2 |
| `pattern_loading` | Pattern loading mode (`:none`, `:checkerboard`, `:auto`) | `:none` |

## Limitations & Future Work

- Only frame elements are used for the primary analysis model; shell elements are added only for visualization and diaphragm stiffness.
- Dynamic analysis (modal, response spectrum) is not yet supported.
- Asap model updates via `sync_asap!` do not update topology; adding/removing members requires a full `to_asap!` rebuild.

## References

- `StructuralSynthesizer/src/analyze/asap/utils.jl`
- `StructuralSynthesizer/src/analyze/asap/drape.jl`
