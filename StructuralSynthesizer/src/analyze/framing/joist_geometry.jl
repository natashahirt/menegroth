# -----------------------------------------------------------------------------
# Geometry helpers
# -----------------------------------------------------------------------------

"""Length in the structure's unit `T` from a raw Meshes measure (meters)."""
_len_T(::Type{T}, L) where {T} = T <: Unitful.Quantity ? convert(T, L) : ustrip(u"m", L)
_len_T(::Type{T}, x::Real) where {T} = T <: Unitful.Quantity ? convert(T, x * u"m") : convert(T, x)

"""Stable UInt64 group id for a level: `(slab_idx, level, role, material)`."""
_framing_group_id(level::FramingLevel) =
    hash((:framing_level, level.slab_idx, level.level, level.role, level.material))

"""Member-group id of a level's outermost joists (see `FramingLevel.edge_group_id`)."""
_framing_edge_group_id(level::FramingLevel) = hash((:framing_level_edge, _framing_group_id(level)))

"""Member-group id of the pieces inside a solid head."""
_framing_solid_group_id(level::FramingLevel) = hash((:framing_solid_head, _framing_group_id(level)))

"""Group id of one grillage rib piece, from its two end vertices."""
function _framing_piece_group_id(level::FramingLevel, va::Int, vb::Int)
    a, b = va < vb ? (va, vb) : (vb, va)
    return hash((:framing_piece, _framing_group_id(level), a, b))
end

"""
The two vertices that end `beam`.

A vertex on one edge of the beam is an end. A vertex on two edges is an
interior joint. `nothing` when the beam is branched or closed.
"""
function _beam_terminals(struc, beam)
    counts = Dict{Int, Int}()
    for si in segment_indices(beam)
        a, b = struc.skeleton.edge_indices[struc.segments[si].edge_idx]
        counts[a] = get(counts, a, 0) + 1
        counts[b] = get(counts, b, 0) + 1
    end
    ends = [v for (v, c) in counts if c == 1]
    length(ends) == 2 || return nothing
    return (ends[1], ends[2])
end

"""
Put beam `bi` in its own grillage rib group.

The section is sized from that piece's demand. Collinear pieces still share
a bar size later; they do not share this group.
"""
function _claim_rib_piece!(struc, level::FramingLevel, bi::Int)
    beam = struc.beams[bi]
    terminals = _beam_terminals(struc, beam)
    pg = if terminals === nothing
        edges = sort!(Int[struc.segments[si].edge_idx for si in segment_indices(beam)])
        hash((:framing_piece, _framing_group_id(level), edges))
    else
        _framing_piece_group_id(level, terminals[1], terminals[2])
    end
    old = group_id(beam)
    old == pg && return pg
    _drop_beam_from_its_group!(struc, bi)
    if old !== nothing && old in level.piece_group_ids
        mg = get(struc.member_groups, old, nothing)
        (mg === nothing || isempty(mg.member_indices)) &&
            filter!(i -> i != old, level.piece_group_ids)
    end
    set_group_id!(beam, pg)
    pg in level.piece_group_ids || push!(level.piece_group_ids, pg)
    mg = get!(struc.member_groups, pg) do
        MemberGroup(pg)
    end
    bi in mg.member_indices || push!(mg.member_indices, bi)
    return pg
end

"""A grillage rib of this level, as opposed to a girder on the same story."""
_level_rib(level::FramingLevel, beam) =
    rib_analysis(level) == :grillage && beam.role == level.role

"""
    _slab_boundary_edges(struc, slab) -> Vector{Int}

Edges on the outer boundary of `slab`, in the topological sense — an edge is
a slab boundary iff it belongs to exactly ONE of the slab's own faces.

A multi-cell slab's shared interior edges (between two of its own cells) are
excluded, and girders shared with an ADJACENT slab are included (they are on
this slab's perimeter, even though the adjacent slab also contains them).

This is deliberately *not* `edge_face_count(skel, e) == 1`, which is a
building-perimeter test — that would strip every interior girder shared
between adjacent slabs and leave corner/edge bays with only 1-2 boundary
edges, causing `materialize_level!` to fail to intersect joist lines on
per-bay slabs (Phase 11 follow-up: sparse-joist bug).
"""
function _slab_boundary_edges(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton

    slab_faces = Set{Int}()
    for cell_idx in slab.cell_indices
        push!(slab_faces, struc.cells[cell_idx].face_idx)
    end
    isempty(slab_faces) && return Int[]

    counts = Dict{Int, Int}()
    for f in slab_faces
        for e in skel.face_edge_indices[f]
            counts[e] = get(counts, e, 0) + 1
        end
    end

    out = [e for (e, c) in counts if c == 1]
    sort!(out)                                    # deterministic order
    return out
end

"""
    _slab_boundary_sub_edges(struc, slab) -> Vector{Int}

All boundary sub-edges of a slab, following any `_split_host_edge!` chains
recorded in `skel.edge_chains`. A prior level's joist landings on the boundary
subdivide the boundary edges, but `skel.face_edge_ids` still names the ORIGINAL
edge index (now truncated to its first sub-segment). Phase 10 needs the full
sub-edge list so a higher-level joist can intersect any part of the boundary,
not just the first sub-segment. Order along each original boundary edge is
preserved (`edge_chains` stores sub-edges in v1→v2 order — see
`_split_host_edge!`).
"""
function _slab_boundary_sub_edges(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton
    out = Int[]
    for E in _slab_boundary_edges(struc, slab)
        key = hash((:framing_host_chain, E))
        if haskey(skel.edge_chains, key)
            append!(out, skel.edge_chains[key])
        else
            push!(out, E)
        end
    end
    return out
end

"""
    _level_host_edges(struc, slab, level_idx) -> Vector{Int}

Host-edge candidates for a level's joist landings (Phase 10).

- **Level 1** → slab boundary sub-edges, the girders shared by this slab's own
  cells, and this slab's walls. A tributary joist that crosses an interior
  girder or a wall lands on it.
- **Level `N ≥ 2`** → those same edges ∪ every edge of every level-`N-1` beam.
  A level-`N` joist crossing a level-`N-1` beam therefore lands on it as an
  interior support (the joist becomes a continuous chain over its host lattice).

The boundary is always included so a level-`N ≥ 2` joist can span from perimeter
to perimeter over interior level-`N-1` supports (the standard secondary-beam
convention). A previous-level beam on another story, or in another slab, is
not a host: its edge must sit at this slab's elevation and its midpoint must
lie in this slab. Returned indices are unique and sorted for determinism.
"""
function _level_host_edges(struc::BuildingStructure, slab::Slab, level_idx::Int)
    boundary = _slab_boundary_sub_edges(struc, slab)
    hosts = vcat(boundary, _slab_interior_sub_edges(struc, slab),
                 _slab_wall_edges(struc, slab))
    level_idx == 1 && return unique!(sort!(hosts))

    prev = level_idx - 1
    z = _slab_elevation_m(struc, slab)
    poly = _slab_interior_polygon_m(struc, slab)
    prev_edges = Int[]
    for b in struc.beams
        level_of(b) == prev || continue
        for si in segment_indices(b)
            si <= length(struc.segments) || continue
            e = struc.segments[si].edge_idx
            _edge_on_this_slab(struc, e, z, poly) || continue
            push!(prev_edges, e)
        end
    end
    return unique!(sort!(vcat(hosts, prev_edges)))
end

"""
Wall edges of this slab: the `:walls` group, at this slab's elevation, with
the midpoint in the slab. A wall on another story is not a joist host.
"""
function _slab_wall_edges(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton
    z = _slab_elevation_m(struc, slab)
    poly = _slab_interior_polygon_m(struc, slab)
    out = Int[]
    for e in get(skel.groups_edges, :walls, Int[])
        _edge_on_this_slab(struc, e, z, poly) || continue
        push!(out, e)
    end
    return out
end

"""Beam or wall that owns `edge`, or `nothing` when the edge is only geometry."""
function _member_for_edge(struc::BuildingStructure, edge::Int)
    for member in Iterators.flatten((struc.beams, struc.walls))
        for si in segment_indices(member)
            si <= length(struc.segments) || continue
            struc.segments[si].edge_idx == edge && return member
        end
    end
    return nothing
end

"""Elevation (m) of the slab boundary, or `nothing` when it has no edge."""
function _slab_elevation_m(struc::BuildingStructure, slab::Slab)
    edges = _slab_boundary_edges(struc, slab)
    isempty(edges) && return nothing
    v1, _ = struc.skeleton.edge_indices[first(edges)]
    return _vertex_z_m(struc.skeleton, v1)
end

"""
`edge` belongs to this slab: both ends are within 1 cm of `z`, and the
midpoint lies in `poly`. `poly === nothing` keeps the elevation test only.
"""
function _edge_on_this_slab(struc::BuildingStructure, edge::Int, z, poly)
    z === nothing && return false
    v1, v2 = struc.skeleton.edge_indices[edge]
    abs(_vertex_z_m(struc.skeleton, v1) - z) <= 0.01 || return false
    abs(_vertex_z_m(struc.skeleton, v2) - z) <= 0.01 || return false
    poly === nothing && return true
    a = _vertex_xy_m(struc.skeleton, v1)
    b = _vertex_xy_m(struc.skeleton, v2)
    mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
    return _point_in_polygon(mid, poly)
end

"""Map each host beam's edges to its beam index (for subdivision bookkeeping)."""
function _edge_to_beam_map(struc::BuildingStructure)
    m = Dict{Int, Int}()
    for (bi, beam) in enumerate(struc.beams)
        for si in segment_indices(beam)
            si <= length(struc.segments) || continue
            m[struc.segments[si].edge_idx] = bi
        end
    end
    return m
end

"""XY of a skeleton vertex in meters (Float64)."""
function _vertex_xy_m(skel, v::Int)
    c = Meshes.coords(skel.vertices[v])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

"""Z of a skeleton vertex in meters (Float64)."""
_vertex_z_m(skel, v::Int) = ustrip(u"m", Meshes.coords(skel.vertices[v]).z)

"""2D dot product."""
_dot2(a::NTuple{2, Float64}, b::NTuple{2, Float64}) = a[1] * b[1] + a[2] * b[2]

"""Unit-normalize a 2D direction; returns `(0,0)` for a zero vector."""
function _unit2(a::NTuple{2, Float64})
    n = hypot(a[1], a[2])
    n < 1e-12 && return (0.0, 0.0)
    return (a[1] / n, a[2] / n)
end

"""
    _pattern_joist_lines(struc, slab, host_edges, pattern) -> Vector{Tuple{NTuple{2,Float64}, NTuple{2,Float64}}}

Resolve `pattern` to joist center-lines in slab-local 2D meters, each a
`(point, unit-direction)` pair. Lines are extended infinitely; the boundary
crossings become the joist ends in `materialize_level!`, which additionally clips
each line to the slab interior on non-convex boundaries (see the concave-safe
guard there) so no joist crosses a re-entrant notch.
"""
function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              host_edges::Vector{Int},
                              pattern::LinearAxisPattern)
    skel = struc.skeleton
    a = _unit2(pattern.axis)
    a == (0.0, 0.0) && return Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    perp = (-a[2], a[1])                         # joists laid out ⟂ to axis

    # Perpendicular extent of the slab boundary vertices.
    verts = Set{Int}()
    for e in host_edges
        v1, v2 = skel.edge_indices[e]
        push!(verts, v1); push!(verts, v2)
    end
    isempty(verts) && return Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    projs = [_dot2(_vertex_xy_m(skel, v), perp) for v in verts]
    pmin, pmax = extrema(projs)
    W = pmax - pmin
    W <= 1e-9 && return Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]

    positions = _joist_offsets(pattern, pmin, pmax, W)
    return [((q * perp[1], q * perp[2]), a) for q in positions]
end

"""
Drop collinear stations so a rectangle with mid-edge vertices stays a quad.

The first point is not repeated at the end. A vertex stays when the turn
there is larger than `tol` in plan area units.
"""
function _panel_corners(poly::Vector{NTuple{2, Float64}}; tol::Float64 = 1e-8)
    pts = NTuple{2, Float64}[]
    for p in poly
        if isempty(pts) || hypot(p[1] - pts[end][1], p[2] - pts[end][2]) > 1e-9
            push!(pts, p)
        end
    end
    if length(pts) >= 2 && hypot(pts[1][1] - pts[end][1], pts[1][2] - pts[end][2]) <= 1e-9
        pop!(pts)
    end
    length(pts) < 3 && return NTuple{2, Float64}[]
    corners = NTuple{2, Float64}[]
    n = length(pts)
    for i in 1:n
        a = pts[mod1(i - 1, n)]
        b = pts[i]
        c = pts[mod1(i + 1, n)]
        turn = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
        abs(turn) > tol && push!(corners, b)
    end
    return corners
end

"""
Interior rib lines of a quadrilateral panel, as `(point, unit direction)`.

`nξ` and `nη` are bay counts, the same counts a [`WaffleRibGrid`](@ref)
stores. The panel edges are the boundary ribs, so a 2×2 bay grid has one
interior rib each way, at the midpoint of each side. Lines of constant ξ
and constant η are straight under the bilinear map.
"""
function _isoparametric_rib_lines(poly::Vector{NTuple{2, Float64}}, nξ::Int, nη::Int)
    (nξ >= 1 && nη >= 1) || throw(ArgumentError(
        "an isoparametric rib grid needs at least one bay each way, got $nξ by $nη"))
    corners = _panel_corners(poly)
    length(corners) == 4 || throw(ArgumentError(
        "IsoparametricPattern lays ribs on a quadrilateral panel. " *
        "This boundary has $(length(corners)) corners."))
    panel = StructuralSizer.IsoParametricPanel((corners[1], corners[2], corners[3], corners[4]))
    lines = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    for i in 1:(nξ - 1)
        ξ = i / nξ
        a = StructuralSizer.physical_coords(panel, ξ, 0.0)
        b = StructuralSizer.physical_coords(panel, ξ, 1.0)
        d = _unit2((b[1] - a[1], b[2] - a[2]))
        d == (0.0, 0.0) && continue
        push!(lines, (a, d))
    end
    for j in 1:(nη - 1)
        η = j / nη
        a = StructuralSizer.physical_coords(panel, 0.0, η)
        b = StructuralSizer.physical_coords(panel, 1.0, η)
        d = _unit2((b[1] - a[1], b[2] - a[2]))
        d == (0.0, 0.0) && continue
        push!(lines, (a, d))
    end
    return lines
end

"""Iso-ξ and iso-η ribs of a quad slab. `n_xi` and `n_eta` are bay counts."""
function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              _host_edges::Vector{Int},
                              pattern::IsoparametricPattern)
    poly = _slab_interior_polygon_m(struc, slab)
    poly === nothing && throw(ArgumentError(
        "IsoparametricPattern needs the slab boundary, and this slab has none."))
    return _isoparametric_rib_lines(poly, pattern.n_xi, pattern.n_eta)
end

"""Both rib families of a module grid, over the slab's true outline."""
function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              _host_edges::Vector{Int},
                              pattern::ModularRibPattern)
    poly = _slab_interior_polygon_m(struc, slab)
    poly === nothing && throw(ArgumentError(
        "ModularRibPattern needs the slab boundary, and this slab has none."))
    lines = StructuralSizer.modular_rib_lines(poly; angle = pattern.angle,
                                              spacing = pattern.spacing,
                                              origin = pattern.origin)
    return [(l.point, l.direction) for l in lines]
end

function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              host_edges::Vector{Int},
                              pattern::RadialPattern)
    c = (Float64(pattern.center[1]), Float64(pattern.center[2]))
    return [(c, (cos(k * pattern.angular_spacing), sin(k * pattern.angular_spacing)))
            for k in 0:(pattern.n - 1)]
end

function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              host_edges::Vector{Int},
                              pattern::CustomPattern)
    polylines = pattern.generator(slab)
    lines = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    for pl in polylines
        length(pl) < 2 && continue
        p1 = (Float64(pl[1][1]), Float64(pl[1][2]))
        p2 = (Float64(pl[end][1]), Float64(pl[end][2]))
        d = _unit2((p2[1] - p1[1], p2[2] - p1[2]))
        d == (0.0, 0.0) && continue
        push!(lines, (p1, d))
    end
    return lines
end

"""
Interior joist perpendicular-offsets in `(pmin, pmax)`. With an explicit
`pattern.count`, `count` evenly spaced interior lines. Otherwise the joists sit
at `pattern.spacing` centers, centered in the bay: `n = ceil(W/s) - 1` joists
leave two equal end gaps in `(s/2, s]`, so no end gap exceeds the spacing and
none is a sliver. Returns `Float64[]` when neither spacing nor count is resolved.
"""
function _joist_offsets(pattern::LinearAxisPattern, pmin::Float64, pmax::Float64, W::Float64)
    if pattern.count !== nothing
        n = pattern.count
        n <= 0 && return Float64[]
        return [pmin + k * W / (n + 1) for k in 1:n]
    end
    pattern.spacing === nothing && return Float64[]
    sp = pattern.spacing isa Unitful.Quantity ?
        ustrip(u"m", pattern.spacing) : Float64(pattern.spacing)
    sp <= 1e-9 && return Float64[]
    # Tolerance keeps an exact multiple (W = k·s) at k − 1 joists.
    n = ceil(Int, W / sp - 1e-9) - 1
    n <= 0 && return Float64[]
    gap = (W - (n - 1) * sp) / 2
    return [pmin + gap + k * sp for k in 0:(n - 1)]
end

"""
Intersections of the infinite line `p0 + t*dir` with the slab boundary edges,
sorted by `t`. Each hit is `(edge_idx, param_u ∈ [0,1] on the edge, xy_on_edge)`.
The `xy` is taken from the host edge (`A + u*(B-A)`) so the landing lies exactly
on the edge.
"""
function _boundary_intersections(struc::BuildingStructure, host_edges::Vector{Int},
                                 p0::NTuple{2, Float64}, dir::NTuple{2, Float64})
    skel = struc.skeleton
    hits = Tuple{Float64, Int, Float64, NTuple{2, Float64}}[]   # (t, edge, u, xy)
    for e in host_edges
        v1, v2 = skel.edge_indices[e]
        A = _vertex_xy_m(skel, v1)
        B = _vertex_xy_m(skel, v2)
        res = _line_seg_intersect(p0, dir, A, B)
        res === nothing && continue
        t, u = res
        xy = (A[1] + u * (B[1] - A[1]), A[2] + u * (B[2] - A[2]))
        push!(hits, (t, e, u, xy))
    end
    sort!(hits; by = first)
    return [(e, u, xy) for (_, e, u, xy) in hits]
end

"""
    _slab_interior_polygon_m(struc, slab) -> Union{Nothing, Vector{NTuple{2, Float64}}}

The slab's TRUE outer boundary as an ordered XY polygon in meters (Float64),
reusing the concave-safe [`_get_slab_boundary_vertices`](@ref) loop (CCW, and
explicitly NOT a convex hull — it handles L/T/U re-entrant shapes). Returns
`nothing` when the boundary cannot be resolved or has fewer than three vertices,
so callers fall back to the un-clipped (convex) joist path. Used only to clip
joist center-lines to the slab interior (#5) — a geometry helper, not a
structural-mechanics decision, so no code clause applies.
"""
function _slab_interior_polygon_m(struc::BuildingStructure, slab::Slab)
    boundary_vis =
        try
            first(_get_slab_boundary_vertices(struc, slab))
        catch
            return nothing
        end
    length(boundary_vis) < 3 && return nothing
    return NTuple{2, Float64}[_vertex_xy_m(struc.skeleton, v) for v in boundary_vis]
end

"""Skeleton vertex loops of the beam rings inside the slab's faces."""
function _slab_hole_vertex_loops(struc::BuildingStructure, slab::Slab)
    loops = Vector{Int}[]
    for ci in slab.cell_indices
        append!(loops, get(struc.skeleton.face_hole_vertices, struc.cells[ci].face_idx,
                           Vector{Int}[]))
    end
    return loops
end

"""Plan loops (metres) of the beam rings inside the slab. Ribs stop at them."""
_slab_hole_loops_m(struc::BuildingStructure, slab::Slab) =
    [NTuple{2, Float64}[_vertex_xy_m(struc.skeleton, v) for v in loop]
     for loop in _slab_hole_vertex_loops(struc, slab)]

"""
Skeleton edges on the sides of the slab's hole rings, including the pieces a
landing has already split off. Ribs land on these members.
"""
function _slab_hole_edges(struc::BuildingStructure, slab::Slab; tol::Float64 = 1e-6)
    loops = _slab_hole_loops_m(struc, slab)
    isempty(loops) && return Int[]
    skel = struc.skeleton
    z = _vertex_z_m(skel, first(_slab_hole_vertex_loops(struc, slab))[1])
    out = Int[]
    for (e, (v1, v2)) in enumerate(skel.edge_indices)
        abs(_vertex_z_m(skel, v1) - z) <= tol || continue
        abs(_vertex_z_m(skel, v2) - z) <= tol || continue
        p1 = _vertex_xy_m(skel, v1)
        p2 = _vertex_xy_m(skel, v2)
        on = any(loops) do loop
            n = length(loop)
            any(1:n) do i
                a, b = loop[i], loop[mod1(i + 1, n)]
                _param_on_segment(p1, a, b; tol = tol) !== nothing &&
                    _param_on_segment(p2, a, b; tol = tol) !== nothing
            end
        end
        on && push!(out, e)
    end
    return out
end

"""
Edges shared by two of the slab's own faces, following landing splits. These
are the girders inside a multi-cell slab. A grillage rib lands on them.
"""
function _slab_interior_sub_edges(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton
    counts = Dict{Int, Int}()
    for ci in slab.cell_indices, e in skel.face_edge_indices[struc.cells[ci].face_idx]
        counts[e] = get(counts, e, 0) + 1
    end
    out = Int[]
    for (E, c) in counts
        c >= 2 || continue
        key = hash((:framing_host_chain, E))
        haskey(skel.edge_chains, key) ? append!(out, skel.edge_chains[key]) : push!(out, E)
    end
    return sort!(out)
end

"""
    _point_on_polygon_boundary(px, py, poly; tol) -> Bool

`true` when `(px, py)` lies within `tol` of any edge of the simple polygon `poly`
(i.e. ON the boundary). Used to make span interiority deterministic: an on-edge
sample point makes the even–odd ray cast [`_point_in_polygon_xy`](@ref) undefined
(a joist line collinear with a boundary edge), so such samples are rejected rather
than classified. Pure geometry — no mechanics.
"""
function _point_on_polygon_boundary(px::Float64, py::Float64,
                                    poly::Vector{NTuple{2, Float64}}; tol::Float64 = 1e-9)
    n = length(poly)
    tol2 = tol * tol
    for i in 1:n
        ax, ay = poly[i]
        bx, by = poly[mod1(i + 1, n)]
        ex = bx - ax; ey = by - ay
        L2 = ex * ex + ey * ey
        if L2 <= tol2                       # degenerate (zero-length) edge
            (px - ax)^2 + (py - ay)^2 <= tol2 && return true
            continue
        end
        # Closest point on segment AB to P, via the clamped projection parameter.
        t = clamp(((px - ax) * ex + (py - ay) * ey) / L2, 0.0, 1.0)
        cx = ax + t * ex; cy = ay + t * ey
        (px - cx)^2 + (py - cy)^2 <= tol2 && return true
    end
    return false
end

"""
    _interior_subchains(chain_xy, poly) -> Vector{Vector{Int}}

Split an ordered joist-line landing chain into maximal runs of consecutive
landings whose connecting span lies INSIDE the concave-safe slab polygon `poly`.
Interiority is decided per span by sampling SEVERAL interior points (not just the
midpoint) and requiring every sample to be strictly inside `poly` — via the
even–odd ray cast [`_point_in_polygon_xy`](@ref) — AND off the boundary (via
[`_point_on_polygon_boundary`](@ref)). Multi-point sampling plus the explicit
on-boundary rejection make the classification deterministic when a joist line is
collinear with a boundary edge (a single midpoint could land exactly on-edge,
where the ray cast is undefined) and robust for angled / non-rectilinear spans. A
span with any exterior or on-boundary sample (a re-entrant notch, or beyond the
plate) breaks the chain and that segment is dropped. A span inside or along one
of `holes` (a beam ring around an atrium) is dropped the same way. Returns index runs into
`chain_xy`; single-vertex runs are discarded by the caller. Pure geometry — no
mechanics. (Only invoked for non-convex bays; convex/rectilinear layouts skip the
clip entirely in the caller, so their behavior is unchanged.)
"""
function _interior_subchains(chain_xy::Vector{NTuple{2, Float64}},
                             poly::Vector{NTuple{2, Float64}};
                             holes::Vector{Vector{NTuple{2, Float64}}} = Vector{NTuple{2, Float64}}[])
    n = length(chain_xy)
    runs = Vector{Int}[]
    n < 2 && return runs
    # On-boundary tolerance, RELATIVE to the slab extent. An absolute 1e-9 m is
    # wrong at scale: on a large plate coordinates carry more floating-point noise,
    # while on a tiny plate 1e-9 m could swallow a real feature. Scale the base
    # 1e-9 by a characteristic length (the polygon's bounding-box diagonal) so the
    # test is dimensionally sensible for any slab size. Pure geometry — no clause.
    xs = (p[1] for p in poly); ys = (p[2] for p in poly)
    char_len = hypot(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
    bnd_tol = 1e-9 * max(char_len, 1.0)
    # Interior sample parameters along each span — deliberately NOT including the
    # endpoints (which sit on host edges) nor forcing a single midpoint.
    sample_ts = (0.15, 0.35, 0.5, 0.65, 0.85)
    current = Int[]
    for i in 1:(n - 1)
        ax, ay = chain_xy[i]
        bx, by = chain_xy[i + 1]
        span_interior = true
        # A span COLLINEAR with a boundary edge is dropped INTENTIONALLY: its
        # interior samples land on the boundary (rejected by `_point_on_polygon_
        # boundary`), so the whole span breaks the chain and no joist is laid there.
        # This is correct — that perimeter line is already carried by a level-0
        # girder, so a joist duplicating it would double the support and (via the
        # cascade) the tributary. Interior spans that merely graze a re-entrant
        # notch corner are likewise excluded, deferring that area to the per-cell
        # path. No mechanics — geometric span selection only.
        for t in sample_ts
            sx = ax + t * (bx - ax)
            sy = ay + t * (by - ay)
            if _point_on_polygon_boundary(sx, sy, poly; tol = bnd_tol) ||
               !_point_in_polygon_xy(sx, sy, poly) ||
               any(h -> _point_on_polygon_boundary(sx, sy, h; tol = bnd_tol) ||
                        _point_in_polygon_xy(sx, sy, h), holes)
                span_interior = false
                break
            end
        end
        if span_interior
            isempty(current) && push!(current, i)
            push!(current, i + 1)
        else
            length(current) >= 2 && push!(runs, current)
            current = Int[]
        end
    end
    length(current) >= 2 && push!(runs, current)
    return runs
end

"""
Intersect infinite line `p0 + t*dir` with segment `A→B`. Returns `(t, u)` with
`u ∈ [0, 1]` (clamped), or `nothing` for a parallel/degenerate case.
"""
function _line_seg_intersect(p0::NTuple{2, Float64}, dir::NTuple{2, Float64},
                             A::NTuple{2, Float64}, B::NTuple{2, Float64}; tol::Float64 = 1e-9)
    ex = B[1] - A[1]
    ey = B[2] - A[2]
    det = ex * dir[2] - ey * dir[1]        # (B-A) × dir
    abs(det) < tol && return nothing
    rx = A[1] - p0[1]
    ry = A[2] - p0[2]
    # Solve p0 + t dir = A + u (B-A):
    t = (rx * (-ey) + ex * ry) / det
    u = (dir[1] * ry - dir[2] * rx) / det
    (u < -tol || u > 1.0 + tol) && return nothing
    return (t, clamp(u, 0.0, 1.0))
end

"""
Plan outlines of the slab openings on this slab's story.

A framed opening is still listed. Its edges are supports
([`_edges_along_loops`](@ref)); an unframed opening is only this outline,
and the joist stops there.
"""
function _slab_opening_loops_m(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton
    isempty(skel.openings) && return Vector{NTuple{2, Float64}}[]
    poly = _slab_interior_polygon_m(struc, slab)
    poly === nothing && return Vector{NTuple{2, Float64}}[]
    z = _slab_elevation_m(struc, slab)
    z === nothing && return Vector{NTuple{2, Float64}}[]
    level = story_index_at(skel, z)
    level === nothing && return Vector{NTuple{2, Float64}}[]
    loops = Vector{NTuple{2, Float64}}[]
    for op in skel.openings
        op.story == level || continue
        n = length(op.loop)
        n < 3 && continue
        cx = sum(p[1] for p in op.loop) / n
        cy = sum(p[2] for p in op.loop) / n
        inside = _point_in_polygon_xy(cx, cy, poly) ||
            any(p -> _point_in_polygon_xy(p[1], p[2], poly), op.loop)
        inside && push!(loops, op.loop)
    end
    return loops
end

"""Skeleton edges that lie on an edge of one of `loops`."""
function _edges_along_loops(skel, loops; tol::Float64 = 1e-4)
    isempty(loops) && return Int[]
    out = Int[]
    for (e, (v1, v2)) in enumerate(skel.edge_indices)
        p1 = _vertex_xy_m(skel, v1)
        p2 = _vertex_xy_m(skel, v2)
        hypot(p2[1] - p1[1], p2[2] - p1[2]) <= tol && continue
        on = false
        for loop in loops
            n = length(loop)
            for i in 1:n
                a = loop[i]
                b = loop[mod1(i + 1, n)]
                _param_on_segment(p1, a, b; tol = tol) === nothing && continue
                _param_on_segment(p2, a, b; tol = tol) === nothing && continue
                on = true
                break
            end
            on && break
        end
        on && push!(out, e)
    end
    return out
end

"""A new plan vertex, in the same coordinate type the skeleton already uses."""
function _opening_stop_vertex!(skel, xy::NTuple{2, Float64}, z_m::Float64)
    sample = Meshes.coords(skel.vertices[1]).x
    if sample isa Unitful.Quantity
        pt = Meshes.Point(xy[1] * u"m", xy[2] * u"m", z_m * u"m")
        return add_vertex!(skel, pt; group = :opening_stops)
    end
    return add_vertex!(skel, [xy[1], xy[2], z_m]; group = :opening_stops)
end

"""
Insert a vertex wherever `chain` crosses an opening edge, and return the
chain split into the pieces that stay outside every opening.

Each piece is `(vertices, starts_at_chain_start, ends_at_chain_end)`.
"""
function _opening_pieces(skel, chain::Vector{Int}, loops, z_m::Float64; tol::Float64 = 1e-6)
    verts = _insert_loop_crossings!(skel, chain, loops, z_m; tol = tol)
    xy = [_vertex_xy_m(skel, v) for v in verts]
    runs = Vector{Int}[]
    current = Int[]
    for i in 1:(length(verts) - 1)
        if _span_outside_openings(xy[i], xy[i + 1], loops; tol = tol)
            isempty(current) && push!(current, i)
            push!(current, i + 1)
        else
            length(current) >= 2 && push!(runs, current)
            current = Int[]
        end
    end
    length(current) >= 2 && push!(runs, current)
    pieces = Tuple{Vector{Int}, Bool, Bool}[]
    for run in runs
        vs = verts[run]
        push!(pieces, (vs, vs[1] == chain[1], vs[end] == chain[end]))
    end
    return pieces
end

"""Chain with a vertex added at every opening-edge crossing that is not already an end."""
function _insert_loop_crossings!(skel, chain::Vector{Int}, loops, z_m::Float64; tol::Float64 = 1e-6)
    out = Int[chain[1]]
    for i in 1:(length(chain) - 1)
        a = _vertex_xy_m(skel, chain[i])
        b = _vertex_xy_m(skel, chain[i + 1])
        dir = (b[1] - a[1], b[2] - a[2])
        L = hypot(dir[1], dir[2])
        cuts = Tuple{Float64, NTuple{2, Float64}}[]
        if L > 1e-4
            for loop in loops
                n = length(loop)
                for k in 1:n
                    hit = _line_seg_intersect(a, dir, loop[k], loop[mod1(k + 1, n)]; tol = tol)
                    hit === nothing && continue
                    t, _ = hit
                    dist = min(t, 1 - t) * L
                    dist <= 1e-4 && continue
                    p = (a[1] + t * dir[1], a[2] + t * dir[2])
                    any(c -> hypot(c[2][1] - p[1], c[2][2] - p[2]) <= 1e-4, cuts) && continue
                    push!(cuts, (t, p))
                end
            end
        end
        sort!(cuts; by = first)
        for (_, p) in cuts
            push!(out, _opening_stop_vertex!(skel, p, z_m))
        end
        last(out) == chain[i + 1] || push!(out, chain[i + 1])
    end
    return out
end

"""`true` when the open segment from `a` to `b` stays out of every opening."""
function _span_outside_openings(a::NTuple{2, Float64}, b::NTuple{2, Float64}, loops; tol::Float64 = 1e-6)
    for loop in loops
        _span_meets_loop(a, b, loop; tol = tol) && return false
    end
    return true
end

"""`true` when samples of `a→b` lie in `loop`, or the whole span lies on its boundary."""
function _span_meets_loop(a::NTuple{2, Float64}, b::NTuple{2, Float64}, loop; tol::Float64 = 1e-6)
    on = 0
    for t in (0.2, 0.5, 0.8)
        s = (a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]))
        if _point_on_polygon_boundary(s[1], s[2], loop; tol = max(tol, 1e-6))
            on += 1
            continue
        end
        _point_in_polygon_xy(s[1], s[2], loop) && return true
    end
    return on == 3
end

"""
Releases of one joist piece after an opening cut.

Both ends on a support keep `end_fixity` (a new end at a framed header is
`:fixed`, continuous into that support). One supported end is a cantilever:
`:fixed` at the support, so the seat takes the moment, and `:pinned` at the
opening. No support returns `nothing` and the piece is omitted.
"""
function _opening_piece_release(verts::Vector{Int}, landings::Set{Int},
                                end_fixity::NTuple{2, Symbol},
                                at_start::Bool, at_end::Bool)
    n_host = count(v -> v in landings, verts)
    n_host == 0 && return nothing
    s_host = verts[1] in landings
    e_host = verts[end] in landings
    if s_host && e_host
        rs = at_start ? end_fixity[1] : :fixed
        re = at_end ? end_fixity[2] : :fixed
        return (rs, re)
    elseif s_host
        return (:fixed, :pinned)
    elseif e_host
        return (:pinned, :fixed)
    else
        return (:pinned, :pinned)
    end
end

"""
Stop each joist chain at the slab openings.

Returns the kept chains and one release pair each. A piece with one support
is a cantilever. A piece with none is omitted, with a warning.
"""
function _clip_chains_at_openings!(skel, chains::Vector{Vector{Int}}, loops, z_m::Float64,
                                  landings::Set{Int}, end_fixity::NTuple{2, Symbol})
    out_chains = Vector{Int}[]
    out_rel = NTuple{2, Symbol}[]
    for chain in chains
        pieces = _opening_pieces(skel, chain, loops, z_m)
        if isempty(pieces)
            @warn "a joist lies in an unframed opening and has no support, so it is omitted" maxlog = 4
            continue
        end
        for (verts, at_start, at_end) in pieces
            length(verts) < 2 && continue
            rel = _opening_piece_release(verts, landings, end_fixity, at_start, at_end)
            if rel === nothing
                @warn "a joist lies in an unframed opening and has no support, so it is omitted" maxlog = 4
                continue
            end
            if !_joist_ends_supported(verts, landings)
                @warn "a joist stops at an unframed opening and is checked as a cantilever" maxlog = 4
            end
            push!(out_chains, verts)
            push!(out_rel, rel)
        end
    end
    return out_chains, out_rel
end

_joist_ends_supported(verts, landings) = (verts[1] in landings) && (verts[end] in landings)

