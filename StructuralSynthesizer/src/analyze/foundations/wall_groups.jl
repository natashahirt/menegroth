# Grade-wall foundation groups.
#
# A grade story whose plan closes a cell is one mat (ACI 318-11 §15.10.1,
# corpus: aci-318-11, page 277). A straight run, and an L or a T that does
# not close, is one wall footing. A spur that tees off a cell is its own
# strip, measured from the cell face; the mat does not grow out to cover it.
# Two disconnected closed groups are two mats.

const _WALL_FND_JOIN_M = 1e-3

"""One straight piece of a grade wall, in plan metres."""
struct WallFoundationPiece
    wall_index::Int
    p1::NTuple{2, Float64}
    p2::NTuple{2, Float64}
end

"""
A foundation shared by one connected set of grade-wall pieces.

`kind` is `:mat` when the pieces close a cell and `:strip` when they do not.
`polygon` is the outer ring of a mat, in metres, and is empty for a strip.
"""
struct WallFoundationGroup
    kind::Symbol
    pieces::Vector{WallFoundationPiece}
    polygon::Vector{NTuple{2, Float64}}
end

"""
    classify_wall_foundation_groups(walls, indices) → Vector{WallFoundationGroup}

Group the walls in `indices`. Endpoints within 1 mm are the same joint, and
an endpoint that lands in the middle of another wall splits that wall.

A door or window is a hole in the wall, not a gap in the centerline. The
cell stays closed, and the mat still covers that wall, opening included.
"""
function classify_wall_foundation_groups(walls, indices::AbstractVector{Int})
    raw = Tuple{Int, NTuple{2, Float64}, NTuple{2, Float64}}[]
    for i in indices
        w = walls[i]
        p1 = (Float64(w.x1), Float64(w.y1))
        p2 = (Float64(w.x2), Float64(w.y2))
        hypot(p2[1] - p1[1], p2[2] - p1[2]) < _WALL_FND_JOIN_M && continue
        push!(raw, (i, p1, p2))
    end
    isempty(raw) && return WallFoundationGroup[]

    pieces = _split_wall_pieces(raw)
    verts, edges = _wall_graph(pieces)
    comps = _edge_components(length(verts), edges)
    groups = WallFoundationGroup[]
    for comp in comps
        append!(groups, _groups_of_component(verts, edges, pieces, comp))
    end
    return groups
end

classify_wall_foundation_groups(walls) =
    classify_wall_foundation_groups(walls, eachindex(walls))

"""True when `(x, y)` is inside a mat group. A point on the wall line is not inside."""
function point_in_wall_group(group::WallFoundationGroup, x::Real, y::Real)
    group.kind == :mat || return false
    _near_piece(group.pieces, x, y) && return false
    return _point_in_ring(group.polygon, Float64(x), Float64(y))
end

# ── Geometry ────────────────────────────────────────────────────────────────

function _split_wall_pieces(raw)
    cuts = Dict{Int, Vector{NTuple{2, Float64}}}()
    for i in eachindex(raw), j in eachindex(raw)
        i == j && continue
        _, a1, a2 = raw[i]
        for p in (raw[j][2], raw[j][3])
            _open_hit(a1, a2, p) === nothing && continue
            push!(get!(() -> NTuple{2, Float64}[], cuts, i), p)
        end
    end
    pieces = WallFoundationPiece[]
    for (k, (idx, a, b)) in enumerate(raw)
        pts = NTuple{2, Float64}[a, b]
        for p in get(cuts, k, NTuple{2, Float64}[])
            push!(pts, p)
        end
        dx, dy = b[1] - a[1], b[2] - a[2]
        L = hypot(dx, dy)
        sort!(pts, by = p -> ((p[1] - a[1]) * dx + (p[2] - a[2]) * dy) / L)
        for i in 1:(length(pts) - 1)
            hypot(pts[i + 1][1] - pts[i][1], pts[i + 1][2] - pts[i][2]) <
                _WALL_FND_JOIN_M && continue
            push!(pieces, WallFoundationPiece(idx, pts[i], pts[i + 1]))
        end
    end
    return pieces
end

"""Parameter of `p` on the open segment `a`–`b`, or `nothing`."""
function _open_hit(a, b, p)
    dx, dy = b[1] - a[1], b[2] - a[2]
    L2 = dx * dx + dy * dy
    L2 <= 0 && return nothing
    t = ((p[1] - a[1]) * dx + (p[2] - a[2]) * dy) / L2
    (t <= _WALL_FND_JOIN_M / sqrt(L2) || t >= 1 - _WALL_FND_JOIN_M / sqrt(L2)) &&
        return nothing
    px = a[1] + t * dx
    py = a[2] + t * dy
    hypot(px - p[1], py - p[2]) > _WALL_FND_JOIN_M && return nothing
    return t
end

function _wall_graph(pieces)
    verts = NTuple{2, Float64}[]
    function vid(p)
        for (i, v) in enumerate(verts)
            hypot(v[1] - p[1], v[2] - p[2]) <= _WALL_FND_JOIN_M && return i
        end
        push!(verts, p)
        return length(verts)
    end
    edges = Tuple{Int, Int, Int}[]
    for (k, piece) in enumerate(pieces)
        a, b = vid(piece.p1), vid(piece.p2)
        a == b && continue
        push!(edges, (a, b, k))
    end
    return verts, edges
end

function _edge_components(nvert, edges)
    parent = collect(1:nvert)
    function find(v)
        parent[v] == v && return v
        parent[v] = find(parent[v])
        return parent[v]
    end
    for (a, b, _) in edges
        ra, rb = find(a), find(b)
        ra != rb && (parent[rb] = ra)
    end
    buckets = Dict{Int, Vector{Int}}()
    for (k, (a, _, _)) in enumerate(edges)
        push!(get!(() -> Int[], buckets, find(a)), k)
    end
    return collect(values(buckets))
end

"""
Peel degree-1 vertices. What remains is the cell; the peeled edges are spurs.
A component with no cell is one strip.
"""
function _groups_of_component(verts, edges, pieces, comp)
    sub = edges[comp]
    alive = trues(length(sub))
    adj = [Int[] for _ in 1:length(verts)]
    deg = zeros(Int, length(verts))
    for (k, (a, b, _)) in enumerate(sub)
        push!(adj[a], k)
        push!(adj[b], k)
        deg[a] += 1
        deg[b] += 1
    end
    q = [v for v in eachindex(verts) if deg[v] == 1]
    head = 1
    while head <= length(q)
        v = q[head]
        head += 1
        deg[v] == 1 || continue
        e = 0
        for k in adj[v]
            alive[k] || continue
            e = k
            break
        end
        e == 0 && continue
        alive[e] = false
        deg[v] = 0
        a, b, _ = sub[e]
        u = a == v ? b : a
        deg[u] -= 1
        deg[u] == 1 && push!(q, u)
    end

    core = [sub[k] for k in eachindex(sub) if alive[k]]
    spurs = [sub[k] for k in eachindex(sub) if !alive[k]]
    if isempty(core)
        return WallFoundationGroup[_strip_group(pieces, sub)]
    end
    groups = WallFoundationGroup[_mat_group(verts, pieces, core)]
    for spur in _spur_components(spurs)
        push!(groups, _strip_group(pieces, spur))
    end
    return groups
end

function _spur_components(spurs)
    isempty(spurs) && return Vector{Vector{Tuple{Int, Int, Int}}}()
    parent = Dict{Int, Int}()
    function find(v)
        haskey(parent, v) || (parent[v] = v)
        parent[v] == v && return v
        parent[v] = find(parent[v])
        return parent[v]
    end
    for (a, b, _) in spurs
        ra, rb = find(a), find(b)
        ra != rb && (parent[rb] = ra)
    end
    buckets = Dict{Int, Vector{Tuple{Int, Int, Int}}}()
    for e in spurs
        push!(get!(() -> Tuple{Int, Int, Int}[], buckets, find(e[1])), e)
    end
    return collect(values(buckets))
end

function _strip_group(pieces, edges)
    WallFoundationGroup(:strip, [pieces[e[3]] for e in edges], NTuple{2, Float64}[])
end

function _mat_group(verts, pieces, core)
    owned = [pieces[e[3]] for e in core]
    ring = _outer_ring(verts, [(e[1], e[2]) for e in core])
    return WallFoundationGroup(:mat, owned, ring)
end

"""The face with the largest area. For a cell with a shaft, that is the outside."""
function _outer_ring(verts, edges)
    faces = _walk_faces(verts, edges)
    isempty(faces) && return NTuple{2, Float64}[]
    best = faces[1]
    best_a = abs(_shoelace(verts, best))
    for face in faces
        a = abs(_shoelace(verts, face))
        a > best_a && (best = face; best_a = a)
    end
    return NTuple{2, Float64}[verts[i] for i in best]
end

function _walk_faces(verts, edges)
    adj = [Tuple{Int, Float64}[] for _ in eachindex(verts)]
    for (a, b) in edges
        push!(adj[a], (b, atan(verts[b][2] - verts[a][2], verts[b][1] - verts[a][1])))
        push!(adj[b], (a, atan(verts[a][2] - verts[b][2], verts[a][1] - verts[b][1])))
    end
    for nbrs in adj
        sort!(nbrs, by = t -> t[2])
    end
    function nxt(u, v)
        incoming = atan(verts[u][2] - verts[v][2], verts[u][1] - verts[v][1])
        nbrs = adj[v]
        for (w, ang) in nbrs
            ang > incoming + 1e-12 && return w
        end
        return nbrs[1][1]
    end
    seen = Set{Tuple{Int, Int}}()
    faces = Vector{Vector{Int}}()
    for (a, b) in edges
        for (u0, v0) in ((a, b), (b, a))
            (u0, v0) in seen && continue
            face = Int[]
            u, v = u0, v0
            guard = 0
            while guard <= 2 * length(edges) + 2
                guard += 1
                push!(face, u)
                push!(seen, (u, v))
                w = nxt(u, v)
                u, v = v, w
                (u, v) == (u0, v0) && break
            end
            push!(faces, face)
        end
    end
    return faces
end

function _shoelace(verts, face)
    a = 0.0
    n = length(face)
    for i in 1:n
        x1, y1 = verts[face[i]]
        x2, y2 = verts[face[mod1(i + 1, n)]]
        a += x1 * y2 - x2 * y1
    end
    return 0.5 * a
end

function _point_in_ring(ring, x, y)
    length(ring) < 3 && return false
    inside = false
    n = length(ring)
    for i in 1:n
        x1, y1 = ring[i]
        x2, y2 = ring[mod1(i + 1, n)]
        (y1 > y) == (y2 > y) && continue
        xint = x1 + (y - y1) / (y2 - y1) * (x2 - x1)
        xint > x && (inside = !inside)
    end
    return inside
end

function _near_piece(pieces, x, y)
    for piece in pieces
        _projects_on(piece, Float64(x), Float64(y), _WALL_FND_JOIN_M) !== nothing &&
            return true
    end
    return false
end

"""Station from `p1` when `(x, y)` lands on the piece within `lateral`, else nothing."""
function _projects_on(piece, x, y, lateral)
    x1, y1 = piece.p1
    x2, y2 = piece.p2
    dx, dy = x2 - x1, y2 - y1
    L = hypot(dx, dy)
    L < _WALL_FND_JOIN_M && return nothing
    t = ((x - x1) * dx + (y - y1) * dy) / (L * L)
    t < -_WALL_FND_JOIN_M / L && return nothing
    t > 1 + _WALL_FND_JOIN_M / L && return nothing
    px = x1 + clamp(t, 0.0, 1.0) * dx
    py = y1 + clamp(t, 0.0, 1.0) * dy
    hypot(px - x, py - y) > lateral && return nothing
    return clamp(t, 0.0, 1.0) * L
end

# ── Reactions ───────────────────────────────────────────────────────────────

"""One base node offered to the piece it sits on."""
struct GradeWallNode
    id::UInt64
    wall_index::Int
    x::Float64
    y::Float64
    pu::Float64
    ps::Float64
end

"""
Put each node on one piece. A node that lands on two pieces, the shared
corner, goes to the longer piece so the reaction is not counted twice.

Returns `(samples, owners, piece_ids)`. `samples[k]` is `(station, pu, ps)`
in metres and newtons, and `piece_ids[k]` is the node id of each sample in
that same order. `owners[id]` is the piece index that kept the node.
"""
function assign_grade_wall_nodes(pieces::Vector{WallFoundationPiece},
                                 nodes::Vector{GradeWallNode},
                                 thickness_m::AbstractVector{<:Real})
    owners = Dict{UInt64, Tuple{Int, Float64, Float64, Float64}}()
    length_of = [hypot(p.p2[1] - p.p1[1], p.p2[2] - p.p1[2]) for p in pieces]
    for node in nodes
        best = nothing
        for (k, piece) in enumerate(pieces)
            piece.wall_index == node.wall_index || continue
            tw = thickness_m[piece.wall_index]
            s = _projects_on(piece, node.x, node.y, max(tw, 0.2))
            s === nothing && continue
            if best === nothing || length_of[k] > best[2] + _WALL_FND_JOIN_M ||
               (abs(length_of[k] - best[2]) <= _WALL_FND_JOIN_M && k < best[1])
                best = (k, length_of[k], s)
            end
        end
        best === nothing && continue
        k, _, s = best
        prev = get(owners, node.id, nothing)
        if prev === nothing || length_of[k] > length_of[prev[1]] + _WALL_FND_JOIN_M
            owners[node.id] = (k, s, node.pu, node.ps)
        end
    end
    samples = [Tuple{Float64, Float64, Float64}[] for _ in pieces]
    piece_ids = [UInt64[] for _ in pieces]
    for (id, (k, s, pu, ps)) in owners
        push!(samples[k], (s, pu, ps))
        push!(piece_ids[k], id)
    end
    return samples, owners, piece_ids
end

"""
    collect_grade_wall_groups(struc) → Vector of (group, legs, support indices)

Grade walls are the piers with a base node at the support elevation. Factored
reactions are the solved node reactions. Service reactions are unfactored D+L,
the same solve the column demands use. A column node on a wall is listed in
the group's support indices and is not also a column load.
"""
function collect_grade_wall_groups(struc)
    mesh = struc.wall_mesh
    isempty(mesh.piers) && return _empty_grade_groups()
    model = struc.asap_model
    model.processed || throw(ArgumentError(
        "ASAP model not solved. Call solve! before reading wall reactions."))
    grade_z = _grade_elevation_m(struc)
    grade_z === nothing && return _empty_grade_groups()

    base_of = Dict{Int, Vector{Asap.Node}}()
    for pier in mesh.piers
        nodes = Asap.Node[]
        seen = Set{UInt64}()
        for sh in pier.shells
            for nd in sh.nodes
                id = objectid(nd)
                id in seen && continue
                abs(ustrip(u"m", nd.position[3]) - grade_z) > WALL_CUT_ZTOL_M && continue
                push!(seen, id)
                push!(nodes, nd)
            end
        end
        isempty(nodes) && continue
        base_of[pier.wall_index] = nodes
    end
    isempty(base_of) && return _empty_grade_groups()

    indices = sort!(collect(keys(base_of)))
    groups = classify_wall_foundation_groups(struc.walls, indices)
    isempty(groups) && return _empty_grade_groups()

    R_s = _service_reactions(struc)
    grade_nodes = GradeWallNode[]
    nodes_by_id = Dict{UInt64, Asap.Node}()
    for (wi, nodes) in base_of
        for nd in nodes
            id = objectid(nd)
            pu = ustrip(u"N", nd.reaction[3])
            ps = R_s[nd.globalID[3]]
            x = ustrip(u"m", nd.position[1])
            y = ustrip(u"m", nd.position[2])
            push!(grade_nodes, GradeWallNode(id, wi, x, y, pu, ps))
            nodes_by_id[id] = nd
        end
    end

    pieces = WallFoundationPiece[]
    ranges = UnitRange{Int}[]
    for group in groups
        a = length(pieces) + 1
        append!(pieces, group.pieces)
        push!(ranges, a:length(pieces))
    end
    thick = [ustrip(u"m", w.thickness) for w in struc.walls]
    samples, owners, piece_ids = assign_grade_wall_nodes(pieces, grade_nodes, thick)
    owner_piece = Dict{UInt64, Int}(id => rec[1] for (id, rec) in owners)
    piece_nodes = [[nodes_by_id[id] for id in ids] for ids in piece_ids]

    Leg = StructuralSizer.WallLineDemand
    out = NamedTuple{(:group, :legs, :support_indices, :service_cases, :strength_cases),
                     Tuple{WallFoundationGroup, Vector{Leg}, Vector{Int},
                           Vector{Vector{Leg}}, Vector{Vector{Leg}}}}[]
    for (g, group) in enumerate(groups)
        legs = _legs_from_samples(struc, pieces[ranges[g]], samples[ranges[g]])
        isempty(legs) && continue
        owned = Set(k for k in ranges[g])
        supports = Int[]
        for (i, supp) in enumerate(struc.supports)
            id = objectid(model.nodes[supp.node_idx])
            get(owner_piece, id, 0) in owned || continue
            push!(supports, i)
        end
        service_cases, strength_cases = _wall_combination_cases(
            struc, pieces[ranges[g]], samples[ranges[g]], piece_nodes[ranges[g]])
        push!(out, (group = group, legs = legs, support_indices = supports,
                    service_cases = service_cases, strength_cases = strength_cases))
    end
    return out
end

_empty_grade_groups() = NamedTuple[]

function _grade_elevation_m(struc)
    vs = get(struc.skeleton.groups_vertices, :support, Int[])
    isempty(vs) && return nothing
    geom = struc.skeleton.geometry
    geom === nothing && return nothing
    return minimum(geom.vertex_coords[v, 3] for v in vs)
end

function _group_wall_indices(group)
    Set(piece.wall_index for piece in group.pieces)
end

"""
Length of `piece` that is concrete at the base, in metres.

An opening counts only when its sill is at the base (`z0` within a millimetre
of the story). A window with a sill leaves concrete at the joint. Overlapping
openings are counted once.
"""
function _base_solid_length(wall, piece)
    dx = wall.x2 - wall.x1
    dy = wall.y2 - wall.y1
    L = hypot(dx, dy)
    L <= 1e-9 && return 0.0
    station(p) = ((p[1] - wall.x1) * dx + (p[2] - wall.y1) * dy) / L
    a, b = minmax(station(piece.p1), station(piece.p2))
    span = b - a
    span <= 0 && return 0.0
    gaps = Tuple{Float64, Float64}[]
    for op in wall.openings
        op.z0 <= 1e-3 && op.height > 1e-3 || continue
        lo = max(a, op.s0)
        hi = min(b, op.s0 + op.width)
        hi - lo > 1e-6 && push!(gaps, (lo, hi))
    end
    sort!(gaps)
    lost = 0.0
    cursor = a
    for (lo, hi) in gaps
        lo = max(lo, cursor)
        hi > lo && (lost += hi - lo)
        cursor = max(cursor, hi)
    end
    return max(span - lost, 0.0)
end

function _legs_from_samples(struc, pieces, samples)
    walls = struc.walls
    legs = StructuralSizer.WallLineDemand[]
    for (k, piece) in enumerate(pieces)
        smp = samples[k]
        wall = walls[piece.wall_index]
        rows = isempty(smp) ? [(_piece_length(piece) / 2, 0.0, 0.0)] : smp
        line = StructuralSizer.WallLineSample{typeof(1.0u"m"), typeof(1.0u"N")}[
            StructuralSizer.WallLineSample(s * u"m", pu * u"N", ps * u"N")
            for (s, pu, ps) in rows]
        push!(legs, StructuralSizer.WallLineDemand(
            piece.wall_index,
            (piece.p1[1] * u"m", piece.p1[2] * u"m"),
            (piece.p2[1] * u"m", piece.p2[2] * u"m"),
            wall.thickness, _stacked_wall_height(wall), line;
            solid_length = _base_solid_length(wall, piece) * u"m"))
    end
    Ps = sum(ustrip(u"N", smp.Ps) for leg in legs for smp in leg.samples)
    Ps > 1.0 || return StructuralSizer.WallLineDemand[]
    return legs
end

"""
One wall-line demand vector per service combination and per strength combination.

Station order matches the gravity samples. A combination in net uplift is an
empty vector at that index, so it stays aligned with the column actions.
Empty when lateral reactions were not stored.
"""
function _wall_combination_cases(struc, pieces, samples, nodes)
    struc.foundation_lateral === nothing && return (
        Vector{StructuralSizer.WallLineDemand}[],
        Vector{StructuralSizer.WallLineDemand}[])
    actions = Tuple[]
    for nds in nodes
        for nd in nds
            a = node_foundation_actions(struc, nd)
            a === nothing && return (
                Vector{StructuralSizer.WallLineDemand}[],
                Vector{StructuralSizer.WallLineDemand}[])
            push!(actions, a)
        end
    end
    isempty(actions) && return (
        Vector{StructuralSizer.WallLineDemand}[],
        Vector{StructuralSizer.WallLineDemand}[])
    labels(xs) = [x.label for x in xs]
    for a in actions
        (length(a.service) == length(actions[1].service) &&
         length(a.strength) == length(actions[1].strength) &&
         labels(a.service) == labels(actions[1].service) &&
         labels(a.strength) == labels(actions[1].strength)) ||
            throw(ArgumentError(
                "Grade-wall nodes do not share ASCE 7 combination labels."))
    end
    service = [_legs_from_samples(struc, pieces, _samples_at(samples, actions, k, :service))
               for k in eachindex(actions[1].service)]
    strength = [_legs_from_samples(struc, pieces, _samples_at(samples, actions, k, :strength))
                for k in eachindex(actions[1].strength)]
    return service, strength
end

"""Sample rows with combination `k`'s vertical force in both `Pu` and `Ps`."""
function _samples_at(samples, actions, k, kind)
    idx = 1
    out = [Tuple{Float64, Float64, Float64}[] for _ in samples]
    for (piece, rows) in enumerate(samples)
        for (s, _, _) in rows
            a = actions[idx]
            idx += 1
            P = kind === :service ? a.service[k].P : a.strength[k].P
            push!(out[piece], (s, P, P))
        end
    end
    return out
end

_piece_length(piece) = hypot(piece.p2[1] - piece.p1[1], piece.p2[2] - piece.p1[2])

"""
Design every grade-wall group and return the foundations plus the column
supports those groups take. An enclosed column joins its cell mat. A column
on the wall line is already in the line load, so it is not punched again.
"""
function design_grade_wall_foundations(struc, demands, soil, opts)
    collected = collect_grade_wall_groups(struc)
    isempty(collected) && return Foundation[], Set{Int}()
    opts.code == :aci || throw(ArgumentError(
        "Grade wall foundations follow ACI 318-11; the active code is $(opts.code)."))

    skip = Set{Int}()
    built = Foundation[]
    claimed = Set{Int}()
    mat = opts.spread_params.material
    for item in collected
        group, legs = item.group, item.legs
        on_wall = item.support_indices
        if group.kind == :mat
            enclosed = Int[]
            for i in eachindex(struc.supports)
                i in on_wall && continue
                i in claimed && continue
                x, y = _support_plan_m(struc, i)
                point_in_wall_group(group, x, y) || continue
                push!(enclosed, i)
            end
            union!(claimed, enclosed, on_wall)
            col_demands = StructuralSizer.FoundationDemand[demands[i] for i in enclosed]
            positions = _support_positions_xy(struc, enclosed)
            column_service, column_strength = _aligned_column_actions(struc, enclosed)
            # A column without stored actions would mix its gravity Pu with a
            # seismic wall line. Keep the gravity mat in that case.
            wall_service = item.service_cases
            wall_strength = item.strength_cases
            if !isempty(enclosed) && isempty(column_service)
                wall_service = Vector{StructuralSizer.WallLineDemand}[]
                wall_strength = Vector{StructuralSizer.WallLineDemand}[]
            end
            loads = StructuralSizer.footing_loads(; demands=col_demands, positions=positions,
                column_service=column_service, column_strength=column_strength,
                walls=legs, wall_service=wall_service, wall_strength=wall_strength)
            result = StructuralSizer.design_footing(
                StructuralSizer.MatFoundation(), loads, soil; opts = opts.mat_params)
            idxs = vcat(enclosed, on_wall)
            push!(built, _wall_foundation(idxs, result, :mat, _group_wall_indices(group), mat))
        else
            union!(claimed, on_wall)
            loads = StructuralSizer.footing_loads(; walls=legs,
                wall_service=item.service_cases, wall_strength=item.strength_cases)
            result = StructuralSizer.design_footing(
                StructuralSizer.StripFooting(), loads, soil; opts = opts.strip_params)
            push!(built, _wall_foundation(on_wall, result, :wall_strip,
                                           _group_wall_indices(group), mat))
        end
        union!(skip, on_wall)
    end
    union!(skip, claimed)
    return built, skip
end

function _support_plan_m(struc, i)
    v = struc.skeleton.vertices[struc.supports[i].vertex_idx]
    c = Meshes.coords(v)
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function _wall_foundation(support_indices, result, kind, wall_indices, mat)
    volumes = _compute_foundation_volumes(result, mat.concrete, mat.rebar)
    return Foundation(collect(Int, support_indices), result;
                      foundation_type = kind,
                      wall_indices = sort!(collect(Int, wall_indices)),
                      volumes = volumes)
end
