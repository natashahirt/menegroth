# =============================================================================
# One-Way Directed Tributary Areas
# =============================================================================

"""
    get_tributary_polygons_one_way(vertices::Vector{<:Point}; weights=nothing, axis)

Compute tributary polygons using one-way directed partitioning along the specified axis.

Each interior point is assigned to the edge closest along ±axis direction.
Edges parallel to axis get zero area (they're never "closest" in this metric).
"""
function get_tributary_polygons_one_way(vertices::Vector{<:Point}; weights=nothing, axis)
    m = length(vertices)
    m >= 3 || return TributaryResult[]
    
    # Convert to 2D coords and ensure CCW
    pts_orig = [_to_2d(v) for v in vertices]
    pts_orig = _ensure_ccw(pts_orig)
    
    # Normalize axis: u = direction, n = perpendicular
    vx, vy = Float64(axis[1]), Float64(axis[2])
    vlen = hypot(vx, vy)
    vlen < 1e-12 && error("axis must be non-zero")
    u = (vx / vlen, vy / vlen)
    n = (-u[2], u[1])
    
    # Handle weights
    weights_orig = isnothing(weights) ? ones(m) : Float64.(weights)
    
    # Transform to (s,t) coordinates
    pts_st = [_to_st(p, u, n) for p in pts_orig]
    
    # Get critical t-values (vertex t's)
    t_vals = sort(unique([p[2] for p in pts_st]))
    length(t_vals) < 2 && return [TributaryResult(i, NTuple{2,Float64}[], 0.0, 0.0) for i in 1:m]
    
    # Build trapezoids per edge by sweeping strips
    edge_traps = [NTuple{4, NTuple{2,Float64}}[] for _ in 1:m]
    
    for k in 1:(length(t_vals) - 1)
        t0, t1 = t_vals[k], t_vals[k + 1]
        
        # Sample slightly inside strip to avoid vertex ambiguities
        eps_t = min(1e-9, (t1 - t0) * 0.01)
        t0s = t0 + eps_t
        t1s = t1 - eps_t
        
        if t1s <= t0s
            # Degenerate strip
            continue
        end
        
        # Get intervals at BOTH ends of strip
        I0 = _scanline_intervals(pts_st, t0s)
        I1 = _scanline_intervals(pts_st, t1s)
        
        # Pair intervals (for convex polygons, should be 1-to-1)
        # For concave, need more sophisticated matching
        if length(I0) != length(I1)
            # Topology changed - use midpoint as fallback
            t_mid = (t0 + t1) / 2
            I_mid = _scanline_intervals(pts_st, t_mid)
            _add_traps_from_intervals!(edge_traps, I_mid, I_mid, t0, t1, weights_orig)
        else
            _add_traps_from_intervals!(edge_traps, I0, I1, t0, t1, weights_orig)
        end
    end
    
    # Assemble polygons from trapezoids
    total_area = abs(_polygon_area(pts_orig))
    results = TributaryResult[]
    
    for i in 1:m
        if isempty(edge_traps[i])
            push!(results, TributaryResult(i, NTuple{2,Float64}[], 0.0, 0.0))
            continue
        end
        
        poly_xy = _traps_to_polygon(edge_traps[i], u, n)
        
        if length(poly_xy) >= 4
            area = abs(_polygon_area(poly_xy))
            push!(results, TributaryResult(i, poly_xy, area, area / total_area))
        else
            push!(results, TributaryResult(i, NTuple{2,Float64}[], 0.0, 0.0))
        end
    end
    
    return results
end

"""Add trapezoids from paired intervals at t0 and t1."""
function _add_traps_from_intervals!(edge_traps, I0, I1, t0, t1, weights)
    for (interval0, interval1) in zip(I0, I1)
        (sL0, edgeL0), (sR0, edgeR0) = interval0
        (sL1, edgeL1), (sR1, edgeR1) = interval1
        
        # Compute weighted split at both ends
        wL0, wR0 = weights[edgeL0], weights[edgeR0]
        wL1, wR1 = weights[edgeL1], weights[edgeR1]
        
        split0 = _weighted_split(sL0, sR0, wL0, wR0)
        split1 = _weighted_split(sL1, sR1, wL1, wR1)
        
        # Handle edge identity changes
        if edgeL0 == edgeL1
            # Left edge is consistent - build single left trapezoid
            if split0 > sL0 + 1e-12 || split1 > sL1 + 1e-12
                left_trap = ((sL0, t0), (split0, t0), (split1, t1), (sL1, t1))
                push!(edge_traps[edgeL0], left_trap)
            end
        else
            # Left edge changed - split trapezoid at transition
            # For now, attribute to bottom edge (could be refined)
            if split0 > sL0 + 1e-12 || split1 > sL1 + 1e-12
                left_trap = ((sL0, t0), (split0, t0), (split1, t1), (sL1, t1))
                push!(edge_traps[edgeL0], left_trap)
            end
        end
        
        if edgeR0 == edgeR1
            # Right edge is consistent - build single right trapezoid
            if sR0 > split0 + 1e-12 || sR1 > split1 + 1e-12
                right_trap = ((split0, t0), (sR0, t0), (sR1, t1), (split1, t1))
                push!(edge_traps[edgeR0], right_trap)
            end
        else
            # Right edge changed - attribute to bottom edge
            if sR0 > split0 + 1e-12 || sR1 > split1 + 1e-12
                right_trap = ((split0, t0), (sR0, t0), (sR1, t1), (split1, t1))
                push!(edge_traps[edgeR0], right_trap)
            end
        end
    end
end

# =============================================================================
# Coordinate Transforms
# =============================================================================

_to_st(p::NTuple{2,Float64}, u::NTuple{2,Float64}, n::NTuple{2,Float64}) = 
    (p[1]*u[1] + p[2]*u[2], p[1]*n[1] + p[2]*n[2])

_to_xy(s::Float64, t::Float64, u::NTuple{2,Float64}, n::NTuple{2,Float64}) = 
    (s*u[1] + t*n[1], s*u[2] + t*n[2])

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
        
        abs(t2 - t1) < 1e-12 && continue  # skip horizontal
        
        # Half-open: include lower, exclude upper
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

function _weighted_split(sL::Float64, sR::Float64, wL::Float64, wR::Float64)
    denom = wL + wR
    denom < 1e-12 && return (sL + sR) / 2
    α = wR / denom
    return (1 - α) * sL + α * sR
end

# =============================================================================
# Trapezoid → Polygon
# =============================================================================

"""Convert trapezoids to polygon by tracing boundary."""
function _traps_to_polygon(traps::Vector{NTuple{4, NTuple{2,Float64}}}, 
                           u::NTuple{2,Float64}, n::NTuple{2,Float64})
    isempty(traps) && return NTuple{2,Float64}[]
    
    # Collect all t-values from trapezoid corners
    t_set = Set{Float64}()
    for trap in traps
        push!(t_set, trap[1][2])  # bottom (t0)
        push!(t_set, trap[3][2])  # top (t1)
    end
    t_sorted = sort(collect(t_set))
    
    # At each t-level, find the left and right boundary of the union
    left_chain = NTuple{2,Float64}[]
    right_chain = NTuple{2,Float64}[]
    
    for t in t_sorted
        s_left, s_right = Inf, -Inf
        
        for trap in traps
            # Trapezoid corners: (sL0,t0), (sR0,t0), (sR1,t1), (sL1,t1)
            t_bot = trap[1][2]
            t_top = trap[3][2]
            
            # Check if t is within trapezoid's t-range
            if t_bot - 1e-12 <= t <= t_top + 1e-12
                # Interpolate left and right s at this t
                if abs(t_top - t_bot) < 1e-12
                    sL = min(trap[1][1], trap[4][1])
                    sR = max(trap[2][1], trap[3][1])
                else
                    α = clamp((t - t_bot) / (t_top - t_bot), 0.0, 1.0)
                    # Left boundary: from trap[1] (bottom-left) to trap[4] (top-left)
                    sL = trap[1][1] + α * (trap[4][1] - trap[1][1])
                    # Right boundary: from trap[2] (bottom-right) to trap[3] (top-right)
                    sR = trap[2][1] + α * (trap[3][1] - trap[2][1])
                end
                s_left = min(s_left, sL)
                s_right = max(s_right, sR)
            end
        end
        
        if isfinite(s_left) && isfinite(s_right) && s_right >= s_left - 1e-12
            push!(left_chain, (s_left, t))
            push!(right_chain, (s_right, t))
        end
    end
    
    isempty(left_chain) && return NTuple{2,Float64}[]
    
    # Build polygon: left chain bottom→top, right chain top→bottom
    poly_st = NTuple{2,Float64}[]
    
    # Add left chain
    for pt in left_chain
        if isempty(poly_st) || !_pts_equal(pt, poly_st[end])
            push!(poly_st, pt)
        end
    end
    
    # Add right chain (reversed)
    for i in length(right_chain):-1:1
        pt = right_chain[i]
        if !_pts_equal(pt, poly_st[end])
            push!(poly_st, pt)
        end
    end
    
    # Close polygon
    if length(poly_st) >= 3 && !_pts_equal(poly_st[1], poly_st[end])
        push!(poly_st, poly_st[1])
    end
    
    # Transform to (x,y)
    poly_xy = [_to_xy(s, t, u, n) for (s,t) in poly_st]
    
    # Simplify and ensure CCW
    poly_xy = _simplify_collinear_ow(poly_xy)
    poly_xy = _ensure_ccw(poly_xy)
    
    return poly_xy
end

# =============================================================================
# Polygon Utilities
# =============================================================================

_pts_equal(a::NTuple{2,Float64}, b::NTuple{2,Float64}) = hypot(a[1]-b[1], a[2]-b[2]) < 1e-9

"""Simplify collinear vertices (handles closed polygons correctly)."""
function _simplify_collinear_ow(pts::Vector{NTuple{2,Float64}})
    length(pts) < 4 && return pts
    
    # Remove closing point if present
    closed = _pts_equal(pts[1], pts[end])
    if closed
        pts = pts[1:end-1]
    end
    
    nv = length(pts)
    nv < 3 && return pts
    
    result = NTuple{2,Float64}[]
    
    for i in 1:nv
        prev = pts[mod1(i - 1, nv)]
        curr = pts[i]
        next = pts[mod1(i + 1, nv)]
        
        # Cross product to check collinearity
        cross = (curr[1] - prev[1]) * (next[2] - curr[2]) - 
                (curr[2] - prev[2]) * (next[1] - curr[1])
        
        if abs(cross) > 1e-9
            push!(result, curr)
        end
    end
    
    # Re-close polygon
    if length(result) >= 3
        push!(result, result[1])
        return result
    else
        return vcat(pts, [pts[1]])
    end
end
