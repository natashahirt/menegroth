# Input Validation

> ```julia
> result = validate_input(api_input)
> result.ok      # true if valid
> result.errors  # Vector{String} of error messages
> ```

## Overview

Input validation checks the `APIInput` for structural and logical consistency before running the design pipeline. It catches common errors — missing vertices, dangling edge references, unsupported floor types — and returns descriptive error messages.

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
| Units | `input.units` is a recognized unit string (`"feet"`, `"inches"`, `"meters"`, `"mm"`) | Parse error from `parse_unit` |
| Vertices | At least 4 vertices required; each has exactly 3 coordinates | `"Need at least 4 vertices (got N)"` |
| Edges | At least one edge; each has 2 valid, non-degenerate vertex indices | `"Edge N: vertex index out of range"` |
| Supports | At least one support; each index references a valid vertex | `"Support N: vertex index out of range"` |
| Stories Z | If provided, at least 2 elevations required | `"If provided, need at least 2 story elevations"` |
| Faces | If provided, each face has ≥ 3 vertices with 3 coordinates each | `"Face category[j] has N vertices (need ≥ 3)"` |
| Fire rating | `fire_rating` is one of 0, 1, 1.5, 2, 3, 4 | `"Invalid fire_rating. Must be one of: 0, 1, 1.5, 2, 3, 4"` |
| Optimization target | `optimize_for` is `"weight"`, `"carbon"`, or `"cost"` | `"Invalid optimize_for. Must be: weight, carbon, or cost"` |
| Material names | `params.materials.concrete`, `.rebar`, `.steel` are recognized presets | `"Unknown concrete/rebar/steel: ..."` |

### Validation Response

The validation result is used in two places:

1. **`POST /validate`** — returns the validation result directly as JSON
2. **`POST /design`** — validates first; if invalid, returns an `APIError` without running the pipeline

### Early Return

Validation is designed for fast rejection: checks are ordered from cheapest to most expensive. If any check fails, subsequent checks may still run to collect all errors in a single response.

## Options & Configuration

Validation rules are hardcoded to match the supported API schema. Adding new floor types, material presets, or optimization targets requires updating both `json_to_params` and `validate_input`.

## Limitations & Future Work

- Geometric validity (e.g., non-intersecting edges, planar faces) is not checked during validation; it is handled during skeleton construction.
- Custom material definitions are not validated; they pass validation but may fail during `json_to_params`.
- Schema versioning would allow different validation rules for different API versions.
