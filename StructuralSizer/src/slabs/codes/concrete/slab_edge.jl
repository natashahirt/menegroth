# =============================================================================
# Slab edge outside the column centerlines
# =============================================================================
#
# The drawn polygon is the column and beam centerline. It does not move when a
# column is resized. Each straight exterior run is shifted out, perpendicular
# to itself, by the largest distance from a column center on that run to that
# column's face. The outline corner is the intersection of the two adjacent
# shifted lines, so the edge stays straight when the columns on it differ.

"""
One straight run of a slab's centerline perimeter.

`vertices` starts at the run's first corner and ends at its last, in the
walk order of the polygon. `outward` is the unit normal pointing out of the
slab. `width` is the shift of this run, in metres. `edges` are the polygon
edge indices, each edge running from its start vertex to the next.
"""
struct SlabEdgeRun
    vertices::Vector{NTuple{2, Float64}}
    outward::NTuple{2, Float64}
    width::Float64
    edges::Vector{Int}
end

"""
    story_slab_edge(polygon, columns) -> NamedTuple

`polygon` is the centerline perimeter in metres, one corner each, not closed.
Walk it with the slab on the left: counter-clockwise for the exterior, clockwise
for a hole. `columns` gives each column center `xy` and `half(direction)`, the
distance in metres from that center to the column face along a unit vector.

The result is `(runs, outline, edge_run)`. `outline[k]` is the slab-edge corner
at the start of `runs[k]`. `edge_run[i]` is the run that owns polygon edge `i`.
"""
function story_slab_edge(polygon, columns)
    n = length(polygon)
    n >= 3 || throw(ArgumentError("a slab edge needs at least three corners"))
    outward = Vector{NTuple{2, Float64}}(undef, n)
    for i in 1:n
        a = polygon[i]
        b = polygon[mod1(i + 1, n)]
        dx = Float64(b[1] - a[1])
        dy = Float64(b[2] - a[2])
        len = hypot(dx, dy)
        len < 1e-12 && throw(ArgumentError("a slab edge has a zero-length side"))
        # Right-hand normal. The slab is on the left of a directed edge, so
        # this points out of the slab.
        outward[i] = (dy / len, -dx / len)
    end

    # Start where the direction changes, so the first run does not swallow a
    # corner that belongs to the last run.
    start = 1
    for i in 1:n
        prev = outward[mod1(i - 1, n)]
        if outward[i][1] * prev[1] + outward[i][2] * prev[2] <= 1 - 1e-8
            start = i
            break
        end
    end

    runs = SlabEdgeRun[]
    edge_run = zeros(Int, n)
    i = start
    while true
        edges = Int[i]
        nrm = outward[i]
        j = mod1(i + 1, n)
        while j != start &&
                nrm[1] * outward[j][1] + nrm[2] * outward[j][2] > 1 - 1e-8
            push!(edges, j)
            j = mod1(j + 1, n)
        end
        verts = NTuple{2, Float64}[(Float64(polygon[e][1]), Float64(polygon[e][2]))
                                   for e in edges]
        nxt = polygon[mod1(edges[end] + 1, n)]
        push!(verts, (Float64(nxt[1]), Float64(nxt[2])))
        push!(runs, SlabEdgeRun(verts, nrm, _run_width(polygon, edges, nrm, columns), edges))
        r = length(runs)
        for e in edges
            edge_run[e] = r
        end
        i = j
        i == start && break
    end

    outline = Vector{NTuple{2, Float64}}(undef, length(runs))
    for k in eachindex(runs)
        prev = runs[mod1(k - 1, length(runs))]
        outline[k] = _offset_corner(prev, runs[k])
    end
    return (runs = runs, outline = outline, edge_run = edge_run)
end

"""Largest column-face distance along `outward` of the columns that sit on `edges`."""
function _run_width(polygon, edges, outward, columns)
    w = 0.0
    n = length(polygon)
    for e in edges
        a = polygon[e]
        b = polygon[mod1(e + 1, n)]
        for col in columns
            _segment_station(col.xy, a, b) === nothing && continue
            w = max(w, Float64(col.half(outward)))
        end
    end
    return w
end

"""Station of `p` on segment `a`→`b`, or `nothing` when `p` is off the segment."""
function _segment_station(p, a, b; tol::Float64 = 1e-3)
    abx = Float64(b[1] - a[1])
    aby = Float64(b[2] - a[2])
    L2 = abx * abx + aby * aby
    L2 < 1e-18 && return hypot(Float64(p[1] - a[1]), Float64(p[2] - a[2])) <= tol ? 0.0 : nothing
    s = ((Float64(p[1] - a[1])) * abx + (Float64(p[2] - a[2])) * aby) / L2
    # Past either end is off the segment, even on the same line.
    reach = tol / sqrt(L2)
    (s < -reach || s > 1 + reach) && return nothing
    qx = Float64(a[1]) + s * abx
    qy = Float64(a[2]) + s * aby
    hypot(Float64(p[1]) - qx, Float64(p[2]) - qy) <= tol || return nothing
    return clamp(s, 0.0, 1.0)
end

# =============================================================================
# The slab edge of one floor
# =============================================================================

"""Metres from a coordinate that may carry a length unit."""
_edge_m(x) = x isa Unitful.Quantity ? Float64(ustrip(u"m", x)) : Float64(x)

"""
    floor_slab_edges(struc, z; tol = 0.01) -> Vector{NamedTuple}

Slab-edge loops of the floor at elevation `z`, in metres.

The floor is every cell whose face lies at `z`. An edge used by one of those
cells is on the slab boundary, so an edge between two slabs is not. Each loop
is `(vertices, polygon, edge)`: skeleton vertex indices, their plan points
walked with the slab on the left (the exterior counter-clockwise, a courtyard
clockwise), and the [`story_slab_edge`](@ref) result. The columns are those
whose vertex is at `z`, with the column above each. A loop through a vertex
with more than two boundary edges is skipped. Empty when no column has a size.
"""
function floor_slab_edges(struc, z::Real; tol::Float64 = 0.01)
    out = NamedTuple{(:vertices, :polygon, :edge)}[]
    hasproperty(struc, :columns) && hasproperty(struc, :cells) || return out
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    size(vc, 2) >= 3 || return out
    samples = _floor_column_samples(struc, z; tol = tol)
    isempty(samples) && return out
    counts = Dict{Int, Int}()
    for cell in struc.cells
        vis = skel.face_vertex_indices[cell.face_idx]
        isempty(vis) && continue
        abs(_edge_m(vc[first(vis), 3]) - z) <= tol || continue
        for e in skel.face_edge_indices[cell.face_idx]
            counts[e] = get(counts, e, 0) + 1
        end
    end
    adj = Dict{Int, Vector{Int}}()
    for (e, c) in counts
        c == 1 || continue
        a, b = skel.edge_indices[e]
        push!(get!(() -> Int[], adj, a), b)
        push!(get!(() -> Int[], adj, b), a)
    end
    loops = Vector{Int}[]
    seen = Set{Int}()
    for start in sort!(collect(keys(adj)))
        start in seen && continue
        loop = Int[start]
        prev, cur = 0, start
        closed = false
        for _ in 1:length(adj)
            nbrs = adj[cur]
            length(nbrs) == 2 || break
            nxt = nbrs[1] == prev ? nbrs[2] : nbrs[1]
            if nxt == start
                closed = true
                break
            end
            push!(loop, nxt)
            prev, cur = cur, nxt
        end
        union!(seen, loop)
        closed && length(loop) >= 3 && push!(loops, loop)
    end
    isempty(loops) && return out
    polys = [NTuple{2, Float64}[(_edge_m(vc[v, 1]), _edge_m(vc[v, 2])) for v in loop]
             for loop in loops]
    areas = [_signed_area(p) for p in polys]
    outer = argmax(abs.(areas))
    for (i, (loop, poly)) in enumerate(zip(loops, polys))
        # Exterior counter-clockwise; a courtyard clockwise, so its outward
        # normal steps into the opening.
        if (areas[i] > 0) != (i == outer)
            reverse!(loop)
            reverse!(poly)
        end
        push!(out, (vertices = loop, polygon = poly, edge = story_slab_edge(poly, samples)))
    end
    return out
end

"""Signed area of a plan polygon. Positive when counter-clockwise."""
_signed_area(poly) = 0.5 * sum(
    poly[i][1] * poly[mod1(i + 1, length(poly))][2] -
    poly[mod1(i + 1, length(poly))][1] * poly[i][2]
    for i in eachindex(poly); init = 0.0)

"""
Columns at elevation `z`, one sample per plan point.

`half(d)` is the largest center-to-face distance along `d` of the column and
the column above it. Columns without a size are left out.
"""
function _floor_column_samples(struc, z::Real; tol::Float64 = 0.01)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    groups = Dict{NTuple{2, Float64}, Vector{Any}}()
    for col in struc.columns
        vi = col_vertex_idx(col)
        vi > 0 || continue
        abs(_edge_m(vc[vi, 3]) - z) <= tol || continue
        key = (round(_edge_m(vc[vi, 1]), digits = 6), round(_edge_m(vc[vi, 2]), digits = 6))
        bucket = get!(() -> Any[], groups, key)
        _has_column_size(col) && push!(bucket, col)
        above = hasproperty(col, :column_above) ? col.column_above : nothing
        above !== nothing && _has_column_size(above) && push!(bucket, above)
    end
    samples = NamedTuple{(:xy, :half), Tuple{NTuple{2, Float64}, Function}}[]
    for (xy, cols) in groups
        isempty(cols) && continue
        push!(samples, (xy = xy, half = let cols = cols
            d -> maximum(_column_face_offset_m(c, d) for c in cols)
        end))
    end
    return samples
end

"""A column the edge can measure: a positive `c1`, and `c2` unless it is round."""
function _has_column_size(col)
    hasproperty(col, :c1) || return false
    c1 = col.c1
    (c1 === nothing || _edge_m(c1) <= 1e-6) && return false
    col_shape(col) == :circular && return true
    hasproperty(col, :c2) || return false
    c2 = col.c2
    return c2 !== nothing && _edge_m(c2) > 1e-6
end

"""
    slab_edge_offsets(loops) -> NamedTuple

From [`floor_slab_edges`](@ref) loops: `shift[v]`, the displacement in metres
from boundary vertex `v` to the slab edge, and `side[(a, b)]` (`a < b`), the
outward normal and width of the run that owns that boundary edge. A run's
first vertex goes to the outline corner; any other vertex moves straight out.
"""
function slab_edge_offsets(loops)
    shift = Dict{Int, NTuple{2, Float64}}()
    side = Dict{Tuple{Int, Int}, NamedTuple{(:outward, :width), Tuple{NTuple{2, Float64}, Float64}}}()
    for loop in loops
        poly, vids, edge = loop.polygon, loop.vertices, loop.edge
        n = length(poly)
        for (k, run) in enumerate(edge.runs)
            for (j, e) in enumerate(run.edges)
                p = poly[e]
                xy = j == 1 ? edge.outline[k] :
                    (p[1] + run.outward[1] * run.width, p[2] + run.outward[2] * run.width)
                shift[vids[e]] = (xy[1] - p[1], xy[2] - p[2])
                a, b = vids[e], vids[mod1(e + 1, n)]
                side[minmax(a, b)] = (outward = run.outward, width = run.width)
            end
        end
    end
    return (shift = shift, side = side)
end

"""
    slab_edge_corner_area(v, prev, run, corner) -> Float64

Slab area at the corner where `prev` ends and `run` starts, in m², beyond the
two rectangles `width × length` that the runs cover. `v` is the centerline
corner and `corner` the slab-edge corner. Positive at a convex corner. At a
re-entrant corner the two rectangles overlap and the value is negative.
"""
function slab_edge_corner_area(v, prev::SlabEdgeRun, run::SlabEdgeRun, corner)
    p = (v[1] + prev.outward[1] * prev.width, v[2] + prev.outward[2] * prev.width)
    q = (v[1] + run.outward[1] * run.width, v[2] + run.outward[2] * run.width)
    return _signed_area((v, p, corner, q))
end

"""
Width of the slab past the centerline at plan points `pts`, facing `dir`.

The run of the floor edge at `z` that holds every point and whose outward
normal is `dir` gives the width. Zero when no run qualifies: the points are
inside the floor, or on an edge between two slabs.
"""
function slab_edge_width_at(struc, z::Real, pts, dir::NTuple{2, Float64})
    isempty(pts) && return 0.0
    for loop in floor_slab_edges(struc, z)
        poly = loop.polygon
        n = length(poly)
        for run in loop.edge.runs
            run.outward[1] * dir[1] + run.outward[2] * dir[2] > 1 - 1e-6 || continue
            on_run = all(pts) do p
                any(e -> _segment_station(p, poly[e], poly[mod1(e + 1, n)]) !== nothing,
                    run.edges)
            end
            on_run && return run.width
        end
    end
    return 0.0
end

"""Intersection of the two shifted centerlines, the slab corner between them."""
function _offset_corner(a::SlabEdgeRun, b::SlabEdgeRun)
    p = (a.vertices[1][1] + a.outward[1] * a.width,
         a.vertices[1][2] + a.outward[2] * a.width)
    q = (b.vertices[1][1] + b.outward[1] * b.width,
         b.vertices[1][2] + b.outward[2] * b.width)
    d = (a.vertices[end][1] - a.vertices[1][1], a.vertices[end][2] - a.vertices[1][2])
    e = (b.vertices[end][1] - b.vertices[1][1], b.vertices[end][2] - b.vertices[1][2])
    det = d[1] * e[2] - d[2] * e[1]
    abs(det) < 1e-12 && return p
    s = ((q[1] - p[1]) * e[2] - (q[2] - p[2]) * e[1]) / det
    return (p[1] + s * d[1], p[2] + s * d[2])
end
