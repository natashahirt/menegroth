# Framing of slab openings on beam-supported floors.
#
# A trimmer runs parallel to the span, from the first beam or wall on one side
# of the opening to the first beam or wall on the other. A header runs
# perpendicular to the span, from trimmer to trimmer, and picks up the slab
# the opening cuts. The opening record stays, so the face inside that frame
# has no net area and is not a slab.

"""Floor types that frame an opening. Flat plate, flat slab, waffle, and vault do not."""
const _FRAMING_FLOOR_TYPES = (:one_way, :composite_deck, :joist, :two_way)

"""Floor types that keep an opening unframed even when beams are present."""
const _UNFRAMED_FLOOR_TYPES = (:flat_plate, :flat_slab, :waffle, :vault, :grade)

"""
    frame_slab_openings!(skel; floor_type=:auto, plan_axis=(1, 0),
                         tributary_axis=nothing, joists_planned=false) -> skel

Add trimmers and headers for each opening `floor_type` frames. Faces are
rebuilt when any beam is added, and each new face keeps the slab group of the
face it was cut from.

Call this after [`find_faces!`](@ref) and before cells are created. A second
call adds nothing.
"""
function frame_slab_openings!(skel::BuildingSkeleton;
                              floor_type::Symbol=:auto,
                              plan_axis::NTuple{2, <:Real}=(1.0, 0.0),
                              tributary_axis=nothing,
                              joists_planned::Bool=false)
    isempty(skel.openings) && return skel
    isempty(skel.faces) && find_faces!(skel)
    added = false
    for (k, op) in enumerate(skel.openings)
        added |= _frame_one_opening!(skel, k, op; floor_type, plan_axis,
                                     tributary_axis, joists_planned)
    end
    added || return skel
    saved = _face_group_snapshot(skel)
    _reset_detected_faces!(skel)
    rebuild_stories!(skel)
    find_faces!(skel)
    _restore_face_groups!(skel, saved)
    rebuild_geometry_cache!(skel)
    return skel
end

"""
    opening_cantilever_length(struc, slab) -> Union{Length, Nothing}

Longest stretch of slab from a span end to an opening on `slab`, or `nothing`
when no opening leaves such a stretch.

The stretch is a cantilever: it is held at the support and free at the
opening. ACI 318-11 Table 9.5(a) (the cantilever row of
[`min_thickness`](@ref)) uses that length, not the bay. A framed opening
fills its own face, so it is not a cell and does not show up here.
"""
function opening_cantilever_length(struc::BuildingStructure, slab_or_cells)
    skel = struc.skeleton
    indices = slab_or_cells isa AbstractVector ? slab_or_cells : slab_or_cells.cell_indices
    best = 0.0
    found = false
    for ci in indices
        cell = struc.cells[ci]
        ks = face_openings(skel, cell.face_idx)
        isempty(ks) && continue
        axis = _unit2d((Float64(cell.spans.axis[1]), Float64(cell.spans.axis[2])))
        face = _face_loop_m(skel, cell.face_idx)
        ss = [p[1] * axis[1] + p[2] * axis[2] for p in face]
        s0, s1 = extrema(ss)
        for k in ks
            os = [p[1] * axis[1] + p[2] * axis[2] for p in skel.openings[k].loop]
            o0, o1 = extrema(os)
            lo = max(o0, s0)
            hi = min(o1, s1)
            hi > lo + 1e-4 || continue
            for gap in (lo - s0, s1 - hi)
                gap > 1e-3 || continue
                found = true
                best = max(best, gap)
            end
        end
    end
    return found ? best * u"m" : nothing
end

"""The sizer asks for this length. An opening that was framed is not a cell, so it returns `nothing`."""
StructuralSizer._opening_cantilever_span(struc::BuildingStructure, slab) =
    opening_cantilever_length(struc, slab)

"""`true` when this floor puts beams under the slab, so an opening can be framed."""
function _floor_frames_openings(floor_type::Symbol, joists_planned::Bool, has_support::Bool)
    floor_type in _UNFRAMED_FLOOR_TYPES && return false
    floor_type in _FRAMING_FLOOR_TYPES && return true
    joists_planned && return true
    return has_support && floor_type in (:auto, :unknown)
end

"""Frame opening `k`, or warn and leave it. Returns whether any edge was added."""
function _frame_one_opening!(skel, k::Int, op::SlabOpening; floor_type, plan_axis,
                             tributary_axis, joists_planned)
    if op.framing === :none
        @warn "opening $k on story $(op.story) is left unframed"
        return false
    end
    faces = [f for f in eachindex(skel.face_vertex_indices) if k in face_openings(skel, f)]
    if isempty(faces)
        @warn "opening $k on story $(op.story) lies on no slab; it is left unframed"
        return false
    end
    if length(faces) > 1
        @warn "opening $k crosses a beam; it is left unframed. Draw it in one bay, or frame it by hand."
        return false
    end
    face = only(faces)
    has_support = _face_has_line_support(skel, face)
    if !_floor_frames_openings(floor_type, joists_planned, has_support)
        @warn "opening $k on story $(op.story) is left unframed"
        return false
    end
    axis = _opening_span_axis(skel, face, plan_axis, tributary_axis)
    box = _opening_frame_box(op.loop, axis, op.framing)
    if box === nothing
        @warn "opening $k is not a rectangle on the span axis; it is left unframed"
        return false
    end
    u, n, s0, s1, t0, t1, exact = box
    exact || @warn "opening $k is framed by the rectangle around it"
    z = _plan_coord_m(skel.stories[op.story].elevation)
    segs = _support_segments(skel, op.story)
    # Two trimmers, one at each side of the opening, parallel to the span.
    sides = ((t0, s0, s1), (t1, s0, s1))
    landings = NamedTuple[]
    for (t, a, b) in sides
        lo = _seek_support(u, n, t, a, -1, segs)
        hi = _seek_support(u, n, t, b, +1, segs)
        if lo === nothing || hi === nothing
            @warn "a trimmer for opening $k meets no beam; the opening is left unframed"
            return false
        end
        push!(landings, (t = t, lo = lo, hi = hi, a = a, b = b))
    end
    return _commit_opening_frame!(skel, k, op.story, z, u, n, s0, s1, landings, segs)
end

"""
Span direction the trimmers follow. An explicit two-component `tributary_axis`
wins; otherwise the face's own short axis.
"""
function _opening_span_axis(skel, face, plan_axis, tributary_axis)
    dir = _axis_pair(tributary_axis)
    dir !== nothing && return dir
    si = get_cell_spans(skel, face; plan_axis = plan_axis)
    return _unit2d((Float64(si.axis[1]), Float64(si.axis[2])))
end

_axis_pair(::Any) = nothing
_axis_pair(v::NTuple{2, <:Real}) = _unit2d((Float64(v[1]), Float64(v[2])))
function _axis_pair(v::AbstractVector{<:Real})
    length(v) == 2 || return nothing
    return _unit2d((Float64(v[1]), Float64(v[2])))
end

"""
`(u, n, s0, s1, t0, t1, exact)`. `s` is along `u` and `t` along `n`, and the
frame is the rectangle `[s0, s1] × [t0, t1]`. `exact` is false when that
rectangle is larger than the opening. `:auto` returns `nothing` unless the
opening already is that rectangle.
"""
function _opening_frame_box(loop, span_axis, framing::Symbol)
    u = framing === :opening_axes ? _longest_edge_dir(loop) : _unit2d(span_axis)
    n = (-u[2], u[1])
    ss = [p[1] * u[1] + p[2] * u[2] for p in loop]
    tt = [p[1] * n[1] + p[2] * n[2] for p in loop]
    s0, s1 = extrema(ss)
    t0, t1 = extrema(tt)
    (s1 - s0) > 1e-6 && (t1 - t0) > 1e-6 || return nothing
    box = (s1 - s0) * (t1 - t0)
    area = abs(_shoelace_area(loop))
    exact = _on_two_levels(ss) && _on_two_levels(tt) && abs(box - area) <= 1e-4 * max(box, 1.0)
    framing === :auto && !exact && return nothing
    return (u, n, s0, s1, t0, t1, exact)
end

"""Every coordinate sits on one end or the other, so the outline is a rectangle in this frame."""
function _on_two_levels(xs; tol = 1e-5)
    lo, hi = extrema(xs)
    hi - lo > tol || return false
    return all(x -> abs(x - lo) <= tol || abs(x - hi) <= tol, xs)
end

function _longest_edge_dir(loop)
    best, bu = 0.0, (1.0, 0.0)
    n = length(loop)
    for i in 1:n
        a, b = loop[i], loop[mod1(i + 1, n)]
        dx, dy = b[1] - a[1], b[2] - a[2]
        L = hypot(dx, dy)
        L > best || continue
        best, bu = L, (dx / L, dy / L)
    end
    return bu
end

_unit2d(a) = (n = hypot(a[1], a[2]); n < 1e-12 ? (1.0, 0.0) : (a[1] / n, a[2] / n))

"""World point `s` along `u` and `t` along `n`."""
_frame_point(u, n, s, t) = (s * u[1] + t * n[1], s * u[2] + t * n[2])

"""
Vertex at `(xy, z)` in meters. Matches the coordinate type already on the
skeleton, so a metre-valued building does not gain a bare-number point.
"""
function _frame_vertex!(skel, xy, z, level)
    # A trimmer end that misses an existing node by a fraction of a millimetre
    # would be a second vertex, and the new beam would lie on the old one.
    # The face walk then goes out and back on that line.
    story = get(skel.stories, level, nothing)
    if story !== nothing
        for v in story.vertices
            px, py = _frame_xy(skel, v)
            hypot(px - xy[1], py - xy[2]) <= 1e-3 || continue
            c = Meshes.coords(skel.vertices[v])
            vz = c.z isa Unitful.Quantity ? Float64(ustrip(u"m", c.z)) : Float64(c.z)
            abs(vz - z) <= 1e-3 && return v
        end
    end
    if isempty(skel.vertices)
        return add_vertex!(skel, [xy[1], xy[2], z]; group = :beams, level_idx = level)
    end
    sample = Meshes.coords(skel.vertices[1]).x
    if sample isa Unitful.Quantity
        pt = Meshes.Point(xy[1] * u"m", xy[2] * u"m", z * u"m")
        return add_vertex!(skel, pt; group = :beams, level_idx = level)
    end
    return add_vertex!(skel, [xy[1], xy[2], z]; group = :beams, level_idx = level)
end

"""Plan meters of a skeleton vertex."""
function _frame_xy(skel, v::Int)
    c = Meshes.coords(skel.vertices[v])
    return (_plan_coord_m(c.x), _plan_coord_m(c.y))
end

"""Beam and wall segments on story `level`: `(edge, a, b)` in plan meters."""
function _support_segments(skel, level::Int)
    story = skel.stories[level]
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    walls = Set(get(skel.groups_edges, :walls, Int[]))
    out = Tuple{Int, NTuple{2, Float64}, NTuple{2, Float64}}[]
    for e in story.edges
        (e in beams || e in walls) || continue
        v1, v2 = skel.edge_indices[e]
        a, b = _frame_xy(skel, v1), _frame_xy(skel, v2)
        hypot(b[1] - a[1], b[2] - a[2]) < 1e-9 && continue
        push!(out, (e, a, b))
    end
    return out
end

"""The face has a beam or a wall on its boundary."""
function _face_has_line_support(skel, face::Int)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    walls = Set(get(skel.groups_edges, :walls, Int[]))
    return any(e -> e in beams || e in walls, skel.face_edge_indices[face])
end

"""
First beam or wall the trimmer meets, walking from `s_from` in `direction`
(`-1` or `+1`) along the line at across-span coordinate `t`.

Returns `(s, edge, point)` or `nothing`. A beam the station already sits on
returns `s_from`.
"""
function _seek_support(u, n, t, s_from, direction, segs)
    origin = _frame_point(u, n, 0.0, t)
    best = nothing
    for (e, a, b) in segs
        for s in _line_segment_stations(origin, u, a, b, s_from, direction)
            if direction < 0
                s <= s_from + 1e-6 || continue
                best === nothing || s > best[1] || continue
            else
                s >= s_from - 1e-6 || continue
                best === nothing || s < best[1] || continue
            end
            best = (s, e, _frame_point(u, n, s, t))
        end
    end
    return best
end

"""
Stations where the line `origin + s * dir` meets segment `a → b`, in the
search `direction` from `s_from`. A crossing gives one station. A beam that
lies on the line gives the station itself when the beam already covers it,
otherwise the near end. Parallel beams off the line give none.
"""
function _line_segment_stations(origin, dir, a, b, s_from, direction)
    d = (b[1] - a[1], b[2] - a[2])
    den = dir[1] * d[2] - dir[2] * d[1]
    rel = (a[1] - origin[1], a[2] - origin[2])
    if abs(den) < 1e-10
        abs(rel[1] * dir[2] - rel[2] * dir[1]) > 1e-6 && return Float64[]
        s_a = (a[1] - origin[1]) * dir[1] + (a[2] - origin[2]) * dir[2]
        s_b = (b[1] - origin[1]) * dir[1] + (b[2] - origin[2]) * dir[2]
        lo, hi = minmax(s_a, s_b)
        lo - 1e-6 <= s_from <= hi + 1e-6 && return Float64[s_from]
        return Float64[direction < 0 ? hi : lo]
    end
    s = (rel[1] * d[2] - rel[2] * d[1]) / den
    w = (rel[1] * dir[2] - rel[2] * dir[1]) / den
    return -1e-6 <= w <= 1 + 1e-6 ? Float64[s] : Float64[]
end

"""
Add the two trimmers and two headers. A trimmer is one chain from support to
support. An edge that already exists is kept, so a second call adds nothing.
"""
function _commit_opening_frame!(skel, k, level, z, u, n, s0, s1, landings, segs)
    splits = Dict{Int, Vector{Tuple{Float64, Int}}}()
    function vertex_at(xy)
        v = _frame_vertex!(skel, xy, z, level)
        _note_support_split!(splits, skel, segs, xy, v)
        return v
    end
    function landing_vertex(hit)
        _, _, xy = hit
        return vertex_at(xy)
    end
    chains = Vector{Int}[]
    new_edges = 0
    # Trimmers first, so the header ends exist and the support beams are split.
    stations = Tuple{Float64, Int}[]
    for side in landings
        vlo = landing_vertex(side.lo)
        va = vertex_at(_frame_point(u, n, side.a, side.t))
        vb = vertex_at(_frame_point(u, n, side.b, side.t))
        vhi = landing_vertex(side.hi)
        push!(stations, (side.a, va))
        push!(stations, (side.b, vb))
        ids, nnew = _edges_through!(skel, level, [vlo, va, vb, vhi])
        new_edges += nnew
        push!(chains, ids)
    end
    _apply_opening_splits!(skel, splits)
    # Headers: the two stations at each end of the span, one on each trimmer.
    for s in (s0, s1)
        vs = [v for (ss, v) in stations if abs(ss - s) <= 1e-6]
        length(vs) == 2 || continue
        _, nnew = _edges_through!(skel, level, vs)
        new_edges += nnew
    end
    for (i, ids) in enumerate(chains)
        _chain_fresh!(skel, hash((:opening_trimmer, k, i)), ids)
    end
    if new_edges > 0
        @warn "opening $k framed with trimmers and headers" edges = new_edges
    end
    return new_edges > 0
end

"""Record a support split where `xy` lies in the interior of a beam or wall."""
function _note_support_split!(splits, skel, segs, xy, v::Int)
    for (e, a, b) in segs
        param = _segment_param(a, b, xy)
        -1e-6 <= param <= 1 + 1e-6 || continue
        px = a[1] + clamp(param, 0.0, 1.0) * (b[1] - a[1])
        py = a[2] + clamp(param, 0.0, 1.0) * (b[2] - a[2])
        hypot(px - xy[1], py - xy[2]) > 1e-6 && continue
        param <= 1e-6 && continue
        param >= 1 - 1e-6 && continue
        v1, v2 = skel.edge_indices[e]
        (v == v1 || v == v2) && continue
        push!(get!(Vector{Tuple{Float64, Int}}, splits, e), (param, v))
    end
    return nothing
end

"""Parameter of `p` along `a → b`, unclamped."""
function _segment_param(a, b, p)
    dx, dy = b[1] - a[1], b[2] - a[2]
    L2 = dx * dx + dy * dy
    L2 < 1e-16 && return 0.0
    return ((p[1] - a[1]) * dx + (p[2] - a[2]) * dy) / L2
end

"""
Edges joining `verts` in order, skipping a repeated vertex. An edge already
connecting the pair is reused. Returns the edge ids and how many were new.
"""
function _edges_through!(skel, level, verts)
    ids = Int[]
    nnew = 0
    for i in 1:(length(verts) - 1)
        a, b = verts[i], verts[i + 1]
        a == b && continue
        pa, pb = _frame_xy(skel, a), _frame_xy(skel, b)
        hypot(pa[1] - pb[1], pa[2] - pb[2]) <= 1e-3 && continue
        existing = find_edge(skel, a, b)
        if existing === nothing
            push!(ids, add_element!(skel, a, b; group = :beams, level_idx = level))
            nnew += 1
        else
            push!(ids, existing)
        end
    end
    return ids, nnew
end

"""Split each support edge at the trimmer landings and keep it one member."""
function _apply_opening_splits!(skel, splits)
    for (e, hits) in splits
        mids = Int[]
        seen = Set{Int}()
        for (_, v) in sort!(hits; by = first)
            v in seen && continue
            push!(seen, v)
            v1, v2 = skel.edge_indices[e]
            (v == v1 || v == v2) && continue
            push!(mids, v)
        end
        isempty(mids) && continue
        _split_support_edge!(skel, e, mids)
    end
    return nothing
end

"""
Replace support edge `E` with the chain `v1, mids..., v2`. `E` becomes the
first piece. The pieces stay one member.
"""
function _split_support_edge!(skel, E::Int, mids::Vector{Int})
    v1, v2 = skel.edge_indices[E]
    chain = Int[v1]
    for v in mids
        _vertices_coincide(skel, chain[end], v) && continue
        push!(chain, v)
    end
    _vertices_coincide(skel, chain[end], v2) || push!(chain, v2)
    length(chain) >= 3 || return nothing
    group = _edge_group(skel, E)
    level = _edge_story(skel, E)
    _rewire_edge!(skel, E, chain[1], chain[2])
    subs = Int[E]
    for k in 2:(length(chain) - 1)
        push!(subs, add_element!(skel, chain[k], chain[k + 1]; group = group, level_idx = level))
    end
    _replace_edge_in_chains!(skel, E, subs)
    return subs
end

"""Story whose edge list contains `E`, or `-1`."""
function _edge_story(skel, E::Int)
    for (level, story) in skel.stories
        E in story.edges && return level
    end
    return -1
end

"""Put `subs` where `E` sits in any member chain. An unchained split becomes one."""
function _replace_edge_in_chains!(skel, E::Int, subs::Vector{Int})
    found = false
    for chain in values(skel.edge_chains)
        i = findfirst(==(E), chain)
        i === nothing && continue
        splice!(chain, i, subs)
        found = true
    end
    found && return nothing
    length(subs) > 1 || return nothing
    skel.edge_chains[hash((:opening_split, E))] = subs
    return nothing
end

"""Chain `ids` into one member when none of them already belongs to a chain."""
function _chain_fresh!(skel, key::UInt64, ids::Vector{Int})
    length(ids) > 1 || return nothing
    any(e -> _edge_in_chain(skel, e), ids) && return nothing
    skel.edge_chains[key] = ids
    return nothing
end

function _edge_in_chain(skel, E::Int)
    for chain in values(skel.edge_chains)
        E in chain && return true
    end
    return false
end

"""Mean elevation of a face's vertices, in meters."""
function _face_z_m(skel, vis)
    z = 0.0
    for v in vis
        z += Float64(ustrip(u"m", Meshes.coords(skel.vertices[v]).z))
    end
    return z / length(vis)
end

"""`(loop, groups, elevation)` for every face, so a rebuilt face can inherit its slab group."""
function _face_group_snapshot(skel)
    snaps = Tuple{Vector{NTuple{2, Float64}}, Vector{Symbol}, Float64}[]
    for (i, vis) in enumerate(skel.face_vertex_indices)
        loop = [_frame_xy(skel, v) for v in vis]
        groups = Symbol[g for (g, ids) in skel.groups_faces if i in ids]
        push!(snaps, (loop, groups, _face_z_m(skel, vis)))
    end
    return snaps
end

"""Drop detected faces. Vertices, edges, and openings stay."""
function _reset_detected_faces!(skel)
    empty!(skel.faces)
    empty!(skel.face_vertex_indices)
    empty!(skel.face_edge_indices)
    empty!(skel.face_holes)
    empty!(skel.face_hole_vertices)
    for ids in values(skel.groups_faces)
        empty!(ids)
    end
    for story in values(skel.stories)
        empty!(story.faces)
    end
    skel.lookup === nothing || empty!(skel.lookup.face_index)
    return nothing
end

"""
Give each new face the slab groups of the smallest old face that contains it.

The match stays on the same story. Grade and floor share a plan, so a
plan-only test would hand the upper floor the grade group.
"""
function _restore_face_groups!(skel, snaps)
    for (i, vis) in enumerate(skel.face_vertex_indices)
        p = _interior_point([_frame_xy(skel, v) for v in vis])
        z = _face_z_m(skel, vis)
        match = nothing
        match_area = Inf
        for (old, groups, z_old) in snaps
            abs(z - z_old) > 1e-2 && continue
            _frame_contains(p, old) || continue
            a = abs(_shoelace_area(old))
            a < match_area || continue
            match, match_area = groups, a
        end
        match === nothing && continue
        for g in match
            g === :slabs && continue
            haskey(skel.groups_faces, g) || (skel.groups_faces[g] = Int[])
            i in skel.groups_faces[g] || push!(skel.groups_faces[g], i)
        end
    end
    return nothing
end

"""A point inside `loop`: its centroid when that falls inside, otherwise a step in from the first edge."""
function _interior_point(loop)
    c = _frame_centroid(loop)
    _frame_contains(c, loop) && return c
    a, b = loop[1], loop[2]
    dx, dy = b[1] - a[1], b[2] - a[2]
    L = hypot(dx, dy)
    L < 1e-12 && return a
    mid = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
    return (mid[1] - 1e-3 * dy / L, mid[2] + 1e-3 * dx / L)
end

function _frame_centroid(loop)
    a = _shoelace_area(loop)
    abs(a) < 1e-12 && return loop[1]
    cx = cy = 0.0
    n = length(loop)
    for i in 1:n
        p, q = loop[i], loop[mod1(i + 1, n)]
        cr = p[1] * q[2] - q[1] * p[2]
        cx += (p[1] + q[1]) * cr
        cy += (p[2] + q[2]) * cr
    end
    return (cx / (6a), cy / (6a))
end

"""`p` is inside or on the boundary of a simple polygon."""
function _frame_contains(p, loop)
    x, y = p
    n = length(loop)
    n < 3 && return false
    inside = false
    j = n
    for i in 1:n
        xi, yi = loop[i]
        xj, yj = loop[j]
        if _frame_on_segment(x, y, xi, yi, xj, yj)
            return true
        end
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

function _frame_on_segment(px, py, x1, y1, x2, y2; tol = 1e-8)
    dx, dy = x2 - x1, y2 - y1
    L2 = dx * dx + dy * dy
    L2 <= tol * tol && return hypot(px - x1, py - y1) <= tol
    t = ((px - x1) * dx + (py - y1) * dy) / L2
    (-tol <= t <= 1 + tol) || return false
    qx = x1 + clamp(t, 0.0, 1.0) * dx
    qy = y1 + clamp(t, 0.0, 1.0) * dy
    return hypot(px - qx, py - qy) <= tol
end
