# =============================================================================
# Semirigid floor: in-plane (membrane) slab mesh
# =============================================================================
#
# ASCE 7-22 §12.3.1 and §12.7.3 (corpus: asce-7-22, PDF pages 179 and 184):
# a diaphragm that is not idealized as rigid or flexible is modeled with its
# stiffness. The slab here is a membrane: it carries in-plane force only, so
# gravity keeps its tributary path to the beams. The mesh is built after the
# walls, and every wall or frame node lying on a slab face edge is a mesh node,
# so the floor and the walls share their nodes along the whole wall top.

"""
Elements across the least plan width of a floor.

# Engineering judgment
FEA discretisation, not a code provision. Linear membrane triangles are stiff
in in-plane bending. On an in-plane cantilever (`scripts/runners/
membrane_mesh_convergence.jl`), 8 elements across the depth read 95% of the
Timoshenko tip displacement, 12 read 98%, and 16 read 99%, for span-to-depth
ratios 1 to 4.
"""
const SEMIRIGID_MESH_DIV = 12

"Nodes within this distance [m] of a face edge are on that edge."
const _SEMIRIGID_NODE_TOL_M = 1e-3

"""One floor of a semirigid diaphragm: its membrane triangles and nodes."""
struct SemirigidFloor
    "Floor elevation [m]."
    elevation_m::Float64
    "Target element edge length [m]."
    mesh_size_m::Float64
    "Membrane triangles of this floor."
    shells::Vector{Asap.ShellTri3}
    "Skeleton face each triangle meshes, parallel to `shells`."
    face_of_shell::Vector{Int}
    "Every node of the floor mesh, once."
    nodes::Vector{Asap.Node}
end

"""Seismic-system wall-top nodes at one floor, with their tributary wall length [m]."""
struct SemirigidDriftNodes
    elevation_m::Float64
    nodes::Vector{Asap.Node}
    weights::Vector{Float64}
end

"""
Semirigid diaphragm: the membrane mesh of every floor that carries a slab.

`base_E_Pa` is the modulus of each triangle before `stiffness_factor`, so the
in-plane stiffness can be set again without meshing again
([`set_semirigid_stiffness!`](@ref)). `plan_axis` and `drift_nodes` are set by
the lateral stage from the declared seismic system ([`semirigid_sfrs!`](@ref)).
"""
mutable struct SemirigidDiaphragmLayout
    floors::Vector{SemirigidFloor}
    base_E_Pa::IdDict{Asap.ShellTri3, Float64}
    stiffness_factor::Float64
    plan_axis::Union{Nothing, NTuple{2, Float64}}
    drift_nodes::Vector{SemirigidDriftNodes}
end

"""Every membrane triangle of the layout."""
semirigid_shells(layout::SemirigidDiaphragmLayout) =
    reduce(vcat, (f.shells for f in layout.floors); init=Asap.ShellTri3[])

"""
    set_semirigid_stiffness!(layout, factor) -> layout

Set every membrane triangle's modulus to `factor` times its slab modulus. The
caller reprocesses the model.
"""
function set_semirigid_stiffness!(layout::SemirigidDiaphragmLayout, factor::Real)
    (isfinite(factor) && factor > 0) || throw(ArgumentError(
        "semirigid diaphragm: the stiffness factor must be positive; got $factor."))
    for (sh, E) in layout.base_E_Pa
        sh.E = Float64(factor) * E
    end
    layout.stiffness_factor = Float64(factor)
    return layout
end

_xy(nd::Asap.Node) = (ustrip(u"m", nd.position[1]), ustrip(u"m", nd.position[2]))
_z(nd::Asap.Node) = ustrip(u"m", nd.position[3])

"""
    _create_semirigid_floors(struc, nodes, pool; factor, props) -> SemirigidDiaphragmLayout

Mesh every slab face as membrane triangles, floor by floor.

`nodes` are the frame nodes by skeleton vertex. `pool` holds every node a floor
edge may pass through: frame nodes and wall-shell nodes. A pool node within
1 mm of a face edge, at the face's elevation, becomes a node of that edge.
Edges are subdivided once and shared by both faces that meet there. A node the
mesh creates moves only in plan: its `w`, `θx`, `θy`, and `θz` are fixed,
because a membrane gives them no stiffness.
"""
function _create_semirigid_floors(struc::BuildingStructure, nodes::Vector{Asap.Node},
                                  pool::Vector{Asap.Node}; factor::Real, props::NamedTuple)
    skel = struc.skeleton
    faces_by_z = Dict{Int, Vector{Tuple{Int, Any}}}()
    for slab in struc.slabs
        for ci in slab.cell_indices
            face = struc.cells[ci].face_idx
            verts = skel.face_vertex_indices[face]
            zs = [_z(nodes[v]) for v in verts]
            maximum(zs) - minimum(zs) <= _SEMIRIGID_NODE_TOL_M || throw(ArgumentError(
                "semirigid diaphragm: face $face is not level ($(extrema(zs)) m). " *
                "A membrane floor is flat."))
            key = round(Int, zs[1] * 1000)
            push!(get!(faces_by_z, key, Tuple{Int, Any}[]), (face, slab))
        end
    end
    isempty(faces_by_z) && throw(ArgumentError(
        "semirigid diaphragm: the structure has no slab faces to mesh."))

    E_slab = uconvert(u"Pa", props.E)
    base_E = IdDict{Asap.ShellTri3, Float64}()
    floors = SemirigidFloor[]
    for key in sort!(collect(keys(faces_by_z)))
        z = key / 1000
        items = faces_by_z[key]
        level_pool = [nd for nd in pool if abs(_z(nd) - z) <= _SEMIRIGID_NODE_TOL_M]
        pts = NTuple{2, Float64}[]
        for (face, _) in items, v in skel.face_vertex_indices[face]
            push!(pts, _xy(nodes[v]))
        end
        width = min(maximum(p[1] for p in pts) - minimum(p[1] for p in pts),
                    maximum(p[2] for p in pts) - minimum(p[2] for p in pts))
        width > 0 || throw(ArgumentError(
            "semirigid diaphragm: the floor at $z m has no plan width."))
        h = width / SEMIRIGID_MESH_DIV
        edge_cache = Dict{Tuple{Int, Int}, Vector{Asap.Node}}()
        shells = Asap.ShellTri3[]
        face_of = Int[]
        for (face, slab) in items
            t = thickness(slab) * props.t_factor
            for sh in _mesh_semirigid_face(skel, face, nodes, level_pool, edge_cache, h,
                                            t, factor * E_slab, props.ν)
                base_E[sh] = ustrip(u"Pa", E_slab)
                push!(shells, sh)
                push!(face_of, face)
            end
        end
        seen = Set{UInt64}()
        floor_nodes = Asap.Node[]
        for sh in shells, nd in sh.nodes
            objectid(nd) in seen && continue
            push!(seen, objectid(nd))
            push!(floor_nodes, nd)
        end
        push!(floors, SemirigidFloor(z, h, shells, face_of, floor_nodes))
    end
    return SemirigidDiaphragmLayout(floors, base_E, Float64(factor), nothing,
                                    SemirigidDriftNodes[])
end

"""A node the floor mesh creates: free in plan, fixed out of plane."""
_membrane_node(x, y, z) =
    Asap.Node([x * u"m", y * u"m", z * u"m"], [true, true, false, false, false, false])

"""
Nodes along skeleton edge `va → vb`, endpoints included, in that order.

Pool nodes on the edge are kept. One joint is listed once for every triangle
that uses it, and that repeated reference is one station. A different node
within 1 mm of a station throws. A gap longer than `h` between consecutive
nodes is split evenly. The result is cached under the unordered vertex pair,
so the two faces that share an edge share its nodes.
"""
function _semirigid_edge_nodes!(cache, nodes, pool, va, vb, h)
    key = minmax(va, vb)
    if !haskey(cache, key)
        a, b = nodes[key[1]], nodes[key[2]]
        (ax, ay), (bx, by) = _xy(a), _xy(b)
        z = 0.5 * (_z(a) + _z(b))
        L = hypot(bx - ax, by - ay)
        L > 0 || throw(ArgumentError(
            "semirigid diaphragm: a slab face has a zero-length edge."))
        ex, ey = (bx - ax) / L, (by - ay) / L
        stations = Tuple{Float64, Asap.Node}[(0.0, a), (L, b)]
        for nd in pool
            (nd === a || nd === b) && continue
            x, y = _xy(nd)
            s = (x - ax) * ex + (y - ay) * ey
            d = abs(-(x - ax) * ey + (y - ay) * ex)
            (d <= _SEMIRIGID_NODE_TOL_M && _SEMIRIGID_NODE_TOL_M < s < L - _SEMIRIGID_NODE_TOL_M) || continue
            occupied = findfirst(st -> abs(st[1] - s) <= _SEMIRIGID_NODE_TOL_M, stations)
            if occupied !== nothing
                stations[occupied][2] === nd && continue
                throw(ArgumentError(
                    "semirigid diaphragm: two nodes lie within 1 mm of each other at " *
                    "($x, $y, $z) m on a slab edge."))
            end
            push!(stations, (s, nd))
        end
        sort!(stations; by=first)
        out = Asap.Node[]
        for k in 1:(length(stations) - 1)
            s0, n0 = stations[k]
            s1, _ = stations[k + 1]
            push!(out, n0)
            m = ceil(Int, (s1 - s0) / h - 1e-9)
            for j in 1:(m - 1)
                s = s0 + (s1 - s0) * j / m
                push!(out, _membrane_node(ax + s * ex, ay + s * ey, z))
            end
        end
        push!(out, last(stations)[2])
        cache[key] = out
    end
    seq = cache[key]
    return va == key[1] ? seq : reverse(seq)
end

"""Membrane triangles of one slab face."""
function _mesh_semirigid_face(skel, face, nodes, pool, edge_cache, h, t, E, ν)
    verts = skel.face_vertex_indices[face]
    nv = length(verts)
    boundary = Asap.Node[]
    for k in 1:nv
        seq = _semirigid_edge_nodes!(edge_cache, nodes, pool, verts[k], verts[mod1(k + 1, nv)], h)
        append!(boundary, seq[1:(end - 1)])
    end
    poly = [_xy(nd) for nd in boundary]
    area2 = sum(poly[i][1] * poly[mod1(i + 1, length(poly))][2] -
                poly[mod1(i + 1, length(poly))][1] * poly[i][2] for i in eachindex(poly))
    abs(area2) > 0 || throw(ArgumentError(
        "semirigid diaphragm: slab face $face has zero area."))
    if area2 < 0
        reverse!(boundary)
        reverse!(poly)
    end
    z = _z(first(boundary))

    corner = [_xy(nodes[v]) for v in verts]
    on_boundary = Set(objectid(nd) for nd in boundary)
    fixed = Asap.Node[]
    for nd in pool
        objectid(nd) in on_boundary && continue
        x, y = _xy(nd)
        _point_in_polygon_xy(x, y, corner) || continue
        _distance_to_polygon(x, y, poly) > _SEMIRIGID_NODE_TOL_M || continue
        push!(fixed, nd)
    end

    holes = face_opening_loops(skel, face)
    interior = NTuple{2, Float64}[]
    xs = [p[1] for p in poly]
    ys = [p[2] for p in poly]
    for x in range(minimum(xs) + h, maximum(xs) - h / 2; step=h),
        y in range(minimum(ys) + h, maximum(ys) - h / 2; step=h)
        _point_in_polygon_xy(x, y, poly) || continue
        any(loop -> _point_in_polygon_xy(x, y, loop), holes) && continue
        _distance_to_polygon(x, y, poly) >= h / 2 || continue
        any(nd -> hypot(_xy(nd)[1] - x, _xy(nd)[2] - y) < h / 2, fixed) && continue
        push!(interior, (x, y))
    end

    all_nodes = vcat(boundary, fixed, [_membrane_node(p[1], p[2], z) for p in interior])
    outer = vcat(collect(1:length(boundary)), 1)
    hole_area = 0.0
    sections = Vector{Int}[]
    for raw in holes
        loop = Asap._as_hole_loop(raw)
        isempty(loop) && continue
        ids = Int[]
        for p in loop
            push!(all_nodes, _membrane_node(p[1], p[2], z))
            push!(ids, length(all_nodes))
        end
        push!(ids, ids[1])
        push!(sections, ids)
        hole_area += abs(_polygon_area_m2(NTuple{2, Float64}[(p[1], p[2]) for p in loop]))
    end
    points = [_xy(nd) for nd in all_nodes]
    # Hole edges are constrained segments, the same pair set the shell mesher
    # passes. Triangles inside a hole are dropped below. A face with no hole
    # is the single outer curve, as before.
    segments = Set{Tuple{Int, Int}}()
    for ids in sections
        for k in 1:(length(ids) - 1)
            push!(segments, (ids[k], ids[k + 1]))
        end
    end
    tri = isempty(segments) ?
        Asap.DT.triangulate(points; boundary_nodes=[outer], rng=Asap._mesh_rng()) :
        Asap.DT.triangulate(points; boundary_nodes=[outer], segments=segments, rng=Asap._mesh_rng())
    shells = Asap.ShellTri3[]
    for T in Asap.DT.each_solid_triangle(tri)
        i, j, k = Asap.DT.triangle_vertices(T)
        a, b, c = points[i], points[j], points[k]
        mid = ((a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3)
        any(loop -> _point_in_polygon_xy(mid[1], mid[2], loop), holes) && continue
        sh = Asap.ShellTri3((all_nodes[i], all_nodes[j], all_nodes[k]), t, E, ν;
                            id=:semirigid_diaphragm, membrane_only=true)
        Asap.populate_globalID!(sh)
        push!(shells, sh)
    end
    covered = sum(sh.area for sh in shells)
    face_area = abs(area2) / 2 - hole_area
    abs(covered - face_area) <= 1e-6 * max(1.0, face_area) || throw(ArgumentError(
        "semirigid diaphragm: the mesh of face $face covers $covered m² of $face_area m²."))
    return shells
end

"""Distance [m] from `(x, y)` to the closed polygon `poly`."""
function _distance_to_polygon(x, y, poly)
    best = Inf
    n = length(poly)
    for i in 1:n
        (ax, ay) = poly[i]
        (bx, by) = poly[mod1(i + 1, n)]
        dx, dy = bx - ax, by - ay
        L2 = dx^2 + dy^2
        s = L2 > 0 ? clamp(((x - ax) * dx + (y - ay) * dy) / L2, 0.0, 1.0) : 0.0
        best = min(best, hypot(x - ax - s * dx, y - ay - s * dy))
    end
    return best
end
