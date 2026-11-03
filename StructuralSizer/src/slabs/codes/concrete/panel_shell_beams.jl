# =============================================================================
# Frame beams on a panel shell
# =============================================================================
#
# A beam is a chain of frame elements between the shell nodes that lie on its
# line. The beam is not meshed as a shell. The shared nodes are what make the
# slab and the beam move together.

"""
A frame beam drawn on the shell.

`xy` is an open polyline in plan, in metres. `eccentricity` is
`(e_f1_start, e_f1_end, e_f2, e_f3)` in metres: the rigid offset from the
shell node to the frame centroid. Zeros put the centroid on the shell.
At the default roll, local y is up, so a web below the slab is a negative
`e_f2`.
"""
struct ShellFrameBeam
    xy::Vector{NTuple{2, Float64}}
    section::Asap.Section
    eccentricity::NTuple{4, Float64}
    id::Symbol
end

function ShellFrameBeam(xy, section::Asap.Section;
                        eccentricity::NTuple{4, Float64} = (0.0, 0.0, 0.0, 0.0),
                        id::Symbol = :beam)
    return ShellFrameBeam(collect(NTuple{2, Float64}, xy), section, eccentricity, id)
end

"""
Offset of a web whose top is flush with the slab soffit.

The shell node is on the slab mid-plane. The web centroid sits
`h_slab/2 + h_web/2` below that. A frame element is created at roll `π/2`,
which puts local y upward, so the offset is the `e_f2` component and it is
negative.
"""
function web_below_slab_eccentricity(h_slab::Length, h_web::Length)
    e = -ustrip(u"m", h_slab / 2 + h_web / 2)
    return (0.0, 0.0, e, 0.0)
end

"""
Offset of a section whose top is flush with the slab soffit.

`soffit_to_centroid` is half the depth of a rectangle and half the stem of a
T-beam. The shell node is on the slab mid-plane, so the frame centroid is
that distance plus half the slab thickness below the node.
"""
function web_below_slab_eccentricity(h_slab::Length, section::AbstractSection)
    e = -ustrip(u"m", h_slab / 2 + soffit_to_centroid(section))
    return (0.0, 0.0, e, 0.0)
end

"""Same section with a different strong-axis inertia. Area, E, G, Iy, and J stay."""
function section_with_strong_inertia(section::Asap.Section, Ix)
    return Asap.Section(section.A, section.E, section.G, Ix, section.Iy, section.J,
                        section.ρ; Ay = section.Ay, Az = section.Az)
end

"""
    shell_beam_properties(section, h_slab, material; composite, I_service, b_eff, n)
        -> NamedTuple

`(section, eccentricity)` for one frame beam on the story shell.

A concrete beam is the gross web, hung below the soffit. A T-beam contributes
its stem only: the flange is the shell. Steel sits on the shell nodes. When
`composite` is set and `I_service` is given, the strong inertia is
[`composite_beam_inertia`](@ref). Otherwise the steel section is the bare one.
That bare section is the first pass, before the studs exist.

# ENGINEERING JUDGMENT
The story shell and the concrete web are both gross. `to_asap_section` of a
concrete beam applies the 0.35 cracked-member factor, and that factor is not
used here.
"""
function shell_beam_properties(section::RCBeamSection, h_slab::Length, material::Concrete;
                               composite::Bool = false, I_service = nothing,
                               b_eff = nothing, n = nothing)
    composite && throw(ArgumentError("a concrete beam is not a composite steel beam"))
    asap = to_asap_section(section, material; I_factor = 1.0)
    return (section = asap, eccentricity = web_below_slab_eccentricity(h_slab, section))
end

function shell_beam_properties(section::RCTBeamSection, h_slab::Length, material::Concrete;
                               composite::Bool = false, I_service = nothing,
                               b_eff = nothing, n = nothing)
    composite && throw(ArgumentError("a concrete beam is not a composite steel beam"))
    bw = ustrip(u"m", section.bw)
    hw = ustrip(u"m", section.h - section.hf)
    hw > 0 || throw(ArgumentError("a T-beam stem depth must be positive"))
    A = bw * hw
    Ix = bw * hw^3 / 12
    Iy = hw * bw^3 / 12
    a_dim = max(bw, hw)
    b_dim = min(bw, hw)
    β = 1 / 3 - 0.21 * (b_dim / a_dim) * (1 - (b_dim / a_dim)^4 / 12)
    J = β * a_dim * b_dim^3
    E = material.E
    G = E / (2 * (1 + material.ν))
    asap = Asap.Section(A * u"m^2", E, G, Ix * u"m^4", Iy * u"m^4", J * u"m^4", material.ρ)
    return (section = asap, eccentricity = web_below_slab_eccentricity(h_slab, section))
end

function shell_beam_properties(section::PixelFrameSection, h_slab::Length, material;
                               composite::Bool = false, I_service = nothing,
                               b_eff = nothing, n = nothing)
    composite && throw(ArgumentError("a concrete beam is not a composite steel beam"))
    asap = to_asap_section(section, material; I_factor = 1.0)
    return (section = asap, eccentricity = web_below_slab_eccentricity(h_slab, section))
end

function shell_beam_properties(section::AbstractSection, h_slab::Length, material;
                               composite::Bool = false, I_service = nothing,
                               b_eff = nothing, n = nothing)
    asap = to_asap_section(section, material)
    ecc = (0.0, 0.0, 0.0, 0.0)
    if !composite || I_service === nothing
        return (section = asap, eccentricity = ecc)
    end
    (b_eff === nothing || n === nothing) && throw(ArgumentError(
        "a composite shell beam needs b_eff and n = Es/Ec"))
    Ix = composite_beam_inertia(I_service, b_eff, h_slab, n)
    return (section = section_with_strong_inertia(asap, Ix), eccentricity = ecc)
end

"""
    composite_beam_inertia(I_service, b_eff, t_slab, n) -> SecondMomentOfArea

Strong-axis inertia to assign a composite steel frame that shares its nodes
with the shell.

`I_service` is the AISC inertia: `I_LB` from Commentary Eq. C-I3-1, or the
cracked negative section (corpus: aisc-360-22, pages 501–502). `n` is
`Es/Ec`. The shell already bends the slab about its own centre, and Eq. C-I3-1
does not include that term, so it is removed here:

    I_frame = I_service − b_eff t³ / (12 n)

# ENGINEERING JUDGMENT
The subtraction is the overlap between the shell and Eq. C-I3-1. It is floored
at zero. The shell outside `b_eff` is the slab spanning between beams, and it
is left in the shell.
"""
function composite_beam_inertia(I_service, b_eff::Length, t_slab::Length, n::Real)
    n > 0 || throw(ArgumentError("modular ratio n = Es/Ec must be positive, got $n"))
    I_slab = b_eff * t_slab^3 / (12 * n)
    return max(I_service - I_slab, zero(I_service))
end

"""Points of `line` with no gap larger than `spacing`. Endpoints are kept."""
function _sample_polyline(line, spacing::Float64)
    length(line) >= 2 || throw(ArgumentError("a beam line needs two points"))
    spacing > 0 || throw(ArgumentError("beam sample spacing must be positive"))
    out = NTuple{2, Float64}[]
    for i in 1:(length(line) - 1)
        ax, ay = line[i]
        bx, by = line[i + 1]
        L = hypot(bx - ax, by - ay)
        n = max(1, ceil(Int, L / spacing))
        for k in 0:(n - 1)
            t = k / n
            push!(out, (ax + t * (bx - ax), ay + t * (by - ay)))
        end
    end
    push!(out, line[end])
    return out
end

"""Closest distance from `(x, y)` to `line`, and the station of that point."""
function _station_on_polyline(x, y, line)
    best_d = Inf
    best_s = 0.0
    acc = 0.0
    for i in 1:(length(line) - 1)
        ax, ay = line[i]
        bx, by = line[i + 1]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        L = sqrt(L2)
        t = L2 < 1e-24 ? 0.0 : clamp(((x - ax) * dx + (y - ay) * dy) / L2, 0.0, 1.0)
        d = hypot(x - (ax + t * dx), y - (ay + t * dy))
        if d < best_d
            best_d = d
            best_s = acc + t * L
        end
        acc += L
    end
    return best_d, best_s
end

function _shell_nodes(shells)
    seen = IdDict{Asap.Node, Nothing}()
    out = Asap.Node[]
    for el in shells
        for n in el.nodes
            haskey(seen, n) && continue
            seen[n] = nothing
            push!(out, n)
        end
    end
    return out
end

"""Shell nodes that lie on `line`, ordered along it."""
function _nodes_on_polyline(nodes, line; tol::Float64 = 1e-4)
    hits = Tuple{Float64, Asap.Node}[]
    for n in nodes
        x = ustrip(u"m", n.position[1])
        y = ustrip(u"m", n.position[2])
        d, s = _station_on_polyline(x, y, line)
        d <= tol && push!(hits, (s, n))
    end
    sort!(hits; by = first)
    ordered = Asap.Node[]
    last_s = -Inf
    for (s, n) in hits
        s - last_s < 1e-6 && continue
        push!(ordered, n)
        last_s = s
    end
    return ordered
end

"""
    frame_elements_on_shell(nodes, beams; tol=1e-4, section_at=nothing)
        -> Vector{Asap.Element}

One frame element between each consecutive shell node on a beam line.

`section_at(beam, station)` supplies the section at a station, in metres from
the start of the beam line. `nothing` uses `beam.section` for every piece.
The station passed in is the midpoint of that piece.
"""
function frame_elements_on_shell(nodes, beams; tol::Float64 = 1e-4, section_at = nothing)
    frames = Asap.Element[]
    for beam in beams
        ordered = _nodes_on_polyline(nodes, beam.xy; tol = tol)
        length(ordered) < 2 && throw(ArgumentError(
            "beam $(beam.id) does not meet two shell nodes"))
        e = beam.eccentricity
        ecc = (e[1] * u"m", e[2] * u"m", e[3] * u"m", e[4] * u"m")
        for i in 1:(length(ordered) - 1)
            sec = beam.section
            if section_at !== nothing
                x1 = ustrip(u"m", ordered[i].position[1])
                y1 = ustrip(u"m", ordered[i].position[2])
                x2 = ustrip(u"m", ordered[i + 1].position[1])
                y2 = ustrip(u"m", ordered[i + 1].position[2])
                s1 = _station_on_polyline(x1, y1, beam.xy)[2]
                s2 = _station_on_polyline(x2, y2, beam.xy)[2]
                sec = section_at(beam, 0.5 * (s1 + s2))
            end
            push!(frames, Asap.Element(ordered[i], ordered[i + 1], sec, beam.id;
                                       eccentricity = ecc))
        end
    end
    return frames
end

"""
    panel_shell_with_beams(boundary, shell_section, beams; target_edge, holes)
        -> NamedTuple

Mesh `boundary` (plan metres, one corner each) and connect `beams` to the
shell nodes on their lines.

The shell edges are free. The caller fixes the supports.
"""
function panel_shell_with_beams(boundary, shell_section::Asap.ShellSection, beams;
                               target_edge::Length = 0.5u"m",
                               holes = Vector{NTuple{2, Float64}}[])
    length(boundary) >= 3 || throw(ArgumentError("a panel needs at least 3 corners"))
    spacing = ustrip(u"m", target_edge)
    lines = [_sample_polyline(b.xy, spacing) for b in beams]
    corners = Tuple(Asap.Node([p[1] * u"m", p[2] * u"m", 0.0u"m"], :free) for p in boundary)
    shells = Asap.Shell(corners, shell_section;
                        holes = holes,
                        interior_constrained_lines = lines,
                        edge_support_type = :free,
                        target_edge_length = target_edge,
                        id = :panel)
    nodes = _shell_nodes(shells)
    # Match the sampled line, which is what the mesher constrained.
    sampled = [ShellFrameBeam(line, b.section; eccentricity = b.eccentricity, id = b.id)
               for (line, b) in zip(lines, beams)]
    frames = frame_elements_on_shell(nodes, sampled)
    return (shells = shells, frames = frames, nodes = nodes)
end

# =============================================================================
# One shell for every panel on a story
# =============================================================================

"""
One slab panel in a story shell.

`polygon` is the plan outline in metres, one corner each. `section` is the
shell thickness and material of that panel. `holes` are opening loops inside
the panel, in the same coordinates.
"""
struct StoryShellPanel
    polygon::Vector{NTuple{2, Float64}}
    section::Asap.ShellSection
    holes::Vector{Vector{NTuple{2, Float64}}}
end

function StoryShellPanel(polygon, section::Asap.ShellSection;
                         holes = Vector{NTuple{2, Float64}}[])
    return StoryShellPanel(
        NTuple{2, Float64}[_story_quantize(p) for p in polygon],
        section,
        Vector{NTuple{2, Float64}}[NTuple{2, Float64}[_story_quantize(p) for p in h] for h in holes],
    )
end

_story_quantize(p) = (round(p[1], digits = 6), round(p[2], digits = 6))

function _point_on_segment(p, a, b; tol = 1e-5)
    abx, aby = b[1] - a[1], b[2] - a[2]
    L2 = abx * abx + aby * aby
    if L2 <= tol * tol
        return hypot(p[1] - a[1], p[2] - a[2]) <= tol
    end
    t = ((p[1] - a[1]) * abx + (p[2] - a[2]) * aby) / L2
    (t >= -tol && t <= 1 + tol) || return false
    t = clamp(t, 0.0, 1.0)
    return hypot(p[1] - (a[1] + t * abx), p[2] - (a[2] + t * aby)) <= tol
end

"""Panel edges split at every vertex that lands on them."""
function _split_panel_edges(poly, verts)
    segs = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    n = length(poly)
    for i in 1:n
        a = poly[i]
        b = poly[mod1(i + 1, n)]
        hits = Tuple{Float64, NTuple{2, Float64}}[(0.0, a), (1.0, b)]
        abx, aby = b[1] - a[1], b[2] - a[2]
        L2 = abx * abx + aby * aby
        for p in verts
            (p == a || p == b) && continue
            _point_on_segment(p, a, b) || continue
            t = L2 <= 1e-24 ? 0.0 : ((p[1] - a[1]) * abx + (p[2] - a[2]) * aby) / L2
            push!(hits, (clamp(t, 0.0, 1.0), p))
        end
        sort!(hits; by = first)
        for k in 1:(length(hits) - 1)
            p, q = hits[k][2], hits[k + 1][2]
            hypot(q[1] - p[1], q[2] - p[2]) < 1e-6 && continue
            push!(segs, (p, q))
        end
    end
    return segs
end

_edge_key(a, b) = a <= b ? (a, b) : (b, a)

function _story_area(loop)
    area = 0.0
    n = length(loop)
    for i in 1:n
        x1, y1 = loop[i]
        x2, y2 = loop[mod1(i + 1, n)]
        area += x1 * y2 - x2 * y1
    end
    return 0.5 * area
end

"""Walk degree-2 edges into closed loops."""
function _closed_loops(edges)
    adj = Dict{NTuple{2, Float64}, Vector{NTuple{2, Float64}}}()
    for (a, b) in edges
        push!(get!(() -> NTuple{2, Float64}[], adj, a), b)
        push!(get!(() -> NTuple{2, Float64}[], adj, b), a)
    end
    for (p, nbrs) in adj
        length(unique(nbrs)) == 2 || throw(ArgumentError(
            "the story outline does not form closed loops at $p"))
    end
    seen = Set{Tuple{NTuple{2, Float64}, NTuple{2, Float64}}}()
    loops = Vector{NTuple{2, Float64}}[]
    for (a, nbrs) in adj
        for b in nbrs
            key = _edge_key(a, b)
            key in seen && continue
            loop = NTuple{2, Float64}[a]
            prev, cur = a, b
            push!(seen, key)
            while cur != a
                push!(loop, cur)
                nbr = adj[cur]
                nxt = nbr[1] == prev ? nbr[2] : nbr[1]
                push!(seen, _edge_key(cur, nxt))
                prev, cur = cur, nxt
                length(loop) > length(edges) + 2 && throw(ArgumentError(
                    "a story outline loop did not close"))
            end
            push!(loops, loop)
        end
    end
    return loops
end

function _drop_colinear(loop)
    n = length(loop)
    out = NTuple{2, Float64}[]
    for i in 1:n
        a = loop[mod1(i - 1, n)]
        b = loop[i]
        c = loop[mod1(i + 1, n)]
        cross = (b[1] - a[1]) * (c[2] - b[2]) - (b[2] - a[2]) * (c[1] - b[1])
        la = hypot(b[1] - a[1], b[2] - a[2])
        lb = hypot(c[1] - b[1], c[2] - b[2])
        la * lb <= 1e-16 && continue
        abs(cross) / (la * lb) < 1e-8 && continue
        push!(out, b)
    end
    return out
end

function _dist_to_polygon(x, y, poly)
    best = Inf
    n = length(poly)
    for i in 1:n
        a = poly[i]
        b = poly[mod1(i + 1, n)]
        abx, aby = b[1] - a[1], b[2] - a[2]
        L2 = abx * abx + aby * aby
        t = L2 <= 1e-24 ? 0.0 : clamp(((x - a[1]) * abx + (y - a[2]) * aby) / L2, 0.0, 1.0)
        best = min(best, hypot(x - (a[1] + t * abx), y - (a[2] + t * aby)))
    end
    return best
end

"""Index of the panel that contains `(x, y)`. A point on a shared edge takes the nearest panel."""
function _owning_panel(x, y, panels)
    hits = Int[i for (i, p) in enumerate(panels) if _pip_xy(x, y, p.polygon)]
    length(hits) == 1 && return hits[1]
    length(hits) > 1 && throw(ArgumentError(
        "a shell element at ($x, $y) lies in more than one panel"))
    best, bestd = 0, Inf
    for (i, p) in enumerate(panels)
        d = _dist_to_polygon(x, y, p.polygon)
        if d < bestd
            best = i
            bestd = d
        end
    end
    bestd <= 1e-3 || throw(ArgumentError(
        "a shell element at ($x, $y) is outside every panel"))
    return best
end

function _triangle_centroid(el)
    x = 0.0
    y = 0.0
    for n in el.nodes
        x += ustrip(u"m", n.position[1])
        y += ustrip(u"m", n.position[2])
    end
    return (x / 3, y / 3)
end

function _shell_on_section(el, sec::Asap.ShellSection)
    if abs(el.thickness - sec.thickness) < 1e-12 && abs(el.E - sec.E) < 1.0 &&
            abs(el.ν - sec.ν) < 1e-12 && abs(el.ρ - sec.ρ) < 1e-6
        return el
    end
    return Asap.ShellTri3(el.nodes, sec.thickness * u"m", sec.E * u"Pa", sec.ν;
                          ρ = sec.ρ, id = el.id)
end

"""Outer loop, shared edges, and holes of a connected story plate."""
function _story_plate(panels, beams)
    verts = NTuple{2, Float64}[]
    for p in panels
        append!(verts, p.polygon)
    end
    for b in beams
        append!(verts, NTuple{2, Float64}[_story_quantize(pt) for pt in b.xy])
    end
    unique!(verts)
    counts = Dict{Tuple{NTuple{2, Float64}, NTuple{2, Float64}}, Int}()
    for panel in panels
        for (a, b) in _split_panel_edges(panel.polygon, verts)
            k = _edge_key(a, b)
            counts[k] = get(counts, k, 0) + 1
        end
    end
    boundary = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    interior = Vector{NTuple{2, Float64}}[]
    for (k, n) in counts
        if n == 1
            push!(boundary, k)
        elseif n == 2
            push!(interior, NTuple{2, Float64}[k[1], k[2]])
        else
            throw(ArgumentError("more than two panels share an edge $k"))
        end
    end
    isempty(boundary) && throw(ArgumentError("the story panels have no outer boundary"))
    loops = _closed_loops(boundary)
    areas = abs.(_story_area.(loops))
    outer_i = argmax(areas)
    outer = _drop_colinear(loops[outer_i])
    length(outer) >= 3 || throw(ArgumentError("the story outline is degenerate"))
    _story_area(outer) < 0 && reverse!(outer)
    for (i, loop) in enumerate(loops)
        i == outer_i && continue
        cx = sum(p[1] for p in loop) / length(loop)
        cy = sum(p[2] for p in loop) / length(loop)
        _pip_xy(cx, cy, outer) || throw(ArgumentError(
            "the story panels are not one connected plate"))
    end
    holes = Vector{NTuple{2, Float64}}[]
    for (i, loop) in enumerate(loops)
        i == outer_i && continue
        h = _drop_colinear(loop)
        length(h) >= 3 && push!(holes, h)
    end
    for panel in panels
        append!(holes, panel.holes)
    end
    return outer, interior, holes
end

"""
    story_shell(panels, beams; target_edge, section_at) -> NamedTuple

One shell for every panel, with the shared edges constrained so neighbouring
panels use the same nodes. Each triangle takes the thickness of the panel
that contains its centroid.

`beams` are frame elements on those nodes, not shells. `section_at(beam,
station)` replaces the section of the piece whose midpoint is `station`
metres along the beam. The shell edges are free. The caller fixes the supports.

Every shell node is on one plane, z = 0. A panel's thickness is centered on
that plane.
"""
function story_shell(panels::AbstractVector{StoryShellPanel}, beams;
                     target_edge::Length = 0.5u"m",
                     section_at = nothing)
    isempty(panels) && throw(ArgumentError("a story shell needs a panel"))
    outer, interior, holes = _story_plate(panels, beams)
    spacing = ustrip(u"m", target_edge)
    lines = Vector{NTuple{2, Float64}}[]
    append!(lines, interior)
    sampled_beams = ShellFrameBeam[]
    for b in beams
        line = _sample_polyline([_story_quantize(p) for p in b.xy], spacing)
        push!(lines, line)
        push!(sampled_beams, ShellFrameBeam(line, b.section;
                                            eccentricity = b.eccentricity, id = b.id))
    end
    corners = Tuple(Asap.Node([p[1] * u"m", p[2] * u"m", 0.0u"m"], :free) for p in outer)
    raw = Asap.Shell(corners, panels[1].section;
                     holes = holes,
                     interior_constrained_lines = lines,
                     edge_support_type = :free,
                     target_edge_length = target_edge,
                     id = :story)
    shells = Asap.ShellElement[]
    panel_index = Int[]
    for el in raw
        x, y = _triangle_centroid(el)
        i = _owning_panel(x, y, panels)
        push!(shells, _shell_on_section(el, panels[i].section))
        push!(panel_index, i)
    end
    nodes = _shell_nodes(shells)
    frames = frame_elements_on_shell(nodes, sampled_beams; section_at = section_at)
    return (
        shells = shells,
        frames = frames,
        nodes = nodes,
        panel_index = panel_index,
        boundary = outer,
    )
end
