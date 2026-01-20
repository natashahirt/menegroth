# =============================================================================
# Straight Skeleton for Convex Polygons (Isotropic Tributary Areas)
# =============================================================================

"""
    get_tributary_polygons_isotropic(vertices::Vector{<:Point})

Compute tributary polygons for each edge using straight skeleton (wavefront) algorithm.
Returns Vector{TributaryResult}, one per original edge.

For convex polygons only—no split events handled.
"""
function get_tributary_polygons_isotropic(vertices::Vector{<:Point})
    n = length(vertices)
    n >= 3 || return TributaryResult[]
    
    # Convert to simple 2D coords (strip units, work in meters)
    pts = [_to_2d(v) for v in vertices]
    original_pts = copy(pts)
    
    # Warn if non-convex (algorithm only handles convex polygons correctly)
    if !_is_convex(pts)
        @warn "Non-convex polygon detected — tributary areas will be incorrect (split events not implemented)"
    end
    
    # Track edges at each wavefront level
    # edge_levels[level] = vector of edges, where edge[i] = (start_pt, end_pt)
    edge_levels = Vector{Vector{NTuple{2, NTuple{2,Float64}}}}()
    
    # Initial edges (level 0) - edge i goes from vertex i to vertex i+1
    initial_edges = [(pts[i], pts[mod1(i + 1, n)]) for i in 1:n]
    push!(edge_levels, initial_edges)
    
    # Current polygon state
    current_pts = copy(pts)
    n_active = n
    
    # Map from current vertex index to SET of original edge indices
    # Each wavefront edge may own multiple original edges after collapses
    edge_map = [[i] for i in 1:n]
    
    while n_active > 2
        # Compute bisectors at each active vertex
        bisectors, speeds = _compute_bisectors_active(current_pts, n_active)
        
        # Find next edge collapse (now returns intersection point)
        t_min, collapse_idx, collapse_pt = _find_next_collapse_active(current_pts, n_active, bisectors, speeds)
        
        if t_min == Inf || t_min <= 1e-10
            break
        end
        
        # Advance all vertices to time t_min
        new_pts = Vector{NTuple{2,Float64}}(undef, n_active)
        for i in 1:n_active
            bx, by = bisectors[i]
            s = speeds[i]
            px, py = current_pts[i]
            new_pts[i] = (px + bx * s * t_min, py + by * s * t_min)
        end
        
        # Record edges at this level - ALL original edges in each ownership set get geometry
        level_edges = Vector{NTuple{2, NTuple{2,Float64}}}(undef, n)
        for i in 1:n
            level_edges[i] = ((0.0, 0.0), (0.0, 0.0))
        end
        for i in 1:n_active
            next_i = mod1(i + 1, n_active)
            edge_geom = (new_pts[i], new_pts[next_i])
            # Record this geometry for ALL original edges owned by this wavefront edge
            for orig_edge in edge_map[i]
                level_edges[orig_edge] = edge_geom
            end
        end
        push!(edge_levels, level_edges)
        
        # Collapse: edge at collapse_idx shrinks to zero
        # Both vertices collapse_idx and next_idx merge into collapse_pt
        next_idx = mod1(collapse_idx + 1, n_active)
        
        # Build new vertex list and UNION edge ownership at collapse point
        new_current_pts = NTuple{2,Float64}[]
        new_edge_map = Vector{Vector{Int}}()
        for i in 1:n_active
            if i == collapse_idx
                # Insert the true collapse point
                push!(new_current_pts, collapse_pt)
                # UNION: this wavefront edge now owns edges from BOTH collapsing vertices
                merged_ownership = union(edge_map[collapse_idx], edge_map[next_idx])
                push!(new_edge_map, merged_ownership)
            elseif i == next_idx
                # Skip - this vertex merges into collapse_pt
                continue
            else
                push!(new_current_pts, new_pts[i])
                push!(new_edge_map, edge_map[i])
            end
        end
        
        # Update state
        current_pts = new_current_pts
        edge_map = new_edge_map
        n_active = length(current_pts)
    end
    
    # Final convergence for remaining 2-3 vertices
    if n_active >= 2
        bisectors, speeds = _compute_bisectors_active(current_pts, n_active)
        t_min, _, final_pt = _find_next_collapse_active(current_pts, n_active, bisectors, speeds)
        
        if t_min < Inf && t_min > 1e-10
            # All remaining vertices converge to the final point
            final_pts = Vector{NTuple{2,Float64}}(undef, n_active)
            for i in 1:n_active
                final_pts[i] = final_pt  # All converge to same point
            end
            
            # Record final level - propagate to ALL owned original edges
            level_edges = Vector{NTuple{2, NTuple{2,Float64}}}(undef, n)
            for i in 1:n
                level_edges[i] = ((0.0, 0.0), (0.0, 0.0))
            end
            for i in 1:n_active
                next_i = mod1(i + 1, n_active)
                edge_geom = (final_pts[i], final_pts[next_i])
                for orig_edge in edge_map[i]
                    level_edges[orig_edge] = edge_geom
                end
            end
            push!(edge_levels, level_edges)
        end
    end
    
    # Reorganize: edge_levels[level][edge] → sorted_by_edge[edge][level]
    sorted_by_edge = _reorganize_edge_levels(edge_levels, n)
    
    # Convert edges to polygon vertices
    tributary_polygons = _convert_edges_to_polygons(sorted_by_edge)
    
    # Build results
    total_area = abs(_polygon_area(original_pts))
    results = TributaryResult[]
    for i in 1:n
        poly_verts = tributary_polygons[i]
        area = abs(_polygon_area(poly_verts))
        frac = total_area > 0 ? area / total_area : 0.0
        push!(results, TributaryResult(i, poly_verts, area, frac))
    end
    
    return results
end

"""Compute bisectors and speeds for active vertices (simple array, 1:n_active)."""
function _compute_bisectors_active(pts::Vector{NTuple{2,Float64}}, n::Int)
    bisectors = Vector{NTuple{2,Float64}}(undef, n)
    speeds = Vector{Float64}(undef, n)
    
    for i in 1:n
        prev_i = mod1(i - 1, n)
        next_i = mod1(i + 1, n)
        
        p_prev = pts[prev_i]
        p_curr = pts[i]
        p_next = pts[next_i]
        
        # Edge vectors
        v_in = (p_curr[1] - p_prev[1], p_curr[2] - p_prev[2])
        v_out = (p_next[1] - p_curr[1], p_next[2] - p_curr[2])
        
        len_in = hypot(v_in...)
        len_out = hypot(v_out...)
        
        if len_in < 1e-10 || len_out < 1e-10
            bisectors[i] = (0.0, 0.0)
            speeds[i] = 0.0
            continue
        end
        
        # Normalize
        v_in = v_in ./ len_in
        v_out = v_out ./ len_out
        
        # Inward normals (90° CCW rotation for CCW polygon - interior is on LEFT)
        n_in = (-v_in[2], v_in[1])
        n_out = (-v_out[2], v_out[1])
        
        # Bisector direction
        bx, by = n_in[1] + n_out[1], n_in[2] + n_out[2]
        blen = hypot(bx, by)
        
        if blen < 1e-10
            bisectors[i] = (0.0, 0.0)
            speeds[i] = 0.0
        else
            bisectors[i] = (bx / blen, by / blen)
            speeds[i] = 2.0 / blen
        end
    end
    
    return bisectors, speeds
end

"""Find next edge collapse for active polygon. Returns (t_min, collapse_idx, collapse_point)."""
function _find_next_collapse_active(pts::Vector{NTuple{2,Float64}}, n::Int, bisectors, speeds)
    t_min = Inf
    collapse_idx = 0
    collapse_pt = (0.0, 0.0)
    
    for i in 1:n
        next_i = mod1(i + 1, n)
        
        p1 = pts[i]
        p2 = pts[next_i]
        d1 = bisectors[i] .* speeds[i]
        d2 = bisectors[next_i] .* speeds[next_i]
        
        t = _ray_ray_intersect_time(p1, d1, p2, d2)
        
        if t > 1e-10 && t < t_min
            t_min = t
            collapse_idx = i
            # Compute actual intersection point
            collapse_pt = (p1[1] + d1[1] * t, p1[2] + d1[2] * t)
        end
    end
    
    return t_min, collapse_idx, collapse_pt
end

"""Reorganize edge_levels[level][edge] → sorted_by_edge[edge][level]."""
function _reorganize_edge_levels(edge_levels, n_edges::Int)
    sorted_by_edge = [Vector{NTuple{2, NTuple{2,Float64}}}() for _ in 1:n_edges]
    
    for level in edge_levels
        for (edge_idx, edge) in enumerate(level)
            push!(sorted_by_edge[edge_idx], edge)
        end
    end
    
    return sorted_by_edge
end

# Tolerance for collinearity check (in meters)
const COLLINEAR_TOL = 0.01  # 1cm - more conservative

"""Check if an edge is a valid (non-placeholder) edge."""
_is_valid_edge(e) = _dist(e[1], e[2]) > 1e-9 || _dist(e[1], (0.0, 0.0)) > 1e-9

"""Convert edge history to closed polygon vertices."""
function _convert_edges_to_polygons(sorted_by_edge)
    polygons = Vector{Vector{NTuple{2,Float64}}}()
    
    for edge_list in sorted_by_edge
        # Filter out placeholder edges (collapsed to origin)
        valid_edges = filter(_is_valid_edge, edge_list)
        
        if isempty(valid_edges)
            push!(polygons, NTuple{2,Float64}[])
            continue
        end
        
        # Collect all nodes: forward edge[1], then backward edge[2]
        node_list = NTuple{2,Float64}[]
        for edge in valid_edges
            push!(node_list, edge[1])
        end
        for edge in reverse(valid_edges)
            push!(node_list, edge[2])
        end
        
        # Smooth collinear points
        smoothed = _smooth_nodes(node_list)
        
        # Final deduplication
        unique_nodes = _deduplicate_nodes(smoothed)
        push!(polygons, unique_nodes)
    end
    
    return polygons
end

"""Remove collinear points while preserving polygon shape."""
function _smooth_nodes(node_list::Vector{NTuple{2,Float64}})
    length(node_list) <= 2 && return node_list
    
    # Start with first two nodes
    result = [node_list[1], node_list[2]]
    
    for i in 3:length(node_list)
        pt = node_list[i]
        
        # Check collinearity with last two points in result
        if _is_collinear(result[end-1], result[end], pt; tol=COLLINEAR_TOL)
            result[end] = pt  # Replace middle point with new endpoint
        else
            push!(result, pt)
        end
    end
    
    return result
end

"""Remove duplicate nodes (within tolerance)."""
function _deduplicate_nodes(nodes::Vector{NTuple{2,Float64}}; atol::Float64 = 1e-6)
    isempty(nodes) && return nodes
    
    unique = [nodes[1]]
    for i in 2:length(nodes)
        is_dup = any(n -> _dist(n, nodes[i]) < atol, unique)
        is_dup || push!(unique, nodes[i])
    end
    return unique
end

"""Euclidean distance between two points."""
_dist(p1, p2) = hypot(p1[1] - p2[1], p1[2] - p2[2])

"""Check if three points are collinear within tolerance (perpendicular distance)."""
function _is_collinear(p1, p2, p3; tol::Float64 = COLLINEAR_TOL)
    len = _dist(p1, p3)
    len < 1e-9 && return true  # p1 and p3 are same point
    
    # Cross product gives 2x area of triangle; divide by base length for height
    cross = (p2[1] - p1[1]) * (p3[2] - p1[2]) - (p2[2] - p1[2]) * (p3[1] - p1[1])
    perp_dist = abs(cross) / len
    
    return perp_dist < tol
end
