# =============================================================================
# Skeleton Lookup (for O(1) vertex/edge/face queries)
# =============================================================================

const COORD_DIGITS = 6  # Rounding precision for coordinate hashing

"""
    SkeletonLookup

Cached lookup indices for O(1) vertex/edge/face queries on a BuildingSkeleton.
Stored in `skel.lookup` and automatically used by `add_vertex!`, `add_element!`, etc.

Enable with `enable_lookup!(skel)` before building, or `build_lookup!(skel)` after.
"""
mutable struct SkeletonLookup
    vertex_index::Dict{NTuple{3, Float64}, Int}
    edge_index::Dict{Tuple{Int, Int}, Int}
    face_index::Dict{Vector{Int}, Int}
    version::Int
end

"""Create an empty `SkeletonLookup` with no cached indices."""
SkeletonLookup() = SkeletonLookup(
    Dict{NTuple{3, Float64}, Int}(),
    Dict{Tuple{Int, Int}, Int}(),
    Dict{Vector{Int}, Int}(),
    0
)

"""
    GeometryCache

Precomputed geometric properties for a BuildingSkeleton.

Built once by `rebuild_geometry_cache!(skel)` after the skeleton is fully populated
(i.e. after `find_faces!`). All downstream code should read from the cache instead of
calling `Meshes.measure` / `Meshes.coords` repeatedly.

# Fields
- `vertex_coords`: N×3 `Float64` matrix of (x,y,z) in meters — the single source of
  truth for coordinate lookups.
- `edge_lengths`: Precomputed `Meshes.measure(edge)` per edge (with units).
- `face_areas`: Plan area of each face (with units), from the shoelace of its
  vertices. A `Meshes` measure of an `Ngon` fans triangles from the first
  vertex and is wrong for a concave quad.
- `edge_face_counts`: Edge index → number of adjacent faces (boundary edges have 1).
- `edge_stories`: Edge index → story index (0-based).
"""
struct GeometryCache{L, A}
    vertex_coords::Matrix{Float64}
    edge_lengths::Vector{L}
    face_areas::Vector{A}
    edge_face_counts::Dict{Int, Int}
    edge_stories::Dict{Int, Int}
end

"""
    SlabOpening(story, loop, framing=:auto)

An opening through the slab on one story: a stair, duct, or shaft.

`framing` says what happens on a beam-supported floor (one-way, composite
deck, joists, or two-way with beams):

- `:auto` — a rectangle aligned with the span axis is framed. Trimmers run
  parallel to the span, from support to support, beside the opening. Headers
  run perpendicular to the span, between the trimmers. Anything else is left
  unframed and checked as a cantilever.
- `:opening_axes` — frame along the opening's own edges, even when they are
  skewed to the span. A trimmer that meets no beam refuses that opening. A
  non-rectangular opening is framed by the rectangle around it.
- `:none` — leave it unframed.

The opening record stays either way, so the face inside a frame is a void and
its area is subtracted once.

# Fields
- `story::Int`: Story level index (a key of `skel.stories`, 0-based)
- `loop::Vector{NTuple{2, Float64}}`: Plan outline in meters
- `framing::Symbol`: `:auto`, `:opening_axes`, or `:none`
"""
struct SlabOpening
    story::Int
    loop::Vector{NTuple{2, Float64}}
    framing::Symbol
    function SlabOpening(story::Integer, loop, framing::Symbol=:auto)
        framing in (:auto, :opening_axes, :none) || throw(ArgumentError(
            "opening framing is :auto, :opening_axes, or :none; got :$framing"))
        new(Int(story), Vector{NTuple{2, Float64}}(loop), framing)
    end
end

"""
Geometric and topological representation of a building.

`openings` holds the [`SlabOpening`](@ref)s; see [`face_openings`](@ref) for the
openings that overlap one face.

`face_holes` maps a face to the plan outlines (meters, counterclockwise) of the
beam networks that sit inside it without touching its boundary, such as a ring
of beams around an atrium. [`find_faces!`](@ref) fills it. The nested network
has faces of its own, so the hole is the outer face's void, not an opening in
the slab inside the ring. `face_hole_vertices` holds the same loops as skeleton
vertex indices, in the same order, so ribs can land on the ring's members.

# Edge groups (`groups_edges`)
`groups_edges::Dict{Symbol, Vector{Int}}` maps a group name to the edge indices
in that group (used for member grouping, e.g. `:beams`, `:columns`). Symbol keys
are arbitrary. These names are reserved:

- `:joists` — auto-generated **level-1** members (joists that directly support
  the slab), produced from a slab's [`FramingLevel`](@ref)s.
- `:secondary` — auto-generated **level-2+** members (secondary beams and
  deeper framing levels).
- `:absent` — an edge that stays in the skeleton and keeps its frame slot,
  but is not a member. `to_asap!` gives it a zero section. Move the index
  back into `:columns`, `:beams`, `:braces`, or `:walls` to restore it.

`:joists` and `:secondary` are **populated only by Phase 5's `materialize_level!`** (which
also inserts the joist landings as skeleton vertices via `edge_chains`). Nothing
in Phase 4 writes to them — the names are reserved here so downstream code can
rely on the convention. Do not repurpose `:joists` / `:secondary` for manually
defined members.
"""
mutable struct BuildingSkeleton{T} <: AbstractBuildingSkeleton
    vertices::Vector{Meshes.Point}
    edges::Vector{Meshes.Segment}
    faces::Vector{Meshes.Polygon}
    edge_indices::Vector{Tuple{Int, Int}}
    face_vertex_indices::Vector{Vector{Int}}
    face_edge_indices::Vector{Vector{Int}}
    graph::Graphs.SimpleGraph{Int}
    groups_vertices::Dict{Symbol, Vector{Int}}
    groups_edges::Dict{Symbol, Vector{Int}}
    groups_faces::Dict{Symbol, Vector{Int}}
    stories::Dict{Int, Story{T}}
    stories_z::Vector{T}
    # O(1) lookup tables (optional, enable with enable_lookup! or build_lookup!)
    lookup::Union{SkeletonLookup, Nothing}
    # Precomputed geometry (populated by rebuild_geometry_cache!)
    geometry::Union{GeometryCache, Nothing}
    # Edge chains: maps a chain ID → ordered vector of edge indices that form
    # one continuous member (populated by shatter logic in the API layer).
    # When empty, each edge is its own chain (1:1 mapping, the default).
    edge_chains::Dict{UInt64, Vector{Int}}
    openings::Vector{SlabOpening}
    face_holes::Dict{Int, Vector{Vector{NTuple{2, Float64}}}}
    face_hole_vertices::Dict{Int, Vector{Vector{Int}}}
    # Rectangular holes in wall edges, one spec per story. Copied onto `Wall`
    # by `initialize_members!`. See `add_wall_opening!`.
    wall_openings::Vector{WallOpeningSpec}

    """Construct an empty `BuildingSkeleton` with no vertices, edges, faces, or lookup tables."""
    function BuildingSkeleton{T}() where T
        new{T}(
            Meshes.Point[], Meshes.Segment[], Meshes.Polygon[],
            Tuple{Int, Int}[], Vector{Int}[], Vector{Int}[],
            Graphs.SimpleGraph(0),
            Dict{Symbol, Vector{Int}}(), Dict{Symbol, Vector{Int}}(), Dict{Symbol, Vector{Int}}(),
            Dict{Int, Story{T}}(), T[],
            nothing,  # lookup disabled by default
            nothing,  # geometry cache not yet built
            Dict{UInt64, Vector{Int}}(),  # edge_chains (empty = no shattering)
            SlabOpening[],
            Dict{Int, Vector{Vector{NTuple{2, Float64}}}}(),
            Dict{Int, Vector{Vector{Int}}}(),
            WallOpeningSpec[],
        )
    end
end
