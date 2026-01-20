# =============================================================================
# Straight Skeleton using DCEL (Isotropic Tributary Areas)
# =============================================================================

"""
    get_tributary_polygons_isotropic_dcel(vertices::Vector{<:Point})

Compute tributary polygons using straight skeleton with DCEL data structure.
Returns Vector{TributaryResult}, one per original edge.

This implementation properly handles simultaneous collapse events by recording
skeleton arcs (vertex trajectories) and using angular ordering to stitch faces.
"""
function get_tributary_polygons_isotropic_dcel(vertices::Vector{<:Point})
    m = length(vertices)  # Original vertex count
    m >= 3 || return TributaryResult[]
    
    # Convert to simple 2D coords
    pts_orig = [_to_2d(v) for v in vertices]
    
    # Ensure CCW orientation (algorithm assumes interior is on LEFT)
    pts_orig = _ensure_ccw(pts_orig)
    original_pts = copy(pts_orig)  # Keep for area calculation
    
    # Simplify collinear vertices (removes 180° degeneracies)
    pts, keep_idx = simplify_collinear_polygon(pts_orig; tol=1e-12)
    n = length(pts)
    n >= 3 || return TributaryResult[]  # Degenerate after simplification
    
    # Build mapping: orig_to_simp[i] = simplified edge that contains original edge i
    orig_to_simp = fill(0, m)
    n_s = length(keep_idx)
    for k in 1:n_s
        a = keep_idx[k]
        b = keep_idx[mod1(k + 1, n_s)]
        i = a
        while i != b
            orig_to_simp[i] = k
            i = mod1(i + 1, m)
        end
    end
    
    if !_is_convex(pts)
        @warn "Non-convex polygon detected — DCEL algorithm handles convex only"
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
    
    # Track which original edges are still active
    edge_active = trues(n)
    
    while n_active > 2
        # Compute bisectors at each active vertex
        bisectors, speeds = _compute_bisectors_dcel(current_pts, n_active)
        
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
            break
        end
        
        # Build new polygon handling batch collapses
        new_current_pts, new_edge_map = _build_collapsed_polygon_dcel(
            new_pts, edge_map, n_active, collapse_set, collapse_pt_for
        )
        
        # Update state
        current_pts = new_current_pts
        edge_map = new_edge_map
        n_active = length(current_pts)
    end
    
    # =========================================================================
    # Step 3: Final convergence - remaining vertices meet at center
    # =========================================================================
    if n_active >= 2
        bisectors, speeds = _compute_bisectors_dcel(current_pts, n_active)
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

"""Compute bisectors and speeds for active vertices."""
function _compute_bisectors_dcel(pts::Vector{NTuple{2,Float64}}, n::Int)
    bisectors = Vector{NTuple{2,Float64}}(undef, n)
    speeds = Vector{Float64}(undef, n)
    
    for i in 1:n
        prev_i = mod1(i - 1, n)
        next_i = mod1(i + 1, n)
        
        p_prev = pts[prev_i]
        p_curr = pts[i]
        p_next = pts[next_i]
        
        v_in = (p_curr[1] - p_prev[1], p_curr[2] - p_prev[2])
        v_out = (p_next[1] - p_curr[1], p_next[2] - p_curr[2])
        
        len_in = hypot(v_in...)
        len_out = hypot(v_out...)
        
        if len_in < 1e-10 || len_out < 1e-10
            bisectors[i] = (0.0, 0.0)
            speeds[i] = 0.0
            continue
        end
        
        v_in = v_in ./ len_in
        v_out = v_out ./ len_out
        
        # Inward normals (90° CCW rotation)
        n_in = (-v_in[2], v_in[1])
        n_out = (-v_out[2], v_out[1])
        
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

"""Ray-ray intersection time."""
function _ray_ray_intersect_time_dcel(p1, d1, p2, d2)
    dx = d1[1] - d2[1]
    dy = d1[2] - d2[2]
    px = p2[1] - p1[1]
    py = p2[2] - p1[2]
    
    if abs(dx) >= abs(dy)
        abs(dx) < 1e-10 && return Inf
        return px / dx
    else
        abs(dy) < 1e-10 && return Inf
        return py / dy
    end
end

"""Build new polygon after batch collapse."""
function _build_collapsed_polygon_dcel(
    advanced_pts::Vector{NTuple{2,Float64}},
    edge_map::Vector{Int},
    n_active::Int,
    collapse_set::Set{Int},
    collapse_pt_for::Dict{Int, NTuple{2,Float64}}
)
    new_pts = NTuple{2,Float64}[]
    new_edge_map = Int[]
    
    # Check for wrap-around
    wrap_around = (1 in collapse_set) && (n_active in collapse_set)
    
    # Find first non-collapsed index
    start_idx = 1
    if wrap_around
        for i in 1:n_active
            if !(i in collapse_set)
                start_idx = i
                break
            end
        end
    end
    
    visited = 0
    i = start_idx
    
    while visited < n_active
        if i in collapse_set
            # Collapse run
            run_pts = NTuple{2,Float64}[]
            while i in collapse_set && visited < n_active
                push!(run_pts, collapse_pt_for[i])
                visited += 1
                i = mod1(i + 1, n_active)
            end
            
            # Average collapse points
            avg_pt = (
                sum(p[1] for p in run_pts) / length(run_pts),
                sum(p[2] for p in run_pts) / length(run_pts)
            )
            
            push!(new_pts, avg_pt)
            
            if !(i in collapse_set) && visited < n_active
                push!(new_edge_map, edge_map[i])
            elseif !isempty(new_edge_map)
                push!(new_edge_map, new_edge_map[1])
            end
        else
            push!(new_pts, advanced_pts[i])
            push!(new_edge_map, edge_map[i])
            visited += 1
            i = mod1(i + 1, n_active)
        end
    end
    
    return new_pts, new_edge_map
end
