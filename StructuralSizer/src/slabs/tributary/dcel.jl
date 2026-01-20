# =============================================================================
# DCEL (Doubly Connected Edge List) for Straight Skeleton
# =============================================================================

"""
DCEL vertex with position and one outgoing halfedge reference.
"""
mutable struct DCELVertex
    p::NTuple{2,Float64}
    out::Int  # Index of one outgoing halfedge (0 if isolated)
end

"""
DCEL halfedge with twin, next, prev pointers and face label.
"""
mutable struct HalfEdge
    origin::Int       # Vertex index
    twin::Int         # Halfedge index of twin
    next::Int         # Halfedge index of next in face cycle
    prev::Int         # Halfedge index of prev in face cycle
    face::Int         # Face ID (0 = outside, 1..n = tributary faces)
    is_skeleton::Bool # True if this is a skeleton edge (separates faces)
end

"""
DCEL face with ID and one boundary halfedge reference.
"""
mutable struct DCELFace
    id::Int
    edge::Int  # Index of one halfedge on boundary (0 if empty)
end

"""
Complete DCEL structure for straight skeleton.
"""
mutable struct DCEL
    V::Vector{DCELVertex}
    E::Vector{HalfEdge}
    F::Vector{DCELFace}
end

DCEL() = DCEL(DCELVertex[], HalfEdge[], DCELFace[])

# =============================================================================
# Vertex Registry (position-based deduplication)
# =============================================================================

"""
Registry for deduplicating vertices by position within tolerance.
"""
struct VertexRegistry
    tol::Float64
    map::Dict{Tuple{Int,Int}, Int}
    dcel::DCEL
end

VertexRegistry(dcel::DCEL; tol::Float64=1e-9) = VertexRegistry(tol, Dict{Tuple{Int,Int}, Int}(), dcel)

"""Compute hash key for position (quantized to tolerance grid)."""
_vertex_key(p::NTuple{2,Float64}, tol::Float64) = (round(Int, p[1] / tol), round(Int, p[2] / tol))

"""
Get existing vertex index or create new vertex at position p.
Returns vertex index in DCEL.
"""
function get_or_create_vertex!(reg::VertexRegistry, p::NTuple{2,Float64})
    key = _vertex_key(p, reg.tol)
    idx = get(reg.map, key, 0)
    if idx == 0
        # Create new vertex
        push!(reg.dcel.V, DCELVertex(p, 0))
        idx = length(reg.dcel.V)
        reg.map[key] = idx
    end
    return idx
end

"""Check if vertex exists at position."""
has_vertex(reg::VertexRegistry, p::NTuple{2,Float64}) = haskey(reg.map, _vertex_key(p, reg.tol))

"""Get vertex index if exists, else 0."""
function get_vertex(reg::VertexRegistry, p::NTuple{2,Float64})
    return get(reg.map, _vertex_key(p, reg.tol), 0)
end

# =============================================================================
# Halfedge Construction
# =============================================================================

"""
Create a pair of twin halfedges between vertices v1 and v2.
h1: v1 → v2 with face = face1
h2: v2 → v1 with face = face2
If is_skeleton=true, marks these as skeleton edges (face separators).
Returns (h1_idx, h2_idx).
"""
function create_halfedge_pair!(dcel::DCEL, v1::Int, v2::Int, face1::Int, face2::Int; is_skeleton::Bool=false)
    h1 = HalfEdge(v1, 0, 0, 0, face1, is_skeleton)
    h2 = HalfEdge(v2, 0, 0, 0, face2, is_skeleton)
    
    push!(dcel.E, h1)
    h1_idx = length(dcel.E)
    push!(dcel.E, h2)
    h2_idx = length(dcel.E)
    
    # Set twin pointers
    dcel.E[h1_idx].twin = h2_idx
    dcel.E[h2_idx].twin = h1_idx
    
    # Update vertex out pointers (if not set)
    if dcel.V[v1].out == 0
        dcel.V[v1].out = h1_idx
    end
    if dcel.V[v2].out == 0
        dcel.V[v2].out = h2_idx
    end
    
    return h1_idx, h2_idx
end

"""Get destination vertex of halfedge h."""
dest(dcel::DCEL, h::Int) = dcel.E[dcel.E[h].twin].origin

"""Get position of vertex v."""
pos(dcel::DCEL, v::Int) = dcel.V[v].p

# =============================================================================
# Angular Ordering for next/prev
# =============================================================================

"""Compute angle of direction from origin to dest (in radians, [-π, π])."""
function _edge_angle(dcel::DCEL, h::Int)
    v_orig = dcel.E[h].origin
    v_dest = dest(dcel, h)
    p1 = pos(dcel, v_orig)
    p2 = pos(dcel, v_dest)
    return atan(p2[2] - p1[2], p2[1] - p1[1])
end

"""
Collect all outgoing halfedges from vertex v.
Returns vector of halfedge indices.
"""
function outgoing_halfedges(dcel::DCEL, v::Int)
    out = Int[]
    for (i, he) in enumerate(dcel.E)
        if he.origin == v
            push!(out, i)
        end
    end
    return out
end

"""
Collect all incoming halfedges to vertex v.
Returns vector of halfedge indices.
"""
function incoming_halfedges(dcel::DCEL, v::Int)
    inc = Int[]
    for i in 1:length(dcel.E)
        if dest(dcel, i) == v
            push!(inc, i)
        end
    end
    return inc
end

"""
Set next/prev pointers using standard DCEL rotation system.
This is the correct way to handle high-degree skeleton vertices.

Rule: next(h) = rotation_successor(twin(h))
Where rotation_successor gives the next outgoing edge CCW around a vertex.
"""
function compute_next_prev!(dcel::DCEL)
    # Clear next/prev
    for he in dcel.E
        he.next = 0
        he.prev = 0
    end
    
    # Outgoing halfedges per vertex
    outlists = [Int[] for _ in 1:length(dcel.V)]
    for h in 1:length(dcel.E)
        push!(outlists[dcel.E[h].origin], h)
    end
    
    # Rotation successor (CCW) around each vertex
    rot_next = fill(0, length(dcel.E))
    for v in 1:length(outlists)
        out = outlists[v]
        isempty(out) && continue
        
        # Sort CCW by geometric angle
        sort!(out, by = h -> _edge_angle(dcel, h))
        
        m = length(out)
        for i in 1:m
            rot_next[out[i]] = out[mod1(i+1, m)]
        end
    end
    
    # Standard DCEL rule: next(h) = rot_next(twin(h))
    for h in 1:length(dcel.E)
        t = dcel.E[h].twin
        t == 0 && continue
        dcel.E[h].next = rot_next[t]
    end
    
    # Fill prev pointers consistently
    for h in 1:length(dcel.E)
        nh = dcel.E[h].next
        nh != 0 && (dcel.E[nh].prev = h)
    end
end

# =============================================================================
# Face Construction and Extraction
# =============================================================================

"""
Create face with given ID and assign one boundary halfedge.
"""
function create_face!(dcel::DCEL, id::Int, boundary_edge::Int)
    push!(dcel.F, DCELFace(id, boundary_edge))
    return length(dcel.F)
end

"""
Walk a face cycle starting from halfedge h, respecting face boundaries.
Only follows edges that belong to the same face.
Returns vector of vertex positions forming the polygon boundary.
"""
function walk_face_cycle(dcel::DCEL, start_h::Int; max_steps::Int=10000)
    vertices = NTuple{2,Float64}[]
    target_face = dcel.E[start_h].face
    h = start_h
    steps = 0
    
    while true
        push!(vertices, pos(dcel, dcel.E[h].origin))
        
        # Get next halfedge
        h_next = dcel.E[h].next
        steps += 1
        
        # Stop conditions:
        # 1. Returned to start
        # 2. No next edge
        # 3. Too many steps (safety)
        # 4. Next edge belongs to different face (crossed a boundary!)
        if h_next == start_h || h_next == 0 || steps > max_steps
            break
        end
        
        # Check if we're about to cross into a different face
        if dcel.E[h_next].face != target_face
            # We've hit a face boundary - stop here
            # This shouldn't happen if next pointers are set correctly,
            # but it's a safety check
            # @warn "Face walk crossed boundary: face $target_face → face $(dcel.E[h_next].face) at step $steps"
            break
        end
        
        h = h_next
    end
    
    # Remove consecutive duplicates (from micro-spokes)
    return _dedup_consecutive(vertices)
end

"""
Find one halfedge for each face ID by scanning all halfedges.
Returns Dict{face_id => halfedge_index}.
"""
function find_face_halfedges(dcel::DCEL)
    face_edges = Dict{Int, Int}()
    for (i, he) in enumerate(dcel.E)
        if !haskey(face_edges, he.face)
            face_edges[he.face] = i
        end
    end
    return face_edges
end

"""
Remove consecutive duplicate vertices (from micro-spokes or multiple halfedges
at same coordinate). Also removes closing duplicate if last ≈ first.

Note: atol must be larger than micro-spoke eps (which is ~1e-8 * bbox_diag).
Using 1e-6 to safely catch micro-spoke artifacts without merging real vertices.
"""
function _dedup_consecutive(verts::Vector{NTuple{2,Float64}}; atol=1e-6)
    isempty(verts) && return verts
    out = NTuple{2,Float64}[verts[1]]
    for i in 2:length(verts)
        if hypot(verts[i][1] - out[end][1], verts[i][2] - out[end][2]) > atol
            push!(out, verts[i])
        end
    end
    # Drop if last equals first (cycle closure duplicate)
    if length(out) >= 2 && hypot(out[end][1] - out[1][1], out[end][2] - out[1][2]) <= atol
        pop!(out)
    end
    return out
end

"""
Extract polygon for face with given ID using DCEL cycle walk.
Returns vector of (x, y) tuples, or empty if face not found.
"""
function extract_face_polygon(dcel::DCEL, face_id::Int)
    # Find a halfedge on this face
    for (i, he) in enumerate(dcel.E)
        if he.face == face_id
            return walk_face_cycle(dcel, i)
        end
    end
    return NTuple{2,Float64}[]
end

"""
Extract polygon for face by collecting all halfedges with that face ID
and connecting them geometrically. This is a fallback method that doesn't
rely on next pointers being correct.

Handles disconnected chains by finding all vertices touched by face edges.
"""
function extract_face_polygon_by_edges(dcel::DCEL, face_id::Int)
    # Collect all halfedges belonging to this face (excluding zero-length self-loops)
    face_edges = Int[]
    for (i, he) in enumerate(dcel.E)
        if he.face == face_id
            # Skip zero-length self-loops (artificial bisectors)
            v_start = he.origin
            v_end = dest(dcel, i)
            if v_start != v_end  # Only include real edges
                push!(face_edges, i)
            end
        end
    end
    
    isempty(face_edges) && return NTuple{2,Float64}[]
    
    # Collect all unique vertices touched by this face's edges
    all_vertices = Set{Int}()
    for h in face_edges
        push!(all_vertices, dcel.E[h].origin)
        push!(all_vertices, dest(dcel, h))
    end
    
    # Build adjacency: for each vertex, which edges start/end there?
    vertex_out = Dict{Int, Vector{Int}}()
    
    for h in face_edges
        v_start = dcel.E[h].origin
        push!(get!(vertex_out, v_start, Int[]), h)
    end
    
    # Try to find a connected chain starting from each edge
    best_vertices = NTuple{2,Float64}[]
    
    for start_edge in face_edges
        vertices = NTuple{2,Float64}[]
        visited = Set{Int}()
        h = start_edge
        
        for _ in 1:length(face_edges) + 1
            h in visited && break
            push!(visited, h)
            
            v_origin = dcel.E[h].origin
            push!(vertices, pos(dcel, v_origin))
            
            # Find next edge: one that starts where this one ends
            v_end = dest(dcel, h)
            candidates = get(vertex_out, v_end, Int[])
            
            # Pick the first unvisited candidate
            h_next = 0
            for c in candidates
                if !(c in visited)
                    h_next = c
                    break
                end
            end
            
            h_next == 0 && break
            h = h_next
        end
        
        # Keep the longest chain found
        if length(vertices) > length(best_vertices)
            best_vertices = vertices
        end
        
        # If we've found all edges, we're done
        if length(visited) == length(face_edges)
            break
        end
    end
    
    # Remove consecutive duplicates
    return _dedup_consecutive(best_vertices)
end

# =============================================================================
# Artificial Bisector Insertion (for multi-degree vertices)
# =============================================================================

"""Compute bounding box diagonal of all vertices (for epsilon scaling)."""
function _bbox_diag(dcel::DCEL)
    isempty(dcel.V) && return 1.0
    xs = [v.p[1] for v in dcel.V]
    ys = [v.p[2] for v in dcel.V]
    return hypot(maximum(xs)-minimum(xs), maximum(ys)-minimum(ys))
end

"""Unit vector from angle."""
_angle_unit(a::Float64) = (cos(a), sin(a))

"""Create auxiliary vertex at tiny offset from p in direction dir."""
function create_aux_vertex!(reg::VertexRegistry, p::NTuple{2,Float64}, dir::NTuple{2,Float64}, eps::Float64)
    dlen = hypot(dir...)
    dlen < 1e-14 && return get_or_create_vertex!(reg, p)
    pe = (p[1] + eps*dir[1]/dlen, p[2] + eps*dir[2]/dlen)
    return get_or_create_vertex!(reg, pe)
end

"""
Insert artificial bisectors as MICRO-SPOKES (not self-loops!) at vertices 
where faces have incoming but no outgoing edges.

Self-loops (v→v) have undefined angles and break the rotation system.
Instead, we create tiny spokes v→v_aux where v_aux is at micro-offset.
"""
function insert_artificial_bisectors!(dcel::DCEL, reg::VertexRegistry; eps_scale=1e-8)
    diag = _bbox_diag(dcel)
    eps = eps_scale * max(diag, 1.0)
    
    inserted = 0
    
    for v in 1:length(dcel.V)
        out = outgoing_halfedges(dcel, v)
        inc = incoming_halfedges(dcel, v)
        
        isempty(out) && continue
        isempty(inc) && continue
        
        # Outgoing edges sorted CCW by angle
        sort!(out, by = h -> _edge_angle(dcel, h))
        
        # Faces present
        out_faces = Set(dcel.E[h].face for h in out if dcel.E[h].face != 0)
        inc_faces = Set(dcel.E[h].face for h in inc if dcel.E[h].face != 0)
        
        missing = collect(setdiff(inc_faces, out_faces))
        isempty(missing) && continue
        
        # For each missing face, insert a spoke roughly continuing its incoming direction
        for f in missing
            h_in_idx = findfirst(h -> dcel.E[h].face == f, inc)
            h_in_idx === nothing && continue
            h_in = inc[h_in_idx]
            
            # Incoming direction into v is angle of h_in (origin -> v)
            a_in = _edge_angle(dcel, h_in)
            # Continuation direction out of v is +π
            a_spoke = a_in + π
            dir = _angle_unit(a_spoke)
            
            # Choose an adjacent face to pair with (best aligned outgoing)
            best_out = 0
            best_diff = Inf
            for h_out in out
                a_out = _edge_angle(dcel, h_out)
                diff = abs(mod(a_out - a_spoke + π, 2π) - π)
                if diff < best_diff
                    best_diff = diff
                    best_out = h_out
                end
            end
            
            best_out == 0 && continue
            
            f_out = dcel.E[best_out].face
            p = dcel.V[v].p
            v_aux = create_aux_vertex!(reg, p, dir, eps)
            
            # Skeleton separator between faces f and f_out
            create_halfedge_pair!(dcel, v, v_aux, f, f_out; is_skeleton=true)
            inserted += 1
        end
    end
    
    return inserted
end

"""
Check if a vertex has unmatched faces (diagnostic function).
Returns list of faces that have incoming but no matching outgoing edge.
"""
function diagnose_vertex(dcel::DCEL, v::Int)
    unmatched = Int[]
    
    out_edges = outgoing_halfedges(dcel, v)
    in_edges = incoming_halfedges(dcel, v)
    
    out_faces = Set(dcel.E[h].face for h in out_edges if dcel.E[h].face != 0)
    in_faces = Set(dcel.E[h].face for h in in_edges if dcel.E[h].face != 0)
    
    # Faces that arrive but have no departure
    for f in in_faces
        if !(f in out_faces)
            push!(unmatched, f)
        end
    end
    
    return unmatched
end

# =============================================================================
# Validation
# =============================================================================

"""
Validate DCEL consistency. Returns (is_valid, error_messages).
"""
function validate_dcel(dcel::DCEL)
    errors = String[]
    
    # Check twin consistency
    for (i, he) in enumerate(dcel.E)
        if he.twin != 0
            if dcel.E[he.twin].twin != i
                push!(errors, "Halfedge $i: twin.twin != self")
            end
        end
    end
    
    # Check next/prev consistency
    for (i, he) in enumerate(dcel.E)
        if he.next != 0 && dcel.E[he.next].prev != i
            push!(errors, "Halfedge $i: next.prev != self")
        end
        if he.prev != 0 && dcel.E[he.prev].next != i
            push!(errors, "Halfedge $i: prev.next != self")
        end
    end
    
    # Check face cycles close
    face_edges = find_face_halfedges(dcel)
    for (fid, start_h) in face_edges
        h = start_h
        steps = 0
        while true
            h = dcel.E[h].next
            steps += 1
            if h == start_h
                break
            end
            if h == 0 || steps > length(dcel.E)
                push!(errors, "Face $fid: cycle does not close")
                break
            end
        end
    end
    
    return isempty(errors), errors
end
