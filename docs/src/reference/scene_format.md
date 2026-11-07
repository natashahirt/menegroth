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
  "units": {"position": "m", "displacement": "m", "rotation": "rad", "force": "N", "line_load": "N/m", "stress": "Pa"},
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
| `element_eccentricity` | f32 | elements × 4 | `(e_start_f1, e_end_f1, e_f2, e_f3)` meters, in the element local axes. Zeros are a concentric member |

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

`element_axial` is present for a solved frame. One signed value per frame element, newtons, tension positive. It is the station of `ElementInternalForces` whose absolute axial force is largest, the same choice as the JSON frame view. `max_axial_n` is the largest absolute value.

### Result fields on shells and tributaries

| Buffer | Dtype | Shape | Meaning |
| --- | --- | --- | --- |
| `element_axial` | f32 | elements | Signed axial force, N. Tension positive |
| `shell_surface_stress` | f32 | triangles | Signed dominant principal surface stress, Pa, one per `shell_faces` triangle. Tension positive. Written only for a solved model |
| `shell_axial` | f32 | triangles | Vertical membrane force, N/m, one per `shell_faces` triangle. Tension positive. Written only for a solved model |
| `tributary_position` | f32 | vertices × 3 | Polygon vertices relative to `origin`, on the slab plane |
| `tributary_count` | u32 | polygons | Vertices in each loop |
| `tributary_element` | u32 | polygons | 0-based frame element, or `0xffffffff` when the edge is not in the analysis model |
| `tributary_kind` | u8 | polygons | 0 column, 1 beam, 2 wall |
| `tributary_cell` | u32 | polygons | 0-based cell that owns the loop. A column-supported cell uses the stored column polygons and wall-width regions; a beam-supported cell uses its edge polygons |

`shell_surface_stress` is the scalar the JSON view calls `face_surface_stress`: the principal stress of larger magnitude at the top or bottom surface, from `ShellInternalForces`. `max_surface_stress_pa` is the largest absolute value. An unsolved model omits the buffer.

`shell_axial` is the vertical component of that same membrane force, `v · N · v` with `v` the global Z axis projected onto the shell. On a wall it is the axial force per unit length. On a floor the in-plane axes are horizontal, so the value is zero. An unsolved model omits it.

On a column-supported cell the loops are the column polygons and wall-width regions stored by `compute_column_tributaries!`. On a beam-supported cell they are the straight-skeleton polygon of each cell edge. Kind is column, beam, or wall. `tributary_cell` names the cell, and a slab's `bind.cell_indices` lists the cells it owns, so the picture is that slab. A design with an empty cache omits the buffers. The loops lie on the slab; a viewer lifts them slightly so they read above the surface.

### Shells and footings

Present when `build_scene` is called on a `BuildingStructure` or a `BuildingDesign` that has them. For a design the model is `design.asap_model`, the frame + slab + wall service model from `build_analysis_model!`.

| Buffer | Dtype | Shape | Meaning |
| --- | --- | --- | --- |
| `shell_faces` | u32 | triangles × 3 | Shell triangles, **0-based** indices into `node_position` |
| `shell_kind` | u8 | triangles | 0 slab, 1 wall, 2 drop panel or column patch, 3 other |
| `footing_center` | f32 | footings × 3 | Box centroid relative to `origin`. The centroid sits half a depth below the supports |
| `footing_size` | f32 | footings × 3 | `(x, y, depth)` in meters. X and Y are the plan sides |
| `footing_kind` | u8 | footings | 0 spread, 1 strip, 2 combined, 3 mat, 4 wall strip. Absent on an older file, which is all spreads |
| `footing_support_node` | u32 | supports | **0-based** analysis-model nodes the footing is designed from, flat |
| `footing_support_count` | u32 | footings | How many `footing_support_node` entries belong to each footing, in order |
| `shell_thickness` | f32 | triangles | Shell thickness in meters, one value per `shell_faces` triangle |
| `load_arrow_position` | f32 | arrows × 3 | Sample point of a shell area load, relative to `origin` |
| `load_arrow_vector` | f32 | arrows × 3 | Mean pressure (Pa) times its direction. Down is −Z |

Shell nodes are model nodes, so `node_displacement` already holds their solved translation. A viewer draws the deflected shell by moving each vertex by `scale × node_displacement`; that is the linear interpolation of translations `ShellTri3` uses (`ShellDisplacements`). No shell buffer is needed in the `solved` stage.

Footing sizes are the foundation design result (`footing_length`, `footing_width`, `footing_depth` for a structure; `FoundationDesignResult.length`, `width`, `depth` for a design), not a display scale. A mat stores its width `B` on X and its length `L_ftg` on Y. A spread or a straight strip stores `L_ftg` along the support span and `B` across it, with the length on X when the supports do not span farther in Y. A wall strip whose walls turn a corner is the axis-aligned extent of those legs thickened by `B/2`; that box contains the reentrant corner, and the dossier says the footing is the legs. The center of a straight footing is the mean of the bound support nodes, half a depth below the lowest one. Those nodes are the skeleton support vertices: `_merge_shell_nodes` keeps them at the front of the analysis model, and the writer rejects a vertex whose analysis node is not at that position. A footing's displacement is the mean displacement of those nodes. The base is fixed, so that displacement is the restraint. A pile is not drawn.

### Sized member solids

Present for a `BuildingDesign` whose column or beam results carry a section.

| Buffer | Dtype | Shape | Meaning |
| --- | --- | --- | --- |
| `member_solid_position` | f32 | vertices × 3 | Solid vertices relative to `origin`, undeflected |
| `member_solid_faces` | u32 | triangles × 3 | **0-based** indices into `member_solid_position` |
| `member_solid_element` | u32 | triangles | 0-based frame element of each triangle |

Each solid is `StructuralSizer.section_polygon(section)` swept along the eccentric section axis by `_build_frame_element_mesh`, the same mesh as the JSON sized mode, rotated by the column's `θ`. The axis is the node line plus `element_eccentricity` along the element local axes. A concentric element stays on the node line. Hollow sections are not swept and keep their centerline only. The header list `element_section` has one section name per frame element, empty when none was sized.

## Component records and the solve trace

`build_scene` on a `BuildingDesign` adds two header objects. A model-only scene does not.

`components` is one dossier per designed column, beam, slab, wall, and footing. `design_trace` is the solve: `event_count`, `converged`, `diagnostics`, `phase_timings_s`, a short `summary`, and `events`, every `TraceEvent` in order. `components[].path` is the subset of those events whose `element_id` or `data.lookup` names that component.

Numbers are SI, taken from the design result. A missing value is JSON `null`. A ratio that the solve left unverified (`NaN`) is `null`, and the governing check is `axial_compression_unverified` rather than a stand-in. Clauses are the ones the diagnose path already selects for that section (`_column_code_clauses`, `_beam_code_clauses`). Slab deflection is ACI 318-19 §24.2 and slab punching is ACI 318-19 §22.6, the same clauses as `_diagnose_slab`. An unknown section has an empty clause. Wall clauses are the checker's own `clause` string. Footing checks have no clause in `FoundationDesignResult`, so theirs is empty.

Trace payloads are copied. A vector longer than 80 entries keeps `length` and the first eight values (`truncated: true`). Nested values deeper than eight levels become a type name.

`bind` is how a click finds the dossier. Coordinates are structural, Z up. The viewer swaps Y and Z.

| Kind | `bind` |
| --- | --- |
| column, beam | `frame_elements`: 0-based analysis-model elements, via `asap_model_frame_edge_indices` |
| slab | `shell_kinds` `[0, 2]` (slab and drop panel) and `elevation_m`, the story elevation of the slab's cells |
| wall | `shell_kinds` `[1]`, `plane.origin` and `plane.normal` in plan, and `z0_m` / `z1_m` for that story |
| footing | `footing`: 0-based index in `footing_center`, and `support_nodes`: the same 0-based analysis nodes as `footing_support_node` |

Each dossier also has `governing` (`check`, `ratio`, `ok`, `clause`), `drawing`, and `checks`. The drawing is the sized geometry and the strip schedule (`bar_size`, `spacing_m`, areas, `Mu_kNm`). A column `outline_m` is `section_polygon` in the section's local frame, or `null` when there is no section. `rebar_m` is `[y, z, diameter]` in that same frame for each bar. A column uses the stored bar centers. A beam uses its one tension layer at `d` and, when doubly reinforced, its compression layer at `d_prime`, spaced the way the section's own clear-spacing check spaces them. `transverse` is the stirrup, tie, or spiral centerline (`loop_m`, or `radius_m` for a spiral) with its bar diameter and clear cover. Transverse spacing is not a field of the section, so the record does not invent one. Either object is `null` when the section stores none. Wall `drawing.note` records that a failed ordinary-wall check does not change the section. A footing `drawing` carries `foundation_type`, `analysis` (`rigid`, `winkler`, or `shukla`, or null), `utilization`, `n_columns`, `reinforcement` (areas in m², or metres when the result stores area per unit width), `wall_indices`, and `walls`. Each wall has its centerline, thickness, and openings (`s0_m`, `z0_m`, `width_m`, `height_m`, `kind`). An opening is a hole in that wall; the mat still covers the centerline. A wall strip that turns a corner sets `note` to say the box is the extent of the legs. A mat or wall strip governs on `utilization`. A spread still governs on bearing, punching, or flexure.

Slab `method` holds `requested`, `used`, `fallback`, `iterations`, `failure_reason`, `failing_check`, `M0_kNm`, and `qu_kPa`.

A slab `drawing.deck` is null unless the floor result is a composite deck. The flute is the catalog profile: `hr_m`, `rib_top_m`, `rib_bottom_m`, `pitch_m`, `fill_m`, `total_depth_m`, `gage`, and `sheet_m`. `direction` is the slab span axis in plan, the line the ribs run along, or null when that axis has no length. `shell_thickness` stays the meshed plate, `total_depth`. `drawing.ribs` is null unless T-beam ribs bear the slab. A shared stem records `bw_m`, `stem_m` (`h − hf`), `flange_m`, and `spacing_m` (center-to-center of parallel ribs, otherwise null). Stems that are not one section set `uniform` false and carry no sizes.

## Unknown values

`build_scene` rejects an unknown stage name, a station count below 2, a frame element whose release has no `etype2DOF` mask, and a frame element shorter than `1e-9` m. It does not substitute a default.

## Version 2 — several designs

Version 2 is the same magic and a `u16` version of 2. After the 8-byte preamble the file is a sequence of records. A record is `u32` type, `u32` payload length, payload, then zero padding to an 8-byte file offset. Type 1 is a block. Type 2 is an index. The last index is the one that counts. Adding a design appends the blocks the file does not already have and a new index. Earlier bytes are not moved. `compact_variants!` rewrites the file without blocks no design names.

A block's payload is the 32-byte SHA-256 of its uncompressed bytes, a gzip codec byte (`1`), a storage byte (`0` raw, `1` quantized), a `u16` dtype code (`1` f32, `2` u32, `3` u16, `4` u8, `5` i16, `6` json), a `u32` count, an `f32` scale, then a gzip member. The hash covers the dtype name, the count, the scale, and the uncompressed bytes. Quantized `node_displacement` and `shell_surface_stress` are `i16` steps of `max(|value|) / 32767`, and the viewer expands them with the stored scale. Check values in the component records stay exact. `node_rotation` is not written.

The index is JSON. `geometry_hash` is the structure without parameters, story elevations, or edges framing auto-generation added. A design of a different geometry is refused. `variants` lists each solved parameterization (`params` is a hash and a label per `DesignParameters` field), its summary, and `parts`. A part has a role (`frame`, `shell`, `loads`, `arrows`, `footings`, `solids`, `tributary`) and a map of buffer name to block hash. Frame and shell nodes are numbered locally. The assembled node order is frame parts, then shell parts, each sorted by id. Index buffers in the other parts already use that order. `axes` is the fields whose hash is not constant, each tagged with the element it belongs to (`slab`, `column`, `beam`, `footing`, `wall`, or `none`). A differing field with no tag is an error. The viewer offers a design from an element only when that design differs in that element's axes and in no others.
