# =============================================================================
# One shell for the slabs and beams of a story
# =============================================================================
#
# Neighbouring panels share nodes. Each triangle takes the thickness of the
# slab it sits in. Beams are frames on those nodes. Concrete hangs below the
# soffit by its centroid. Steel sits on the nodes.
#
# Slab bars are sized from the shell moments. Each beam's shell demand is
# returned for `size_beams!`, which takes the larger of it and the tributary
# demand (see story_shell_beams.jl).

"""Section on the beam, or the shared section of its member group."""
function _story_beam_section(struc, beam)
    sec = section(beam)
    sec !== nothing && return sec
    gid = group_id(beam)
    gid === nothing && return nothing
    group = get(struc.member_groups, gid, nothing)
    group === nothing && return nothing
    return group.section
end

"""Ordered vertex indices of a beam's segments."""
function _story_vertex_chain(struc, beam)
    skel = struc.skeleton
    pairs = Tuple{Int, Int}[]
    for si in segment_indices(beam)
        e = struc.segments[si].edge_idx
        push!(pairs, Tuple(skel.edge_indices[e]))
    end
    isempty(pairs) && return Int[]
    length(pairs) == 1 && return Int[pairs[1][1], pairs[1][2]]
    adj = Dict{Int, Vector{Int}}()
    for (a, b) in pairs
        push!(get!(() -> Int[], adj, a), b)
        push!(get!(() -> Int[], adj, b), a)
    end
    ends = Int[v for (v, ns) in adj if length(ns) == 1]
    start = isempty(ends) ? first(keys(adj)) : minimum(ends)
    ordered = Int[start]
    prev, cur = 0, start
    for _ in 1:length(pairs)
        nxt = 0
        for cand in adj[cur]
            cand == prev && continue
            cand in ordered && continue
            nxt = cand
            break
        end
        nxt == 0 && break
        push!(ordered, nxt)
        prev, cur = cur, nxt
    end
    return ordered
end

_story_metres(x) = x isa Quantity ? uconvert(u"m", x) : x * u"m"

"""
Whole-beam release for the story shell, start and end along `chain`.

The frame model's per-element releases ([`resolve_edge_releases`](@ref)) put
a released end at a skeleton vertex: the start vertex of an edge for
`:freefixed`, its end vertex for `:fixedfree`, both for `:freefree` and
`:joist`. The shell releases the same vertices, so both models give a beam
the same end fixity. Only the two ends of `chain` can be released.
"""
function _story_beam_release(struc, beam, chain, material)
    segs = [struc.segments[si] for si in segment_indices(beam)]
    rels = resolve_edge_releases(beam, segs, material)
    released = Set{Int}()
    for (seg, rel) in zip(segs, rels)
        a, b = struc.skeleton.edge_indices[seg.edge_idx]
        rel in (:freefixed, :freefree, :joist) && push!(released, a)
        rel in (:fixedfree, :freefree, :joist) && push!(released, b)
    end
    s, e = first(chain) in released, last(chain) in released
    s && e && return (length(rels) == 1 && only(rels) === :joist) ? :joist : :freefree
    s && return :freefixed
    e && return :fixedfree
    return :fixedfixed
end

"""Largest slab thickness touching this beam, in metres. `nothing` when no slab touches it."""
function _story_beam_thickness(struc, beam, thickness_of_face)
    hs = typeof(1.0u"m")[]
    skel = struc.skeleton
    for si in segment_indices(beam)
        va, vb = skel.edge_indices[struc.segments[si].edge_idx]
        for (face, h) in thickness_of_face
            vs = skel.face_vertex_indices[face]
            (va in vs && vb in vs) || continue
            push!(hs, h)
        end
    end
    return isempty(hs) ? nothing : maximum(hs)
end

"""Structural steel recorded on the beam's material volumes, or `nothing`."""
function _recorded_structural_steel(beam)
    for mat in keys(volumes(beam))
        mat isa StructuralSizer.StructuralSteel && return mat
    end
    return nothing
end

"""
Concrete for RC sections. Otherwise the section's own material, then the steel
recorded on the beam when it was sized, then the story-wide `steel`.

A catalog shape carries no material. The beam's volume key is the material its
sizing options used, so a framing level sized in a different steel than the
girders keeps that steel in the shell.
"""
function _story_beam_material(sec, concrete, steel, recorded = nothing)
    if sec isa RCBeamSection || sec isa RCTBeamSection
        return concrete
    end
    if hasproperty(sec, :material) && getfield(sec, :material) !== nothing
        return getfield(sec, :material)
    end
    recorded isa StructuralSizer.StructuralSteel && return recorded
    steel === nothing || return steel
    throw(ArgumentError("$(typeof(sec)) has no material for the story shell; pass `steel`"))
end

"""True when `origin` is the last point of the beam line `xy`. Throws when it is at neither end."""
function _story_origin_at_end(xy, origin; tol::Float64 = 1e-3)
    da = hypot(xy[1][1] - origin[1], xy[1][2] - origin[2])
    db = hypot(xy[end][1] - origin[1], xy[end][2] - origin[2])
    min(da, db) <= tol || throw(ArgumentError(
        "composite field origin $origin is not at an end of the beam line"))
    return db < da
end

"""
`section_at` for [`StructuralSizer.story_shell`](@ref): the composite inertia
of each piece of a beam in `composite_at`, by its normalized station on the
building-model field. Other beams keep their section.
"""
function _story_composite_section_at(composite_at)
    isempty(composite_at) && return nothing
    return function (beam, station)
        c = get(composite_at, beam.id, nothing)
        c === nothing && return beam.section
        total = sum(hypot(beam.xy[k + 1][1] - beam.xy[k][1], beam.xy[k + 1][2] - beam.xy[k][2])
                    for k in 1:(length(beam.xy) - 1))
        s = clamp(station / total, 0.0, 1.0)
        c.flip && (s = 1.0 - s)
        return StructuralSizer.section_with_strong_inertia(beam.section,
                                                          composite_stiffness_at(c.profile, s))
    end
end

"""Fix uz at the shell node on each support point, and anchor the rigid-body modes."""
function _pin_story_supports!(nodes, pts)
    used = IdDict{Asap.Node, Nothing}()
    for (x, y) in pts
        best, bestd = nodes[1], Inf
        for n in nodes
            d = hypot(ustrip(u"m", n.position[1]) - x, ustrip(u"m", n.position[2]) - y)
            if d < bestd
                best = n
                bestd = d
            end
        end
        bestd <= 1e-3 || throw(ArgumentError("no shell node at support ($x, $y)"))
        haskey(used, best) && continue
        used[best] = nothing
        best.dof[3] = false
    end
    anchored = false
    for n in nodes
        n.dof[3] && continue
        if !anchored
            n.dof[1] = false
            n.dof[2] = false
            n.dof[6] = false
            anchored = true
        else
            n.dof[2] = false
            break
        end
    end
    return length(used)
end

function _column_support_points(struc, level)
    pts = NTuple{2, Float64}[]
    skel = struc.skeleton
    for col in struc.columns
        hasproperty(col, :story) || continue
        col.story == level || continue
        push!(pts, StructuralSizer._vertex_xy_m(skel, col.vertex_idx))
    end
    return pts
end

"""Length of a column, in metres, from its segment."""
function _column_length_m(struc, col)
    si = first(segment_indices(col))
    e = struc.segments[si].edge_idx
    return ustrip(u"m", struc.skeleton.geometry.edge_lengths[e])
end

"""
The Asap section the frame model would give `col`, or `nothing` when the
column has no section this shell can turn into one.

Concrete goes through [`StructuralSizer.to_asap_section`](@ref), which applies
ACI 318-11 §10.10.4.1 (0.70 Ig) once. This function does not apply it again.
"""
function _column_asap_section(col, concrete, steel)
    sec = section(col)
    sec === nothing && return nothing
    if sec isa RCColumnSection || sec isa RCCircularSection
        mat = col.concrete === nothing ? concrete : col.concrete
        return StructuralSizer.to_asap_section(sec, mat)
    elseif sec isa ISymmSection || sec isa HSSRectSection || sec isa HSSRoundSection
        mat = hasproperty(sec, :material) && getfield(sec, :material) !== nothing ?
              getfield(sec, :material) : steel
        mat === nothing && return nothing
        return StructuralSizer.to_asap_section(sec, mat)
    end
    return nothing
end

"""
Rotational stiffness `(krx, kry)` in N·m/rad that `col` gives the floor joint
at one of its ends. `nothing` when the column has no usable section.

# ENGINEERING JUDGMENT
Slope-deflection stiffness of a prismatic member with the far end fixed and
no sidesway: `4EI/L` about each bending axis. The far end of a column standing
on a fixed base is fixed, so this is that column. A column whose far end is
another floor joint can rotate there, and `4EI/L` is then an upper bound.
`Ix` resists rotation about the axis perpendicular to c2, as
[`_apply_column_roll!`](@ref) places it, and `θ` carries that into global X
and Y. A diagonal spring has no cross term, so a column whose c1 is not along
X or Y loses the product stiffness.
"""
function _column_end_stiffness(struc, col, concrete, steel)
    asap = _column_asap_section(col, concrete, steel)
    asap === nothing && return nothing
    L = _column_length_m(struc, col)
    L > 0 || return nothing
    E = ustrip(u"Pa", asap.E)
    Ix = ustrip(u"m^4", asap.Ix)
    Iy = ustrip(u"m^4", asap.Iy)
    s, c = sincos(col.θ)
    klz = 4 * E * Ix / L
    kly = 4 * E * Iy / L
    return (kly * s^2 + klz * c^2, kly * c^2 + klz * s^2)
end

"""Shell node within 1 mm of `(x, y)`, or `nothing`."""
function _shell_node_at(nodes, x, y)
    best, bestd = nodes[1], Inf
    for n in nodes
        d = hypot(ustrip(u"m", n.position[1]) - x, ustrip(u"m", n.position[2]) - y)
        d < bestd && ((best, bestd) = (n, d))
    end
    return bestd <= 1e-3 ? best : nothing
end

"""
Grounded rotational springs for the columns below this story and the columns
above it, on the shell nodes at those columns. Columns with no section are
skipped. Stiffnesses at one node add.
"""
function _story_column_springs(struc, level, nodes, concrete, steel)
    isempty(nodes) && return Asap.Spring[]
    acc = Dict{Asap.Node, NTuple{2, Float64}}()
    for col in struc.columns
        col.story == level || col.story == level + 1 || continue
        k = _column_end_stiffness(struc, col, concrete, steel)
        k === nothing && continue
        x, y = StructuralSizer._vertex_xy_m(struc.skeleton, col.vertex_idx)
        node = _shell_node_at(nodes, x, y)
        node === nothing && continue
        old = get(acc, node, (0.0, 0.0))
        acc[node] = (old[1] + k[1], old[2] + k[2])
    end
    springs = Asap.Spring[]
    for (node, (krx, kry)) in acc
        (krx == 0.0 && kry == 0.0) && continue
        push!(springs, Asap.Spring(node; krx = krx * u"N*m/rad", kry = kry * u"N*m/rad",
                                   id = :column))
    end
    return springs
end

"""Local end forces of each frame piece, grouped by beam id. Newtons and N·m."""
function _shell_beam_forces(frames)
    grouped = Dict{Symbol, Vector{Vector{Float64}}}()
    for el in frames
        push!(get!(() -> Vector{Float64}[], grouped, el.id), copy(el.forces))
    end
    return grouped
end

"""
    analyze_story_shell(struc, level; target_edge, concrete, steel, support_points,
                         composite_service, solve) -> NamedTuple

Mesh every slab on `level` as one shell and connect the beams that have a
section. A beam with no section is skipped. The story is `analyzed` only
when every beam on the story had a section and the shell solved.

This is [`build_story_shell`](@ref) followed by [`solve_story_shell!`](@ref).
A caller that solves the same story again, as beam or column sections
change, keeps the [`StoryShell`](@ref) (`shell` in the result) and calls
`solve_story_shell!` on it instead of meshing again.

The beam-force solve uses [`total_factored_pressure`](@ref) on each panel.
Each beam also takes its own weight. Slab bars use the service dead and
live pressures, patterned and factored inside
[`story_panel_reinforcement`](@ref). Supports are the column centres on
this story, unless `support_points` is given as `(x, y)` pairs in metres.

`steel` is the material of a steel section that carries none, as catalog
shapes chosen by `size_beams!` do.

Each beam's ends take the frame model's release ([`resolve_edge_releases`](@ref)):
a steel gravity beam on simple connections is pinned in both models, and
the slab carries the hogging over its supports.

# ENGINEERING JUDGMENT
Asap frees rotation only. The beam hangs below the slab on a rigid offset,
so a released end still passes the beam's axial force, and that force times
the offset is a small end moment about the slab mid-plane. It is kept and is
part of the shell demand.

AISC 360-16 §B3.4a (corpus: aisc-360-16, page 69): a simple connection
transmits a negligible moment and may be assumed to allow unrestrained
relative rotation. That is the release at the column node.

# ENGINEERING JUDGMENT
The release frees the beam only at the column node. At every other node the
beam turns with the slab, so next to a support where the slab is continuous
it follows the slab's hogging and carries a short negative-moment region
(about one metre on a 6 m bay, and not mesh-dependent). That hogging is part
of the beam's shell demand. The slab bars are sized from the slab's own
shell moments, which do not hold it, so moving it onto the slab would leave
it unreinforced.

Columns above and below the story are rotational springs at their shell
nodes ([`_story_column_springs`](@ref)). A column with no section adds none,
and that support stays a vertical pin.

A composite steel beam whose studs are known (it has a
[`composite_stiffness_profile`](@ref) for its current section) takes, on each
piece, `I_LB` in a sagging region and the cracked section in a hogging one.
The regions are the frame model's, or `composite_regions[i]` when given (the
shell's own from an earlier solve, placed by
[`composite_profile_on_regions`](@ref)). Neither inertia holds the slab's
bending about its own centre, which the shell supplies (see
[`StructuralSizer.shell_beam_properties`](@ref)). Its demand also carries
one moment field per load combination. Any other steel beam is bare.
`composite_regions` in the result gives, for each such beam, the regions its
stiffness was placed on.

# ENGINEERING JUDGMENT
The model returned here is the gross shell: factored demands and slab bars
stay on it. Hogging plates are softened only while the service deflection is
being solved, and that stiffness is restored before return.

The shell forces are written onto each slab of the story as
`design_details.shell_beam_forces`. `design_details.shell_reinforcement`
is one `ElementRebarField` per panel of the story, and
`design_details.shell_panels` indexes that slab's own panels in it. `beam_demands` is one
[`ShellBeamDemand`](@ref) per beam index, from the same factored load cases
as the bars. Beam sections are not changed here. A cracked service
solve, used for deflection, is restored to this gross shell before return.

`service_spans` maps a beam index to its span records from that solve:
`RCShellSpan`s for concrete, live-load `SteelShellSpan`s for steel. They are
a deflection check of their own, not a replacement for the frame model's.
"""
function analyze_story_shell(struc, level::Int;
                             target_edge::Length = 0.5u"m",
                             concrete = NWC_4000,
                             steel = nothing,
                             support_points = nothing,
                             solve::Bool = true,
                             service::Bool = true,
                             rebar = Rebar_60,
                             sustained_live_fraction::Real = 0.0,
                             composite_regions = nothing)
    shell = build_story_shell(struc, level; target_edge, concrete, steel, support_points,
                              composite_regions)
    return solve_story_shell!(shell, struc; composite_regions, service, rebar,
                              sustained_live_fraction, solve)
end

"""
    StoryShell

One story's shell, meshed once by [`build_story_shell`](@ref) and solved in
place by [`solve_story_shell!`](@ref).

The mesh, the supports and the beam lines stay. Each solve puts every beam
piece's current section and web offset, the panel pressures and the column
springs on the model, then refactors on the stored sparsity pattern. A
different slab thickness, a different set of beams with a section, or a
different end release is another model, and the solve meshes it again.

The slab continues past the centerline to the column faces. That band is
meshed once. A later column size moves only its outer nodes.
"""
mutable struct StoryShell
    level::Int
    target_edge::typeof(1.0u"m")
    concrete::Any
    steel::Any
    support_points::Vector{NTuple{2, Float64}}
    built::NamedTuple
    model::Union{Nothing, Asap.Model}
    frame_station::Vector{Float64}
    signature::UInt
    reasons::Vector{String}
    # Outer nodes of the slab-edge band, and where each one sits on the centerline.
    edge_outer::Vector{Asap.Node}
    edge_anchor::Vector{NTuple{2, Float64}}
    edge_run::Vector{Int}
    edge_corner::Vector{Bool}
end

"""
    build_story_shell(struc, level; target_edge, concrete, steel,
                      support_points, composite_regions) -> StoryShell

Mesh every slab on `level` as one shell with the beams that have a section,
and pin its supports. Nothing is solved. Supports are the column centres on
this story, unless `support_points` is given as `(x, y)` pairs in metres.
`steel` is the material of a steel section that carries none.
"""
function build_story_shell(struc, level::Int;
                           target_edge::Length = 0.5u"m",
                           concrete = NWC_4000,
                           steel = nothing,
                           support_points = nothing,
                           composite_regions = nothing)
    inp = _story_shell_inputs(struc, level, concrete, steel, composite_regions)
    pts = support_points === nothing ? _column_support_points(struc, level) :
          NTuple{2, Float64}[(Float64(p[1]), Float64(p[2])) for p in support_points]
    shell = StoryShell(level, uconvert(u"m", target_edge), concrete, steel, pts,
                       NamedTuple(), nothing, Float64[], UInt(0), String[],
                       Asap.Node[], NTuple{2, Float64}[], Int[], Bool[])
    return _mesh_story_shell!(shell, inp, struc)
end

"""
What the mesh and the element types depend on: each panel's thickness, the
beams in the shell, and their end releases.
"""
_story_shell_signature(inp) =
    hash((inp.thickness_of_face, inp.beam_ids, [b.release for b in inp.beams],
          inp.wall_lines))

"""Station of the middle of each frame piece, in metres along its beam's line."""
function _story_frame_stations(frames, beams)
    line = Dict(b.id => b.xy for b in beams)
    at(n, xy) = StructuralSizer._station_on_polyline(
        ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2]), xy)[2]
    return Float64[0.5 * (at(el.nodeStart, line[el.id]) + at(el.nodeEnd, line[el.id]))
                   for el in frames]
end

"""Factored pressure on each panel's plates, and each beam piece's own weight."""
function _story_shell_loads(built, pressures)
    loads = Asap.AbstractLoad[]
    by_panel = Dict{Int, Vector{Asap.ShellElement}}()
    for (el, i) in zip(built.shells, built.panel_index)
        push!(get!(() -> Asap.ShellElement[], by_panel, i), el)
    end
    for (i, els) in by_panel
        push!(loads, Asap.AreaLoad(els, pressures[i]))
    end
    for el in built.frames
        push!(loads, Asap.GravityLoad(el, 9.80665u"m/s^2"))
    end
    return loads
end

"""Mesh `inp` onto `shell` and pin its supports. The solve sets beam sections."""
function _mesh_story_shell!(shell::StoryShell, inp, struc)
    built = StructuralSizer.story_shell(inp.panels, inp.beams;
                                       target_edge = shell.target_edge,
                                       support_lines = inp.wall_lines)
    shell.built = built
    shell.frame_station = _story_frame_stations(built.frames, inp.beams)
    shell.signature = _story_shell_signature(inp)
    shell.model = nothing
    empty!(shell.reasons)
    # Walls first, so the in-plane anchor in the pin sees nodes already held.
    _hold_story_walls!(built.nodes, inp.wall_lines)
    n_pin = _pin_story_supports!(built.nodes, shell.support_points)
    if n_pin < 3 && isempty(inp.wall_lines)
        push!(shell.reasons, n_pin == 0 && length(shell.support_points) < 3 ?
            "the story shell needs at least three supports" :
            "fewer than three shell nodes were supported")
    else
        _append_slab_edge!(shell, built, inp, struc)
        shell.model = Asap.Model(built.nodes, built.frames, built.shells,
                                 _story_shell_loads(built, inp.pressures))
    end
    return shell
end

"""
Place the stored slab-edge nodes for the columns `struc` has now.

Returns whether any node moved. The centerline anchors do not.
"""
function _place_slab_edge!(shell::StoryShell, struc)
    isempty(shell.edge_outer) && return false
    edge = StructuralSizer.story_slab_edge(shell.built.boundary,
                                           _edge_column_samples(struc, shell.level))
    length(edge.runs) == maximum(shell.edge_run) || return false
    moved = false
    for i in eachindex(shell.edge_outer)
        run = edge.runs[shell.edge_run[i]]
        xy = if shell.edge_corner[i]
            edge.outline[shell.edge_run[i]]
        else
            a = shell.edge_anchor[i]
            (a[1] + run.outward[1] * run.width, a[2] + run.outward[2] * run.width)
        end
        node = shell.edge_outer[i]
        x0 = ustrip(u"m", node.position[1])
        y0 = ustrip(u"m", node.position[2])
        (abs(x0 - xy[1]) > 1e-9 || abs(y0 - xy[2]) > 1e-9) && (moved = true)
        node.position[1] = xy[1] * u"m"
        node.position[2] = xy[2] * u"m"
    end
    return moved
end

"""One outer node per centerline boundary node, and a triangle pair across the band."""
function _append_slab_edge!(shell::StoryShell, built, inp, struc)
    empty!(shell.edge_outer)
    empty!(shell.edge_anchor)
    empty!(shell.edge_run)
    empty!(shell.edge_corner)
    boundary = built.boundary
    samples = _edge_column_samples(struc, shell.level)
    isempty(samples) && return shell
    edge = StructuralSizer.story_slab_edge(boundary, samples)
    maximum(r.width for r in edge.runs) > 1e-6 || return shell
    chain, anchors, poly_edge, station = _boundary_node_chain(built.nodes, boundary)
    length(chain) < 3 && return shell

    outers = Asap.Node[]
    sizehint!(outers, length(chain))
    for i in eachindex(chain)
        r = edge.edge_run[poly_edge[i]]
        run = edge.runs[r]
        corner = station[i] <= 1e-5 && poly_edge[i] == run.edges[1]
        xy = if corner
            edge.outline[r]
        else
            a = anchors[i]
            (a[1] + run.outward[1] * run.width, a[2] + run.outward[2] * run.width)
        end
        push!(outers, Asap.Node([xy[1] * u"m", xy[2] * u"m", 0.0u"m"], :free))
        push!(shell.edge_anchor, anchors[i])
        push!(shell.edge_run, r)
        push!(shell.edge_corner, corner)
    end

    n = length(chain)
    used = falses(n)
    for i in 1:n
        j = mod1(i + 1, n)
        _band_span(chain[i], outers[i]) < 1e-6 &&
            _band_span(chain[j], outers[j]) < 1e-6 && continue
        used[i] = used[j] = true
        b0, b1 = chain[i], chain[j]
        o0, o1 = outers[i], outers[j]
        mid = (0.5 * (anchors[i][1] + anchors[j][1]), 0.5 * (anchors[i][2] + anchors[j][2]))
        nrm = edge.runs[edge.edge_run[poly_edge[i]]].outward
        probe = (mid[1] - nrm[1] * 1e-3, mid[2] - nrm[2] * 1e-3)
        panel = StructuralSizer._owning_panel(probe[1], probe[2], inp.panels)
        sec = inp.panels[panel].section
        for nodes in ((b0, o0, b1), (o0, o1, b1))
            el = Asap.ShellTri3(nodes, sec.thickness * u"m", sec.E * u"Pa", sec.ν;
                                ρ = sec.ρ, id = :slab_edge)
            push!(built.shells, el)
            push!(built.panel_index, panel)
        end
    end
    for i in eachindex(outers)
        used[i] || continue
        push!(shell.edge_outer, outers[i])
    end
    # Drop the bookkeeping of unused nodes so a later move touches only the band.
    if length(shell.edge_outer) != length(outers)
        keep = findall(used)
        shell.edge_anchor = shell.edge_anchor[keep]
        shell.edge_run = shell.edge_run[keep]
        shell.edge_corner = shell.edge_corner[keep]
    end
    return shell
end

_band_span(a::Asap.Node, b::Asap.Node) = hypot(
    ustrip(u"m", a.position[1]) - ustrip(u"m", b.position[1]),
    ustrip(u"m", a.position[2]) - ustrip(u"m", b.position[2]))

"""Boundary mesh nodes in walk order, with the polygon edge and station of each."""
function _boundary_node_chain(nodes, polygon)
    chain = Asap.Node[]
    anchors = NTuple{2, Float64}[]
    poly_edge = Int[]
    station = Float64[]
    n = length(polygon)
    for i in 1:n
        a = polygon[i]
        b = polygon[mod1(i + 1, n)]
        hits = Tuple{Float64, Asap.Node, NTuple{2, Float64}}[]
        for node in nodes
            xy = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))
            s = StructuralSizer._segment_station(xy, a, b; tol = 1e-4)
            s === nothing && continue
            s > 1 - 1e-5 && continue
            push!(hits, (s, node, xy))
        end
        sort!(hits, by = first)
        for (s, node, xy) in hits
            push!(chain, node)
            push!(anchors, xy)
            push!(poly_edge, i)
            push!(station, s)
        end
    end
    return chain, anchors, poly_edge, station
end

"""Put each beam's current section and web offset on its frame pieces."""
function _set_story_beams!(shell::StoryShell, inp)
    beam_of = Dict(b.id => b for b in inp.beams)
    section_at = _story_composite_section_at(inp.composite_at)
    for (el, s) in zip(shell.built.frames, shell.frame_station)
        b = beam_of[el.id]
        el.section = section_at === nothing ? b.section : section_at(b, s)
        el.eccentricity = b.eccentricity
    end
    return shell
end

"""
Panels, panel designs and beam lines of story `level` from the slabs and
sections the structure holds now. Meshes nothing.
"""
function _story_shell_inputs(struc, level::Int, concrete, steel, composite_regions)
    haskey(struc.skeleton.stories, level) || throw(ArgumentError(
        "story $level is not in the skeleton"))
    story = struc.skeleton.stories[level]
    faces = Set(story.faces)
    vertices = Set(story.vertices)

    panels = StructuralSizer.StoryShellPanel[]
    designs = StructuralSizer.StoryPanelDesign[]
    pressures = []
    thickness_of_face = Pair{Int, typeof(1.0u"m")}[]
    slabs = Slab[]
    panel_slab = Int[]
    for slab in struc.slabs
        h = _story_metres(thickness(slab))
        h > zero(h) || throw(ArgumentError("a story shell slab needs a positive thickness"))
        sec = Asap.ShellSection(h, concrete.E, concrete.ν; ρ = concrete.ρ, name = :story)
        touched = false
        for ci in slab.cell_indices
            cell = struc.cells[ci]
            face = cell.face_idx
            face in faces || continue
            touched = true
            poly = NTuple{2, Float64}[StructuralSizer._vertex_xy_m(struc.skeleton, vi)
                                       for vi in struc.skeleton.face_vertex_indices[face]]
            holes = StructuralSizer.slab_opening_loops(struc, slab; face_idx = face)
            push!(panels, StructuralSizer.StoryShellPanel(poly, sec; holes = holes))
            push!(pressures, total_factored_pressure(cell))
            sym = cell.floor_type === :unknown ? slab.floor_type : cell.floor_type
            push!(designs, StructuralSizer.StoryPanelDesign(
                cell.self_weight + cell.sdl, cell.live_load, h, cell.spans.axis,
                StructuralSizer.floor_type(sym)))
            push!(thickness_of_face, face => h)
            push!(panel_slab, length(slabs) + 1)
        end
        touched && push!(slabs, slab)
    end
    isempty(panels) && throw(ArgumentError("story $level has no slab panels"))

    beams = StructuralSizer.ShellFrameBeam[]
    beam_ids = Symbol[]
    beam_index = Dict{Symbol, Int}()
    skipped = Int[]
    composite_at = Dict{Symbol, NamedTuple}()
    regions_used = Dict{Int, Vector{NamedTuple}}()
    origins = Dict{Int, NTuple{2, Float64}}()
    stale = Int[]
    for (i, beam) in enumerate(struc.beams)
        chain = _story_vertex_chain(struc, beam)
        on_story = !isempty(chain) && all(v -> v in vertices, chain)
        on_story || beam.level == level || continue
        isempty(chain) && continue
        sec = _story_beam_section(struc, beam)
        if sec === nothing
            push!(skipped, i)
            continue
        end
        h = _story_beam_thickness(struc, beam, thickness_of_face)
        h === nothing && (h = _story_metres(thickness(slabs[1])))
        xy = NTuple{2, Float64}[StructuralSizer._vertex_xy_m(struc.skeleton, v) for v in chain]
        mat = _story_beam_material(sec, concrete, steel, _recorded_structural_steel(beam))
        props = StructuralSizer.shell_beam_properties(sec, h, mat)
        release = _story_beam_release(struc, beam, chain, mat)
        id = Symbol("beam_", i)
        profile = composite_stiffness_profile(struc, beam)
        if profile !== nothing
            if _sections_identical(profile.section, sec)
                regions = composite_regions === nothing ? nothing :
                          get(composite_regions, i, nothing)
                regions_used[i] = regions === nothing ? profile.regions : regions
                placed = regions === nothing ? profile :
                         composite_profile_on_regions(profile, regions)
                composite_at[id] = (; profile = placed,
                                    flip = _story_origin_at_end(xy, profile.origin))
                origins[i] = profile.origin
            else
                push!(stale, i)
            end
        end
        push!(beams, StructuralSizer.ShellFrameBeam(xy, props.section;
                                                    eccentricity = props.eccentricity, id = id,
                                                    release = release))
        push!(beam_ids, id)
        beam_index[id] = i
    end
    return (; panels, designs, pressures, thickness_of_face, slabs, panel_slab, beams,
            beam_ids, beam_index, skipped, composite_at, regions_used, origins, stale,
            wall_lines = _story_wall_supports(struc, level))
end

# Reserved `_analysis_caches` key. Not a slab index. The value is
# `wall index => factored vertical reaction [N]` from the last story-shell
# sizing. `clear_geometry_caches!` drops it with the other caches.
const _STORY_SHELL_WALL_AXIAL_KEY = -2

"""
Plan pieces of walls that hold this story's slab up, with the wall's index.

A wall meets the slab at a story elevation ([`supporting_wall_segments`](@ref)
uses the same test). An opening whose top reaches the pier top breaks the
line: there is no wall under the soffit across that width. A window that
stops short of the soffit leaves the line whole. Pieces stay in wall order,
which is the order a shared node is given to one wall.
"""
function _story_wall_support_pieces(struc, level)
    out = Tuple{Int, NTuple{2, NTuple{2, Float64}}}[]
    hasproperty(struc, :walls) || return out
    z = ustrip(u"m", _story_metres(struc.skeleton.stories[level].elevation))
    for (i, wall) in enumerate(struc.walls)
        zs = StructuralSizer._wall_end_elevations_m(struc.skeleton, wall.story)
        any(zw -> abs(zw - z) <= 0.1, zs) || continue
        for piece in _solid_wall_pieces(wall)
            push!(out, (i, piece))
        end
    end
    return out
end

"""Plan lines of [`_story_wall_support_pieces`](@ref), without the wall index."""
function _story_wall_supports(struc, level)
    return NTuple{2, NTuple{2, Float64}}[piece for (_, piece) in
                                          _story_wall_support_pieces(struc, level)]
end

"""
Factored upward reaction on each wall, in newtons.

`pieces` are `(wall index, segment)` in assignment order. A node on several
segments is counted on the first. The reaction is the upward force the wall
delivers to the slab (`node.reaction[3]`), the same sign as a compression-
positive pier axial. A node with no reaction vector is skipped.
"""
function _factored_wall_reactions(nodes, pieces)
    totals = Dict{Int, Float64}()
    isempty(pieces) && return totals
    segments = [piece for (_, piece) in pieces]
    for node in nodes
        rxn = node.reaction
        (rxn isa AbstractVector && length(rxn) >= 3) || continue
        pt = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))
        hit = findfirst(seg -> StructuralSizer._point_on_segment(pt, seg[1], seg[2]),
                        segments)
        hit === nothing && continue
        nz = ustrip(u"N", rxn[3])
        isfinite(nz) || continue
        w = pieces[hit][1]
        totals[w] = get(totals, w, 0.0) + nz
    end
    return totals
end

"""
Store each wall's factored shell reaction from the last solve of `shells`.

The number is the upward support force under the story shell's factored
panel pressure (`1.2D + 1.6L`). Stories add. A wall that holds no solved
shell is absent, so a later design does not scale it.
"""
function _record_story_shell_wall_axials!(struc, shells)
    totals = Dict{Int, Float64}()
    for (level, shell) in shells
        shell.model === nothing && continue
        pieces = _story_wall_support_pieces(struc, level)
        isempty(pieces) && continue
        for (w, n) in _factored_wall_reactions(shell.model.nodes, pieces)
            totals[w] = get(totals, w, 0.0) + n
        end
    end
    inner = get!(() -> Dict{Symbol, Any}(), struc._analysis_caches,
                 _STORY_SHELL_WALL_AXIAL_KEY)
    inner[:axial] = totals
    return totals
end

"""Drop a stored shell reaction. A design with no story shell calls this."""
function _clear_story_shell_wall_axials!(struc)
    delete!(struc._analysis_caches, _STORY_SHELL_WALL_AXIAL_KEY)
    return struc
end

"""Factored shell reaction [N] stored for `wall_index`, or `nothing`."""
function _story_shell_wall_axial(struc, wall_index::Int)
    inner = get(struc._analysis_caches, _STORY_SHELL_WALL_AXIAL_KEY, nothing)
    inner === nothing && return nothing
    stored = get(inner, :axial, nothing)
    stored === nothing && return nothing
    return get(stored, wall_index, nothing)
end


"""Solid pieces of `wall`'s plan line. A full-height opening is a gap."""
function _solid_wall_pieces(wall; tol::Float64 = 1e-6)
    x1, y1, x2, y2 = wall.x1, wall.y1, wall.x2, wall.y2
    L = hypot(x2 - x1, y2 - y1)
    L <= tol && return NTuple{2, NTuple{2, Float64}}[]
    H = wall.base.L
    Hm = H isa Unitful.Quantity ? ustrip(u"m", H) : Float64(H)
    gaps = Tuple{Float64, Float64}[]
    for op in wall.openings
        op.z0 + op.height >= Hm - 1e-3 || continue
        s0 = clamp(op.s0, 0.0, L)
        s1 = clamp(op.s0 + op.width, 0.0, L)
        s1 - s0 > tol && push!(gaps, (s0, s1))
    end
    sort!(gaps)
    merged = Tuple{Float64, Float64}[]
    for (a, b) in gaps
        if isempty(merged) || a > merged[end][2] + tol
            push!(merged, (a, b))
        else
            merged[end] = (merged[end][1], max(merged[end][2], b))
        end
    end
    cuts = [0.0]
    for (a, b) in merged
        push!(cuts, a, b)
    end
    push!(cuts, L)
    point(s) = (x1 + (x2 - x1) * s / L, y1 + (y2 - y1) * s / L)
    pieces = NTuple{2, NTuple{2, Float64}}[]
    for i in 1:2:length(cuts) - 1
        cuts[i + 1] - cuts[i] > tol || continue
        push!(pieces, (point(cuts[i]), point(cuts[i + 1])))
    end
    return pieces
end

"""
Fix the slab on each wall line.

ACI 318-11 R13.6.3.3 (corpus: aci-318-11, page 254): a slab cast integrally
with a concrete wall of large flexural stiffness has little rotation at the
joint. uz is fixed. Rotation about the wall's own axis is fixed too: rx
when the wall runs along x, ry when it runs along y. A skewed wall keeps
both global rotations free here; [`_story_wall_springs`](@ref) restrains the
rotation about that wall's axis.
"""
function _hold_story_walls!(nodes, segments)
    isempty(segments) && return 0
    n = 0
    for node in nodes
        pt = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))
        hit = findfirst(seg -> StructuralSizer._point_on_segment(pt, seg[1], seg[2]), segments)
        hit === nothing && continue
        seg = segments[hit]
        dof = copy(node.dof)
        dof[3] && (n += 1)
        dof[3] = false
        dx = abs(seg[2][1] - seg[1][1])
        dy = abs(seg[2][2] - seg[1][2])
        if dx >= 4 * dy
            dof[4] = false
        elseif dy >= 4 * dx
            dof[5] = false
        end
        node.dof = dof
    end
    return n
end

"""
Grounded springs that restrain rotation about a skewed wall's axis.

# ENGINEERING JUDGMENT
R13.6.3.3 gives no stiffness. The spring is one thousand times the plate
rigidity `E t³/12` times the mesh spacing, so the rotation about the wall
is small beside the slab's own flexibility, and the value stays finite.
An axis-aligned wall is fixed by its degrees of freedom instead.
"""
function _story_wall_springs(shell::StoryShell, segments)
    springs = Asap.Spring[]
    isempty(segments) && return springs
    built = shell.built
    built === nothing && return springs
    isempty(built.shells) && return springs
    el = built.shells[1]
    spacing = ustrip(u"m", shell.target_edge)
    k = 1.0e3 * el.E * el.thickness^3 / 12 * spacing
    seen = IdDict{Asap.Node, Nothing}()
    for node in built.nodes
        haskey(seen, node) && continue
        pt = (ustrip(u"m", node.position[1]), ustrip(u"m", node.position[2]))
        hit = findfirst(seg -> StructuralSizer._point_on_segment(pt, seg[1], seg[2]), segments)
        hit === nothing && continue
        seg = segments[hit]
        dx = seg[2][1] - seg[1][1]
        dy = seg[2][2] - seg[1][2]
        L = hypot(dx, dy)
        L > 1e-9 || continue
        (abs(dx) >= 4 * abs(dy) || abs(dy) >= 4 * abs(dx)) && continue
        seen[node] = nothing
        tx, ty = dx / L, dy / L
        spring = Asap.Spring(node; id = :wall_axis)
        spring.K[4, 4] = k * tx * tx
        spring.K[4, 5] = k * tx * ty
        spring.K[5, 4] = k * ty * tx
        spring.K[5, 5] = k * ty * ty
        push!(springs, spring)
    end
    return springs
end

"""
    solve_story_shell!(shell, struc; composite_regions, service, rebar,
                       sustained_live_fraction, solve=true) -> NamedTuple

Solve `shell` with the structure's current beam sections, panel loads and
column springs, and write the results onto its slabs. The result is the one
[`analyze_story_shell`](@ref) documents, plus `shell`.

The mesh is reused. Only a change in slab thickness, in which beams have a
section, or in a beam's end release meshes the story again. `solve = false`
records the panels as meshed and not solved.
"""
function solve_story_shell!(shell::StoryShell, struc;
                            composite_regions = nothing,
                            service::Bool = true,
                            rebar = Rebar_60,
                            sustained_live_fraction::Real = 0.0,
                            solve::Bool = true)
    level = shell.level
    concrete, steel = shell.concrete, shell.steel
    inp = _story_shell_inputs(struc, level, concrete, steel, composite_regions)
    _story_shell_signature(inp) == shell.signature || _mesh_story_shell!(shell, inp, struc)
    built = shell.built
    reasons = String[]
    isempty(inp.skipped) || push!(reasons,
        "beams with no section were left out of the shell: $(inp.skipped)")
    isempty(inp.stale) || push!(reasons,
        "composite beams whose stiffness was recorded for another section are bare steel: $(inp.stale)")
    ran = false
    forces = Dict{Symbol, Vector{Vector{Float64}}}()
    bars = StructuralSizer.ElementRebarField[]
    beam_demands = Dict{Int, ShellBeamDemand}()
    service_spans = Dict{Int, Vector{Any}}()
    service_converged = true
    model = nothing
    if !solve
        push!(reasons, "the story shell was meshed and not solved")
    elseif shell.model === nothing
        append!(reasons, shell.reasons)
    else
        model = shell.model
        _set_story_beams!(shell, inp)
        moved = _place_slab_edge!(shell, struc)
        model.loads = _story_shell_loads(built, inp.pressures)
        if model.processed && moved
            # The edge nodes moved. Connectivity did not, so the pattern stands.
            Asap.update!(model; geometry = true)
        elseif model.processed
            Asap.update!(model; values_only = true)
        else
            Asap.process!(model)
        end
        empty!(model.springs)
        springs = _story_column_springs(struc, level, built.nodes, concrete, steel)
        append!(springs, _story_wall_springs(shell, inp.wall_lines))
        isempty(springs) || Asap.add_springs!(model, springs)
        Asap.solve!(model)
        forces = _shell_beam_forces(built.frames)
        cases = StructuralSizer.story_load_cases(model, built.panel_index, inp.designs)
        bars = StructuralSizer.story_panel_reinforcement(
            model, built.panel_index, inp.designs; cases = cases, fc = concrete.fc′,
            fy = rebar.Fy)
        beam_demands = story_shell_beam_demands(model, built.frames, inp.beam_index, cases;
                                                origins = inp.origins)
        if service && !isempty(inp.beams)
            specs = service_beams(struc, inp.beams, inp.beam_index, beam_demands,
                                  shell.support_points, inp.thickness_of_face)
            cracked = story_cracked_service(
                model, built, inp.designs, specs;
                concrete = concrete, rebar = rebar, bars = bars,
                sustained_live_fraction = sustained_live_fraction)
            for (id, spans) in cracked.spans
                i = get(inp.beam_index, id, nothing)
                i === nothing && continue
                service_spans[i] = spans
            end
            service_converged = cracked.converged
            service_converged || @warn "Cracked service shell did not settle" level iterations=cracked.iterations
        end
        ran = true
    end
    status = (ran && isempty(inp.skipped)) ? :analyzed : :not_analyzed
    extra = (
        analysis_status = status,
        analysis_source = :story_shell,
        analysis_reasons = reasons,
        shell_beam_forces = forces,
        shell_beam_ids = inp.beam_ids,
        shell_reinforcement = bars,
    )
    for (k, slab) in enumerate(inp.slabs)
        own = merge(extra, (shell_panels = findall(==(k), inp.panel_slab),))
        existing = slab.design_details
        slab.design_details = existing isa NamedTuple ? merge(existing, own) : own
    end
    return (
        model = model,
        built = built,
        shell = shell,
        beam_forces = forces,
        beam_demands = beam_demands,
        shell_reinforcement = bars,
        service_spans = service_spans,
        service_converged = service_converged,
        composite_regions = inp.regions_used,
        analysis_status = status,
        skipped_beams = inp.skipped,
        reasons = reasons,
    )
end
