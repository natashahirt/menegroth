# =============================================================================
# Cracked service shell — the re-solve
# =============================================================================
#
# Three service levels on the mesh `analyze_story_shell` already built:
# dead, dead plus the sustained part of live load, and dead plus all live
# load. Each level starts from the gross shell, scales stiffness to Ie/Ig,
# and re-solves until the scale settles. The gross factored solution is
# restored before this returns, so slab bars and strength demands stay on it.

"""
The straight run a steel shell beam is checked on.

`xy` is the whole run in plan, metres. `supports` are stations (m) held by a
column, a wall, a `:support`, or a line of a lower framing level.
`s0` and `s1` are this member's range on that run. `ids` are the shell ids of
every piece of the run, so the sag can be sampled on all of them. `total` is
the run length (m).
"""
struct ShellLineSpan
    xy::Vector{NTuple{2, Float64}}
    supports::Vector{Float64}
    s0::Float64
    s1::Float64
    ids::Vector{Symbol}
    total::Float64
end

"""
A beam the cracked service shell knows how to soften.

`I_service` (m⁴) is set for a steel or composite beam: the inertia of its
solved section under the checker's definition (see
[`StructuralSizer.SteelShellSpan`](@ref)). Zero for reinforced concrete.

`line` is set for steel and composite. Their live-load span is that run, not
the member polyline. Reinforced concrete leaves it `nothing` and keeps the
column spans, which also set the flange width.
"""
struct ShellServiceBeam
    id::Symbol
    xy::Vector{NTuple{2, Float64}}
    section::Any
    support_xy::Vector{NTuple{2, Float64}}
    half_width::Any
    flange_width::Any
    hf::Float64
    mu_neg::Float64
    hogging_strip::Bool
    I_service::Float64
    line::Union{Nothing, ShellLineSpan}
end

function ShellServiceBeam(id::Symbol, xy, section, support_xy;
                          half_width = _zero_width, flange_width = _zero_width,
                          hf::Real = 0.0, mu_neg::Real = 0.0,
                          hogging_strip::Bool = false, I_service::Real = 0.0,
                          line::Union{Nothing, ShellLineSpan} = nothing)
    return ShellServiceBeam(id, collect(NTuple{2, Float64}, xy), section,
                            collect(NTuple{2, Float64}, support_xy),
                            half_width, flange_width, Float64(hf), Float64(mu_neg),
                            hogging_strip, Float64(I_service), line)
end

_zero_width(::Real) = 0.0

_service_rc(section) = section isa RCBeamSection || section isa RCTBeamSection

"""Modulus of rupture including the lightweight factor of Eq. (9-10).

`fr` itself is `7.5 √f'c`. ACI 318-11 §9.5.2.3 Eq. (9-10) multiplies by λ
(corpus: aci-318-11, PDF p. 132).
"""
function _service_rupture(concrete)
    return ustrip(u"Pa", StructuralSizer.fr(concrete.fc′)) * concrete.λ
end

function _service_materials(concrete, rebar)
    return (
        Ec = ustrip(u"Pa", concrete.E),
        Es = ustrip(u"Pa", rebar.E),
        fr = _service_rupture(concrete),
        fc = ustrip(u"Pa", concrete.fc′),
        fy = ustrip(u"Pa", rebar.Fy),
    )
end

"""Top-bar area (m²/m) along `dir`, and `(h, d)` in metres, from the gross-shell bars."""
function story_top_steel(built, designs, bars)
    bars === nothing && return (_zero_steel, _zero_depth)
    nbar = length(bars)
    function as_top(k::Int, dir)
        p = built.panel_index[k]
        1 <= p <= nbar || return 0.0
        field = bars[p]
        r = findfirst(e -> e.elem_idx == k, field.elements)
        r === nothing && return 0.0
        elr = field.elements[r]
        ax, ay = StructuralSizer._resolve_rebar_axes(
            StructuralSizer.panel_shell(), designs[p].span_axis)
        cax = abs(dir[1] * ax[1] + dir[2] * ax[2])
        cay = abs(dir[1] * ay[1] + dir[2] * ay[2])
        return cax >= cay ? elr.As_x_top : elr.As_y_top
    end
    function depth_at(k::Int)
        p = built.panel_index[k]
        1 <= p <= nbar || return (0.0, 0.0)
        field = bars[p]
        return (field.h, field.d)
    end
    return as_top, depth_at
end

_zero_steel(::Int, ::Any) = 0.0
_zero_depth(::Int) = (0.0, 0.0)

function _service_loads(shells, panel_index, designs, frames, α::Float64)
    loads = Asap.AbstractLoad[]
    groups = Dict{Int, Vector{Asap.ShellElement}}()
    for (k, el) in enumerate(shells)
        k <= length(panel_index) || continue
        i = panel_index[k]
        i == 0 && continue
        push!(get!(() -> Asap.ShellElement[], groups, i), el)
    end
    for (i, els) in groups
        q = ustrip(u"Pa", designs[i].q_dead) + α * ustrip(u"Pa", designs[i].q_live)
        push!(loads, Asap.AreaLoad(els, q * u"Pa"))
    end
    for el in frames
        push!(loads, Asap.GravityLoad(el, 9.80665u"m/s^2"))
    end
    return loads
end

function _interp(samples, s::Float64)
    isempty(samples) && return 0.0
    s <= samples[1][1] && return samples[1][2]
    s >= samples[end][1] && return samples[end][2]
    for i in 1:(length(samples) - 1)
        s0, v0 = samples[i]
        s1, v1 = samples[i + 1]
        s0 <= s <= s1 || continue
        t = s1 == s0 ? 0.0 : (s - s0) / (s1 - s0)
        return v0 + t * (v1 - v0)
    end
    return samples[end][2]
end

function _mid_station(el, xy, total)
    x = ustrip(u"m", (el.nodeStart.position[1] + el.nodeEnd.position[1]) / 2)
    y = ustrip(u"m", (el.nodeStart.position[2] + el.nodeEnd.position[2]) / 2)
    _, s = StructuralSizer._station_on_polyline(x, y, xy)
    return total > 0 ? s / total : 0.0
end

"""Sagging-positive moment samples `(station, N·m)` along `pieces`."""
function _sagging_samples(pieces, xy, u, elemental, total)
    samples = Tuple{Float64, Float64}[]
    total > 0 || return samples
    for el in pieces
        loads = 1 <= el.elementID <= length(elemental) ? elemental[el.elementID] : Asap.AbstractLoad[]
        f = _element_forces_from_u(el, u, loads; resolution = 5)
        sgn = el.LCS[2][3] > 0 ? 1.0 : -1.0
        x0 = ustrip(u"m", el.nodeStart.position[1])
        y0 = ustrip(u"m", el.nodeStart.position[2])
        x1 = ustrip(u"m", el.nodeEnd.position[1])
        y1 = ustrip(u"m", el.nodeEnd.position[2])
        _, s0 = StructuralSizer._station_on_polyline(x0, y0, xy)
        _, s1 = StructuralSizer._station_on_polyline(x1, y1, xy)
        n = length(f.My)
        for j in 1:n
            t = n == 1 ? 0.0 : (j - 1) / (n - 1)
            s = (s0 + t * (s1 - s0)) / total
            push!(samples, (s, sgn * f.My[j]))
        end
    end
    sort!(samples; by = first)
    return samples
end

"""Nodal `(station, uz)` with `uz` in metres, positive upward."""
function _nodal_uz(pieces, xy, u, total)
    pts = Dict{Int, Tuple{Float64, Float64}}()
    for el in pieces
        for node in (el.nodeStart, el.nodeEnd)
            x = ustrip(u"m", node.position[1])
            y = ustrip(u"m", node.position[2])
            _, s_m = StructuralSizer._station_on_polyline(x, y, xy)
            s = total > 0 ? s_m / total : 0.0
            gid = node.globalID[3]
            uz = 1 <= gid <= length(u) ? u[gid] : 0.0
            pts[node.nodeID] = (s, uz)
        end
    end
    samples = collect(values(pts))
    sort!(samples; by = first)
    return samples
end

function _span_sagging(samples, s0, s1)
    m = 0.0
    for (s, v) in samples
        s0 - 1e-6 <= s <= s1 + 1e-6 || continue
        m = max(m, v)
    end
    return m
end

function _span_deflection(nodes, sp)
    if sp.cantilever
        # The tip displacement relative to the support, not the bow of the chord.
        free_at_start = sp.end1_continuous && !sp.end0_continuous
        u_free = _interp(nodes, free_at_start ? sp.s0 : sp.s1)
        u_sup = _interp(nodes, free_at_start ? sp.s1 : sp.s0)
        return max(0.0, -(u_free - u_sup))
    end
    sel = Tuple{Float64, Float64}[(s, uz) for (s, uz) in nodes if sp.s0 - 1e-8 <= s <= sp.s1 + 1e-8]
    if isempty(sel) || sel[1][1] > sp.s0 + 1e-8
        pushfirst!(sel, (sp.s0, _interp(nodes, sp.s0)))
    end
    if sel[end][1] < sp.s1 - 1e-8
        push!(sel, (sp.s1, _interp(nodes, sp.s1)))
    end
    return StructuralSizer.chord_deflection(first.(sel), last.(sel))
end

function _span_end_moments(samples, sp)
    m0 = _interp(samples, sp.s0)
    m1 = _interp(samples, sp.s1)
    neg = Float64[]
    if sp.cantilever
        push!(neg, max(sp.end1_continuous ? -m1 : -m0, 0.0))
    else
        sp.end0_continuous && push!(neg, max(-m0, 0.0))
        sp.end1_continuous && push!(neg, max(-m1, 0.0))
    end
    return neg
end

"""Plates whose centroid lies within `half_width` of `xy` and inside `[s0, s1]`."""
function _plates_in_strip(shells, xy, s0, s1, half_width)
    hits = Tuple{Int, Float64, Float64}[]
    for (k, el) in enumerate(shells)
        el.id === :wall && continue
        x, y = StructuralSizer._triangle_centroid(el)
        dist, s_m = StructuralSizer._station_on_polyline(x, y, xy)
        total = StructuralSizer.polyline_length(xy)
        s = total > 0 ? s_m / total : 0.0
        s0 - 1e-6 <= s <= s1 + 1e-6 || continue
        hw = half_width(s)
        hw > 0 || continue
        dist <= hw || continue
        push!(hits, (k, s, dist))
    end
    return hits
end

function _reading(sp, total, Ma_pos, Ma_neg, Δ, bf, hf, Ig, Ie)
    return (
        s0 = sp.s0, s1 = sp.s1, cantilever = sp.cantilever,
        L = (sp.s1 - sp.s0) * total, bf = bf, hf = hf,
        Ma_pos = Ma_pos, Ma_neg = Ma_neg, Δ = Δ, Ig = Ig, Ie = Ie,
    )
end

"""
Where each shell beam sits on its framing line.

A steel span is this line, from support to support. The supports are the
columns, walls, and `:support` vertices on the line, and any crossing with a
line of a lower framing level. A crossing of the same level is not a support.
Reinforced concrete does not use this table.
"""
function _shell_line_lookup(struc::BuildingStructure)
    assign_framing_levels!(struc)
    lines = _constant_level_lines(struc, _frame_lines(struc))
    fixed = beam_support_lookup(struc).fixed
    at = Dict{Int, Vector{Int}}()
    level_of = Int[]
    for (i, ln) in enumerate(lines)
        push!(level_of, struc.beams[ln.beams[1]].level)
        for v in ln.verts
            push!(get!(at, v, Int[]), i)
        end
    end
    table = Dict{Symbol, ShellLineSpan}()
    for (i, ln) in enumerate(lines)
        cum, xyz = _line_stations(struc.skeleton, ln.verts)
        xy = NTuple{2, Float64}[(p[1], p[2]) for p in xyz]
        supports = _line_support_stations(ln, i, lines, at, fixed, cum, level_of)
        ids = Symbol[Symbol("beam_", bi) for bi in ln.beams]
        station = Dict(v => cum[k] for (k, v) in enumerate(ln.verts))
        for bi in ln.beams
            chain = _beam_vertex_chain(struc, struc.beams[bi])
            chain === nothing && continue
            s0, s1 = Inf, -Inf
            for v in chain
                haskey(station, v) || continue
                s0 = min(s0, station[v])
                s1 = max(s1, station[v])
            end
            isfinite(s0) || continue
            table[Symbol("beam_", bi)] = ShellLineSpan(xy, supports, s0, s1, ids, cum[end])
        end
    end
    return table
end

"""Stations (m) and upward displacement of one frame element, on `xy`."""
function _profile_line_samples(el, u, loads, xy)
    prof = Asap.element_deflection_profile(el, u, loads; resolution = 21)
    x0 = ustrip(u"m", el.nodeStart.position[1])
    y0 = ustrip(u"m", el.nodeStart.position[2])
    x1 = ustrip(u"m", el.nodeEnd.position[1])
    y1 = ustrip(u"m", el.nodeEnd.position[2])
    _, s0 = StructuralSizer._station_on_polyline(x0, y0, xy)
    _, s1 = StructuralSizer._station_on_polyline(x1, y1, xy)
    n = length(prof)
    out = Tuple{Float64, Float64}[]
    for i in 1:n
        t = n == 1 ? 0.0 : (i - 1) / (n - 1)
        push!(out, (s0 + t * (s1 - s0), prof[i]))
    end
    return out
end

"""
Live-load readings of one steel piece, measured on its framing line.

The offset is taken from the element shape, not from the nodes alone. A span
that is a single element still has its bow. `L` is the support-to-support
length, or twice the cantilever length (IBC 2021 Table 1604.3 footnote i,
corpus: ibc-2021, PDF p. 418). `loads_of` is one load vector per frame element.
"""
function _steel_line_readings(frames, u, loads_of, beam, cache)
    line = beam.line
    key = line.ids[1]
    samples = get!(cache, key) do
        wanted = Set(line.ids)
        out = Tuple{Float64, Float64}[]
        for el in frames
            el.id in wanted || continue
            raw = 1 <= el.elementID <= length(loads_of) ? loads_of[el.elementID] : Asap.AbstractLoad[]
            mine = Asap.AbstractLoad[ld for ld in raw if ld.element === el]
            append!(out, _profile_line_samples(el, u, mine, line.xy))
        end
        sort!(out; by = first)
        out
    end
    spans = _deflection_spans(line.supports, line.total)
    mine = Tuple{Float64, Float64}[(s, uz) for (s, uz) in samples
                                   if line.s0 - 1e-4 <= s <= line.s1 + 1e-4]
    readings = NamedTuple[]
    for (a, b, kind) in spans
        min(line.s1, b) - max(line.s0, a) > 1e-4 || continue
        sel = Tuple{Float64, Float64}[(s, uz) for (s, uz) in mine
                                      if a - 1e-4 <= s <= b + 1e-4]
        δ, L = _span_offset(kind, a, b, sel, samples)
        L > 1e-8 || continue
        push!(readings, (
            s0 = a, s1 = b, cantilever = kind !== :chord,
            L = L, bf = 0.0, hf = beam.hf,
            Ma_pos = 0.0, Ma_neg = Float64[], Δ = δ, Ig = 0.0, Ie = 0.0,
        ))
    end
    return readings
end

"""
Moment, deflection, and the next `Ie/Ig` from the solution now on `model`.

`shell_k` and `frame_k` are the scales the next solve should use. A plate
covered by more than one strip takes the smaller scale.

# ENGINEERING JUDGMENT
- Overlapping strips keep the minimum factor. Two beams claiming one plate
  would otherwise leave it at the stiffer of the two.
- The factored hogging moment used to pick an RC span's top bars is the
  shell demand's envelope. More top steel raises `Icr` and lowers the
  computed deflection.
- A steel or composite frame is not scaled. Its section is already `I_LB`
  or the cracked hogging inertia, and the shell carries the slab bending.
"""
function _service_reading(model, built, beams, materials, as_top, depth_at)
    shells = model.shell_elements
    frames = model.frame_elements
    n_s, n_f = length(shells), length(frames)
    shell_k = ones(n_s)
    frame_k = ones(n_f)
    moments = StructuralSizer._story_moment_field(model)
    elemental = Asap.get_elemental_loads(model)
    # The profile's particular solution must be this solve's loads. The cached
    # map can still be the factored case.
    loads_of = Asap.get_elemental_loads(model.loads, length(frames))
    u = model.u
    frame_of = IdDict{Any, Int}(el => i for (i, el) in enumerate(frames))
    per_beam = Dict{Symbol, Vector{NamedTuple}}()
    mat = materials
    # One profile per framing line, shared by every piece of that line.
    line_cache = Dict{Symbol, Vector{Tuple{Float64, Float64}}}()

    for beam in beams
        total = StructuralSizer.polyline_length(beam.xy)
        pieces = [el for el in frames if el.id == beam.id]
        sort!(pieces; by = el -> _mid_station(el, beam.xy, total))
        samples = _sagging_samples(pieces, beam.xy, u, elemental, total)
        # Steel is measured on the framing line. The column spans stay for
        # reinforced concrete, where they also set the flange and the cracked
        # inertia.
        if !_service_rc(beam.section) && beam.line !== nothing
            per_beam[beam.id] = _steel_line_readings(frames, u, loads_of, beam, line_cache)
            beam.hogging_strip && _soften_hogging!(
                shell_k, shells, moments, samples, beam, as_top, depth_at, mat)
            continue
        end
        nodes = _nodal_uz(pieces, beam.xy, u, total)
        spans = StructuralSizer.shell_service_spans(beam.xy, beam.support_xy)
        readings = NamedTuple[]
        span_k = Float64[]
        rc = _service_rc(beam.section)
        for sp in spans
            Ma_pos = _span_sagging(samples, sp.s0, sp.s1)
            Ma_neg = _span_end_moments(samples, sp)
            Δ = _span_deflection(nodes, sp)
            mid = (sp.s0 + sp.s1) / 2
            bf = beam.flange_width(mid)
            if rc
                web = StructuralSizer._shell_web(beam.section)
                bf = max(bf, ustrip(u"m", web.bw))
                props = StructuralSizer.rc_span_inertia(
                    beam.section, bf, beam.hf, Ma_pos, Ma_neg, beam.mu_neg;
                    Ec = mat.Ec, Es = mat.Es, fr = mat.fr, fc = mat.fc, fy = mat.fy,
                    cantilever = sp.cantilever)
                k = props.Ig > 0 ? clamp(props.Ie / props.Ig, 1e-4, 1.0) : 1.0
                Ig, Ie = props.Ig, props.Ie
            else
                k, Ig, Ie = 1.0, 0.0, 0.0
            end
            push!(span_k, k)
            push!(readings, _reading(sp, total, Ma_pos, Ma_neg, Δ, bf, beam.hf, Ig, Ie))
            rc || continue
            for (k_plate, _, _) in _plates_in_strip(shells, beam.xy, sp.s0, sp.s1, beam.half_width)
                shell_k[k_plate] = min(shell_k[k_plate], k)
            end
        end
        if rc
            for (sp, k) in zip(spans, span_k)
                for el in pieces
                    s = _mid_station(el, beam.xy, total)
                    sp.s0 - 1e-6 <= s <= sp.s1 + 1e-6 || continue
                    i = frame_of[el]
                    frame_k[i] = min(frame_k[i], k)
                end
            end
        end
        if beam.hogging_strip && !rc
            _soften_hogging!(shell_k, shells, moments, samples, beam, as_top, depth_at, mat)
        end
        per_beam[beam.id] = readings
    end
    return (shell_k = shell_k, frame_k = frame_k, beams = per_beam)
end

"""
Soften plates over a hogging stretch. Eq. (9-8) on the slab strip, with the
top bars taken from the gross-shell design. A plate already scaled by another
strip keeps the smaller factor.
"""
function _soften_hogging!(shell_k, shells, moments, samples, beam, as_top, depth_at, mat)
    for (k, s, _) in _plates_in_strip(shells, beam.xy, 0.0, 1.0, beam.half_width)
        _interp(samples, s) < -1.0 || continue
        el = shells[k]
        ex = (el.LCS[1][1], el.LCS[1][2])
        ey = (el.LCS[2][1], el.LCS[2][2])
        dir = StructuralSizer.polyline_direction(beam.xy, s)
        Mxx, Myy, Mxy = moments[k]
        tx = dir[1] * ex[1] + dir[2] * ex[2]
        ty = dir[1] * ey[1] + dir[2] * ey[2]
        Ma = max(Mxx * tx^2 + Myy * ty^2 + 2 * Mxy * tx * ty, 0.0)
        As = as_top(k, dir)
        h, d = depth_at(k)
        k_strip = StructuralSizer.slab_strip_inertia_ratio(
            Ma, As, h, d, mat.Ec, mat.Es, mat.fr)
        shell_k[k] = min(shell_k[k], k_strip)
    end
    return shell_k
end

"""Next service scales: a cracked plate or piece stays cracked (see [`story_cracked_service`](@ref))."""
_ratchet_scales(k, reading) = min.(k, reading)

function _scales_settled(a, b, tol)
    length(a) == length(b) || return false
    return maximum(abs.(a .- b); init = 0.0) <= tol
end

function _assemble_spans(levels, beam, mat)
    dead = levels[:D]
    full = levels[:DL]
    sus = get(levels, :S, dead)
    length(dead) == length(full) == length(sus) || throw(ArgumentError(
        "service levels of beam $(beam.id) produced different spans"))
    spans = StructuralSizer.RCShellSpan[]
    for i in eachindex(dead)
        a, b, c = dead[i], sus[i], full[i]
        push!(spans, StructuralSizer.RCShellSpan(;
            L = a.L, bf = a.bf, hf = a.hf, cantilever = a.cantilever,
            Ma_D_pos = a.Ma_pos, Ma_S_pos = b.Ma_pos, Ma_DL_pos = c.Ma_pos,
            Ma_D_neg = a.Ma_neg, Ma_S_neg = b.Ma_neg, Ma_DL_neg = c.Ma_neg,
            Mu_neg = beam.mu_neg,
            Δ_D = a.Δ, Δ_S = b.Δ, Δ_DL = c.Δ,
            Ie_D = a.Ie, Ie_S = b.Ie, Ie_DL = c.Ie,
            Ec = mat.Ec, Es = mat.Es, fr = mat.fr, fc = mat.fc, fy = mat.fy))
    end
    return spans
end

"""
Live-load span records of a steel or composite beam. Only live load: the
shell has hardened composite stiffness throughout, so it cannot carry an
unshored beam's wet-concrete stage. Total deflection stays with the frame model.
"""
function _assemble_steel_spans(levels, beam)
    dead = levels[:D]
    full = levels[:DL]
    length(dead) == length(full) || throw(ArgumentError(
        "service levels of beam $(beam.id) produced different spans"))
    name = StructuralSizer._shell_section_name(beam.section)
    spans = StructuralSizer.SteelShellSpan[]
    for (a, c) in zip(dead, full)
        a.L > 0 || continue
        push!(spans, StructuralSizer.SteelShellSpan(;
            L = a.L, Δ_LL = max(0.0, c.Δ - a.Δ),
            I_solved = beam.I_service, solved = name))
    end
    return spans
end

"""
Put the model's column springs back into the stiffness.

`Asap.update!(; values_only=true)` rebuilds the stiffness from the elements
and drops grounded springs. The spring objects stay on `model.springs`.
"""
function _restore_column_springs!(model)
    isempty(model.springs) && return model
    Asap.add_springs!(model, model.springs)
    return model
end

"""
    story_cracked_service(model, built, designs, beams; concrete, rebar,
        sustained_live_fraction=0, max_iter=6, tol=0.02) -> NamedTuple

Re-solve `model` at service level and restore the gross factored state.

`designs` are the story panels, in `built.panel_index` order. `beams` are
[`ShellServiceBeam`](@ref)s. `ψ = 0` sustains dead load only and `ψ = 1`
sustains dead plus all live load, so neither is a third factorization
(ACI 318-11 R9.5.2.5, corpus: aci-318-11, PDF p. 132).

`Asap.update!(; values_only=true)` rebuilds the stiffness from the elements
and drops grounded springs. [`_restore_column_springs!`](@ref) puts the column
springs back before each solve.

# ENGINEERING JUDGMENT
Within one service level a plate or piece that has cracked stays cracked: its
scale only goes down from one iteration to the next. ACI 318-11 defines `Ma`
as the maximum service moment at the stage deflection is computed (notation,
corpus: aci-318-11, PDF p. 27), and does not say whether that is before or
after cracked parts shed moment. Recomputing each scale from scratch lets a
softened plate shed enough moment to read uncracked, and the next solve
cracks it again. The one-way scale settles, on the soft side.

Returns `spans`, one vector per beam id: [`StructuralSizer.RCShellSpan`](@ref)s
for reinforced concrete and [`StructuralSizer.SteelShellSpan`](@ref)s (live
load only) for steel and composite. Also `iterations` and `converged`.
With `keep = true`, `service_model` is a copy of the model in its settled
dead-plus-live state: cracked stiffness, service loads and column springs.
Solving that copy again gives the displacements the deflection check read.
"""
function story_cracked_service(model, built, designs, beams::AbstractVector{ShellServiceBeam};
                              concrete, rebar = Rebar_60,
                              bars = nothing,
                              sustained_live_fraction::Real = 0.0,
                              max_iter::Int = 6, tol::Float64 = 0.02,
                              keep::Bool = false)
    max_iter >= 1 || throw(ArgumentError("max_iter must be at least 1"))
    ψ = StructuralSizer._as_sustained_live_fraction(sustained_live_fraction)
    shells = model.shell_elements
    frames = model.frame_elements
    isempty(shells) && throw(ArgumentError("the service shell has no plates"))
    saved_loads = model.loads
    base_E = [el.E for el in shells]
    base_sections = [el.section for el in frames]
    mat = _service_materials(concrete, rebar)
    as_top, depth_at = bars === nothing ? (_zero_steel, _zero_depth) :
                       story_top_steel(built, designs, bars)

    levels_of = Dict{Symbol, Dict{Symbol, Vector{NamedTuple}}}()
    iterations = 0
    converged = true
    kept = nothing
    try
        for (name, α) in ((:D, 0.0), (:DL, 1.0), (:S, ψ))
            name === :S && (ψ == 0.0 || ψ == 1.0) && continue
            shell_k = ones(length(shells))
            frame_k = ones(length(frames))
            reading = nothing
            settled = false
            for iter in 1:max_iter
                StructuralSizer.apply_service_scales!(
                    shells, frames, shell_k, frame_k, base_E, base_sections)
                model.loads = _service_loads(shells, built.panel_index, designs, frames, α)
                Asap.update!(model; values_only = true)
                _restore_column_springs!(model)
                Asap.solve!(model)
                reading = _service_reading(model, built, beams, mat, as_top, depth_at)
                iterations = max(iterations, iter)
                next_shell = _ratchet_scales(shell_k, reading.shell_k)
                next_frame = _ratchet_scales(frame_k, reading.frame_k)
                if _scales_settled(shell_k, next_shell, tol) &&
                        _scales_settled(frame_k, next_frame, tol)
                    settled = true
                    break
                end
                shell_k = next_shell
                frame_k = next_frame
            end
            converged &= settled
            levels_of[name] = reading.beams
            keep && name === :DL && (kept = copy_solved_model(model))
        end
    finally
        for (el, E) in zip(shells, base_E)
            el.E = E
        end
        for (el, sec) in zip(frames, base_sections)
            el.section = sec
        end
        model.loads = saved_loads
        Asap.update!(model; values_only = true)
        _restore_column_springs!(model)
        Asap.solve!(model)
    end

    if ψ == 0.0
        levels_of[:S] = levels_of[:D]
    elseif ψ == 1.0
        levels_of[:S] = levels_of[:DL]
    end

    spans = Dict{Symbol, Vector{Any}}()
    for beam in beams
        levels = Dict{Symbol, Vector{NamedTuple}}(
            name => get(levels_of[name], beam.id, NamedTuple[]) for name in (:D, :S, :DL))
        isempty(levels[:D]) && continue
        if _service_rc(beam.section)
            spans[beam.id] = collect(Any, _assemble_spans(levels, beam, mat))
        elseif beam.I_service > 0
            spans[beam.id] = collect(Any, _assemble_steel_spans(levels, beam))
        end
    end
    return (spans = spans, iterations = iterations, converged = converged,
            service_model = kept)
end

"""
    copy_solved_model(model) -> Asap.Model

Independent copy of `model`, without its factorization or elemental-load
cache. The factorization holds a C pointer that `deepcopy` must not touch.
Both caches are rebuilt on the copy's next solve.
"""
function copy_solved_model(model)
    fact = model._factorization
    eloads = model._elemental_loads
    model._factorization = nothing
    model._elemental_loads = nothing
    try
        return deepcopy(model)
    finally
        model._factorization = fact
        model._elemental_loads = eloads
    end
end

# -----------------------------------------------------------------------------
# Building beams → service beams
# -----------------------------------------------------------------------------

"""Span length, in metres, containing normalized station `s`."""
function _service_span_length(xy, support_xy, s)
    spans = StructuralSizer.shell_service_spans(xy, support_xy)
    total = StructuralSizer.polyline_length(xy)
    for sp in spans
        if sp.s0 - 1e-6 <= s <= sp.s1 + 1e-6
            return max((sp.s1 - sp.s0) * total, 1e-6) * u"m"
        end
    end
    return max(total, 1e-6) * u"m"
end

"""
ACI 318-11 §8.12 flange. `half` is the wider side's overhang, because a plate's
distance to the centreline is unsigned. `full` is the flange width `bf`.
`sides` is `(; left, right, left_clear, right_clear, one_side)` from
[`_service_flange_sides`](@ref).
"""
function _rc_flange_widths(bw, hf, xy, support_xy, sides)
    (; left, right, left_clear, right_clear) = sides
    one = something(sides.one_side, isnothing(left) || isnothing(right))
    function overhangs(s)
        ln = _service_span_length(xy, support_xy, s)
        ol = ustrip(u"m", StructuralSizer._aci_side_overhang(left, s, hf, ln, one, left_clear))
        orr = ustrip(u"m", StructuralSizer._aci_side_overhang(right, s, hf, ln, one, right_clear))
        return ol, orr
    end
    half = function (s)
        ol, orr = overhangs(s)
        return max(ol, orr)
    end
    full = function (s)
        ol, orr = overhangs(s)
        return ustrip(u"m", bw) + ol + orr
    end
    return half, full
end

"""
Wider of the two §I3.1a side widths, in metres.

The plate test has no signed side, so the wider side sets the strip
(engineering judgment). Each side is capped by the same helper
[`b_eff_at_station`](@ref) uses (AISC 360-16 §I3.1a, corpus: aisc-360-16,
PDF p. 150). `flip` matches a composite field whose origin is the far end
of the shell polyline.
"""
function _composite_half_width(profile, flip::Bool)
    return function (s)
        sp = flip ? 1 - Float64(s) : Float64(s)
        L = StructuralSizer.span_at_station(profile.L, sp, profile.supports)
        left, right, slab = profile.left, profile.right, profile.slab
        side(p, spacing, edge) = p === nothing ?
            StructuralSizer._effective_half_width(L, spacing, edge) :
            StructuralSizer._effective_half_width(
                L, 2 * StructuralSizer._sample_extent(p, sp) * u"m", nothing)
        bl = side(left, slab.beam_spacing_left, slab.edge_dist_left)
        br = side(right, slab.beam_spacing_right, slab.edge_dist_right)
        return max(ustrip(u"m", bl), ustrip(u"m", br))
    end
end

"""
Tributary half-width of a bare steel beam. There is no §I3.1a width to apply;
the strip is the slab that bears on the beam (engineering judgment).
"""
function _tributary_half_width(left, right)
    return function (s)
        dl = left === nothing ? 0.0 : StructuralSizer._sample_extent(left, s)
        dr = right === nothing ? 0.0 : StructuralSizer._sample_extent(right, s)
        return max(dl, dr)
    end
end

"""
    service_beams(struc, shell_beams, beam_index, beam_demands, support_points,
                  thickness_of_face) -> Vector{ShellServiceBeam}

One [`ShellServiceBeam`](@ref) per shell beam that has a building section.
Reinforced-concrete beams carry their flange. Steel and composite beams carry
a hogging strip and no span inertia.
"""
function service_beams(struc, shell_beams, beam_index, beam_demands,
                       support_points, thickness_of_face)
    specs = ShellServiceBeam[]
    ctx = _flange_context(struc)
    lines_of = _shell_line_lookup(struc)
    for shell_beam in shell_beams
        i = get(beam_index, shell_beam.id, nothing)
        i === nothing && continue
        beam = struc.beams[i]
        sec = _story_beam_section(struc, beam)
        sec === nothing && continue
        h = _story_beam_thickness(struc, beam, thickness_of_face)
        hf = h === nothing ? 0.0 : ustrip(u"m", h)
        demand = get(beam_demands, i, nothing)
        mu_neg = demand === nothing ? 0.0 : demand.Mu_neg
        xy = shell_beam.xy
        if _service_rc(sec)
            web = StructuralSizer._shell_web(sec)
            sides = _service_flange_sides(struc, i, web.bw, ctx)
            sides === nothing && (sides = (left = nothing, right = nothing,
                left_clear = nothing, right_clear = nothing, one_side = nothing, hf = nothing))
            # A framing-level member bears the topping of the slab it frames.
            sides.hf === nothing || (hf = ustrip(u"m", sides.hf))
            half, full = _rc_flange_widths(web.bw, hf * u"m", xy, support_points, sides)
            push!(specs, ShellServiceBeam(shell_beam.id, xy, sec, support_points;
                half_width = half, flange_width = full, hf = hf, mu_neg = mu_neg,
                hogging_strip = false))
        else
            profile = composite_stiffness_profile(struc, beam)
            composite = profile !== nothing && _sections_identical(profile.section, sec)
            half = if composite
                flip = _story_origin_at_end(xy, profile.origin)
                _composite_half_width(profile, flip)
            else
                left, right = beam_side_profiles(struc, beam)
                _tributary_half_width(left, right)
            end
            I_svc = composite ? _solved_service_inertia(profile) :
                    _steel_strong_inertia(sec)
            push!(specs, ShellServiceBeam(shell_beam.id, xy, sec, support_points;
                half_width = half, hf = hf, mu_neg = mu_neg, hogging_strip = true,
                I_service = I_svc, line = get(lines_of, shell_beam.id, nothing)))
        end
    end
    return specs
end

"""Strong-axis inertia (m⁴) of a bare steel section, or 0 when it has none."""
function _steel_strong_inertia(sec)
    hasproperty(sec, :Ix) || return 0.0
    return ustrip(u"m^4", uconvert(u"m^4", sec.Ix))
end

"""
Service inertia (m⁴) of the section the shell solved, under the definition
the composite checker applies to a candidate: `I_LB` at the peak of the
region of greatest positive moment, combined with the cracked negative
inertia by Eq. C-I3-5 when the member also hogs (AISC 360-22 Commentary,
corpus: aisc-360-22, PDF p. 502).

Both inertias come from the recorded profile on the frame model's regions,
the definition the checker applies to a candidate. The shell itself places
them on its own regions, so near its own hogging it can be softer than this.
The solved section is checked unscaled, so that difference only reaches the
scaling of other candidates.
"""
function _solved_service_inertia(profile)
    regions = profile.regions
    isempty(regions) && return ustrip(u"m^4", uconvert(u"m^4",
        StructuralSizer.get_I_cracked_negative(profile.section, profile.Asr;
                                               d_rebar = profile.d_rebar)))
    primary = argmax(r -> r.M_peak, regions)
    I_pos = composite_stiffness_at(profile, primary.s_peak)
    covered = sum(r.s_right - r.s_left for r in regions)
    continuous = covered < 1 - 1e-3
    I_neg = StructuralSizer.get_I_cracked_negative(profile.section, profile.Asr;
                                                    d_rebar = profile.d_rebar)
    I = StructuralSizer.composite_service_inertia(I_pos, I_neg; continuous = continuous)
    return ustrip(u"m^4", uconvert(u"m^4", I))
end
