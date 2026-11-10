# =============================================================================
# Rib grillage
# =============================================================================
#
# A ribbed floor is the slab the building already designs, plus a frame of
# ribs. This solve is that frame. It is not a shell mesh and not a new floor
# type. The rib lines are the same grid [`_isoparametric_rib_lines`](@ref)
# materializes, including the panel edges.
#
# ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101): a two-way slab system may
# be analyzed by any procedure satisfying equilibrium and compatibility.
# Rectangular bays bring their load to the ribs by the isotropic straight
# skeleton, in closed form ([`rectangle_rib_tributaries`](@ref)). One
# factorization carries the factored panel pressure. Corners are pinned in
# translation and free to rotate.

"""
    analyze_rectangle_grillage(Lx, Ly, nξ, nη, pressure) -> NamedTuple

Solve one rectangular rib grid.

`Lx` and `Ly` are metres. `nξ` and `nη` are the bay counts. `pressure` is
the factored panel pressure in pascals, acting downward. Ribs are continuous
through every crossing. The four corners are pinned in translation.

`solid_head`, `depth`, and `concrete` give each piece inside a corner head
the gross solid rectangle. Pieces outside the head keep a uniform stand-in
section. The corner reactions of a uniform pressure do not depend on that
choice.

Returns the model, the upward reaction at each corner in newtons, and the
rib network the pieces were cut from.
"""
function analyze_rectangle_grillage(Lx::Real, Ly::Real, nξ::Int, nη::Int, pressure::Real;
                                    solid_head::Real = 0.0,
                                    depth::Union{Nothing, Unitful.Length} = nothing,
                                    concrete::Union{Nothing, StructuralSizer.Concrete} = nothing)
    (Lx > 0 && Ly > 0) || throw(ArgumentError(
        "a rib panel needs positive sides, got $Lx by $Ly"))
    (nξ >= 1 && nη >= 1) || throw(ArgumentError(
        "a rib grid needs at least one bay each way, got $nξ by $nη"))
    isfinite(pressure) || throw(ArgumentError("panel pressure must be finite, got $pressure"))
    if solid_head > 0 && (depth === nothing || concrete === nothing)
        throw(ArgumentError(
            "a solid head needs its full depth and its concrete"))
    end
    panel = StructuralSizer.IsoParametricPanel(((0.0, 0.0), (Float64(Lx), 0.0),
                                                 (Float64(Lx), Float64(Ly)), (0.0, Float64(Ly))))
    grid = StructuralSizer.WaffleRibGrid(panel, nξ, nη; solid_head = Float64(solid_head))
    net = StructuralSizer.rib_network(grid)
    head_widths = solid_head > 0 ? StructuralSizer.solid_piece_widths(grid) : Float64[]
    profiles = StructuralSizer.rectangle_rib_tributaries(Lx, Ly, nξ, nη)
    length(profiles) == length(net.pieces) || throw(ArgumentError(
        "the rib grid and its tributary profiles do not match"))
    nodes = Asap.Node[]
    sizehint!(nodes, length(net.nodes))
    for (x, y) in net.nodes
        corner = (x <= 1e-9 || x >= Lx - 1e-9) && (y <= 1e-9 || y >= Ly - 1e-9)
        dof = corner ? [false, false, false, true, true, true] : fill(true, 6)
        push!(nodes, Asap.Node([x * u"m", y * u"m", 0.0u"m"], dof))
    end
    rib_sec = Asap.Section(0.05u"m^2", 30.0e9u"Pa", 13.0e9u"Pa",
                           1.0e-3u"m^4", 1.0e-3u"m^4", 1.0e-4u"m^4", 2400.0u"kg/m^3")
    elements = Asap.Element[]
    loads = Asap.AbstractLoad[]
    for (k, piece) in enumerate(net.pieces)
        sec = rib_sec
        if solid_head > 0 && head_widths[k] > 0
            # Stiffness only. This model has no member self-weight. The building
            # frame weighs the projection below the topping.
            sec = StructuralSizer.solid_head_section(head_widths[k] * u"m", depth, concrete)
        end
        el = Asap.Element(nodes[piece.a], nodes[piece.b], sec, Symbol("rib_", piece.rib))
        push!(elements, el)
        profile = profiles[k]
        widths = [w * u"m" for w in profile.widths]
        push!(loads, Asap.TributaryLoad(el, profile.positions, widths,
                                         pressure * u"Pa", (0.0, 0.0, -1.0)))
    end
    model = Asap.Model(nodes, elements, loads)
    Asap.solve!(model)
    corners = Float64[]
    for node in nodes
        node.dof[3] && continue
        push!(corners, ustrip(u"N", node.reaction[3]))
    end
    return (model = model, corner_reactions = corners, network = net)
end

"""
    analyze_simply_supported_rib(stations, widths, pressure) -> NamedTuple

One straight rib, pinned vertically at its ends, loaded by a width profile.

`stations` are metres along the rib and `widths` are metres. `pressure` is
pascals, downward. The rib is two equal elements, so the midspan moment is
an end force of either element. Vertical shear is local DOF 3, and vertical
bending is local DOF 5 and 11.

Returns the upward end reactions in newtons, the midspan moment in
newton-metres, and the end shear in newtons.
"""
function analyze_simply_supported_rib(stations, widths, pressure::Real)
    length(stations) == length(widths) || throw(ArgumentError(
        "a rib profile needs one width per station"))
    length(stations) >= 2 || throw(ArgumentError("a rib profile needs two stations"))
    L = Float64(stations[end] - stations[1])
    L > 0 || throw(ArgumentError("rib length must be positive, got $L"))
    s0 = Float64(stations[1])
    mid = s0 + L / 2
    sec = Asap.Section(0.05u"m^2", 30.0e9u"Pa", 13.0e9u"Pa",
                       1.0e-3u"m^4", 1.0e-3u"m^4", 1.0e-4u"m^4", 2400.0u"kg/m^3")
    # Free θy. The start is fixed in x; the far end is free in x.
    n0 = Asap.Node([s0 * u"m", 0.0u"m", 0.0u"m"], [false, false, false, false, true, false])
    nm = Asap.Node([mid * u"m", 0.0u"m", 0.0u"m"], [false, false, true, false, true, false])
    n1 = Asap.Node([(s0 + L) * u"m", 0.0u"m", 0.0u"m"], [true, false, false, false, true, false])
    e0 = Asap.Element(n0, nm, sec, :rib_a)
    e1 = Asap.Element(nm, n1, sec, :rib_b)
    # A new element rolls π/2, which puts global Z in local y. This check
    # wants local z vertical, so the roll is zero.
    e0.Ψ = 0.0
    e1.Ψ = 0.0
    function _half(el, a, b)
        pos = Float64[]
        w = Float64[]
        for (s, wi) in zip(stations, widths)
            s < a - 1e-9 && continue
            s > b + 1e-9 && continue
            push!(pos, clamp((Float64(s) - a) / (b - a), 0.0, 1.0))
            push!(w, Float64(wi))
        end
        (isempty(pos) || pos[1] > 1e-9) && (pushfirst!(pos, 0.0); pushfirst!(w, _profile_at(stations, widths, a)))
        pos[end] < 1 - 1e-9 && (push!(pos, 1.0); push!(w, _profile_at(stations, widths, b)))
        return Asap.TributaryLoad(el, pos, [wi * u"m" for wi in w], pressure * u"Pa", (0.0, 0.0, -1.0))
    end
    model = Asap.Model([n0, nm, n1], [e0, e1], Asap.AbstractLoad[_half(e0, s0, mid), _half(e1, mid, s0 + L)])
    Asap.solve!(model)
    # solve! replaces the elements with the realized ones. The near element
    # starts at the first support; its far end is midspan.
    near = argmin(el -> ustrip(u"m", el.nodeStart.position[1]), model.frame_elements)
    return (
        model = model,
        reaction_start = ustrip(u"N", n0.reaction[3]),
        reaction_end = ustrip(u"N", n1.reaction[3]),
        midspan_moment = abs(near.forces[11]),
        end_shear = abs(near.forces[3]),
    )
end

"""
Downward sag of `nodes`, ordered along a rib, relative to the chord
through the end nodes. Positive is below that chord.
"""
function downward_sag(nodes)
    length(nodes) >= 2 || throw(ArgumentError("a rib sag needs the nodes along the rib"))
    function plan(node)
        (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))
    end
    p0, p1 = plan(nodes[1]), plan(nodes[end])
    L2 = (p1[1] - p0[1])^2 + (p1[2] - p0[2])^2
    L2 > 0 || throw(ArgumentError("a rib sag needs two distinct ends"))
    uz0 = ustrip(u"m", nodes[1].displacement[3])
    uz1 = ustrip(u"m", nodes[end].displacement[3])
    best = 0.0
    for node in nodes
        p = plan(node)
        t = ((p[1] - p0[1]) * (p1[1] - p0[1]) + (p[2] - p0[2]) * (p1[2] - p0[2])) / L2
        uz = ustrip(u"m", node.displacement[3])
        best = max(best, (1 - t) * uz0 + t * uz1 - uz)
    end
    return best * u"m"
end

"""
    grillage_rib_sags(solved) -> Vector{NamedTuple}

Downward sag of each rib in a solved [`analyze_rectangle_grillage`](@ref),
relative to its own ends. The story shell is not used.
"""
function grillage_rib_sags(solved)
    net = solved.network
    nodes = solved.model.nodes
    length(nodes) >= length(net.nodes) || throw(ArgumentError(
        "the solved frame is missing rib nodes"))
    ribs = unique(p.rib for p in net.pieces)
    out = NamedTuple[]
    for rib in ribs
        chain = StructuralSizer.rib_chain(net, rib)
        isempty(chain) && throw(ArgumentError("rib $rib has no nodes"))
        push!(out, (rib = rib, sag = downward_sag([nodes[i] for i in chain])))
    end
    return out
end

"""Piecewise-linear width at station `s`."""
function _profile_at(stations, widths, s)
    s <= stations[1] && return Float64(widths[1])
    s >= stations[end] && return Float64(widths[end])
    i = searchsortedlast(collect(Float64, stations), Float64(s))
    i = clamp(i, 1, length(stations) - 1)
    ds = Float64(stations[i + 1] - stations[i])
    ds == 0 && return Float64(widths[i + 1])
    t = (Float64(s) - Float64(stations[i])) / ds
    return Float64(widths[i]) + t * (Float64(widths[i + 1]) - Float64(widths[i]))
end

# -----------------------------------------------------------------------------
# The building frame is the grillage
# -----------------------------------------------------------------------------
#
# A framing level with `analysis = :grillage` owns its panel. The ribs are the
# frame members already in the building, and each one carries the isotropic
# skeleton of the rectangular bays ([`rectangle_rib_tributaries`](@ref)). The
# story shell does not also take those ribs, and the uniform joist strip is
# not posted on top of the skeleton.
#
# ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101).

"""The one `:grillage` level on `slab`, or `nothing`. Two is an error."""
function _grillage_level(slab)
    hits = FramingLevel[]
    for fl in slab.framing_levels
        rib_analysis(fl) == :grillage && push!(hits, fl)
    end
    length(hits) <= 1 || throw(ArgumentError(
        "slab $(hits[1].slab_idx) has $(length(hits)) grillage levels. One level owns the panel."))
    return isempty(hits) ? nothing : only(hits)
end

"""Cell indices whose panel a grillage owns."""
function _grillage_cells(struc)
    out = Set{Int}()
    for slab in struc.slabs
        _grillage_level(slab) === nothing && continue
        for ci in slab.cell_indices
            push!(out, ci)
        end
    end
    return out
end

"""
Stories whose every slab is a grillage. A story that mixes a grillage floor
with another floor throws: one story has one panel analysis.
"""
function exclusive_grillage_stories(struc)
    stories = Set{Int}()
    owners = Dict{Int, Bool}()
    level_of = Dict(f => lvl for (lvl, story) in struc.skeleton.stories for f in story.faces)
    for slab in struc.slabs
        grill = _grillage_level(slab) !== nothing
        for ci in slab.cell_indices
            lvl = get(level_of, struc.cells[ci].face_idx, nothing)
            lvl === nothing && continue
            seen = get(owners, lvl, nothing)
            if seen !== nothing && seen != grill
                throw(ArgumentError(
                    "story $lvl mixes a grillage floor with another floor. " *
                    "One story has one panel analysis."))
            end
            owners[lvl] = grill
            grill && push!(stories, lvl)
        end
    end
    return sort!(collect(stories))
end

"""Local frame of a rectangular quad. Corners run around the panel."""
function _rectangular_frame(corners)
    length(corners) == 4 || throw(ArgumentError(
        "a grillage panel is a quadrilateral, and this one has $(length(corners)) corners"))
    StructuralSizer.is_rectangular_panel(corners) || throw(ArgumentError(
        "a grillage tributary is the rectangular skeleton. This panel is not a rectangle."))
    o = corners[1]
    ex = (corners[2][1] - o[1], corners[2][2] - o[2])
    ey = (corners[4][1] - o[1], corners[4][2] - o[2])
    Lx = hypot(ex[1], ex[2])
    Ly = hypot(ey[1], ey[2])
    (Lx > 1e-9 && Ly > 1e-9) || throw(ArgumentError("a rib panel has a zero side"))
    return (origin = o, ex = (ex[1] / Lx, ex[2] / Lx), ey = (ey[1] / Ly, ey[2] / Ly),
            Lx = Lx, Ly = Ly)
end

_to_global(frame, x, y) = (
    frame.origin[1] + x * frame.ex[1] + y * frame.ey[1],
    frame.origin[2] + x * frame.ex[2] + y * frame.ey[2],
)

"""
    grillage_piece_profiles(corners, nξ, nη)

One skeleton profile per rib piece, in the same order as [`rib_network`](@ref).

`corners` is the quad in order. `a` and `b` are the piece ends in that same
coordinate system. `positions` and `widths` are the piece's own profile.
"""
function grillage_piece_profiles(corners, nξ::Int, nη::Int)
    if StructuralSizer.is_rectangular_panel(corners)
        return _rectangle_piece_profiles(corners, nξ, nη)
    end
    length(corners) == 4 || throw(ArgumentError(
        "a grillage panel is a quadrilateral, and this one has $(length(corners)) corners"))
    c = ntuple(i -> (Float64(corners[i][1]), Float64(corners[i][2])), 4)
    panel = StructuralSizer.IsoParametricPanel(c)
    grid = StructuralSizer.WaffleRibGrid(panel, nξ, nη)
    net = StructuralSizer.rib_network(grid)
    profiles = StructuralSizer._isotropic_rib_tributaries(c, nξ, nη)
    length(profiles) == length(net.pieces) || throw(ArgumentError(
        "the rib grid and its tributary profiles do not match"))
    out = NamedTuple[]
    for (piece, profile) in zip(net.pieces, profiles)
        push!(out, (
            a = net.nodes[piece.a],
            b = net.nodes[piece.b],
            positions = profile.positions,
            widths = profile.widths,
        ))
    end
    return out
end

"""Closed-form skeleton of a rectangle, mapped back onto the given corners."""
function _rectangle_piece_profiles(corners, nξ::Int, nη::Int)
    frame = _rectangular_frame(corners)
    panel = StructuralSizer.IsoParametricPanel((
        (0.0, 0.0), (frame.Lx, 0.0), (frame.Lx, frame.Ly), (0.0, frame.Ly)))
    grid = StructuralSizer.WaffleRibGrid(panel, nξ, nη)
    net = StructuralSizer.rib_network(grid)
    profiles = StructuralSizer.rectangle_rib_tributaries(frame.Lx, frame.Ly, nξ, nη)
    length(profiles) == length(net.pieces) || throw(ArgumentError(
        "the rib grid and its tributary profiles do not match"))
    out = NamedTuple[]
    for (piece, profile) in zip(net.pieces, profiles)
        pa = net.nodes[piece.a]
        pb = net.nodes[piece.b]
        push!(out, (
            a = _to_global(frame, pa[1], pa[2]),
            b = _to_global(frame, pb[1], pb[2]),
            positions = profile.positions,
            widths = profile.widths,
        ))
    end
    return out
end

"""Parameter of `p` on segment `a`→`b`, or `nothing` when `p` is off the segment."""
function _param_on_segment(p, a, b; tol::Float64 = 1e-3)
    ab = (b[1] - a[1], b[2] - a[2])
    L2 = ab[1]^2 + ab[2]^2
    L2 <= tol * tol && return nothing
    t = ((p[1] - a[1]) * ab[1] + (p[2] - a[2]) * ab[2]) / L2
    t < -tol / sqrt(L2) && return nothing
    t > 1 + tol / sqrt(L2) && return nothing
    foot = (a[1] + t * ab[1], a[2] + t * ab[2])
    hypot(foot[1] - p[1], foot[2] - p[2]) > tol && return nothing
    return clamp(t, 0.0, 1.0)
end

"""
Shortest skeleton edge at elevation `z` (metres) that contains both ends of the
piece. Returns `(edge, t_a, t_b)` with parameters in the edge's canonical
direction. Edges on other levels are skipped, so stacked identical floors do
not share ribs.
"""
function _edge_covering_piece(skel, a, b, z::Float64; tol::Float64 = 1e-3)
    best = nothing
    bestL = Inf
    for (e, vs) in enumerate(skel.edge_indices)
        abs(_vertex_z_m(skel, vs[1]) - z) <= tol || continue
        abs(_vertex_z_m(skel, vs[2]) - z) <= tol || continue
        p1 = _vertex_xy_m(skel, vs[1])
        p2 = _vertex_xy_m(skel, vs[2])
        ta = _param_on_segment(a, p1, p2; tol = tol)
        tb = _param_on_segment(b, p1, p2; tol = tol)
        (ta === nothing || tb === nothing) && continue
        L = hypot(p2[1] - p1[1], p2[2] - p1[2])
        if L < bestL
            best = (e, ta, tb)
            bestL = L
        end
    end
    return best
end

"""Piece profile placed on the canonical edge, zero outside the piece."""
function _profile_on_edge(ta, tb, positions, widths)
    s0, s1 = ta, tb
    pos, w = positions, widths
    if tb < ta
        s0, s1 = tb, ta
        pos = reverse(1.0 .- positions)
        w = reverse(widths)
    end
    out_p = Float64[]
    out_w = Float64[]
    if s0 > 1e-9
        push!(out_p, 0.0)
        push!(out_w, 0.0)
    end
    for (p, wi) in zip(pos, w)
        push!(out_p, s0 + p * (s1 - s0))
        push!(out_w, wi)
    end
    if s1 < 1.0 - 1e-9
        push!(out_p, 1.0)
        push!(out_w, 0.0)
    end
    out_p[1] = 0.0
    out_p[end] = 1.0
    for i in 2:length(out_p)
        out_p[i] < out_p[i - 1] && (out_p[i] = out_p[i - 1])
    end
    return (out_p, out_w)
end

"""Elevation (metres) of the slab's cells; throws when they are not level."""
function _slab_face_z_m(struc, slab; tol::Float64 = 1e-3)
    skel = struc.skeleton
    zs = [_vertex_z_m(skel, v) for ci in slab.cell_indices
          for v in skel.face_vertex_indices[struc.cells[ci].face_idx]]
    isempty(zs) && throw(ArgumentError("the slab has no cells, so its elevation is unknown"))
    lo, hi = extrema(zs)
    hi - lo <= tol || throw(ArgumentError(
        "a grillage slab must be level; its cells span z = $(lo) to $(hi) m"))
    return (lo + hi) / 2
end

"""
    grillage_edge_profiles(struc, slab, level) -> Dict{Int, (positions, widths)}

Skeleton width on each skeleton edge the ribs occupy, in the edge's canonical
direction. Widths are metres. The areas sum to the panel.
"""
function grillage_edge_profiles(struc, slab, fl::FramingLevel)
    fl.pattern isa IsoparametricPattern || throw(ArgumentError(
        "rib analysis :grillage needs an IsoparametricPattern, " *
        "and this level has a $(typeof(fl.pattern))"))
    poly = _slab_interior_polygon_m(struc, slab)
    poly === nothing && throw(ArgumentError(
        "a grillage needs the slab boundary, and this slab has none"))
    corners = _panel_corners(poly)
    pieces = grillage_piece_profiles(corners, fl.pattern.n_xi, fl.pattern.n_eta)
    skel = struc.skeleton
    z = _slab_face_z_m(struc, slab)
    ProfT = Tuple{Vector{Float64}, Vector{Float64}}
    by_edge = Dict{Int, Vector{ProfT}}()
    for piece in pieces
        hit = _edge_covering_piece(skel, piece.a, piece.b, z)
        hit === nothing && throw(ArgumentError(
            "grillage rib from $(piece.a) to $(piece.b) does not lie on a frame " *
            "member at the slab's elevation z = $(z) m"))
        e, ta, tb = hit
        push!(get!(Vector{ProfT}, by_edge, e),
              _profile_on_edge(ta, tb, piece.positions, piece.widths))
    end
    merged = Dict{Int, ProfT}()
    area = 0.0
    for (e, profs) in by_edge
        pos, w = _merge_edge_profiles(profs)
        merged[e] = (pos, w)
        vs = skel.edge_indices[e]
        p1 = _vertex_xy_m(skel, vs[1])
        p2 = _vertex_xy_m(skel, vs[2])
        L = hypot(p2[1] - p1[1], p2[2] - p1[2])
        area += _profile_integral(pos, w) * L
    end
    panel = StructuralSizer.polygon_area_m(corners)
    abs(area - panel) <= 1e-6 * max(panel, 1.0) || throw(ArgumentError(
        "grillage ribs carry $(area) m² and the panel is $(panel) m²"))
    return merged
end

"""Post the skeleton on the frame elements and return the cell indices owned."""
function _emit_grillage_loads!(loads::Vector{Asap.AbstractLoad},
                               dest::Vector{Asap.TributaryLoad},
                               frame_elements::Vector{<:Asap.Element},
                               struc, slab, fl::FramingLevel,
                               pressure::Unitful.Quantity)
    profiles = grillage_edge_profiles(struc, slab, fl)
    dir = (0.0, 0.0, -1.0)
    for (e, (pos, widths_m)) in profiles
        (1 <= e <= length(frame_elements)) || throw(ArgumentError(
            "grillage rib edge $e has no frame element"))
        widths = [w * u"m" for w in widths_m]
        tl = Asap.TributaryLoad(frame_elements[e], pos, widths, pressure, dir)
        push!(loads, tl)
        push!(dest, tl)
    end
    return dest
end

"""
Put each grillage joist's skeleton back after the cascade clears level ≥ 1.
Boundary ribs stay on the level-0 beams, where the cell merge left them.
The joist area is not handed to those beams: they already carry their own share.
"""
function _restore_grillage_joist_profiles!(struc::BuildingStructure{T}, fl::FramingLevel) where {T}
    slab = nothing
    for s in struc.slabs
        any(level -> level === fl, s.framing_levels) || continue
        slab = s
        break
    end
    slab === nothing && throw(ArgumentError("a grillage level is not attached to a slab"))
    profiles = grillage_edge_profiles(struc, slab, fl)
    for mi in level_member_indices(struc, fl)
        _assign_one_grillage_beam!(struc, struc.beams[mi], profiles, T)
    end
    return struc
end

function _assign_one_grillage_beam!(struc::BuildingStructure{T}, beam, profiles, ::Type{T}) where {T}
    skel = struc.skeleton
    segs = segment_indices(beam)
    edges = [struc.segments[si].edge_idx for si in segs]
    verts = _ordered_chain_vertices(skel, edges)
    lens = Float64[]
    for si in segs
        L = struc.segments[si].L
        push!(lens, L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L))
    end
    total = sum(lens)
    total > 0 || return
    positions = Float64[]
    widths_m = Float64[]
    offset = 0.0
    for (k, e) in enumerate(edges)
        haskey(profiles, e) || throw(ArgumentError(
            "a grillage joist edge is missing its skeleton profile"))
        pos, w = profiles[e]
        a, _ = skel.edge_indices[e]
        if verts[k] != a
            pos = reverse(1.0 .- pos)
            w = reverse(w)
        end
        Lk = lens[k]
        for j in eachindex(pos)
            push!(positions, (offset + pos[j] * Lk) / total)
            push!(widths_m, w[j])
        end
        offset += Lk
    end
    positions[1] = 0.0
    positions[end] = 1.0
    for i in 2:length(positions)
        positions[i] < positions[i - 1] && (positions[i] = positions[i - 1])
    end
    widths_T = T[_meters_to_T(T, w) for w in widths_m]
    beam.tributary_profile = TributaryProfile{T}(positions, widths_T, nothing)
    return beam
end
