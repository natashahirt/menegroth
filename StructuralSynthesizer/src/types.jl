"""
    types.jl
Centralized type definitions for the StructuralSynthesizer package.
Defines the core data structures and their hierarchies.
"""

# --- Component Structs ---

"""
    Story{T}
Data container for a specific elevation level.
"""
mutable struct Story{T}
    elevation::T
    vertices::Vector{Int}
    edges::Vector{Int}
    faces::Vector{Int}
end

# Convenience constructor
Story{T}(elev::T) where T = Story{T}(elev, Int[], Int[], Int[])

"""
    SlabSection{T, A, P}
BIM and engineering metadata shared by multiple physical slabs.

# Type Parameters
- `T`: Length type (e.g., `typeof(1.0u"m")` or `Float64`)
- `A`: Area type (e.g., `typeof(1.0u"m^2")` or `Float64`)
- `P`: Pressure type (e.g., `typeof(1.0u"kN/m^2")` or `Float64`)
"""
mutable struct SlabSection{T, A, P}
    geometry_hash::UInt64
    thickness::T
    material::Union{Symbol, AbstractMaterial}
    area::A
    slab_type::Symbol
    span_axis::Union{Meshes.Vec{3, T}, Nothing}
    dead_load::P
    live_load::P
end

# Convenience constructor - infers A and P from arguments
function SlabSection(
    hash::UInt64, thickness::T, material, area::A, 
    slab_type::Symbol, span_axis, dead_load::P, live_load::P
) where {T, A, P}
    # Normalize span_axis to match T if needed
    axis = isnothing(span_axis) ? nothing : Meshes.Vec{3, T}(span_axis...)
    SlabSection{T, A, P}(hash, thickness, material, area, slab_type, axis, dead_load, live_load)
end

"""
    Slab{T, A, P}
Individual slab instance linked to a skeleton face.

# Type Parameters
- `T`: Length type (inherited from SlabSection)
- `A`: Area type (inherited from SlabSection)
- `P`: Pressure type (inherited from SlabSection)
"""
mutable struct Slab{T, A, P}
    face_idx::Int
    section::SlabSection{T, A, P}
    beams::Vector{Int}
end

# Convenience constructor - infers types from section
Slab(idx::Int, sec::SlabSection{T, A, P}) where {T, A, P} = Slab{T, A, P}(idx, sec, Int[])

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
    BuildingStructure{T, A, P}
Analytical layer wrapping a BuildingSkeleton.

# Type Parameters
- `T`: Length type from skeleton (e.g., `typeof(1.0u"m")`)
- `A`: Area type for slabs (defaults to `typeof(1.0u"m^2")`)
- `P`: Pressure type for loads (defaults to `typeof(1.0u"kN/m^2")`)
"""
mutable struct BuildingStructure{T, A, P} <: AbstractBuildingStructure
    skeleton::BuildingSkeleton{T}
    slabs::Vector{Slab{T, A, P}}
    slab_sections::Dict{UInt64, SlabSection{T, A, P}}
    asap_model::Asap.Model
end

# Standard constructor using SI defaults for area/pressure
function BuildingStructure(skel::BuildingSkeleton{T}) where T
    # Default area and pressure types based on Constants standards
    A = typeof(1.0u"m^2")
    P = typeof(1.0u"kN/m^2")
    BuildingStructure{T, A, P}(
        skel,
        Slab{T, A, P}[],
        Dict{UInt64, SlabSection{T, A, P}}(),
        Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[])
    )
end

# Explicit constructor for custom unit systems
function BuildingStructure{T, A, P}(skel::BuildingSkeleton{T}) where {T, A, P}
    BuildingStructure{T, A, P}(
        skel,
        Slab{T, A, P}[],
        Dict{UInt64, SlabSection{T, A, P}}(),
        Asap.Model(Asap.Node[], Asap.Element[], Asap.AbstractLoad[])
    )
end
