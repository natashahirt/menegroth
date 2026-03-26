# Input Validation

> ```julia
> using StructuralSynthesizer, JSON3
>
> input_json = """
> {
>   "units": "ft",
>   "vertices": [
>     [0.0, 0.0, 0.0], [10.0, 0.0, 0.0], [10.0, 10.0, 0.0], [0.0, 10.0, 0.0],
>     [0.0, 0.0, 10.0], [10.0, 0.0, 10.0], [10.0, 10.0, 10.0], [0.0, 10.0, 10.0]
>   ],
>   "edges": {
>     "beams": [[1,2],[2,3],[3,4],[4,1],[5,6],[6,7],[7,8],[8,5]],
>     "columns": [[1,5],[2,6],[3,7],[4,8]],
>     "braces": []
>   },
>   "supports": [1,2,3,4]
> }
> """
>
> api_input = JSON3.read(input_json, APIInput)
> result = validate_input(api_input)
> result.ok      # true if valid
> result.errors  # Vector{ValidationError} of structured error records
> ```

## Overview

Input validation checks the `APIInput` for basic structural and logical consistency before running the design pipeline (units present, indices in range, etc.). It returns a `ValidationResult` containing `.ok::Bool` and `.errors::Vector{ValidationError}` (structured errors with `field`, `value`, `constraint`, `allowed`, `message`).

**Source:** `StructuralSynthesizer/src/api/validation.jl`

## Functions

```@docs
validate_input
```

## Implementation Details

### Validation Checks

`validate_input(input::APIInput)` performs the following checks and returns a `ValidationResult` with `.ok::Bool` and `.errors::Vector{ValidationError}`:

| Check | Field path(s) | Constraint | Notes |
|:------|:-------------|:-----------|:------|
| Units | `units` | `required` / `general` | Missing units pushes a `required` error. If present but invalid, `parse_unit` failure is captured as a `general` error. |
| Vertices | `vertices`, `vertices[i]` | `range` / `general` | Requires at least 4 vertices; each vertex must have exactly 3 coordinates. |
| Edges | `edges`, `edges[i]`, `edges[i].v1`, `edges[i].v2` | `required` / `general` / `range` | Requires at least one edge across beams/columns/braces; each edge must be length-2, non-degenerate, and within `1:n_vertices`. |
| Supports | `supports`, `supports[i]` | `required` / `range` | Requires at least one support; each support index must be within `1:n_vertices`. |
| Stories Z | `stories_z` | `range` | Only checked when non-empty; if provided, requires at least 2 elevations. |
| Faces | `faces.<category>[j]`, `faces.<category>[j].vertex[k]` | `range` / `general` | Only checked for categories present in the JSON. Each polyline must have ≥ 3 vertices; each vertex must have exactly 3 coordinates. |
| Floor type | `floor_type` | `enum` | Must be one of `flat_plate`, `flat_slab`, `one_way`, `vault`. |
| Floor compatibility | `column_type`, `beam_type` | `compatibility` | Beamless slabs require RC columns; vaults require RC beams/columns (steel rejected). |
| Floor options | `floor_options.method`, `floor_options.deflection_limit`, `floor_options.punching_strategy` | `enum` | `method` is uppercased for comparison; punching strategy is lowercased. |
| Numeric bounds | `floor_options.vault_lambda`, `floor_options.target_edge_m`, `visualization_target_edge_m`, `max_iterations` | `range` | When present, each must be \(>0\) (or ≥1 for `max_iterations`). |
| Scoped overrides | `scoped_overrides[...]` | `enum` / `required` / `range` / `general` | Validates override floor type + floor options; requires non-empty `faces`; validates each polygon shape and optional `concrete` override. |
| Member type enums | `column_type`, `beam_type` | `enum` | Must be one of the supported API type strings. |
| Column catalog | `column_catalog` | `enum` | Only validated when non-null; allowed catalogs depend on `column_type`. |
| Sizing strategies | `column_sizing_strategy`, `beam_sizing_strategy` | `enum` | Compared case-insensitively against `discrete` / `nlp`. |
| Beam catalog bounds | `beam_catalog_bounds.*` | `required` / `range` | Only when `beam_catalog == "custom"`; checks min/max ordering and positive resolution. |
| PixelFrame options | `pixelframe_options.*` | `enum` / `required` / `range` | Only validated when `column_type` or `beam_type` is `"pixelframe"`. |
| Fire rating | `fire_rating` | `enum` | Must be one of `0`, `1`, `1.5`, `2`, `3`, `4`. |
| Optimization target | `optimize_for` | `enum` | Must be one of `weight`, `carbon`, `cost`. |
| Material/soil lookups | `materials.*`, `foundation_*` | `enum` | Uses resolver maps; on failure provides `allowed` options list. |
| Foundations | `foundation_*`, `foundation_options.*` | `enum` / `range` | Only validated when `size_foundations=true`. |
| Unit system | `unit_system` | `enum` | Must be `imperial` or `metric` (case-insensitive). |

### Validation Response

The validation result is used in two places:

1. **`POST /validate`** — returns `{"status":"ok","message":"Input is valid."}` on success, or a 400 validation error payload on failure.
2. **`POST /design`** — validates first; if invalid, returns a 400 JSON response with `{"status":"error","error":"ValidationError","message":"...","errors":[...]}` without running the pipeline.

On validation failure, the API routes serialize `ValidationError` objects into `errors = [{field, value, constraint, allowed, message}, ...]`.

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
