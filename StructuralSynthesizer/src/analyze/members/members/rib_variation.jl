# Variable rib width and depth.
#
# Each rib piece is sized on its own. A piece that frames into a solid head is
# sized again for one-way shear on concrete alone (ENGINEERING JUDGMENT: ACI
# 318-11 §11.1.1 permits Vs). Pieces of one rib then share §8.13.2's limit on
# the least width (corpus: aci-318-11, PDF page 120), and the soffit may step
# at a node by at most `rib_depth_step`. ACI 318-11 §12.10.6 (PDF page 224)
# requires anchorage where a bar is not parallel to the compression face and
# gives no length for a step, so each piece stays prismatic.

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

"""
    raise_head_face_ribs!(struc, params, fallback; I_factor, gravity_factor) -> Bool

Size the rib pieces that frame into a solid head so their concrete shear
covers the piece shear. One sizing call per framing level reads the forces
once. No-op when `params.rib_head_stirrups` is set.
"""
function raise_head_face_ribs!(struc, params, fallback; I_factor::Real, gravity_factor)
    params.rib_head_stirrups && return false
    work = Tuple{Any, Set{UInt64}}[]
    for slab in struc.slabs
        level = _grillage_level(slab)
        level === nothing && continue
        opts = _level_concrete_options(level, fallback)
        opts === nothing && continue
        ids = _head_face_group_ids(struc, level)
        isempty(ids) && continue
        push!(work, (opts, ids))
    end
    isempty(work) && return false
    changed = false
    for (opts, ids) in work
        # The previous level's sections are already on the elements. Read
        # forces only after the frame stiffness matches them.
        _ensure_frame_demands!(struc)
        accept = let keep = ids
            g -> g in keep
        end
        try
            size_beams!(struc, opts; reanalyze = false, gravity_factor,
                        I_factor, stirrup_shear = false,
                        group_filter = accept)
            changed = true
        catch err
            _no_feasible_section(err) || rethrow()
            @warn "No section carries head-face shear on concrete alone; the solid head may grow" maxlog = 4
        end
    end
    return changed
end

"""Catalog sections at least `bw_min_in` wide and `h_min_in` deep."""
function _rib_raise_catalog(sec::StructuralSizer.RCTBeamSection, spacing, bw_min_in, h_min_in)
    bf_of = bw -> max(sec.bf, bw)
    function keep(cat, joist::Bool)
        out = StructuralSizer.RCTBeamSection[]
        for s in cat
            ustrip(u"inch", s.bw) + 1e-6 >= bw_min_in || continue
            ustrip(u"inch", s.h) + 1e-6 >= h_min_in || continue
            ustrip(u"inch", s.bw) <= ustrip(u"inch", s.bf) + 1e-6 || continue
            if joist
                stem = ustrip(u"inch", s.h - s.hf)
                stem <= 3.5 * ustrip(u"inch", s.bw) + 1e-6 || continue
            end
            push!(out, s)
        end
        return out
    end
    if spacing !== nothing
        cat = keep(StructuralSizer.joist_rc_tbeams(;
            flange_width = bf_of, flange_thickness = sec.hf, center_spacing = spacing), true)
        isempty(cat) || return cat, spacing
    end
    # ACI 318-11 §8.13.4: a rib the joist limits cannot carry is a beam.
    cat = keep(StructuralSizer.large_rc_tbeams(;
        flange_width = bf_of, flange_thickness = sec.hf), false)
    return cat, nothing
end

"""Install a deeper or wider section on piece `bi`, or leave it.

`demand` and `length_m` come from one read taken before any piece on the
line is changed. Reading again would see stiffness from the piece just installed.
"""
function _raise_rib_piece!(struc, bi::Int, opts, spacing, bw_min_in, h_min_in,
                           demand, length_m;
                           stirrup_shear::Bool, I_factor::Real)
    sec = section(struc.beams[bi])
    sec isa StructuralSizer.RCTBeamSection || return false
    ustrip(u"inch", sec.bw) + 0.05 >= bw_min_in &&
        ustrip(u"inch", sec.h) + 0.05 >= h_min_in && return false
    (demand === nothing || length_m === nothing) && return false
    cat, used = _rib_raise_catalog(sec, spacing, bw_min_in, h_min_in)
    isempty(cat) && return false
    d = demand
    bf_of = bw -> max(sec.bf, bw)
    result = try
        StructuralSizer.size_tbeams(
            [d.Mux_pos * u"N*m"], [d.Vu_strong * u"N"],
            [StructuralSizer.ConcreteMemberGeometry(length_m)], opts;
            flange_width = bf_of, flange_thickness = sec.hf,
            joist_spacing = used, catalog = cat, stirrup_shear = stirrup_shear,
            Mu_neg = [d.Mux_neg * u"N*m"],
            Nu = [d.Pu_t > 0 ? -d.Pu_t * u"N" : d.Pu_c * u"N"])
    catch err
        _no_feasible_section(err) && return false
        err isa ArgumentError || rethrow()
        return false
    end
    _install_rib_section!(struc, bi, result.sections[1], opts.material;
                          I_factor = I_factor, rebar = opts.rebar_material,
                          edge_ids = nothing)
    return true
end

"""Pairs of pieces in `group` that meet at a node."""
function _adjacent_rib_pairs(struc, group)
    ends = Dict{Int, Union{Nothing, NTuple{2, Int}}}(
        bi => _beam_terminals(struc, struc.beams[bi]) for bi in group)
    pairs = Tuple{Int, Int}[]
    for (i, a) in enumerate(group)
        ta = ends[a]
        ta === nothing && continue
        for b in group[i + 1:end]
            tb = ends[b]
            tb === nothing && continue
            share = ta[1] == tb[1] || ta[1] == tb[2] || ta[2] == tb[1] || ta[2] == tb[2]
            share && push!(pairs, (a, b))
        end
    end
    return pairs
end

"""
    conform_rib_lines!(struc, params, fallback; I_factor) -> Bool

Raise the shallower piece at a node until the soffit step is at most
`rib_depth_step`, then widen a joist rib until §8.13.2 holds for the least
width on that rib.
"""
function conform_rib_lines!(struc, params, fallback; I_factor::Real)
    step_in = ustrip(u"inch", params.rib_depth_step)
    step_in >= 0 || throw(ArgumentError(
        "rib_depth_step is not negative, got $(params.rib_depth_step)"))
    ribs = Int[]
    opts_of = Dict{Int, StructuralSizer.ConcreteBeamOptions}()
    faces = Set{UInt64}()
    for slab in struc.slabs
        level = _grillage_level(slab)
        level === nothing && continue
        opts = _level_concrete_options(level, fallback)
        opts === nothing && continue
        params.rib_head_stirrups || union!(faces, _head_face_group_ids(struc, level))
        pieces = Set(level.piece_group_ids)
        isempty(pieces) && level.group_id !== nothing && push!(pieces, level.group_id)
        for bi in level_member_indices(struc, level)
            gid = group_id(struc.beams[bi])
            gid === nothing && continue
            gid in pieces || continue
            section(struc.beams[bi]) isa StructuralSizer.RCTBeamSection || continue
            push!(ribs, bi)
            opts_of[bi] = opts
        end
    end
    unique!(ribs)
    isempty(ribs) && return false
    _ensure_frame_demands!(struc)
    known = Dict{UInt64, Tuple{Any, Float64}}()
    group_ids, demands, lengths = _beam_group_demands(struc, nothing; resolution = 200,
                                                      shell_demands = nothing)[1:3]
    for (gid, demand, L) in zip(group_ids, demands, lengths)
        known[gid] = (demand, L)
    end
    changed = false
    for group in _collinear_rib_groups(struc, ribs)
        changed |= _conform_one_rib_line!(struc, params, group, step_in, faces, opts_of,
                                          known; I_factor = I_factor)
    end
    return changed
end

function _conform_one_rib_line!(struc, params, group, step_in, faces, opts_of, known; I_factor)
    gids = UInt64[]
    for bi in group
        gid = group_id(struc.beams[bi])
        gid === nothing && continue
        gid in gids || push!(gids, gid)
    end
    specs = _compute_flange_params(struc, gids)
    joist = !isempty(specs) && all(s -> s !== nothing && s.joist_spacing !== nothing, specs)
    spacing = joist ? maximum(s.joist_spacing for s in specs) : nothing
    height = Dict{Int, Float64}()
    for bi in group
        height[bi] = ustrip(u"inch", section(struc.beams[bi]).h)
    end
    # The deeper piece stays. The shallower one rises until the step fits.
    for _ in 1:length(group)
        moved = false
        for (a, b) in _adjacent_rib_pairs(struc, group)
            if height[a] < height[b] - step_in - 1e-6
                height[a] = height[b] - step_in
                moved = true
            elseif height[b] < height[a] - step_in - 1e-6
                height[b] = height[a] - step_in
                moved = true
            end
        end
        moved || break
    end
    widths = Dict{Int, Float64}()
    width_list = Float64[]
    stems = Float64[]
    for bi in group
        sec = section(struc.beams[bi])
        widths[bi] = ustrip(u"inch", sec.bw)
        push!(width_list, widths[bi])
        stem = height[bi] - ustrip(u"inch", sec.hf)
        push!(stems, max(stem, 0.0))
    end
    if joist
        line = StructuralSizer.joist_rib_line(width_list, stems)
        # The raised depths can demand a wider least rib. Every piece of the
        # line rises to that width; §8.13.2 is one limit for the rib.
        need = line.depth_ok ? 4.0 : max(4.0, line.bw_required_in)
        for bi in group
            widths[bi] = max(widths[bi], need)
        end
    end
    changed = false
    for bi in group
        gid = group_id(struc.beams[bi])
        concrete_only = gid !== nothing && gid in faces
        demand, length_m = gid === nothing ? (nothing, nothing) : get(known, gid, (nothing, nothing))
        changed |= _raise_rib_piece!(struc, bi, opts_of[bi], spacing,
                                     widths[bi], height[bi], demand, length_m;
                                     stirrup_shear = !concrete_only, I_factor = I_factor)
    end
    return changed
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
