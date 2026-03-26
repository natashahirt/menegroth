# JSON Serialization

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
> vr = validate_input(api_input)
> @assert vr.ok join(vr.errors, "\n")
>
> skeleton = json_to_skeleton(api_input)
> params   = json_to_params(api_input.params, api_input.units)
> hash     = compute_geometry_hash(api_input)
> ```

## Overview

The serialization module converts between JSON API types and internal Julia types. Deserialization (`json_to_*`) handles unit conversion and type mapping from JSON strings to Julia objects. Serialization (`design_to_json`) converts the `BuildingDesign` back to JSON-safe output types.

**Source:** `StructuralSynthesizer/src/api/deserialize.jl`, `serialize.jl`

## Functions

```@docs
json_to_skeleton
json_to_params
design_to_json
compute_geometry_hash
```

## Implementation Details

### json_to_skeleton

`json_to_skeleton(input::APIInput) → BuildingSkeleton` performs:

1. **Unit conversion** — vertex coordinates from accepted API units (`feet/ft`, `inches/in`, `meters/m`, `millimeters/mm`, `centimeters/cm`) into internal meters
2. **Vertex creation** — `Meshes.Point` objects from coordinate arrays
3. **Edge creation** — skeleton edges from `APIEdgeGroups`, classified into `:beams`, `:columns`, `:braces`
4. **Support marking** — vertices listed in `input.supports` are marked as restrained
5. **Story setup** — if `input.stories_z` is provided (non-empty), it is copied into `skel.stories_z` (after unit conversion to meters) before `rebuild_stories!` runs. Note that `rebuild_stories!` will then recompute stories from vertex Z coordinates (rounded), overwriting `skel.stories_z`; `input.stories_z` still participates in `compute_geometry_hash` for caching behavior.
6. **Face detection + grouping** — faces are always detected from the edge mesh; if `input.faces` is provided, its polygons are used as selectors to assign detected faces to groups (`"floor"`, `"roof"`, `"grade"`), otherwise the server auto-categorizes faces by story level

### json_to_params

`json_to_params(api_params::APIParams, coord_unit_str::String="meters") → DesignParameters` maps JSON string identifiers to Julia types. In the API server, it is called as `json_to_params(input.params, input.units)` so any face-scoped override polygons are converted using the same coordinate units as `APIInput.vertices`.

| JSON Field | JSON String | Julia Result |
|:-----------|:------------|:-------------|
| `floor_type` | `"flat_plate"` | `FlatPlateOptions(...)` |
| `floor_type` | `"flat_slab"` | `FlatSlabOptions(base=FlatPlateOptions(...))` |
| `floor_type` | `"one_way"` | `OneWayOptions()` (currently ignores `floor_options.*`) |
| `floor_type` | `"vault"` | `VaultOptions(lambda = something(floor_options.vault_lambda, 10.0))` (vault currently uses only `vault_lambda`; other `floor_options.*` fields are ignored) |
| `column_type` | `"rc_rect"` | `ConcreteColumnOptions(material=column_concrete, rebar_material=..., section_shape=:rect, catalog=..., sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `column_type` | `"rc_circular"` | `ConcreteColumnOptions(material=column_concrete, rebar_material=..., section_shape=:circular, catalog=..., sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `column_type` | `"steel_w"` | `SteelColumnOptions(material=steel, section_type=:w, catalog=..., sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `column_type` | `"steel_hss"` | `SteelColumnOptions(material=steel, section_type=:hss, catalog=..., sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `column_type` | `"steel_pipe"` | `SteelColumnOptions(material=steel, section_type=:pipe, catalog=..., sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `column_type` | `"pixelframe"` | `PixelFrameColumnOptions(fc_values=...)` |
| `beam_type` | `"steel_w"` | `SteelBeamOptions(material=steel, section_type=:w, sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `beam_type` | `"steel_hss"` | `SteelBeamOptions(material=steel, section_type=:hss, sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `beam_type` | `"rc_rect"` | `ConcreteBeamOptions(material=concrete, rebar_material=rebar, include_flange=false, catalog=..., custom_catalog=..., sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `beam_type` | `"rc_tbeam"` | `ConcreteBeamOptions(material=concrete, rebar_material=rebar, include_flange=true, catalog=..., custom_catalog=..., sizing_strategy=..., time_limit_sec=something(mip_time_limit_sec, 30.0))` |
| `beam_type` | `"pixelframe"` | `PixelFrameBeamOptions(fc_values=...)` |
| `materials.concrete` | `"NWC_4000"` | `NWC_4000` |
| `materials.concrete` | `"NWC_5000"` | `NWC_5000` |
| `materials.column_concrete` | `"NWC_6000"` | `NWC_6000` |
| `materials.steel` | `"A992"` | `A992_Steel` |
| `materials.rebar` | `"Rebar_60"` | `Rebar_60` |
| `optimize_for` | `"weight"` | `:weight` |
| `optimize_for` | `"carbon"` | `:carbon` |
| `optimize_for` | `"cost"` | `:cost` |
| `floor_options.method` | `"DDM"` | `DDM()` |
| `floor_options.method` | `"DDM_SIMPLIFIED"` | `DDM(:simplified)` |
| `floor_options.method` | `"EFM"` | `EFM()` |
| `floor_options.method` | `"EFM_HARDY_CROSS"` | `EFM(solver=:hardy_cross)` |
| `floor_options.method` | `"FEA"` | `FEA(target_edge = floor_options.target_edge_m * u"m")` when provided; otherwise `FEA(target_edge = nothing)` and the mesher uses an adaptive default (`clamp(min_span_m/20, 0.15, 0.75)` m). |
| `column_sizing_strategy` | `"discrete"` / `"nlp"` | Sets `ConcreteColumnOptions(...; sizing_strategy=...)` and `SteelColumnOptions(...; sizing_strategy=...)` |
| `beam_sizing_strategy` | `"discrete"` / `"nlp"` | Sets `ConcreteBeamOptions(...; sizing_strategy=...)` and `SteelBeamOptions(...; sizing_strategy=...)` |
| `mip_time_limit_sec` | — | Sets `time_limit_sec` on discrete column/beam options (defaults to 30s when omitted/`null`) |
| `beam_catalog` | `"custom"` + `beam_catalog_bounds` | Builds `custom_catalog = rc_beam_catalog_from_bounds(...)` and sets `ConcreteBeamOptions(catalog=:standard, custom_catalog=custom_catalog)` |
| `pixelframe_options.fc_preset` | `"standard"`, `"low"`, `"high"`, `"extended"` | Selects preset `fc_values` (MPa) for PixelFrame catalogs |
| `pixelframe_options.fc_preset` | `"custom"` | Uses `fc_min_ksi`, `fc_max_ksi`, `fc_resolution_ksi` to build `fc_values` (MPa). The resolution is clamped to at least 0.5 ksi. If `pixelframe_options` is omitted entirely, the server uses the `"standard"` preset. |
| `foundation_soil` | `"medium_sand"` | `FoundationParameters(soil=medium_sand, ...)` when `size_foundations=true` |
| `foundation_concrete` | `"NWC_3000"` | `FoundationParameters(concrete=NWC_3000, ...)` when `size_foundations=true` |
| `foundation_options.*` | — | Builds `FoundationOptions(strategy=..., mat_coverage_threshold=..., spread_params=..., strip_params=..., mat_params=...)` |
| `max_iterations` | — | Sets `DesignParameters.max_iterations = something(api_params.max_iterations, 20)` |
| `scoped_overrides` | — | Builds `DesignParameters.scoped_floor_overrides` (face-scoped floor overrides; coordinates converted to meters) |
| `visualization_target_edge_m` | — | Sets `DesignParameters.visualization_target_edge_m` (shell mesh target edge length in meters) |
| `skip_visualization` | — | When `true`, sets `DesignParameters.skip_visualization` so `design_to_json` returns `visualization = null` |
| `visualization_detail` | `"minimal"` / `"full"` | Controls serialization detail; `"minimal"` omits deflected slab meshes |

Notes:
- Unknown `floor_type` strings fall back to `FlatPlateOptions(...)` with the resolved analysis settings.
- `column_catalog` is optional in JSON. When omitted or `null`, the server selects a default catalog based on `column_type` (steel → `"preferred"`, RC → `"standard"`).
- `unit_system` controls `DesignParameters.display_units` and therefore the units used in serialized output. Length-valued arrays use `APIOutput.length_unit` (`"ft"` or `"m"`); thickness and similar dimensions use the display thickness unit (inches for imperial, millimeters for metric). See also `thickness_unit`, `volume_unit`, and `mass_unit` in the schema.

### design_to_json

`design_to_json(design::BuildingDesign; geometry_hash) → APIOutput` converts the design to JSON-safe output:

1. **Summary** — extracts material quantities, embodied carbon, pass/fail status
2. **Slabs** — converts each `SlabDesignResult` to `APISlabResult` using the design's display units
3. **Columns** — converts each `ColumnDesignResult` to `APIColumnResult`
4. **Beams** — converts each `BeamDesignResult` to `APIBeamResult`
5. **Foundations** — converts each `FoundationDesignResult` to `APIFoundationResult`
6. **Visualization** — if enabled, generates `APIVisualization` with node positions, frame elements, slab meshes, and deflected shapes
7. **Metadata** — `compute_time_s`, `geometry_hash`, status plus explicit unit labels (`length_unit`, `thickness_unit`, `volume_unit`, `mass_unit`)

### compute_geometry_hash

`compute_geometry_hash(input::APIInput) → String` computes a SHA-256 hash of the geometry-defining fields:
- `vertices`
- `edges` (beams, columns, braces)
- `supports`
- `stories_z`
- `faces` (if provided)
- `units`

The hash intentionally excludes `params`, so parameter-only changes produce the same hash. It is used to detect when two requests share the same geometry, enabling skeleton reuse and skipping the `json_to_skeleton` and `find_faces!` steps.

## Limitations & Future Work

- Unit conversion assumes all input is in consistent units; mixing units within a single input is not supported.
- Custom material definitions beyond the preset names require extending the `json_to_params` mapping.
- Serialization of visualization data is the most expensive part; clients can set `skip_visualization=true` (and/or `visualization_detail="minimal"`) to reduce CPU and payload size.

## References

- `StructuralSynthesizer/src/api/deserialize.jl`
- `StructuralSynthesizer/src/api/serialize.jl`
- `StructuralSynthesizer/src/api/cache.jl`
