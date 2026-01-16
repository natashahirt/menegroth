# Weighted straight skeleton (grassfire) algorithm for convex polygons
#
# Computes tributary areas for load distribution based on edge weights.
# Higher weight = faster wavefront propagation = larger tributary area.

"""
    TributaryResult

Result of grassfire tributary area calculation for a convex polygon.
"""
struct TributaryResult
    edge_areas::Vector{Float64}      # Tributary area for each edge
    edge_fractions::Vector{Float64}  # area / total_area (sum = 1.0)
    skeleton_vertices::Vector{NTuple{2, Float64}}  # Internal skeleton points
    total_area::Float64
end

"""
    grassfire_tributary(vertices, weights) -> TributaryResult

Compute tributary areas for a convex polygon using weighted straight skeleton.

# Arguments
- `vertices::Vector{NTuple{2, Float64}}`: Polygon vertices in order (CCW preferred)
- `weights::Vector{Float64}`: Normalized weights per edge (should sum to 1.0)

# Returns
- `TributaryResult` with tributary areas and fractions for each edge

Higher-weighted edges get larger tributary areas (they "attract" more load).
"""
function grassfire_tributary(
    vertices::Vector{NTuple{2, Float64}},
    weights::Vector{Float64},
)::TributaryResult
    n = length(vertices)
    n >= 3 || throw(ArgumentError("Polygon must have at least 3 vertices"))
    length(weights) == n || throw(ArgumentError("weights length must match vertex count"))
    
    # Normalize weights if not already
    w_sum = sum(weights)
    w_norm = w_sum > 0 ? weights ./ w_sum : ones(n) ./ n
    
    # For convex polygons, compute weighted straight skeleton
    skeleton_verts, edge_regions = _weighted_skeleton_convex(vertices, w_norm)
    
    # Compute area for each edge's tributary region
    edge_areas = Float64[]
    for region in edge_regions
        push!(edge_areas, polygon_area(region))
    end
    
    total = sum(edge_areas)
    fractions = total > 0 ? edge_areas ./ total : ones(n) ./ n
    
    return TributaryResult(edge_areas, fractions, skeleton_verts, total)
end

"""
Compute weighted straight skeleton for a convex polygon.
Returns skeleton vertices and tributary region polygons for each edge.
"""
function _weighted_skeleton_convex(
    vertices::Vector{NTuple{2, Float64}},
    weights::Vector{Float64},
)
    n = length(vertices)
    
    # Compute edge unit normals (inward pointing)
    normals = _compute_inward_normals(vertices)
    
    # Compute weighted bisector directions at each vertex
    bisectors = _compute_weighted_bisectors(vertices, normals, weights)
    
    # Find skeleton center (intersection of bisectors)
    # For convex polygons, all bisectors meet at a single point (or small region)
    center = _find_skeleton_center(vertices, bisectors)
    
    # Build tributary regions: each edge gets a quadrilateral (or triangle)
    # from edge endpoints to the skeleton center
    edge_regions = Vector{NTuple{2, Float64}}[]
    for i in 1:n
        j = mod1(i + 1, n)
        # Region for edge i: vertices[i] -> vertices[j] -> center -> back
        # This forms a triangle from the edge to the center
        region = [vertices[i], vertices[j], center]
        push!(edge_regions, region)
    end
    
    return [center], edge_regions
end

"""Compute inward-pointing unit normals for each edge."""
function _compute_inward_normals(vertices::Vector{NTuple{2, Float64}})
    n = length(vertices)
    normals = NTuple{2, Float64}[]
    
    # Compute polygon centroid for direction reference
    cx = sum(v[1] for v in vertices) / n
    cy = sum(v[2] for v in vertices) / n
    
    for i in 1:n
        j = mod1(i + 1, n)
        
        # Edge vector
        dx = vertices[j][1] - vertices[i][1]
        dy = vertices[j][2] - vertices[i][2]
        len = sqrt(dx^2 + dy^2)
        
        if len > 1e-12
            # Perpendicular (rotate 90°): (-dy, dx) or (dy, -dx)
            nx, ny = -dy / len, dx / len
            
            # Check if pointing inward (toward centroid)
            mid_x = (vertices[i][1] + vertices[j][1]) / 2
            mid_y = (vertices[i][2] + vertices[j][2]) / 2
            to_center_x = cx - mid_x
            to_center_y = cy - mid_y
            
            # Flip if pointing outward
            if nx * to_center_x + ny * to_center_y < 0
                nx, ny = -nx, -ny
            end
            
            push!(normals, (nx, ny))
        else
            push!(normals, (0.0, 0.0))
        end
    end
    
    return normals
end

"""
Compute weighted bisector direction at each vertex.
The bisector direction accounts for different edge weights (propagation speeds).
"""
function _compute_weighted_bisectors(
    vertices::Vector{NTuple{2, Float64}},
    normals::Vector{NTuple{2, Float64}},
    weights::Vector{Float64},
)
    n = length(vertices)
    bisectors = NTuple{2, Float64}[]
    
    for i in 1:n
        # Edges meeting at vertex i: edge (i-1) ending here, edge i starting here
        prev_edge = mod1(i - 1, n)
        curr_edge = i
        
        n1 = normals[prev_edge]
        n2 = normals[curr_edge]
        w1 = weights[prev_edge]
        w2 = weights[curr_edge]
        
        # Weighted bisector: combination of normals scaled by weights
        # Higher weight means faster propagation → bisector tilts toward that edge
        bx = w1 * n1[1] + w2 * n2[1]
        by = w1 * n1[2] + w2 * n2[2]
        
        mag = sqrt(bx^2 + by^2)
        if mag > 1e-12
            push!(bisectors, (bx / mag, by / mag))
        else
            # Fallback: average of normals
            push!(bisectors, ((n1[1] + n2[1]) / 2, (n1[2] + n2[2]) / 2))
        end
    end
    
    return bisectors
end

"""
Find the skeleton center by intersecting weighted bisector rays.
For convex polygons with uniform weights, this is the medial axis center.
"""
function _find_skeleton_center(
    vertices::Vector{NTuple{2, Float64}},
    bisectors::Vector{NTuple{2, Float64}},
)
    n = length(vertices)
    
    # Use least squares to find best intersection point of all bisector rays
    # Each ray: P_i + t * B_i, we want the point minimizing distance to all rays
    
    # Collect intersection candidates from pairs of rays
    candidates = NTuple{2, Float64}[]
    
    for i in 1:n
        for j in (i+1):n
            pt = _ray_intersection(
                vertices[i], bisectors[i],
                vertices[j], bisectors[j]
            )
            if !isnothing(pt)
                push!(candidates, pt)
            end
        end
    end
    
    if isempty(candidates)
        # Fallback: use centroid
        cx = sum(v[1] for v in vertices) / n
        cy = sum(v[2] for v in vertices) / n
        return (cx, cy)
    end
    
    # Average of valid intersection points (inside polygon)
    valid = filter(p -> _point_in_convex_polygon(p, vertices), candidates)
    
    if isempty(valid)
        # Use centroid as fallback
        cx = sum(v[1] for v in vertices) / n
        cy = sum(v[2] for v in vertices) / n
        return (cx, cy)
    end
    
    avg_x = sum(p[1] for p in valid) / length(valid)
    avg_y = sum(p[2] for p in valid) / length(valid)
    return (avg_x, avg_y)
end

"""Compute intersection of two rays: P1 + t*D1 and P2 + s*D2."""
function _ray_intersection(
    p1::NTuple{2, Float64}, d1::NTuple{2, Float64},
    p2::NTuple{2, Float64}, d2::NTuple{2, Float64},
)
    # Solve: P1 + t*D1 = P2 + s*D2
    # t*D1.x - s*D2.x = P2.x - P1.x
    # t*D1.y - s*D2.y = P2.y - P1.y
    
    det = d1[1] * (-d2[2]) - d1[2] * (-d2[1])
    
    if abs(det) < 1e-12
        return nothing  # Parallel rays
    end
    
    dx = p2[1] - p1[1]
    dy = p2[2] - p1[2]
    
    t = (dx * (-d2[2]) - dy * (-d2[1])) / det
    
    # Only consider forward intersections (t > 0)
    if t < 0
        return nothing
    end
    
    return (p1[1] + t * d1[1], p1[2] + t * d1[2])
end

"""Check if a point is inside a convex polygon."""
function _point_in_convex_polygon(
    pt::NTuple{2, Float64},
    vertices::Vector{NTuple{2, Float64}},
)
    n = length(vertices)
    
    for i in 1:n
        j = mod1(i + 1, n)
        
        # Cross product to determine which side of edge the point is on
        edge_x = vertices[j][1] - vertices[i][1]
        edge_y = vertices[j][2] - vertices[i][2]
        to_pt_x = pt[1] - vertices[i][1]
        to_pt_y = pt[2] - vertices[i][2]
        
        cross = edge_x * to_pt_y - edge_y * to_pt_x
        
        # For CCW polygon, point should be on left (positive cross) for all edges
        # Allow small tolerance for points on the boundary
        if cross < -1e-10
            return false
        end
    end
    
    return true
end
