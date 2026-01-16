# Cell grouping for tributary area calculation optimization
#
# Groups geometrically similar cells to avoid duplicate grassfire calculations

"""
    CellGroup

Group of cells with identical normalized geometry and weight ratios.
Tributary fractions computed once can be reused for all cells in the group.
"""
struct CellGroup
    hash::UInt64                       # Hash of canonical form
    cell_indices::Vector{Int}          # Indices of cells in this group
    trib_fractions::Vector{Float64}    # Tributary area fraction per edge (sum = 1.0)
end

CellGroup(hash::UInt64) = CellGroup(hash, Int[], Float64[])

"""
    canonical_form_hash(geometry::CellGeometry, weight_ratios::Vector{Float64}) -> UInt64

Compute a hash of the normalized polygon geometry and weight ratios.
Used to identify cells that will have identical tributary distributions.

Normalization:
1. Scale polygon to unit area
2. Rotate so longest edge is horizontal
3. Translate centroid to origin
4. Combine with weight ratios (relative, not absolute)
"""
function canonical_form_hash(
    geometry::CellGeometry,
    weight_ratios::Vector{Float64},
)::UInt64
    verts = geometry.vertices
    n = length(verts)
    n >= 3 || throw(ArgumentError("Polygon must have at least 3 vertices"))
    
    # 1. Find rotation angle: align longest edge with x-axis
    max_len = 0.0
    max_angle = 0.0
    for i in 1:n
        len = geometry.edge_lengths[i]
        if len > max_len
            max_len = len
            j = mod1(i + 1, n)
            dx = verts[j][1] - verts[i][1]
            dy = verts[j][2] - verts[i][2]
            max_angle = atan(dy, dx)
        end
    end
    
    # 2. Rotate vertices
    cos_a, sin_a = cos(-max_angle), sin(-max_angle)
    rotated = [(v[1] * cos_a - v[2] * sin_a, v[1] * sin_a + v[2] * cos_a) for v in verts]
    
    # 3. Translate centroid to origin
    cx = sum(v[1] for v in rotated) / n
    cy = sum(v[2] for v in rotated) / n
    translated = [(v[1] - cx, v[2] - cy) for v in rotated]
    
    # 4. Scale to unit area
    area = geometry.area
    scale = area > 0 ? 1.0 / sqrt(area) : 1.0
    scaled = [(v[1] * scale, v[2] * scale) for v in translated]
    
    # 5. Quantize to avoid floating point noise
    quantized_verts = [(_quantize(v[1]), _quantize(v[2])) for v in scaled]
    quantized_weights = [_quantize(w) for w in weight_ratios]
    
    # 6. Find canonical starting vertex (lexicographically smallest)
    # This ensures same polygon with different vertex orderings hash the same
    start_idx = _find_canonical_start(quantized_verts)
    
    # Reorder from canonical start
    canonical_verts = circshift(quantized_verts, -(start_idx - 1))
    canonical_weights = circshift(quantized_weights, -(start_idx - 1))
    
    # Compute hash
    return hash((canonical_verts, canonical_weights))
end

"""Quantize a float to reduce precision for hash stability."""
function _quantize(x::Float64, precision::Int=6)::Float64
    factor = 10.0^precision
    return round(x * factor) / factor
end

"""Find lexicographically smallest vertex index for canonical ordering."""
function _find_canonical_start(verts::Vector{NTuple{2, Float64}})::Int
    n = length(verts)
    min_idx = 1
    for i in 2:n
        # Compare lexicographically: first by x, then by y
        if verts[i][1] < verts[min_idx][1] ||
           (verts[i][1] == verts[min_idx][1] && verts[i][2] < verts[min_idx][2])
            min_idx = i
        end
    end
    return min_idx
end

"""
    create_cell_groups(geometries, weight_lists) -> Dict{UInt64, CellGroup}

Group cells by their canonical form hash.
Returns a dictionary mapping hash → CellGroup.

# Arguments
- `geometries::Vector{CellGeometry}`: Geometry for each cell
- `weight_lists::Vector{Vector{Float64}}`: Edge weights for each cell (normalized)
"""
function create_cell_groups(
    geometries::Vector{CellGeometry},
    weight_lists::Vector{Vector{Float64}},
)::Dict{UInt64, CellGroup}
    length(geometries) == length(weight_lists) || 
        throw(ArgumentError("geometries and weight_lists must have same length"))
    
    groups = Dict{UInt64, CellGroup}()
    
    for (cell_idx, (geom, weights)) in enumerate(zip(geometries, weight_lists))
        # Compute weight ratios for hashing
        w_ratios = weight_ratios(weights)
        h = canonical_form_hash(geom, w_ratios)
        
        if !haskey(groups, h)
            groups[h] = CellGroup(h)
        end
        push!(groups[h].cell_indices, cell_idx)
    end
    
    return groups
end

"""
    compute_group_tributaries!(groups, geometries, weight_lists)

Compute tributary fractions for each group (one representative per group).
Stores results in `group.trib_fractions`.
"""
function compute_group_tributaries!(
    groups::Dict{UInt64, CellGroup},
    geometries::Vector{CellGeometry},
    weight_lists::Vector{Vector{Float64}},
)
    for (hash, group) in groups
        isempty(group.cell_indices) && continue
        
        # Use first cell as representative
        rep_idx = first(group.cell_indices)
        geom = geometries[rep_idx]
        weights = weight_lists[rep_idx]
        
        # Compute tributary fractions
        result = grassfire_tributary(geom.vertices, weights)
        
        # Store in group (mutate the struct field)
        empty!(group.trib_fractions)
        append!(group.trib_fractions, result.edge_fractions)
    end
end

"""
    get_cell_tributary_fractions(groups, geometries, cell_idx) -> Vector{Float64}

Get tributary fractions for a specific cell from its group.
The fractions must be remapped to match the cell's edge ordering.
"""
function get_cell_tributary_fractions(
    groups::Dict{UInt64, CellGroup},
    geometries::Vector{CellGeometry},
    weight_lists::Vector{Vector{Float64}},
    cell_idx::Int,
)::Vector{Float64}
    geom = geometries[cell_idx]
    weights = weight_lists[cell_idx]
    w_ratios = weight_ratios(weights)
    h = canonical_form_hash(geom, w_ratios)
    
    group = get(groups, h, nothing)
    if isnothing(group) || isempty(group.trib_fractions)
        # Fallback: compute directly
        result = grassfire_tributary(geom.vertices, weights)
        return result.edge_fractions
    end
    
    # Note: For cells in the same group, tributary fractions are in canonical order
    # We need to remap them to this cell's vertex ordering
    # For now, assume all cells in a group have the same vertex ordering
    # TODO: Add proper remapping if needed
    return copy(group.trib_fractions)
end
