# Flexible floors: lines of seismic-system walls, collector ties along them,
# and the center-of-mass displacement read between them.
#
# ASCE 7-22 §12.8.4 (corpus: asce-7-22, PDF page 187) distributes the story
# shear to the vertical elements of the seismic force-resisting system, and
# §12.8.4.1 has a flexible diaphragm account for the position and distribution
# of the supported masses. Commentary C12.8.4.1 (PDF page 727) has those
# elements resist the mass tributary to them with no explicitly computed
# torsion. The declared system names the elements ([`seismic_members`](@ref));
# this file arranges them into lines.
#
# The floor between two lines is a simple span. Along a line, the slab over the
# walls is a collector: the walls on one line move together along it and share
# the line force by stiffness. That tie is the only constraint added; across
# the lines the floor stays flexible.

"""One line of seismic-system walls parallel to a plan axis, at one floor."""
struct DiaphragmLine
    "Floor elevation [m]: the top of the walls on the line."
    elevation_m::Float64
    "Plan axis the line resists, `:x` or `:y`."
    direction::Symbol
    "Position of the line along the other plan axis [m]."
    offset_m::Float64
    "Indices into `struc.walls`."
    walls::Vector{Int}
    "Wall-shell nodes at the floor, in order along the line."
    nodes::Vector{Asap.Node}
end

"""
Lines of seismic-system walls on a flexible floor, and the collector ties along them.

`links` ties every node of a line after the first to the first, in the global
translation along the line only. Every other degree of freedom is released.
"""
struct FlexibleDiaphragmLayout
    "Unit vector of the first plan axis."
    plan_axis::NTuple{2, Float64}
    lines::Vector{DiaphragmLine}
    links::Vector{Asap.RigidLink}
end

"Walls whose positions across their axis agree within this [m] are on one line."
const _DIAPHRAGM_LINE_TOL_M = 1e-3

"A direction cosine within this of 0 or 1 is perpendicular or parallel to a plan axis."
const _DIAPHRAGM_AXIS_TOL = 1e-6

"""
    flexible_diaphragm_layout!(struc, lateral::LateralDesign) -> FlexibleDiaphragmLayout

Build the wall lines of a flexible floor from the declared seismic system and
store them on `struc.diaphragm_layout`.

For each plan axis, that axis's system names its walls
([`seismic_members`](@ref)). A wall parallel to the axis resists it; a wall
perpendicular to it resists the other axis. Walls whose tops are at one floor
and whose positions across the axis agree within 1 mm form one line, and the
wall-top nodes of the line are tied along it.

Throws when the floor has rigid links or a semirigid shell, when a strut is
present, when an axis's system includes frames, when a wall is on neither
plan axis, or when the plan axes are not the global axes: the tie acts on a
global translation.
"""
function flexible_diaphragm_layout!(struc::BuildingStructure, lateral::LateralDesign)
    struc.diaphragm_layout = nothing
    isempty(struc.asap_rigid_links) || throw(ArgumentError(
        "flexible diaphragm: the floor has rigid links. Wall lines are for a flexible floor."))
    _has_semirigid_diaphragm(struc) && throw(ArgumentError(
        "flexible diaphragm: the floor is a semirigid shell, not flexible."))
    isempty(struc.struts) || throw(ArgumentError(
        "flexible diaphragm: a strut is a brace and is not on a wall line."))
    axis = lateral.plan_axis
    dof = _global_translation_dof(axis)
    lines = DiaphragmLine[]
    for direction in (:x, :y)
        system = direction === :x ? lateral.system_x : lateral.system_y
        members = seismic_members(struc, system)
        (isempty(members.beams) && isempty(members.columns)) || throw(ArgumentError(
            "flexible diaphragm: the $direction-axis system $(typeof(system)) includes " *
            "frames. Frame lines on a flexible floor are not built; only " *
            "seismic-system walls form lines here."))
        append!(lines, _wall_lines(struc, members.walls, axis, direction))
    end
    links = Asap.RigidLink[]
    for line in lines
        k = dof[line.direction]
        release = ntuple(i -> i != k, 6)
        master = first(line.nodes)
        for nd in line.nodes[2:end]
            push!(links, Asap.RigidLink(master, nd; release, id=:collector))
        end
    end
    layout = FlexibleDiaphragmLayout(axis, lines, links)
    struc.diaphragm_layout = layout
    return layout
end

"""
    lateral_solve_links(struc) -> Vector{Asap.RigidLink}

Constraints every lateral-stage solve uses: the rigid-diaphragm links, and on
a flexible floor the collector ties along its wall lines. A semirigid floor
adds none: the membrane is in the stiffness.
"""
function lateral_solve_links(struc::BuildingStructure)
    layout = struc.diaphragm_layout
    layout isa FlexibleDiaphragmLayout || return struc.asap_rigid_links
    return vcat(struc.asap_rigid_links, layout.links)
end

"""The stored layout, checked against the analysis plan axis when one is given."""
function _require_flexible_layout(struc, axis=nothing)
    layout = struc.diaphragm_layout
    layout isa FlexibleDiaphragmLayout || throw(ArgumentError(
        "flexible diaphragm: the wall lines are not built. The ordinary-wall stage " *
        "builds them from the declared seismic system (flexible_diaphragm_layout!)."))
    if axis !== nothing && maximum(abs.(layout.plan_axis .- axis)) > 1e-12
        throw(ArgumentError(
            "flexible diaphragm: the wall lines were built on plan axis " *
            "$(layout.plan_axis) and the analysis uses $(axis)."))
    end
    return layout
end

"""Global translation (1 = X, 2 = Y) along each plan axis. A rotated axis throws."""
function _global_translation_dof(axis::NTuple{2, Float64})
    e1, _ = plan_axes(axis)
    abs(abs(e1[1]) - 1) <= _DIAPHRAGM_AXIS_TOL && return (x=1, y=2)
    abs(abs(e1[2]) - 1) <= _DIAPHRAGM_AXIS_TOL && return (x=2, y=1)
    throw(ArgumentError(
        "flexible diaphragm: the plan axis $axis is not a global axis. The collector " *
        "tie along a wall line acts on a global translation, so a rotated plan is not built."))
end

"""Runs of `items`, already sorted by `key`, whose consecutive keys differ by at most `tol`."""
function _runs_within(items, key, tol)
    runs = Vector{eltype(items)}[]
    for item in items
        if isempty(runs) || key(item) - key(last(runs[end])) > tol
            push!(runs, [item])
        else
            push!(runs[end], item)
        end
    end
    return runs
end

"""Lines along `direction` formed by the walls `wall_indices`, floor by floor."""
function _wall_lines(struc, wall_indices, axis::NTuple{2, Float64}, direction::Symbol)
    e1, e2 = plan_axes(axis)
    d, n = direction === :x ? (e1, e2) : (e2, e1)
    placed = Tuple{Float64, Float64, Int}[]   # (top elevation, offset, wall)
    for i in wall_indices
        g = _wall_pier_geometry(struc.walls[i], struc.skeleton)
        dx, dy = g.x2 - g.x1, g.y2 - g.y1
        L = hypot(dx, dy)
        L > 0 || throw(ArgumentError("flexible diaphragm: wall $i has no plan length."))
        c = abs(dx * d[1] + dy * d[2]) / L
        c <= _DIAPHRAGM_AXIS_TOL && continue
        c >= 1 - _DIAPHRAGM_AXIS_TOL || throw(ArgumentError(
            "flexible diaphragm: wall $i is on neither plan axis. A wall line runs " *
            "along one axis."))
        offset = 0.5 * ((g.x1 + g.x2) * n[1] + (g.y1 + g.y2) * n[2])
        push!(placed, (g.z_top, offset, i))
    end
    sort!(placed; by=first)
    lines = DiaphragmLine[]
    for floor in _runs_within(placed, first, WALL_CUT_ZTOL_M)
        z = sum(first, floor) / length(floor)
        sort!(floor; by=item -> item[2])
        for run in _runs_within(floor, item -> item[2], _DIAPHRAGM_LINE_TOL_M)
            offset = sum(item -> item[2], run) / length(run)
            walls = sort!([item[3] for item in run])
            push!(lines, DiaphragmLine(z, direction, offset, walls,
                _line_nodes(struc, walls, z, d)))
        end
    end
    return lines
end

"""Wall-shell nodes at elevation `z` on the walls of one line, in order along `d`."""
function _line_nodes(struc, walls, z, d)
    seen = Set{UInt64}()
    stations = Tuple{Float64, Asap.Node}[]
    for i in walls
        for sh in _pier_by_wall_index(struc.wall_mesh, i).shells
            for nd in sh.nodes
                abs(ustrip(u"m", nd.position[3]) - z) <= WALL_CUT_ZTOL_M || continue
                id = objectid(nd)
                id in seen && continue
                push!(seen, id)
                s = ustrip(u"m", nd.position[1]) * d[1] + ustrip(u"m", nd.position[2]) * d[2]
                push!(stations, (s, nd))
            end
        end
    end
    length(stations) >= 2 || throw(ArgumentError(
        "flexible diaphragm: walls $walls have fewer than two shell nodes at $z m."))
    sort!(stations; by=first)
    return [nd for (_, nd) in stations]
end

"""Lines of `layout` at `elevation_m` along `direction`, ordered by offset."""
function _diaphragm_lines_at(layout::FlexibleDiaphragmLayout, elevation_m::Real,
                             direction::Symbol)
    lines = [line for line in layout.lines
             if line.direction === direction &&
                abs(line.elevation_m - elevation_m) <= WALL_CUT_ZTOL_M]
    return sort!(lines; by=line -> line.offset_m)
end

# ------------------------------------------------------------------------------
# What a strip of floor between two lines carries
# ------------------------------------------------------------------------------

"""
Effective seismic weight of an ELF level between two positions on the unit plan
axis `n` [kN], as a function `(lo, hi) -> weight`.

Each floor cell spreads its effective seismic weight uniformly over its face.
Wall and frame self-weight are the items ELF lumps on this level
([`_elf_weight_items`](@ref)), a wall along its plan length. Over the whole
floor the measure equals the level's `weight_kN`; that is checked here.
"""
function _strip_measure(struc, level::ElfLevel, n::NTuple{2, Float64})
    skel = struc.skeleton
    elevs = _elf_story_elevations(skel)
    key = _elf_elevation_key(level.elevation_m, elevs)
    cell_by_face = Dict(cell.face_idx => cell for cell in struc.cells)
    faces = Tuple{Vector{NTuple{2, Float64}}, Float64}[]
    for face in skel.stories[level.story].faces
        cell = get(cell_by_face, face, nothing)
        cell === nothing && continue
        # ASCE 7-22 §12.7.2 (corpus: asce-7-22, PDF page 184), as ELF uses it.
        push!(faces, (_face_plan_vertices(skel, face),
                      ustrip(u"kN", effective_seismic_weight(cell))))
    end
    items, _ = _elf_weight_items(struc, elevs)
    pieces = [(w, a, b) for (k, w, a, b) in items if k == key]
    function measure(lo, hi)
        total = 0.0
        for (pts, w) in faces
            total += w * _strip_area(pts, n, lo, hi) / _polygon_area_centroid(pts)[3]
        end
        for (w, a, b) in pieces
            total += w * _strip_fraction(a, b, n, lo, hi)
        end
        return total
    end
    whole = measure(-Inf, Inf)
    abs(whole - level.weight_kN) <= 1e-6 * max(1.0, level.weight_kN) || throw(ArgumentError(
        "flexible diaphragm: the weight spread over story $(level.story) is $whole kN " *
        "and the ELF level weight is $(level.weight_kN) kN."))
    return measure
end

"""
Floor width of a wind level between two positions on the unit plan axis `n`
[m], as a function `(lo, hi) -> width`.

The width is the floor outline projected onto the axis across the lines. The
Chapter 27 wall pressures at one height are uniform across the building
width (ASCE 7-22 Figure 27.3-1, corpus: asce-7-22, PDF page 344), so the level
force is uniform per unit of that width.
"""
function _strip_measure(struc, level::WindStoryLevel, n::NTuple{2, Float64})
    spans = NTuple{2, Float64}[]
    for loop in level.outline
        isempty(loop) && continue
        push!(spans, extrema(p[1] * n[1] + p[2] * n[2] for p in loop))
    end
    isempty(spans) && throw(ArgumentError(
        "flexible diaphragm: story $(level.story) has no floor outline."))
    sort!(spans; by=first)
    merged = [spans[1]]
    for (a, b) in spans[2:end]
        if a <= merged[end][2]
            merged[end] = (merged[end][1], max(merged[end][2], b))
        else
            push!(merged, (a, b))
        end
    end
    return (lo, hi) -> sum(max(0.0, min(b, hi) - max(a, lo)) for (a, b) in merged)
end

"""Area of the polygon `pts` between `lo ≤ p·n ≤ hi` [m²]. An infinite bound is open."""
function _strip_area(pts, n, lo, hi)
    poly = collect(pts)
    isfinite(lo) && (poly = _clip_halfplane(poly, n, lo, 1.0))
    isfinite(hi) && (poly = _clip_halfplane(poly, n, hi, -1.0))
    length(poly) < 3 && return 0.0
    A2 = 0.0
    for i in eachindex(poly)
        x1, y1 = poly[i]
        x2, y2 = poly[mod1(i + 1, length(poly))]
        A2 += x1 * y2 - x2 * y1
    end
    return abs(A2) / 2
end

"""The part of `poly` with `side·(p·n − c) ≥ 0` (Sutherland–Hodgman, one edge)."""
function _clip_halfplane(poly, n, c, side)
    out = NTuple{2, Float64}[]
    isempty(poly) && return out
    f(p) = side * (p[1] * n[1] + p[2] * n[2] - c)
    prev = poly[end]
    fprev = f(prev)
    for p in poly
        fp = f(p)
        if fp >= 0
            fprev < 0 && push!(out, _edge_crossing(prev, p, fprev, fp))
            push!(out, p)
        elseif fprev >= 0
            push!(out, _edge_crossing(prev, p, fprev, fp))
        end
        prev, fprev = p, fp
    end
    return out
end

function _edge_crossing(a, b, fa, fb)
    t = fa / (fa - fb)
    return (a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]))
end

"""
Fraction of a uniform weight on segment `a`–`b` lying in `lo ≤ p·n < hi`.

A segment with no extent across `n` is a point: it is in the strip or not,
and the half-open strip puts a point on a shared bound in exactly one strip.
"""
function _strip_fraction(a, b, n, lo, hi)
    p1 = a[1] * n[1] + a[2] * n[2]
    p2 = b[1] * n[1] + b[2] * n[2]
    pmin, pmax = minmax(p1, p2)
    pmax - pmin <= 1e-12 && return (lo <= pmin < hi) ? 1.0 : 0.0
    return max(0.0, min(pmax, hi) - max(pmin, lo)) / (pmax - pmin)
end

# ------------------------------------------------------------------------------
# Center-of-mass displacement
# ------------------------------------------------------------------------------

"""
Displacement of a flexible floor at plan point `p`, along the plan axis `direction` [m].

The point lies between two wall lines of that axis at the floor, and the floor
between them is read as a straight line. That neglects in-plane diaphragm
deformation, which ASCE 7-22 §12.8.6.5 and commentary C12.8.6 (corpus:
asce-7-22, PDF pages 188 and 729) permit for story drift. A line's
displacement is the largest-magnitude displacement of its wall-top nodes along
the axis; the collector tie makes them equal. A point outside the outermost
lines throws: the floor beyond them is not extrapolated.
"""
function _flexible_disp_at(u, layout::FlexibleDiaphragmLayout, elevation_m::Real,
                           direction::Symbol, p)
    e1, e2 = plan_axes(layout.plan_axis)
    d, n = direction === :x ? (e1, e2) : (e2, e1)
    lines = _diaphragm_lines_at(layout, elevation_m, direction)
    isempty(lines) && throw(ArgumentError(
        "flexible diaphragm: no seismic-system wall line along $direction at " *
        "$(elevation_m) m to read the center-of-mass drift from."))
    s = p[1] * n[1] + p[2] * n[2]
    lo = first(lines).offset_m
    hi = last(lines).offset_m
    (lo - _DIAPHRAGM_LINE_TOL_M <= s <= hi + _DIAPHRAGM_LINE_TOL_M) || throw(ArgumentError(
        "flexible diaphragm: the center of mass at $(p) m is outside the outermost " *
        "wall lines along $direction at $(elevation_m) m (they span $lo to $hi m " *
        "across the axis). The floor beyond them is not extrapolated."))
    length(lines) == 1 && return _line_displacement(u, only(lines), d)
    s = clamp(s, lo, hi)
    k = clamp(searchsortedlast([line.offset_m for line in lines], s), 1, length(lines) - 1)
    a, b = lines[k], lines[k + 1]
    t = (s - a.offset_m) / (b.offset_m - a.offset_m)
    return (1 - t) * _line_displacement(u, a, d) + t * _line_displacement(u, b, d)
end

"""Largest-magnitude displacement along `d` of the nodes of one line [m]."""
function _line_displacement(u, line::DiaphragmLine, d)
    best = 0.0
    for nd in line.nodes
        g = nd.globalID
        v = u[g[1]] * d[1] + u[g[2]] * d[2]
        abs(v) > abs(best) && (best = v)
    end
    return best
end
