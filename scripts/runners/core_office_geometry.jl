#=
Skeleton for the four-story core office used by the scene runners.

3×3 bays of 8 m, four stories of 3.6 m. The four plan edges of the center bay
are walls on every story below the roof. Inside that bay, a lobby slab along
the south side stays in the floor, and the rest of the bay is three shafts
(two elevators and a stair) with no slab between them. The walls that bound
those shafts are plan edges in `:walls`. The roof face over the core stays
one slab. The opening is the missing shaft faces, not a hole cut into a
zero-area cell.

Dimensions are demo geometry, not a code minimum. The lobby is 2.5 m deep.
Each elevator shaft is 2.4 m wide and the stair is the remaining 3.2 m.
=#

using StructuralSynthesizer
using Meshes
using Unitful
import Graphs

const CORE_BAY = 8.0
const CORE_STORIES = 4
const CORE_STORY_H = 3.6
# South edge of the shafts, measured from the building origin. The lobby is
# the strip from y = CORE_BAY to this line.
const CORE_LOBBY_Y = 10.5
# Dividers, measured from the building origin. Elevator 1 is x = 8 to 10.4,
# elevator 2 is x = 10.4 to 12.8, and the stair is x = 12.8 to 16.
const CORE_ELEV_X = 10.4
const CORE_STAIR_X = 12.8

function core_office_skeleton()
    skel = gen_medium_office(3 * CORE_BAY * u"m", 3 * CORE_BAY * u"m", CORE_STORY_H * u"m",
                             3, 3, CORE_STORIES)
    x0, x1 = CORE_BAY, 2 * CORE_BAY
    corners = ((x0, x0), (x1, x0), (x1, x1), (x0, x1))
    edges = ((corners[1], corners[2]), (corners[2], corners[3]),
             (corners[3], corners[4]), (corners[4], corners[1]))
    claimed = 0
    for z in (ustrip(u"m", z) for z in skel.stories_z[1:end-1]), ((ax, ay), (bx, by)) in edges
        _claim_as_wall!(skel, _find_plan_edge(skel, ax, ay, z, bx, by))
        claimed += 1
    end
    claimed == 4 * CORE_STORIES ||
        error("core: claimed $claimed wall edges, expected $(4 * CORE_STORIES)")
    # The grid still has a column at each core corner. The walls are the
    # vertical structure there, so those stacks leave the column group.
    _drop_core_corner_columns!(skel)
    # Lobby slab along the south of the core, three shafts north of it, and
    # the walls between them. The roof stays one face.
    _shape_core!(skel)
    # Doors sit on the lobby face of the shafts, clear of the tee joints, and
    # one entrance sits on the south wall into the lobby. Sizes are the demo
    # geometry, not a code minimum.
    _core_doors!(skel)
    return skel
end

"""
Doors on every story that has the core walls.

The shaft wall runs from (8, 10.5) toward (16, 10.5). Each door is centered
on its own bay so it does not cross a divider: elevator doors are 1.1 m in
the 2.4 m bays, and the stair door is 1.0 m in the 3.2 m bay. The lobby
entrance is 1.8 m, centered on the south core wall from (8, 8) toward (16, 8).
"""
function _core_doors!(skel)
    elev_s0 = (CORE_ELEV_X - CORE_BAY - 1.1) / 2
    stair_s0 = (CORE_STAIR_X - CORE_BAY) + (2 * CORE_BAY - CORE_STAIR_X - 1.0) / 2
    entrance_s0 = (CORE_BAY - 1.8) / 2
    for story in 0:(CORE_STORIES - 1)
        z = story * CORE_STORY_H
        lobby_a = _vertex_at(skel, CORE_BAY, CORE_LOBBY_Y, z)
        lobby_b = _vertex_at(skel, 2 * CORE_BAY, CORE_LOBBY_Y, z)
        south_a = _vertex_at(skel, CORE_BAY, CORE_BAY, z)
        south_b = _vertex_at(skel, 2 * CORE_BAY, CORE_BAY, z)
        add_wall_opening!(skel, lobby_a, lobby_b, story,
                          WallOpening(elev_s0, 0.0, 1.1, 2.1, :door))
        add_wall_opening!(skel, lobby_a, lobby_b, story,
                          WallOpening(elev_s0 + (CORE_ELEV_X - CORE_BAY), 0.0, 1.1, 2.1, :door))
        add_wall_opening!(skel, lobby_a, lobby_b, story,
                          WallOpening(stair_s0, 0.0, 1.0, 2.1, :door))
        add_wall_opening!(skel, south_a, south_b, story,
                          WallOpening(entrance_s0, 0.0, 1.8, 2.1, :door))
    end
    return skel
end

function _vertex_at(skel, x, y, z; tol = 1e-3)
    found = 0
    for (i, v) in enumerate(skel.vertices)
        c = Meshes.coords(v)
        p = (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z))
        _near(p, (x, y, z), tol) || continue
        found == 0 || error("core: more than one vertex at ($x, $y, $z)")
        found = i
    end
    found == 0 && error("core: no vertex at ($x, $y, $z)")
    return found
end

"""
    _shape_core!(skel) -> Int

Turn each center bay below the roof into a lobby slab and three shafts.

The lobby occupies y = 8 m to `CORE_LOBBY_Y` across the bay and stays in the
floor group, so the wall on its north edge is a slab boundary. North of that
wall the bay has no face: the two elevator shafts and the stair are one void.
The west and east core walls are split where the lobby meets them, and three
interior walls are added. Each interior wall ends on another wall, so
`split_tee_junctions!` can share the corner nodes when the analysis mesh is
built. The roof face is left as the full bay.
"""
function _shape_core!(skel)
    roof_z = ustrip(u"m", skel.stories_z[end])
    x0, x1 = CORE_BAY, 2 * CORE_BAY
    bays = Tuple{Int, Float64}[]
    for (fi, vis) in enumerate(skel.face_vertex_indices)
        xs, ys, zs = _face_xyz(skel, vis)
        all(z -> abs(z - zs[1]) <= 1e-6, zs) || continue
        abs(zs[1] - roof_z) <= 1e-3 && continue
        all(x -> x0 - 1e-3 <= x <= x1 + 1e-3, xs) || continue
        all(y -> x0 - 1e-3 <= y <= x1 + 1e-3, ys) || continue
        push!(bays, (fi, zs[1]))
    end
    length(bays) == CORE_STORIES ||
        error("core: found $(length(bays)) center bays below the roof, expected $(CORE_STORIES)")
    for (fi, z) in bays
        story = round(Int, z / CORE_STORY_H)
        # The lobby meets the west and east walls mid-edge. Split those edges
        # so the lobby face and the office face each own their own piece.
        _split_wall_edge!(skel, x0, x0, x0, x1, x0, CORE_LOBBY_Y, z, story)
        _split_wall_edge!(skel, x1, x0, x1, x1, x1, CORE_LOBBY_Y, z, story)
        _add_wall!(skel, x0, CORE_LOBBY_Y, x1, CORE_LOBBY_Y, z, story)
        _add_wall!(skel, CORE_ELEV_X, CORE_LOBBY_Y, CORE_ELEV_X, x1, z, story)
        _add_wall!(skel, CORE_STAIR_X, CORE_LOBBY_Y, CORE_STAIR_X, x1, z, story)
        _retarget_lobby!(skel, fi, z)
    end
    # Interior walls and the west/east lobby splits live only below the roof,
    # so those plan points are missing at the roof elevation. The top-story
    # pier still reaches z = roof, and to_asap! will not mesh it unless each
    # column line has a vertex there.
    _seed_roof_wall_vertices!(skel)
    rebuild_geometry_cache!(skel)
    return length(bays)
end

"""
Copy every top-story wall endpoint onto the roof.

The roof face stays the full bay. These vertices are the column-line ends of
the piers below, including tee points that `split_tee_junctions!` will cut.
"""
function _seed_roof_wall_vertices!(skel)
    roof_z = ustrip(u"m", skel.stories_z[end])
    roof_story = length(skel.stories_z) - 1
    top_z = roof_z - CORE_STORY_H
    seen = NTuple{2, Float64}[]
    for ei in get(skel.groups_edges, :walls, Int[])
        v1, v2 = skel.edge_indices[ei]
        for v in (v1, v2)
            c = Meshes.coords(skel.vertices[v])
            abs(ustrip(u"m", c.z) - top_z) <= 1e-3 || continue
            xy = (ustrip(u"m", c.x), ustrip(u"m", c.y))
            any(p -> hypot(p[1] - xy[1], p[2] - xy[2]) <= 1e-3, seen) && continue
            push!(seen, xy)
            add_vertex!(skel, _point_m(skel, xy[1], xy[2], roof_z); level_idx=roof_story)
        end
    end
    return length(seen)
end

"""Plan coordinates of a face's vertices, in metres."""
function _face_xyz(skel, vis)
    xs = Float64[]
    ys = Float64[]
    zs = Float64[]
    for v in vis
        c = Meshes.coords(skel.vertices[v])
        push!(xs, ustrip(u"m", c.x))
        push!(ys, ustrip(u"m", c.y))
        push!(zs, ustrip(u"m", c.z))
    end
    return xs, ys, zs
end

"""Point in the same units as the skeleton's vertices."""
function _point_m(skel, x, y, z)
    c = Meshes.coords(skel.vertices[1])
    return Meshes.Point(x * unit(c.x), y * unit(c.y), z * unit(c.z))
end

"""
Split the wall edge from `(x1, y1)` to `(x2, y2)` at `(xm, ym)` on story `z`.

The original edge becomes the piece from its first stored end to the new
vertex. The other piece is a new `:walls` edge. Every face that used the
original edge keeps both pieces, so the office bay on the outside of the core
still spans the full side.
"""
function _split_wall_edge!(skel, x1, y1, x2, y2, xm, ym, z, story)
    va = _vertex_at(skel, x1, y1, z)
    vb = _vertex_at(skel, x2, y2, z)
    ei = find_edge(skel, va, vb)
    ei === nothing &&
        error("core: no wall edge from ($x1, $y1, $z) to ($x2, $y2, $z)")
    a, b = skel.edge_indices[ei]
    vm = add_vertex!(skel, _point_m(skel, xm, ym, z); level_idx=story)
    _point_on_segment(skel, a, b, vm) ||
        error("core: split point ($xm, $ym, $z) is not on its wall")
    skel.edge_indices[ei] = (a, vm)
    skel.edges[ei] = Meshes.Segment(skel.vertices[a], skel.vertices[vm])
    Graphs.rem_edge!(skel.graph, a, b) ||
        error("core: the wall graph has no edge from $a to $b")
    Graphs.add_edge!(skel.graph, a, vm) ||
        error("core: could not connect the split of edge $ei")
    new_ei = add_element!(skel, vm, b; group=:walls, level_idx=story)
    for edges in skel.face_edge_indices
        ei in edges && push!(edges, new_ei)
    end
    for (cid, chain) in skel.edge_chains
        ei in chain && push!(skel.edge_chains[cid], new_ei)
    end
    return new_ei
end

"""True when vertex `v` lies strictly between vertices `a` and `b` in plan."""
function _point_on_segment(skel, a, b, v; tol = 1e-3)
    ca = Meshes.coords(skel.vertices[a])
    cb = Meshes.coords(skel.vertices[b])
    cv = Meshes.coords(skel.vertices[v])
    ax, ay = ustrip(u"m", ca.x), ustrip(u"m", ca.y)
    bx, by = ustrip(u"m", cb.x), ustrip(u"m", cb.y)
    vx, vy = ustrip(u"m", cv.x), ustrip(u"m", cv.y)
    dx, dy = bx - ax, by - ay
    len = hypot(dx, dy)
    len <= tol && return false
    cross = dx * (vy - ay) - dy * (vx - ax)
    abs(cross) / len > tol && return false
    t = ((vx - ax) * dx + (vy - ay) * dy) / (len * len)
    return tol / len < t < 1 - tol / len
end

"""Add one plan wall at elevation `z` and put it in the `:walls` group."""
function _add_wall!(skel, x1, y1, x2, y2, z, story)
    seg = Meshes.Segment(_point_m(skel, x1, y1, z), _point_m(skel, x2, y2, z))
    return add_element!(skel, seg; group=:walls, level_idx=story)
end

"""
Replace center-bay face `fi` with the lobby quad.

The face stays in its floor group. Its polygon, vertex loop, and edge loop
all become the lobby, so the shaft area north of `CORE_LOBBY_Y` is no longer
a slab face.
"""
function _retarget_lobby!(skel, fi, z)
    vids = Int[
        _vertex_at(skel, CORE_BAY, CORE_BAY, z),
        _vertex_at(skel, 2 * CORE_BAY, CORE_BAY, z),
        _vertex_at(skel, 2 * CORE_BAY, CORE_LOBBY_Y, z),
        _vertex_at(skel, CORE_BAY, CORE_LOBBY_Y, z),
    ]
    edges = Int[]
    for i in eachindex(vids)
        v1 = vids[i]
        v2 = vids[mod1(i + 1, length(vids))]
        ei = find_edge(skel, v1, v2)
        ei === nothing && error("core: lobby face at z = $z m is missing an edge")
        push!(edges, ei)
    end
    skel.face_vertex_indices[fi] = vids
    skel.face_edge_indices[fi] = edges
    skel.faces[fi] = Meshes.Ngon(skel.vertices[vids]...)
    return fi
end

function _drop_core_corner_columns!(skel)
    corners = ((CORE_BAY, CORE_BAY), (2 * CORE_BAY, CORE_BAY),
               (2 * CORE_BAY, 2 * CORE_BAY), (CORE_BAY, 2 * CORE_BAY))
    drop = Int[]
    for eidx in skel.groups_edges[:columns]
        a, b = skel.edge_indices[eidx]
        ca = Meshes.coords(skel.vertices[a])
        cb = Meshes.coords(skel.vertices[b])
        pa = (ustrip(u"m", ca.x), ustrip(u"m", ca.y))
        pb = (ustrip(u"m", cb.x), ustrip(u"m", cb.y))
        any(c -> _near(pa, c, 1e-3) && _near(pb, c, 1e-3), corners) || continue
        push!(drop, eidx)
    end
    length(drop) == 4 * CORE_STORIES ||
        error("core: found $(length(drop)) corner columns, expected $(4 * CORE_STORIES)")
    gone = Set(drop)
    filter!(e -> e ∉ gone, skel.groups_edges[:columns])
    return length(drop)
end

function _find_plan_edge(skel, x1, y1, z, x2, y2; tol = 1e-3)
    for (eidx, (a, b)) in enumerate(skel.edge_indices)
        ca = Meshes.coords(skel.vertices[a])
        cb = Meshes.coords(skel.vertices[b])
        p = (ustrip(u"m", ca.x), ustrip(u"m", ca.y), ustrip(u"m", ca.z))
        q = (ustrip(u"m", cb.x), ustrip(u"m", cb.y), ustrip(u"m", cb.z))
        (_near(p, (x1, y1, z), tol) && _near(q, (x2, y2, z), tol)) && return eidx
        (_near(p, (x2, y2, z), tol) && _near(q, (x1, y1, z), tol)) && return eidx
    end
    error("core: no edge from ($x1, $y1, $z) to ($x2, $y2, $z)")
end

_near(a, b, tol) = all(abs(a[i] - b[i]) <= tol for i in 1:min(length(a), length(b)))

function _claim_as_wall!(skel, eidx)
    filter!(!=(eidx), skel.groups_edges[:beams])
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)
    return eidx
end
