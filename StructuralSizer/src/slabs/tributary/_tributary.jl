# Tributary load distribution module
#
# Computes how slab loads distribute to supporting beams using
# weighted straight skeleton (grassfire) algorithm.

# Core modules (order matters: geometry → weights → grassfire → grouping → discretize)
include("geometry.jl")
include("weights.jl")
include("grassfire.jl")
include("grouping.jl")
include("discretize.jl")

# =============================================================================
# Main Interface
# =============================================================================

"""
    distribute_cell_loads(geometry, total_force; weights=nothing, strategy=WEIGHT_UNIFORM, n_points=5) -> Vector{EdgeLoadResult}

Compute tributary load distribution for a single cell (bay).

# Arguments
- `geometry::CellGeometry`: Cell polygon geometry with vertices and edge indices
- `total_force::NTuple{3, Float64}`: Total force (Fx, Fy, Fz) to distribute [N]

# Keyword Arguments
- `weights::Union{Nothing, Vector{Float64}}`: Pre-computed edge weights (normalized)
- `strategy::WeightStrategy`: Weight computation strategy if weights not provided
- `n_points::Int`: Number of point loads per edge (default 5)

# Returns
Vector of `EdgeLoadResult` with point loads for each edge.
"""
function distribute_cell_loads(
    geometry::CellGeometry,
    total_force::NTuple{3, Float64};
    weights::Union{Nothing, AbstractVector{<:Real}} = nothing,
    strategy::WeightStrategy = WEIGHT_UNIFORM,
    n_points::Int = 5,
)::Vector{EdgeLoadResult}
    # Compute weights if not provided
    w = if isnothing(weights)
        compute_edge_weights(strategy, geometry.edge_lengths)
    else
        # Normalize provided weights
        w_arr = Float64.(weights)
        w_sum = sum(w_arr)
        w_sum > 0 ? w_arr ./ w_sum : ones(length(w_arr)) ./ length(w_arr)
    end
    
    # Compute tributary fractions
    result = grassfire_tributary(geometry.vertices, w)
    
    # Discretize into point loads
    return discretize_tributary_loads(geometry, result.edge_fractions, total_force; n_points=n_points)
end

"""
    distribute_cell_loads_grouped(geometries, total_forces; strategy=WEIGHT_UNIFORM, n_points=5) -> Vector{Vector{EdgeLoadResult}}

Compute tributary loads for multiple cells with deduplication via grouping.

# Arguments
- `geometries::Vector{CellGeometry}`: Geometry for each cell
- `total_forces::Vector{NTuple{3, Float64}}`: Total force for each cell

# Returns
Vector of `Vector{EdgeLoadResult}`, one per cell.
"""
function distribute_cell_loads_grouped(
    geometries::Vector{CellGeometry},
    total_forces::Vector{NTuple{3, Float64}};
    strategy::WeightStrategy = WEIGHT_UNIFORM,
    n_points::Int = 5,
)::Vector{Vector{EdgeLoadResult}}
    n = length(geometries)
    n == length(total_forces) || throw(ArgumentError("geometries and total_forces must have same length"))
    n > 0 || return Vector{EdgeLoadResult}[]
    
    # Compute weights for all cells
    weight_lists = [compute_edge_weights(strategy, g.edge_lengths) for g in geometries]
    
    # Create cell groups
    groups = create_cell_groups(geometries, weight_lists)
    
    # Compute tributaries for each group (once per unique geometry)
    compute_group_tributaries!(groups, geometries, weight_lists)
    
    # Apply to each cell
    results = Vector{EdgeLoadResult}[]
    for (i, (geom, force)) in enumerate(zip(geometries, total_forces))
        fracs = get_cell_tributary_fractions(groups, geometries, weight_lists, i)
        loads = discretize_tributary_loads(geom, fracs, force; n_points=n_points)
        push!(results, loads)
    end
    
    return results
end

# =============================================================================
# Legacy Interface (for backward compatibility)
# =============================================================================

"""
    distribute_slab_loads(beam_ids, total_force; xs=[0.5])

Legacy interface: distribute total_force evenly across beam_ids.

Returns a vector of NamedTuples: `(beam_id, xs, F)`.
For tributary-based distribution, use `distribute_cell_loads` instead.
"""
function distribute_slab_loads(
    beam_ids::AbstractVector{<:Integer},
    total_force::NTuple{3, Float64};
    xs::AbstractVector{<:Real} = [0.5],
)
    n_beams = length(beam_ids)
    n_beams > 0 || return NamedTuple[]

    Fx, Fy, Fz = total_force
    scale = 1.0 / n_beams
    f_per = (Fx * scale, Fy * scale, Fz * scale)

    xs_vec = Float64.(xs)
    n_pts = length(xs_vec)

    return [
        (beam_id = Int(b), xs = xs_vec, F = fill(f_per ./ n_pts, n_pts))
        for b in beam_ids
    ]
end
