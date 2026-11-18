# Analysis fields beyond deflection: axial force and tributary polygons.
# Shell surface stress is written with the shell faces in build.jl.

"""
Signed axial-force extremum of each frame element, newtons.

Positive is tension, the sign `ElementInternalForces` already uses. The value
is the station whose absolute force is largest, the same choice as the JSON
frame view.
"""
function _element_axial(model::Asap.Model, elements)
    axial = Float32[]
    sizehint!(axial, length(elements))
    peak = 0.0
    for elem in elements
        force, _, _ = _compute_frame_analytical(elem, model)
        push!(axial, Float32(force))
        peak = max(peak, abs(force))
    end
    _assign_story_column_axial!(axial, model, elements)
    peak = maximum(abs, axial; init = 0.0)
    return axial, peak
end

"""
Column axial in a story-shell scene, from the vertical reactions.

The drawn columns stand on the skeleton and are not the solved members. Each
story is pinned at its column centres, and that pin's vertical reaction is
the load the column delivers. A lower column carries every story at and
above its top. Positive axial is tension, so compression is the negative of
the upward reaction.
"""
function _assign_story_column_axial!(axial, model, elements)
    analysis_scene_kind(model) === :story_shell || return axial
    drawn = analysis_drawn_only(model)
    drawn === nothing && return axial
    pins = Tuple{Float64, Float64, Float64, Float64}[]
    for (i, n) in enumerate(model.nodes)
        i in drawn.nodes && continue
        length(n.dof) < 3 && continue
        n.dof[3] && continue
        isassigned(n.reaction, 3) || continue
        x = ustrip(u"m", n.position[1])
        y = ustrip(u"m", n.position[2])
        z = ustrip(u"m", n.position[3])
        push!(pins, (x, y, z, ustrip(u"N", n.reaction[3])))
    end
    isempty(pins) && return axial
    for e in drawn.frames
        1 <= e <= length(elements) || continue
        el = elements[e]
        a = el.nodeStart.position
        b = el.nodeEnd.position
        z1 = ustrip(u"m", a[3])
        z2 = ustrip(u"m", b[3])
        abs(z1 - z2) < 0.05 && continue
        top = max(z1, z2)
        xy = z1 >= z2 ? (ustrip(u"m", a[1]), ustrip(u"m", a[2])) :
                        (ustrip(u"m", b[1]), ustrip(u"m", b[2]))
        R = 0.0
        for (x, y, z, Rz) in pins
            hypot(x - xy[1], y - xy[2]) < 1e-2 || continue
            z + 0.05 < top && continue
            R += Rz
        end
        axial[e] = Float32(-R)
    end
    return axial
end

const _TRIBUTARY_COLUMN = 0x00
const _TRIBUTARY_BEAM = 0x01
const _TRIBUTARY_WALL = 0x02
const _TRIBUTARY_NONE = 0xffffffff

"""0-based frame element of a skeleton edge, or a sentinel when the edge is not in the analysis model."""
function _element_for_edge(edges, edge_idx::Int)
    i = findfirst(isequal(edge_idx), edges)
    return isnothing(i) ? _TRIBUTARY_NONE : UInt32(i - 1)
end

"""Frame element of a member's first segment."""
function _member_element(struc::BuildingStructure, edges, member)
    segs = segment_indices(member)
    isempty(segs) && return _TRIBUTARY_NONE
    seg = first(segs)
    seg > length(struc.segments) && return _TRIBUTARY_NONE
    return _element_for_edge(edges, struc.segments[seg].edge_idx)
end

_scene_meters(x::Unitful.Length) = ustrip(u"m", x)
_scene_meters(x::Real) = Float64(x)

"""
Plan polygons of one member's assigned tributary.

`points` is the centerline, in order. `positions` are breakpoints along that
centerline, from 0 at the start to 1 at the end. `widths` are the full width
at each breakpoint, in the same length unit as `points`. Width varies
linearly between breakpoints. Each straight run is its own polygon, offset
by half the width to either side, so a kink does not fold the offset through
the corner. A run whose width is zero is omitted.
"""
function _tributary_ribbons(points::Vector{NTuple{2,Float64}},
                             positions::Vector{Float64},
                             widths::Vector{Float64})
    length(points) >= 2 || return Vector{NTuple{2,Float64}}[]
    length(positions) == length(widths) || return Vector{NTuple{2,Float64}}[]
    lengths = Float64[]
    total = 0.0
    for i in 1:(length(points) - 1)
        a, b = points[i], points[i + 1]
        L = hypot(b[1] - a[1], b[2] - a[2])
        push!(lengths, L)
        total += L
    end
    total > 1e-9 || return NTuple{2,Float64}[][]
    loops = Vector{NTuple{2,Float64}}[]
    covered = 0.0
    for (i, L) in enumerate(lengths)
        L <= 1e-9 && continue
        s0 = covered / total
        s1 = (covered + L) / total
        covered += L
        a, b = points[i], points[i + 1]
        dir = ((b[1] - a[1]) / L, (b[2] - a[2]) / L)
        normal = (-dir[2], dir[1])
        stations = Float64[s0, s1]
        for s in positions
            s0 + 1e-9 < s < s1 - 1e-9 && push!(stations, s)
        end
        sort!(stations)
        left = NTuple{2,Float64}[]
        right = NTuple{2,Float64}[]
        alive = false
        for s in stations
            w = _profile_width(positions, widths, s)
            w > 1e-8 && (alive = true)
            t = (s - s0) / (s1 - s0)
            p = (a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]))
            h = w / 2
            push!(left, (p[1] + h * normal[1], p[2] + h * normal[2]))
            push!(right, (p[1] - h * normal[1], p[2] - h * normal[2]))
        end
        alive || continue
        push!(loops, vcat(left, reverse(right)))
    end
    return loops
end

"""Width at station `s`, linear between the breakpoints."""
function _profile_width(positions::Vector{Float64}, widths::Vector{Float64}, s::Float64)
    s <= positions[1] && return widths[1]
    s >= positions[end] && return widths[end]
    i = searchsortedlast(positions, s)
    i = clamp(i, 1, length(positions) - 1)
    p0, p1 = positions[i], positions[i + 1]
    p1 == p0 && return widths[i + 1]
    return widths[i] + (widths[i + 1] - widths[i]) * (s - p0) / (p1 - p0)
end

"""Meters, whether the profile stored a length or a bare number of meters."""
_profile_width_m(w::Unitful.Length) = ustrip(u"m", w)
_profile_width_m(w::Real) = Float64(w)

"""Centerline of `beam`, one point per vertex, in meters."""
function _beam_centerline_m(struc, beam)
    segs = segment_indices(beam)
    isempty(segs) && return NTuple{2,Float64}[]
    edges = Int[struc.segments[si].edge_idx for si in segs if 1 <= si <= length(struc.segments)]
    isempty(edges) && return NTuple{2,Float64}[]
    verts = _ordered_chain_vertices(struc.skeleton, edges)
    return [_vertex_xy_m(struc.skeleton, v) for v in verts]
end

"""Ribbons of every beam that was given a width profile."""
function _profile_tributary_loops(struc)
    out = Tuple{Vector{NTuple{2,Float64}}, Int, Float64, UInt32}[]
    drawn = Set{Int}()
    for beam in struc.beams
        profile = beam.tributary_profile
        profile === nothing && continue
        points = _beam_centerline_m(struc, beam)
        length(points) < 2 && continue
        widths = [_profile_width_m(w) for w in profile.widths]
        loops = _tributary_ribbons(points, profile.positions, widths)
        isempty(loops) && continue
        segs = segment_indices(beam)
        edge = nothing
        z = 0.0
        for si in segs
            1 <= si <= length(struc.segments) || continue
            e = struc.segments[si].edge_idx
            push!(drawn, e)
            edge === nothing && (edge = e)
            v = struc.skeleton.edge_indices[e][1]
            z = _scene_meters(struc.skeleton.geometry.vertex_coords[v, 3])
        end
        edge === nothing && continue
        cell = _cell_on_edge(struc, edge)
        for loop in loops
            push!(out, (loop, edge, z, cell))
        end
    end
    return out, drawn
end

"""0-based index of the first cell on `edge`, or 0 when the edge bounds none."""
function _cell_on_edge(struc, edge_idx::Int)
    for (i, cell) in enumerate(struc.cells)
        edges = struc.skeleton.face_edge_indices[cell.face_idx]
        edge_idx in edges && return UInt32(i - 1)
    end
    return UInt32(0)
end

"""Append one plan polygon. Returns false when the loop has fewer than three vertices."""
function _push_plan!(pos::Vector{Float32}, counts::Vector{UInt32}, xy, z::Float64, origin)
    start = length(pos)
    n = 0
    for (x, y) in xy
        push!(pos, Float32(_scene_meters(x) - origin[1]),
                   Float32(_scene_meters(y) - origin[2]),
                   Float32(z - origin[3]))
        n += 1
    end
    if n < 3
        resize!(pos, start)
        return false
    end
    push!(counts, UInt32(n))
    return true
end

"""A flat plate or flat slab carries its area on columns and walls, not on the grid beams."""
function _cell_is_beamless(cell)
    ft = cell.floor_type
    return ft === :flat_plate || ft === :flat_slab
end

"""
True when wall piers cover this plan edge and their height includes `z`.

A pier runs from its story elevation through `base.L`, the same span
`_wall_pier_geometry` meshes, so a roof edge is included when the pier below
reaches it. Several collinear piers may share one edge; the edge is a wall
when their union covers it.
"""
function _edge_on_wall(struc::BuildingStructure, edge_idx::Int, z::Float64)
    skel = struc.skeleton
    v1, v2 = skel.edge_indices[edge_idx]
    vc = skel.geometry.vertex_coords
    P = (_scene_meters(vc[v1, 1]), _scene_meters(vc[v1, 2]))
    Q = (_scene_meters(vc[v2, 1]), _scene_meters(vc[v2, 2]))
    dx = Q[1] - P[1]
    dy = Q[2] - P[2]
    span = hypot(dx, dy)
    span < 1e-6 && return false
    ux, uy = dx / span, dy / span
    nx, ny = -uy, ux
    covered = Tuple{Float64, Float64}[]
    for wall in struc.walls
        haskey(skel.stories, wall.story) || continue
        z0 = _scene_meters(skel.stories[wall.story].elevation)
        height = _scene_meters(wall.base.L)
        height > 0 || continue
        z0 - 0.05 <= z <= z0 + height + 0.05 || continue
        A = (wall.x1 - P[1], wall.y1 - P[2])
        B = (wall.x2 - P[1], wall.y2 - P[2])
        max(abs(A[1] * nx + A[2] * ny), abs(B[1] * nx + B[2] * ny)) > 1e-3 && continue
        sA = A[1] * ux + A[2] * uy
        sB = B[1] * ux + B[2] * uy
        lo, hi = min(sA, sB), max(sA, sB)
        (hi < -1e-3 || lo > span + 1e-3) && continue
        push!(covered, (max(lo, 0.0), min(hi, span)))
    end
    isempty(covered) && return false
    sort!(covered)
    at = 0.0
    for (lo, hi) in covered
        lo > at + 1e-3 && return false
        at = max(at, hi)
    end
    return at >= span - 1e-3
end

"""
Who owns one cell-edge polygon.

A wall that covers the edge owns it, including the roof edge a pier reaches.
On a beamless floor the remaining edges belong to the columns. On a beam floor
a beam edge stays a beam, and any other edge belongs to the columns.
"""
function _tributary_kind_for_edge(struc, cell, edge_idx::Int, z::Float64, beam_edges)
    _edge_on_wall(struc, edge_idx, z) && return _TRIBUTARY_WALL
    if edge_idx in beam_edges && !_cell_is_beamless(cell)
        return _TRIBUTARY_BEAM
    end
    return _TRIBUTARY_COLUMN
end

"""
Tributary polygons on the slab plane, copied from `slab.tributary_polygons`.

Those loops are the column and wall shares, parabolic edges already sampled.
A beam that was given a width profile is a ribbon of that width along its
centerline, one polygon per straight run. A beam-supported cell with no
profile keeps the straight-skeleton edge polygons. A grillage cell is drawn
from its pan skeletons instead: the same split that loads the ribs.
`tributary_cell` is the 0-based cell index. A ribbon uses the first cell
on its edge.
"""
function _with_tributaries(packet::ScenePacket, design::BuildingDesign)
    struc = design.structure
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    origin = packet.origin
    edges = design.asap_model_frame_edge_indices
    pos = Float32[]
    counts = UInt32[]
    owners = UInt32[]
    kinds = UInt8[]
    cells = UInt32[]
    covered = Set{Int}()
    grill_cells = _grillage_cells(struc)
    pan_edges = Set{Int}()

    for slab in struc.slabs
        fl = _grillage_level(slab)
        if fl !== nothing
            z = _slab_face_z_m(struc, slab)
            cell = isempty(slab.cell_indices) ? 0 : UInt32(first(slab.cell_indices) - 1)
            for (edge_idx, xy) in grillage_tributary_loops(struc, slab, fl)
                _push_plan!(pos, counts, xy, z, origin) || continue
                push!(pan_edges, edge_idx)
                push!(owners, _element_for_edge(edges, edge_idx))
                push!(kinds, _TRIBUTARY_BEAM)
                push!(cells, cell)
            end
            for ci in slab.cell_indices
                push!(covered, ci)
            end
        end
        for region in slab.tributary_polygons
            region.cell_idx in grill_cells && continue
            1 <= region.cell_idx <= length(struc.cells) || continue
            face_verts = skel.face_vertex_indices[struc.cells[region.cell_idx].face_idx]
            isempty(face_verts) && continue
            z = _scene_meters(vc[face_verts[1], 3])
            _push_plan!(pos, counts, region.xy, z, origin) || continue
            push!(owners, _tributary_owner(struc, edges, region))
            push!(kinds, region.kind === :wall ? _TRIBUTARY_WALL : _TRIBUTARY_COLUMN)
            push!(cells, UInt32(region.cell_idx - 1))
            push!(covered, region.cell_idx)
        end
    end

    ribbons, profiled_edges = _profile_tributary_loops(struc)
    for (xy, edge_idx, z, cell) in ribbons
        edge_idx in pan_edges && continue
        _push_plan!(pos, counts, xy, z, origin) || continue
        push!(owners, _element_for_edge(edges, edge_idx))
        push!(kinds, _TRIBUTARY_BEAM)
        push!(cells, cell)
    end

    beam_edges = Set{Int}()
    for beam in struc.beams
        for seg_idx in segment_indices(beam)
            seg_idx > length(struc.segments) && continue
            push!(beam_edges, struc.segments[seg_idx].edge_idx)
        end
    end

    for (cell_idx, cell) in enumerate(struc.cells)
        cell_idx in covered && continue
        _cell_is_beamless(cell) && continue
        tribs = cell_edge_tributaries(struc, cell_idx)
        isnothing(tribs) && continue
        face_edges = skel.face_edge_indices[cell.face_idx]
        face_verts = skel.face_vertex_indices[cell.face_idx]
        n_verts = length(face_verts)
        n_verts < 2 && continue
        z = _scene_meters(vc[face_verts[1], 3])
        for trib in tribs
            trib.area < 1e-8 && continue
            local_idx = trib.local_edge_idx
            (1 <= local_idx <= length(face_edges) && local_idx <= n_verts) || continue
            global_edge = face_edges[local_idx]
            global_edge in profiled_edges && continue
            a = face_verts[local_idx]
            b = face_verts[mod1(local_idx + 1, n_verts)]
            xy = Asap.vertices(trib, (vc[a, 1], vc[a, 2]), (vc[b, 1], vc[b, 2]))
            _push_plan!(pos, counts, xy, z, origin) || continue
            push!(owners, _element_for_edge(edges, global_edge))
            push!(kinds, _tributary_kind_for_edge(struc, cell, global_edge, z, beam_edges))
            push!(cells, UInt32(cell_idx - 1))
        end
    end

    isempty(counts) && return packet
    meta = copy(packet.meta)
    tally = copy(meta["counts"])
    tally["tributary_polygons"] = length(counts)
    meta["counts"] = tally
    extra = SceneBuffer[
        SceneBuffer("tributary_position", pos),
        SceneBuffer("tributary_count", counts),
        SceneBuffer("tributary_element", owners),
        SceneBuffer("tributary_kind", kinds),
        SceneBuffer("tributary_cell", cells),
    ]
    return ScenePacket(packet.stages, origin, meta, vcat(packet.buffers, extra))
end

"""Frame element of a stored slab share. A wall has no frame element."""
function _tributary_owner(struc, edges, region)
    if region.kind === :column && 1 <= region.owner <= length(struc.columns)
        return _member_element(struc, edges, struc.columns[region.owner])
    end
    return _TRIBUTARY_NONE
end
