# =============================================================================
# T-Beam Flange Geometry (ACI 318-11 §8.12, §8.13)
# =============================================================================
#
# The effective flange of an RC beam or rib depends on its own web width:
# `bf = bw + overhangs`, and each overhang is capped at one-half the clear
# distance to the next web (§8.12.2(b), §8.12.3(c)), which is measured from the
# web faces. This file finds, per member, the slab on each side and the nearest
# parallel web, and turns that into a flange width for any candidate `bw`.
#
# Girders keep their per-side tributary profiles (`beam_side_profiles`) and gain
# the clear-distance cap. Members of a framing level (joists, secondary beams)
# have no tributary face edges; their sides run to the nearest parallel web, or
# to the slab edge when there is none, and their flange thickness is the
# topping of the slab they frame.
# =============================================================================

const _FLANGE_PARALLEL_TOL = 1e-3   # |sin θ| below which two members are parallel
const _FLANGE_Z_TOL_M = 1e-3        # same floor
const _FLANGE_MIN_OVERLAP_M = 1e-3  # shared length along the member, meters
const _FLANGE_STRAIGHT_TOL_M = 1e-4 # chain vertices off the chord, meters

"""Plan chord of a straight beam: start `p`, unit direction `u`, length `L`, elevation `z` (meters)."""
struct _BeamChord
    p::NTuple{2, Float64}
    u::NTuple{2, Float64}
    L::Float64
    z::Float64
end

"""
Chord of `beam` along its segment chain, in the traversal order
`beam_side_profiles` uses, so "left" is the counterclockwise normal of `u` in
both. `nothing` for an empty, zero-length, or non-straight chain.
"""
function _beam_chord(struc::BuildingStructure, beam)
    skel = struc.skeleton
    segs = segment_indices(beam)
    isempty(segs) && return nothing
    verts = _ordered_chain_vertices(skel, [struc.segments[si].edge_idx for si in segs])
    p = _vertex_xy_m(skel, verts[1])
    q = _vertex_xy_m(skel, verts[end])
    L = hypot(q[1] - p[1], q[2] - p[2])
    L > 1e-9 || return nothing
    u = ((q[1] - p[1]) / L, (q[2] - p[2]) / L)
    n = (-u[2], u[1])
    for v in verts
        x = _vertex_xy_m(skel, v)
        abs(_dot2((x[1] - p[1], x[2] - p[2]), n)) <= _FLANGE_STRAIGHT_TOL_M || return nothing
    end
    return _BeamChord(p, u, L, _vertex_z_m(skel, verts[1]))
end

"""Nearest parallel web on one side: centerline-to-centerline distance (m) and its `struc.beams` index."""
struct _SideWeb
    dist_m::Float64
    neighbor::Int
end

"""
Nearest parallel beam on each side of beam `i`: same floor, parallel, and
sharing some length along `i`. Returns `(left, right)`, each a `_SideWeb` or
`nothing`.
"""
function _nearest_parallel_webs(chords::AbstractVector, i::Int)
    c = chords[i]
    n = (-c.u[2], c.u[1])
    left = nothing
    right = nothing
    for (j, o) in enumerate(chords)
        (j == i || o === nothing) && continue
        abs(o.z - c.z) <= _FLANGE_Z_TOL_M || continue
        abs(c.u[1] * o.u[2] - c.u[2] * o.u[1]) <= _FLANGE_PARALLEL_TOL || continue
        rel = (o.p[1] - c.p[1], o.p[2] - c.p[2])
        a = _dot2(rel, c.u)
        b = a + o.L * _dot2(o.u, c.u)
        lo, hi = minmax(a, b)
        min(hi, c.L) - max(lo, 0.0) > _FLANGE_MIN_OVERLAP_M || continue
        off = _dot2(rel, n)
        if off > _FLANGE_STRAIGHT_TOL_M
            (left === nothing || off < left.dist_m) && (left = _SideWeb(off, j))
        elseif off < -_FLANGE_STRAIGHT_TOL_M
            (right === nothing || -off < right.dist_m) && (right = _SideWeb(-off, j))
        end
    end
    return left, right
end

"""
Distance (m) from the midpoint of chord `c` to the boundary of `slab` along
`sign` times the left normal, or `nothing` when the ray misses the boundary.
"""
function _slab_edge_distance(struc::BuildingStructure, slab::Slab, c::_BeamChord, sign::Int)
    skel = struc.skeleton
    mid = (c.p[1] + c.L / 2 * c.u[1], c.p[2] + c.L / 2 * c.u[2])
    dir = (-sign * c.u[2], sign * c.u[1])
    best = Inf
    for e in _slab_boundary_sub_edges(struc, slab)
        a, b = skel.edge_indices[e]
        hit = _line_seg_intersect(mid, dir, _vertex_xy_m(skel, a), _vertex_xy_m(skel, b))
        hit === nothing && continue
        t = hit[1]
        t > 1e-9 && (best = min(best, t))
    end
    return isfinite(best) ? best : nothing
end

"""True when the whole chord lies on `poly`."""
function _chord_on_polygon(c::_BeamChord, poly::Vector{NTuple{2, Float64}}; tol::Float64 = 1e-3)
    for s in (0.0, 0.5, 1.0)
        x = c.p[1] + s * c.L * c.u[1]
        y = c.p[2] + s * c.L * c.u[2]
        _point_on_polygon_boundary(x, y, poly; tol = tol) || return false
    end
    return true
end

"""
Flange thickness of a slab whose boundary contains one of `idxs`, or `nothing`.

Used when a perimeter girder is not stored as a face edge, so
[`_edge_slab_thickness`](@ref) has no entry for it.
"""
function _boundary_group_hf(struc, idxs, chords)
    for mi in idxs
        c = chords[mi]
        c === nothing && continue
        for slab in struc.slabs
            poly = _slab_interior_polygon_m(struc, slab)
            poly === nothing && continue
            _chord_on_polygon(c, poly) || continue
            hf = _slab_flange_hf(slab)
            hf === nothing && continue
            return hf
        end
    end
    return nothing
end

"""
One-sided T-beam flange for a member whose centerline is the slab boundary.

ACI 318-11 §8.12.3 (corpus: aci-318-11, page 119): the slab is on one side
only, so the outward side is dropped. The inward extent is the clear distance
to the next parallel web, or the distance across the slab when there is no
web. A centerline that is not on a slab boundary returns `nothing`
(ACI 318-11 §8.12.1: the flange and the web are built integrally). The width
limits themselves stay in `flange_width_at_station`.
"""
function _boundary_member_flange(struc, mi::Int, chords; field::Bool, level_gids)
    c = chords[mi]
    c === nothing && return nothing
    lw, rw = _nearest_parallel_webs(chords, mi)
    for slab in struc.slabs
        poly = _slab_interior_polygon_m(struc, slab)
        poly === nothing && continue
        _chord_on_polygon(c, poly) || continue
        nx, ny = -c.u[2], c.u[1]
        mid = (c.p[1] + 0.5 * c.L * c.u[1], c.p[2] + 0.5 * c.L * c.u[2])
        inward = nothing
        for sign in (1, -1)
            tx = mid[1] + sign * 0.02 * nx
            ty = mid[2] + sign * 0.02 * ny
            _point_on_polygon_boundary(tx, ty, poly; tol = 1e-4) && continue
            _point_in_polygon_xy(tx, ty, poly) || continue
            inward = sign
            break
        end
        inward === nothing && continue
        web = inward > 0 ? lw : rw
        dist = web !== nothing ? web.dist_m :
            _slab_edge_distance(struc, slab, c, inward > 0 ? 1 : -1)
        dist === nothing && continue
        side = StructuralSizer.SideExtentProfile(dist)
        left = inward > 0 ? side : nothing
        right = inward > 0 ? nothing : side
        le = inward > 0 && web === nothing ? dist : nothing
        re = inward < 0 && web === nothing ? dist : nothing
        m = struc.beams[mi]
        return _MemberFlange(mi, _member_span(struc, m), left, right,
                             inward > 0 ? lw : nothing,
                             inward < 0 ? rw : nothing,
                             le, re, true,
                             field ? beam_signed_moment_field(struc, m) : nothing,
                             level_gids)
    end
    return nothing
end

"""
Flange geometry of one member.

- `ln`: span for the §8.12 length caps, the member's support-to-support length.
- `left`, `right`: per-side extent profiles (`nothing`: no slab on that side).
- `left_web`, `right_web`: nearest parallel web; caps that side at one-half the
  clear distance to it.
- `left_edge_m`, `right_edge_m`: framing-level member with no web on that side,
  the distance from its centerline to the slab edge. The overhang stops at the
  edge.
- `one_side`: `true` applies §8.12.3 to both sides (a free slab edge); `nothing`
  lets a missing side decide.
- `field`: `(M_of_s, breakpoints)` for a girder whose profiles vary, `nothing`
  when the flange is the same at every station.
- `level_gids`: member groups of the member's own framing level (empty for a
  girder).
"""
struct _MemberFlange
    beam_idx::Int
    ln::typeof(1.0u"m")
    left::Union{StructuralSizer.SideExtentProfile, Nothing}
    right::Union{StructuralSizer.SideExtentProfile, Nothing}
    left_web::Union{_SideWeb, Nothing}
    right_web::Union{_SideWeb, Nothing}
    left_edge_m::Union{Float64, Nothing}
    right_edge_m::Union{Float64, Nothing}
    one_side::Union{Bool, Nothing}
    field::Any
    level_gids::Vector{UInt64}
end

"""
Flange geometry of one member group.

`hf` is the thinnest slab the group bears. `joist_spacing` is the rib spacing
when the group is ribs of ACI 318-11 §8.13 joist construction, else `nothing`.
"""
struct _GroupFlange
    hf::typeof(1.0u"m")
    members::Vector{_MemberFlange}
    joist_spacing::Union{Nothing, typeof(1.0u"m")}
end

"""Web width (m) of a sized beam section, or `nothing` when unsized or unknown."""
_section_web_width(::Nothing) = nothing
function _section_web_width(sec)
    sec isa StructuralSizer.RCTBeamSection && return uconvert(u"m", sec.bw)
    sec isa StructuralSizer.RCBeamSection && return uconvert(u"m", sec.b)
    # A steel beam's flange is what the slab bears against and reaches around.
    hasproperty(sec, :bf) && getproperty(sec, :bf) isa Unitful.Length &&
        return uconvert(u"m", sec.bf)
    return nothing
end

"""
`beam index => (slab, framing level)` for every member of a materialized framing
level. Read from each beam's own group id: `struc.member_groups` holds only the
last member type grouped (columns, after column sizing).
"""
function _framing_home(struc::BuildingStructure)
    owner = Dict{UInt64, Tuple{Slab, FramingLevel}}()
    for slab in struc.slabs, fl in slab.framing_levels, gid in level_group_ids(fl)
        owner[gid] = (slab, fl)
    end
    home = Dict{Int, Tuple{Slab, FramingLevel}}()
    isempty(owner) && return home
    for (i, b) in enumerate(struc.beams)
        gid = group_id(b)
        gid === nothing && continue
        entry = get(owner, gid, nothing)
        entry === nothing || (home[i] = entry)
    end
    return home
end

"""
Center-to-center rib spacing (m) of a `:joist` level, or `nothing` when it has none.

ACI 318-11 §8.13.1 (corpus: aci-318-11, page 120) defines joist construction as
regularly spaced ribs spanning one way or two orthogonal ways. A module grid
qualifies, cut edge bays included, and its larger module side is the stricter
§8.13.3 center spacing. Radial and custom ribs are not regularly spaced, so
they return `nothing`: §8.13.4 designs them as slabs and beams, without the
joist increase.
"""
function _rib_spacing_m(struc::BuildingStructure, fl::FramingLevel)
    fl.role === :joist || return nothing
    pat = fl.pattern
    if pat isa LinearAxisPattern
        if pat.spacing !== nothing
            return pat.spacing isa Unitful.Quantity ? ustrip(u"m", pat.spacing) : Float64(pat.spacing)
        end
        return _infer_joist_spacing_m(struc, fl, pat.axis)
    end
    pat isa ModularRibPattern && return maximum(pat.spacing)
    pat isa IsoparametricPattern || return nothing
    return _isoparametric_spacing_m(struc, fl)
end

"""
Larger center-to-center bay of an isoparametric rib grid, in metres.

ACI 318-11 §8.13.3 (corpus: aci-318-11, page 120) limits the clear spacing.
The larger of the two bay directions is the stricter center spacing. A panel
that is not a quadrilateral returns `nothing`, and the joist increase stays off.
"""
function _isoparametric_spacing_m(struc::BuildingStructure, fl::FramingLevel)
    fl.slab_idx < 1 && return nothing
    fl.slab_idx > length(struc.slabs) && return nothing
    poly = _slab_interior_polygon_m(struc, struc.slabs[fl.slab_idx])
    poly === nothing && return nothing
    corners = _panel_corners(poly)
    length(corners) == 4 || return nothing
    Lξ = hypot(corners[2][1] - corners[1][1], corners[2][2] - corners[1][2])
    Lη = hypot(corners[4][1] - corners[1][1], corners[4][2] - corners[1][2])
    (Lξ > 1e-9 && Lη > 1e-9) || return nothing
    return max(Lξ / fl.pattern.n_xi, Lη / fl.pattern.n_eta)
end

"""Flange thickness `hf` (m) a beam may take from `slab`, or `nothing` (vault, shaped, precast, timber)."""
function _slab_flange_hf(slab)
    hf = StructuralSizer.flange_thickness(slab.result)
    return hf === nothing ? nothing : uconvert(u"m", hf)
end

"""
Edge → flange thicknesses (m) of the slabs on that edge, including host sub-edges
split by joist landings. An entry is `nothing` when that slab offers no flange.
"""
function _edge_slab_thickness(struc::BuildingStructure)
    skel = struc.skeleton
    HF = Union{Nothing, typeof(1.0u"m")}
    out = Dict{Int, Vector{HF}}()
    for slab in struc.slabs
        hf = _slab_flange_hf(slab)
        for cell_idx in slab.cell_indices
            face_idx = struc.cells[cell_idx].face_idx
            for e in skel.face_edge_indices[face_idx]
                push!(get!(Vector{HF}, out, e), hf)
                for sub in get(skel.edge_chains, hash((:framing_host_chain, e)), Int[])
                    push!(get!(Vector{HF}, out, sub), hf)
                end
            end
        end
    end
    return out
end

"""Support-to-support length of `beam` (m)."""
function _member_span(struc::BuildingStructure, beam)
    L = sum(struc.segments[si].L for si in segment_indices(beam))
    return uconvert(u"m", L isa Unitful.Quantity ? L : L * u"m")
end

"""
    _compute_flange_params(struc, group_ids) -> Vector{Union{Nothing, _GroupFlange}}

Flange geometry per beam group, or `nothing` for a group with no slab (sized
rectangular). Evaluate a width with [`_group_flange_width`](@ref).

A girder group takes `hf` from the slabs on its edges and its sides from
`beam_side_profiles`. A framing-level group (joists, secondary beams) takes `hf`
from the slab it frames and its sides from the nearest parallel webs.
"""
function _compute_flange_params(struc::BuildingStructure, group_ids::AbstractVector{UInt64})
    chords = [_beam_chord(struc, b) for b in struc.beams]
    edge_hf = _edge_slab_thickness(struc)
    home = _framing_home(struc)
    out = Vector{Union{Nothing, _GroupFlange}}(nothing, length(group_ids))

    for (g, gid) in enumerate(group_ids)
        idxs = struc.member_groups[gid].member_indices
        isempty(idxs) && continue
        framed = count(mi -> haskey(home, mi), idxs)
        if framed == length(idxs)
            out[g] = _framed_group_flange(struc, idxs, chords, home)
        elseif framed == 0
            out[g] = _girder_group_flange(struc, idxs, chords, edge_hf)
        else
            throw(ArgumentError(
                "beam group $gid mixes framing-level members with girders; the T-beam " *
                "flange (ACI 318-11 §8.12) is defined per kind, so they cannot share one section"))
        end
    end
    return out
end

"""
Flange geometry of girder `mi`: tributary side profiles, capped at one-half the
clear distance to the nearest parallel web. `field = true` also samples the
signed moment field that picks the governing station. `nothing` without slab.
"""
function _girder_member_flange(struc, mi::Int, chords; field::Bool = true)
    m = struc.beams[mi]
    left, right = beam_side_profiles(struc, m)
    if left === nothing && right === nothing
        # No tributary profile. A centerline on the slab boundary is still an
        # edge T-beam (ACI 318-11 §8.12.3, corpus: aci-318-11, page 119).
        return _boundary_member_flange(struc, mi, chords; field = field,
                                       level_gids = UInt64[])
    end
    lw, rw = chords[mi] === nothing ? (nothing, nothing) : _nearest_parallel_webs(chords, mi)
    # One profile means slab on one side. The width check already treats a
    # missing side as §8.12.3; the flag is what collinear bar sharing reads.
    one = (left === nothing) != (right === nothing) ? true : nothing
    return _MemberFlange(mi, _member_span(struc, m), left, right,
                         left === nothing ? nothing : lw,
                         right === nothing ? nothing : rw,
                         nothing, nothing, one,
                         field ? beam_signed_moment_field(struc, m) : nothing, UInt64[])
end

"""
Flange geometry of framing-level member `mi` in `slab`: each side runs to the
nearest parallel web, or to the slab edge when there is none. A side that ends
at a free slab edge makes the member an edge T-beam, so §8.12.3 governs both
overhangs. `nothing` when neither side has slab.
"""
function _framed_member_flange(struc, mi::Int, slab::Slab, fl::FramingLevel, chords)
    c = chords[mi]
    c === nothing && throw(ArgumentError(
        "framing member $mi is not straight; its T-beam flange (ACI 318-11 §8.12) " *
        "needs a straight member. Set include_flange=false for this level."))
    lw, rw = _nearest_parallel_webs(chords, mi)
    le = lw === nothing ? _slab_edge_distance(struc, slab, c, +1) : nothing
    re = rw === nothing ? _slab_edge_distance(struc, slab, c, -1) : nothing
    side(w, e) = w !== nothing ? StructuralSizer.SideExtentProfile(w.dist_m) :
                 e !== nothing ? StructuralSizer.SideExtentProfile(e) : nothing
    left, right = side(lw, le), side(rw, re)
    if left === nothing && right === nothing
        return _boundary_member_flange(struc, mi, chords; field = false,
                                       level_gids = level_group_ids(fl))
    end
    # A missing side is slab on one side only (ACI 318-11 §8.12.3). A side
    # that reaches a free edge with no web is the same. An inset rib with a
    # web on both sides stays two-sided (§8.12.2).
    missing_side = (left === nothing) != (right === nothing)
    free = missing_side || (left !== nothing && lw === nothing) ||
           (right !== nothing && rw === nothing)
    return _MemberFlange(mi, _member_span(struc, struc.beams[mi]), left, right,
                         lw, rw, le, re, free ? true : nothing, nothing,
                         level_group_ids(fl))
end

"""
Girder group: `hf` from the slabs on its edges, sides from the tributary profiles.
A girder bearing any slab without a solid flange (e.g. a vault) is sized rectangular.
"""
function _girder_group_flange(struc, idxs, chords, edge_hf)
    hfs = Union{Nothing, typeof(1.0u"m")}[]
    for mi in idxs, si in segment_indices(struc.beams[mi])
        append!(hfs, get(edge_hf, struc.segments[si].edge_idx, ()))
    end
    if isempty(hfs)
        # The perimeter member is not recorded as a face edge. If its
        # centerline is the slab boundary it still bears that slab.
        hf = _boundary_group_hf(struc, idxs, chords)
        hf === nothing && return nothing
        hfs = [hf]
    end
    any(isnothing, hfs) && return nothing
    members = _MemberFlange[mf for mf in (_girder_member_flange(struc, mi, chords) for mi in idxs)
                            if mf !== nothing]
    isempty(members) && return nothing
    return _GroupFlange(minimum(hfs), members, nothing)
end

"""Framing-level group: `hf` is the framed slab's topping, sides run to the next web or the slab edge."""
function _framed_group_flange(struc, idxs, chords, home)
    hfs = typeof(1.0u"m")[]
    spacings = Float64[]
    all_ribs = true
    members = _MemberFlange[]
    for mi in idxs
        slab, fl = home[mi]
        hf = _slab_flange_hf(slab)
        hf === nothing && return nothing
        push!(hfs, hf)
        s = _rib_spacing_m(struc, fl)
        s === nothing ? (all_ribs = false) : push!(spacings, s)
        mf = _framed_member_flange(struc, mi, slab, fl, chords)
        mf === nothing || push!(members, mf)
    end
    isempty(members) && return nothing
    # The widest spacing is the one §8.13.3 must hold for.
    spacing = all_ribs && !isempty(spacings) ? maximum(spacings) * u"m" : nothing
    return _GroupFlange(minimum(hfs), members, spacing)
end

"""
Web width assumed for the neighbor across `web` when sizing member `mf` with
candidate web `bw`.

- Neighbor in the batch being sized: it gets the same section, so `bw`.
- Neighbor sized earlier in this `size_beams!` call (a lower framing level, or a
  framing level when `me` is a girder): its section.
- Otherwise its section is not final yet, so the widest web it could take:
  `rib_web_max` for a member of the same framing level, the widest built-in
  T-beam web for anything else, or its current section if wider.

`final = true` is for use after sizing: every sized neighbor's section is read.
"""
function _neighbor_web_width(struc, mf::_MemberFlange, web::_SideWeb, bw, batch,
                             rib_web_max; final::Bool = false)
    nb = struc.beams[web.neighbor]
    gid = group_id(nb)
    gid !== nothing && gid in batch && return uconvert(u"m", bw)
    sized = _section_web_width(section(nb))
    same_level = gid !== nothing && gid in mf.level_gids
    lv_me, lv_nb = level_of(struc.beams[mf.beam_idx]), level_of(nb)
    sized_before = final || (!same_level && lv_nb >= 1 && (lv_me == 0 || lv_nb < lv_me))
    sized_before && sized !== nothing && return sized
    fallback = uconvert(u"m", same_level ? rib_web_max : StructuralSizer.MAX_CATALOG_TBEAM_WEB)
    return sized === nothing ? fallback : max(fallback, sized)
end

"""
Overhang cap on one side from the geometry: one-half the clear distance to the
next web (ACI 318-11 §8.12.2(b), §8.12.3(c)), or the distance from the web face
to a free slab edge. `nothing` when neither applies.
"""
function _side_clear_cap(struc, mf::_MemberFlange, web, edge_m, bw, batch, rib_web_max;
                         final::Bool = false)
    if web !== nothing
        bn = _neighbor_web_width(struc, mf, web, bw, batch, rib_web_max; final)
        return (web.dist_m * u"m" - bw / 2 - bn / 2) / 2
    end
    edge_m === nothing && return nothing
    return edge_m * u"m" - bw / 2
end

"""Flange width (m) of one member for candidate web `bw` and flange thickness `hf`."""
function _member_flange_width(struc, mf::_MemberFlange, bw, hf; batch, rib_web_max)
    lc = _side_clear_cap(struc, mf, mf.left_web, mf.left_edge_m, bw, batch, rib_web_max)
    rc = _side_clear_cap(struc, mf, mf.right_web, mf.right_edge_m, bw, batch, rib_web_max)
    kw = (left = mf.left, right = mf.right, left_clear = lc, right_clear = rc,
          one_side = mf.one_side)
    bf = if mf.field === nothing
        StructuralSizer.flange_width_at_station(bw, hf, mf.ln, 0.5; kw...)
    else
        M_of_s, bps = mf.field
        StructuralSizer.governing_flange_width(bw, hf, mf.ln, M_of_s; kw...,
                                               extra_breakpoints = bps)
    end
    return uconvert(u"m", bf)
end

"""
    _group_flange_width(struc, spec, bw; hf=spec.hf, batch, rib_web_max) -> Length

Narrowest member flange of the group for candidate web `bw`: the group shares
one section, so the member with the least flange governs. `batch` holds the
group ids sized together with this one.
"""
function _group_flange_width(struc, spec::_GroupFlange, bw;
                             hf = spec.hf, batch = Set{UInt64}(),
                             rib_web_max = StructuralSizer.MAX_CATALOG_TBEAM_WEB)
    return minimum(_member_flange_width(struc, mf, bw, hf; batch, rib_web_max)
                   for mf in spec.members)
end

"""
    _service_flange_sides(struc, mi, bw, ctx) -> NamedTuple or nothing

Flange sides of sized beam `mi` with web `bw` for the story-shell service
model, from the same geometry sizing used, with neighbors' final sections:
`(; left, right, left_clear, right_clear, one_side, hf)`. `hf` is the topping
for a framing-level member and `nothing` for a girder. `ctx` is
`(; chords, home)` from [`_flange_context`](@ref). `nothing` when neither side
has slab.
"""
function _service_flange_sides(struc::BuildingStructure, mi::Int, bw, ctx)
    entry = get(ctx.home, mi, nothing)
    hf = entry === nothing ? nothing : _slab_flange_hf(entry[1])
    entry !== nothing && hf === nothing && return nothing
    mf = entry === nothing ? _girder_member_flange(struc, mi, ctx.chords; field = false) :
                             _framed_member_flange(struc, mi, entry[1], entry[2], ctx.chords)
    mf === nothing && return nothing
    gid = group_id(struc.beams[mi])
    batch = gid === nothing ? Set{UInt64}() : Set([gid])
    cap(web, edge) = _side_clear_cap(struc, mf, web, edge, bw, batch,
                                     StructuralSizer.MAX_CATALOG_TBEAM_WEB; final = true)
    return (left = mf.left, right = mf.right,
            left_clear = cap(mf.left_web, mf.left_edge_m),
            right_clear = cap(mf.right_web, mf.right_edge_m),
            one_side = mf.one_side, hf = hf)
end

"""Chords and framing homes shared by every [`_service_flange_sides`](@ref) call on one story."""
_flange_context(struc::BuildingStructure) =
    (chords = [_beam_chord(struc, b) for b in struc.beams], home = _framing_home(struc))

"""
Widest web a framing-level neighbor can take under `opts`: the custom catalog's
widest, the joist-rib catalog's when it applies at `joist_spacing`, or the widest
built-in T-beam web.
"""
function _rib_web_max(opts, joist_spacing)
    if opts.custom_catalog !== nothing
        ws = [w for w in (_section_web_width(s) for s in opts.custom_catalog) if w !== nothing]
        isempty(ws) || return maximum(ws)
    end
    if joist_spacing !== nothing
        s_in = ustrip(u"inch", joist_spacing)
        any(w -> 0 < s_in - w <= 30, 4:8) && return StructuralSizer.MAX_JOIST_RIB_WIDTH
    end
    return StructuralSizer.MAX_CATALOG_TBEAM_WEB
end

"""
    _verify_tbeam_flanges(struc, accept)

Check the one assumption T-beam sizing makes about sections it cannot see yet.
A neighbor on another level that is sized later was assumed to be at most
`MAX_CATALOG_TBEAM_WEB` wide (see [`_neighbor_web_width`](@ref)). If it came out
wider, the clear distance (ACI 318-11 §8.12.2(b)) and so the flange used were
too large, and this throws. Neighbors in the member's own framing level are
bounded by that level's catalog, and neighbors sized earlier were read directly.
"""
function _verify_tbeam_flanges(struc::BuildingStructure, accept)
    gids = UInt64[gid for (gid, mg) in struc.member_groups
                  if mg.section isa StructuralSizer.RCTBeamSection &&
                     (accept === nothing || accept(gid))]
    isempty(gids) && return nothing
    chords = [_beam_chord(struc, b) for b in struc.beams]
    home = _framing_home(struc)
    bound = uconvert(u"m", StructuralSizer.MAX_CATALOG_TBEAM_WEB)
    for gid in gids, mi in struc.member_groups[gid].member_indices
        chords[mi] === nothing && continue
        lv_me = level_of(struc.beams[mi])
        own = haskey(home, mi) ? level_group_ids(home[mi][2]) : UInt64[]
        for web in _nearest_parallel_webs(chords, mi)
            web === nothing && continue
            nb = struc.beams[web.neighbor]
            gnb = group_id(nb)
            (gnb == gid || (gnb !== nothing && gnb in own)) && continue
            lv_nb = level_of(nb)
            (lv_nb >= 1 && (lv_me == 0 || lv_nb < lv_me)) && continue
            w = _section_web_width(section(nb))
            (w === nothing || w <= bound + 1e-9u"m") && continue
            throw(ErrorException(
                "T-beam group $gid was sized assuming its neighbor beam $(web.neighbor) " *
                "is at most $(uconvert(u"inch", bound)) wide, but that beam is " *
                "$(round(u"inch", w; digits = 2)). The flange's clear-distance cap " *
                "(ACI 318-11 §8.12.2(b)) is then too large. Narrow that beam's catalog " *
                "or set include_flange = false."))
        end
    end
    return nothing
end
