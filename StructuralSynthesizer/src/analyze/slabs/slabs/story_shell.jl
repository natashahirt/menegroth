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

"""Concrete for RC sections; otherwise the section's own material, then `steel`."""
function _story_beam_material(sec, concrete, steel)
    if sec isa RCBeamSection || sec isa RCTBeamSection
        return concrete
    end
    if hasproperty(sec, :material) && getfield(sec, :material) !== nothing
        return getfield(sec, :material)
    end
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
        push!(pts, StructuralSizer._column_xy_m(skel, col))
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
        x, y = StructuralSizer._column_xy_m(struc.skeleton, col)
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

A steel beam released at both ends is marked `simple` in its
[`ShellBeamDemand`](@ref). AISC 360-16 §B3.4a (corpus: aisc-360-16, page 69):
a simple connection transmits a negligible moment and may be assumed to allow
unrestrained relative rotation.

# ENGINEERING JUDGMENT
The release frees the beam only at the column node. At every other node the
beam turns with the slab, so next to a support where the slab is continuous
it follows the slab's hogging and carries a short negative-moment region
(about one metre on a 6 m bay, and not mesh-dependent). The frame model's
state, a simple-span beam under a slab that carries its own hogging, is
also in equilibrium. A `simple` beam is sized on that state: the shell's
`Mu_neg` and moment fields are kept for reporting but do not size the beam
or place its studs. That hogging is then the slab's, over the support.

Columns above and below the story are rotational springs at their shell
nodes ([`_story_column_springs`](@ref)). A column with no section adds none,
and that support stays a vertical pin.

A composite steel beam whose studs are known (it has a
[`composite_stiffness_profile`](@ref) for its current section) takes, on each
piece, the inertia the building model uses at that station: `I_LB` in a
sagging region, the cracked section in a hogging one. Neither holds the
slab's bending about its own centre, which the shell supplies (see
[`StructuralSizer.shell_beam_properties`](@ref)). Its demand also carries
one moment field per load combination. Any other steel beam is bare.

# ENGINEERING JUDGMENT
The model returned here is the gross shell: factored demands and slab bars
stay on it. Hogging plates are softened only while the service deflection is
being solved, and that stiffness is restored before return.

The shell forces are written onto each slab of the story as
`design_details.shell_beam_forces`. `design_details.shell_reinforcement`
is one `ElementRebarField` per panel of the story. `beam_demands` is one
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
                             sustained_live_fraction::Real = 0.0)
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
        end
        touched && push!(slabs, slab)
    end
    isempty(panels) && throw(ArgumentError("story $level has no slab panels"))

    beams = StructuralSizer.ShellFrameBeam[]
    beam_ids = Symbol[]
    beam_index = Dict{Symbol, Int}()
    skipped = Int[]
    composite_at = Dict{Symbol, NamedTuple}()
    origins = Dict{Int, NTuple{2, Float64}}()
    stale = Int[]
    simple = Set{Int}()
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
        mat = _story_beam_material(sec, concrete, steel)
        props = StructuralSizer.shell_beam_properties(sec, h, mat)
        release = _story_beam_release(struc, beam, chain, mat)
        mat isa StructuralSizer.StructuralSteel && release in (:freefree, :joist) &&
            push!(simple, i)
        id = Symbol("beam_", i)
        profile = composite_stiffness_profile(struc, beam)
        if profile !== nothing
            if _sections_identical(profile.section, sec)
                composite_at[id] = (; profile, flip = _story_origin_at_end(xy, profile.origin))
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

    built = StructuralSizer.story_shell(panels, beams; target_edge = target_edge,
                                        section_at = _story_composite_section_at(composite_at))
    pts = support_points === nothing ? _column_support_points(struc, level) : support_points
    reasons = String[]
    isempty(skipped) || push!(reasons,
        "beams with no section were left out of the shell: $(skipped)")
    isempty(stale) || push!(reasons,
        "composite beams whose stiffness was recorded for another section are bare steel: $(stale)")
    ran = false
    forces = Dict{Symbol, Vector{Vector{Float64}}}()
    bars = StructuralSizer.ElementRebarField[]
    beam_demands = Dict{Int, ShellBeamDemand}()
    service_spans = Dict{Int, Vector{Any}}()
    service_converged = true
    model = nothing
    if solve
        if length(pts) < 3
            push!(reasons, "the story shell needs at least three supports")
        else
            nfixed = _pin_story_supports!(built.nodes, pts)
            if nfixed < 3
                push!(reasons, "fewer than three shell nodes were supported")
            else
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
                model = Asap.Model(built.nodes, built.frames, built.shells, loads)
                Asap.process!(model)
                springs = _story_column_springs(struc, level, built.nodes, concrete, steel)
                isempty(springs) || Asap.add_springs!(model, springs)
                Asap.solve!(model)
                forces = _shell_beam_forces(built.frames)
                cases = StructuralSizer.story_load_cases(model, built.panel_index, designs)
                bars = StructuralSizer.story_panel_reinforcement(
                    model, built.panel_index, designs; cases = cases, fc = concrete.fc′)
                beam_demands = story_shell_beam_demands(model, built.frames, beam_index, cases;
                                                        origins = origins)
                for i in simple
                    haskey(beam_demands, i) && (beam_demands[i] = _as_simple(beam_demands[i]))
                end
                if service && !isempty(beams)
                    specs = service_beams(struc, beams, beam_index, beam_demands, pts,
                                          thickness_of_face)
                    cracked = story_cracked_service(
                        model, built, designs, specs;
                        concrete = concrete, rebar = rebar, bars = bars,
                        sustained_live_fraction = sustained_live_fraction)
                    for (id, spans) in cracked.spans
                        i = get(beam_index, id, nothing)
                        i === nothing && continue
                        service_spans[i] = spans
                    end
                    service_converged = cracked.converged
                    service_converged || @warn "Cracked service shell did not settle" level iterations=cracked.iterations
                end
                ran = true
            end
        end
    else
        push!(reasons, "the story shell was meshed and not solved")
    end
    status = (ran && isempty(skipped)) ? :analyzed : :not_analyzed
    extra = (
        analysis_status = status,
        analysis_source = :story_shell,
        analysis_reasons = reasons,
        shell_beam_forces = forces,
        shell_beam_ids = beam_ids,
        shell_reinforcement = bars,
    )
    for slab in slabs
        existing = slab.design_details
        slab.design_details = existing isa NamedTuple ? merge(existing, extra) : extra
    end
    return (
        model = model,
        built = built,
        beam_forces = forces,
        beam_demands = beam_demands,
        shell_reinforcement = bars,
        service_spans = service_spans,
        service_converged = service_converged,
        analysis_status = status,
        skipped_beams = skipped,
        reasons = reasons,
    )
end
