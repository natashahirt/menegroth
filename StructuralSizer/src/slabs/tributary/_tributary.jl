# Tributary Area Computation (Straight Skeleton via DCEL and One-Way Directed)

include("utils.jl")
include("dcel.jl")
include("isotropic.jl")
include("one_way.jl")

# =============================================================================
# Main Dispatch Function
# =============================================================================

"""
    get_tributary_polygons(vertices::Vector{<:Point}; weights=nothing, axis=nothing)

Compute tributary polygons for each edge of the polygon.

## Arguments
- `vertices`: Polygon vertices as Meshes.Point objects
- `weights`: Optional vector of edge weights (one per edge)
- `axis`: Optional direction vector [vx, vy]. If `nothing`, uses isotropic straight skeleton.
  If provided, partitions along that direction using bidirectional weighted distance.

## Examples
```julia
# Isotropic (default)
results = get_tributary_polygons(vertices)

# Isotropic with weights
results = get_tributary_polygons(vertices; weights=[1.0, 2.0, 1.0, 2.0])

# Partition along x-axis
results = get_tributary_polygons(vertices; axis=[1.0, 0.0])

# Partition along arbitrary direction
results = get_tributary_polygons(vertices; axis=[1.0, 1.5])

# Directed with weights
results = get_tributary_polygons(vertices; weights=[1.0, 2.0, 1.0, 2.0], axis=[1.0, 0.0])
```
"""
function get_tributary_polygons(vertices::Vector{<:Point}; weights=nothing, axis=nothing)
    if isnothing(axis)
        return get_tributary_polygons_isotropic(vertices; weights=weights)
    else
        return get_tributary_polygons_one_way(vertices; weights=weights, axis=axis)
    end
end