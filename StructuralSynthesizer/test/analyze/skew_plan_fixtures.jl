# Office fixtures whose plan is a mapped rectangle.
#
# `_skew_office(map)` is two bays each way (6 m in X, 5 m in Y, so a one-way
# slab has one short span), three 4 m stories, with every grid point sent
# through `map(x, y)`. A rotation keeps the bays rectangular. A shear makes
# them parallelograms, so the Y-grid lines are no longer perpendicular to the
# X-grid lines. The four isolated wall segments sit where the axis-aligned
# stage tests put theirs, mapped the same way.

using Unitful

"""Rotation by `α` about the origin."""
function _skew_rotation(α)
    c, s = cos(α), sin(α)
    return (x, y) -> (c * x - s * y, s * x + c * y)
end

"""Shear that tilts the Y-grid lines by `α` from the Y axis."""
_skew_shear(α) = (x, y) -> (x + tan(α) * y, y)

const _SKEW_SPANS = (6.0, 5.0)

"""Skeleton of the mapped office. Same edges, groups, and faces as `gen_medium_office`."""
function _skew_skeleton(map; spans=_SKEW_SPANS, bays=2, height=4.0, stories=3)
    skel = BuildingSkeleton{typeof(1.0u"m")}()
    for k in 0:stories
        push!(skel.stories_z, k * height * u"m")
    end
    function pt(i, j, k)
        x, y = map(i * spans[1], j * spans[2])
        return Meshes.Point(x * u"m", y * u"m", skel.stories_z[k + 1])
    end
    for k in 0:stories
        for j in 0:bays, i in 0:(bays - 1)
            add_element!(skel, Meshes.Segment(pt(i, j, k), pt(i + 1, j, k));
                         group=:beams, level_idx=k)
        end
        for i in 0:bays, j in 0:(bays - 1)
            add_element!(skel, Meshes.Segment(pt(i, j, k), pt(i, j + 1, k));
                         group=:beams, level_idx=k)
        end
        k > 0 || continue
        for i in 0:bays, j in 0:bays
            add_element!(skel, Meshes.Segment(pt(i, j, k - 1), pt(i, j, k));
                         group=:columns, level_idx=k)
        end
    end
    for i in 0:bays, j in 0:bays
        add_vertex!(skel, pt(i, j, 0); group=:support)
        add_vertex!(skel, pt(i, j, stories); group=:roof)
    end
    find_faces!(skel)
    for (level, story) in skel.stories
        grp = level == 0 ? :grade : level == stories ? :roof : :floor
        append!(get!(skel.groups_faces, grp, Int[]), story.faces)
    end
    return skel
end

function _skew_xy(skel, v)
    c = Meshes.coords(skel.vertices[v])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z))
end

"""Move each story's beam on the plan segment `a`–`b` into `:walls`."""
function _skew_claim!(skel, a, b, stories)
    beams = skel.groups_edges[:beams]
    for story in 0:(stories - 1)
        hits = filter(skel.stories[story].edges) do e
            e in beams || return false
            p = _skew_xy(skel, skel.edge_indices[e][1])
            q = _skew_xy(skel, skel.edge_indices[e][2])
            abs(p[3] - q[3]) <= 1e-6 || return false
            same(u, v) = hypot(u[1] - v[1], u[2] - v[2]) <= 1e-6
            return (same(p, a) && same(q, b)) || (same(p, b) && same(q, a))
        end
        length(hits) == 1 || error("skew fixture: story $story has $(length(hits)) edges on the wall line")
        e = only(hits)
        filter!(!=(e), beams)
        push!(get!(skel.groups_edges, :walls, Int[]), e)
    end
    return skel
end

# The isolated segments of `_STAGE_BOTH_AXES`, in bay indices. No two share an end.
const _SKEW_SEGMENTS = (
    (0, 0, 1, 0),
    (1, 2, 2, 2),
    (2, 0, 2, 1),
    (0, 1, 0, 2),
)

"""
Mapped office with the four isolated wall lines on every story.

`plan_axis` is the lateral stage's first plan axis; floor spans are detected on it.
"""
function _skew_office(map; thickness=0.3u"m", stories=3, floor_type::Symbol=:vault,
                      plan_axis=(1.0, 0.0), tributary_axis=nothing,
                      scoped_floor_overrides=StructuralSynthesizer.ScopedFloorOverride[])
    skel = _skew_skeleton(map; stories)
    sx, sy = _SKEW_SPANS
    for (i1, j1, i2, j2) in _SKEW_SEGMENTS
        _skew_claim!(skel, map(i1 * sx, j1 * sy), map(i2 * sx, j2 * sy), stories)
    end
    struc = BuildingStructure(skel)
    opts = floor_type === :vault ? (; floor_opts=VaultOptions(rise=1.0u"m", thickness=0.05u"m")) : (;)
    initialize!(struc;
        floor_type=floor_type,
        material=NWC_4000,
        wall_thickness=thickness,
        plan_axis=plan_axis,
        tributary_axis=tributary_axis,
        scoped_floor_overrides=scoped_floor_overrides,
        opts...)
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end
