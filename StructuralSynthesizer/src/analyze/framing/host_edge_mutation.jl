"""
Add (or dedup) a landing vertex on host `edge` at parameter `u`; record it in
`edge_mids[edge]` when it is strictly interior to the edge (so the host is later
split there). Landings that coincide with an existing edge endpoint (`u ≈ 0/1`)
reuse that vertex and are NOT recorded as split points. Returns the vertex index.
"""
function _landing_vertex!(skel, edge::Int, u::Float64, xy::NTuple{2, Float64},
                          z_m::Float64, edge_mids::Dict{Int, Vector{Tuple{Float64, Int}}};
                          tol::Float64 = 1e-3)
    # Reuse the host endpoint when the landing is within `tol` metres of it.
    # A parameter test of 1e-6 left a vertex a fraction of a millimetre off the
    # end, and the joist then stopped on that vertex instead of the beam.
    v1, v2 = skel.edge_indices[edge]
    p1 = _vertex_xy_m(skel, v1)
    p2 = _vertex_xy_m(skel, v2)
    hypot(xy[1] - p1[1], xy[2] - p1[2]) <= tol && return v1
    hypot(xy[1] - p2[1], xy[2] - p2[2]) <= tol && return v2
    v = _nearest_story_vertex(skel, xy, z_m; tol = tol)
    if v === nothing
        v = add_vertex!(skel, [xy[1], xy[2], z_m]; group = :framing_landings)
    end
    (v == v1 || v == v2) && return v
    push!(get!(Vector{Tuple{Float64, Int}}, edge_mids, edge), (u, v))
    return v
end

"""A vertex within `tol` metres of `xy` at elevation `z_m`, or `nothing`."""
function _nearest_story_vertex(skel, xy::NTuple{2, Float64}, z_m::Float64;
                               tol::Float64 = 1e-3)
    best = nothing
    best_d = tol
    for v in eachindex(skel.vertices)
        abs(_vertex_z_m(skel, v) - z_m) <= tol || continue
        p = _vertex_xy_m(skel, v)
        d = hypot(p[1] - xy[1], p[2] - xy[2])
        d <= best_d || continue
        best = v
        best_d = d
    end
    return best
end

"""
Split host edge `E` of `host` (a beam or a wall) at the ordered interior
vertices `mids` (v1-side → v2-side), reusing `edge_chains`. Index-stable: the
first sub-edge reuses `E`; the rest are appended. New sub-segments replace
that one segment in the host's `segment_indices`. The member's other edges
stay. Interior joints are `:fixed`, and the outer releases of the split
edge are preserved.

A beam's length is the sum of its pieces. A wall's `base.L` is the pier
height, not the plan length, so a wall split does not rewrite it.
"""
function _split_host_edge!(struc::BuildingStructure, host::AbstractMember{T}, E::Int,
                           mids::Vector{Int}) where {T}
    skel = struc.skeleton
    v1, v2 = skel.edge_indices[E]
    # A landing that falls on an end, or on the previous landing, is not a
    # piece. A zero-length piece is not an element.
    chain_vs = Int[v1]
    for v in mids
        _vertices_coincide(skel, chain_vs[end], v) && continue
        push!(chain_vs, v)
    end
    _vertices_coincide(skel, chain_vs[end], v2) || push!(chain_vs, v2)
    n_sub = length(chain_vs) - 1
    n_sub < 2 && return                       # nothing to split
    mids = chain_vs[2:end-1]
    host_group = _edge_group(skel, E)

    seg_E_idx = findfirst(s -> s.edge_idx == E, struc.segments)
    seg_E_idx === nothing && return
    orig_seg = struc.segments[seg_E_idx]
    orig_rs, orig_re, orig_Cb = orig_seg.release_start, orig_seg.release_end, orig_seg.Cb

    sub_edges = Int[E]
    _rewire_edge!(skel, E, chain_vs[1], chain_vs[2])
    for k in 2:n_sub
        e_new = add_element!(skel, chain_vs[k], chain_vs[k + 1]; group = host_group)
        push!(sub_edges, e_new)
    end

    chain_seg_indices = Int[]
    for (k, e_sub) in enumerate(sub_edges)
        L_T = _len_T(T, Meshes.measure(skel.edges[e_sub]))
        rs = k == 1     ? orig_rs : :fixed     # interior joints stay continuous
        re = k == n_sub ? orig_re : :fixed
        if k == 1
            orig_seg.L = L_T
            orig_seg.Lb = L_T
            orig_seg.release_start = rs
            orig_seg.release_end = re
            push!(chain_seg_indices, seg_E_idx)
        else
            push!(struc.segments,
                  Segment(e_sub, L_T; Lb = L_T, Cb = orig_Cb,
                          release_start = rs, release_end = re))
            push!(chain_seg_indices, length(struc.segments))
        end
    end

    # Replace only the split segment. Assigning the new pieces over the whole
    # list drops every other edge of a girder that is already a chain, and a
    # joist landing on a dropped edge then has no member to share a node with.
    prior = collect(Int, segment_indices(host))
    at = findfirst(==(seg_E_idx), prior)
    threaded = at === nothing ? chain_seg_indices :
        [prior[1:(at - 1)]; chain_seg_indices; prior[(at + 1):end]]
    host.base.segment_indices = threaded
    # A wall's length is the pier height. The pieces are the plan line only.
    if !(host isa Wall)
        host.base.L = sum(struc.segments[si].L for si in threaded)
        host.base.Lb = maximum(struc.segments[si].Lb for si in threaded)
    end

    # 2c. Update face-vertex and face-edge indices for all faces containing E
    #     to preserve topological consistency and CCW winding (defect P11).
    for f in 1:length(skel.face_edge_indices)
        f_edges = skel.face_edge_indices[f]
        E_idx = findfirst(==(E), f_edges)
        E_idx === nothing && continue

        f_verts = skel.face_vertex_indices[f]
        old_v_indices = copy(f_verts)

        # Orientation: is the face traversing E as v1->v2 or v2->v1?
        # f_edges[E_idx] connects f_verts[E_idx] and f_verts[next].
        if f_verts[E_idx] == v1
            # v1 -> v2: insert mids and sub_edges[2:end] after E
            splice!(f_verts, E_idx+1:E_idx, mids)
            splice!(f_edges, E_idx+1:E_idx, sub_edges[2:end])
        else
            # v2 -> v1: replace E with reverse(sub_edges) and insert reverse(mids)
            splice!(f_verts, E_idx+1:E_idx, reverse(mids))
            splice!(f_edges, E_idx:E_idx, reverse(sub_edges))
        end

        # Update lookup if enabled
        if skel.lookup !== nothing
            delete!(skel.lookup.face_index, sort(old_v_indices))
            skel.lookup.face_index[sort(f_verts)] = f
        end

        # Update Meshes.Polygon object for area/normal consistency
        skel.faces[f] = Meshes.Ngon(skel.vertices[f_verts]...)
    end

    # Keep an existing chain whole. A second chain of only the new pieces
    # would claim the same edges.
    chained = false
    for chain in values(skel.edge_chains)
        i = findfirst(==(E), chain)
        i === nothing && continue
        splice!(chain, i, sub_edges)
        chained = true
    end
    if !chained
        skel.edge_chains[hash((:framing_host_chain, E))] = copy(sub_edges)
    end
    return
end

"""Rewire existing edge index `E` to connect vertices `a → b` (graph + lookup)."""
function _rewire_edge!(skel, E::Int, a::Int, b::Int)
    old = skel.edge_indices[E]
    skel.edges[E] = Meshes.Segment(skel.vertices[a], skel.vertices[b])
    skel.edge_indices[E] = (a, b)
    Graphs.rem_edge!(skel.graph, old[1], old[2])
    Graphs.add_edge!(skel.graph, a, b)
    if skel.lookup !== nothing
        delete!(skel.lookup.edge_index, (old[1], old[2]))
        delete!(skel.lookup.edge_index, (old[2], old[1]))
        skel.lookup.edge_index[(a, b)] = E
        skel.lookup.edge_index[(b, a)] = E
    end
    return
end

"""Group symbol an edge index belongs to (first match), or `:beams`."""
function _edge_group(skel, E::Int)
    for (g, edges) in skel.groups_edges
        E in edges && return g
    end
    return :beams
end
