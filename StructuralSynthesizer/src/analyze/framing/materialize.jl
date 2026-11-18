# -----------------------------------------------------------------------------
# materialize_level!
# -----------------------------------------------------------------------------

"""
Host edge a point lies on, or `nothing`.

Returns `(edge, parameter, foot)` in the edge's vertex order.
"""
function _host_landing(skel, host_edges, xy::NTuple{2, Float64}; tol::Float64 = 1e-3)
    best = nothing
    best_d = tol
    for e in host_edges
        v1, v2 = skel.edge_indices[e]
        p1 = _vertex_xy_m(skel, v1)
        p2 = _vertex_xy_m(skel, v2)
        t = _param_on_segment(xy, p1, p2; tol = tol)
        t === nothing && continue
        foot = (p1[1] + t * (p2[1] - p1[1]), p1[2] + t * (p2[2] - p1[2]))
        d = hypot(foot[1] - xy[1], foot[2] - xy[2])
        d <= best_d || continue
        best = (e, t, foot)
        best_d = d
    end
    return best
end

"""How many skeleton edges meet at `v`."""
_vertex_degree(skel, v::Int) = count(e -> v == e[1] || v == e[2], skel.edge_indices)

"""
Split the level-0 beam that `v` already lies on, when `v` is not on any edge yet.

A joist end can sit on a girder without being one of that girder's vertices.
The girder is cut there so the joist and the girder share the node.
"""
function _land_loose_end!(struc, v::Int; tol::Float64 = 1e-3)
    skel = struc.skeleton
    _vertex_degree(skel, v) > 0 && return nothing
    xy = _vertex_xy_m(skel, v)
    best = nothing
    best_d = tol
    for beam in struc.beams
        beam.level > 0 && continue
        for si in segment_indices(beam)
            si <= length(struc.segments) || continue
            e = struc.segments[si].edge_idx
            1 <= e <= length(skel.edge_indices) || continue
            v1, v2 = skel.edge_indices[e]
            (v == v1 || v == v2) && return nothing
            p1 = _vertex_xy_m(skel, v1)
            p2 = _vertex_xy_m(skel, v2)
            dx, dy = p2[1] - p1[1], p2[2] - p1[2]
            L2 = dx * dx + dy * dy
            L2 < 1e-12 && continue
            u = ((xy[1] - p1[1]) * dx + (xy[2] - p1[2]) * dy) / L2
            (-0.02 <= u <= 1.02) || continue
            u = clamp(u, 0.0, 1.0)
            d = hypot(xy[1] - (p1[1] + u * dx), xy[2] - (p1[2] + u * dy))
            d < best_d || continue
            best = (beam, e)
            best_d = d
        end
    end
    best === nothing && return nothing
    beam, e = best
    _split_host_edge!(struc, beam, e, [v])
    return e
end

"""
Put `v` on the host edge it already lies on, so a later split shares the node.

A joist end within `tol` metres of a host segment is recorded as a landing.
An end that is already a host endpoint is left alone.
"""
function _weld_vertex_onto_host!(skel, v::Int, host_edges, edge_mids; tol::Float64 = 1e-3)
    xy = _vertex_xy_m(skel, v)
    best = nothing
    best_d = tol
    best_u = 0.0
    for e in host_edges
        v1, v2 = skel.edge_indices[e]
        (v == v1 || v == v2) && return nothing
        p1 = _vertex_xy_m(skel, v1)
        p2 = _vertex_xy_m(skel, v2)
        dx, dy = p2[1] - p1[1], p2[2] - p1[2]
        L2 = dx * dx + dy * dy
        L2 < 1e-12 && continue
        u = ((xy[1] - p1[1]) * dx + (xy[2] - p1[2]) * dy) / L2
        (-0.02 <= u <= 1.02) || continue
        u = clamp(u, 0.0, 1.0)
        d = hypot(xy[1] - (p1[1] + u * dx), xy[2] - (p1[2] + u * dy))
        d <= best_d || continue
        best = e
        best_d = d
        best_u = u
    end
    best === nothing && return nothing
    mids = get!(Vector{Tuple{Float64, Int}}, edge_mids, best)
    any(m -> m[2] == v, mids) && return best
    push!(mids, (best_u, v))
    return best
end

"""
A vertex within `tol` of `v` that already lies on more beams, or `v`.

Used after hosts are split. A joist end a fraction of a millimetre off the
beam is moved onto the beam's node.
"""
function _snap_to_connected(skel, v::Int; tol::Float64 = 1e-3)
    xy = _vertex_xy_m(skel, v)
    z = _vertex_z_m(skel, v)
    best = v
    best_d = tol
    deg = _vertex_degree(skel, v)
    for u in eachindex(skel.vertices)
        u == v && continue
        du = _vertex_degree(skel, u)
        du > deg || continue
        abs(_vertex_z_m(skel, u) - z) <= tol || continue
        p = _vertex_xy_m(skel, u)
        d = hypot(p[1] - xy[1], p[2] - xy[2])
        d <= best_d || continue
        best = u
        best_d = d
        deg = du
    end
    return best
end

"""True when two skeleton vertices are the same point within `tol` metres."""
function _vertices_coincide(skel, a::Int, b::Int; tol::Float64 = 1e-3)
    a == b && return true
    pa = _vertex_xy_m(skel, a)
    pb = _vertex_xy_m(skel, b)
    hypot(pa[1] - pb[1], pa[2] - pb[2]) <= tol || return false
    return abs(_vertex_z_m(skel, a) - _vertex_z_m(skel, b)) <= tol
end

"""
Finite vertex chains for a `CustomPattern` whose sagitta is positive.

Returns `false` for every other pattern, including a custom rib with sagitta
`0` (that rib stays the chord). Endpoints that miss the slab boundary throw.
"""
function _append_curved_joist_chains!(struc, slab, level, skel, z_m, host_edges,
                                      edge_to_beam, joist_chains, edge_mids, landed_hosts)
    pat = level.pattern
    (pat isa CustomPattern && pat.sagitta > 0) || return false
    for pl in pat.generator(slab)
        length(pl) < 2 && continue
        pts = StructuralSizer.curved_rib_polyline(pl, pat.sagitta)
        chain_vs = Int[]
        for (k, xy) in enumerate(pts)
            hit = _host_landing(skel, host_edges, xy)
            if hit !== nothing
                e, u, foot = hit
                v = _landing_vertex!(skel, e, u, foot, z_m, edge_mids)
                host = get(edge_to_beam, e, 0)
                host != 0 && push!(landed_hosts, host)
            else
                (k == 1 || k == length(pts)) && throw(ArgumentError(
                    "a curved rib must start and end on the slab boundary"))
                v = add_vertex!(skel, [xy[1], xy[2], z_m]; group = :framing_landings)
            end
            (!isempty(chain_vs) && last(chain_vs) == v) && continue
            push!(chain_vs, v)
        end
        length(chain_vs) < 2 && continue
        push!(joist_chains, chain_vs)
    end
    return true
end

"""One joist beam on `indices`, appended to the level's bookkeeping."""
function _push_joist_beam!(struc::BuildingStructure{T}, level::FramingLevel{T},
                           indices::Vector{Int}, beam_indices, beam_solid, created,
                           is_solid::Bool) where {T}
    L_beam_T = sum(struc.segments[si].L for si in indices)
    Lb_beam_T = maximum(struc.segments[si].Lb for si in indices)
    beam = Beam(indices, L_beam_T; Lb = Lb_beam_T,
                role = level.role, level = level.level,
                lateral_role = :gravity, torsion_released = level.torsion_released)
    # Zero volume until sizing. `_volume_key` unwraps reinforced concrete so
    # `element_ec` can read `mat.ρ`.
    set_volumes!(beam, MaterialVolumes(_volume_key(level.material) => zero(VolumeType)))
    push!(struc.beams, beam)
    push!(beam_indices, length(struc.beams))
    push!(beam_solid, is_solid)
    push!(created, beam)
    return beam
end

"""
    materialize_level!(struc::BuildingStructure, slab::Slab{T}, level::FramingLevel{T}) -> Vector{Beam{T}}

Turn one [`FramingLevel`](@ref) into real `Beam{T}` members (plan
`joists-roles-materials`, Phase 5). Material-agnostic — the material lives on
`level` and is applied at sizing time via the member group. Returns the created
joist beams (empty if the pattern lays out no joists on this slab).

# Steps
1. **Pattern → polylines.** [`_pattern_joist_lines`](@ref) resolves
   `level.pattern` to joist center-lines in the slab's local 2D frame, using the
   slab's real geometry for extent/count (`count === nothing` ⇒ derived from the
   slab extent and spacing so joists span the bay).
2. **Landings + host subdivision.** Each joist line's two ends are intersected
   with the slab's outer boundary edges; a skeleton vertex is inserted at each
   landing and the host edge is split into a multi-segment `edge_chains` chain
   (same surgery as `api/deserialize.jl`). Host member indices are recorded in
   `level.supports`.
3. **Joist Segments.** One `Segment` per joist piece, with `release_start`/`release_end`
   taken from `level.end_fixity` (`:default` ⇒ resolved later by Phase 2's
   `resolve_release` through the Phase-3 `default_release` dispatch — no release
   mechanics are decided here).
4. **Joist Beams.** A one-way chain is one `Beam{T}` over its supports. A
   grillage rib is one beam per segment, so each piece borders a single cell
   and meets the next piece with a rigid joint. `role = level.role`,
   `level = level.level`, `lateral_role = :gravity`,
   `torsion_released = level.torsion_released`. The member material is recorded
   as a zero-volume `MaterialVolumes` entry (sizing overwrites it).
5. **MemberGroup.** A one-way level shares one group, `hash`ed from
   `(slab_idx, level, role, material)` and stamped on `level.group_id`.
   A grillage gives each rib piece its own group (`piece_group_ids`).
   Sizing options for the level, when they differ from the building, live on
   `level.beam_options`.

The layer-2+ tributary cascade (`compute_member_tributaries!`) is driven once by
[`populate_levels!`](@ref) after all levels are materialized, not per level.

!!! note "ENGINEERING JUDGMENT — lateral_role = :gravity"
    Auto-generated joists are created with `lateral_role = :gravity` (Phase 1
    convention: joists provide gravity load paths, not lateral-system
    participation, in the default model). This is a judgment default, not a code
    requirement; a caller wanting joists in the lateral system re-tags them
    afterward.

!!! note "Phase 7 seam (`:bridge` / `sync_asap!`)"
    Landings are recorded as real skeleton geometry (`edge_chains`), so a later
    `to_asap!` / `sync_asap!` sees the subdivided hosts and the joist edges
    directly — no `ParametricFrameElement` bridge is created here. Phase 7 wires
    seat eccentricity (`Element.eccentricity`) and shell-pressure routing on top
    of this geometry.
"""
function materialize_level!(struc::BuildingStructure, slab::Slab{T},
                            level::FramingLevel{T}) where {T}
    skel = struc.skeleton
    created = Beam{T}[]
    n_host_beams = length(struc.beams)
    grillage = rib_analysis(level) == :grillage
    level.pattern isa ModularRibPattern && !grillage && throw(ArgumentError(
        "a ModularRibPattern level is a grillage: its bays carry their own skeleton. " *
        "Set analysis = :grillage."))

    # Extent (for laying out joist positions) always uses the slab boundary —
    # a level-N joist spans the same slab bay. Hosts are the boundary, the
    # girders between this slab's cells, and this slab's walls. Level N ≥ 2
    # also lands on level-(N-1) beams. Interior girders and walls are already
    # in that host set, so a rib bay is the face those members enclose.
    # Every level also lands on the beam rings around the slab's holes.
    extent_edges = _slab_boundary_sub_edges(struc, slab)
    host_edges = _level_host_edges(struc, slab, level.level)
    extra_hosts = _slab_hole_edges(struc, slab)
    # Headers and trimmers of a framed opening are supports. An unframed
    # opening has none of these edges; the joist is cut at the outline below.
    opening_loops = _slab_opening_loops_m(struc, slab)
    append!(extra_hosts, _edges_along_loops(skel, opening_loops))
    isempty(extra_hosts) || (host_edges = unique!(sort!(vcat(host_edges, extra_hosts))))
    if isempty(host_edges) || isempty(extent_edges)
        level.group_id = _framing_group_id(level)   # mark materialized (idempotent)
        grillage && @warn "a grillage slab has no host or no boundary, so it grew no ribs" slab = level.slab_idx hosts = length(host_edges) extent = length(extent_edges)
        return created
    end

    # Floor elevation (all boundary edges of a slab are co-planar in Z).
    z_m = _vertex_z_m(skel, skel.edge_indices[first(extent_edges)][1])

    # edge → host beam index (for subdivision bookkeeping). Includes both
    # boundary sub-edges and level-(N-1) beam edges.
    edge_to_beam = _edge_to_beam_map(struc)

    # 1. Pattern → joist center-lines (p0, direction) in slab-local 2D meters,
    #    laid out over the SLAB extent (independent of the level's host set).
    #    A curved rib is a finite chain. An infinite line through its ends
    #    would cross the whole slab.
    joist_chains = Vector{Int}[]
    edge_mids = Dict{Int, Vector{Tuple{Float64, Int}}}()
    landed_hosts = Set{Int}()
    curved = _append_curved_joist_chains!(struc, slab, level, skel, z_m, host_edges,
                                          edge_to_beam, joist_chains, edge_mids, landed_hosts)
    lines = curved ? Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[] :
        _pattern_joist_lines(struc, slab, extent_edges, level.pattern)

    # Concave-safe clipping guard (#5). `_pattern_joist_lines` lays joists across
    # the perpendicular bounding-extent of the slab and `_boundary_intersections`
    # casts an INFINITE line, so on a re-entrant (non-convex) slab a joist chain
    # built from ALL crossings would span a re-entrant notch (through the
    # exterior) or land outside the plate. When the slab's TRUE outer boundary is
    # non-convex we clip each joist line to its interior sub-span(s) (see
    # `_interior_subchains`). On a convex/rectangular boundary the whole span
    # between the two crossings is interior, so the clip is a strict no-op and the
    # layout is byte-identical to the pre-clip behavior — this guard skips the
    # clip path entirely for convex slabs. Pure geometry (no code provision).
    # A slab with a beam ring inside it is clipped the same way, so no joist
    # crosses the void the ring encloses.
    interior_poly = _slab_interior_polygon_m(struc, slab)
    hole_loops = _slab_hole_loops_m(struc, slab)
    clip_interior = interior_poly !== nothing &&
        (!Asap.is_convex_polygon(interior_poly) || !isempty(hole_loops))

    # 2. Resolve landings for each joist line.
    #    joist_chains :: Vector{Vector{Int}}  — ordered chain vertices per joist.
    #    edge_mids    :: Dict{host_edge => Vector{(param_u, vertex_idx)}}
    for (p0, dir) in lines
        hits = _boundary_intersections(struc, host_edges, p0, dir)
        length(hits) < 2 && continue

        # (Phase 10) Collect ALL landings along the joist line, in order — not
        # just the two extremes. Each host edge crossing becomes an interior
        # support on the joist chain; consecutive-duplicate vertices (from
        # sharing an edge endpoint between adjacent hits) are dropped so the
        # chain is topologically clean. `chain_xy`/`chain_hosts` run parallel to
        # `chain_vs` for the concave clip (midpoint interiority) and host
        # bookkeeping.
        chain_vs = Int[]
        chain_xy = NTuple{2, Float64}[]
        chain_hosts = Int[]                       # host beam idx per vertex (0 ⇒ none)
        for (e, u, xy) in hits
            v = _landing_vertex!(skel, e, u, xy, z_m, edge_mids)
            (!isempty(chain_vs) && last(chain_vs) == v) && continue
            push!(chain_vs, v)
            push!(chain_xy, xy)
            push!(chain_hosts, get(edge_to_beam, e, 0))
        end
        length(chain_vs) < 2 && continue

        # Convex slab (or unresolved boundary): keep the full chain — the entire
        # span between the two boundary crossings is interior (no-op clip,
        # byte-identical to prior behavior). Non-convex slab: split into
        # interior-only sub-chains so no segment crosses a re-entrant notch.
        subchains = clip_interior ?
            _interior_subchains(chain_xy, interior_poly; holes = hole_loops) :
            Vector{Int}[collect(1:length(chain_vs))]

        for idxs in subchains
            length(idxs) < 2 && continue
            push!(joist_chains, chain_vs[idxs])
            for i in idxs
                chain_hosts[i] != 0 && push!(landed_hosts, chain_hosts[i])
            end
        end
    end

    # An unframed opening is not a support. The joist stops at its edge: one
    # supported end is a cantilever (fixed at the support, free at the opening),
    # and a piece with no support is omitted. A framed opening's header is
    # already a landing, so those pieces stay supported at both ends.
    chain_releases = nothing
    if !isempty(opening_loops)
        landings = Set{Int}(v for mids in values(edge_mids) for (_, v) in mids)
        joist_chains, chain_releases = _clip_chains_at_openings!(
            skel, joist_chains, opening_loops, z_m, landings, level.end_fixity)
    end

    # A solid head cuts the joists, and queues the same cuts on the perimeter
    # girders, before those girders are split. No head leaves the chains as
    # they were built. Opening releases pass through that cut.
    joist_chains, joist_releases, joist_solid, head_panel = _cut_joists_at_solid_head!(
        struc, slab, level, skel, z_m, extent_edges, joist_chains, edge_mids;
        chain_releases = chain_releases)

    # Joists of one level that cross share a node there, so a two-way grid is
    # one frame. ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101) asks the
    # analysis for compatibility as well as equilibrium; two ribs that pass
    # through each other without a node would deflect independently.
    landings = Set{Int}(v for mids in values(edge_mids) for (_, v) in mids)
    joist_chains = _node_chain_crossings!(skel, joist_chains, z_m; tol = 1e-3, keep = landings)

    # A joist end that lies on a beam but is not yet one of its vertices would
    # stop a fraction of a millimetre off that beam. The beam may belong to
    # the next slab, so it is not always in this slab's host list. Weld the
    # end onto whichever beam it already lies on, before the split.
    beam_edges = Int[]
    for beam in struc.beams, si in segment_indices(beam)
        1 <= si <= length(struc.segments) || continue
        push!(beam_edges, struc.segments[si].edge_idx)
    end
    unique!(beam_edges)
    for chain in joist_chains
        length(chain) < 2 && continue
        _weld_vertex_onto_host!(skel, chain[1], beam_edges, edge_mids)
        _weld_vertex_onto_host!(skel, chain[end], beam_edges, edge_mids)
    end

    # 2b. Split each host edge once with all its (sorted) landing vertices.
    for (host_edge, mids) in edge_mids
        isempty(mids) && continue
        host = _member_for_edge(struc, host_edge)
        host === nothing && continue
        sort!(mids; by = first)                       # order along v1 → v2
        mid_vertices = [v for (_, v) in mids]
        _split_host_edge!(struc, host, host_edge, mid_vertices)
    end

    # 3–4. Segments and beams. A one-way chain with `k` vertices is one Beam
    #      of `k-1` segments: interior joints stay `:fixed`, and only the two
    #      chain ends honor `level.end_fixity`. A grillage rib is one beam per
    #      segment, rigid at every node it shares with the next piece, so each
    #      piece can take its own section. A solid-head chain stays one beam.
    joist_group = level.level == 1 ? :joists : :secondary
    beam_indices = Int[]
    beam_solid = Bool[]
    for (ci, raw_chain) in enumerate(joist_chains)
        raw_chain = length(raw_chain) < 2 ? raw_chain :
            [ _snap_to_connected(skel, raw_chain[1]);
              raw_chain[2:end-1];
              _snap_to_connected(skel, raw_chain[end]) ]
        _land_loose_end!(struc, raw_chain[1])
        _land_loose_end!(struc, raw_chain[end])
        chain_vs = Int[raw_chain[1]]
        for v in raw_chain[2:end]
            if _vertices_coincide(skel, chain_vs[end], v)
                # Keep the vertex that already lies on a beam. The other is a
                # landing a fraction of a millimetre off that beam.
                _vertex_degree(skel, v) > _vertex_degree(skel, chain_vs[end]) &&
                    (chain_vs[end] = v)
                continue
            end
            push!(chain_vs, v)
        end
        length(chain_vs) < 2 && continue
        n_seg = length(chain_vs) - 1
        seg_indices = Int[]
        rel = joist_releases[ci]
        # A solid-head run stays one beam. Every other grillage run is one
        # beam per bay so the pieces can take different sections.
        split_pieces = grillage && !joist_solid[ci]
        for k in 1:n_seg
            v_a = chain_vs[k]
            v_b = chain_vs[k + 1]
            e_joist = add_element!(skel, v_a, v_b; group = joist_group)
            L_T = _len_T(T, Meshes.measure(skel.edges[e_joist]))
            rs = k == 1     ? rel[1] : :fixed
            re = k == n_seg ? rel[2] : :fixed
            seg = Segment(e_joist, L_T; Lb = L_T, Cb = 1.0,
                          release_start = rs, release_end = re)
            push!(struc.segments, seg)
            push!(seg_indices, length(struc.segments))
            split_pieces && _push_joist_beam!(struc, level, seg_indices[end:end],
                                              beam_indices, beam_solid, created, false)
        end
        split_pieces && continue
        _push_joist_beam!(struc, level, seg_indices, beam_indices, beam_solid,
                          created, joist_solid[ci])
    end

    # 5. Member groups. A one-way level shares one group and splits off its two
    #    outermost joists. A grillage gives each rib piece its own group.
    gid = _framing_group_id(level)
    level.group_id = gid
    empty!(level.piece_group_ids)
    solid_idxs = [bi for (bi, flag) in zip(beam_indices, beam_solid) if flag]
    rib_idxs = [bi for (bi, flag) in zip(beam_indices, beam_solid) if !flag]
    if grillage
        for bi in rib_idxs
            _claim_rib_piece!(struc, level, bi)
        end
    else
        edge_idxs = _outermost_concrete_joists(struc, level, rib_idxs)
        interior_idxs = setdiff(rib_idxs, edge_idxs)
        for bi in interior_idxs
            set_group_id!(struc.beams[bi], gid)
        end
        if !isempty(interior_idxs)
            struc.member_groups[gid] = MemberGroup(gid, interior_idxs, nothing)
        end
        if !isempty(edge_idxs)
            egid = _framing_edge_group_id(level)
            level.edge_group_id = egid
            for bi in edge_idxs
                set_group_id!(struc.beams[bi], egid)
            end
            struc.member_groups[egid] = MemberGroup(egid, edge_idxs, nothing)
        end
    end
    # Perimeter girders were split with the joist landings. Pull the piece
    # inside each head off the girder so it is not catalog-sized with it.
    if head_panel !== nothing && n_host_beams > 0
        append!(solid_idxs, _detach_host_solid_runs!(
            struc, slab, level, 1:n_host_beams, head_panel))
    end
    if !isempty(solid_idxs)
        sg = _framing_solid_group_id(level)
        level.solid_group_id = sg
        for bi in solid_idxs
            set_group_id!(struc.beams[bi], sg)
        end
        struc.member_groups[sg] = MemberGroup(sg, copy(solid_idxs), nothing)
    end

    # Record the hosts this level landed on (member indices at level `level-1`
    # below — a mixture of level-0 girders and level-(N-1) joists for N ≥ 2).
    level.supports = sort!(collect(landed_hosts))

    # Refresh derived geometry (edge lengths for the new edges, etc.).
    rebuild_geometry_cache!(skel)

    if level.pattern isa ModularRibPattern
        small = undersized_rib_bays(struc, slab, level)
        isempty(small) || @warn "Slab $(level.slab_idx): $(length(small)) cut rib bay(s) are " *
            "smaller than half a module. A column head casts its bays solid; a bay no " *
            "head claims stays a ribbed void." maxlog = 4
    end

    grillage && isempty(created) && @warn "a grillage slab grew no ribs" slab = level.slab_idx hosts = length(host_edges) lines = length(lines) chains = length(joist_chains)
    return created
end

"""
    _node_chain_crossings!(skel, chains, z_m; tol=1e-6) -> Vector{Vector{Int}}

The same vertex chains, with one shared vertex wherever two of them cross.

A crossing inside both pieces gets a new vertex at elevation `z_m` (metres).
A chain end or interior vertex that lies on another chain's piece is inserted
into that piece. Two vertices at the same point on different chains become
one; a vertex in `keep` (a landing already queued on a host) is the one that
stays. Chain ends stay where they are, so releases are unchanged. `tol` is
metres.
"""
function _node_chain_crossings!(skel, chains::Vector{Vector{Int}}, z_m::Float64;
                                tol::Float64 = 1e-6, keep::Set{Int} = Set{Int}())
    length(chains) < 2 && return chains
    xy(v) = _vertex_xy_m(skel, v)
    alias = Dict{Int, Int}()
    function root(v)
        while haskey(alias, v)
            v = alias[v]
        end
        return v
    end
    created = Tuple{NTuple{2, Float64}, Int}[]
    function crossing_vertex(p)
        for (q, v) in created
            hypot(q[1] - p[1], q[2] - p[2]) <= tol && return v
        end
        v = _nearest_story_vertex(skel, p, z_m; tol = tol)
        if v === nothing
            v = add_vertex!(skel, [p[1], p[2], z_m]; group = :framing_landings)
        end
        push!(created, (p, v))
        return v
    end
    inserts = Dict{Tuple{Int, Int}, Vector{Tuple{Float64, Int}}}()
    for c1 in 1:(length(chains) - 1), c2 in (c1 + 1):length(chains)
        A, B = chains[c1], chains[c2]
        for i in 1:(length(A) - 1), j in 1:(length(B) - 1)
            a0, a1 = xy(A[i]), xy(A[i + 1])
            b0, b1 = xy(B[j]), xy(B[j + 1])
            hit = StructuralSizer._segment_crossing(a0, a1, b0, b1, tol)
            hit === nothing && continue
            t, u = hit
            La = hypot(a1[1] - a0[1], a1[2] - a0[2])
            Lb = hypot(b1[1] - b0[1], b1[2] - b0[2])
            va = t * La <= tol ? A[i] : (1 - t) * La <= tol ? A[i + 1] : 0
            vb = u * Lb <= tol ? B[j] : (1 - u) * Lb <= tol ? B[j + 1] : 0
            if va != 0 && vb != 0
                ra, rb = root(va), root(vb)
                if ra != rb
                    rb in keep && !(ra in keep) ? (alias[ra] = rb) : (alias[rb] = ra)
                end
                continue
            end
            v = va != 0 ? va : vb != 0 ? vb :
                crossing_vertex((a0[1] + t * (a1[1] - a0[1]), a0[2] + t * (a1[2] - a0[2])))
            va == 0 && push!(get!(Vector{Tuple{Float64, Int}}, inserts, (c1, i)), (t, v))
            vb == 0 && push!(get!(Vector{Tuple{Float64, Int}}, inserts, (c2, j)), (u, v))
        end
    end
    isempty(inserts) && isempty(alias) && return chains
    out = Vector{Vector{Int}}(undef, length(chains))
    for (c, ch) in enumerate(chains)
        verts = Int[root(ch[1])]
        for k in 1:(length(ch) - 1)
            for (_, v) in sort!(get(inserts, (c, k), Tuple{Float64, Int}[]); by = first)
                r = root(v)
                r == last(verts) || push!(verts, r)
            end
            r = root(ch[k + 1])
            r == last(verts) || push!(verts, r)
        end
        out[c] = verts
    end
    return out
end

"""
    _outermost_concrete_joists(struc, level, beam_indices) -> Vector{Int}

The joists of a concrete `:joist` level with a `LinearAxisPattern` that sit at
the smallest and largest offset across the pattern axis. Their T-beam flange
reaches the bay edge on one side, so it is narrower than an interior rib's.
Empty for other levels, and when there are fewer than three joists (every joist
is then outermost and one group already sizes them together).
"""
function _outermost_concrete_joists(struc::BuildingStructure, level::FramingLevel,
                                    beam_indices::Vector{Int})
    level.role === :joist || return Int[]
    level.pattern isa LinearAxisPattern || return Int[]
    _volume_key(level.material) isa StructuralSizer.Concrete || return Int[]
    length(beam_indices) >= 3 || return Int[]
    a = _unit2((Float64(level.pattern.axis[1]), Float64(level.pattern.axis[2])))
    a == (0.0, 0.0) && return Int[]
    perp = (-a[2], a[1])
    skel = struc.skeleton
    q = map(beam_indices) do bi
        v1, v2 = _member_end_vertices(struc, struc.beams[bi])
        p1 = _vertex_xy_m(skel, v1); p2 = _vertex_xy_m(skel, v2)
        _dot2(((p1[1] + p2[1]) / 2, (p1[2] + p2[2]) / 2), perp)
    end
    qmin, qmax = extrema(q)
    tol = 1e-6
    return [bi for (bi, qi) in zip(beam_indices, q)
            if qi <= qmin + tol || qi >= qmax - tol]
end

