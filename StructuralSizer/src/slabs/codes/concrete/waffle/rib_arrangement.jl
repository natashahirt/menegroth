# =============================================================================
# Rib arrangement on any plan region
# =============================================================================
#
# Ribs on a polygon with holes form a planar graph: the region boundary and
# the ribs, split at every crossing. Each face of that graph is a bay, and
# each bay sends its load to the edges around it by its own isotropic
# straight skeleton. A cut bay at an irregular edge is handled the same way
# as a full module, and the bay areas sum to the region.
#
# ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101) permits a slab system to
# be analyzed by any procedure that satisfies equilibrium and compatibility.
# The skeleton is the load split inside that procedure; the clause does not
# prescribe it.

"""One face of a [`RibArrangement`](@ref)."""
struct RibBay
    "Node indices around the bay, counterclockwise."
    loop::Vector{Int}
    "Edge index of each side. Side `k` runs from `loop[k]` to `loop[k+1]`."
    sides::Vector{Int}
    "Node loops of free-standing networks inside the bay."
    holes::Vector{Vector{Int}}
    "Plan area, net of `holes`."
    area::Float64
end

"""Nodes, straight edges between them, and the bays they enclose."""
struct RibArrangement
    nodes::Vector{NTuple{2, Float64}}
    edges::Vector{NTuple{2, Int}}
    bays::Vector{RibBay}
end

_xy2(p) = (Float64(p[1]), Float64(p[2]))
_cross2(a, b) = a[1] * b[2] - a[2] * b[1]
_fmt_m(p) = "($(round(p[1]; digits = 3)), $(round(p[2]; digits = 3))) m"

"""Signed shoelace area of a point loop. Counterclockwise is positive."""
function _loop_signed_area(pts)
    n = length(pts)
    a = 0.0
    for i in 1:n
        p = pts[i]
        q = pts[mod1(i + 1, n)]
        a += p[1] * q[2] - q[1] * p[2]
    end
    return a / 2
end

"""Even-odd test. A point on the loop is not decided; callers keep it off."""
function _inside_loop(p, loop)
    x, y = p
    inside = false
    n = length(loop)
    j = n
    for i in 1:n
        xi, yi = loop[i]
        xj, yj = loop[j]
        if (yi > y) != (yj > y)
            xi + (y - yi) / (yj - yi) * (xj - xi) > x && (inside = !inside)
        end
        j = i
    end
    return inside
end

"""Distance from `p` to the closest side of `loop`."""
function _distance_to_loop(p, loop)
    best = Inf
    n = length(loop)
    for i in 1:n
        a = loop[i]
        b = loop[mod1(i + 1, n)]
        ab = (b[1] - a[1], b[2] - a[2])
        L2 = ab[1]^2 + ab[2]^2
        t = L2 <= 0 ? 0.0 : clamp(((p[1] - a[1]) * ab[1] + (p[2] - a[2]) * ab[2]) / L2, 0.0, 1.0)
        best = min(best, hypot(a[1] + t * ab[1] - p[1], a[2] + t * ab[2] - p[2]))
    end
    return best
end

"""Inside `outline`, outside every hole, and at least `tol` from every loop."""
function _in_region(p, outline, holes; tol::Float64 = 1e-9)
    _distance_to_loop(p, outline) <= tol && return false
    _inside_loop(p, outline) || return false
    for h in holes
        _distance_to_loop(p, h) <= tol && return false
        _inside_loop(p, h) && return false
    end
    return true
end

# -----------------------------------------------------------------------------
# Planar faces
# -----------------------------------------------------------------------------

"""
    planar_bays(nodes, edges) -> RibArrangement

Faces of the plan graph with these `nodes` and straight `edges`.

Edges must already meet only at nodes; [`rib_arrangement`](@ref) splits
crossing segments first. Each bounded face is a [`RibBay`](@ref). A
network that touches nothing around it becomes a hole of the smallest bay
that contains it. The outline of the whole graph is not a bay.

Throws when a bay boundary visits a node twice, which is a rib that ends
inside a bay or a lone rib linking two networks. No bay sends load to
such a rib.
"""
function planar_bays(nodes::AbstractVector, edges::AbstractVector)
    xy = NTuple{2, Float64}[_xy2(p) for p in nodes]
    E = NTuple{2, Int}[(Int(e[1]), Int(e[2])) for e in edges]
    edge_of = Dict{Tuple{Int, Int}, Int}()
    adj = [Int[] for _ in xy]
    for (k, (a, b)) in enumerate(E)
        a == b && throw(ArgumentError("rib edge $k starts and ends at node $a"))
        haskey(edge_of, (a, b)) && throw(ArgumentError(
            "nodes $a and $b are joined by two edges"))
        edge_of[(a, b)] = k
        edge_of[(b, a)] = k
        push!(adj[a], b)
        push!(adj[b], a)
    end
    for (v, nbrs) in enumerate(adj)
        p = xy[v]
        sort!(nbrs; by = n -> atan(xy[n][2] - p[2], xy[n][1] - p[1]))
    end
    span = isempty(xy) ? 1.0 :
        max(1.0, maximum(p -> abs(p[1]), xy), maximum(p -> abs(p[2]), xy))
    atol = 1e-12 * span^2

    visited = Set{Tuple{Int, Int}}()
    faces = Vector{Int}[]
    others = Vector{Int}[]
    for u in eachindex(adj), v in adj[u]
        (u, v) in visited && continue
        cycle = Int[]
        cu, cv = u, v
        while !((cu, cv) in visited)
            push!(visited, (cu, cv))
            push!(cycle, cu)
            nb = adj[cv]
            i = findfirst(==(cu), nb)
            cu, cv = cv, nb[mod1(i - 1, length(nb))]
        end
        a = length(cycle) >= 3 ? _loop_signed_area(xy[cycle]) : 0.0
        a > atol ? push!(faces, cycle) : push!(others, cycle)
    end

    for cycle in faces
        allunique(cycle) && continue
        n = length(cycle)
        steps = Set((cycle[i], cycle[mod1(i + 1, n)]) for i in 1:n)
        twice = [(a, b) for (a, b) in steps if a < b && (b, a) in steps]
        where = isempty(twice) ? _fmt_m(xy[cycle[1]]) :
            join(("$(_fmt_m(xy[a])) to $(_fmt_m(xy[b]))" for (a, b) in twice), "; ")
        throw(ArgumentError(
            "a rib bay's boundary walks $where twice. A rib ends inside the bay " *
            "or is the only link between two networks, so no bay loads it."))
    end

    loops = [xy[f] for f in faces]
    areas = [_loop_signed_area(l) for l in loops]
    holes = [Vector{Int}[] for _ in faces]
    for cycle in others
        own = Set(cycle)
        p = xy[cycle[1]]
        host = 0
        for (k, f) in enumerate(faces)
            any(v -> v in own, f) && continue
            _inside_loop(p, loops[k]) || continue
            (host == 0 || areas[k] < areas[host]) && (host = k)
        end
        host == 0 && continue
        a = length(cycle) >= 3 ? _loop_signed_area(xy[cycle]) : 0.0
        (a < -atol && allunique(cycle)) || throw(ArgumentError(
            "ribs near $(_fmt_m(p)) float inside a bay without enclosing an area, " *
            "so no bay loads them. Connect them to the ribs around them."))
        push!(holes[host], cycle)
    end

    bays = RibBay[]
    for (k, f) in enumerate(faces)
        n = length(f)
        sides = [edge_of[(f[i], f[mod1(i + 1, n)])] for i in 1:n]
        net = areas[k] - sum((abs(_loop_signed_area(xy[h])) for h in holes[k]); init = 0.0)
        push!(bays, RibBay(f, sides, holes[k], net))
    end
    return RibArrangement(xy, E, bays)
end

# -----------------------------------------------------------------------------
# Segments into a graph
# -----------------------------------------------------------------------------

"""
Parameters `(t, u)` where segments `a1→b1` and `a2→b2` meet, or `nothing`.
Parallel segments do not meet here. `tol` is a length.
"""
function _segment_crossing(a1, b1, a2, b2, tol::Float64)
    d1 = (b1[1] - a1[1], b1[2] - a1[2])
    d2 = (b2[1] - a2[1], b2[2] - a2[2])
    L1 = hypot(d1...)
    L2 = hypot(d2...)
    (L1 <= tol || L2 <= tol) && return nothing
    den = _cross2(d1, d2)
    abs(den) <= 1e-12 * L1 * L2 && return nothing
    r = (a2[1] - a1[1], a2[2] - a1[2])
    t = _cross2(r, d2) / den
    u = _cross2(r, d1) / den
    e1 = tol / L1
    e2 = tol / L2
    (-e1 <= t <= 1 + e1 && -e2 <= u <= 1 + e2) || return nothing
    return (clamp(t, 0.0, 1.0), clamp(u, 0.0, 1.0))
end

"""
    rib_arrangement(outline, holes, ribs; tol=1e-7) -> RibArrangement

Bays of a region whose ribs are `ribs`.

`outline` and each loop in `holes` are plan polygons. `ribs` are polylines
inside the region, ending on its boundary. Every crossing and every landing
becomes one shared node, so a rib is continuous through it. `tol` is the
length within which two points are one node.
"""
function rib_arrangement(outline, holes, ribs; tol::Float64 = 1e-7)
    segs = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    for loop in Iterators.flatten(((outline,), holes))
        n = length(loop)
        for i in 1:n
            push!(segs, (_xy2(loop[i]), _xy2(loop[mod1(i + 1, n)])))
        end
    end
    for pl in ribs
        for i in 1:(length(pl) - 1)
            push!(segs, (_xy2(pl[i]), _xy2(pl[i + 1])))
        end
    end
    cuts = [Float64[0.0, 1.0] for _ in segs]
    for i in 1:(length(segs) - 1), j in (i + 1):length(segs)
        hit = _segment_crossing(segs[i][1], segs[i][2], segs[j][1], segs[j][2], tol)
        hit === nothing && continue
        push!(cuts[i], hit[1])
        push!(cuts[j], hit[2])
    end
    nodes = NTuple{2, Float64}[]
    function node_at(p)
        for (k, q) in enumerate(nodes)
            hypot(q[1] - p[1], q[2] - p[2]) <= tol && return k
        end
        push!(nodes, p)
        return length(nodes)
    end
    edges = NTuple{2, Int}[]
    seen = Set{NTuple{2, Int}}()
    for ((a, b), ts) in zip(segs, cuts)
        sort!(ts)
        ids = [node_at((a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]))) for t in ts]
        for k in 1:(length(ids) - 1)
            i, j = ids[k], ids[k + 1]
            i == j && continue
            key = (min(i, j), max(i, j))
            key in seen && continue
            push!(seen, key)
            push!(edges, (i, j))
        end
    end
    return without_hole_bays(planar_bays(nodes, edges), [map(_xy2, h) for h in holes])
end

"""`true` when `bay` lies inside one of `holes`, judged just inside its first side."""
function _bay_in_hole(arr::RibArrangement, bay::RibBay, holes)
    isempty(holes) && return false
    p = arr.nodes[bay.loop[1]]
    q = arr.nodes[bay.loop[2]]
    L = hypot(q[1] - p[1], q[2] - p[2])
    ε = 1e-5
    s = ((p[1] + q[1]) / 2 - ε * (q[2] - p[2]) / L, (p[2] + q[2]) / 2 + ε * (q[1] - p[1]) / L)
    return any(h -> _inside_loop(s, h), holes)
end

"""
    without_hole_bays(arr, holes) -> RibArrangement

`arr` without the bays inside `holes`. A hole's boundary encloses a face of
the arrangement, and that face is the void, not a bay.
"""
without_hole_bays(arr::RibArrangement, holes) =
    RibArrangement(arr.nodes, arr.edges, [b for b in arr.bays if !_bay_in_hole(arr, b, holes)])

# -----------------------------------------------------------------------------
# Rib lines
# -----------------------------------------------------------------------------

"""Parameter `t` where the line `p0 + t d` crosses segment `a→b`, or `nothing`."""
function _line_crosses_segment(p0, d, a, b)
    ab = (b[1] - a[1], b[2] - a[2])
    den = _cross2(ab, d)
    abs(den) <= 1e-12 * hypot(ab...) * hypot(d...) && return nothing
    r = (a[1] - p0[1], a[2] - p0[2])
    t = -_cross2(r, ab) / den
    u = -_cross2(r, d) / den
    (-1e-12 <= u <= 1 + 1e-12) || return nothing
    return t
end

"""
    clip_line_to_region(p0, d, outline, holes=()) -> Vector{Tuple{NTuple{2,Float64}, NTuple{2,Float64}}}

Pieces of the infinite line `p0 + t d` inside the region, each from one
boundary crossing to the next.

A piece along the boundary is dropped: that line is already the boundary.
A line through a boundary vertex stays one piece when the region continues
on both sides.
"""
function clip_line_to_region(p0, d, outline, holes = ())
    p0 = _xy2(p0)
    d = _xy2(d)
    hypot(d...) > 0 || throw(ArgumentError("a rib line needs a direction"))
    ts = Float64[]
    for loop in Iterators.flatten(((outline,), holes))
        n = length(loop)
        for i in 1:n
            t = _line_crosses_segment(p0, d, _xy2(loop[i]), _xy2(loop[mod1(i + 1, n)]))
            t === nothing || push!(ts, t)
        end
    end
    sort!(ts)
    at(t) = (p0[1] + t * d[1], p0[2] + t * d[2])
    span = maximum(p -> max(abs(p[1]), abs(p[2])), outline)
    tol = 1e-9 * max(span, 1.0)
    uniq = Float64[]
    for t in ts
        (isempty(uniq) || hypot((at(t) .- at(uniq[end]))...) > tol) && push!(uniq, t)
    end
    out = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    for k in 1:(length(uniq) - 1)
        mid = at((uniq[k] + uniq[k + 1]) / 2)
        _in_region(mid, outline, holes; tol = tol) || continue
        a, b = at(uniq[k]), at(uniq[k + 1])
        if !isempty(out) && hypot((out[end][2] .- a)...) <= tol
            out[end] = (out[end][1], b)
        else
            push!(out, (a, b))
        end
    end
    return out
end

"""Offsets of parallel lines `s` apart across `[pmin, pmax]`."""
function _module_offsets(pmin::Float64, pmax::Float64, s::Float64, through)
    W = pmax - pmin
    if through === nothing
        # Centered, as joist offsets are: end gaps in (s/2, s].
        n = ceil(Int, W / s - 1e-9) - 1
        n <= 0 && return Float64[]
        gap = (W - (n - 1) * s) / 2
        return [pmin + gap + k * s for k in 0:(n - 1)]
    end
    q0 = Float64(through)
    kmin = ceil(Int, (pmin - q0) / s + 1e-9)
    kmax = floor(Int, (pmax - q0) / s - 1e-9)
    return [q0 + k * s for k in kmin:kmax]
end

"""
    modular_rib_lines(outline; angle, spacing, origin=nothing) -> Vector{NamedTuple}

Two orthogonal families of straight ribs over `outline`.

Family 1 runs at `angle` (radians from the x axis) with ribs `spacing[1]`
apart. Family 2 runs at `angle + π/2` with ribs `spacing[2]` apart. With
`origin`, one rib of each family passes through it. Without, each family
is centered on the outline so its two end gaps are equal and in
`(s/2, s]`.

Each entry is `(family, point, direction)` for an infinite line. Clip it
with [`clip_line_to_region`](@ref).
"""
function modular_rib_lines(outline; angle::Real, spacing, origin = nothing)
    s1, s2 = Float64(spacing[1]), Float64(spacing[2])
    (s1 > 0 && s2 > 0) || throw(ArgumentError(
        "rib spacing must be positive, got $s1 and $s2"))
    c, s = cos(Float64(angle)), sin(Float64(angle))
    d1 = (c, s)
    d2 = (-s, c)
    pts = [_xy2(p) for p in outline]
    out = NamedTuple{(:family, :point, :direction),
                     Tuple{Int, NTuple{2, Float64}, NTuple{2, Float64}}}[]
    for (family, dir, normal, sp) in ((1, d1, d2, s1), (2, d2, d1, s2))
        proj = [p[1] * normal[1] + p[2] * normal[2] for p in pts]
        through = origin === nothing ? nothing :
            Float64(origin[1]) * normal[1] + Float64(origin[2]) * normal[2]
        for q in _module_offsets(minimum(proj), maximum(proj), sp, through)
            push!(out, (family = family, point = (q * normal[1], q * normal[2]), direction = dir))
        end
    end
    return out
end

"""
    modular_rib_arrangement(outline, holes; angle, spacing, origin=nothing) -> RibArrangement

[`modular_rib_lines`](@ref) clipped to the region and split at every
crossing.
"""
function modular_rib_arrangement(outline, holes = (); angle::Real, spacing, origin = nothing)
    ribs = Vector{NTuple{2, Float64}}[]
    for line in modular_rib_lines(outline; angle = angle, spacing = spacing, origin = origin)
        for (a, b) in clip_line_to_region(line.point, line.direction, outline, holes)
            push!(ribs, [a, b])
        end
    end
    return rib_arrangement(outline, holes, ribs)
end

"""
    undersized_bays(arr, module_area; fraction=0.5) -> Vector{Int}

Bays of `arr` smaller than `fraction` of a full module.
"""
function undersized_bays(arr::RibArrangement, module_area::Real; fraction::Real = 0.5)
    module_area > 0 || throw(ArgumentError("module area must be positive, got $module_area"))
    # A cut bay under half a module stays a ribbed void unless a column head
    # claims it: the offcut is formed with a smaller pan. ACI 318-11 §8.13
    # sets no minimum bay size; the half-module mark is only this list.
    return [k for (k, bay) in enumerate(arr.bays) if bay.area < fraction * module_area]
end

# -----------------------------------------------------------------------------
# Bay skeletons
# -----------------------------------------------------------------------------

"""Piecewise-linear width at `t` on a `(positions, widths)` profile."""
function _width_at(pos, w, t)
    t <= pos[1] && return Float64(w[1])
    t >= pos[end] && return Float64(w[end])
    i = clamp(searchsortedlast(pos, t), 1, length(pos) - 1)
    dt = pos[i + 1] - pos[i]
    dt <= 0 && return Float64(w[i + 1])
    return w[i] + (t - pos[i]) / dt * (w[i + 1] - w[i])
end

"""The piece of a profile between `t0` and `t1`, rescaled to `[0, 1]`."""
function _sub_profile(pos, w, t0::Float64, t1::Float64)
    (t0 <= 1e-12 && t1 >= 1 - 1e-12) && return (collect(Float64, pos), collect(Float64, w))
    P = [t0]
    W = [_width_at(pos, w, t0)]
    for (p, wi) in zip(pos, w)
        t0 < p < t1 || continue
        push!(P, p)
        push!(W, Float64(wi))
    end
    push!(P, t1)
    push!(W, _width_at(pos, w, t1))
    return ((P .- t0) ./ (t1 - t0), W)
end

"""Skeleton profile of each side of a polygon with no straight-through vertex."""
function _corner_polygon_profiles(cpts, hole_pts)
    m = length(cpts)
    if isempty(hole_pts) && is_rectangular_panel(cpts)
        return map(1:m) do j
            a, b, c = cpts[j], cpts[mod1(j + 1, m)], cpts[mod1(j + 2, m)]
            rectangle_edge_tributary(hypot((b .- a)...), hypot((c .- b)...))
        end
    end
    pts = [Meshes.Point(p[1], p[2]) for p in cpts]
    polys = try
        get_tributary_polygons_isotropic(pts; holes = isempty(hole_pts) ? nothing : hole_pts)
    catch err
        throw(ArgumentError(
            "a rib bay at $(_fmt_m(cpts[1])) could not be given an isotropic skeleton " *
            "($(sprint(showerror, err)))"))
    end
    out = [(Float64[0.0, 1.0], Float64[0.0, 0.0]) for _ in 1:m]
    for poly in polys
        1 <= poly.local_edge_idx <= m || continue
        out[poly.local_edge_idx] = (collect(Float64, poly.profile_s),
                                    [max(Float64(wi), 0.0) for wi in poly.profile_w])
    end
    return out
end

"""`(edge, (positions, widths))` for every side of `bay`, in edge direction."""
function _bay_side_profiles(arr::RibArrangement, bay::RibBay)
    loop = bay.loop
    n = length(loop)
    pts = arr.nodes[loop]
    corners = Int[]
    for k in 1:n
        a, b, c = pts[mod1(k - 1, n)], pts[k], pts[mod1(k + 1, n)]
        ab = (b[1] - a[1], b[2] - a[2])
        bc = (c[1] - b[1], c[2] - b[2])
        abs(_cross2(ab, bc)) > 1e-9 * hypot(ab...) * hypot(bc...) && push!(corners, k)
    end
    m = length(corners)
    m >= 3 || throw(ArgumentError("a rib bay at $(_fmt_m(pts[1])) has no area"))
    hole_pts = [arr.nodes[h] for h in bay.holes]
    profiles = _corner_polygon_profiles(pts[corners], hole_pts)
    out = Tuple{Int, Tuple{Vector{Float64}, Vector{Float64}}}[]
    carried = 0.0
    for j in 1:m
        k0, k1 = corners[j], corners[mod1(j + 1, m)]
        ks = Int[]
        k = k0
        while true
            push!(ks, k)
            k = mod1(k + 1, n)
            k == k1 && break
        end
        lens = [hypot((pts[mod1(k + 1, n)] .- pts[k])...) for k in ks]
        total = sum(lens)
        pos, w = profiles[j]
        carried += tributary_profile_area(total, pos, w)
        t0 = 0.0
        for (k, L) in zip(ks, lens)
            t1 = min(t0 + L / total, 1.0)
            sp, sw = _sub_profile(pos, w, t0, t1)
            e = bay.sides[k]
            arr.edges[e][1] == loop[k] || ((sp, sw) = _reversed_profile(sp, sw))
            push!(out, (e, (sp, sw)))
            t0 = t1
        end
    end
    abs(carried - bay.area) <= 1e-6 * max(bay.area, 1.0) || throw(ArgumentError(
        "the rib bay at $(_fmt_m(pts[1])) is $(bay.area) m², but its skeleton " *
        "gives the ribs $(carried) m²"))
    return out
end

"""
    bay_edge_profiles(arr) -> Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}

Skeleton width on every edge of `arr` that bounds a bay, in the edge's own
direction (`edges[e][1]` to `edges[e][2]`).

A rectangular bay uses the closed form ([`rectangle_edge_tributary`](@ref));
any other bay uses [`get_tributary_polygons_isotropic`](@ref). An edge
between two bays carries both widths. Straight-through nodes on a bay side
split that side's profile by length, so a side cut by a landing keeps the
skeleton of the whole side. Every bay is checked to send its whole area.
"""
function bay_edge_profiles(arr::RibArrangement)
    ProfT = Tuple{Vector{Float64}, Vector{Float64}}
    acc = Dict{Int, Vector{ProfT}}()
    for bay in arr.bays
        for (e, prof) in _bay_side_profiles(arr, bay)
            push!(get!(Vector{ProfT}, acc, e), prof)
        end
    end
    out = Dict{Int, ProfT}()
    for (e, profs) in acc
        out[e] = length(profs) == 1 ? profs[1] : Asap._sum_profiles(profs)
    end
    return out
end
