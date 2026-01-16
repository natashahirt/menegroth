# Discretization of tributary areas into point loads
#
# Converts tributary area fractions to point load specifications

"""
    EdgeLoadResult

Point loads for a single edge from tributary area calculation.
"""
struct EdgeLoadResult
    edge_idx::Int
    xs::Vector{Float64}           # Normalized positions [0, 1]
    forces::Vector{NTuple{3, Float64}}  # (Fx, Fy, Fz) at each position
end

"""
    discretize_tributary_loads(geometry, trib_fractions, total_force; n_points=5) -> Vector{EdgeLoadResult}

Convert tributary fractions to discretized point loads along each edge.

# Arguments
- `geometry::CellGeometry`: Cell polygon geometry with edge indices
- `trib_fractions::Vector{Float64}`: Tributary area fraction per edge (sum ≈ 1.0)
- `total_force::NTuple{3, Float64}`: Total force (Fx, Fy, Fz) to distribute
- `n_points::Int`: Number of point loads per edge (default 5)

# Returns
Vector of `EdgeLoadResult`, one per edge, with point loads distributed along each edge.
"""
function discretize_tributary_loads(
    geometry::CellGeometry,
    trib_fractions::Vector{Float64},
    total_force::NTuple{3, Float64};
    n_points::Int = 5,
)::Vector{EdgeLoadResult}
    n = length(geometry.edge_indices)
    length(trib_fractions) == n || throw(ArgumentError("trib_fractions length must match edge count"))
    n_points >= 1 || throw(ArgumentError("n_points must be at least 1"))
    
    results = EdgeLoadResult[]
    
    for i in 1:n
        edge_idx = geometry.edge_indices[i]
        frac = trib_fractions[i]
        
        # Force for this edge
        edge_force = (total_force[1] * frac, total_force[2] * frac, total_force[3] * frac)
        
        # Distribute along edge
        xs, forces = _distribute_along_edge(edge_force, n_points)
        
        push!(results, EdgeLoadResult(edge_idx, xs, forces))
    end
    
    return results
end

"""
Distribute a force evenly along an edge as point loads.
"""
function _distribute_along_edge(
    total_force::NTuple{3, Float64},
    n_points::Int,
)::Tuple{Vector{Float64}, Vector{NTuple{3, Float64}}}
    if n_points == 1
        # Single point at midspan
        return [0.5], [total_force]
    end
    
    # Evenly spaced points, avoiding exact endpoints (x=0, x=1)
    # Use trapezoidal-like spacing
    offset = 0.5 / n_points  # Start/end offset from edge endpoints
    xs = [offset + (1.0 - 2*offset) * (i - 1) / (n_points - 1) for i in 1:n_points]
    
    # Force per point
    f_per = (total_force[1] / n_points, total_force[2] / n_points, total_force[3] / n_points)
    forces = fill(f_per, n_points)
    
    return xs, forces
end

"""
    discretize_uniform_loads(edge_indices, total_force; n_points=5) -> Vector{EdgeLoadResult}

Simple uniform distribution (fallback when no tributary calculation needed).
Distributes total_force evenly across all edges.
"""
function discretize_uniform_loads(
    edge_indices::Vector{Int},
    total_force::NTuple{3, Float64};
    n_points::Int = 5,
)::Vector{EdgeLoadResult}
    n = length(edge_indices)
    n > 0 || return EdgeLoadResult[]
    
    # Equal fraction per edge
    frac = 1.0 / n
    edge_force = (total_force[1] * frac, total_force[2] * frac, total_force[3] * frac)
    
    results = EdgeLoadResult[]
    for edge_idx in edge_indices
        xs, forces = _distribute_along_edge(edge_force, n_points)
        push!(results, EdgeLoadResult(edge_idx, xs, forces))
    end
    
    return results
end

"""
    merge_edge_loads(load_lists::Vector{Vector{EdgeLoadResult}}) -> Vector{EdgeLoadResult}

Merge point loads from multiple cells that share edges.
Combines loads at the same edge by summing forces at each position.
"""
function merge_edge_loads(load_lists::Vector{Vector{EdgeLoadResult}})::Vector{EdgeLoadResult}
    # Group by edge index
    edge_map = Dict{Int, Vector{EdgeLoadResult}}()
    
    for loads in load_lists
        for load in loads
            if !haskey(edge_map, load.edge_idx)
                edge_map[load.edge_idx] = EdgeLoadResult[]
            end
            push!(edge_map[load.edge_idx], load)
        end
    end
    
    # Merge loads for each edge
    merged = EdgeLoadResult[]
    for (edge_idx, edge_loads) in sort(collect(edge_map), by=first)
        if length(edge_loads) == 1
            push!(merged, only(edge_loads))
        else
            # Combine loads: assume same xs positions
            xs = edge_loads[1].xs
            n_pts = length(xs)
            
            # Sum forces at each position
            combined_forces = [
                (sum(el.forces[j][1] for el in edge_loads if length(el.forces) >= j),
                 sum(el.forces[j][2] for el in edge_loads if length(el.forces) >= j),
                 sum(el.forces[j][3] for el in edge_loads if length(el.forces) >= j))
                for j in 1:n_pts
            ]
            
            push!(merged, EdgeLoadResult(edge_idx, xs, combined_forces))
        end
    end
    
    return merged
end
