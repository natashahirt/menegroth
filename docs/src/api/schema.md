# API Schema

> ```julia
> # All input/output types are defined in:
> # StructuralSynthesizer/src/api/schema.jl
> ```

## Overview

The API schema defines the JSON input and output structures for the HTTP API. Input types are mutable structs (for JSON deserialization via StructTypes.jl), and output types are immutable structs (for serialization).

## Key Types

### Input Types

### APIInput

The top-level input object sent to `POST /design` and `POST /validate`.

| Field | Type | Required | Description |
|:------|:-----|:---------|:------------|
| `units` | `String` | yes | Coordinate units: `"feet"/"ft"`, `"inches"/"in"`, `"meters"/"m"`, `"millimeters"/"mm"`, or `"centimeters"/"cm"` |
| `vertices` | `Vector{Vector{Float64}}` | yes | 3D vertex coordinates `[[x,y,z], ...]` |
| `edges` | `APIEdgeGroups` | yes | Edge connectivity by group |
| `supports` | `Vector{Int}` | yes | 1-based vertex indices with support conditions |
| `stories_z` | `Vector{Float64}` | no | Story elevation Z coordinates (inferred from vertices if empty / omitted) |
| `faces` | `APIFaceGroups` | no | Face definitions by group (auto-detected if empty / omitted) |
| `params` | `APIParams` | yes | Design parameters |

See [`APIInput`](@ref) in [API Overview](overview.md).

### APIEdgeGroups

| Field | Type | Description |
|:------|:-----|:------------|
| `beams` | `Vector{Vector{Int}}` | Beam edges as `[[v1, v2], ...]` (1-based vertex pairs) |
| `columns` | `Vector{Vector{Int}}` | Column edges |
| `braces` | `Vector{Vector{Int}}` | Brace edges (optional) |

`APIEdgeGroups` groups the structural edge connectivity into beams, columns, and braces, each defined as a vector of vertex-index pairs.

### APIFaceGroups

A dictionary mapping face group names to face-coordinate polylines:

```json
{
  "floor": [[[0.0,0.0,10.0], [30.0,0.0,10.0], [30.0,20.0,10.0], [0.0,20.0,10.0]]],
  "roof": [[[0.0,0.0,20.0], [30.0,0.0,20.0], [30.0,20.0,20.0], [0.0,20.0,20.0]]]
}
```

### APIParams

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `unit_system` | `String` | `"imperial"` | `"imperial"` or `"metric"` |
| `loads` | `APILoads` | `APILoads()` | Gravity loading |
| `floor_type` | `String` | `"flat_plate"` | Floor system type: `"flat_plate"`, `"flat_slab"`, `"one_way"`, or `"vault"` |
| `floor_options` | `APIFloorOptions` | `APIFloorOptions()` | Floor-specific options |
| `materials` | `APIMaterials` | `APIMaterials()` | Material selections |
| `column_type` | `String` | `"rc_rect"` | `"rc_rect"`, `"rc_circular"`, `"steel_w"`, `"steel_hss"`, `"steel_pipe"`, or `"pixelframe"` |
| `column_catalog` | `Union{String, Nothing}` | `nothing` | Optional. If omitted or `null`, the server chooses a safe default based on `column_type` (**steel** → `"preferred"`, **RC** → `"standard"`). If provided: **Steel** (steel_w/steel_hss/steel_pipe): `"compact_only"`, `"preferred"`, `"all"`. **RC rectangular** (rc_rect): `"standard"`, `"square"`, `"rectangular"`, `"low_capacity"`, `"high_capacity"`, `"all"`. **RC circular** (rc_circular): `"standard"`, `"low_capacity"`, `"high_capacity"`, `"all"`. Ignored for pixelframe. |
| `column_sizing_strategy` | `String` | `"discrete"` | `"discrete"` (catalog/MIP) or `"nlp"` (continuous Ipopt). Applies to columns. |
| `beam_type` | `String` | `"steel_w"` | `"steel_w"`, `"steel_hss"`, `"rc_rect"`, `"rc_tbeam"`, or `"pixelframe"` |
| `beam_catalog` | `String` | `"large"` | RC beam catalog (when `beam_type` is RC): `"standard"`, `"small"`, `"large"`, `"xlarge"`, `"all"`, or `"custom"`. Ignored for steel and pixelframe. |
| `beam_sizing_strategy` | `String` | `"discrete"` | `"discrete"` (catalog/MIP) or `"nlp"` (continuous Ipopt). Applies to beams. |
| `beam_catalog_bounds` | `Union{APIBeamCatalogBounds, Nothing}` | `nothing` | Required when `beam_catalog == "custom"`; bounds and resolution (inches) for generating a custom RC beam catalog. |
| `pixelframe_options` | `Union{APIPixelFrameOptions, Nothing}` | `nothing` | Required when `column_type == "pixelframe"` or `beam_type == "pixelframe"`; selects PixelFrame concrete strength catalog. |
| `fire_rating` | `Float64` | `0.0` | Fire resistance in hours |
| `optimize_for` | `String` | `"weight"` | `"weight"`, `"carbon"`, or `"cost"` |
| `size_foundations` | `Bool` | `false` | Whether to size foundations |
| `foundation_soil` | `String` | `"medium_sand"` | Soil type name (used when `size_foundations=true`): `"loose_sand"`, `"medium_sand"`, `"dense_sand"`, `"soft_clay"`, `"stiff_clay"`, `"hard_clay"` |
| `foundation_concrete` | `String` | `"NWC_3000"` | Foundation concrete grade (used when `size_foundations=true`) |
| `foundation_options` | `Union{APIFoundationOptions, Nothing}` | `nothing` | Optional strategy + per-type overrides (spread/strip/mat). Applied when `size_foundations=true`. |
| `scoped_overrides` | `Vector{APIScopedOverride}` | `[]` | Optional face-scoped floor overrides (e.g., vault-only regions). |
| `geometry_is_centerline` | `Bool` | `false` | How to interpret input vertex coordinates — see [Structural Column Offsets](#structural-column-offsets) |

See [`APIParams`](@ref) in [API Overview](overview.md).

### APIBeamCatalogBounds

Bounds for generating a custom RC beam catalog when `APIParams.beam_catalog == "custom"` (all lengths in inches):

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `min_width_in` | `Float64` | `12.0` | Minimum beam width |
| `max_width_in` | `Float64` | `36.0` | Maximum beam width |
| `min_depth_in` | `Float64` | `18.0` | Minimum beam depth |
| `max_depth_in` | `Float64` | `48.0` | Maximum beam depth |
| `resolution_in` | `Float64` | `2.0` | Grid resolution (applied to both width and depth) |

### APIPixelFrameOptions

PixelFrame catalog selection (strengths are resolved into an internal `fc_values` vector in MPa):

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `fc_preset` | `String` | `"standard"` | `"standard"`, `"low"`, `"high"`, `"extended"`, or `"custom"` |
| `fc_min_ksi` | `Union{Float64, Nothing}` | `nothing` | Required when `fc_preset == "custom"` |
| `fc_max_ksi` | `Union{Float64, Nothing}` | `nothing` | Required when `fc_preset == "custom"` |
| `fc_resolution_ksi` | `Union{Float64, Nothing}` | `nothing` | Required when `fc_preset == "custom"` |

### APIFoundationOptions

Optional foundation strategy + per-type overrides (applied when `APIParams.size_foundations == true`):

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `strategy` | `String` | `"auto"` | `"auto"`, `"all_spread"`, `"all_strip"`, or `"mat"` |
| `mat_coverage_threshold` | `Float64` | `0.5` | Mat selection threshold \(R \in [0, 1]\) used by `"auto"` |
| `spread_params` | `Union{APISpreadParams, Nothing}` | `nothing` | Optional spread-footing overrides |
| `strip_params` | `Union{APIStripParams, Nothing}` | `nothing` | Optional strip-footing overrides |
| `mat_params` | `Union{APIMatParams, Nothing}` | `nothing` | Optional mat-footing overrides |

#### APISpreadParams

All lengths are in inches:

| Field | Type | Default |
|:------|:-----|:--------|
| `cover_in` | `Union{Float64, Nothing}` | `nothing` |
| `min_depth_in` | `Union{Float64, Nothing}` | `nothing` |
| `bar_size` | `Union{Int, Nothing}` | `nothing` |
| `depth_increment_in` | `Union{Float64, Nothing}` | `nothing` |
| `size_increment_in` | `Union{Float64, Nothing}` | `nothing` |

#### APIStripParams

All lengths are in inches:

| Field | Type | Default |
|:------|:-----|:--------|
| `cover_in` | `Union{Float64, Nothing}` | `nothing` |
| `min_depth_in` | `Union{Float64, Nothing}` | `nothing` |
| `bar_size_long` | `Union{Int, Nothing}` | `nothing` |
| `bar_size_trans` | `Union{Int, Nothing}` | `nothing` |
| `width_increment_in` | `Union{Float64, Nothing}` | `nothing` |
| `max_depth_ratio` | `Union{Float64, Nothing}` | `nothing` |
| `merge_gap_factor` | `Union{Float64, Nothing}` | `nothing` |
| `eccentricity_limit` | `Union{Float64, Nothing}` | `nothing` |

#### APIMatParams

All lengths are in inches:

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `cover_in` | `Union{Float64, Nothing}` | `nothing` | Clear cover |
| `min_depth_in` | `Union{Float64, Nothing}` | `nothing` | Minimum mat thickness |
| `bar_size_x` | `Union{Int, Nothing}` | `nothing` | Bar size in x |
| `bar_size_y` | `Union{Int, Nothing}` | `nothing` | Bar size in y |
| `depth_increment_in` | `Union{Float64, Nothing}` | `nothing` | Thickness increment |
| `edge_overhang_in` | `Union{Float64, Nothing}` | `nothing` | Edge overhang |
| `analysis_method` | `Union{String, Nothing}` | `nothing` | `"rigid"`, `"shukla"`, or `"winkler"` |

### APIScopedOverride

Face-scoped floor override blocks (used for region-specific floor types like vaults):

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `floor_type` | `String` | `"vault"` | `"flat_plate"`, `"flat_slab"`, `"one_way"`, or `"vault"` |
| `floor_options` | `APIScopedFloorOptions` | `APIScopedFloorOptions()` | Scoped floor options (currently supports `vault_lambda` only) |
| `faces` | `Vector{Vector{Vector{Float64}}}` | `[]` | Face polygons (each polygon is an array of `[x,y,z]` points, in coordinate units) |

#### APIScopedFloorOptions

| Field | Type | Default |
|:------|:-----|:--------|
| `vault_lambda` | `Union{Float64, Nothing}` | `nothing` |

### APILoads

| Field | Type | Default | Unit | Description |
|:------|:-----|:--------|:-----|:------------|
| `floor_LL_psf` | `Float64` | `80.0` | psf | Floor live load |
| `roof_LL_psf` | `Float64` | `20.0` | psf | Roof live load |
| `grade_LL_psf` | `Float64` | `100.0` | psf | Grade live load |
| `floor_SDL_psf` | `Float64` | `15.0` | psf | Floor superimposed dead load |
| `roof_SDL_psf` | `Float64` | `15.0` | psf | Roof superimposed dead load |
| `wall_SDL_psf` | `Float64` | `10.0` | psf | Perimeter wall dead load |

`APILoads` specifies gravity loading intensities (in psf) for floors, roofs, grade levels, and perimeter walls, covering both live loads and superimposed dead loads.

### APIFloorOptions

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `method` | `String` | `"DDM"` | Analysis method: `"DDM"`, `"DDM_SIMPLIFIED"`, `"EFM"`, `"EFM_HARDY_CROSS"`, or `"FEA"` |
| `deflection_limit` | `String` | `"L_360"` | Deflection limit: `"L_240"`, `"L_360"`, `"L_480"` |
| `punching_strategy` | `String` | `"grow_columns"` | `"grow_columns"`, `"reinforce_first"`, `"reinforce_last"` |

`APIFloorOptions` controls floor-specific design settings including the analysis method (DDM, EFM, FEA, or rule-of-thumb), deflection limits, and the punching shear mitigation strategy.

### APIMaterials

| Field | Type | Default | Description |
|:------|:-----|:--------|:------------|
| `concrete` | `String` | `"NWC_4000"` | Concrete name (e.g., `"NWC_4000"`, `"NWC_5000"`) |
| `column_concrete` | `String` | `"NWC_6000"` | Column concrete name (used for RC column sizing) |
| `rebar` | `String` | `"Rebar_60"` | Rebar grade (e.g., `"Rebar_60"`, `"Rebar_75"`) |
| `steel` | `String` | `"A992"` | Structural steel grade |

`APIMaterials` selects the material grades used throughout the design. Note that RC columns default to a higher-strength concrete (`column_concrete`, default `"NWC_6000"`) unless overridden.

### Output Types

### APIOutput

The top-level response from `POST /design`.

| Field | Type | Description |
|:------|:-----|:------------|
| `status` | `String` | `"ok"` or `"error"` |
| `compute_time_s` | `Float64` | Wall-clock design time in seconds |
| `length_unit` | `String` | Length unit label for length-category outputs (`"ft"` or `"m"`) |
| `thickness_unit` | `String` | Thickness unit label for thickness-category outputs (`"in"` or `"mm"`) |
| `volume_unit` | `String` | Volume unit label for volume-category outputs (`"ft3"` or `"m3"`) |
| `mass_unit` | `String` | Mass unit label for mass-category outputs (`"lb"` or `"kg"`) |
| `summary` | `APISummary` | Design summary |
| `slabs` | `Vector{APISlabResult}` | Per-slab results |
| `columns` | `Vector{APIColumnResult}` | Per-column results |
| `beams` | `Vector{APIBeamResult}` | Per-beam results |
| `foundations` | `Vector{APIFoundationResult}` | Per-foundation results |
| `geometry_hash` | `String` | Geometry hash for caching |
| `visualization` | `Union{APIVisualization, Nothing}` | Visualization data (optional; `nothing` when unavailable) |

See [`APIOutput`](@ref) in [API Overview](overview.md).

### Unit-Neutral Key Mapping

Output field names are unit-neutral. Unit interpretation comes from top-level unit labels (`length_unit`, `thickness_unit`, `volume_unit`, `mass_unit`).

| Legacy key | Current key |
|:-------------|:------------|
| `thickness_in` | `thickness` |
| `c1_in` | `c1` |
| `c2_in` | `c2` |
| `length_ft` | `length` |
| `width_ft` | `width` |
| `depth_ft` | `depth` |
| `concrete_volume_ft3` | `concrete_volume` |
| `steel_weight_lb` | `steel_weight` |
| `rebar_weight_lb` | `rebar_weight` |
| `position_ft` | `position` |
| `displacement_ft` | `displacement` |
| `deflected_position_ft` | `deflected_position` |
| `section_depth_ft` | `section_depth` |
| `section_width_ft` | `section_width` |
| `flange_width_ft` | `flange_width` |
| `web_thickness_ft` | `web_thickness` |
| `flange_thickness_ft` | `flange_thickness` |
| `center_ft` | `center` |
| `extra_depth_ft` | `extra_depth` |
| `thickness_ft` | `thickness` |
| `z_top_ft` | `z_top` |
| `max_displacement_ft` | `max_displacement` |

### APISummary

| Field | Type | Description |
|:------|:-----|:------------|
| `all_pass` | `Bool` | All elements pass code checks |
| `concrete_volume` | `Float64` | Total concrete volume (see `volume_unit`) |
| `steel_weight` | `Float64` | Total structural steel weight (see `mass_unit`) |
| `rebar_weight` | `Float64` | Total rebar weight (see `mass_unit`) |
| `embodied_carbon_kgCO2e` | `Float64` | Total embodied carbon |
| `critical_ratio` | `Float64` | Governing D/C ratio |
| `critical_element` | `String` | Element with highest D/C |

`APISummary` aggregates the high-level design results: overall pass/fail status, total material quantities (concrete volume, steel weight, rebar weight), embodied carbon, and the governing demand-to-capacity ratio with its associated critical element.

### APISlabResult

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `Int` | Slab index |
| `ok` | `Bool` | Slab passes all slab checks (`converged && deflection_ok && punching_ok`) |
| `thickness` | `Float64` | Slab thickness (see `thickness_unit`) |
| `converged` | `Bool` | Design converged |
| `failure_reason` | `String` | Failure description (empty if ok) |
| `failing_check` | `String` | Which check failed |
| `iterations` | `Int` | Design iterations used |
| `deflection_ok` | `Bool` | Deflection within limit |
| `deflection_ratio` | `Float64` | Actual L/n ratio |
| `punching_ok` | `Bool` | Punching shear adequate |
| `punching_max_ratio` | `Float64` | Maximum punching D/C |

`APISlabResult` reports per-slab design outcomes including thickness, convergence status, deflection and punching shear checks, and iteration count.

### APIColumnResult

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `Int` | Column index |
| `section` | `String` | Section designation |
| `c1` | `Float64` | Depth dimension (see `thickness_unit`) |
| `c2` | `Float64` | Width dimension (see `thickness_unit`) |
| `shape` | `String` | `"rectangular"` or `"circular"` |
| `axial_ratio` | `Float64` | Pu / ϕPn |
| `interaction_ratio` | `Float64` | P-M interaction ratio |
| `ok` | `Bool` | Passes all checks |

`APIColumnResult` reports per-column design outcomes including section designation, dimensions, shape, axial ratio, P-M interaction ratio, and pass/fail status.

### APIBeamResult

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `Int` | Beam index |
| `section` | `String` | Section designation |
| `flexure_ratio` | `Float64` | Mu / ϕMn |
| `shear_ratio` | `Float64` | Vu / ϕVn |
| `ok` | `Bool` | Passes all checks |

`APIBeamResult` reports per-beam design outcomes including section designation, flexure and shear demand-to-capacity ratios, and pass/fail status.

### APIFoundationResult

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `Int` | Foundation index |
| `length` | `Float64` | Footing length (see `length_unit`) |
| `width` | `Float64` | Footing width (see `length_unit`) |
| `depth` | `Float64` | Footing depth (see `length_unit`) |
| `bearing_ratio` | `Float64` | Bearing pressure / capacity |
| `ok` | `Bool` | Passes all checks |

`APIFoundationResult` reports per-foundation design outcomes including footing dimensions, bearing pressure ratio, and pass/fail status.

### APIVisualization

| Field | Type | Description |
|:------|:-----|:------------|
| `nodes` | `Vector{APIVisualizationNode}` | Node positions, displacements, and deflected positions |
| `frame_elements` | `Vector{APIVisualizationFrameElement}` | Frame element data with section geometry and optional material color |
| `sized_slabs` | `Vector{APISizedSlab}` | Slab boundary/thickness plus drop-panel patches |
| `deflected_slab_meshes` | `Vector{APIDeflectedSlabMesh}` | Deflected slab surface meshes with local/global displacements and drop-panel patches |
| `foundations` | `Vector{APIVisualizationFoundation}` | Foundation blocks for visualization |
| `is_beamless_system` | `Bool` | True when model uses slab-only framing (`flat_plate` / `flat_slab`) |
| `suggested_scale_factor` | `Float64` | Suggested displacement magnification |
| `max_displacement` | `Float64` | Maximum displacement in the model (see `length_unit`) |
| `max_frame_axial` | `Float64` | Maximum \(|P|\) across all frame elements |
| `max_frame_moment` | `Float64` | Maximum \(|M|\) across all frame elements |
| `max_frame_shear` | `Float64` | Maximum \(|V|\) across all frame elements |
| `max_slab_bending` | `Float64` | Maximum \(|M|\) across all slab faces |
| `max_slab_membrane` | `Float64` | Maximum \(|N|\) across all slab faces |
| `max_slab_shear` | `Float64` | Maximum transverse shear across all slab faces |
| `max_slab_von_mises` | `Float64` | Maximum von Mises stress across all slab faces |
| `max_slab_surface_stress` | `Float64` | Maximum \(|\sigma|\) across all slab faces |

The visualization schema contains several related types:

- **`APIVisualization`** — Top-level container for all visualization payloads.
- **`APIVisualizationNode`** — A single node with `position`, `displacement`, `deflected_position`, and support metadata (`is_support`).
- **`APIVisualizationFrameElement`** — A frame element with start/end node indices, section geometry, member type, and optional `material_color_hex`.
- **`APISizedSlab`** — A slab boundary polygon with thickness (`thickness`, `z_top`) and `drop_panels`.
- **`APIDropPanelPatch`** — A rectangular drop-panel patch (`center`, `length`, `width`, `extra_depth`) used in both sized and deflected slab views.
- **`APIDeflectedSlabMesh`** — A triangulated deflected slab mesh with `vertex_displacements`, `vertex_displacements_local`, and `drop_panels`.
- **`APIVisualizationFoundation`** — Foundation block geometry (`center`, `length`, `width`, `depth`) with utilization metadata.

Example snippet (abbreviated) showing beamless-state and one drop-panel patch:

```json
{
  "visualization": {
    "is_beamless_system": true,
    "sized_slabs": [
      {
        "slab_id": 1,
        "thickness": 1.0,
        "z_top": 12.0,
        "drop_panels": [
          {
            "center": [30.0, 20.0, 12.0],
            "length": 8.0,
            "width": 8.0,
            "extra_depth": 0.5
          }
        ]
      }
    ],
    "deflected_slab_meshes": [
      {
        "slab_id": 1,
        "drop_panels": [
          {
            "center": [30.0, 20.0, 12.0],
            "length": 8.0,
            "width": 8.0,
            "extra_depth": 0.5
          }
        ]
      }
    ]
  }
}
```

#### APIVisualizationNode

| Field | Type | Description |
|:------|:-----|:------------|
| `node_id` | `Int` | 1-based node index in analysis model |
| `position` | `Vector{Float64}` | Original node position `[x,y,z]` |
| `displacement` | `Vector{Float64}` | Nodal displacement vector `[dx,dy,dz]` |
| `deflected_position` | `Vector{Float64}` | Deflected node position `[x,y,z]` |
| `is_support` | `Bool` | True when this node is a structural support node |

#### APIVisualizationFrameElement

| Field | Type | Description |
|:------|:-----|:------------|
| `element_id` | `Int` | Analysis element index |
| `node_start` | `Int` | 1-based start node index |
| `node_end` | `Int` | 1-based end node index |
| `element_type` | `String` | `"beam"`, `"column"`, `"strut"`, or `"other"` |
| `utilization_ratio` | `Float64` | Governing utilization ratio (D/C) for the element |
| `ok` | `Bool` | Element pass/fail flag |
| `section_name` | `String` | Section designation |
| `material_color_hex` | `String` | Optional material display color (e.g. `#6E6E6E`) |
| `section_type` | `String` | Section shape family |
| `section_depth` | `Float64` | Section depth |
| `section_width` | `Float64` | Section width |
| `flange_width` | `Float64` | W-shape flange width (0 for non-W shapes) |
| `web_thickness` | `Float64` | W-shape web thickness (0 for non-W shapes) |
| `flange_thickness` | `Float64` | W-shape flange thickness (0 for non-W shapes) |
| `section_polygon` | `Vector{Vector{Float64}}` | Section polygon in local `[y,z]` coordinates |
| `section_polygon_inner` | `Vector{Vector{Float64}}` | Inner boundary for hollow sections (HSS rect/round); empty for solid sections |
| `original_points` | `Vector{Vector{Float64}}` | Interpolated points along the element centerline `[x,y,z]` |
| `displacement_vectors` | `Vector{Vector{Float64}}` | Displacements at each interpolated point `[dx,dy,dz]` |
| `max_axial_force` | `Float64` | Signed axial extremum (+ tension, − compression) |
| `max_moment` | `Float64` | Signed moment extremum (largest \(|M|\), sign preserved) |
| `max_shear` | `Float64` | Signed shear extremum (largest \(|V|\), sign preserved) |

### APIError

| Field | Type | Description |
|:------|:-----|:------------|
| `status` | `String` | `"error"` |
| `error` | `String` | Error type |
| `message` | `String` | Human-readable message |
| `traceback` | `String` | Stack trace (debug mode only) |

See [`APIError`](@ref) in [API Overview](overview.md).

## Structural Column Offsets

When `geometry_is_centerline` is `false` (the default), the server treats input
vertex coordinates as **architectural reference points** — panel corners and
facade lines.  Edge and corner columns are automatically offset inward to their
structural centerlines before analysis.

### How it works

1. **Column classification**: Each column is classified as `:interior`, `:edge`,
   or `:corner` based on how many boundary edges meet at its vertex
   (`edge_face_counts` in the skeleton).

2. **Inward normal computation**: For each boundary edge adjacent to a
   non-interior column, the face-winding approach determines the inward-pointing
   normal. The skeleton stores face vertices in CCW order; the left-hand normal
   of the directed edge (as it appears in the owning face's winding) reliably
   points toward the slab interior, even for concave polygons.

3. **Deduplication**: Parallel boundary edges (dot product > 0.95) produce
   duplicate normals. These are collapsed so each unique inward direction
   contributes only one offset component.

4. **Offset magnitude**: Along each unique inward normal, the offset equals half
   the column dimension in that direction (`_column_half_dim_m`), accounting for
   column shape (rectangular vs circular) and rotation angle `θ`.

5. **Application**: The resulting `structural_offset` (dx, dy) in meters is
   stored on each `Column` and applied in `to_asap!` when building Asap model
   nodes.  Beams that frame into the column naturally follow because they share
   the same skeleton vertex (and therefore the same shifted Asap node).

### When `geometry_is_centerline = true`

All offsets are `(0, 0)` — the input vertex positions are used directly as
structural centerlines.

### Iteration

Offsets depend on column dimensions, which change during design iteration.
`update_structural_offsets!` is called:
- After `estimate_column_sizes!` (initial sizing)
- After `_reconcile_columns!` (if columns grow during reconciliation)
- After `restore!` (snapshot recovery)

The function is idempotent and safe to call repeatedly.

### Slab boundary behaviour

The slab boundary always matches the input (architectural) geometry.  When
offsets are active, edge/corner column support nodes sit slightly inboard of the
slab edge, producing a small cantilever overhang in the slab FEA mesh.  This is
structurally correct — the slab extends to the building face while the column
supports it from inboard.

!!! note "Future work: centerline input slab extension"
    When `geometry_is_centerline = true`, the slab boundary stops at the column
    centerline rather than extending outward to the building face.  This means the
    small outboard slab strip is not modelled.  Extending the slab boundary outward
    by half the column dimension for centerline input is a planned enhancement.

### Grasshopper

The **Geometry Input** component exposes a right-click toggle **"Input is
Centerline"**.  When checked, `geometry_is_centerline = true` is sent in the API
payload.  The default (unchecked) is architectural input.  The component message
bar shows "CL" when centerline mode is active.

## Limitations & Future Work

- Output fields are unit-neutral; clients must use `length_unit`, `thickness_unit`, `volume_unit`, and `mass_unit` to interpret numeric values.
- The current server implementation always builds an analysis model and returns `visualization` data; making this optional (for performance) would require an API option.
- The schema is versioned implicitly; explicit API versioning (`/v1/design`) is planned.
- Slab boundary extension for centerline input mode is not yet implemented (see note above).

## References

- `StructuralSynthesizer/src/api/schema.jl`
