# =============================================================================
# Straight Skeleton using DCEL (Weighted Tributary Areas)
# =============================================================================

"""
    get_tributary_polygons_isotropic_dcel(vertices::Vector{<:Point}; weights=nothing)

Compute tributary polygons using straight skeleton with DCEL data structure.
Returns Vector{TributaryResult}, one per original edge.

## Arguments
- `vertices`: Polygon vertices as Meshes.Point objects
- `weights`: Optional vector of edge weights (one per edge). 
  - Higher weight = faster shrink = smaller tributary area
  - Default `nothing` = all weights equal to 1.0 (isotropic)
  - Example: `weights=[1.0, 2.0, 1.0, 2.0]` for a rectangle where 
    opposite edges have different weights

## Weight Convention
Weights represent the "speed" at which each edge moves inward during 
wavefront propagation. A weight of 2.0 means the edge moves twice as 
fast as an edge with weight 1.0, resulting in roughly half the tributary area.
"""
function get_tributary_polygons_isotropic_dcel(vertices::Vector{<:Point}; weights=nothing)
    m = length(vertices)  # Original vertex count
    m >= 3 || return TributaryResult[]
    
    # Convert to simple 2D coords
    pts_orig = [_to_2d(v) for v in vertices]
    
    # Ensure CCW orientation (algorithm assumes interior is on LEFT)
    pts_orig = _ensure_ccw(pts_orig)
    original_pts = copy(pts_orig)  # Keep for area calculation
    
    # Handle weights
    if isnothing(weights)
        weights_orig = ones(m)
    else
        length(weights) == m || error("weights must have same length as vertices ($m)")
        weights_orig = Float64.(weights)
        all(w -> w > 0, weights_orig) || error("all weights must be positive")
    end
    
    # Simplify collinear vertices (removes 180° degeneracies)
    pts, keep_idx = simplify_collinear_polygon(pts_orig; tol=1e-12)
    n = length(pts)
    n >= 3 || return TributaryResult[]  # Degenerate after simplification
    
    # Build mapping: orig_to_simp[i] = simplified edge that contains original edge i
    # Also compute simplified weights (average weight of merged edges)
    orig_to_simp = fill(0, m)
    n_s = length(keep_idx)
    simp_weights = zeros(n_s)
    simp_edge_counts = zeros(Int, n_s)
    
    for k in 1:n_s
        a = keep_idx[k]
        b = keep_idx[mod1(k + 1, n_s)]
        i = a
        while i != b
            orig_to_simp[i] = k
            simp_weights[k] += weights_orig[i]
            simp_edge_counts[k] += 1
            i = mod1(i + 1, m)
        end
    end
    
    # Average the weights for merged edges
    for k in 1:n_s
        if simp_edge_counts[k] > 0
            simp_weights[k] /= simp_edge_counts[k]
        else
            simp_weights[k] = 1.0
        end
    end
    
    # Initialize DCEL and vertex registry
    dcel = DCEL()
    registry = VertexRegistry(dcel; tol=1e-9)
    
    # =========================================================================
    # Step 1: Build boundary halfedges for the simplified polygon
    # =========================================================================
    boundary_vertices = Int[]
    for i in 1:n
        v_idx = get_or_create_vertex!(registry, pts[i])
        push!(boundary_vertices, v_idx)
    end
    
    # Create boundary halfedge pairs
    # Edge i (from vertex i to vertex i+1) has:
    #   - Inner halfedge with face = i (tributary face for simplified edge i)
    #   - Outer halfedge with face = 0 (outside)
    boundary_inner = Int[]  # Inner halfedges (one per simplified edge)
    boundary_outer = Int[]  # Outer halfedges
    
    for i in 1:n
        v1 = boundary_vertices[i]
        v2 = boundary_vertices[mod1(i + 1, n)]
        h_inner, h_outer = create_halfedge_pair!(dcel, v1, v2, i, 0)
        push!(boundary_inner, h_inner)
        push!(boundary_outer, h_outer)
    end
    
    # =========================================================================
    # Step 2: Wavefront propagation with skeleton arc recording
    # =========================================================================
    
    # Current wavefront state
    current_pts = copy(pts)
    n_active = n
    
    # edge_map[i] = which original edge the current wavefront edge i represents
    edge_map = collect(1:n)
    
    # weight_map[i] = weight of current wavefront edge i
    weight_map = copy(simp_weights)
    
    # Track which original edges are still active
    edge_active = trues(n)
    
    while n_active > 2
        # Compute bisectors at each active vertex (weighted)
        bisectors, speeds = _compute_bisectors_weighted(current_pts, n_active, weight_map)
        
        # Find all edges collapsing at the next event time
        t_min, collapses = _find_all_collapses_dcel(current_pts, n_active, bisectors, speeds)
        
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
        
        # Record skeleton arcs for each active vertex trajectory
        # Each vertex i sits between wavefront edges (i-1) and i
        # So its trajectory separates faces edge_map[mod1(i-1, n_active)] and edge_map[i]
        for i in 1:n_active
            p_old = current_pts[i]
            p_new = new_pts[i]
            
            # Skip degenerate arcs
            if _dist_dcel(p_old, p_new) < 1e-10
                continue
            end
            
            # Adjacent faces (original edge IDs)
            face_left = edge_map[mod1(i - 1, n_active)]
            face_right = edge_map[i]
            
            # Record the skeleton arc
            _record_skeleton_arc!(dcel, registry, p_old, p_new, face_left, face_right)
        end
        
        # Build lookup structures for batch processing
        collapse_set = Set(c[1] for c in collapses)
        collapse_pt_for = Dict(c[1] => c[2] for c in collapses)
        
        # Mark collapsing edges
        for (idx, _) in collapses
            edge_active[edge_map[idx]] = false
        end
        
        # Handle case where ALL edges collapse (final convergence)
        if length(collapse_set) == n_active
            # All edges collapse simultaneously
            cps = [pt for (_, pt) in collapses]
            
            # Check if all collapse points are coincident (within tolerance)
            # For isotropic symmetric cases they coincide; with weights they may form a segment
            tol_meet = 1e-8
            all_coincident = true
            for i in 2:length(cps)
                if _dist_dcel(cps[1], cps[i]) > tol_meet
                    all_coincident = false
                    break
                end
            end
            
            if all_coincident
                # All points coincide — use average (or just first point)
                meet = (sum(p[1] for p in cps) / length(cps), 
                        sum(p[2] for p in cps) / length(cps))
                
                # Record arcs from each vertex to meeting point
                for i in 1:n_active
                    p_old = current_pts[i]
                    if _dist_dcel(p_old, meet) > 1e-10
                        face_left = edge_map[mod1(i - 1, n_active)]
                        face_right = edge_map[i]
                        _record_skeleton_arc!(dcel, registry, p_old, meet, face_left, face_right)
                    end
                end
            else
                # Collapse points form a segment (roof ridge) — record to segment endpoints
                # Find bounding box of collapse points
                xs = [p[1] for p in cps]
                ys = [p[2] for p in cps]
                x_min, x_max = extrema(xs)
                y_min, y_max = extrema(ys)
                
                # Use endpoints of the bounding box (or cluster and use cluster centers)
                # For now, use min/max points as segment endpoints
                meet1 = (x_min, y_min)
                meet2 = (x_max, y_max)
                
                # Record arcs to both endpoints (or to nearest endpoint)
                for i in 1:n_active
                    p_old = current_pts[i]
                    face_left = edge_map[mod1(i - 1, n_active)]
                    face_right = edge_map[i]
                    
                    # Choose closer endpoint
                    d1 = _dist_dcel(p_old, meet1)
                    d2 = _dist_dcel(p_old, meet2)
                    meet = d1 < d2 ? meet1 : meet2
                    
                    if _dist_dcel(p_old, meet) > 1e-10
                        _record_skeleton_arc!(dcel, registry, p_old, meet, face_left, face_right)
                    end
                end
            end
            break
        end
        
        # Build new polygon handling batch collapses (also updates weights)
        new_current_pts, new_edge_map, new_weight_map = _build_collapsed_polygon_weighted(
            new_pts, edge_map, weight_map, n_active, collapse_set, collapse_pt_for
        )
        
        # Update state
        current_pts = new_current_pts
        edge_map = new_edge_map
        weight_map = new_weight_map
        n_active = length(current_pts)
    end
    
    # =========================================================================
    # Step 3: Final convergence - remaining vertices meet at center
    # =========================================================================
    if n_active >= 2
        bisectors, speeds = _compute_bisectors_weighted(current_pts, n_active, weight_map)
        t_min, _, final_pt = _find_next_collapse_single(current_pts, n_active, bisectors, speeds)
        
        if t_min < Inf && t_min > 1e-10
            # Record final skeleton arcs to the center point
            for i in 1:n_active
                p_old = current_pts[i]
                if _dist_dcel(p_old, final_pt) > 1e-10
                    face_left = edge_map[mod1(i - 1, n_active)]
                    face_right = edge_map[i]
                    _record_skeleton_arc!(dcel, registry, p_old, final_pt, face_left, face_right)
                end
            end
        end
    end
    
    # =========================================================================
    # Step 4: Compute next/prev pointers using DCEL rotation system
    # =========================================================================
    compute_next_prev!(dcel)
    
    # =========================================================================
    # Step 4b: Insert artificial bisectors (micro-spokes, not self-loops)
    # =========================================================================
    n_bisectors = insert_artificial_bisectors!(dcel, registry)
    if n_bisectors > 0
        # Recompute next/prev after inserting bisectors
        compute_next_prev!(dcel)
    end
    
    # =========================================================================
    # Step 4c: Validate DCEL
    # =========================================================================
    valid, errs = validate_dcel(dcel)
    valid || @warn(join(errs, "\n"))
    
    # =========================================================================
    # Step 5: Extract tributary polygons for simplified faces
    # =========================================================================
    total_area = abs(_polygon_area(original_pts))
    simp_results = Vector{Tuple{Vector{NTuple{2,Float64}}, Float64}}(undef, n)
    
    for i in 1:n
        # Use cycle walking as primary (rotation system ensures correctness)
        poly_verts = extract_face_polygon(dcel, i)
        
        if isempty(poly_verts) || length(poly_verts) < 3
            # Fallback: try edge-based extraction for debugging
            poly_verts = extract_face_polygon_by_edges(dcel, i)
        end
        
        if isempty(poly_verts) || length(poly_verts) < 3
            simp_results[i] = (NTuple{2,Float64}[], 0.0)
        else
            area = abs(_polygon_area(poly_verts))
            simp_results[i] = (poly_verts, area)
        end
    end
    
    # =========================================================================
    # Step 6: Map simplified results back to original edges
    # =========================================================================
    results = TributaryResult[]
    for i in 1:m  # m = original vertex count
        k = orig_to_simp[i]
        if k == 0 || k > n
            push!(results, TributaryResult(i, NTuple{2,Float64}[], 0.0, 0.0))
        else
            poly, area = simp_results[k]
            frac = total_area > 0 ? area / total_area : 0.0
            push!(results, TributaryResult(i, poly, area, frac))
        end
    end
    
    return results
end

# =============================================================================
# Helper Functions (DCEL-specific versions)
# =============================================================================

"""Distance between two points."""
_dist_dcel(p1, p2) = hypot(p1[1] - p2[1], p1[2] - p2[2])

"""Record a skeleton arc from p_old to p_new separating face_left and face_right."""
function _record_skeleton_arc!(dcel::DCEL, registry::VertexRegistry, 
                                p_old::NTuple{2,Float64}, p_new::NTuple{2,Float64},
                                face_left::Int, face_right::Int)
    v1 = get_or_create_vertex!(registry, p_old)
    v2 = get_or_create_vertex!(registry, p_new)
    
    # Don't create self-loops
    v1 == v2 && return
    
    # Create halfedge pair marked as SKELETON edges (face separators):
    # Walking from v1 to v2, face_left is on the LEFT
    # DCEL convention: halfedge's face = the face on its LEFT
    # h1: v1 → v2 with face = face_left
    # h2: v2 → v1 with face = face_right (original right is now on left)
    # These edges SEPARATE faces and should not be crossed during face walks
    create_halfedge_pair!(dcel, v1, v2, face_left, face_right; is_skeleton=true)
end

"""Compute bisectors and speeds for active vertices (isotropic, all weights = 1)."""
function _compute_bisectors_dcel(pts::Vector{NTuple{2,Float64}}, n::Int)
    return _compute_bisectors_weighted(pts, n, ones(n))
end

"""
Compute weighted bisectors and speeds for active vertices.

For vertex i between edges (i-1) and i with weights w_{i-1} and w_i:
- Bisector direction = normalize(w_{i-1} * n_{i-1} + w_i * n_i)
- Speed = computed so the vertex stays on both moving edge offsets

Higher weight = faster movement = smaller tributary area for that edge.
"""
function _compute_bisectors_weighted(pts::Vector{NTuple{2,Float64}}, n::Int, weights::Vector{Float64})
    bisectors = Vector{NTuple{2,Float64}}(undef, n)
    speeds = Vector{Float64}(undef, n)
    
    for i in 1:n
        prev_i = mod1(i - 1, n)
        next_i = mod1(i + 1, n)
        
        p_prev = pts[prev_i]
        p_curr = pts[i]
        p_next = pts[next_i]
        
        # Edge directions
        e_in = (p_curr[1] - p_prev[1], p_curr[2] - p_prev[2])   # edge (prev_i)
        e_out = (p_next[1] - p_curr[1], p_next[2] - p_curr[2])  # edge (i)
        
        len_in = hypot(e_in...)
        len_out = hypot(e_out...)
        if len_in < 1e-12 || len_out < 1e-12
            bisectors[i] = (0.0, 0.0)
            speeds[i] = 0.0
            continue
        end
        
        e_in = (e_in[1]/len_in, e_in[2]/len_in)
        e_out = (e_out[1]/len_out, e_out[2]/len_out)
        
        # Inward normals for CCW polygon
        n_in = (-e_in[2], e_in[1])
        n_out = (-e_out[2], e_out[1])
        
        w_in = weights[prev_i]
        w_out = weights[i]
        
        # Weighted bisector direction
        bx = w_in*n_in[1] + w_out*n_out[1]
        by = w_in*n_in[2] + w_out*n_out[2]
        bl = hypot(bx, by)
        if bl < 1e-12
            bisectors[i] = (0.0, 0.0)
            speeds[i] = 0.0
            continue
        end
        
        b = (bx/bl, by/bl)
        bisectors[i] = b
        
        # Enforce BOTH offset constraints:
        # s*(b·n_in)  = w_in * t
        # s*(b·n_out) = w_out*t
        din = b[1]*n_in[1] + b[2]*n_in[2]
        dout = b[1]*n_out[1] + b[2]*n_out[2]
        
        if abs(din) < 1e-12 || abs(dout) < 1e-12
            speeds[i] = 0.0
            continue
        end
        
        s1 = w_in / din
        s2 = w_out / dout
        
        # Both should be positive for a valid inward motion
        if s1 <= 0 || s2 <= 0
            speeds[i] = 0.0
            continue
        end
        
        # If they disagree due to numerics, average; clamping would use min(s1,s2)
        speeds[i] = 0.5*(s1 + s2)
    end
    
    return bisectors, speeds
end

"""Find all edges collapsing at the minimum time."""
function _find_all_collapses_dcel(pts::Vector{NTuple{2,Float64}}, n::Int, bisectors, speeds)
    # First pass: find t_min
    t_min = Inf
    for i in 1:n
        next_i = mod1(i + 1, n)
        p1 = pts[i]
        p2 = pts[next_i]
        d1 = bisectors[i] .* speeds[i]
        d2 = bisectors[next_i] .* speeds[next_i]
        t = _ray_ray_intersect_time_dcel(p1, d1, p2, d2)
        if t > 1e-10 && t < t_min
            t_min = t
        end
    end
    
    t_min == Inf && return (Inf, Tuple{Int, NTuple{2,Float64}}[])
    
    # Second pass: collect all edges collapsing at t_min
    tol = max(1e-9, 1e-6 * t_min)
    collapses = Tuple{Int, NTuple{2,Float64}}[]
    
    for i in 1:n
        next_i = mod1(i + 1, n)
        p1 = pts[i]
        p2 = pts[next_i]
        d1 = bisectors[i] .* speeds[i]
        d2 = bisectors[next_i] .* speeds[next_i]
        t = _ray_ray_intersect_time_dcel(p1, d1, p2, d2)
        
        if isfinite(t) && t > 1e-10 && abs(t - t_min) <= tol
            pt = (p1[1] + d1[1] * t, p1[2] + d1[2] * t)
            push!(collapses, (i, pt))
        end
    end
    
    return (t_min, collapses)
end

"""Find next single collapse (for final convergence)."""
function _find_next_collapse_single(pts::Vector{NTuple{2,Float64}}, n::Int, bisectors, speeds)
    t_min = Inf
    collapse_idx = 0
    collapse_pt = (0.0, 0.0)
    
    for i in 1:n
        next_i = mod1(i + 1, n)
        p1 = pts[i]
        p2 = pts[next_i]
        d1 = bisectors[i] .* speeds[i]
        d2 = bisectors[next_i] .* speeds[next_i]
        t = _ray_ray_intersect_time_dcel(p1, d1, p2, d2)
        
        if t > 1e-10 && t < t_min
            t_min = t
            collapse_idx = i
            collapse_pt = (p1[1] + d1[1] * t, p1[2] + d1[2] * t)
        end
    end
    
    return t_min, collapse_idx, collapse_pt
end

"""
Robust time when p1 + t*d1 == p2 + t*d2 (edge-collapse event).
Returns Inf if (d1-d2) is too small or the fit residual is too large.

This is the 2D system: (p1 - p2) + t*(d1 - d2) = 0
We solve using least-squares and verify consistency with scaled tolerance.
"""
function _ray_ray_intersect_time_dcel(p1, d1, p2, d2; tol_rel=1e-10, tol_abs=1e-12)
    # Solve (p1 - p2) + t*(d1 - d2) = 0 in least-squares sense
    ax = d1[1] - d2[1]
    ay = d1[2] - d2[2]
    bx = p2[1] - p1[1]
    by = p2[2] - p1[2]
    
    denom = ax*ax + ay*ay
    denom < tol_abs && return Inf
    
    # Least-squares t
    t = (bx*ax + by*ay) / denom
    t <= 1e-12 && return Inf
    
    # Residual check: p1 + t*d1 should equal p2 + t*d2
    rx = (p1[1] + t*d1[1]) - (p2[1] + t*d2[1])
    ry = (p1[2] + t*d1[2]) - (p2[2] + t*d2[2])
    r = hypot(rx, ry)
    
    # Scale tolerance to problem magnitude (position + displacement scale)
    scale = max(hypot(bx, by), hypot(d1[1]*t, d1[2]*t), hypot(d2[1]*t, d2[2]*t), 1.0)
    tol = max(tol_abs, tol_rel * scale)
    
    return (r <= tol) ? t : Inf
end

"""Build new polygon after batch collapse."""
function _build_collapsed_polygon_dcel(
    advanced_pts::Vector{NTuple{2,Float64}},
    edge_map::Vector{Int},
    n_active::Int,
    collapse_set::Set{Int},
    collapse_pt_for::Dict{Int, NTuple{2,Float64}}
)
    # Build new polygon after edge collapses.
    #
    # Key insight: 
    # - Vertex i sits between edge i-1 (ending at i) and edge i (starting at i)
    # - When edge i collapses, vertices i and i+1 merge to collapse_pt_for[i]
    # - A vertex survives only if BOTH adjacent edges survive
    # - Otherwise, vertex position comes from whichever adjacent edge collapsed
    
    new_pts = NTuple{2,Float64}[]
    new_edge_map = Int[]
    
    for i in 1:n_active
        prev_edge = mod1(i - 1, n_active)
        curr_edge = i
        
        prev_collapsed = prev_edge in collapse_set
        curr_collapsed = curr_edge in collapse_set
        
        if prev_collapsed && curr_collapsed
            # Both adjacent edges collapsed - vertex merges into collapse region
            # Skip this vertex; it will be represented by a collapse point
            continue
        elseif prev_collapsed && !curr_collapsed
            # Previous edge collapsed, current survives
            # This vertex is at the END of a collapse run
            # Position comes from the collapse of prev_edge
            push!(new_pts, collapse_pt_for[prev_edge])
            push!(new_edge_map, edge_map[curr_edge])
        elseif !prev_collapsed && curr_collapsed
            # Previous survives, current collapsed
            # This vertex is at the START of a collapse run
            # Skip - the collapse point will be added when we exit the run
            continue
        else
            # Neither collapsed - vertex survives at advanced position
            push!(new_pts, advanced_pts[i])
            push!(new_edge_map, edge_map[curr_edge])
        end
    end
    
    return new_pts, new_edge_map
end

"""Build new polygon after batch collapse, also tracking weights."""
function _build_collapsed_polygon_weighted(
    advanced_pts::Vector{NTuple{2,Float64}},
    edge_map::Vector{Int},
    weight_map::Vector{Float64},
    n_active::Int,
    collapse_set::Set{Int},
    collapse_pt_for::Dict{Int, NTuple{2,Float64}}
)
    new_pts = NTuple{2,Float64}[]
    new_edge_map = Int[]
    new_weight_map = Float64[]
    
    for i in 1:n_active
        prev_edge = mod1(i - 1, n_active)
        curr_edge = i
        
        prev_collapsed = prev_edge in collapse_set
        curr_collapsed = curr_edge in collapse_set
        
        if prev_collapsed && curr_collapsed
            continue
        elseif prev_collapsed && !curr_collapsed
            push!(new_pts, collapse_pt_for[prev_edge])
            push!(new_edge_map, edge_map[curr_edge])
            push!(new_weight_map, weight_map[curr_edge])
        elseif !prev_collapsed && curr_collapsed
            continue
        else
            push!(new_pts, advanced_pts[i])
            push!(new_edge_map, edge_map[curr_edge])
            push!(new_weight_map, weight_map[curr_edge])
        end
    end
    
    return new_pts, new_edge_map, new_weight_map
end
