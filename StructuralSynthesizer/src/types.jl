"""
    types.jl
Centralized type definitions for the StructuralSynthesizer package.
Defines the core data structures and their hierarchies.
"""

# --- Abstract Types ---
abstract type AbstractStructuralSynthesizer end
abstract type AbstractBuildingSkeleton <: AbstractStructuralSynthesizer end

# --- Component Structs ---

"""
    Story{T}
Data container for a specific elevation level.
"""
Base.@kwdef mutable struct Story{T}
    elevation::T
    vertices::Vector{Int} = Int[]
    edges::Vector{Int} = Int[]
    faces::Vector{Int} = Int[]
end

"""
    SlabSection{T}
BIM and engineering metadata shared by multiple physical slabs.
"""
Base.@kwdef mutable struct SlabSection{T}
    geometry_hash::UInt64
    thickness::T
    material::Symbol = :concrete
    area::Unitful.Area
    slab_type::Symbol = :one_way
    span_axis::Union{Meshes.Vec{3, T}, Nothing} = nothing
    dead_load::Unitful.Pressure
    live_load::Unitful.Pressure
end

"""
    Slab{T}
Individual slab instance linked to a skeleton face.
"""
Base.@kwdef mutable struct Slab{T}
    face_idx::Int
    section::SlabSection{T}
    beams::Vector{Int} = Int[]
end

# --- Core Structs ---

"""
    BuildingSkeleton{T}
Geometric and topological representation of a building.
"""
mutable struct BuildingSkeleton{T} <: AbstractBuildingSkeleton
    # Geometry
    vertices::Vector{Meshes.Point}
    edges::Vector{Meshes.Segment}
    faces::Vector{Meshes.Polygon}

    # Topology
    edge_indices::Vector{Tuple{Int, Int}}
    face_vertex_indices::Vector{Vector{Int}}
    face_edge_indices::Vector{Vector{Int}}
    graph::Graphs.SimpleGraph{Int}

    # Groups
    groups_vertices::Dict{Symbol, Vector{Int}}
    groups_edges::Dict{Symbol, Vector{Int}}
    groups_faces::Dict{Symbol, Vector{Int}}

    # Levels
    stories::Dict{Int, Story{T}}
    stories_z::Vector{T}

    # Empty constructor
    function BuildingSkeleton{T}() where T
        new{T}(
            Meshes.Point[], Meshes.Segment[], Meshes.Polygon[],
            Tuple{Int, Int}[], Vector{Int}[], Vector{Int}[],
            Graphs.SimpleGraph(0),
            Dict{Symbol, Vector{Int}}(), Dict{Symbol, Vector{Int}}(), Dict{Symbol, Vector{Int}}(),
            Dict{Int, Story{T}}(), T[]
        )
    end
end

"""
    BuildingStructure{T}
Analytical layer wrapping a BuildingSkeleton.
"""
mutable struct BuildingStructure{T}
    skeleton::BuildingSkeleton{T}
    slabs::Vector{Slab{T}}
    slab_sections::Dict{UInt64, SlabSection{T}}
    asap_model::Asap.Model

    function BuildingStructure(skel::BuildingSkeleton{T}) where T
        new{T}(
            skel,
            Slab{T}[],
            Dict{UInt64, SlabSection{T}}(),
            Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[])
        )
    end
end
