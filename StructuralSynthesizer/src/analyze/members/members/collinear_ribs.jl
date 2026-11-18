# Collinear rib bars.
#
# Each grillage rib piece is sized on its own web and depth. Pieces that lie
# on one straight line, including across a girder or a solid-head piece, then
# share one bar size. The continuous count is whatever the least-demanding
# piece needs; a piece that needs more keeps extra bars of that same size.
# Stirrups stay on the piece. This is the 2024 policy: size each piece, keep
# the shared bars constant along the line.

"""
    _collinear_rib_groups(struc, eligible; tol=1e-3) -> Vector{Vector{Int}}

Beam indices in `eligible` that lie on one straight line.

The walk may pass through a beam that is not eligible (a girder or a solid-head
piece) when that beam is collinear and shares a node, so a rib line continues
across a girder. `tol` is the same cross-product test as
[`group_collinear_members!`](@ref).
"""
function _collinear_rib_groups(struc, eligible::Vector{Int}; tol::Float64 = 1e-3)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    ends = Dict{Int, NTuple{2, Int}}()
    dirs = Dict{Int, NTuple{2, Float64}}()
    at = Dict{Int, Vector{Int}}()
    for (m_idx, m) in enumerate(struc.beams)
        terminals = _beam_terminals(struc, m)
        terminals === nothing && continue
        ep1, ep2 = terminals
        dx = vc[ep2, 1] - vc[ep1, 1]
        dy = vc[ep2, 2] - vc[ep1, 2]
        L = hypot(dx, dy)
        L < 1e-9 && continue
        ends[m_idx] = (ep1, ep2)
        dirs[m_idx] = (dx / L, dy / L)
        push!(get!(Vector{Int}, at, ep1), m_idx)
        push!(get!(Vector{Int}, at, ep2), m_idx)
    end
    wanted = Set(eligible)
    visited = Set{Int}()
    groups = Vector{Int}[]
    for seed in eligible
        seed in visited && continue
        haskey(ends, seed) || continue
        group = Int[]
        stack = Int[seed]
        push!(visited, seed)
        while !isempty(stack)
            cur = pop!(stack)
            cur in wanted && push!(group, cur)
            d = dirs[cur]
            ep1, ep2 = ends[cur]
            for ep in (ep1, ep2)
                for nb in get(at, ep, Int[])
                    nb == cur && continue
                    nb in visited && continue
                    haskey(dirs, nb) || continue
                    nd = dirs[nb]
                    abs(d[1] * nd[2] - d[2] * nd[1]) < tol || continue
                    push!(visited, nb)
                    push!(stack, nb)
                end
            end
        end
        length(group) > 1 && push!(groups, group)
    end
    return groups
end

"""
How many bars of `bar_size` fit in one layer of `sec`.

ACI 318-11 §7.6.1 (corpus: aci-318-11, page 96): clear spacing at least `db`
and at least 1 in. §3.3.2(c) (page 48) limits the aggregate to 3/4 of that
clear spacing. The 3/4 in aggregate is the value the T-beam catalog already
uses for this fit.
"""
function _rib_bars_in_one_layer(sec::StructuralSizer.RCTBeamSection, bar_size::Int)
    db = ustrip(u"inch", StructuralSizer.rebar(bar_size).diameter)
    d_stir = ustrip(u"inch", StructuralSizer.rebar(sec.stirrup_size).diameter)
    cover = ustrip(u"inch", sec.cover)
    bw = ustrip(u"inch", sec.bw)
    return StructuralSizer._max_bars_in_width(bw, cover, d_stir, db, 0.75)
end

"""
Smallest bar count of `bar_size` that keeps the piece's sagging capacity.

`φMn` is not reduced, `As` is not reduced, and the section stays
tension-controlled (ACI 318-11 §10.3.5, corpus: aci-318-11, page 142) with at
least `As,min` (ACI 318-11 §10.5.1, page 144). `nothing` when no count that
fits the web does all of that.
"""
function _rib_bottom_count(proto::StructuralSizer.RCTBeamSection, old, bar_size::Int,
                           fc_psi::Float64, fy_psi::Float64)
    Ab = ustrip(u"inch^2", StructuralSizer.rebar(bar_size).A)
    As_old = ustrip(u"inch^2", old.As)
    φ_old = StructuralSizer._compute_φMn(old, fc_psi, fy_psi)
    max_n = _rib_bars_in_one_layer(proto, bar_size)
    n0 = max(1, ceil(Int, As_old / Ab - 1e-9))
    for n in n0:max_n
        sec = StructuralSizer.RCTBeamSection(;
            bw = proto.bw, h = proto.h, bf = proto.bf, hf = proto.hf,
            bar_size = bar_size, n_bars = n,
            cover = proto.cover, stirrup_size = proto.stirrup_size,
            bar_size_prime = proto.n_bars_prime > 0 ? proto.bar_size_prime : 0,
            n_bars_prime = proto.n_bars_prime)
        As = ustrip(u"inch^2", sec.As)
        As + 1e-9 >= As_old || continue
        d_in = ustrip(u"inch", sec.d)
        bw_in = ustrip(u"inch", sec.bw)
        As + 1e-9 >= StructuralSizer._as_min_aci_1051(bw_in, d_in, fc_psi, fy_psi) || continue
        StructuralSizer._compute_εt(sec, fc_psi, fy_psi) >= 0.004 || continue
        StructuralSizer._compute_φMn(sec, fc_psi, fy_psi) + 1e-6 >= φ_old || continue
        return n
    end
    return nothing
end

"""
Smallest top-bar count of `bar_size` that keeps `As′`.

A piece with no top bars stays that way: the continuous top count can be zero,
and the pieces that need top steel add bars. `nothing` when the bars that
preserve `As′` do not fit in the web.
"""
function _rib_top_count(proto::StructuralSizer.RCTBeamSection, old, bar_size::Int)
    old.n_bars_prime <= 0 && return 0
    Ab = ustrip(u"inch^2", StructuralSizer.rebar(bar_size).A)
    As_old = ustrip(u"inch^2", old.As_prime)
    max_n = _rib_bars_in_one_layer(proto, bar_size)
    n0 = max(1, ceil(Int, As_old / Ab - 1e-9))
    for n in n0:max_n
        sec = StructuralSizer.RCTBeamSection(;
            bw = proto.bw, h = proto.h, bf = proto.bf, hf = proto.hf,
            bar_size = proto.bar_size, n_bars = proto.n_bars,
            cover = proto.cover, stirrup_size = proto.stirrup_size,
            bar_size_prime = bar_size, n_bars_prime = n)
        ustrip(u"inch^2", sec.As_prime) + 1e-9 >= As_old && return n
    end
    return nothing
end

"""Write `sec` onto beam `bi`, its group, and the frame element when one exists."""
function _install_rib_section!(struc, bi::Int, sec, mat; I_factor, rebar, edge_ids)
    beam = struc.beams[bi]
    gid = group_id(beam)
    if gid !== nothing && haskey(struc.member_groups, gid)
        struc.member_groups[gid].section = sec
    end
    set_section!(beam, sec)
    L_raw = sum(struc.segments[si].L for si in segment_indices(beam))
    L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
    set_volumes!(beam, member_material_volumes(sec, L_total, mat; rebar = rebar))
    model = struc.asap_model
    model === nothing && return sec
    frames = model.frame_elements
    asap = StructuralSizer.to_asap_section(sec, mat; I_factor = I_factor)
    for si in segment_indices(beam)
        edge = struc.segments[si].edge_idx
        edge_ids !== nothing && !(edge in edge_ids) && continue
        1 <= edge <= length(frames) || continue
        frames[edge].section = asap
    end
    return sec
end

"""
Flange width of rib piece `bi` at web `bw`.

`spec` is that piece's group flange. Neighbors being raised together are in
`batch`, so they are taken at the same web.
"""
function _raised_flange_width(struc, spec, bw, hf, opts, batch)
    rib_max = _rib_web_max(opts, spec.joist_spacing)
    return _group_flange_width(struc, spec, bw; hf = hf, batch = batch,
                               rib_web_max = rib_max)
end

"""True when any member of `spec` is an edge T-beam (§8.12.3, one flange)."""
function _spec_has_edge(spec)
    return any(mf -> mf.one_side === true, spec.members)
end

"""True when piece `mi` is the edge T-beam in `spec`."""
function _piece_one_side(spec, mi::Int)
    for mf in spec.members
        mf.beam_idx == mi && return mf.one_side === true
    end
    return false
end

"""
    _share_collinear_rib_bars!(struc, group_ids, specs, opts; uniform, ...)

Give every rib piece on a collinear line one bar size.

Each piece keeps the fewest bars of that size that preserve its sagging
capacity and its top-steel area. When `uniform` is set, every rib in the pass
is first raised to the largest web and the largest depth, and the flange is
recomputed at that web. A piece whose bars then cannot satisfy the checks
above keeps the section the sizer gave it.

`recheck(mi, sec)` returns the sizer's `FeasibilityExplanation` for the new
section of piece `mi` against that piece's demand. A piece whose new section
fails it keeps the sizer's section; a piece that passes records it, so the
reported check belongs to the section that was installed. Without `recheck`
the new section is installed with no recorded check.
"""
function _share_collinear_rib_bars!(struc, group_ids, specs, opts;
                                    uniform::Bool = false,
                                    I_factor::Real = 0.35,
                                    edge_ids = nothing,
                                    rebar = nothing,
                                    recheck = nothing)
    spec_of = Dict{Int, Any}()
    ribs = Int[]
    for (gid, spec) in zip(group_ids, specs)
        spec === nothing && continue
        # Edge T-beams (one flange, ACI 318-11 §8.12.3) share a bar size along
        # the line even when they are not joist ribs. A two-sided girder does not.
        spec.joist_spacing === nothing && !_spec_has_edge(spec) && continue
        haskey(struc.member_groups, gid) || continue
        for mi in struc.member_groups[gid].member_indices
            section(struc.beams[mi]) isa StructuralSizer.RCTBeamSection || continue
            push!(ribs, mi)
            spec_of[mi] = spec
        end
    end
    isempty(ribs) && return struc
    mat = opts.material
    fc_psi = ustrip(u"psi", mat.fc′)
    fy_psi = ustrip(u"psi", opts.rebar_material.Fy)
    batch = Set(gid for mi in ribs for gid in (group_id(struc.beams[mi]),) if gid !== nothing)
    bw_max = h_max = nothing
    if uniform && length(ribs) > 1
        secs = [section(struc.beams[mi]) for mi in ribs]
        bw_max = maximum(s.bw for s in secs)
        h_max = maximum(s.h for s in secs)
    end
    bar_of = Dict{Int, Int}(mi => section(struc.beams[mi]).bar_size for mi in ribs)
    # Edge pieces on one line share the deeper section so the continuous bars
    # sit in one layer. Interior ribs on that line keep the depth they were sized to.
    line_bw = Dict{Int, Any}()
    line_h = Dict{Int, Any}()
    for group in _collinear_rib_groups(struc, ribs)
        sized = [mi for mi in group if haskey(bar_of, mi)]
        length(sized) > 1 || continue
        shared = maximum(bar_of[mi] for mi in sized)
        for mi in sized
            bar_of[mi] = shared
        end
        edge = [mi for mi in sized if _piece_one_side(spec_of[mi], mi)]
        length(edge) > 1 || continue
        secs = [section(struc.beams[mi]) for mi in edge]
        bw = maximum(s.bw for s in secs)
        h = maximum(s.h for s in secs)
        for mi in edge
            line_bw[mi] = bw
            line_h[mi] = h
        end
    end

    for mi in ribs
        old = section(struc.beams[mi])
        proto = _rib_proto(struc, mi, old, spec_of[mi], opts, batch,
                           get(line_bw, mi, bw_max), get(line_h, mi, h_max))
        bar_size = bar_of[mi]
        n_bot = _rib_bottom_count(proto, old, bar_size, fc_psi, fy_psi)
        n_top = n_bot === nothing ? nothing : _rib_top_count(proto, old, bar_size)
        if n_bot === nothing || n_top === nothing
            @warn "Rib piece $mi keeps the section from sizing: the shared bars " *
                  "do not fit this web without losing capacity." maxlog = 4
            continue
        end
        unchanged = proto.bw == old.bw && proto.h == old.h && proto.bf == old.bf &&
            proto.hf == old.hf && old.bar_size == bar_size && old.n_bars == n_bot &&
            old.n_bars_prime == n_top && (n_top == 0 || old.bar_size_prime == bar_size)
        unchanged && continue
        sec = StructuralSizer.RCTBeamSection(;
            bw = proto.bw, h = proto.h, bf = proto.bf, hf = proto.hf,
            bar_size = bar_size, n_bars = n_bot,
            cover = old.cover, stirrup_size = old.stirrup_size,
            bar_size_prime = n_top > 0 ? bar_size : 0,
            n_bars_prime = n_top)
        expl = recheck === nothing ? nothing : recheck(mi, sec)
        if expl !== nothing && !expl.passed
            @warn "Rib piece $mi keeps the section from sizing: the shared-bar " *
                  "section fails $(expl.governing_check) " *
                  "(ratio $(round(expl.governing_ratio; digits = 3)))." maxlog = 4
            continue
        end
        _install_rib_section!(struc, mi, sec, mat; I_factor, rebar, edge_ids)
        expl === nothing || (struc.beams[mi].base.check = (section = sec, explanation = expl))
    end
    return struc
end

"""
Geometry the piece is checked against.

`bw_max === nothing` keeps the sized section. Otherwise the piece is raised to
that web and depth when the recomputed flange is at least as wide as the web.
"""
function _rib_proto(struc, mi, old, spec, opts, batch, bw_max, h_max)
    bw_max === nothing && return old
    hf = old.hf
    h_max > hf || return old
    bf = _raised_flange_width(struc, spec, bw_max, hf, opts, batch)
    bf >= bw_max || return old
    return StructuralSizer.RCTBeamSection(;
        bw = bw_max, h = h_max, bf = bf, hf = hf,
        bar_size = old.bar_size, n_bars = old.n_bars,
        cover = old.cover, stirrup_size = old.stirrup_size,
        bar_size_prime = old.n_bars_prime > 0 ? old.bar_size_prime : 0,
        n_bars_prime = old.n_bars_prime)
end
