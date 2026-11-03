# =============================================================================
# Slab grouping helpers
# =============================================================================

"""
    build_slab_groups!(struc::BuildingStructure)

Populate `struc.slab_groups` from `struc.slabs` using `Slab.group_id`.

- If `slab.group_id === nothing`, the slab is treated as its own singleton group
  and a deterministic `UInt64` group id is assigned.
- If `slab.group_id` is set, all slabs with the same id are grouped together.
"""
function build_slab_groups!(struc::BuildingStructure)
    empty!(struc.slab_groups)

    for (s_idx, s) in enumerate(struc.slabs)
        gid = s.group_id === nothing ? UInt64(hash((:singleton_slab_group, s_idx))) : UInt64(s.group_id)
        s.group_id = gid

        sg = get!(struc.slab_groups, gid) do
            SlabGroup(gid)
        end

        push!(sg.slab_indices, s_idx)
    end

    return struc.slab_groups
end

# =============================================================================
# Cell Grouping (for tributary area optimization)
# =============================================================================

"""
    build_cell_groups!(struc::BuildingStructure)

Group cells by rotation-invariant geometry for tributary computation.
- For isotropic cells: groups cells with same shape (rotation + reflection invariant)
- For one-way cells: groups cells with same shape AND same relative span direction

Cells in the same group share identical parametric tributary polygons (computed once).
"""
function build_cell_groups!(struc::BuildingStructure)
    empty!(struc.cell_groups)

    for (c_idx, cell) in enumerate(struc.cells)
        key = _cell_group_hash(struc, cell)

        cg = get!(struc.cell_groups, key) do
            CellGroup(key)
        end
        push!(cg.cell_indices, c_idx)
    end

    return struc.cell_groups
end

"""
Hash cell by rotation-invariant geometry signature.

For isotropic cells (spans.axis ≈ (0,0)): hash only the canonical geometry.
For one-way cells: hash canonical geometry + canonical span edge index.
"""
function _cell_group_hash(struc::BuildingStructure, cell::Cell)
    canon_sig, canon_start, is_reversed = _cell_geometry_signature(struc, cell)
    
    # Check if isotropic (axis ≈ zero)
    axis = cell.spans.axis
    is_isotropic = hypot(axis[1], axis[2]) < 1e-9
    
    if is_isotropic
        # Isotropic: only geometry matters (full rotation + reflection invariance)
        return UInt64(hash(canon_sig))
    else
        # One-way: include canonical span edge index
        n_edges = length(canon_sig)
        span_edge_idx = _find_span_edge_index(struc, cell)
        canon_span_idx = _canonicalize_edge_index(span_edge_idx, canon_start, is_reversed, n_edges)
        return UInt64(hash((canon_sig, canon_span_idx)))
    end
end

"""
Compute rotation+reflection invariant geometry signature.

Returns:
- `canon_sig`: Canonical feature sequence (edge_length, interior_angle) tuples
- `canon_start`: Starting vertex index in the canonical form
- `is_reversed`: Whether the canonical form is the reversed (reflected) sequence
"""
function _cell_geometry_signature(struc::BuildingStructure, cell::Cell)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    v_indices = skel.face_vertex_indices[cell.face_idx]
    
    coords = [(vc[vi, 1], vc[vi, 2]) for vi in v_indices]
    features = _compute_polygon_features(coords)
    return _find_canonical_form(features)
end

"""Compute (edge_length, interior_angle) for each vertex."""
function _compute_polygon_features(coords::AbstractVector{<:NTuple{2, <:Real}})
    n = length(coords)
    features = NTuple{2, Float64}[]
    
    for i in 1:n
        # Edge from vertex i to i+1
        p1 = coords[i]
        p2 = coords[mod1(i + 1, n)]
        edge_len = round(hypot(p2[1] - p1[1], p2[2] - p1[2]), digits=6)
        
        # Interior angle at vertex i (angle between edge i-1→i and edge i→i+1)
        p0 = coords[mod1(i - 1, n)]
        v1 = (p1[1] - p0[1], p1[2] - p0[2])  # incoming edge
        v2 = (p2[1] - p1[1], p2[2] - p1[2])  # outgoing edge
        
        # Angle via atan2 of cross and dot products
        cross = v1[1] * v2[2] - v1[2] * v2[1]
        dot = v1[1] * v2[1] + v1[2] * v2[2]
        angle = round(atan(cross, dot), digits=6)  # Signed angle (-π to π)
        
        push!(features, (edge_len, angle))
    end
    
    return features
end

"""
Find the lexicographically smallest rotation, checking both forward and reversed sequences.

Returns (canonical_sequence, start_index, is_reversed).
"""
function _find_canonical_form(features::AbstractVector{<:NTuple{2, <:Real}})
    n = length(features)
    
    # Try all rotations of forward sequence
    best_seq = features
    best_start = 1
    best_reversed = false
    
    for start in 1:n
        rotated = _circshift_features(features, start)
        if rotated < best_seq
            best_seq = rotated
            best_start = start
            best_reversed = false
        end
    end
    
    # Try all rotations of reversed sequence (handles reflection)
    # When reversed, edge i becomes edge n-i, and angles flip sign
    reversed_features = [(features[mod1(n - i + 1, n)][1], -features[mod1(n - i + 2, n)][2]) 
                         for i in 1:n]
    
    for start in 1:n
        rotated = _circshift_features(reversed_features, start)
        if rotated < best_seq
            best_seq = rotated
            best_start = start
            best_reversed = true
        end
    end
    
    # Convert to tuple for hashing
    canon_tuple = Tuple(round.(v, digits=6) for v in best_seq)
    return canon_tuple, best_start, best_reversed
end

"""Circular shift returning a new vector starting at index `start`."""
function _circshift_features(v::AbstractVector{<:NTuple{2, <:Real}}, start::Int)
    n = length(v)
    return [v[mod1(start + i - 1, n)] for i in 1:n]
end

"""
Find which edge index (1-based, CCW order) the span axis is most parallel to.

For one-way systems, the span direction is perpendicular to the supporting edges.
This returns the index of the edge that best aligns with the span direction.
"""
function _find_span_edge_index(struc::BuildingStructure, cell::Cell)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    v_indices = skel.face_vertex_indices[cell.face_idx]
    n = length(v_indices)
    
    axis = cell.spans.axis
    ax_norm = hypot(axis[1], axis[2])
    ax_norm < 1e-9 && return 0  # Isotropic, no meaningful edge
    
    ax_unit = (axis[1] / ax_norm, axis[2] / ax_norm)
    
    best_idx = 1
    best_alignment = -Inf
    
    for i in 1:n
        vi1 = v_indices[i]
        vi2 = v_indices[mod1(i + 1, n)]
        dx = vc[vi2, 1] - vc[vi1, 1]
        dy = vc[vi2, 2] - vc[vi1, 2]
        edge_len = hypot(dx, dy)
        edge_len < 1e-9 && continue
        
        alignment = abs(ax_unit[1] * dx/edge_len + ax_unit[2] * dy/edge_len)
        if alignment > best_alignment
            best_alignment = alignment
            best_idx = i
        end
    end
    
    return best_idx
end

"""Transform edge index through canonicalization (rotation + optional reversal)."""
function _canonicalize_edge_index(edge_idx::Int, canon_start::Int, is_reversed::Bool, n::Int)
    if is_reversed
        # Reversal maps edge i → edge (n - i + 1), then apply rotation
        reversed_idx = mod1(n - edge_idx + 1, n)
        return mod1(reversed_idx - canon_start + 1, n)
    else
        # Just rotation
        return mod1(edge_idx - canon_start + 1, n)
    end
end

