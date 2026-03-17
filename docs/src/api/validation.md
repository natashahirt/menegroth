# Input Validation

> ```julia
> result = validate_input(api_input)
> result.ok      # true if valid
> result.errors  # Vector{String} of error messages
> ```

## Overview

Input validation checks the `APIInput` for basic structural and logical consistency before running the design pipeline (units present, indices in range, etc.). It returns a `ValidationResult` containing `.ok::Bool` and `.errors::Vector{String}`.

**Source:** `StructuralSynthesizer/src/api/validation.jl`

## Functions

```@docs
validate_input
```

## Implementation Details

### Validation Checks

`validate_input(input::APIInput)` performs the following checks and returns a `ValidationResult` with `.ok::Bool` and `.errors::Vector{String}`:

| Check | Description | Error Message |
|:------|:------------|:-------------|
| Units | `input.units` is non-empty and parses via `parse_unit` | `"Missing required field \"units\". Accepted: feet/ft, inches/in, meters/m, millimeters/mm, centimeters/cm."` or `ArgumentError(...)` string from `parse_unit` |
| Vertices | At least 4 vertices required; each vertex has exactly 3 coordinates | `"Need at least 4 vertices (got N)."` and/or `"Vertex i has k coordinates (expected 3)."` |
| Edges | At least one edge (beams/columns/braces); each edge has 2 valid **1-based** vertex indices and is non-degenerate | `"No edges provided (need at least beams, columns, or braces)."` / `"Edge i has k vertex indices (expected 2)."` / `"Edge i: vertex index v out of range [1, N]."` / `"Edge i: degenerate edge (both indices = v)."` |
| Supports | At least one support; each index references a valid **1-based** vertex | `"No support vertices specified."` / `"Support i: vertex index v out of range [1, N]."` |
| Stories Z | Only validated if provided (non-empty); needs at least 2 elevations | `"If provided, need at least 2 story elevations (got N)."` |
| Faces | If provided, each face polyline has ≥ 3 vertices and each vertex has 3 coordinates | `"Face \"category\"[j] has N vertices (need ≥ 3)."` / `"Face \"category\"[j] vertex k has n coords (expected 3)."` |
| Floor type | `params.floor_type` is one of `"flat_plate"`, `"flat_slab"`, `"one_way"`, `"vault"` | `"Invalid floor_type \"...\". Must be one of: flat_plate, flat_slab, one_way, vault."` |
| Floor compatibility | Beamless slabs (`flat_plate` / `flat_slab`) require **reinforced concrete columns**; vaults disallow **steel** columns and **steel** beams | `"floor_type \"flat_plate\" requires reinforced concrete columns. column_type \"steel_w\" is not supported for beamless slab systems."` / `"floor_type \"vault\" requires reinforced concrete columns. column_type \"...\" is not supported."` / `"floor_type \"vault\" requires reinforced concrete beams. beam_type \"...\" is not supported."` |
| Floor options | `params.floor_options.method`, `.deflection_limit`, `.punching_strategy` are supported strings | `"Invalid floor_options.method \"...\". Must be one of: DDM, DDM_SIMPLIFIED, EFM, EFM_HARDY_CROSS, FEA."` / `"Invalid floor_options.deflection_limit \"...\". Must be one of: L_240, L_360, L_480."` / `"Invalid floor_options.punching_strategy \"...\". Must be one of: grow_columns, reinforce_last, reinforce_first."` |
| Vault lambda | If present, `params.floor_options.vault_lambda > 0` | `"Invalid floor_options.vault_lambda x. Must be > 0."` |
| FEA target edge | If present, `params.floor_options.target_edge_m > 0` | `"Invalid floor_options.target_edge_m x. Must be > 0."` |
| Visualization target edge | If present, `params.visualization_target_edge_m > 0` | `"Invalid visualization_target_edge_m x. Must be > 0."` |
| Scoped overrides | Each `scoped_overrides[i]` has a valid `floor_type`, non-empty `faces`, well-formed face polygons, and (if present) `vault_lambda > 0` | `"Invalid scoped_overrides[i].floor_type \"...\". Must be one of: flat_plate, flat_slab, one_way, vault."` / `"scoped_overrides[i] must include at least one face polygon."` / `"scoped_overrides[i].faces[j] has N vertices (need ≥ 3)."` / `"scoped_overrides[i].faces[j] vertex k has n coords (expected 3)."` / `"Invalid scoped_overrides[i].floor_options.vault_lambda x. Must be > 0."` |
| Member types | `params.column_type` and `params.beam_type` are supported strings | `"Invalid column_type \"...\". Must be one of: rc_rect, rc_circular, steel_w, steel_hss, steel_pipe, pixelframe."` / `"Invalid beam_type \"...\". Must be one of: steel_w, steel_hss, rc_rect, rc_tbeam, pixelframe."` |
| Column catalog | If provided, `params.column_catalog` must match the allowed catalogs for the chosen `column_type` | `"Invalid column_catalog for steel \"...\". Must be one of: compact_only, preferred, all."` / `"Invalid column_catalog for RC rectangular \"...\". Must be one of: standard, square, rectangular, low_capacity, high_capacity, all."` / `"Invalid column_catalog for RC circular \"...\". Must be one of: standard, low_capacity, high_capacity, all."` |
| Column sizing strategy | `params.column_sizing_strategy` is `"discrete"` or `"nlp"` | `"Invalid column_sizing_strategy \"...\". Must be discrete or nlp."` |
| Beam sizing strategy | `params.beam_sizing_strategy` is `"discrete"` or `"nlp"` | `"Invalid beam_sizing_strategy \"...\". Must be discrete or nlp."` |
| Beam catalog bounds | Required when `params.beam_catalog == "custom"` and must have consistent bounds | `"beam_catalog_bounds is required when beam_catalog is \"custom\"."` / `"beam_catalog_bounds: min_width_in must be < max_width_in."` / `"beam_catalog_bounds: min_depth_in must be < max_depth_in."` / `"beam_catalog_bounds: resolution_in must be > 0."` |
| PixelFrame options | If `pixelframe_options` is provided and `column_type` or `beam_type` is `"pixelframe"`, validate `pixelframe_options.fc_preset` (and custom-range fields when `custom`) | `"Invalid pixelframe_options.fc_preset \"...\". Must be one of: standard, low, high, extended, custom."` / `"pixelframe_options: fc_min_ksi, fc_max_ksi, and fc_resolution_ksi are required when fc_preset is \"custom\"."` / `"pixelframe_options: fc_min_ksi must be < fc_max_ksi."` / `"pixelframe_options: fc_resolution_ksi must be > 0."` |
| Fire rating | `fire_rating` is one of 0, 1, 1.5, 2, 3, 4 | `"Invalid fire_rating r. Must be one of: 0, 1, 1.5, 2, 3, 4."` |
| Optimization target | `optimize_for` is `"weight"`, `"carbon"`, or `"cost"` | `"Invalid optimize_for \"...\". Must be: weight, carbon, or cost."` |
| Material names | `params.materials.concrete`, `.rebar`, `.steel` are present in the resolver maps (`NWC_3000/4000/5000/6000`, `Earthen_500/1000/2000/4000/8000`, `Rebar_40/60/75/80`, `A992`) | `"Unknown concrete \"...\". Options: ..."` / `"Unknown rebar \"...\". Options: ..."` / `"Unknown steel \"...\". Options: ..."` |
| Column concrete | `params.materials.column_concrete` is present in the concrete resolver map (`NWC_3000/4000/5000/6000`, `Earthen_500/1000/2000/4000/8000`) | `"Unknown column_concrete \"...\". Options: ..."` |
| Foundation soil | If `params.size_foundations=true`, `params.foundation_soil` is present in the resolver map (`loose_sand`, `medium_sand`, `dense_sand`, `soft_clay`, `stiff_clay`, `hard_clay`) | `"Unknown foundation_soil \"...\". Options: ..."` |
| Foundation concrete | If `params.size_foundations=true`, `params.foundation_concrete` is present in the concrete resolver map (`NWC_3000/4000/5000/6000`) | `"Unknown foundation_concrete \"...\". Options: ..."` |
| Foundation options | If `params.size_foundations=true` and `params.foundation_options` is provided, validate strategy, mat threshold, and optional mat analysis method | `"foundation_options.strategy must be one of: auto, auto_strip_spread, all_spread, all_strip, mat (got \"...\")."` / `"foundation_options.mat_coverage_threshold must be between 0 and 1 (got x)."` / `"foundation_options.mat_params.analysis_method must be rigid, shukla, or winkler (got \"...\")."` |
| Unit system | `params.unit_system` is `"imperial"` or `"metric"` (case-insensitive) | `"Invalid unit_system \"...\". Must be \"imperial\" or \"metric\"."` |

### Validation Response

The validation result is used in two places:

1. **`POST /validate`** — returns `{"status":"ok","message":"Input is valid."}` on success, or a 400 validation error payload on failure.
2. **`POST /design`** — validates first; if invalid, returns a 400 JSON response with `{"status":"error","error":"ValidationError","message":"...","errors":[...]}` without running the pipeline.

### Early Return

Validation collects all errors in a single pass (it does not stop at the first failure), so clients can fix multiple issues at once.

## Options & Configuration

Validation rules are hardcoded to match the supported API schema. Adding new floor types, material presets, or optimization targets requires updating both `json_to_params` and `validate_input`.

## Limitations & Future Work

- Geometric validity (e.g., non-intersecting edges, planar faces) is not checked during validation; it is handled during skeleton construction.
- Custom materials and member/floor types are not supported without extending both `json_to_params` (mappings) and `validate_input` (accepted strings).
- Schema versioning would allow different validation rules for different API versions.

## References

- `StructuralSynthesizer/src/api/validation.jl`
