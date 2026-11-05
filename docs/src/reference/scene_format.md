# Scene format

Binary scene packets (`.mgscene`) are the visualization transport for the web viewer and, later, Grasshopper. One packet is a geometry-independent description of a model: node tables, element connectivity, loads, and the end degrees of freedom a shader needs to draw the deflected shape. Julia does not emit meshes.

## Layout

Little-endian.

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | `u32` | Magic `0x4353474D` (bytes `MGSC`) |
| 4 | `u16` | Format version (currently 1) |
| 6 | `u16` | Flags (0) |
| 8 | `u32` | Header length in bytes |
| 12 | bytes | UTF-8 JSON header |
| pad | | Zero padding so the next byte is 8-aligned |
| buffer region | | Concatenated buffers; each buffer starts 8-aligned relative to the region |

Buffer offsets in the header are relative to the start of the buffer region, not the file.

## Header

```json
{
  "version": 1,
  "stages": ["frame", "loads", "solved"],
  "units": {"position": "m", "displacement": "m", "rotation": "rad", "force": "N", "line_load": "N/m"},
  "origin": [x, y, z],
  "counts": {"nodes": 0, "elements": 0, "stations": 9},
  "hashes": {"geometry": "...", "analysis": "..."},
  "max_displacement": 0.0,
  "suggested_scale": 1.0,
  "buffers": [{"name": "node_position", "dtype": "f32", "count": 0, "offset": 0}]
}
```

`origin` is the minimum node coordinate, in meters. `node_position` is stored relative to it so `f32` keeps millimeter precision on large sites. Displacements, rotations, and local degrees of freedom are absolute (not relative to the origin). The structural Z axis is up. Viewers that use a Y-up camera convert at load time.

`dtype` is `f32`, `u32`, `u16`, or `u8`. `count` is the number of scalars.

## Stages

A packet contains one or more stages. Each stage is rebuilt only when its inputs change; the `hashes` object is the cache key.

### `frame`

| Buffer | Dtype | Shape | Meaning |
| --- | --- | --- | --- |
| `node_position` | f32 | nodes × 3 | Position relative to `origin`, meters |
| `element_nodes` | u32 | elements × 2 | Start and end node, **0-based** |
| `element_type` | u8 | elements | 0 beam, 1 column, 2 brace |
| `element_story` | u16 | elements | Story index, 0 when unknown |

### `loads`

Glyphs only. Member loads that are not in this list still affect the solved stage.

| Buffer | Dtype | Shape | Meaning |
| --- | --- | --- | --- |
| `support_index` | u32 | supports | 0-based node with at least one restrained DOF |
| `support_fixity` | u8 | supports | Bit `i` set when DOF `i+1` is restrained. DOFs are ux, uy, uz, rx, ry, rz |
| `node_force_index` | u32 | | 0-based node |
| `node_force` | f32 | × 3 | Global force, newtons |
| `node_moment_index` | u32 | | |
| `node_moment` | f32 | × 3 | Global moment, N·m |
| `line_load_element` | u32 | | 0-based element (`LineLoad` and `GravityLoad`) |
| `line_load` | f32 | × 3 | Global force per length, N/m |
| `point_load_element` | u32 | | |
| `point_load_position` | f32 | | Fraction along the element, 0–1 |
| `point_load` | f32 | × 3 | Global force, newtons |

### `solved`

The deflected shape is **not** sampled into the file. A shader evaluates the same shape functions as `Asap` (`external/Asap/src/Analysis/displacements.jl`, `unodal`).

| Buffer | Dtype | Shape | Meaning |
| --- | --- | --- | --- |
| `node_displacement` | f32 | nodes × 3 | Translation, meters |
| `node_rotation` | f32 | nodes × 3 | Rotation, radians |
| `element_local_dof` | f32 | elements × 12 | `R * u_global`, then masked by `etype2DOF` (releases already applied) |
| `element_lcs` | f32 | elements × 9 | Local axes `lx, ly, lz` in global coordinates, each xyz |
| `load_element` | u32 | loaded | 0-based element that carries a member load |
| `load_particular` | f32 | loaded × stations × 2 | Particular solution `(dy, dz)` in the local frame at stations `range(0, L, stations)` |

Station `i` (1-based) sits at `t = (i-1)/(stations-1)`.

Local displacement at parameter `t ∈ [0, 1]`, with `x = t L` and `ul` the 12 masked local DOFs (1-based, matching `unodal`):

```
dx = (1-t) ul[1] + t ul[7]
n1 = 1 - 3t² + 2t³
n2 = x (1-t)²
n3 = 3t² - 2t³
n4 = x²/L (t-1)
dy = n1 ul[2] + n2 ul[6] + n3 ul[8] + n4 ul[12] + dy_particular
dz = n1 ul[3] + n2 (-ul[5]) + n3 ul[9] + n4 (-ul[11]) + dz_particular
```

Global displacement is `dx lx + dy ly + dz lz`. Between stations the particular term is interpolated linearly in `t`. At the stations this matches `ElementDisplacements` to within Float32 rounding.

`suggested_scale` is `clamp(0.1 * mean_length / max_displacement, 0.01, 200)`, or 1 when nothing moved. It is a display hint.

### Shells and spread footings

Present when `build_scene` is called on a `BuildingStructure` or a `BuildingDesign` that has them. For a design the model is `design.asap_model`, the frame + slab + wall service model from `build_analysis_model!`.

| Buffer | Dtype | Shape | Meaning |
| --- | --- | --- | --- |
| `shell_faces` | u32 | triangles × 3 | Shell triangles, **0-based** indices into `node_position` |
| `shell_kind` | u8 | triangles | 0 slab, 1 wall, 2 drop panel or column patch, 3 other |
| `footing_center` | f32 | footings × 3 | Box centroid relative to `origin`. The centroid sits half a depth below the supports |
| `footing_size` | f32 | footings × 3 | `(length, width, depth)` in meters. Length is along X, width along Y |
| `shell_thickness` | f32 | triangles | Shell thickness in meters, one value per `shell_faces` triangle |
| `load_arrow_position` | f32 | arrows × 3 | Sample point of a shell area load, relative to `origin` |
| `load_arrow_vector` | f32 | arrows × 3 | Mean pressure (Pa) times its direction. Down is −Z |

Shell nodes are model nodes, so `node_displacement` already holds their solved translation. A viewer draws the deflected shell by moving each vertex by `scale × node_displacement`; that is the linear interpolation of translations `ShellTri3` uses (`ShellDisplacements`). No shell buffer is needed in the `solved` stage.

Footing sizes are the foundation design result (`footing_length`, `footing_width`, `footing_depth` for a structure; `FoundationDesignResult.length`, `width`, `depth` for a design), not a display scale. For a design the center includes the design's structural offsets. Only spread footings are written; any other foundation type throws.

### Sized member solids

Present for a `BuildingDesign` whose column or beam results carry a section.

| Buffer | Dtype | Shape | Meaning |
| --- | --- | --- | --- |
| `member_solid_position` | f32 | vertices × 3 | Solid vertices relative to `origin`, undeflected |
| `member_solid_faces` | u32 | triangles × 3 | **0-based** indices into `member_solid_position` |
| `member_solid_element` | u32 | triangles | 0-based frame element of each triangle |

Each solid is `StructuralSizer.section_polygon(section)` swept between the element's end nodes by `_build_frame_element_mesh`, the same mesh as the JSON sized mode, rotated by the column's `θ`. Hollow sections are not swept and keep their centerline only. The header list `element_section` has one section name per frame element, empty when none was sized.

## Component records and the solve trace

`build_scene` on a `BuildingDesign` adds two header objects. A model-only scene does not.

`components` is one dossier per designed column, beam, slab, wall, and spread footing. `design_trace` is the solve: `event_count`, `converged`, `diagnostics`, `phase_timings_s`, a short `summary`, and `events`, every `TraceEvent` in order. `components[].path` is the subset of those events whose `element_id` or `data.lookup` names that component.

Numbers are SI, taken from the design result. A missing value is JSON `null`. A ratio that the solve left unverified (`NaN`) is `null`, and the governing check is `axial_compression_unverified` rather than a stand-in. Clauses are the ones the diagnose path already selects for that section (`_column_code_clauses`, `_beam_code_clauses`). Slab deflection is ACI 318-19 §24.2 and slab punching is ACI 318-19 §22.6, the same clauses as `_diagnose_slab`. An unknown section has an empty clause. Wall clauses are the checker's own `clause` string. Footing checks have no clause in `FoundationDesignResult`, so theirs is empty.

Trace payloads are copied. A vector longer than 80 entries keeps `length` and the first eight values (`truncated: true`). Nested values deeper than eight levels become a type name.

`bind` is how a click finds the dossier. Coordinates are structural, Z up. The viewer swaps Y and Z.

| Kind | `bind` |
| --- | --- |
| column, beam | `frame_elements`: 0-based analysis-model elements, via `asap_model_frame_edge_indices` |
| slab | `shell_kinds` `[0, 2]` (slab and drop panel) and `elevation_m`, the story elevation of the slab's cells |
| wall | `shell_kinds` `[1]`, `plane.origin` and `plane.normal` in plan, and `z0_m` / `z1_m` for that story |
| footing | `footing`: 0-based index in `footing_center`, same order as the buffer |

Each dossier also has `governing` (`check`, `ratio`, `ok`, `clause`), `drawing`, and `checks`. The drawing is the sized geometry and the strip schedule (`bar_size`, `spacing_m`, areas, `Mu_kNm`). It is not a placing drawing: bar coordinates are not in the result. A column `outline_m` is `section_polygon` in the section's local frame, or `null` when there is no section. Wall `drawing.note` records that a failed ordinary-wall check does not change the section.

Slab `method` holds `requested`, `used`, `fallback`, `iterations`, `failure_reason`, `failing_check`, `M0_kNm`, and `qu_kPa`.

## Unknown values

`build_scene` rejects an unknown stage name, a station count below 2, a frame element whose release has no `etype2DOF` mask, and a frame element shorter than `1e-9` m. It does not substitute a default.
