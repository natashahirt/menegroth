#=
Skeleton for the four-story core office used by the scene runners.

3×3 bays of 8 m, four stories of 3.6 m. The four plan edges of the center bay
are moved from :beams to :walls on every story below the roof, so the core
stacks from grade to the top floor. The center bay is not a slab on those
stories: its face leaves the floor groups, and the roof face over the core
stays. The opening is the missing face, not a hole cut into a zero-area cell.
=#

using StructuralSynthesizer
using Meshes
using Unitful

const CORE_BAY = 8.0
const CORE_STORIES = 4
const CORE_STORY_H = 3.6

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
    # Every floor below the roof is open over the core. The roof stays closed.
    _open_core_shaft!(skel)
    # Two passenger doors on the south face of the core, and a stair door on
    # the east face. Door size is the demo geometry, not a code minimum:
    # 1.1 m by 2.1 m for each elevator, 1.0 m by 2.1 m for the stair.
    _core_doors!(skel)
    return skel
end

"""
Elevator bank on the south core wall and a stair door on the east core wall,
on every story that has the core wall.

South wall from (8, 8) toward (16, 8). The two doors are centered, with a
0.30 m pier between them. East wall from (16, 8) toward (16, 16); the stair
door starts 1.2 m from the south end.
"""
function _core_doors!(skel)
    bank = 1.1 + 0.30 + 1.1
    s1 = (CORE_BAY - bank) / 2
    s2 = s1 + 1.1 + 0.30
    stair = WallOpening(1.2, 0.0, 1.0, 2.1, :door)
    for story in 0:(CORE_STORIES - 1)
        z = story * CORE_STORY_H
        south_a = _vertex_at(skel, CORE_BAY, CORE_BAY, z)
        south_b = _vertex_at(skel, 2 * CORE_BAY, CORE_BAY, z)
        east_b = _vertex_at(skel, 2 * CORE_BAY, 2 * CORE_BAY, z)
        add_wall_opening!(skel, south_a, south_b, story, WallOpening(s1, 0.0, 1.1, 2.1, :door))
        add_wall_opening!(skel, south_a, south_b, story, WallOpening(s2, 0.0, 1.1, 2.1, :door))
        add_wall_opening!(skel, south_b, east_b, story, stair)
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
Take the center-bay face out of every slab group below the roof.

The face stays in the skeleton, so the walls still have a line to sit on.
It is not a slab face, and `rebuild_geometry_cache!` then counts the core
edges as slab boundaries. A full-bay `SlabOpening` would leave a cell with
no area; this does not create that cell.
"""
function _open_core_shaft!(skel)
    roof_z = ustrip(u"m", skel.stories_z[end])
    x0, x1 = CORE_BAY, 2 * CORE_BAY
    drop = Int[]
    for (fi, vis) in enumerate(skel.face_vertex_indices)
        xs = Float64[]
        ys = Float64[]
        zs = Float64[]
        for v in vis
            c = Meshes.coords(skel.vertices[v])
            push!(xs, ustrip(u"m", c.x))
            push!(ys, ustrip(u"m", c.y))
            push!(zs, ustrip(u"m", c.z))
        end
        all(z -> abs(z - zs[1]) <= 1e-6, zs) || continue
        abs(zs[1] - roof_z) <= 1e-3 && continue
        all(x -> x0 - 1e-3 <= x <= x1 + 1e-3, xs) || continue
        all(y -> x0 - 1e-3 <= y <= x1 + 1e-3, ys) || continue
        push!(drop, fi)
    end
    # Grade plus every floor below the roof: one open bay each.
    length(drop) == CORE_STORIES ||
        error("core: opened $(length(drop)) shaft bays, expected $(CORE_STORIES)")
    gone = Set(drop)
    for (grp, faces) in skel.groups_faces
        grp === :roof && continue
        filter!(fi -> fi ∉ gone, faces)
    end
    rebuild_geometry_cache!(skel)
    return length(drop)
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
