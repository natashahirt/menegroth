# Rib pieces at a solid head, rib widths on the bay arrangement, and the
# closing of bays too tight to form.

"""Group ids of rib pieces that share a node with a solid-head piece."""
function _head_face_group_ids(struc, level::FramingLevel)
    ids = Set{UInt64}()
    solid = level.solid_group_id
    solid === nothing && return ids
    nodes = Set{Int}()
    for bi in level_member_indices(struc, level)
        group_id(struc.beams[bi]) == solid || continue
        terminals = _beam_terminals(struc, struc.beams[bi])
        terminals === nothing && continue
        push!(nodes, terminals...)
    end
    isempty(nodes) && return ids
    pieces = Set(level.piece_group_ids)
    if isempty(pieces) && level.group_id !== nothing
        push!(pieces, level.group_id)
    end
    for bi in level_member_indices(struc, level)
        gid = group_id(struc.beams[bi])
        gid === nothing && continue
        gid in pieces || continue
        terminals = _beam_terminals(struc, struc.beams[bi])
        terminals === nothing && continue
        (terminals[1] in nodes || terminals[2] in nodes) && push!(ids, gid)
    end
    return ids
end

"""
`(bw, d, h)` of the narrowest, shallowest rib that frames into the solid head.

One-way shear at the head face uses this section. A floor with no solid piece
yet returns `nothing`, and the caller keeps the section it already chose.
"""
function _head_face_rib_web(struc, level::FramingLevel)
    ids = _head_face_group_ids(struc, level)
    isempty(ids) && return nothing
    dims = Tuple{typeof(1.0u"m"), typeof(1.0u"m"), typeof(1.0u"m")}[]
    for bi in level_member_indices(struc, level)
        gid = group_id(struc.beams[bi])
        gid in ids || continue
        sec = section(struc.beams[bi])
        one = _rib_web_dims(sec)
        one === nothing && continue
        push!(dims, one)
    end
    isempty(dims) && return nothing
    return (minimum(d[1] for d in dims), minimum(d[2] for d in dims),
            maximum(d[3] for d in dims))
end

"""Concrete beam options for this level, or the building fallback."""
function _level_concrete_options(level, fallback)
    own = level.beam_options
    own isa StructuralSizer.ConcreteBeamOptions && return own
    return fallback isa StructuralSizer.ConcreteBeamOptions ? fallback : nothing
end

"""
Rebuild and re-solve when a frame element still carries an older section's stiffness.

`size_beams!` reads [`member_group_demands`](@ref), which refuses that state.
A full `process!` is required: the stiffness update used between sizing passes
does not re-realize a parametric frame, and a demand read then sees the old `K`.
"""
function _ensure_frame_demands!(struc)
    model = struc.asap_model
    (model === nothing || isempty(model.frame_elements)) && return
    isempty(Asap.stale_frame_elements(model)) && return
    Asap.process!(model)
    _solve_struc_model!(struc)
    _refresh_pattern_solve_cache!(struc)
    return
end

"""Least clear width of a bay, metres, between rib centerlines minus the ribs.

ENGINEERING JUDGMENT. The width is the greatest perpendicular distance from
each side to the other vertices. Half of this side's rib and half of the
widest rib on the bay are taken out of it. A triangle has no opposite rib,
so the widest rib stands in for that far side.
"""
function _bay_min_clear(arr, bay, widths)
    pts = [arr.nodes[i] for i in bay.loop]
    isempty(bay.sides) && return 0.0
    far = maximum(widths[s] for s in bay.sides)
    best = Inf
    for (k, e) in enumerate(bay.sides)
        a = pts[k]
        b = pts[mod1(k + 1, length(pts))]
        dx, dy = b[1] - a[1], b[2] - a[2]
        L = hypot(dx, dy)
        L > 1e-9 || continue
        nx, ny = -dy / L, dx / L
        projs = [(p[1] - a[1]) * nx + (p[2] - a[2]) * ny for p in pts]
        width = maximum(projs) - minimum(projs)
        best = min(best, width - 0.5 * widths[e] - 0.5 * far)
    end
    return best
end

"""Rib width, metres, on each arrangement edge. A side with no rib is 0."""
function _arrangement_rib_widths(struc, arr, owners)
    length(owners) == length(arr.edges) || throw(ArgumentError(
        "each rib edge needs the skeleton member that carries it"))
    by_edge = Dict{Int, Float64}()
    for beam in struc.beams
        sec = section(beam)
        w = if sec isa StructuralSizer.RCTBeamSection
            ustrip(u"m", sec.bw)
        elseif sec isa StructuralSizer.RCBeamSection
            ustrip(u"m", sec.b)
        else
            nothing
        end
        w === nothing && continue
        for si in segment_indices(beam)
            by_edge[struc.segments[si].edge_idx] = w
        end
    end
    return [get(by_edge, owners[e], 0.0) for e in eachindex(arr.edges)]
end

"""
`(bw, d, h)` in metres of the sized rib on each arrangement edge, or
`nothing` for an edge with no concrete rib. Beams in the level's solid-head
group are skipped: those edges are cast solid.
"""
function _arrangement_rib_dims(struc, level, arr, owners)
    length(owners) == length(arr.edges) || throw(ArgumentError(
        "each rib edge needs the skeleton member that carries it"))
    gid = level.solid_group_id
    by_edge = Dict{Int, NTuple{3, Float64}}()
    for bi in level_member_indices(struc, level)
        beam = struc.beams[bi]
        gid !== nothing && group_id(beam) == gid && continue
        sec = section(beam)
        sec === nothing && continue
        dims = _rib_web_dims(sec)
        dims === nothing && continue
        one = (ustrip(u"m", dims[1]), ustrip(u"m", dims[2]), ustrip(u"m", dims[3]))
        for si in segment_indices(beam)
            by_edge[struc.segments[si].edge_idx] = one
        end
    end
    return Union{Nothing, NTuple{3, Float64}}[get(by_edge, owners[e], nothing)
                                              for e in eachindex(arr.edges)]
end

"""
Bays whose clear width is below `min_void` join the nearest head they share
an edge with, while the solid fraction stays within `max_fraction`.

A bay that meets a head only at a corner, or that meets none, stays a void.
The head outline is one piece; a detached bay would be a second piece. A run
of tight bays fills in from the head, one shared edge at a time.
"""
function _close_tight_voids(arr, heads, widths, min_void, max_fraction)
    min_void <= 0 && return heads
    out = [StructuralSizer.ColumnSolidHead(h.column, copy(h.bays)) for h in heads]
    refused = Set{Tuple{Int, Int}}()
    for _ in 1:length(arr.bays)
        taken = Set(b for h in out for b in h.bays)
        edge_of = [Set{Int}(e for bi in h.bays for e in arr.bays[bi].sides) for h in out]
        best = nothing
        for (bi, bay) in enumerate(arr.bays)
            bi in taken && continue
            _bay_min_clear(arr, bay, widths) < min_void || continue
            pts = [arr.nodes[k] for k in bay.loop]
            isempty(pts) && continue
            c = (sum(p[1] for p in pts) / length(pts), sum(p[2] for p in pts) / length(pts))
            touch = Int[]
            for (hi, edges) in enumerate(edge_of)
                (hi, bi) in refused && continue
                any(e -> e in edges, bay.sides) && push!(touch, hi)
            end
            isempty(touch) && continue
            hi = touch[argmin([hypot((out[k].column .- c)...) for k in touch])]
            dist = hypot((out[hi].column .- c)...)
            (best === nothing || dist < best[1]) && (best = (dist, hi, bi))
        end
        best === nothing && break
        _, hi, bi = best
        trial = [StructuralSizer.ColumnSolidHead(h.column, copy(h.bays)) for h in out]
        push!(trial[hi].bays, bi)
        sort!(unique!(trial[hi].bays))
        if max_fraction !== nothing && _solid_fraction(arr, trial) > max_fraction + 1e-9
            push!(refused, (hi, bi))
            continue
        end
        out = trial
    end
    return out
end
