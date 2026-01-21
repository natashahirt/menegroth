# =============================================================================
# One-Way Directed Tributary Areas
# =============================================================================

"""
    get_tributary_polygons_one_way(vertices::Vector{<:Point}; weights=nothing, axis)

Compute tributary polygons using one-way directed partitioning along the specified axis.

Each interior point is assigned to the edge closest along ±axis direction.
Edges parallel to axis get zero area (they're never "closest" in this metric).

Algorithm:
1. Transform to (s,t) coordinates where t is perpendicular to the load-span axis
2. Sweep horizontal strips between consecutive vertex t-values  
3. Within each strip, partition the interior via weighted split between bounding edges
4. Sum trapezoid areas directly (exact, no polygon union needed)
5. Reconstruct polygons using actual polygon vertices for exterior boundary

Key insight: Each edge's tributary region has two types of boundaries:
- EXTERIOR: follows the actual polygon edge (use exact vertex coordinates)
- INTERIOR: follows the weighted split line (computed from scanline)
"""
function get_tributary_polygons_one_way(vertices::Vector{<:Point}; weights=nothing, axis)
    m = length(vertices)
    m >= 3 || return TributaryResult[]
    
    # Convert to 2D coords and ensure CCW
    pts_orig = [_to_2d(v) for v in vertices]
    pts_orig = _ensure_ccw(pts_orig)
    
    # Normalize axis: u = load direction, n = perpendicular (sweep direction)
    vx, vy = Float64(axis[1]), Float64(axis[2])
    vlen = hypot(vx, vy)
    vlen < 1e-12 && error("axis must be non-zero")
    u = (vx / vlen, vy / vlen)
    n = (-u[2], u[1])
    
    # Handle weights
    w = isnothing(weights) ? ones(m) : Float64.(weights)
    
    # Transform to (s,t) coordinates
    pts_st = [_to_st(p, u, n) for p in pts_orig]
    
    # Get critical t-values (vertex t's) - these define strip boundaries
    t_vals = sort(unique([p[2] for p in pts_st]))
    length(t_vals) < 2 && return [TributaryResult(i, NTuple{2,Float64}[], 0.0, 0.0) for i in 1:m]
    
    # For each edge, collect:
    # - Total area (summed directly)
    # - Interior boundary points (split line) 
    # - t-range where edge contributes
    # - Which side the edge is on (left=true, right=false)
    edge_areas = zeros(m)
    edge_interior_pts = [NTuple{2,Float64}[] for _ in 1:m]  # split line points
    edge_t_range = [(Inf, -Inf) for _ in 1:m]
    edge_is_left = [true for _ in 1:m]  # track if edge is on left side of interval
    
    # Process each horizontal strip
    for k in 1:(length(t_vals) - 1)
        t0, t1 = t_vals[k], t_vals[k + 1]
        height = t1 - t0
        height < 1e-12 && continue
        
        # Get intervals at bottom of strip (identifies which edges bound each region)
        intervals_0 = _scanline_intervals(pts_st, t0 + 1e-12)
        
        # Process each interval
        for ((sL0, edgeL0), (sR0, edgeR0)) in intervals_0
            # Compute edge positions at t1 directly from edge geometry
            # (don't rely on interval matching which fails when polygon narrows)
            sL1 = _edge_s_at_t(pts_st, edgeL0, t1)
            sR1 = _edge_s_at_t(pts_st, edgeR0, t1)
            
            # Compute weighted splits
            split0 = _weighted_split(sL0, sR0, w[edgeL0], w[edgeR0])
            split1 = _weighted_split(sL1, sR1, w[edgeL0], w[edgeR0])
            
            # Left edge (edgeL0) gets region from polygon edge to split line
            width_L0 = max(0.0, split0 - sL0)
            width_L1 = max(0.0, split1 - sL1)
            if width_L0 > 1e-12 || width_L1 > 1e-12
                area_L = (width_L0 + width_L1) / 2 * height
                edge_areas[edgeL0] += area_L
                
                # Interior = split line (on RIGHT of this edge's region)
                push!(edge_interior_pts[edgeL0], (split0, t0))
                push!(edge_interior_pts[edgeL0], (split1, t1))
                
                edge_is_left[edgeL0] = true
                
                tmin, tmax = edge_t_range[edgeL0]
                edge_t_range[edgeL0] = (min(tmin, t0), max(tmax, t1))
            end
            
            # Right edge (edgeR0) gets region from split line to polygon edge
            width_R0 = max(0.0, sR0 - split0)
            width_R1 = max(0.0, sR1 - split1)
            if width_R0 > 1e-12 || width_R1 > 1e-12
                area_R = (width_R0 + width_R1) / 2 * height
                edge_areas[edgeR0] += area_R
                
                # Interior = split line (on LEFT of this edge's region)
                push!(edge_interior_pts[edgeR0], (split0, t0))
                push!(edge_interior_pts[edgeR0], (split1, t1))
                
                edge_is_left[edgeR0] = false
                
                tmin, tmax = edge_t_range[edgeR0]
                edge_t_range[edgeR0] = (min(tmin, t0), max(tmax, t1))
            end
        end
    end
    
    # Compute total area for fractions
    total_area = abs(_polygon_area(pts_orig))
    
    # Build results
    results = TributaryResult[]
    
    for i in 1:m
        if edge_areas[i] < 1e-12
            push!(results, TributaryResult(i, NTuple{2,Float64}[], 0.0, 0.0))
            continue
        end
        
        # Get the actual polygon edge vertices for this edge
        v1_st = pts_st[i]
        v2_st = pts_st[mod1(i + 1, m)]
        
        # Clip the actual polygon edge to the contributing t-range
        t_min, t_max = edge_t_range[i]
        actual_exterior = _get_edge_in_t_range(v1_st, v2_st, t_min, t_max)
        
        # Reconstruct polygon from actual exterior + interior (split) points
        poly_xy = _build_tributary_polygon_v2(
            actual_exterior, edge_interior_pts[i], edge_is_left[i], u, n
        )
        
        area = edge_areas[i]
        frac = total_area > 0 ? area / total_area : 0.0
        
        push!(results, TributaryResult(i, poly_xy, area, frac))
    end
    
    return results
end

"""
Get points along a polygon edge within a t-range, including the actual vertices.
Returns points ordered by increasing t.
"""
function _get_edge_in_t_range(v1::NTuple{2,Float64}, v2::NTuple{2,Float64}, 
                               t_min::Float64, t_max::Float64)
    s1, t1 = v1
    s2, t2 = v2
    
    # Handle horizontal edge
    if abs(t2 - t1) < 1e-12
        if t_min - 1e-9 <= t1 <= t_max + 1e-9
            return t1 <= t2 ? [v1, v2] : [v2, v1]
        else
            return NTuple{2,Float64}[]
        end
    end
    
    # Collect points on edge within [t_min, t_max]
    points = NTuple{2,Float64}[]
    
    # Add actual vertices if within range
    if t_min - 1e-9 <= t1 <= t_max + 1e-9
        push!(points, v1)
    end
    if t_min - 1e-9 <= t2 <= t_max + 1e-9
        push!(points, v2)
    end
    
    # Add clipped endpoints at t_min and t_max if they're strictly inside edge's t-range
    edge_t_lo, edge_t_hi = minmax(t1, t2)
    
    if t_min > edge_t_lo + 1e-9 && t_min < edge_t_hi - 1e-9
        # t_min is strictly inside edge - add point at t_min
        α = (t_min - t1) / (t2 - t1)
        s_at_tmin = s1 + α * (s2 - s1)
        push!(points, (s_at_tmin, t_min))
    end
    
    if t_max > edge_t_lo + 1e-9 && t_max < edge_t_hi - 1e-9
        # t_max is strictly inside edge - add point at t_max
        α = (t_max - t1) / (t2 - t1)
        s_at_tmax = s1 + α * (s2 - s1)
        push!(points, (s_at_tmax, t_max))
    end
    
    # Sort by t
    sort!(points, by=p->p[2])
    
    return points
end

# =============================================================================
# Polygon Reconstruction with Exact Exterior Boundary
# =============================================================================

"""
Build tributary polygon from exterior (polygon edge) and interior (split) points.

For edge on LEFT of interval:
- Exterior is on LEFT, Interior is on RIGHT
- CCW order: exterior going UP, then interior going DOWN

For edge on RIGHT of interval:  
- Exterior is on RIGHT, Interior is on LEFT
- CCW order: interior going UP, then exterior going DOWN
"""
function _build_tributary_polygon_v2(exterior_pts::Vector{NTuple{2,Float64}},
                                     interior_pts::Vector{NTuple{2,Float64}},
                                     is_left_edge::Bool,
                                     u::NTuple{2,Float64}, n::NTuple{2,Float64})
    
    (isempty(exterior_pts) || isempty(interior_pts)) && return NTuple{2,Float64}[]
    
    # Sort and deduplicate both chains by t
    exterior_chain = _sort_and_dedup(exterior_pts)
    interior_chain = _sort_and_dedup(interior_pts)
    
    (length(exterior_chain) < 2 || length(interior_chain) < 2) && return NTuple{2,Float64}[]
    
    # Build polygon in CCW order
    poly_st = NTuple{2,Float64}[]
    
    if is_left_edge
        # Exterior on LEFT, Interior on RIGHT
        # CCW: start at bottom-left (exterior), go UP along exterior,
        #      then DOWN along interior (reversed), back to start
        
        # Exterior going up (bottom to top)
        for pt in exterior_chain
            if isempty(poly_st) || !_pts_equal(pt, poly_st[end])
                push!(poly_st, pt)
            end
        end
        
        # Interior going down (top to bottom)
        for i in length(interior_chain):-1:1
            pt = interior_chain[i]
            if isempty(poly_st) || !_pts_equal(pt, poly_st[end])
                push!(poly_st, pt)
            end
        end
    else
        # Exterior on RIGHT, Interior on LEFT
        # CCW: start at bottom-left (interior), go UP along interior,
        #      then DOWN along exterior (reversed), back to start
        
        # Interior going up (bottom to top)
        for pt in interior_chain
            if isempty(poly_st) || !_pts_equal(pt, poly_st[end])
                push!(poly_st, pt)
            end
        end
        
        # Exterior going down (top to bottom)
        for i in length(exterior_chain):-1:1
            pt = exterior_chain[i]
            if isempty(poly_st) || !_pts_equal(pt, poly_st[end])
                push!(poly_st, pt)
            end
        end
    end
    
    length(poly_st) < 3 && return NTuple{2,Float64}[]
    
    # Close polygon
    if !_pts_equal(poly_st[1], poly_st[end])
        push!(poly_st, poly_st[1])
    end
    
    # Transform to (x,y)
    poly_xy = [_to_xy(s, t, u, n) for (s, t) in poly_st]
    
    # Simplify and ensure CCW
    poly_xy = _simplify_collinear(poly_xy)
    poly_xy = _ensure_ccw(poly_xy)
    
    return poly_xy
end

"""Sort points by t and remove duplicates."""
function _sort_and_dedup(pts::Vector{NTuple{2,Float64}})
    sorted = sort(pts, by=p->p[2])
    result = NTuple{2,Float64}[]
    for pt in sorted
        if isempty(result) || !_pts_equal(pt, result[end])
            push!(result, pt)
        end
    end
    return result
end

# =============================================================================
# Coordinate Transforms
# =============================================================================

_to_st(p::NTuple{2,Float64}, u::NTuple{2,Float64}, n::NTuple{2,Float64}) = 
    (p[1]*u[1] + p[2]*u[2], p[1]*n[1] + p[2]*n[2])

_to_xy(s::Float64, t::Float64, u::NTuple{2,Float64}, n::NTuple{2,Float64}) = 
    (s*u[1] + t*n[1], s*u[2] + t*n[2])

# =============================================================================
# Edge Geometry Helpers
# =============================================================================

"""Compute s-coordinate where edge `edge_idx` intersects horizontal line at t."""
function _edge_s_at_t(pts_st::Vector{NTuple{2,Float64}}, edge_idx::Int, t::Float64)
    nv = length(pts_st)
    i = edge_idx
    j = mod1(i + 1, nv)
    
    s1, t1 = pts_st[i]
    s2, t2 = pts_st[j]
    
    # Handle horizontal edge (constant t)
    if abs(t2 - t1) < 1e-12
        return (s1 + s2) / 2
    end
    
    # Linear interpolation
    α = clamp((t - t1) / (t2 - t1), 0.0, 1.0)
    return s1 + α * (s2 - s1)
end

# =============================================================================
# Scanline Intersection
# =============================================================================

"""Return intervals as [((sL, edgeL), (sR, edgeR)), ...] for scanline at t."""
function _scanline_intervals(pts_st::Vector{NTuple{2,Float64}}, t::Float64)
    nv = length(pts_st)
    crosses = Tuple{Float64,Int}[]
    
    for i in 1:nv
        j = mod1(i + 1, nv)
        s1, t1 = pts_st[i]
        s2, t2 = pts_st[j]
        
        abs(t2 - t1) < 1e-12 && continue  # skip horizontal edges
        
        # Half-open interval: include lower, exclude upper
        if (t1 <= t < t2) || (t2 <= t < t1)
            α = (t - t1) / (t2 - t1)
            s = s1 + α * (s2 - s1)
            push!(crosses, (s, i))
        end
    end
    
    sort!(crosses, by=x -> x[1])
    
    intervals = Tuple{Tuple{Float64,Int}, Tuple{Float64,Int}}[]
    for k in 1:2:(length(crosses) - 1)
        push!(intervals, (crosses[k], crosses[k+1]))
    end
    
    return intervals
end

# =============================================================================
# Weighted Split
# =============================================================================

"""Compute weighted split point between sL and sR based on edge weights."""
function _weighted_split(sL::Float64, sR::Float64, wL::Float64, wR::Float64)
    denom = wL + wR
    denom < 1e-12 && return (sL + sR) / 2
    α = wR / denom
    return (1 - α) * sL + α * sR
end

# =============================================================================
# Polygon Utilities
# =============================================================================

"""Remove collinear points from polygon."""
function _simplify_collinear(pts::Vector{NTuple{2,Float64}})
    length(pts) < 4 && return pts
    
    closed = _pts_equal(pts[1], pts[end])
    work = closed ? pts[1:end-1] : pts
    
    nv = length(work)
    nv < 3 && return pts
    
    result = NTuple{2,Float64}[]
    
    for i in 1:nv
        prev = work[mod1(i - 1, nv)]
        curr = work[i]
        next = work[mod1(i + 1, nv)]
        
        cross = (curr[1] - prev[1]) * (next[2] - curr[2]) - 
                (curr[2] - prev[2]) * (next[1] - curr[1])
        
        if abs(cross) > 1e-9
            push!(result, curr)
        end
    end
    
    length(result) < 3 && return pts
    
    push!(result, result[1])
    return result
end

_pts_equal(a::NTuple{2,Float64}, b::NTuple{2,Float64}) = hypot(a[1]-b[1], a[2]-b[2]) < 1e-9
