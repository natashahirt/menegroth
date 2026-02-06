# =============================================================================
# Slab Geometry Validation
# =============================================================================
#
# Functions to validate slab cell groupings for DDM/EFM analysis:
# - Rectangular decomposition of concave regions
# - Cell adjacency and connectivity
#
# Note: Convexity checking is provided by Asap.is_convex_polygon
# and the convenience wrapper is_convex_face in utils_building_skeleton.jl
#
# =============================================================================

using Logging

# Re-export Asap's is_convex_polygon for convenience
const is_convex_polygon = Asap.is_convex_polygon

# =============================================================================
# Cell Grid Operations
# =============================================================================

"""
    CellGrid

A 2D grid representation of cells for rectangular decomposition.
"""
struct CellGrid
    grid::Matrix{Int}        # grid[row, col] = cell_idx or 0
    cell_positions::Dict{Int, Tuple{Int, Int}}  # cell_idx → (row, col)
    row_coords::Vector{Float64}  # Y coordinates of row centers
    col_coords::Vector{Float64}  # X coordinates of column centers
end

"""
    build_cell_grid(cell_indices, get_centroid_fn) -> CellGrid

Build a grid representation of cells based on their centroid positions.

# Arguments
- `cell_indices`: Vector of cell indices to include
- `get_centroid_fn(idx)`: Function returning (x, y) centroid of cell

# Returns
- `CellGrid` with cells mapped to grid positions
"""
function build_cell_grid(cell_indices::Vector{Int}, get_centroid_fn::Function)
    isempty(cell_indices) && error("Cannot build grid from empty cell list")
    
    # Get centroids
    centroids = Dict(idx => get_centroid_fn(idx) for idx in cell_indices)
    
    # Find unique X and Y coordinates (with tolerance for floating point)
    xs = sort(unique([round(c[1], digits=4) for c in values(centroids)]))
    ys = sort(unique([round(c[2], digits=4) for c in values(centroids)]))
    
    # Map coordinates to grid indices
    x_to_col = Dict(x => i for (i, x) in enumerate(xs))
    y_to_row = Dict(y => i for (i, y) in enumerate(ys))
    
    # Build grid
    n_rows = length(ys)
    n_cols = length(xs)
    grid = zeros(Int, n_rows, n_cols)
    cell_positions = Dict{Int, Tuple{Int, Int}}()
    
    for (idx, (x, y)) in centroids
        x_round = round(x, digits=4)
        y_round = round(y, digits=4)
        col = x_to_col[x_round]
        row = y_to_row[y_round]
        grid[row, col] = idx
        cell_positions[idx] = (row, col)
    end
    
    return CellGrid(grid, cell_positions, ys, xs)
end

# =============================================================================
# Rectangular Decomposition
# =============================================================================

"""
    decompose_to_rectangles(cell_indices, get_centroid_fn) -> Vector{Vector{Int}}

Decompose a potentially concave cell group into rectangular subgroups.

Uses a greedy maximal-rectangle algorithm: repeatedly finds the largest
axis-aligned rectangle and removes it from the remaining cells.

# Arguments
- `cell_indices`: Vector of cell indices to decompose
- `get_centroid_fn(idx)`: Function returning (x, y) centroid of cell

# Returns
- Vector of cell index groups, each forming a rectangular region
"""
function decompose_to_rectangles(
    cell_indices::Vector{Int}, 
    get_centroid_fn::Function
)
    isempty(cell_indices) && return Vector{Int}[]
    length(cell_indices) == 1 && return [cell_indices]
    
    # Build grid representation
    grid_data = build_cell_grid(cell_indices, get_centroid_fn)
    
    remaining = Set(cell_indices)
    rectangles = Vector{Int}[]
    
    while !isempty(remaining)
        # Find maximal rectangle starting from first remaining cell
        seed = first(remaining)
        rect = _find_maximal_rectangle(seed, remaining, grid_data)
        
        push!(rectangles, rect)
        setdiff!(remaining, rect)
    end
    
    return rectangles
end

"""
Find the maximal axis-aligned rectangle containing the seed cell.
Uses greedy expansion in all four directions.
"""
function _find_maximal_rectangle(
    seed_idx::Int, 
    available::Set{Int}, 
    grid_data::CellGrid
)
    grid = grid_data.grid
    n_rows, n_cols = size(grid)
    
    # Get seed position
    seed_pos = grid_data.cell_positions[seed_idx]
    min_row, max_row = seed_pos[1], seed_pos[1]
    min_col, max_col = seed_pos[2], seed_pos[2]
    
    # Greedy expansion
    changed = true
    while changed
        changed = false
        
        # Try expand right
        if max_col < n_cols && _all_in_range_available(grid, min_row:max_row, max_col+1:max_col+1, available)
            max_col += 1
            changed = true
        end
        
        # Try expand left
        if min_col > 1 && _all_in_range_available(grid, min_row:max_row, min_col-1:min_col-1, available)
            min_col -= 1
            changed = true
        end
        
        # Try expand down (higher row index)
        if max_row < n_rows && _all_in_range_available(grid, max_row+1:max_row+1, min_col:max_col, available)
            max_row += 1
            changed = true
        end
        
        # Try expand up (lower row index)
        if min_row > 1 && _all_in_range_available(grid, min_row-1:min_row-1, min_col:max_col, available)
            min_row -= 1
            changed = true
        end
    end
    
    # Collect all cells in the rectangle
    rect_cells = Int[]
    for r in min_row:max_row, c in min_col:max_col
        idx = grid[r, c]
        if idx != 0 && idx in available
            push!(rect_cells, idx)
        end
    end
    
    return rect_cells
end

"""
Check if all cells in the given grid range are available.
"""
function _all_in_range_available(
    grid::Matrix{Int}, 
    rows::UnitRange{Int}, 
    cols::UnitRange{Int}, 
    available::Set{Int}
)
    for r in rows, c in cols
        idx = grid[r, c]
        # Must have a cell AND be available
        if idx == 0 || !(idx in available)
            return false
        end
    end
    return true
end

# =============================================================================
# Connectivity-Based Grouping
# =============================================================================

"""
    group_by_connectivity(cell_indices, get_neighbors_fn) -> Vector{Vector{Int}}

Group cells into connected components based on adjacency.

# Arguments
- `cell_indices`: Set or Vector of cell indices
- `get_neighbors_fn(idx)`: Function returning vector of adjacent cell indices

# Returns
- Vector of cell groups, where each group is a connected component
"""
function group_by_connectivity(
    cell_indices::Union{Set{Int}, Vector{Int}},
    get_neighbors_fn::Function
)
    remaining = Set(cell_indices)
    groups = Vector{Int}[]
    
    while !isempty(remaining)
        # Flood-fill from arbitrary seed
        seed = first(remaining)
        group = Int[]
        queue = [seed]
        
        while !isempty(queue)
            idx = popfirst!(queue)
            idx in remaining || continue
            
            push!(group, idx)
            delete!(remaining, idx)
            
            # Add adjacent cells that are in our set
            for neighbor in get_neighbors_fn(idx)
                if neighbor in remaining
                    push!(queue, neighbor)
                end
            end
        end
        
        push!(groups, group)
    end
    
    return groups
end

# =============================================================================
# Slab Validation Entry Point
# =============================================================================

"""
    validate_and_split_slab(cell_indices, get_centroid_fn, get_boundary_fn) -> Vector{Vector{Int}}

Validate slab geometry and split into rectangular groups if concave.

# Arguments
- `cell_indices`: Vector of cell indices forming the slab
- `get_centroid_fn(idx)`: Function returning (x, y) centroid of cell
- `get_boundary_fn(indices)`: Function returning boundary polygon as vector of (x,y) points

# Returns
- Vector of cell index groups (single group if convex, multiple if split)
"""
function validate_and_split_slab(
    cell_indices::Vector{Int},
    get_centroid_fn::Function,
    get_boundary_fn::Function
)
    isempty(cell_indices) && return Vector{Int}[]
    length(cell_indices) == 1 && return [cell_indices]
    
    # Get merged boundary polygon
    boundary = get_boundary_fn(cell_indices)
    
    # Check convexity
    if is_convex_polygon(boundary)
        return [cell_indices]  # No split needed
    end
    
    # Warn and decompose
    @warn "Slab cells form a concave region. Splitting into rectangular groups for DDM/EFM analysis." cell_indices
    
    return decompose_to_rectangles(cell_indices, get_centroid_fn)
end

# =============================================================================
# Exports
# =============================================================================

# Note: Exports are handled in the main module file
