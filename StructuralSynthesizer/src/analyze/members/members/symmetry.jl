# =============================================================================
# Geometric symmetry of the framing graph (member-group orbits)
# =============================================================================
#
# Finds the finite isometry automorphism group of the labeled framing skeleton
# — rotations and reflections about the building's vertical axis that map the
# vertex set to itself AND preserve every edge-group role (`:beams`, `:columns`,
# `:joists`, …) — and from it the ORBITS of member groups (which groups are
# geometric mirror / rotation twins of each other).
#
# This is the proposer for the symmetry-aware sizing policy
# (`docs/sizing-map/symmetry-policy.md`). Pure geometry: it runs no analysis and
# changes no section. Its only consumer is a reflection-invariant *demand*
# symmetrization (orbit-elementwise-max), which makes mirror-twin members size
# identically and so removes path-dependent chirality (e.g. `star/e0c0`).
#
# Validated read-only across the full SDF corpus by
# `scripts/runners/plan_symmetry_scan.jl` (memory `expe-471c0edc`): 96% of plans
# carry exploitable symmetry, ~3.5x mean beam-orbit collapse.
#
# Algorithm (standard symmetry detection of a finite labeled point set):
#   * Every isometry fixing the set fixes the centroid, so (restricted to the
#     horizontal plane) it is a rotation about the centroid or a reflection
#     through it; the vertical coordinate is carried along unchanged.
#   * Candidates come from the farthest vertex: any symmetry maps it to an
#     equally far vertex, giving O(n) candidate rotations (angle differences) and
#     O(n) candidate reflections (axis = angle bisector).
#   * A candidate is accepted iff it permutes the vertices (within `tol`) AND
#     maps every edge to an edge in the SAME edge group (role-preserving).
#   * Member-group orbits are the union-find classes of group ids under the
#     accepted permutations acting on each group's edges.

"""Round to the match grid and normalize signed zero: a mirror can send a
centerline coordinate to `-0.0`, and `Dict` treats `-0.0` and `0.0` as distinct
keys (`isequal(-0.0, 0.0) === false`), which would silently drop the match."""
@inline _sym_rz(v::Real) = (r = round(float(v); digits = 6); r == 0.0 ? 0.0 : r)

"""`(x, y, z)` of a skeleton vertex in meters, from the geometry cache when
present, else from the raw `Meshes` point."""
function _vertex_xyz_m(skel, vi::Int)
    if skel.geometry !== nothing
        vc = skel.geometry.vertex_coords
        z = size(vc, 2) >= 3 ? vc[vi, 3] : 0.0
        return (vc[vi, 1], vc[vi, 2], z)
    end
    c = Meshes.coords(skel.vertices[vi])
    return (to_meters(c.x), to_meters(c.y), to_meters(c.z))
end

"""Endpoint vertex indices of edge `e`, as an ascending tuple."""
@inline function _edge_ends(skel, e::Int)
    a, b = skel.edge_indices[e]
    return a < b ? (a, b) : (b, a)
end

"""
    skeleton_automorphisms(skel; tol = 1e-6) -> Vector{Vector{Int}}

Vertex-index permutations (including the identity first) of every isometry of
the horizontal footprint that maps the vertex set to itself **and** preserves
each `groups_edges` role. Each permutation `π` satisfies `π[identity] = identity`
and, for every edge in group `g`, maps it to another edge in group `g`.
"""
function skeleton_automorphisms(skel; tol::Float64 = 1e-6)
    nv = length(skel.vertices)
    nv == 0 && return [Int[]]

    xyz = [_vertex_xyz_m(skel, i) for i in 1:nv]
    cx = sum(p -> p[1], xyz) / nv
    cy = sum(p -> p[2], xyz) / nv
    # Centered horizontal coords for the transform; z is carried unchanged.
    P = [(xyz[i][1] - cx, xyz[i][2] - cy) for i in 1:nv]
    lookup = Dict{NTuple{3, Float64}, Int}()
    for i in 1:nv
        lookup[(_sym_rz(P[i][1]), _sym_rz(P[i][2]), _sym_rz(xyz[i][3]))] = i
    end

    # Precompute each edge group's endpoint-pair membership so a candidate can be
    # rejected the moment it moves an edge out of its role.
    edge_by_ends = Dict{NTuple{2, Int}, Int}()
    for e in 1:length(skel.edge_indices)
        edge_by_ends[_edge_ends(skel, e)] = e
    end
    group_edges = Tuple{Vector{NTuple{2, Int}}, Set{NTuple{2, Int}}}[]
    for (_, eidxs) in skel.groups_edges
        isempty(eidxs) && continue
        ends = [_edge_ends(skel, e) for e in eidxs]
        push!(group_edges, (ends, Set(ends)))
    end

    # Candidate isometries seeded from the farthest-from-centroid vertex: any
    # symmetry maps it to an equally far vertex.
    r = [hypot(P[i][1], P[i][2]) for i in 1:nv]
    i0 = argmax(r); r0 = r[i0]
    identity = collect(1:nv)
    r0 < tol && return [identity]      # degenerate (all vertices stacked)
    θ0 = atan(P[i0][2], P[i0][1])
    far = [i for i in 1:nv if abs(r[i] - r0) <= tol]

    cands = Matrix{Float64}[[1.0 0.0; 0.0 1.0]]
    for j in far
        θj = atan(P[j][2], P[j][1])
        a = θj - θ0                                   # rotation i0 -> j
        push!(cands, [cos(a) -sin(a); sin(a) cos(a)])
        φ = (θ0 + θj) / 2                             # reflection axis i0 -> j
        push!(cands, [cos(2φ) sin(2φ); sin(2φ) -cos(2φ)])
    end

    perms = Vector{Int}[]
    seen = Set{NTuple{4, Float64}}()
    for M in cands
        key = (_sym_rz(M[1, 1]), _sym_rz(M[1, 2]), _sym_rz(M[2, 1]), _sym_rz(M[2, 2]))
        key in seen && continue
        push!(seen, key)
        perm = _induced_vertex_perm(M, P, xyz, lookup)
        perm === nothing && continue
        _preserves_edge_groups(perm, group_edges, edge_by_ends) || continue
        push!(perms, perm)
    end
    return perms
end

"""Vertex permutation from isometry `M` (2×2, horizontal), or `nothing` if it is
not a vertex bijection within the match grid."""
function _induced_vertex_perm(M, P, xyz, lookup)
    n = length(P)
    perm = Vector{Int}(undef, n)
    seen = falses(n)
    @inbounds for i in 1:n
        x, y = P[i]
        qx = M[1, 1] * x + M[1, 2] * y
        qy = M[2, 1] * x + M[2, 2] * y
        j = get(lookup, (_sym_rz(qx), _sym_rz(qy), _sym_rz(xyz[i][3])), 0)
        (j == 0 || seen[j]) && return nothing
        perm[i] = j; seen[j] = true
    end
    return perm
end

"""Does `perm` map every edge of each group to an edge of the SAME group?"""
function _preserves_edge_groups(perm, group_edges, edge_by_ends)
    for (ends, ends_set) in group_edges
        for (a, b) in ends
            pa, pb = perm[a], perm[b]
            img = pa < pb ? (pa, pb) : (pb, pa)
            e = get(edge_by_ends, img, 0)
            (e != 0 && img in ends_set) || return false
        end
    end
    return true
end

"""
    member_group_orbits(struc; member_type = :beams, tol = 1e-6)
        -> Vector{Vector{UInt64}}

Partition the member-group ids of `member_type` into geometric orbits under the
skeleton's automorphism group: two groups share an orbit iff some symmetry maps
one group's members onto the other's. Singleton groups (no twin) appear as
one-element orbits. Orbits and the ids within them are sorted for determinism.

Rebuilds `struc.member_groups` for `member_type` (same as `member_group_demands`).
"""
function member_group_orbits(struc::BuildingStructure; member_type::Symbol = :beams,
                             tol::Float64 = 1e-6)
    skel = struc.skeleton
    build_member_groups!(struc; member_type = member_type)
    member_array = member_type == :columns ? struc.columns :
                   member_type == :struts ? struc.struts : struc.beams

    # Map every member edge to the group that owns it, and index edges by ends.
    edge_to_gid = Dict{Int, UInt64}()
    for (gid, mg) in struc.member_groups
        for m_idx in mg.member_indices
            for seg_idx in segment_indices(member_array[m_idx])
                edge_to_gid[struc.segments[seg_idx].edge_idx] = gid
            end
        end
    end
    edge_by_ends = Dict{NTuple{2, Int}, Int}()
    for (e, gid) in edge_to_gid
        edge_by_ends[_edge_ends(skel, e)] = e
    end

    gids = collect(keys(struc.member_groups))
    pos = Dict(g => k for (k, g) in enumerate(gids))
    parent = collect(1:length(gids))
    find(x) = (parent[x] == x ? x : (parent[x] = find(parent[x])))
    unite(a, b) = (parent[find(a)] = find(b))

    for perm in skeleton_automorphisms(skel; tol = tol)
        isempty(perm) && continue
        for (e, gid) in edge_to_gid
            a, b = _edge_ends(skel, e)
            pa, pb = perm[a], perm[b]
            img = pa < pb ? (pa, pb) : (pb, pa)
            e_img = get(edge_by_ends, img, 0)
            e_img == 0 && continue
            gid_img = edge_to_gid[e_img]
            unite(pos[gid], pos[gid_img])
        end
    end

    buckets = Dict{Int, Vector{UInt64}}()
    for (k, gid) in enumerate(gids)
        push!(get!(buckets, find(k), UInt64[]), gid)
    end
    orbits = [sort(v) for v in values(buckets)]
    sort!(orbits; by = first)
    return orbits
end
