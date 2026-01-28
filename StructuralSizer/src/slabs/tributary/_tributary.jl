# Tributary Area Computation
#
# Edge Tributaries: Straight Skeleton (DCEL) and One-Way Directed
# Vertex Tributaries: Voronoi Tessellation (for column sizing)

include("utils.jl")
include("dcel.jl")
include("isotropic.jl")
include("one_way.jl")
include("spans.jl")
include("voronoi.jl")

# =============================================================================
# Main Dispatch Function
# =============================================================================

"""
    get_tributary_polygons(vertices; weights=nothing, axis=nothing, buffers=nothing)

Compute tributary polygons for each edge of the polygon.

## Arguments
- `vertices::Vector{<:Point}`: Polygon vertices as Meshes.Point objects
- `weights::Union{Nothing, AbstractVector{<:Real}}`: Optional edge weights (one per edge)
- `axis::Union{Nothing, AbstractVector{<:Real}}`: Optional direction vector [vx, vy].
  If `nothing`, uses isotropic straight skeleton. If provided, partitions along that direction.
- `buffers::Union{Nothing, TributaryBuffers}`: Optional pre-allocated buffers to reduce GC.
  Only used for one-way (directed) computation; isotropic skeleton doesn't yet support buffers.

## Examples
```julia
# Isotropic (default)
results = get_tributary_polygons(vertices)

# Isotropic with weights
results = get_tributary_polygons(vertices; weights=[1.0, 2.0, 1.0, 2.0])

# Partition along x-axis
results = get_tributary_polygons(vertices; axis=[1.0, 0.0])

# Directed with weights
results = get_tributary_polygons(vertices; weights=[1.0, 2.0, 1.0, 2.0], axis=[1.0, 0.0])

# Batch processing with buffers (reduced GC)
buffers = TributaryBuffers()
for cell in cells
    results = get_tributary_polygons(verts; axis=[1.0, 0.0], buffers=buffers)
end
```
"""
function get_tributary_polygons(
    vertices::Vector{<:Point};
    weights::Union{Nothing, AbstractVector{<:Real}} = nothing,
    axis::Union{Nothing, AbstractVector{<:Real}} = nothing,
    buffers::Union{Nothing, TributaryBuffers} = nothing
)
    if isnothing(axis) || hypot(axis[1], axis[2]) < 1e-12
        # Isotropic uses DCEL which doesn't yet support buffer reuse
        return get_tributary_polygons_isotropic(vertices; weights=weights)
    else
        return get_tributary_polygons_one_way(vertices; weights=weights, axis=axis, buffers=buffers)
    end
end