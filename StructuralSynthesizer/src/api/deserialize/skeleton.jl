# Shatter Logic — split long edges at intermediate vertices
# =============================================================================

"""
    _shatter_edges(skel, edge_pairs, group; tol=1e-6) -> nothing

For each edge pair `[v1, v2]`, detect any existing skeleton vertices that lie
on the line segment between `v1` and `v2`. If intermediates are found, the edge
is split into ordered sub-segments and all sub-segments are added to the
skeleton. The original user-line is recorded in `skel.edge_chains` so that
`initialize_members!` can later merge the sub-segments into one member.

If no intermediates exist, the edge is added as-is (no chain entry needed —
1:1 mapping is the default).
"""
function _shatter_edges!(skel::BuildingSkeleton{T}, edge_pairs::Vector{Vector{Int}},
                          group::Symbol; tol::Float64=1e-6) where T
    all_vertex_indices = Set(1:length(skel.vertices))

    for pair in edge_pairs
        v1, v2 = pair
        p1 = skel.vertices[v1]
        p2 = skel.vertices[v2]

        # Find intermediate vertices on this line segment
        intermediates = _find_intermediates(skel, v1, v2, all_vertex_indices, tol)

        if isempty(intermediates)
            # No shattering needed — add as single edge
            seg = Meshes.Segment(p1, p2)
            add_element!(skel, seg; group=group)
        else
            # Sort intermediates by parameter along the line and shatter
            chain_id = UInt64(hash((:edge_chain, group, v1, v2)))
            chain_edges = Int[]

            # Build ordered vertex sequence: v1 → intermediates → v2
            ordered = vcat(v1, [vi for (vi, _) in intermediates], v2)

            for k in 1:(length(ordered) - 1)
                va, vb = ordered[k], ordered[k + 1]
                seg = Meshes.Segment(skel.vertices[va], skel.vertices[vb])
                add_element!(skel, seg; group=group)
                push!(chain_edges, length(skel.edges))
            end

            skel.edge_chains[chain_id] = chain_edges
        end
    end
end

"""
Find skeleton vertex indices that lie strictly between `v1` and `v2` on the
line segment, returned sorted by parameter `t ∈ (0, 1)`.
"""
function _find_intermediates(skel::BuildingSkeleton{T}, v1::Int, v2::Int,
                              candidates::Set{Int}, tol::Float64) where T
    p1 = skel.vertices[v1]
    p2 = skel.vertices[v2]

    c1 = Meshes.coords(p1)
    c2 = Meshes.coords(p2)
    dx = ustrip(c2.x - c1.x)
    dy = ustrip(c2.y - c1.y)
    dz = ustrip(c2.z - c1.z)
    seg_len_sq = dx^2 + dy^2 + dz^2
    seg_len_sq < tol^2 && return Tuple{Int, Float64}[]

    result = Tuple{Int, Float64}[]

    for vi in candidates
        vi == v1 && continue
        vi == v2 && continue

        pv = skel.vertices[vi]
        cv = Meshes.coords(pv)
        ex = ustrip(cv.x - c1.x)
        ey = ustrip(cv.y - c1.y)
        ez = ustrip(cv.z - c1.z)

        # Parameter along the line
        t = (ex * dx + ey * dy + ez * dz) / seg_len_sq
        (t < tol || t > 1.0 - tol) && continue

        # Distance from point to line
        # Cross product magnitude / segment length
        cx = ey * dz - ez * dy
        cy = ez * dx - ex * dz
        cz = ex * dy - ey * dx
        dist_sq = (cx^2 + cy^2 + cz^2) / seg_len_sq
        dist_sq > tol^2 && continue

        push!(result, (vi, t))
    end

    sort!(result; by=last)
    return result
end

# =============================================================================
# JSON → BuildingSkeleton
# =============================================================================

"""Throw ArgumentError if any edge vertex index is out of [1, n_verts]."""
function _validate_edge_bounds(edge_pairs::Vector{Vector{Int}}, n_verts::Int, label::String)
    for (i, pair) in enumerate(edge_pairs)
        length(pair) >= 2 || throw(ArgumentError("$label edge $i has $(length(pair)) indices (expected 2)."))
        v1, v2 = pair[1], pair[2]
        (v1 >= 1 && v1 <= n_verts) || throw(ArgumentError("$label edge $i: vertex index $v1 out of range [1, $n_verts]."))
        (v2 >= 1 && v2 <= n_verts) || throw(ArgumentError("$label edge $i: vertex index $v2 out of range [1, $n_verts]."))
    end
end

"""Add vertices from input.vertices to the skeleton (coordinates converted via _to_m)."""
function _add_vertices!(skel::BuildingSkeleton, input::APIInput, _to_m)
    for coords in input.vertices
        pt = Meshes.Point(_to_m(coords[1]), _to_m(coords[2]), _to_m(coords[3]))
        add_vertex!(skel, pt)
    end
end

"""
Add beam, column, brace, and wall edges with bounds checks and shatter.

`input.edges.walls` is shattered into the `:walls` group. An empty wall list
is a no-op: `_shatter_edges!` iterates nothing and adds no edges.
"""
function _add_edges!(skel::BuildingSkeleton, input::APIInput)
    n_verts = length(skel.vertices)
    _validate_edge_bounds(input.edges.beams, n_verts, "Beam")
    _validate_edge_bounds(input.edges.columns, n_verts, "Column")
    _validate_edge_bounds(input.edges.braces, n_verts, "Brace")
    _validate_edge_bounds(input.edges.walls, n_verts, "Wall")
    _shatter_edges!(skel, input.edges.beams, :beams)
    _shatter_edges!(skel, input.edges.columns, :columns)
    _shatter_edges!(skel, input.edges.braces, :braces)
    _shatter_edges!(skel, input.edges.walls, :walls)
end

"""Add `input.openings` as slab openings; each polyline's first z picks its story."""
function _add_openings!(skel::BuildingSkeleton, input::APIInput, _to_m)
    for poly in input.openings
        length(poly) >= 3 || continue
        level = _find_level_idx(skel, _to_m(poly[1][3]))
        loop = [(ustrip(u"m", _to_m(c[1])), ustrip(u"m", _to_m(c[2]))) for c in poly]
        add_slab_opening!(skel, loop, level)
    end
end

_ingest_xyz(skel, v) = begin
    c = Meshes.coords(skel.vertices[v])
    (Float64(ustrip(u"m", c.x)), Float64(ustrip(u"m", c.y)), Float64(ustrip(u"m", c.z)))
end

_fmt_xyz(p) = "($(round(p[1]; digits = 4)), $(round(p[2]; digits = 4)), $(round(p[3]; digits = 4))) m"

"""
Throw when two vertices are within 1 mm.

A joint that was drawn twice would split one member into two that do not meet.
The message names both vertices.
"""
function _refuse_duplicate_vertices!(skel::BuildingSkeleton; tol::Float64 = 0.001)
    n = length(skel.vertices)
    for i in 1:(n - 1)
        a = _ingest_xyz(skel, i)
        for j in (i + 1):n
            b = _ingest_xyz(skel, j)
            d = hypot(b[1] - a[1], b[2] - a[2], b[3] - a[3])
            d < tol || continue
            throw(ArgumentError(
                "vertices $i and $j are $(round(1000d; digits = 2)) mm apart, " *
                "at $(_fmt_xyz(a)) and $(_fmt_xyz(b)). Merge them into one joint."))
        end
    end
    return nothing
end

"""
Throw when two beams cross in plan without sharing a joint.

Columns are short in plan and are not beams. Beams on different stories
do not meet. A shared vertex is the joint. The message names the crossing.
"""
function _refuse_crossing_beams!(skel::BuildingSkeleton; tol::Float64 = 0.001)
    beams = get(skel.groups_edges, :beams, Int[])
    length(beams) < 2 && return nothing
    xyz = [_ingest_xyz(skel, v) for v in eachindex(skel.vertices)]
    for ii in 1:(length(beams) - 1)
        e1 = beams[ii]
        a, b = skel.edge_indices[e1]
        p, q = xyz[a], xyz[b]
        abs(p[3] - q[3]) > tol && continue
        hypot(q[1] - p[1], q[2] - p[2]) < tol && continue
        z1 = (p[3] + q[3]) / 2
        for jj in (ii + 1):length(beams)
            e2 = beams[jj]
            c, d = skel.edge_indices[e2]
            (c == a || c == b || d == a || d == b) && continue
            r, s = xyz[c], xyz[d]
            abs(r[3] - s[3]) > tol && continue
            abs((r[3] + s[3]) / 2 - z1) > tol && continue
            hypot(s[1] - r[1], s[2] - r[2]) < tol && continue
            hit = StructuralSizer._segment_crossing((p[1], p[2]), (q[1], q[2]),
                                                    (r[1], r[2]), (s[1], s[2]), tol)
            hit === nothing && continue
            t, u = hit
            # t and u are fractions of each beam. A meeting at a vertex is
            # already skipped; this drops a graze at an end.
            (1e-4 < t < 1 - 1e-4 && 1e-4 < u < 1 - 1e-4) || continue
            x = p[1] + t * (q[1] - p[1])
            y = p[2] + t * (q[2] - p[2])
            throw(ArgumentError(
                "beams $e1 and $e2 cross at ($(round(x; digits = 4)), $(round(y; digits = 4))) m " *
                "without a joint. Split them there."))
        end
    end
    return nothing
end

"""Add support vertices; throws if any support index is out of [1, n_vertices]."""
function _add_supports!(skel::BuildingSkeleton, input::APIInput)
    n_verts = length(skel.vertices)
    for vi in input.supports
        (vi >= 1 && vi <= n_verts) || throw(ArgumentError("Support vertex index $vi out of range [1, $n_verts]."))
        add_vertex!(skel, skel.vertices[vi]; group=:support)
    end
end

"""
    json_to_skeleton(input::APIInput) -> BuildingSkeleton

Build a `BuildingSkeleton` from the parsed JSON input.

All coordinates are converted to **meters** internally, matching the convention
used by `gen_medium_office` and required by `BuildingStructure` (which hardcodes
`A = typeof(1.0u"m^2")` for area and `P = typeof(1.0u"kN/m^2")` for pressure).

## Shatter behaviour
Long edges that pass through intermediate vertices are automatically split into
sub-segments. The original user-line is recorded in `skel.edge_chains` so that
`initialize_members!` can merge sub-segments into one continuous member.

## Stories Z
If `input.stories_z` is empty, story elevations are inferred from the unique Z
coordinates of all vertices via `rebuild_stories!`.

## Bounds checks
Vertex indices in edges and supports are validated; out-of-range indices throw
`ArgumentError` even when `validate_input` has not been called.
"""
function json_to_skeleton(input::APIInput)
    coord_unit = parse_unit(input.units)
    _to_m(val) = uconvert(u"m", val * coord_unit)

    T = typeof(1.0u"m")
    skel = BuildingSkeleton{T}()
    enable_lookup!(skel)

    if !isempty(input.stories_z)
        skel.stories_z = [_to_m(z) for z in input.stories_z]
    end

    _add_vertices!(skel, input, _to_m)
    _refuse_duplicate_vertices!(skel)
    _add_edges!(skel, input)
    _refuse_crossing_beams!(skel)
    _add_supports!(skel, input)
    _add_faces!(skel, input, coord_unit, _to_m)
    _add_openings!(skel, input, _to_m)

    n_chains = length(skel.edge_chains)
    n_shattered = sum(length(v) for v in values(skel.edge_chains); init=0)
    @debug "Built skeleton" vertices=length(skel.vertices) edges=length(skel.edges) chains=n_chains shattered_edges=n_shattered

    return skel
end

"""Map explicit face polygons onto detected skeleton faces and assign requested groups."""
