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
| Floor options | `params.floor_options.method`, `.deflection_limit`, `.punching_strategy` are supported strings | `"Invalid floor_options.method \"...\". Must be one of: DDM, DDM_SIMPLIFIED, EFM, EFM_HARDY_CROSS, FEA."` / `"Invalid floor_options.deflection_limit \"...\". Must be one of: L_240, L_360, L_480."` / `"Invalid floor_options.punching_strategy \"...\". Must be one of: grow_columns, reinforce_last, reinforce_first."` |
| Member types | `params.column_type` and `params.beam_type` are supported strings | `"Invalid column_type \"...\". Must be one of: rc_rect, rc_circular, steel_w, steel_hss, steel_pipe."` / `"Invalid beam_type \"...\". Must be one of: steel_w, steel_hss, rc_rect, rc_tbeam."` |
| Fire rating | `fire_rating` is one of 0, 1, 1.5, 2, 3, 4 | `"Invalid fire_rating r. Must be one of: 0, 1, 1.5, 2, 3, 4."` |
| Optimization target | `optimize_for` is `"weight"`, `"carbon"`, or `"cost"` | `"Invalid optimize_for \"...\". Must be: weight, carbon, or cost."` |
| Material names | `params.materials.concrete`, `.rebar`, `.steel` are present in the resolver maps (`NWC_3000/4000/5000/6000`, `Rebar_40/60/75/80`, `A992`) | `"Unknown concrete \"...\". Options: ..."` / `"Unknown rebar \"...\". Options: ..."` / `"Unknown steel \"...\". Options: ..."` |
| Column concrete | `params.materials.column_concrete` is present in the concrete resolver map (`NWC_3000/4000/5000/6000`) | `"Unknown column_concrete \"...\". Options: ..."` |
| Foundation soil | If `params.size_foundations=true`, `params.foundation_soil` is present in the resolver map (`loose_sand`, `medium_sand`, `dense_sand`, `soft_clay`, `stiff_clay`, `hard_clay`) | `"Unknown foundation_soil \"...\". Options: ..."` |
| Foundation concrete | If `params.size_foundations=true`, `params.foundation_concrete` is present in the concrete resolver map (`NWC_3000/4000/5000/6000`) | `"Unknown foundation_concrete \"...\". Options: ..."` |
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
