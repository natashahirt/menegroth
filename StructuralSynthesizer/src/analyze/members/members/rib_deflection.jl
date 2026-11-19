# Cracked service deflection of a ribbed story.
#
# The building frame is re-solved at service level with every concrete beam
# element on the story at its ACI 318-11 Eq. (9-8) Ie. A station's deflection
# is its sag below the surface through the column tops of its column bay, read
# from the same solve, so column shortening is not counted as floor sag. The
# span is the bay's longest center-to-center column distance. Limits are ACI
# 318-11 Table 9.5(b) (corpus: aci-318-11, PDF p. 133).
# See docs/sizing-map/ribbed-floors.md.

"""Story index of `slab`, from its first cell's face."""
function _slab_story(struc, slab)
    for (lvl, story) in struc.skeleton.stories
        struc.cells[first(slab.cell_indices)].face_idx in story.faces && return lvl
    end
    throw(ArgumentError("slab on face $(struc.cells[first(slab.cell_indices)].face_idx) is on no story"))
end

_xy_m(node) = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))

"""`true` when `p` is strictly inside the circumcircle of triangle `t` of `pts`."""
function _in_circumcircle(pts, t, p, scale)
    a, b, c = pts[t[1]], pts[t[2]], pts[t[3]]
    _cross2(a, b, c) < 0 && ((b, c) = (c, b))
    ax, ay = a[1] - p[1], a[2] - p[2]
    bx, by = b[1] - p[1], b[2] - p[2]
    cx, cy = c[1] - p[1], c[2] - p[2]
    det = (ax^2 + ay^2) * (bx * cy - cx * by) -
          (bx^2 + by^2) * (ax * cy - cx * ay) +
          (cx^2 + cy^2) * (ax * by - bx * ay)
    return det > 1e-9 * scale^4
end

"""
Delaunay triangles of `pts` (Bowyer–Watson). Points on a common circle are
not split, so a rectangular column grid gives one diagonal per bay.
"""
function _delaunay(pts::Vector{NTuple{2, Float64}})
    n = length(pts)
    xs, ys = first.(pts), last.(pts)
    span = max(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys), 1.0)
    cx, cy = (minimum(xs) + maximum(xs)) / 2, (minimum(ys) + maximum(ys)) / 2
    R = 50 * span
    P = vcat(pts, [(cx - 2R, cy - R), (cx + 2R, cy - R), (cx, cy + 2R)])
    tris = NTuple{3, Int}[(n + 1, n + 2, n + 3)]
    for i in 1:n
        bad = [t for t in tris if _in_circumcircle(P, t, P[i], span)]
        count = Dict{NTuple{2, Int}, Int}()
        for t in bad, (a, b) in ((t[1], t[2]), (t[2], t[3]), (t[3], t[1]))
            e = minmax(a, b)
            count[e] = get(count, e, 0) + 1
        end
        filter!(t -> !(t in bad), tris)
        for (e, k) in count
            k == 1 && push!(tris, (e[1], e[2], i))
        end
    end
    filter!(t -> all(<=(n), t) && abs(_cross2(P[t[1]], P[t[2]], P[t[3]])) > 1e-9 * span^2, tris)
    return tris
end

"""`loop` reordered counterclockwise."""
function _ccw(pts, loop)
    a = sum(_cross2((0.0, 0.0), pts[loop[k]], pts[loop[mod1(k + 1, length(loop))]])
            for k in eachindex(loop))
    return a < 0 ? reverse(loop) : loop
end

"""
Column bays: Delaunay triangles, with two triangles whose shared edge is the
longest edge of both and whose union is convex merged into one quadrilateral.
On a rectangular grid each bay is its four columns.
"""
function _column_bays(pts)
    tris = _delaunay(pts)
    d(a, b) = hypot(pts[a][1] - pts[b][1], pts[a][2] - pts[b][2])
    longest(t) = argmax(e -> d(e...), (minmax(t[1], t[2]), minmax(t[2], t[3]), minmax(t[3], t[1])))
    by_edge = Dict{NTuple{2, Int}, Vector{Int}}()
    for (k, t) in enumerate(tris)
        push!(get!(Vector{Int}, by_edge, longest(t)), k)
    end
    used = falses(length(tris))
    bays = Vector{Vector{Int}}()
    for (e, ks) in by_edge
        length(ks) == 2 || continue
        t1, t2 = tris[ks[1]], tris[ks[2]]
        o1 = only(setdiff(t1, e))
        o2 = only(setdiff(t2, e))
        quad = _ccw(pts, [e[1], o1, e[2], o2])
        convex = all(_cross2(pts[quad[k]], pts[quad[mod1(k + 1, 4)]],
                             pts[quad[mod1(k + 2, 4)]]) > 0 for k in 1:4)
        convex || continue
        used[ks] .= true
        push!(bays, quad)
    end
    for (k, t) in enumerate(tris)
        used[k] || push!(bays, _ccw(pts, collect(t)))
    end
    return bays
end

"""Longest side of a bay polygon, metres."""
_bay_span(xy) = maximum(hypot(xy[k][1] - xy[mod1(k + 1, length(xy))][1],
                              xy[k][2] - xy[mod1(k + 1, length(xy))][2]) for k in eachindex(xy))

"""`true` when `p` is in the convex counterclockwise polygon `xy`, edges included."""
function _in_bay(xy, p, tol)
    for k in eachindex(xy)
        a, b = xy[k], xy[mod1(k + 1, length(xy))]
        _cross2(a, b, p) < -tol * hypot(b[1] - a[1], b[2] - a[2]) && return false
    end
    return true
end

"""
Value at `p` of the surface through `w` at the bay corners `xy`: linear on a
triangle, bilinear on a quadrilateral.
"""
function _bay_surface(xy, w, p)
    if length(xy) == 3
        A = _cross2(xy[1], xy[2], xy[3])
        l1 = _cross2(p, xy[2], xy[3]) / A
        l2 = _cross2(xy[1], p, xy[3]) / A
        return l1 * w[1] + l2 * w[2] + (1 - l1 - l2) * w[3]
    end
    ξ, η = 0.5, 0.5
    for _ in 1:20
        N = ((1 - ξ) * (1 - η), ξ * (1 - η), ξ * η, (1 - ξ) * η)
        dξ = (-(1 - η), 1 - η, η, -η)
        dη = (-(1 - ξ), -ξ, ξ, 1 - ξ)
        rx = sum(N[k] * xy[k][1] for k in 1:4) - p[1]
        ry = sum(N[k] * xy[k][2] for k in 1:4) - p[2]
        J11 = sum(dξ[k] * xy[k][1] for k in 1:4); J12 = sum(dη[k] * xy[k][1] for k in 1:4)
        J21 = sum(dξ[k] * xy[k][2] for k in 1:4); J22 = sum(dη[k] * xy[k][2] for k in 1:4)
        det = J11 * J22 - J12 * J21
        δξ = (J22 * rx - J12 * ry) / det
        δη = (-J21 * rx + J11 * ry) / det
        ξ -= δξ
        η -= δη
        abs(δξ) + abs(δη) < 1e-12 && break
    end
    N = ((1 - ξ) * (1 - η), ξ * (1 - η), ξ * η, (1 - ξ) * η)
    return sum(N[k] * w[k] for k in 1:4)
end

"""
    story_column_bays(struc, lvl) -> Vector{NamedTuple}

Column bays of story `lvl`, from the tops of the columns that end on it:
`(nodes, xy, l)`, with `nodes` the model node of each corner, `xy` in metres
counterclockwise, and `l` the longest center-to-center span in metres.
ENGINEERING JUDGMENT: walls are not bay corners; a floor carried by walls
needs its own reference.
"""
function story_column_bays(struc, lvl::Int)
    model = struc.asap_model
    verts = Set(struc.skeleton.stories[lvl].vertices)
    ids = sort!(unique([c.vertex_idx for c in struc.columns if c.vertex_idx in verts]))
    length(ids) >= 3 || throw(ArgumentError(
        "story $lvl has $(length(ids)) column tops; a column bay needs three"))
    pts = [_xy_m(model.nodes[v]) for v in ids]
    bays = _column_bays(pts)
    isempty(bays) && throw(ArgumentError("the column tops of story $lvl are collinear"))
    return [(nodes = ids[b], xy = pts[b], l = _bay_span(pts[b])) for b in bays]
end

"""
Concrete beam elements of story `lvl` that take a service inertia:
`element index => (section, beam index)`. Solid-head pieces keep the model
stiffness (ENGINEERING JUDGMENT: they are slab, not cracked beams).
"""
function _story_service_elements(struc, lvl::Int)
    skel = struc.skeleton
    # A rib or other level beam belongs to a story through its framing level's
    # slab, not `edge_story`/`story.edges`: an interior grillage rib added after
    # the last geometry-cache rebuild has no story entry and would read story 0,
    # and at the pre-loop depth screen only the ribs carry a concrete section.
    on_story = Set{UInt64}()
    solid = Set{UInt64}()
    for slab in struc.slabs
        slvl = _slab_story(struc, slab)
        for fl in slab.framing_levels
            fl.solid_group_id === nothing || push!(solid, fl.solid_group_id)
            slvl == lvl || continue
            foreach(g -> push!(on_story, g), level_group_ids(fl))
        end
    end
    n_el = length(struc.asap_model.frame_elements)
    out = Dict{Int, Tuple{Any, Int}}()
    for (bi, beam) in enumerate(struc.beams)
        gid = group_id(beam)
        gid in solid && continue
        sec = section(beam)
        sec isa Union{StructuralSizer.RCTBeamSection, StructuralSizer.RCBeamSection} || continue
        for si in segment_indices(beam)
            e = struc.segments[si].edge_idx
            # Level beam: placed by its framing level. Girder (no level): by edge.
            (gid in on_story || edge_story(skel, e) == lvl) || continue
            for i in _frame_element_indices(struc, e)
                1 <= i <= n_el && (out[i] = (sec, bi))
            end
        end
    end
    return out
end

_m4(x) = x isa Unitful.Quantity ? ustrip(u"m^4", x) : Float64(x)

"""Largest sagging and hogging moments (N·m, magnitudes) along element `el`."""
function _service_moments(el, uD, uL, c, loadsD, loadsL)
    fD = _element_forces_from_u(el, uD, loadsD; resolution = 5)
    fL = _element_forces_from_u(el, uL, loadsL; resolution = 5)
    sgn = el.LCS[2][3] > 0 ? 1.0 : -1.0
    M = sgn .* (fD.My .+ c .* fL.My)
    return max(maximum(M), 0.0), max(-minimum(M), 0.0)
end

"""
    story_rib_deflection(struc, lvl; sustained_live_fraction, limit = :sensitive,
                         max_iter = 4, tol = 0.05, resolution = 5) -> NamedTuple

Cracked service deflection of story `lvl` against ACI 318-11 Table 9.5(b).

Three service states are solved on the building frame: dead `D`, sustained
`D + ψL`, and `D + L` ([`_service_dead_live_loads`](@ref), unfactored). In
each, every element from [`_story_service_elements`](@ref) gets
`E·Ie/I_model`, with Ie from [`StructuralSizer.service_inertia`](@ref) at that
state's moments, starting uncracked; the factor only ratchets down (a cracked
element stays cracked) until it moves less than `tol`. A section with no top
bars takes those the factored solve already in the model requires.

At each element station the sag is the column-top surface of its bay
([`story_column_bays`](@ref)) minus the station's vertical displacement. Per
station (§9.5.2.5, Eq. 9-11 with ξ = 2.0 and, conservatively, ρ′ = 0):

- immediate live `Δ_DL − Δ_D ≤ l/360`;
- after attachment `λΔ Δ_S + (Δ_DL − Δ_S) ≤ l/480` (`limit = :sensitive`) or
  `l/240` (`:total`).

The model's sections and stiffness are restored; its factored displacements
are not touched.
"""
function story_rib_deflection(struc, lvl::Int; sustained_live_fraction::Real,
                              limit::Symbol = :sensitive, concrete, rebar,
                              max_iter::Int = 4, tol::Float64 = 0.05, resolution::Int = 5)
    limit in (:sensitive, :total) || throw(ArgumentError(
        "rib_deflection_limit is :$limit; use :sensitive (l/480) or :total (l/240)"))
    ψ = StructuralSizer._as_sustained_live_fraction(sustained_live_fraction)
    model = struc.asap_model
    frames = model.frame_elements
    els = _story_service_elements(struc, lvl)
    isempty(els) && throw(ArgumentError("story $lvl has no concrete beam elements"))
    bays = story_column_bays(struc, lvl)
    mat = _service_materials(concrete, rebar)
    Ec, Es, fr = mat.Ec * u"Pa", mat.Es * u"Pa", mat.fr * u"Pa"
    dead, live, _ = _service_dead_live_loads(struc)
    byD = Asap.frame_loads_by_element(model, dead)
    byL = Asap.frame_loads_by_element(model, live)
    byU = Asap.frame_loads_by_element(model, model.loads)
    none = Asap.AbstractLoad[]
    idx = sort!(collect(keys(els)))

    # Sections with no top bars take those the factored solve requires.
    fc_psi = ustrip(u"psi", concrete.fc′)
    fy_psi = ustrip(u"psi", rebar.Fy)
    secs = Dict{Int, Any}()
    for i in idx
        sec = first(els[i])
        if sec isa StructuralSizer.RCTBeamSection && ustrip(u"inch^2", sec.As_prime) == 0
            _, Mu_neg = _service_moments(frames[i], model.u, model.u, 0.0,
                                         get(byU, i, none), none)
            sec = StructuralSizer._with_top_steel(sec, Mu_neg * u"N*m", fc_psi, fy_psi)
        end
        secs[i] = sec
    end

    base = [el.section for el in frames]
    I_model = Dict(i => _m4(base[i].Ix) for i in idx)
    k0 = Dict(i => _m4(StructuralSizer.service_inertia(secs[i], 0.0u"N*m", 0.0u"N*m";
                                                     Ec, Es, fr)[2]) / I_model[i] for i in idx)
    profiles = Dict{Symbol, Dict{Int, Vector{Float64}}}()
    corner_w = Dict{Symbol, Vector{Vector{Float64}}}()
    converged = true
    try
        for (name, c) in ((:D, 0.0), (:S, ψ), (:DL, 1.0))
            k = copy(k0)
            uD = uL = Float64[]
            settled = false
            for _ in 1:max_iter
                for i in idx
                    frames[i].section = StructuralSizer.section_scaled_moduli(base[i], k[i])
                end
                Asap.update!(model; values_only = true)
                _restore_column_springs!(model)
                uD, uL = Asap.solve(model, Vector{Asap.AbstractLoad}[dead, live],
                                    struc.asap_rigid_links)
                next = Dict{Int, Float64}()
                for i in idx
                    Mp, Mn = _service_moments(frames[i], uD, uL, c,
                                              get(byD, i, none), get(byL, i, none))
                    Ie, _ = StructuralSizer.service_inertia(secs[i], Mp * u"N*m", Mn * u"N*m";
                                                            Ec, Es, fr)
                    next[i] = min(k[i], _m4(Ie) / I_model[i])
                end
                done = all(abs(next[i] - k[i]) <= tol * max(k[i], 1e-9) for i in idx)
                k = next
                if done
                    settled = true
                    break
                end
            end
            converged &= settled
            profiles[name] = Dict(i => Asap.element_deflection_profile(
                                           frames[i], uD, get(byD, i, none); resolution) .+
                                       c .* Asap.element_deflection_profile(
                                           frames[i], uL, get(byL, i, none); resolution)
                                  for i in idx)
            corner_w[name] = [[uD[model.nodes[v].globalID[3]] + c * uL[model.nodes[v].globalID[3]]
                               for v in b.nodes] for b in bays]
        end
    finally
        for (el, sec) in zip(frames, base)
            el.section = sec
        end
        Asap.update!(model; values_only = true)
        _restore_column_springs!(model)
    end

    λΔ = StructuralSizer.long_term_deflection_factor(2.0, 0.0)
    after_div = limit === :sensitive ? 480.0 : 240.0
    worst_ll = (ratio = 0.0, Δ = 0.0, l = 0.0, at = (NaN, NaN))
    worst_lt = worst_ll
    for i in idx
        el = frames[i]
        p0, p1 = _xy_m(el.nodeStart), _xy_m(el.nodeEnd)
        for j in 1:resolution
            t = (j - 1) / (resolution - 1)
            p = (p0[1] + t * (p1[1] - p0[1]), p0[2] + t * (p1[2] - p0[2]))
            for (b, bay) in enumerate(bays)
                _in_bay(bay.xy, p, 1e-6) || continue
                sag(name) = _bay_surface(bay.xy, corner_w[name][b], p) - profiles[name][i][j]
                ΔD, ΔS, ΔDL = sag(:D), sag(:S), sag(:DL)
                Δ_ll = ΔDL - ΔD
                Δ_lt = λΔ * ΔS + (ΔDL - ΔS)
                r_ll = Δ_ll / (bay.l / 360)
                r_lt = Δ_lt / (bay.l / after_div)
                r_ll > worst_ll.ratio && (worst_ll = (ratio = r_ll, Δ = Δ_ll, l = bay.l, at = p))
                r_lt > worst_lt.ratio && (worst_lt = (ratio = r_lt, Δ = Δ_lt, l = bay.l, at = p))
            end
        end
    end
    return (ok = worst_ll.ratio <= 1.0 && worst_lt.ratio <= 1.0,
            live = worst_ll, long_term = worst_lt, limit = limit,
            n_bays = length(bays), converged = converged)
end
