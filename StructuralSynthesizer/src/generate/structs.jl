# T can be Float64 (unitless meters) or Unitful.Quantity (units included)
# Default constructor for unitless meters
# StructureSkeleton() = StructureSkeleton{Float64}()
mutable struct StructureSkeleton{T}
    
    # raw geometry
    # three-element vector (always 3d) probably with a unit
    vertices::Vector{Meshes.Point}
    edges::Vector{Meshes.Segment}
    faces::Vector{Meshes.Polygon}

    # categories
    groups_vertices::Dict{Symbol, Vector{Int}} # eg :support => [1,2,4], :beams => [3,5]
    groups_edges::Dict{Symbol, Vector{Int}} # eg :columns => [1,2,4], :beams => [3,5]
    groups_faces::Dict{Symbol, Vector{Int}} # eg :rc_flat => [1,2,4], :steel_deck => [3,5]

    # topology
    graph::Graphs.SimpleGraph{Int}

    StructureSkeleton{T}() where T = new{T}(
        Meshes.Point[], 
        Meshes.Segment[], 
        Meshes.Polygon[], 
        Dict(), 
        Dict(), 
        Dict(), 
        Graphs.SimpleGraph(0)
    )

end