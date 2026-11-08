# Slab edge past the column centerlines. See `story_slab_edge` in StructuralSizer.

"""Columns framing into story `level`, one sample per plan point, largest face wins."""
function _edge_column_samples(struc, level::Int)
    groups = Dict{NTuple{2, Float64}, Vector{eltype(struc.columns)}}()
    skel = struc.skeleton
    for col in struc.columns
        col.story == level || col.story == level + 1 || continue
        xy = StructuralSizer._vertex_xy_m(skel, col.vertex_idx)
        key = (round(xy[1], digits = 6), round(xy[2], digits = 6))
        push!(get!(() -> eltype(struc.columns)[], groups, key), col)
    end
    samples = NamedTuple{(:xy, :half), Tuple{NTuple{2, Float64}, Function}}[]
    for (xy, cols) in groups
        push!(samples, (xy = xy, half = d -> maximum(_column_half_dim_m(c, d) for c in cols)))
    end
    return samples
end

"""Closed boundary loops at `level`, each walked with the slab on the left."""
function _slab_boundary_loops(struc, level::Int)
    skel = struc.skeleton
    story = get(skel.stories, level, nothing)
    story === nothing && return Tuple{Vector{NTuple{2, Float64}}, Vector{Int}}[]
    vc = skel.geometry.vertex_coords
    efc = skel.geometry.edge_face_counts
    verts = Set(story.vertices)
    adj = Dict{Int, Vector{Int}}()
    for (e, (a, b)) in enumerate(skel.edge_indices)
        get(efc, e, 0) == 1 || continue
        (a in verts && b in verts) || continue
        abs(vc[a, 3] - vc[b, 3]) > 0.01 && continue
        push!(get!(() -> Int[], adj, a), b)
        push!(get!(() -> Int[], adj, b), a)
    end
    loops = Tuple{Vector{NTuple{2, Float64}}, Vector{Int}}[]
    seen = Set{Int}()
    for start in keys(adj)
        start in seen && continue
        loop = Int[start]
        prev, cur = 0, start
        for _ in 1:length(adj)
            nbrs = adj[cur]
            length(nbrs) == 2 || break
            nxt = nbrs[1] == prev ? nbrs[2] : nbrs[1]
            nxt == start && break
            push!(loop, nxt)
            prev, cur = cur, nxt
        end
        length(loop) < 3 && continue
        union!(seen, loop)
        poly = NTuple{2, Float64}[(vc[v, 1], vc[v, 2]) for v in loop]
        push!(loops, (poly, loop))
    end
    isempty(loops) && return loops
    areas = [abs(_polygon_area(poly)) for (poly, _) in loops]
    outer = argmax(areas)
    oriented = Tuple{Vector{NTuple{2, Float64}}, Vector{Int}}[]
    for (i, (poly, loop)) in enumerate(loops)
        area = _polygon_area(poly)
        # Exterior is counter-clockwise. A hole is clockwise, so its outward
        # normal steps into the opening and the slab covers the column there.
        want_positive = i == outer
        if (area > 0) != want_positive
            reverse!(poly)
            reverse!(loop)
        end
        push!(oriented, (poly, loop))
    end
    return oriented
end

_polygon_area(poly) = 0.5 * sum(
    poly[i][1] * poly[mod1(i + 1, length(poly))][2] -
    poly[mod1(i + 1, length(poly))][1] * poly[i][2]
    for i in eachindex(poly))

"""
    slab_vertex_overhang(struc) -> Dict{Int, NTuple{2,Float64}}

Displacement, in metres, from each boundary vertex to the slab edge.

The edge of a straight run is flush with the largest column face on that run.
A corner is where the two adjacent edges meet, so it follows both. Interior
vertices are absent. An empty dict means no column has a size yet.
"""
function slab_vertex_overhang(struc::BuildingStructure)
    shifts = Dict{Int, NTuple{2, Float64}}()
    skel = struc.skeleton
    skel.geometry === nothing && return shifts
    for level in keys(skel.stories)
        samples = _edge_column_samples(struc, level)
        isempty(samples) && continue
        for (poly, vids) in _slab_boundary_loops(struc, level)
            edge = StructuralSizer.story_slab_edge(poly, samples)
            for (k, run) in enumerate(edge.runs)
                for (j, e) in enumerate(run.edges)
                    p = poly[e]
                    xy = if j == 1
                        edge.outline[k]
                    else
                        (p[1] + run.outward[1] * run.width,
                         p[2] + run.outward[2] * run.width)
                    end
                    shifts[vids[e]] = (xy[1] - p[1], xy[2] - p[2])
                end
            end
        end
    end
    return shifts
end

"""
    slab_edge_strips(struc) -> Vector{NamedTuple}

The slab past the column centerlines, one entry per boundary edge of each
floor ([`StructuralSizer.floor_slab_edges`](@ref)).

Fields: `edge` (skeleton edge), `cell` (the cell on that edge), the floor
elevation `z` (m), `va`, `vb`
and their plan points `a`, `b` in metres (walked with the slab on the left),
the run's `outward` normal and `width` (m), and `corner_start`, `corner_end`:
the corner slab beyond the two run rectangles at each end (m², nonzero only
where a run starts). Grade faces have none.
"""
function slab_edge_strips(struc::BuildingStructure)
    skel = struc.skeleton
    out = NamedTuple[]
    (skel.geometry === nothing || isempty(struc.columns)) && return out
    vc = skel.geometry.vertex_coords
    edge_of = Dict{Tuple{Int, Int}, Int}(minmax(a, b) => e for (e, (a, b)) in enumerate(skel.edge_indices))
    cells_of_edge = Dict{Int, Vector{Int}}()
    floors = Float64[]
    for (ci, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        vis = skel.face_vertex_indices[cell.face_idx]
        isempty(vis) && continue
        z = Float64(vc[first(vis), 3])
        any(f -> abs(f - z) <= 0.01, floors) || push!(floors, z)
        for e in skel.face_edge_indices[cell.face_idx]
            push!(get!(() -> Int[], cells_of_edge, e), ci)
        end
    end
    for z in floors, loop in StructuralSizer.floor_slab_edges(struc, z)
        poly, vids, edge = loop.polygon, loop.vertices, loop.edge
        n = length(poly)
        nr = length(edge.runs)
        corner = zeros(n)
        for (k, run) in enumerate(edge.runs)
            prev = edge.runs[mod1(k - 1, nr)]
            i = run.edges[1]
            # ENGINEERING JUDGMENT: at a re-entrant corner the two run
            # rectangles overlap (negative area). The overlap is not
            # subtracted, so both runs carry it: a small, conservative excess.
            corner[i] = max(0.0, StructuralSizer.slab_edge_corner_area(
                poly[i], prev, run, edge.outline[k]))
        end
        for run in edge.runs, e in run.edges
            j = mod1(e + 1, n)
            eid = get(edge_of, minmax(vids[e], vids[j]), 0)
            cs = get(cells_of_edge, eid, Int[])
            length(cs) == 1 || continue
            push!(out, (edge = eid, cell = only(cs), z = z, va = vids[e], vb = vids[j],
                        a = poly[e], b = poly[j], outward = run.outward, width = run.width,
                        corner_start = corner[e], corner_end = corner[j]))
        end
    end
    return out
end

"""
Uniform width (m) of a strip's line load on its edge.

The run width, plus half of the corner slab at each end spread over the edge.
"""
function slab_edge_line_width(strip)
    L = hypot(strip.b[1] - strip.a[1], strip.b[2] - strip.a[2])
    L > 1e-9 || return 0.0
    # ENGINEERING JUDGMENT: the corner slab sits over the corner column. It
    # is spread along the two edges that meet there instead of applied at the
    # node; the column receives the same total, and the beam moment is larger.
    return strip.width + (strip.corner_start + strip.corner_end) / (2 * L)
end

"""Strips grouped by the cell whose pressure loads them."""
function slab_edge_strips_by_cell(struc::BuildingStructure)
    by_cell = Dict{Int, Vector{NamedTuple}}()
    for s in slab_edge_strips(struc)
        push!(get!(() -> NamedTuple[], by_cell, s.cell), s)
    end
    return by_cell
end

"""
    apply_facade_setback!(struc) -> struc

Move boundary vertices in from a drawn slab edge to column centerlines, once.

The setback is half the span-based column estimate and does not change when
columns are resized later. The slab edge then grows back out from these
centerlines with the columns (`slab_vertex_overhang`). A second call does nothing.
"""
function apply_facade_setback!(struc::BuildingStructure)
    skel = struc.skeleton
    haskey(skel.groups_vertices, :centerline_converted) && return struc
    skel.geometry === nothing && rebuild_geometry_cache!(skel)
    half = Float64(ustrip(u"m", StructuralSizer.estimate_column_size_from_span(
        _estimate_avg_span(skel)))) / 2
    half > 1e-6 || return struc
    vc = skel.geometry.vertex_coords
    efc = skel.geometry.edge_face_counts
    delta = Dict{Int, NTuple{2, Float64}}()
    for v in 1:size(vc, 1)
        normals = _unique_inward_normals(skel, vc, efc, v)
        isempty(normals) && continue
        dx = sum(n[1] * half for n in normals)
        dy = sum(n[2] * half for n in normals)
        hypot(dx, dy) > 1e-9 && (delta[v] = (dx, dy))
    end
    isempty(delta) || _shift_skeleton!(skel, delta)
    skel.groups_vertices[:centerline_converted] = Int[]
    return struc
end

"""Move vertices by `delta` (metres) and rebuild the edges, faces, and geometry cache."""
function _shift_skeleton!(skel::BuildingSkeleton, delta::Dict{Int, NTuple{2, Float64}})
    for (i, (dx, dy)) in delta
        c = Meshes.coords(skel.vertices[i])
        x = c.x isa Unitful.Quantity ? c.x + dx * u"m" : c.x + dx
        y = c.y isa Unitful.Quantity ? c.y + dy * u"m" : c.y + dy
        skel.vertices[i] = Meshes.Point(x, y, c.z)
    end
    for (i, (a, b)) in enumerate(skel.edge_indices)
        skel.edges[i] = Meshes.Segment(skel.vertices[a], skel.vertices[b])
    end
    for (i, vis) in enumerate(skel.face_vertex_indices)
        skel.faces[i] = Meshes.Ngon(skel.vertices[vis]...)
    end
    rebuild_geometry_cache!(skel)
    skel.lookup === nothing || build_lookup!(skel)
    return skel
end
