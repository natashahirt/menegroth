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
- `face_areas`: Precomputed `Meshes.measure(face)` per face (with units).
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

"""Geometric and topological representation of a building."""
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
        )
    end
end
