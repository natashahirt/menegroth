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
    
    # Ensure CCW orientation (algorithm assumes interior is on LEFT)
    pts = _ensure_ccw(pts)
    original_pts = copy(pts)
    n = length(pts)
    
    # Warn if non-convex (algorithm only handles convex polygons correctly)
    if !_is_convex(pts)
        @warn "Non-convex polygon detected — tributary areas will be incorrect (split events not implemented)"
    end
    
    # Track edges at each wavefront level
    # edge_levels[level] = vector of edges (Nothing for inactive edges)
    edge_levels = Vector{Vector{Union{Nothing, NTuple{2, NTuple{2,Float64}}}}}()
    
    # Initial edges (level 0) - edge i goes from vertex i to vertex i+1
    initial_edges = Union{Nothing, NTuple{2, NTuple{2,Float64}}}[
        (pts[i], pts[mod1(i + 1, n)]) for i in 1:n
    ]
    push!(edge_levels, initial_edges)
    
    # Current polygon state
    current_pts = copy(pts)
    n_active = n
    
    # STRICT ownership: each wavefront edge owns exactly ONE original edge
    edge_map = collect(1:n)
    
    # Track termination: when each original edge dies and where
    edge_dead = falses(n)
    collapse_point = Vector{Union{Nothing, NTuple{2,Float64}}}(nothing, n)
    
    while n_active > 2
        # Compute bisectors at each active vertex
        bisectors, speeds = _compute_bisectors_active(current_pts, n_active)
        
        # Find ALL edges collapsing at the next event time (handles simultaneous collapses)
        t_min, collapses = _find_all_collapses_active(current_pts, n_active, bisectors, speeds)
        
        if t_min == Inf || t_min <= 1e-10 || isempty(collapses)
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
        
        # Record edges at this level (only for still-active original edges)
        level_edges = Vector{Union{Nothing, NTuple{2, NTuple{2,Float64}}}}(nothing, n)
        for i in 1:n_active
            next_i = mod1(i + 1, n_active)
            orig_edge = edge_map[i]
            level_edges[orig_edge] = (new_pts[i], new_pts[next_i])
        end
        push!(edge_levels, level_edges)
        
        # Build lookup structures for batch processing
        collapse_set = Set(c[1] for c in collapses)
        collapse_pt_for = Dict(c[1] => c[2] for c in collapses)
        
        # Mark all collapsing edges as dead
        for (idx, pt) in collapses
            dead_edge = edge_map[idx]
            edge_dead[dead_edge] = true
            collapse_point[dead_edge] = pt
        end
        
        # Handle case where ALL edges collapse (final convergence)
        if length(collapse_set) == n_active
            break
        end
        
        # Build new polygon handling batch collapses
        # Strategy: find runs of consecutive collapsed edges, emit one collapse point per run
        new_current_pts, new_edge_map = _build_collapsed_polygon(
            new_pts, edge_map, n_active, collapse_set, collapse_pt_for
        )
        
        # Update state
        current_pts = new_current_pts
        edge_map = new_edge_map
        n_active = length(current_pts)
    end
    
    # Final convergence: all remaining edges terminate at the same point
    # Skip if all edges already collapsed in the main loop
    any_surviving = any(i -> !edge_dead[edge_map[i]], 1:n_active)
    
    if n_active >= 2 && any_surviving
        bisectors, speeds = _compute_bisectors_active(current_pts, n_active)
        t_min, _, final_pt = _find_next_collapse_active(current_pts, n_active, bisectors, speeds)
        
        if t_min < Inf && t_min > 1e-10
            # Record final level
            level_edges = Vector{Union{Nothing, NTuple{2, NTuple{2,Float64}}}}(nothing, n)
            for i in 1:n_active
                next_i = mod1(i + 1, n_active)
                orig_edge = edge_map[i]
                level_edges[orig_edge] = (final_pt, final_pt)  # Collapsed to point
            end
            push!(edge_levels, level_edges)
            
            # All surviving edges terminate at final point
            for i in 1:n_active
                orig_edge = edge_map[i]
                if !edge_dead[orig_edge]
                    edge_dead[orig_edge] = true
                    collapse_point[orig_edge] = final_pt
                end
            end
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

"""
Find ALL edges collapsing at the minimum time (handles simultaneous events).
Returns (t_min, collapses) where collapses is Vector of (idx, collapse_point) tuples.
"""
function _find_all_collapses_active(pts::Vector{NTuple{2,Float64}}, n::Int, bisectors, speeds)
    # First pass: find t_min
    t_min = Inf
    for i in 1:n
        next_i = mod1(i + 1, n)
        p1 = pts[i]
        p2 = pts[next_i]
        d1 = bisectors[i] .* speeds[i]
        d2 = bisectors[next_i] .* speeds[next_i]
        t = _ray_ray_intersect_time(p1, d1, p2, d2)
        if t > 1e-10 && t < t_min
            t_min = t
        end
    end
    
    t_min == Inf && return (Inf, Tuple{Int, NTuple{2,Float64}}[])
    
    # Second pass: collect all edges collapsing at t_min (within tolerance)
    tol = max(1e-9, 1e-6 * t_min)
    collapses = Tuple{Int, NTuple{2,Float64}}[]
    
    for i in 1:n
        next_i = mod1(i + 1, n)
        p1 = pts[i]
        p2 = pts[next_i]
        d1 = bisectors[i] .* speeds[i]
        d2 = bisectors[next_i] .* speeds[next_i]
        t = _ray_ray_intersect_time(p1, d1, p2, d2)
        
        if isfinite(t) && t > 1e-10 && abs(t - t_min) <= tol
            pt = (p1[1] + d1[1] * t, p1[2] + d1[2] * t)
            push!(collapses, (i, pt))
        end
    end
    
    return (t_min, collapses)
end

"""
Build new polygon after batch collapse, handling consecutive collapse runs and wrap-around.
Returns (new_pts, new_edge_map).
"""
function _build_collapsed_polygon(
    advanced_pts::Vector{NTuple{2,Float64}},
    edge_map::Vector{Int},
    n_active::Int,
    collapse_set::Set{Int},
    collapse_pt_for::Dict{Int, NTuple{2,Float64}}
)
    new_pts = NTuple{2,Float64}[]
    new_edge_map = Int[]
    
    # Check for wrap-around: does a collapse run span from end back to start?
    wrap_around = (1 in collapse_set) && (n_active in collapse_set)
    
    # Find first non-collapsed index to start iteration (avoids split wrap-around runs)
    start_idx = 1
    if wrap_around
        # Find first index NOT in collapse set
        for i in 1:n_active
            if !(i in collapse_set)
                start_idx = i
                break
            end
        end
    end
    
    # Process vertices in order starting from start_idx
    visited = 0
    i = start_idx
    
    while visited < n_active
        if i in collapse_set
            # Start of a collapse run - collect all consecutive collapsed edges
            run_pts = NTuple{2,Float64}[]
            run_start = i
            
            while i in collapse_set && visited < n_active
                push!(run_pts, collapse_pt_for[i])
                visited += 1
                i = mod1(i + 1, n_active)
            end
            
            # Average the collapse points (should be nearly identical for adjacent collapses)
            avg_pt = (
                sum(p[1] for p in run_pts) / length(run_pts),
                sum(p[2] for p in run_pts) / length(run_pts)
            )
            
            # Emit the collapse point
            push!(new_pts, avg_pt)
            
            # The surviving edge after this run takes ownership
            # (i now points to the first non-collapsed edge after the run)
            if !(i in collapse_set) && visited < n_active
                push!(new_edge_map, edge_map[i])
            elseif !isempty(new_edge_map)
                # Edge case: if we've wrapped and all remaining are collapsed
                push!(new_edge_map, new_edge_map[1])
            end
        else
            # Not collapsing - emit vertex normally
            push!(new_pts, advanced_pts[i])
            push!(new_edge_map, edge_map[i])
            visited += 1
            i = mod1(i + 1, n_active)
        end
    end
    
    return new_pts, new_edge_map
end

"""Reorganize edge_levels[level][edge] → sorted_by_edge[edge][level], skipping Nothing entries."""
function _reorganize_edge_levels(edge_levels, n_edges::Int)
    sorted_by_edge = [Vector{NTuple{2, NTuple{2,Float64}}}() for _ in 1:n_edges]
    
    for level in edge_levels
        for (edge_idx, edge) in enumerate(level)
            edge !== nothing && push!(sorted_by_edge[edge_idx], edge)
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
