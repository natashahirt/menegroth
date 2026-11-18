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
# frame members already in the building, noded at every crossing. Each bay
# they enclose with the slab boundary ([`grillage_bays`](@ref)) puts its own
# isotropic skeleton on the members around it, so the slab can be any polygon
# with holes and the ribs any layout. The story shell does not also take those
# ribs, and the uniform joist strip is not posted on top of the skeleton.
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
    grillage_bays(struc, slab, level) -> (arrangement, edges)

Bays of a grillage level: the faces enclosed by its members, the slab
boundary, the girders between the slab's own cells, and the beam rings around
its holes. `edges[k]` is the skeleton edge behind arrangement edge `k`, in the
same direction. The face inside a ring is the void and is not a bay.

Two skeleton vertices within `tol` metres are one node. Throws when two
members join the same two points, or when a member ends inside a bay.
"""
function grillage_bays(struc, slab, fl::FramingLevel; tol::Float64 = 1e-6)
    skel = struc.skeleton
    z = _slab_face_z_m(struc, slab)
    cand = vcat(_slab_boundary_sub_edges(struc, slab), _slab_interior_sub_edges(struc, slab),
                _slab_hole_edges(struc, slab))
    for mi in level_member_indices(struc, fl), si in segment_indices(struc.beams[mi])
        push!(cand, struc.segments[si].edge_idx)
    end
    unique!(sort!(cand))
    nodes = NTuple{2, Float64}[]
    function node_at(p)
        for (k, q) in enumerate(nodes)
            hypot(q[1] - p[1], q[2] - p[2]) <= tol && return k
        end
        push!(nodes, p)
        return length(nodes)
    end
    E = NTuple{2, Int}[]
    owners = Int[]
    seen = Dict{NTuple{2, Int}, Int}()
    for e in cand
        v1, v2 = skel.edge_indices[e]
        (abs(_vertex_z_m(skel, v1) - z) <= 1e-3 && abs(_vertex_z_m(skel, v2) - z) <= 1e-3) || continue
        a = node_at(_vertex_xy_m(skel, v1))
        b = node_at(_vertex_xy_m(skel, v2))
        a == b && continue
        key = (min(a, b), max(a, b))
        if haskey(seen, key)
            throw(ArgumentError(
                "skeleton edges $(seen[key]) and $e both join $(nodes[a]) and $(nodes[b]) m. " *
                "A grillage bay sends its load to one member per side."))
        end
        seen[key] = e
        push!(E, (a, b))
        push!(owners, e)
    end
    # A rib end that misses the rib it was drawn to meet, by a millimetre,
    # is a spur. The bay walk would go out and back on that one edge.
    nodes, E, src = StructuralSizer.stitch_nodes_onto_edges(nodes, E; tol = 1e-3)
    owners = [owners[k] for k in src]
    arr = StructuralSizer.planar_bays(nodes, E)
    return (StructuralSizer.without_hole_bays(arr, _slab_hole_loops_m(struc, slab)), owners)
end

"""
    slab_column_heads(struc, slab, level) -> Vector{ColumnSolidHead}

The solid head each column of this slab seeds on the grillage, before any
growth. A column on a rib node takes every bay at that node, so a corner is
one bay, a mid-edge column is the bays along that edge, and an interior
column is the bays around the crossing. A column on another story, or off
this slab, is not seeded.

Growth is [`resolve_arrangement_heads`](@ref): the bays are cast solid,
the frame is solved, and a failing check grows one bay. This function does
not run that check. A second call returns the same heads.
"""
function slab_column_heads(struc::BuildingStructure, slab::Slab, level::FramingLevel)
    arr, _ = grillage_bays(struc, slab, level)
    z = _slab_face_z_m(struc, slab)
    poly = _slab_interior_polygon_m(struc, slab)
    seen = Set{NTuple{2, Int}}()
    heads = StructuralSizer.ColumnSolidHead[]
    for col in struc.columns
        xy = _column_on_slab(struc, col, z)
        xy === nothing && continue
        _on_this_slab_plan(xy, poly) || continue
        key = (round(Int, xy[1] * 1e6), round(Int, xy[2] * 1e6))
        key in seen && continue
        push!(seen, key)
        push!(heads, StructuralSizer.seed_column_head(arr, xy))
    end
    sort!(heads; by = h -> (h.column[1], h.column[2]))
    return heads
end

"""Plan point where `column` meets this slab, or `nothing`."""
function _column_on_slab(struc::BuildingStructure, column, z::Float64)
    skel = struc.skeleton
    for si in segment_indices(column)
        si <= length(struc.segments) || continue
        for v in skel.edge_indices[struc.segments[si].edge_idx]
            abs(_vertex_z_m(skel, v) - z) <= 0.01 || continue
            return _vertex_xy_m(skel, v)
        end
    end
    return nothing
end

function _on_this_slab_plan(xy::NTuple{2, Float64}, poly)
    poly === nothing && return true
    _point_on_polygon_boundary(xy[1], xy[2], poly; tol = 1e-4) && return true
    return _point_in_polygon(xy, poly)
end

"""
    undersized_rib_bays(struc, slab, level) -> Vector{StructuralSizer.RibBay}

Bays of a [`ModularRibPattern`](@ref) grillage smaller than half a module.
Empty for any other pattern, which has no module.
"""
function undersized_rib_bays(struc, slab, fl::FramingLevel)
    fl.pattern isa ModularRibPattern || return StructuralSizer.RibBay[]
    arr, _ = grillage_bays(struc, slab, fl)
    return arr.bays[StructuralSizer.undersized_bays(arr, module_area(fl.pattern))]
end

"""
    grillage_edge_profiles(struc, slab, level) -> Dict{Int, (positions, widths)}

Skeleton width on each skeleton edge that bounds a grillage bay
([`grillage_bays`](@ref)), in the edge's canonical direction. Widths are
metres. Each bay uses its own isotropic skeleton, in closed form when it is a
rectangle, so the pattern can be any rib layout. The areas sum to the slab
less its holes.
"""
function grillage_edge_profiles(struc, slab, fl::FramingLevel)
    arr, owners = grillage_bays(struc, slab, fl)
    isempty(arr.bays) && throw(ArgumentError("a grillage slab encloses no rib bay"))
    profiles = StructuralSizer.bay_edge_profiles(arr)
    skel = struc.skeleton
    groups = Dict{Int, Vector{Int}}()
    for k in keys(profiles)
        push!(get!(Vector{Int}, groups, owners[k]), k)
    end
    ProfT = Tuple{Vector{Float64}, Vector{Float64}}
    merged = Dict{Int, ProfT}()
    area = 0.0
    for (e, ks) in groups
        # A stitched rib splits one skeleton edge into two graph edges. Each
        # profile belongs to its own graph edge; the member load is those
        # pieces laid back along the skeleton edge.
        merged[e] = _profile_on_skeleton_edge(arr, profiles, ks, skel, e)
        for k in ks
            a, b = arr.edges[k]
            p1, p2 = arr.nodes[a], arr.nodes[b]
            pos, w = profiles[k]
            area += _profile_integral(pos, w) * hypot(p2[1] - p1[1], p2[2] - p1[2])
        end
    end
    poly = _slab_interior_polygon_m(struc, slab)
    poly === nothing && throw(ArgumentError(
        "a grillage needs the slab boundary, and this slab has none"))
    panel = StructuralSizer.polygon_area_m(poly) -
        sum(StructuralSizer.polygon_area_m, _slab_hole_loops_m(struc, slab); init = 0.0)
    abs(area - panel) <= 1e-6 * max(panel, 1.0) || throw(ArgumentError(
        "grillage ribs carry $(area) m² and the slab is $(panel) m²"))
    return merged
end

"""
    grillage_tributary_loops(struc, slab, level)
        -> Vector of (skeleton edge, polygon)

The pan skeletons [`grillage_edge_profiles`](@ref) already uses, one polygon
per bay side. `skeleton edge` is the building edge that side loads. The
polygons are the picture of that load; they are not a second load path.
"""
function grillage_tributary_loops(struc, slab, fl::FramingLevel)
    arr, owners = grillage_bays(struc, slab, fl)
    out = Tuple{Int, Vector{NTuple{2, Float64}}}[]
    for (e, poly) in StructuralSizer.bay_tributary_polygons(arr)
        1 <= e <= length(owners) || throw(ArgumentError(
            "a grillage bay side has no skeleton edge"))
        push!(out, (owners[e], poly))
    end
    return out
end

"""
Width profile of skeleton edge `e`, in that edge's direction.

One graph edge keeps its profile. A stitch that split the edge into several
graph edges lays each piece's profile onto its station along the member.
"""
function _profile_on_skeleton_edge(arr, profiles, ks, skel, e)
    length(ks) == 1 && return profiles[ks[1]]
    v1, v2 = skel.edge_indices[e]
    p1 = _vertex_xy_m(skel, v1)
    p2 = _vertex_xy_m(skel, v2)
    stations = Tuple{Float64, Float64}[]
    for k in ks
        a, b = arr.edges[k]
        ta = _station_on_segment(arr.nodes[a], p1, p2)
        tb = _station_on_segment(arr.nodes[b], p1, p2)
        pos, w = profiles[k]
        if ta > tb
            ta, tb = tb, ta
            pos, w = StructuralSizer._reversed_profile(pos, w)
        end
        span = tb - ta
        for i in eachindex(pos)
            push!(stations, (ta + Float64(pos[i]) * span, Float64(w[i])))
        end
    end
    sort!(stations; by = first)
    gpos = Float64[]
    gw = Float64[]
    for (t, w) in stations
        if !isempty(gpos) && t <= gpos[end] + 1e-9
            gw[end] = max(gw[end], w)
            continue
        end
        push!(gpos, t)
        push!(gw, w)
    end
    length(gpos) >= 2 || return profiles[ks[1]]
    gpos[1] > 1e-9 && (pushfirst!(gpos, 0.0); pushfirst!(gw, gw[1]))
    gpos[end] < 1 - 1e-9 && (push!(gpos, 1.0); push!(gw, gw[end]))
    return (gpos, gw)
end

"""Parameter of `p` along segment `a`→`b`, clamped to the segment."""
function _station_on_segment(p, a, b)
    ab = (b[1] - a[1], b[2] - a[2])
    L2 = ab[1]^2 + ab[2]^2
    L2 <= 0 && return 0.0
    t = ((p[1] - a[1]) * ab[1] + (p[2] - a[2]) * ab[2]) / L2
    return clamp(t, 0.0, 1.0)
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
