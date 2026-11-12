# Solid head cut on the building frame.
#
# A grillage rib is one building beam from edge to edge until the solid head
# starts. The piece inside the head and the piece outside it are different
# sections, so they are different beams that share the node at the cut and
# stay continuous there (`:fixed`). The perimeter girder is cut the same way.
#
# The cut is a rib-network node where two pieces of one rib disagree on
# `solid`. That is a module line, so each rib piece still lies on one frame
# edge and the skeleton load keeps its area.
#
# ACI 318-11 §13.7.3.1 (corpus: aci-318-11, page 259) permits the gross
# concrete section for the slab-beam's moment of inertia. Each rib family
# owns that rectangle's bending once. The panel pressure already contains
# the topping over the whole panel, the head included, so a section that
# also weighed the full depth would count that topping twice. Each stored
# section uses half of `ρ × projection / full depth`. The two families then
# weigh the concrete below the topping once, and a head that stops at the
# topping adds no mass. Stiffness stays the gross rectangle.

"""Panel of the slab, or `nothing` when the boundary is not four corners."""
function _solid_head_panel(struc, slab)
    poly = _slab_interior_polygon_m(struc, slab)
    poly === nothing && return nothing
    corners = _panel_corners(poly)
    length(corners) == 4 || return nothing
    return StructuralSizer.IsoParametricPanel(StructuralSizer.ensure_ccw(corners))
end

"""`xy` is inside this panel's solid head. A point off the panel is not."""
function _xy_in_solid_head(panel, xy, solid_head)
    solid_head <= 0 && return false
    local ξ, η
    try
        ξ, η = StructuralSizer.parametric_coords(panel, xy[1], xy[2])
    catch
        return false
    end
    (-1e-5 <= ξ <= 1 + 1e-5 && -1e-5 <= η <= 1 + 1e-5) || return false
    return StructuralSizer.is_in_solid_head(ξ, η, solid_head)
end

"""Drop points that land on each other."""
function _unique_plan_points(pts; tol::Float64 = 1e-6)
    out = NTuple{2, Float64}[]
    for p in pts
        any(q -> hypot(q[1] - p[1], q[2] - p[2]) <= tol, out) && continue
        push!(out, p)
    end
    return out
end

"""
Land `foot` on `edge` at `u`, reusing a vertex already queued at that
parameter. A joist that meets the head boundary has already landed there;
a second vertex at the same point would be a zero-length edge.
"""
function _reuse_or_land!(skel, edge::Int, u::Float64, foot, z_m, edge_mids;
                         tol::Float64 = 1e-6)
    if haskey(edge_mids, edge)
        for (eu, v) in edge_mids[edge]
            abs(eu - u) <= tol && return v
        end
    end
    return _landing_vertex!(skel, edge, u, foot, z_m, edge_mids)
end

"""Insert `points` that lie on `chain`, in order along it."""
function _insert_points_on_chain(skel, chain::Vector{Int}, points, z_m::Float64;
                                 tol::Float64 = 1e-3)
    out = Int[chain[1]]
    for k in 1:(length(chain) - 1)
        a = _vertex_xy_m(skel, chain[k])
        b = _vertex_xy_m(skel, chain[k + 1])
        hits = Tuple{Float64, NTuple{2, Float64}}[]
        for p in points
            t = _param_on_segment(p, a, b; tol = tol)
            t === nothing && continue
            (t <= 1e-6 || t >= 1 - 1e-6) && continue
            push!(hits, (t, p))
        end
        sort!(hits; by = first)
        last_t = 0.0
        for (t, p) in hits
            t <= last_t + 1e-6 && continue
            last_t = t
            v = add_vertex!(skel, [p[1], p[2], z_m]; group = :framing_landings)
            last(out) == v && continue
            push!(out, v)
        end
        last(out) == chain[k + 1] && continue
        push!(out, chain[k + 1])
    end
    return out
end

"""Contiguous same-flag pieces of a vertex chain. Each run is the vertices."""
function _solid_subchains(skel, verts::Vector{Int}, panel, solid_head)
    n = length(verts) - 1
    flags = Vector{Bool}(undef, n)
    for k in 1:n
        a = _vertex_xy_m(skel, verts[k])
        b = _vertex_xy_m(skel, verts[k + 1])
        mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
        flags[k] = _xy_in_solid_head(panel, mid, solid_head)
    end
    runs = Vector{Int}[]
    solid = Bool[]
    i = 1
    while i <= n
        j = i
        while j < n && flags[j + 1] == flags[i]
            j += 1
        end
        push!(runs, verts[i:(j + 1)])
        push!(solid, flags[i])
        i = j + 1
    end
    return runs, solid
end

"""
Cut joist chains where a solid head starts, and queue the same cuts on the
slab's boundary girders.

Returns `(chains, releases, solid)`. `solid[i]` is true when that chain is
inside a head. Releases at a cut are `:fixed`, so the rib stays continuous.
A level with no solid head is returned unchanged.
"""
function _cut_joists_at_solid_head!(struc, slab, level, skel, z_m,
                                    extent_edges, joist_chains, edge_mids;
                                    chain_releases=nothing)
    n = length(joist_chains)
    base_rel = chain_releases === nothing ? fill(level.end_fixity, n) : chain_releases
    plain = (joist_chains, base_rel, falses(n), nothing)
    pat = level.pattern
    (pat isa IsoparametricPattern && pat.solid_head > 0) || return plain
    rib_analysis(level) == :grillage || throw(ArgumentError(
        "solid_head belongs on a grillage. This level's analysis is :$(level.analysis)."))
    s = StructuralSizer.snapped_solid_head(pat.solid_head, pat.n_xi, pat.n_eta)
    s == pat.solid_head || (level.pattern = IsoparametricPattern(pat.n_xi, pat.n_eta, s))
    panel = _solid_head_panel(struc, slab)
    panel === nothing && throw(ArgumentError(
        "a solid head is cut on a quadrilateral panel, and this slab is not one"))
    grid = StructuralSizer.WaffleRibGrid(panel, pat.n_xi, pat.n_eta; solid_head = s)
    points = _unique_plan_points(StructuralSizer.solid_head_transitions(grid))
    for p in points
        hit = _host_landing(skel, extent_edges, p)
        hit === nothing && continue
        e, u, foot = hit
        _reuse_or_land!(skel, e, u, foot, z_m, edge_mids)
    end
    chains = Vector{Int}[]
    releases = NTuple{2, Symbol}[]
    solid = Bool[]
    for (ci, chain) in enumerate(joist_chains)
        expanded = _insert_points_on_chain(skel, chain, points, z_m)
        runs, flags = _solid_subchains(skel, expanded, panel, s)
        rel = base_rel[ci]
        for (k, run) in enumerate(runs)
            push!(chains, run)
            rs = k == 1 ? rel[1] : :fixed
            re = k == length(runs) ? rel[2] : :fixed
            push!(releases, (rs, re))
            push!(solid, flags[k])
        end
    end
    # The panel is the boundary before the girders are split. Rebuilding it
    # afterwards follows the new mid-edge vertices and is not the same quad.
    return chains, releases, solid, panel
end

"""Index ranges of contiguous equal flags."""
function _flag_runs(flags::Vector{Bool})
    runs = UnitRange{Int}[]
    i = 1
    n = length(flags)
    while i <= n
        j = i
        while j < n && flags[j + 1] == flags[i]
            j += 1
        end
        push!(runs, i:j)
        i = j + 1
    end
    return runs
end

"""The run that stays on the original beam: the longest piece outside the head."""
function _run_kept_on_host(flags, runs)
    best = 0
    best_len = -1
    for (k, run) in enumerate(runs)
        flags[first(run)] && continue
        len = length(run)
        if len > best_len
            best = k
            best_len = len
        end
    end
    return best == 0 ? 1 : best
end

"""Every segment of `beam` sits within 1 cm of elevation `z`."""
function _beam_at_elevation(struc, beam, z)
    z === nothing && return false
    for si in segment_indices(beam)
        e = struc.segments[si].edge_idx
        v1, v2 = struc.skeleton.edge_indices[e]
        abs(_vertex_z_m(struc.skeleton, v1) - z) <= 0.01 || return false
        abs(_vertex_z_m(struc.skeleton, v2) - z) <= 0.01 || return false
    end
    return true
end

"""Midpoint of one segment, in plan metres."""
function _segment_mid_xy(struc, si::Int)
    e = struc.segments[si].edge_idx
    v1, v2 = struc.skeleton.edge_indices[e]
    a = _vertex_xy_m(struc.skeleton, v1)
    b = _vertex_xy_m(struc.skeleton, v2)
    return ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
end

"""A new beam on `seg_indices`, copying the host's role and material key."""
function _beam_on_segments(struc, proto::Beam{T}, seg_indices::Vector{Int}) where {T}
    L = sum(struc.segments[si].L for si in seg_indices)
    Lb = maximum(struc.segments[si].Lb for si in seg_indices)
    beam = Beam(seg_indices, L; Lb = Lb,
                Kx = proto.base.Kx, Ky = proto.base.Ky, Cb = proto.base.Cb,
                role = proto.role, level = proto.level,
                lateral_role = proto.lateral_role,
                torsion_released = proto.torsion_released)
    vols = MaterialVolumes()
    for (mat, _) in volumes(proto)
        vols[mat] = zero(VolumeType)
    end
    set_volumes!(beam, vols)
    return beam
end

"""Point the host beam at `seg_indices` and refresh its length."""
function _retain_segments!(struc, beam, seg_indices::Vector{Int})
    beam.base.segment_indices = seg_indices
    beam.base.L = sum(struc.segments[si].L for si in seg_indices)
    beam.base.Lb = maximum(struc.segments[si].Lb for si in seg_indices)
    return beam
end

"""Take `bi` out of whatever member group currently lists it."""
function _drop_beam_from_its_group!(struc, bi::Int)
    gid = group_id(struc.beams[bi])
    gid === nothing && return
    haskey(struc.member_groups, gid) || return
    filter!(i -> i != bi, struc.member_groups[gid].member_indices)
    return
end

"""
Split each existing beam that crosses a solid head.

The piece outside the head stays on the original beam, so a perimeter
girder keeps its group and its shortened length. Each piece inside the
head is a new beam. Returns those new indices, and the index of a beam
that was solid over its whole length.
"""
function _detach_host_solid_runs!(struc::BuildingStructure{T}, slab, level,
                                  host_beams, panel) where {T}
    s = level.pattern.solid_head
    created = Int[]
    wholly = Int[]
    z = _slab_elevation_m(struc, slab)
    for bi in host_beams
        beam = struc.beams[bi]
        segs = segment_indices(beam)
        isempty(segs) && continue
        _beam_at_elevation(struc, beam, z) || continue
        flags = [_xy_in_solid_head(panel, _segment_mid_xy(struc, si), s) for si in segs]
        any(flags) || continue
        runs = _flag_runs(flags)
        keep = _run_kept_on_host(flags, runs)
        if length(runs) == 1
            flags[1] && push!(wholly, bi)
            continue
        end
        _retain_segments!(struc, beam, segs[runs[keep]])
        for (k, run) in enumerate(runs)
            k == keep && continue
            piece = _beam_on_segments(struc, beam, segs[run])
            push!(struc.beams, piece)
            push!(created, length(struc.beams))
        end
    end
    for bi in wholly
        _drop_beam_from_its_group!(struc, bi)
        push!(created, bi)
    end
    return created
end

"""A length in metres. A bare real is metres."""
_as_metres(x::Unitful.Length) = uconvert(u"m", x)
_as_metres(x::Real) = float(x) * u"m"

"""Overall depth of a concrete rib, or `nothing` for any other section."""
_concrete_rib_depth(sec::StructuralSizer.RCTBeamSection) = sec.h
_concrete_rib_depth(sec::StructuralSizer.RCBeamSection) = sec.h
_concrete_rib_depth(::Any) = nothing

"""
Depth of the sized ribs outside the solid head, in metres.

`nothing` when those ribs have no section yet. A sized rib that is not
concrete, or two concrete ribs that disagree, is an error: the head fills
to one soffit.
"""
function _sized_rib_depth(struc, level::FramingLevel)
    depths = typeof(1.0u"m")[]
    gid = level.solid_group_id
    for bi in level_member_indices(struc, level)
        gid !== nothing && group_id(struc.beams[bi]) == gid && continue
        sec = section(struc.beams[bi])
        sec === nothing && continue
        h = _concrete_rib_depth(sec)
        h === nothing && throw(ArgumentError(
            "slab $(level.slab_idx) has a solid head, and a sized rib is a " *
            "$(typeof(sec)). The head fills to the concrete rib soffit."))
        push!(depths, _as_metres(h))
    end
    isempty(depths) && return nothing
    href = depths[1]
    for h in depths
        abs(ustrip(u"m", h - href)) <= 1e-6 || throw(ArgumentError(
            "slab $(level.slab_idx) solid-head ribs do not share one depth " *
            "($(href) and $(h))"))
    end
    return href
end

"""Concrete the solid head is cast in, or `nothing`."""
function _solid_head_concrete(level::FramingLevel)
    opts = level.beam_options
    if opts !== nothing && hasproperty(opts, :material) &&
            getfield(opts, :material) isa StructuralSizer.Concrete
        return opts.material
    end
    return level.material isa StructuralSizer.Concrete ? level.material : nothing
end

"""
    apply_solid_head_frame_sections!(struc) -> Dict{Int, Asap.Section}

Hang the solid-head rectangles on the frame once the ribs are sized.

The depth is the sized rib's overall depth. The topping is the CIP slab
thickness already in the panel pressure. Returns the sections written,
keyed by beam index, and an empty dict when the ribs are not sized yet.
"""
function apply_solid_head_frame_sections!(struc)
    out = Dict{Int, Asap.Section}()
    for slab in struc.slabs
        for level in slab.framing_levels
            level.solid_group_id === nothing && continue
            depth = _sized_rib_depth(struc, level)
            depth === nothing && continue
            concrete = _solid_head_concrete(level)
            concrete === nothing && throw(ArgumentError(
                "slab $(level.slab_idx) has a solid head at the rib soffit, " *
                "and the framing level has no concrete"))
            result = slab.result
            result isa StructuralSizer.CIPSlabResult || throw(ArgumentError(
                "a solid head's topping is the CIP slab already in the panel " *
                "pressure, and slab $(level.slab_idx) sized a $(typeof(result))"))
            topping = _as_metres(StructuralSizer.total_depth(result))
            merge!(out, assign_solid_head_sections!(struc, level, depth, concrete;
                                                    topping = topping))
        end
    end
    return out
end

"""Mean of a bay's vertices, metres. The corner test only needs a point inside it."""
function _bay_centroid(arr, bay)
    pts = arr.nodes[bay.loop]
    n = length(pts)
    n > 0 || throw(ArgumentError("a rib bay has no vertices"))
    return (sum(p[1] for p in pts) / n, sum(p[2] for p in pts) / n)
end

"""
Corner heads of a quad panel: every bay whose centroid lies in the snapped
`solid_head` fraction, grouped by the corner it touches.

On a rectangular module grid this is the same concrete the corner fraction
cuts. `s` is that fraction, already snapped.
"""
function _fraction_solid_heads(arr, panel, s::Real)
    s > 0 || return StructuralSizer.ColumnSolidHead[]
    groups = Dict{NTuple{2, Float64}, Vector{Int}}()
    for (k, bay) in enumerate(arr.bays)
        c = _bay_centroid(arr, bay)
        local ξ, η
        try
            ξ, η = StructuralSizer.parametric_coords(panel, c[1], c[2])
        catch
            continue
        end
        StructuralSizer.is_in_solid_head(ξ, η, s) || continue
        key = (ξ <= s ? 0.0 : 1.0, η <= s ? 0.0 : 1.0)
        push!(get!(groups, key, Int[]), k)
    end
    heads = StructuralSizer.ColumnSolidHead[]
    for (key, bays) in groups
        xy = StructuralSizer.physical_coords(panel, key...)
        push!(heads, StructuralSizer.ColumnSolidHead((Float64(xy[1]), Float64(xy[2])),
                                                     sort!(bays)))
    end
    sort!(heads; by = h -> (h.column[1], h.column[2]))
    return heads
end

"""
Heads the solid concrete starts from.

A positive corner fraction is the bays inside it. A column whose bays are
not already in one of those heads gets the bays around it. A column that
meets a head in only some of its bays is an error: one bay belongs to one head.
"""
function _initial_solid_heads(struc, slab, level, arr)
    heads = StructuralSizer.ColumnSolidHead[]
    pat = level.pattern
    if pat isa IsoparametricPattern && pat.solid_head > 0
        panel = _solid_head_panel(struc, slab)
        panel === nothing && throw(ArgumentError(
            "a solid head is the corner bays of a quadrilateral panel, and this slab is not one"))
        heads = _fraction_solid_heads(arr, panel, pat.solid_head)
    end
    taken = Set(b for h in heads for b in h.bays)
    for h in slab_column_heads(struc, slab, level)
        overlap = count(in(taken), h.bays)
        overlap == length(h.bays) && continue
        overlap == 0 || throw(ArgumentError(
            "the column at $(h.column) meets a solid head in only some of its bays"))
        push!(heads, h)
        union!(taken, h.bays)
    end
    return heads
end

"""Heads whose bays the sections use. A resolved head replaces the fraction."""
function _heads_for_sections(struc, slab, level, arr)
    !isempty(level.solid_heads) && return level.solid_heads
    return _initial_solid_heads(struc, slab, level, arr)
end

"""Skeleton-edge width, metres, of every edge that bounds a solid head."""
function _solid_skeleton_widths(struc, slab, level)
    arr, owners = grillage_bays(struc, slab, level)
    heads = _heads_for_sections(struc, slab, level, arr)
    isempty(heads) && throw(ArgumentError(
        "slab $(level.slab_idx) has a solid head and no bay is cast solid"))
    widths = StructuralSizer.solid_edge_widths(arr, heads)
    skel = Dict{Int, Float64}()
    for (e, w) in widths
        1 <= e <= length(owners) || throw(ArgumentError(
            "solid-head edge $e is not an edge of the rib arrangement"))
        skel[owners[e]] = w
    end
    return skel
end

"""Width, metres, of one solid beam. Every segment of the beam bounds a head."""
function _beam_solid_width(struc, beam, skel_width::Dict{Int, Float64})
    segs = segment_indices(beam)
    isempty(segs) && throw(ArgumentError("a solid-head beam has no segment"))
    w0 = nothing
    for si in segs
        e = struc.segments[si].edge_idx
        w = get(skel_width, e, nothing)
        w === nothing && throw(ArgumentError(
            "a solid-head beam at $(_segment_mid_xy(struc, si)) does not bound a solid bay"))
        if w0 === nothing
            w0 = w
        elseif abs(w - w0) > 1e-6
            throw(ArgumentError(
                "a solid-head beam carries two widths ($(w0) m and $(w) m)"))
        end
    end
    return w0
end

"""
    assign_solid_head_sections!(struc, level, depth, concrete; topping)
        -> Dict{Int, Asap.Section}

Gross rectangle for every beam in the level's solid-head group, keyed by
beam index.

The building beam's `section` is a catalog section. This rectangle is the
analysis section, so it is written onto the frame element when the model
already has one, and returned for the caller. `depth` is the full depth at
the head, from the top of the topping to the soffit. `topping` is the
thickness already in the panel pressure. Stiffness is the gross section
(ACI 318-11 §13.7.3.1). Each family stores half of
`concrete.ρ × (depth − topping) / depth`, so the two families weigh the
projection below the topping once.
"""
function assign_solid_head_sections!(struc, level::FramingLevel, depth::Length, concrete;
                                    topping::Length)
    out = Dict{Int, Asap.Section}()
    gid = level.solid_group_id
    gid === nothing && return out
    depth_m = _as_metres(depth)
    topping_m = _as_metres(topping)
    topping_m >= zero(topping_m) || throw(ArgumentError(
        "the topping already in the panel pressure is not negative, got $(topping_m)"))
    depth_m > zero(depth_m) || throw(ArgumentError(
        "a solid head needs a positive depth, got $(depth_m)"))
    depth_m >= topping_m || throw(ArgumentError(
        "the solid head is $(depth_m) deep and the topping already in the " *
        "panel pressure is $(topping_m)"))
    projection = depth_m - topping_m
    slab = struc.slabs[level.slab_idx]
    skel_width = _solid_skeleton_widths(struc, slab, level)
    # Half the projection, so the two rib families weigh it once.
    ρ = concrete.ρ * (projection / depth_m) / 2
    nels = length(struc.asap_model.frame_elements)
    for bi in level_member_indices(struc, level)
        group_id(struc.beams[bi]) == gid || continue
        segs = segment_indices(struc.beams[bi])
        isempty(segs) && continue
        w = _beam_solid_width(struc, struc.beams[bi], skel_width)
        sec = StructuralSizer.solid_head_section(w * u"m", depth_m, concrete; density = ρ)
        out[bi] = sec
        nels == 0 && continue
        for si in segs
            e = struc.segments[si].edge_idx
            1 <= e <= nels || continue
            struc.asap_model.frame_elements[e].section = sec
        end
    end
    return out
end

"""
    solid_head_rectangles_m(struc) -> Dict{Int, NTuple{2, Float64}}

`(width, depth)` in metres for each solid-head beam, once the ribs are sized.

The width is that piece's share of the head. The depth is the sized rib's
overall depth. A level whose ribs are not sized yet is skipped.
"""
function solid_head_rectangles_m(struc)
    out = Dict{Int, NTuple{2, Float64}}()
    for slab in struc.slabs
        for level in slab.framing_levels
            level.solid_group_id === nothing && continue
            depth = _sized_rib_depth(struc, level)
            depth === nothing && continue
            skel_width = _solid_skeleton_widths(struc, slab, level)
            h = ustrip(u"m", depth)
            for bi in level_member_indices(struc, level)
                group_id(struc.beams[bi]) == level.solid_group_id || continue
                segs = segment_indices(struc.beams[bi])
                isempty(segs) && continue
                out[bi] = (_beam_solid_width(struc, struc.beams[bi], skel_width), h)
            end
        end
    end
    return out
end

"""Put beam `bi` in the level's solid-head group, creating the group if needed."""
function _claim_solid_beam!(struc, level, bi::Int)
    gid = level.solid_group_id
    if gid === nothing
        gid = _framing_solid_group_id(level)
        level.solid_group_id = gid
    end
    haskey(struc.member_groups, gid) ||
        (struc.member_groups[gid] = MemberGroup(gid, Int[], nothing))
    group_id(struc.beams[bi]) == gid && return
    _drop_beam_from_its_group!(struc, bi)
    set_group_id!(struc.beams[bi], gid)
    push!(struc.member_groups[gid].member_indices, bi)
    return
end

"""
Move every segment that bounds a resolved head into the solid-head group.

A beam that is only partly solid keeps its non-solid run and the solid runs
become new beams. The cut is already a node of the rib grid, so the skeleton
does not gain a vertex. Releases stay on the segments.
"""
function _expand_solid_to_heads!(struc, slab, level, arr, owners, heads)
    widths = StructuralSizer.solid_edge_widths(arr, heads)
    solid_edges = Set(Int[owners[e] for e in keys(widths)])
    isempty(solid_edges) && return 0
    z = _slab_elevation_m(struc, slab)
    n_before = length(struc.beams)
    moved = 0
    for bi in 1:n_before
        beam = struc.beams[bi]
        _beam_at_elevation(struc, beam, z) || continue
        segs = segment_indices(beam)
        isempty(segs) && continue
        flags = [struc.segments[si].edge_idx in solid_edges for si in segs]
        any(flags) || continue
        if all(flags)
            group_id(beam) == level.solid_group_id && continue
            _claim_solid_beam!(struc, level, bi)
            moved += 1
            continue
        end
        host_group = group_id(beam)
        runs = _flag_runs(flags)
        keep = _run_kept_on_host(flags, runs)
        _retain_segments!(struc, beam, segs[runs[keep]])
        # The piece that stays on this beam is outside the head. A beam that
        # was filed under the solid head goes back with the ribs.
        if host_group == level.solid_group_id && level.group_id !== nothing
            _drop_beam_from_its_group!(struc, bi)
            set_group_id!(beam, level.group_id)
            host_group = level.group_id
            if haskey(struc.member_groups, host_group)
                push!(struc.member_groups[host_group].member_indices, bi)
            end
        end
        for (k, run) in enumerate(runs)
            k == keep && continue
            piece = _beam_on_segments(struc, beam, segs[run])
            push!(struc.beams, piece)
            new_i = length(struc.beams)
            if flags[first(run)]
                _claim_solid_beam!(struc, level, new_i)
                moved += 1
            elseif host_group !== nothing
                set_group_id!(piece, host_group)
                if haskey(struc.member_groups, host_group)
                    push!(struc.member_groups[host_group].member_indices, new_i)
                end
            end
        end
    end
    return moved
end

"""Smallest column face on this slab, metres, or 0.40 m when none is sized."""
function _slab_column_size(struc, slab)
    z = _slab_face_z_m(struc, slab)
    faces = typeof(0.40u"m")[]
    for col in struc.columns
        _column_on_slab(struc, col, z) === nothing && continue
        (col.c1 === nothing || col.c2 === nothing) && continue
        push!(faces, min(_as_metres(col.c1), _as_metres(col.c2)))
    end
    return isempty(faces) ? 0.40u"m" : minimum(faces)
end

"""
    grow_building_solid_heads!(struc, params) -> Bool

Cast each concrete grillage's solid concrete from its rib bays, and grow a
head that fails.

The bays start as the corner fraction, where one is set, plus the bays
around any column those corners do not already cover
([`resolve_arrangement_heads`](@ref)). A failing check adds bays, and the
beams on those bays join the solid-head group. `true` when a head grew or
a beam moved. A level whose ribs are not sized yet is left alone. A second
call with the same sections returns the same heads.
"""
function grow_building_solid_heads!(struc, params)
    changed = false
    for slab in struc.slabs
        level = _grillage_level(slab)
        level === nothing && continue
        concrete = _solid_head_concrete(level)
        concrete === nothing && continue
        depth = _sized_rib_depth(struc, level)
        depth === nothing && continue
        web = _sized_rib_web(struc, level)
        web === nothing && continue
        result = slab.result
        result isa StructuralSizer.CIPSlabResult || continue
        bw, d_rib, h_rib = web
        topping = _as_metres(StructuralSizer.total_depth(result))
        arr, owners = grillage_bays(struc, slab, level)
        start = isempty(level.solid_heads) ? _initial_solid_heads(struc, slab, level, arr) :
                level.solid_heads
        isempty(start) && continue
        before = [copy(h.bays) for h in start]
        qu = _panel_factored_pressure(struc, slab, params)
        outline = _slab_interior_polygon_m(struc, slab)
        holes = _slab_hole_loops_m(struc, slab)
        resolved = resolve_arrangement_heads(arr, [h.column for h in start],
                                             ustrip(u"Pa", qu);
            heads = start, outline = something(outline, ()), holes = holes,
            concrete = concrete, depth = depth, d_head = d_rib,
            bw = bw, d_rib = d_rib, h_rib = h_rib,
            fy = _beam_materials(params)[2].Fy, topping = topping,
            column_size = _slab_column_size(struc, slab))
        level.solid_heads = resolved.heads
        grown = any(zip(before, resolved.heads)) do (was, now)
            was != now.bays
        end
        moved = _expand_solid_to_heads!(struc, slab, level, arr, owners, resolved.heads)
        level.solid_head_report = (
            ok = resolved.ok,
            stop = resolved.stop,
            steps = resolved.steps,
            ratios = [c.ratio for c in resolved.checks],
            governing = [c.governing for c in resolved.checks],
            vu_psi = maximum(ustrip(u"psi", c.column_check.vu) for c in resolved.checks;
                             init = 0.0),
        )
        (grown || moved > 0) && (changed = true)
    end
    changed && apply_solid_head_frame_sections!(struc)
    return changed
end
