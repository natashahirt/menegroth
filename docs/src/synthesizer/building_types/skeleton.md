# BuildingSkeleton

> ```julia
> using StructuralSynthesizer
> using Unitful
> skeleton = gen_medium_office(30.0u"ft", 30.0u"ft", 13.0u"ft", 3, 3, 5)
> length(skeleton.vertices)   # number of grid points
> skeleton.groups_edges[:beams] # indices of beam edges
> skeleton.stories             # Story objects by elevation
> ```

## Overview

`BuildingSkeleton` is the core geometry container for a building's structural layout. It stores the topological mesh — vertices (`Meshes.Point`), edges, and faces — along with spatial indices and precomputed geometric properties. The skeleton is the input to `BuildingStructure` and is immutable during design.

A skeleton represents a building as a half-edge mesh:

- **Vertices** — grid points at column locations and slab corners
- **Edges** — line segments connecting vertices (beams, columns, braces)
- **Faces** — polygonal regions bounded by edges (floor slabs, roof, grade)

## Key Types

```@docs
AbstractBuildingSkeleton
BuildingSkeleton
SkeletonLookup
GeometryCache
```

## Functions

```@docs
add_vertex!
add_element!
rebuild_geometry_cache!
edge_length
face_area
vertex_coords
edge_vertices
face_vertices
is_convex_face
enable_lookup!
build_lookup!
find_vertex
find_edge
find_face
```

## Implementation Details

### Edge Groups

Edges are classified into named groups stored in `groups_edges`:

| Group | Symbol | Description |
|:------|:-------|:------------|
| Beams | `:beams` | Horizontal members connecting column vertices within a story |
| Columns | `:columns` | Vertical members connecting vertices across stories |
| Braces | `:braces` | Diagonal lateral bracing members |

### Face Groups

Faces are classified in `groups_faces`:

| Group | Symbol | Description |
|:------|:-------|:------------|
| Floor | `:floor` | Interior floor slabs |
| Roof | `:roof` | Top-level faces |
| Grade | `:grade` | Ground-level faces (for foundation loading) |

### Spatial Indexing — SkeletonLookup

`SkeletonLookup` provides O(1) lookups for vertices, edges, and faces by their geometric coordinates. It uses hash-based indices (`vertex_index`, `edge_index`, `face_index`) and a `version` counter to detect stale queries. The lookup is enabled with `enable_lookup!` and rebuilt with `build_lookup!`.

### Geometry Cache

`GeometryCache` precomputes and caches:
- `vertex_coords` — raw coordinate tuples for fast access
- `edge_lengths` — span lengths for each edge
- `face_areas` — tributary areas for each face
- `edge_face_counts` — how many faces share each edge (1 = perimeter, 2 = interior)
- `edge_stories` — which story each edge belongs to

### Stories

Stories are inferred from vertex Z coordinates. Each `Story` stores the elevation and the indices of vertices, edges, and faces at that level. Stories are rebuilt automatically via `rebuild_stories!` whenever the skeleton geometry changes.

### Graph Representation

The skeleton maintains a `Graphs.jl` `SimpleGraph` in the `graph` field, where vertices map to skeleton vertices and edges map to skeleton edges. This enables shortest-path queries, connected-component analysis, and neighbor traversal for tributary computation.

## Limitations & Future Work

- Face detection (`find_faces!`) assumes planar, convex polygons. Non-convex or non-planar faces require manual specification or splitting via `validate_and_split_slab`.
- Curved edges (arches, spirals) are not supported; all edges are straight line segments.
