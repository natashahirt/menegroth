# =============================================================================
# Discrete steel member sizing (simultaneous, catalog-based)
# =============================================================================

"""
    ColumnCaseRow

One column's demands in one pattern case, all from that case [N, N·m].
`Pu_c` is the largest compression along the member, `Mux`/`Muy` the largest
moments, and `M1`/`M2` the signed end moments (ACI 318-19 convention).
"""
struct ColumnCaseRow
    Pu_c::Float64
    Mux::Float64
    Muy::Float64
    M1x::Float64
    M2x::Float64
    M1y::Float64
    M2y::Float64
end

"""
    BeamShearCase

One beam's shear and flexure in one pattern case, all from that case [N, N·m].

`Vu` is the largest |Vy| (strong-axis shear). `Nu` is the axial at that
same station, compression-positive, so a gravity case is not credited with
another case's compression. `Tu` is torsion; station diagrams carry none,
so gravity rows are 0. `Mu_pos` and `Mu_neg` are that case's sagging and
hogging peaks, so a moment that is not the shear governor is still a
flexure case.
"""
struct BeamShearCase
    Vu::Float64
    Nu::Float64
    Tu::Float64
    Mu_pos::Float64
    Mu_neg::Float64
end

"""Shear row with no flexure. Callers that have a moment pass the five-field form."""
BeamShearCase(Vu, Nu, Tu) = BeamShearCase(Float64(Vu), Float64(Nu), Float64(Tu), 0.0, 0.0)

"""
    build_member_groups!(struc::BuildingStructure; member_type::Symbol=:beams)

Populate `struc.member_groups` from the specified member collection.

- `member_type`: Which members to group - `:beams`, `:columns`, `:struts`, or `:all`
- If `member.base.group_id === nothing`, the member is treated as its own singleton group
  and a deterministic `UInt64` group id is assigned.
- If `member.base.group_id` is set, all members with the same id are grouped together.

Note: member_indices in MemberGroup refer to indices within the specific member vector
(e.g., struc.beams[idx] for beams).
"""
function build_member_groups!(struc::BuildingStructure; member_type::Symbol=:beams)
    empty!(struc.member_groups)
    
    members = if member_type == :beams
        struc.beams
    elseif member_type == :columns
        struc.columns
    elseif member_type == :struts
        struc.struts
    elseif member_type == :all
        collect(all_members(struc))
    else
        throw(ArgumentError("Unknown member_type: $member_type. Use :beams, :columns, :struts, or :all"))
    end

    for (m_idx, m) in enumerate(members)
        gid = group_id(m) === nothing ? UInt64(hash((:singleton_member_group, member_type, m_idx))) : group_id(m)
        # Persist the resolved group id back onto the member
        set_group_id!(m, gid)

        mg = get!(struc.member_groups, gid) do
            MemberGroup(gid)
        end
        push!(mg.member_indices, m_idx)
    end

    return struc.member_groups
end

"""Stations per element for service deflection; odd so midspan is sampled."""
const _SERVICE_DEFLECTION_STATIONS = 41

"""Copy of a slab tributary load at an unfactored pressure (same geometry, element, id)."""
_tributary_at(ld::Asap.TributaryLoad, p) =
    Asap.TributaryLoad(ld.element, copy(ld.positions), copy(ld.widths), p, ld.direction, ld.id)

"""Copy of a slab `AreaLoad` at an unfactored pressure (same shells and distribution)."""
_area_load_at(ld::Asap.AreaLoad, p) =
    Asap.AreaLoad(ld.shells, p; distribute_to = ld.distribute_to,
                  interior_beams = ld.interior_beams, axis = ld.axis,
                  direction = ld.direction, id = ld.id)

"""
    _service_dead_live_loads(struc) -> (dead, live, sdl)

Unfactored dead, live, and superimposed-dead gravity load sets for the service
deflection solve,
built from the loads on `struc.asap_model` whatever `pattern_loading` is.

Slab pressure keeps the routing of the factored model and only the pressure
changes: dead is `sdl + self_weight`, live is `live_load`, each at factor 1.
- Per-cell, joist-strip, grillage, and slab edge-strip tributary loads are
  copied from the cell records: `cell_dead_loads` / `cell_live_loads` when the
  model was built split (pattern loading), else `cell_tributary_loads`, which
  then holds one copy at the enveloped pressure. Records under a framed slab's
  first cell carry that cell's pressure, as in the factored build.
- Shell-area slab `AreaLoad`s are copied one per eligible slab, in the order of
  `_sync_shell_area_pressures!`.

Dead also holds the unfactored member self-weight (`GravityLoad` at `g`),
fire-protection coating, drop-panel weight, curtain-wall cladding, and wall
self-weight: the same set
as `_unfactored_DL_loads` (foundations). `sdl` is only `cell.sdl` on the same
tributary routing, with self-weight left out. Vault thrust is split into its
dead and live parts and is not part of `sdl`. A `:p_delta` notional lateral
force is not gravity and is left out.
Any other load on the model throws, so a load cannot drop out of the check.

ASCE 7-16 Commentary CC.2.1 (corpus: asce-7-16, PDF p. 856) states the
historical floor limit "1/360 of the span for floors subjected to full nominal
live load": nominal, so no load factor is applied.
"""
function _service_dead_live_loads(struc::BuildingStructure)
    model = struc.asap_model
    isnothing(model) && throw(ArgumentError(
        "service deflection: the building has no Asap model. Run to_asap! first."))
    dead = Asap.AbstractLoad[]
    live = Asap.AbstractLoad[]
    sdl = Asap.AbstractLoad[]

    has_records = false
    for (ci, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        d_rec = get(struc.cell_dead_loads, ci, Asap.TributaryLoad[])
        l_rec = get(struc.cell_live_loads, ci, Asap.TributaryLoad[])
        all_rec = get(struc.cell_tributary_loads, ci, Asap.TributaryLoad[])
        p_D = uconvert(u"Pa", cell.sdl + cell.self_weight)
        p_L = uconvert(u"Pa", cell.live_load)
        if !isempty(d_rec) || !isempty(l_rec)
            foreach(ld -> push!(dead, _tributary_at(ld, p_D)), d_rec)
            foreach(ld -> push!(live, _tributary_at(ld, p_L)), l_rec)
        else
            for ld in all_rec
                push!(dead, _tributary_at(ld, p_D))
                push!(live, _tributary_at(ld, p_L))
            end
        end
        has_records |= !(isempty(d_rec) && isempty(l_rec) && isempty(all_rec))
    end

    slab_area_loads = Asap.AreaLoad[]
    n_thrust = 0
    for ld in model.loads
        if ld isa Asap.TributaryLoad
            has_records || throw(ArgumentError(
                "service deflection: the model has slab TributaryLoads but no cell " *
                "load records, so their dead and live parts cannot be separated"))
        elseif ld isa Asap.GravityLoad
            push!(dead, unfactored_gravity_load(ld))
        elseif ld isa Asap.AreaLoad
            ld.id === :wall_self_weight || push!(slab_area_loads, ld)
        elseif ld isa Asap.LineLoad && (ld.id === FIRE_COATING_LOAD_ID || ld.id === :cladding)
            continue
        elseif ld isa Asap.LineLoad && ld.id === :vault_thrust
            n_thrust += 1
        elseif ld isa Asap.NodeForce && (ld.id === DROP_PANEL_LOAD_ID || ld.id === :p_delta)
            continue
        else
            throw(ArgumentError(
                "service deflection: no unfactored dead/live split is known for a " *
                "$(nameof(typeof(ld))) with id :$(ld.id) on the model"))
        end
    end

    if !isempty(slab_area_loads)
        eligible = [slab for slab in struc.slabs
                    if !isempty(slab.cell_indices) &&
                       struc.cells[first(slab.cell_indices)].floor_type != :grade]
        length(eligible) == length(slab_area_loads) || throw(ArgumentError(
            "service deflection: $(length(slab_area_loads)) slab AreaLoads for " *
            "$(length(eligible)) loaded slabs; cannot match pressures to slabs"))
        for (slab, al) in zip(eligible, slab_area_loads)
            cell0 = struc.cells[first(slab.cell_indices)]
            push!(dead, _area_load_at(al, uconvert(u"Pa", cell0.sdl + cell0.self_weight)))
            push!(live, _area_load_at(al, uconvert(u"Pa", cell0.live_load)))
        end
    end

    if n_thrust > 0
        for (bucket, combo) in ((dead, LoadCombination(name = :service_dead, D = 1.0, L = 0.0)),
                                (live, LoadCombination(name = :service_live, D = 0.0, L = 1.0)))
            p = DesignParameters(load_combinations = [combo])
            specs = EdgeLineLoadSpec[]
            for slab in struc.slabs
                append!(specs, slab_edge_line_loads(struc, slab, p))
            end
            length(specs) == n_thrust || throw(ArgumentError(
                "service deflection: $(length(specs)) vault-thrust specs for $(n_thrust) " *
                "vault-thrust loads on the model"))
            for spec in specs
                push_asap_loads!(bucket, model.frame_elements[spec.edge_idx], spec)
            end
        end
    end

    for (ci, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        p_S = uconvert(u"Pa", cell.sdl)
        d_rec = get(struc.cell_dead_loads, ci, Asap.TributaryLoad[])
        l_rec = get(struc.cell_live_loads, ci, Asap.TributaryLoad[])
        all_rec = get(struc.cell_tributary_loads, ci, Asap.TributaryLoad[])
        recs = !isempty(d_rec) || !isempty(l_rec) ? d_rec : all_rec
        foreach(ld -> push!(sdl, _tributary_at(ld, p_S)), recs)
    end
    if !isempty(slab_area_loads)
        eligible = [slab for slab in struc.slabs
                    if !isempty(slab.cell_indices) &&
                       struc.cells[first(slab.cell_indices)].floor_type != :grade]
        if length(eligible) == length(slab_area_loads)
            for (slab, al) in zip(eligible, slab_area_loads)
                cell0 = struc.cells[first(slab.cell_indices)]
                push!(sdl, _area_load_at(al, uconvert(u"Pa", cell0.sdl)))
            end
        end
    end

    append!(dead, unfactored_fire_coating_loads(model))
    append!(dead, unfactored_drop_panel_loads(struc))
    append!(dead, unfactored_cladding_loads(struc, model.frame_elements))
    _append_service_wall_weight!(dead, model)
    return dead, live, sdl
end

"""
    _service_load_deflections(struc, idxs) -> (δ_LL, δ_total)

Chord offset (m) of each frame element in `idxs`, measured from the straight
line through the supports of its span:
  - `δ_LL`:    live load (L/360)
  - `δ_total`: superimposed dead plus live (L/240)

Supports and the span length are [`assign_framing_levels!`](@ref): a column,
a wall, a `:support` vertex, or a beam line of a lower level. A cantilever is
the tip movement relative to its support.
"""
function _service_load_deflections(struc::BuildingStructure, idxs;
                                   resolution::Int = _SERVICE_DEFLECTION_STATIONS)
    el_ll, el_tot, _ = _relative_service_deflection(struc, idxs; resolution = resolution)
    return el_ll, el_tot
end

"""Station (m) of point `p` along the polyline `xy` with cumulative length `cum`."""
function _project_station(p::NTuple{3, Float64}, xy, cum)
    best_s = 0.0
    best_d = Inf
    for k in 1:(length(xy) - 1)
        a, b = xy[k], xy[k + 1]
        d = b .- a
        L2 = d[1]^2 + d[2]^2 + d[3]^2
        L2 < 1e-18 && continue
        t = clamp(((p[1] - a[1]) * d[1] + (p[2] - a[2]) * d[2] + (p[3] - a[3]) * d[3]) / L2,
                   0.0, 1.0)
        q = a .+ t .* d
        dist = (p[1] - q[1])^2 + (p[2] - q[2])^2 + (p[3] - q[3])^2
        if dist < best_d
            best_d = dist
            best_s = cum[k] + t * (cum[k + 1] - cum[k])
        end
    end
    return best_s
end

"""`(station, uz)` of one element's deflection profile, `uz` positive upward."""
function _element_station_samples(el, profile, xy, cum)
    n = length(profile)
    n == 0 && return Tuple{Float64, Float64}[]
    function xyz(node)
        p = node.position
        (ustrip(u"m", p[1]), ustrip(u"m", p[2]), ustrip(u"m", p[3]))
    end
    s1 = _project_station(xyz(el.nodeStart), xy, cum)
    s2 = _project_station(xyz(el.nodeEnd), xy, cum)
    n == 1 && return [(s1, profile[1])]
    return Tuple{Float64, Float64}[(s1 + (s2 - s1) * (i - 1) / (n - 1), profile[i])
                                   for i in 1:n]
end

_interp_station(samples, s) = begin
    isempty(samples) && return 0.0
    s <= samples[1][1] && return samples[1][2]
    s >= samples[end][1] && return samples[end][2]
    i = searchsortedlast(first.(samples), s)
    i == length(samples) && return samples[end][2]
    (s0, u0), (s1, u1) = samples[i], samples[i + 1]
    return s1 == s0 ? u1 : u0 + (u1 - u0) * (s - s0) / (s1 - s0)
end

"""
Spans of a line: `(s0, s1, kind)`.

`kind` is `:chord` between two supports, `:tip0` when the free end is `s0`,
or `:tip1` when the free end is `s1`. No support: one chord over the line.
"""
function _deflection_spans(supports, total)
    merged = Float64[]
    for s in sort(supports)
        (isempty(merged) || s - merged[end] > 1e-4) && push!(merged, s)
    end
    spans = Tuple{Float64, Float64, Symbol}[]
    if isempty(merged)
        total > 1e-8 && push!(spans, (0.0, total, :chord))
        return spans
    end
    merged[1] > 1e-4 && push!(spans, (0.0, merged[1], :tip0))
    for k in 1:(length(merged) - 1)
        merged[k + 1] - merged[k] > 1e-4 &&
            push!(spans, (merged[k], merged[k + 1], :chord))
    end
    total - merged[end] > 1e-4 && push!(spans, (merged[end], total, :tip1))
    return spans
end

"""Downward sag (m) of one element's profile relative to the chord through its ends."""
function _profile_sag(profile::Vector{Float64})
    n = length(profile)
    n < 2 && return 0.0
    u0, u1 = profile[1], profile[end]
    δ = 0.0
    for i in 1:n
        t = (i - 1) / (n - 1)
        δ = max(δ, -(profile[i] - (u0 + t * (u1 - u0))))
    end
    return δ
end

"""Largest downward offset (m) of `sel` from the span, and the length the limit uses."""
function _span_offset(kind, s0, s1, sel, line_samples)
    L = s1 - s0
    (L <= 1e-8 || isempty(sel)) && return (0.0, L)
    if kind === :chord
        # IBC 2021 Table 1604.3 footnote i (corpus: ibc-2021, PDF p. 418):
        # l is the length of the member between supports.
        u0 = _interp_station(line_samples, s0)
        u1 = _interp_station(line_samples, s1)
        δ = 0.0
        for (s, uz) in sel
            t = (s - s0) / L
            δ = max(δ, -(uz - (u0 + t * (u1 - u0))))
        end
        return (δ, L)
    end
    # IBC 2021 Table 1604.3 footnote i (corpus: ibc-2021, PDF p. 418):
    # for a cantilever, l is twice the length of the cantilever.
    u_sup = _interp_station(line_samples, kind === :tip0 ? s1 : s0)
    δ = 0.0
    for (_, uz) in sel
        δ = max(δ, -(uz - u_sup))
    end
    return (δ, 2 * L)
end

"""
Live and superimposed-dead-plus-live deflection, relative to each span's supports.

Returns per-element chord offsets (m) and, per beam index, the governing
`(δ / l)` of live and of superimposed dead plus live. `l` is the span between
supports, or twice the cantilever length.

# ENGINEERING JUDGMENT
AISC 360-16 Commentary L2 (corpus: aisc-360-16, PDF p. 535) allows D in the
total-load check to be the dead load applied after nonstructural elements are
attached. That share is taken as the whole `cell.sdl`, self-weight excluded.
Post-attachment load is solved on the section the model holds now, including a
composite section where one is installed.
"""
function _relative_service_deflection(struc::BuildingStructure, idxs;
                                     resolution::Int = _SERVICE_DEFLECTION_STATIONS)
    el_ll = Dict{Int, Float64}()
    el_tot = Dict{Int, Float64}()
    ratios = fill((0.0, 0.0), length(struc.beams))
    model = struc.asap_model
    (model === nothing || isempty(model.frame_elements)) && return el_ll, el_tot, ratios
    assign_framing_levels!(struc)
    _, live, sdl = _service_dead_live_loads(struc)
    wanted = Set{Int}(idxs)
    edge_elements = Dict{Int, Vector{Int}}()
    n_el = length(model.frame_elements)
    for (bi, beam) in enumerate(struc.beams)
        for si in segment_indices(beam)
            e = struc.segments[si].edge_idx
            kids = [i for i in _frame_element_indices(struc, e) if 1 <= i <= n_el]
            edge_elements[e] = kids
            union!(wanted, kids)
        end
    end
    isempty(wanted) && return el_ll, el_tot, ratios
    uL, uS = Asap.solve(model, Vector{Asap.AbstractLoad}[live, sdl], struc.asap_rigid_links)
    byL = Asap.frame_loads_by_element(model, live)
    byS = Asap.frame_loads_by_element(model, sdl)
    profL = Dict{Int, Vector{Float64}}()
    profT = Dict{Int, Vector{Float64}}()
    for i in wanted
        el = model.frame_elements[i]
        pL = Asap.element_deflection_profile(el, uL, get(byL, i, Asap.AbstractLoad[]);
                                            resolution = resolution)
        pS = Asap.element_deflection_profile(el, uS, get(byS, i, Asap.AbstractLoad[]);
                                            resolution = resolution)
        profL[i] = pL
        profT[i] = pL .+ pS
    end

    lines = _constant_level_lines(struc, _frame_lines(struc))
    skel = struc.skeleton
    fixed = beam_support_lookup(struc).fixed
    at = Dict{Int, Vector{Int}}()
    level_of = Vector{Int}(undef, length(lines))
    for (i, ln) in enumerate(lines)
        level_of[i] = struc.beams[ln.beams[1]].level
        for v in ln.verts
            push!(get!(at, v, Int[]), i)
        end
    end
    beam_line = Dict{Int, Int}()
    for (i, ln) in enumerate(lines)
        for bi in ln.beams
            beam_line[bi] = i
        end
    end

    function samples_of(ids, prof, xy, cum)
        out = Tuple{Float64, Float64}[]
        for i in ids
            haskey(prof, i) || continue
            append!(out, _element_station_samples(model.frame_elements[i], prof[i], xy, cum))
        end
        sort!(out; by = first)
        return out
    end

    seen_el = Set{Int}()
    for (li, ln) in enumerate(lines)
        cum, xy = _line_stations(skel, ln.verts)
        total = cum[end]
        total > 1e-8 || continue
        sup = _line_support_stations(ln, li, lines, at, fixed, cum, level_of)
        spans = _deflection_spans(sup, total)
        station = Dict(v => cum[k] for (k, v) in enumerate(ln.verts))
        line_ids = Int[]
        for bi in ln.beams
            for si in segment_indices(struc.beams[bi])
                append!(line_ids, get(edge_elements, struc.segments[si].edge_idx, Int[]))
            end
        end
        lineL = samples_of(line_ids, profL, xy, cum)
        lineT = samples_of(line_ids, profT, xy, cum)
        for bi in ln.beams
            ids = Int[]
            s_lo, s_hi = Inf, -Inf
            chain = _beam_vertex_chain(struc, struc.beams[bi])
            if chain !== nothing
                for v in chain
                    haskey(station, v) || continue
                    s_lo = min(s_lo, station[v])
                    s_hi = max(s_hi, station[v])
                end
            end
            for si in segment_indices(struc.beams[bi])
                append!(ids, get(edge_elements, struc.segments[si].edge_idx, Int[]))
            end
            bL = samples_of(ids, profL, xy, cum)
            bT = samples_of(ids, profT, xy, cum)
            rL, rT = 0.0, 0.0
            for (s0, s1, kind) in spans
                on_beam = s_hi >= s0 - 1e-6 && s_lo <= s1 + 1e-6
                on_beam || continue
                selL = [(s, u) for (s, u) in bL if s0 - 1e-6 <= s <= s1 + 1e-6]
                selT = [(s, u) for (s, u) in bT if s0 - 1e-6 <= s <= s1 + 1e-6]
                δL, LL = _span_offset(kind, s0, s1, selL, lineL)
                δT, LT = _span_offset(kind, s0, s1, selT, lineT)
                LL > 1e-8 && (rL = max(rL, δL / LL))
                LT > 1e-8 && (rT = max(rT, δT / LT))
                for i in ids
                    i in seen_el && continue
                    eL = [(s, u) for (s, u) in samples_of([i], profL, xy, cum)
                          if s0 - 1e-6 <= s <= s1 + 1e-6]
                    eT = [(s, u) for (s, u) in samples_of([i], profT, xy, cum)
                          if s0 - 1e-6 <= s <= s1 + 1e-6]
                    el_ll[i] = max(get(el_ll, i, 0.0), _span_offset(kind, s0, s1, eL, lineL)[1])
                    el_tot[i] = max(get(el_tot, i, 0.0), _span_offset(kind, s0, s1, eT, lineT)[1])
                end
            end
            ratios[bi] = (rL, rT)
            union!(seen_el, ids)
        end
    end
    # A beam the line walk did not place still reports the sag of its own
    # elements. A loaded beam with no measured element is a bug: a zero would
    # skip the check. A measured zero is a piece bent only in hogging, such
    # as a short rib at a solid-head face.
    for (bi, beam) in enumerate(struc.beams)
        rL, rT = ratios[bi]
        (rL > 0 || rT > 0) && continue
        measured = false
        loaded = false
        for si in segment_indices(beam)
            e = struc.segments[si].edge_idx
            for i in get(edge_elements, e, Int[])
                if !isempty(byL[i]) || !isempty(byS[i])
                    loaded = true
                end
                haskey(profL, i) || continue
                Lm = _element_length_m(model.frame_elements[i])
                Lm > 1e-8 || continue
                measured = true
                rL = max(rL, _profile_sag(profL[i]) / Lm)
                rT = max(rT, _profile_sag(profT[i]) / Lm)
            end
        end
        if loaded && !measured
            throw(ArgumentError(
                "beam $bi ($(beam.role), level $(beam.level)) carries service load " *
                "but none of its elements has a deflection profile"))
        end
        ratios[bi] = (rL, rT)
    end
    keep_ll = Dict(i => el_ll[i] for i in idxs if haskey(el_ll, i))
    keep_tot = Dict(i => el_tot[i] for i in idxs if haskey(el_tot, i))
    return keep_ll, keep_tot, ratios
end

"""
    _require_service_deflections(demands, group_ids, limit_set::Bool)

Throw when a deflection limit applies and a beam group has no service
deflection. `MemberDemand` reads `δ = 0` as "skip the check". Once member
self-weight is on the model every beam deflects under dead + live, so
`δ_max_total == 0` means the deflection was never computed.
"""
function _require_service_deflections(demands, group_ids, limit_set::Bool)
    limit_set || return nothing
    for (k, d) in enumerate(demands)
        d.δ_max_total > 0 && continue
        throw(ArgumentError(
            "beam group $(group_ids[k]) has a deflection limit but no service " *
            "deflection (δ_total = 0); the deflection check would be skipped"))
    end
    return nothing
end

"""
    _member_span_bounds(struc, m, seg_lengths) -> Vector{Float64}

Distances (m) from the start of member `m` to its span ends: `0`, each interior
support, and the member length. For a beam the interior supports are
[`beam_interior_supports`](@ref) (columns, walls, `:support` vertices, and
beams that pass through). Other members are one span.
"""
function _member_span_bounds(struc::BuildingStructure, m, seg_lengths; lookup = nothing)
    L = sum(seg_lengths; init = 0.0)
    fr = (m isa Beam && lookup !== nothing) ?
        beam_interior_supports(struc, m; lookup = lookup) : Float64[]
    return [0.0; fr .* L; L]
end


"""
    _fem_to_aci_endmoments(M_start, M_end) -> (M1, M2)

Convert a pair of signed FEM internal end moments to ACI 318-19 / AISC 360-16
end-moment convention `(M1, M2)` with `|M2| ≥ |M1|`.

# FEM convention
The inputs are values of Asap's internal moment diagram at the two ends
(`My[i] = Vy·x − M_start`, `external/Asap/src/Analysis/force_displacement.jl`).
With no load between the ends that diagram is linear. Same signs at both
ends mean no inflection point: **single** curvature. Opposite signs mean an
inflection point: **double** curvature. `segment_end_moment_ratio` (wall
piers) uses the same reading.

# ACI 318-19 / AISC 360-16 convention
`M1/M2 > 0` ⇔ **double** curvature (best case, low Cm),
`M1/M2 < 0` ⇔ **single** curvature (worst case, high Cm).

So same-sign FEM end moments map to a **negative** `M1/M2` ratio, and
opposite-sign FEM end moments map to a **positive** ratio.

`M2` is always returned positive (defines the reference direction);
`M1` carries the relative sign.
"""
function _fem_to_aci_endmoments(M_start::Real, M_end::Real)
    if abs(M_start) >= abs(M_end)
        M2_signed = M_start
        M1_signed = M_end
    else
        M2_signed = M_end
        M1_signed = M_start
    end

    M2 = abs(M2_signed)
    if M2 < 1e-12
        return (0.0, 0.0)
    end

    iszero(M1_signed) && return (0.0, M2)
    same_sign = sign(M2_signed) == sign(M1_signed)
    M1 = same_sign ? -abs(M1_signed) : abs(M1_signed)
    return (M1, M2)
end

"""
    _asap_signed_My_envelopes(el, My) -> (sag, hog)

Asap My sign convention (scripts/runners/check_asap_moment_sign.jl, default
Ψ = π/2). Horizontal beams under downward gravity:
  +x / +y / −y: local y = +global Z, midspan My > 0 (sagging), support My < 0
  −x:           local y = −global Z, midspan My < 0 (sagging), support My > 0
Sagging tensions the underside (bottom fiber = −global Z) and equals
sign(My) × sign(local_y · ê_Z). Hogging is the opposite. When |ly·ê_Z| ≈ 0
the face cannot be classified and both envelopes take |My| (conservative).
"""
function _asap_signed_My_envelopes(el, My)
    ly_z = el.LCS[2][3]
    if abs(ly_z) < 1e-8
        mag = mapreduce(abs, max, My)
        return mag, mag
    end
    s = ly_z > 0 ? 1.0 : -1.0
    sag = 0.0
    hog = 0.0
    for M in My
        sag = max(sag, M * s)
        hog = max(hog, -M * s)
    end
    return sag, hog
end

"""
    _strong_weak_peaks(My, Vy, Mz, Vz) -> (Mu, Vu, Mu_weak, Vu_weak)
    _strong_weak_peaks(f::AbstractVector) -> (Mu, Vu)

Peak strong- and weak-axis forces on one Asap frame element.

Asap pairs `My` with `Vy` (transverse load along local y) and `Mz` with `Vz`
(load along local z); see `accumulate_force!`. A beam's default roll is
`Ψ = π/2`, so local y is vertical and gravity is the `My`/`Vy` pair — the
strong axis, same pairing as [`_asap_signed_My_envelopes`](@ref). `Mz`/`Vz`
is the weak axis. Reading `Vz` as the design shear drops gravity shear.

The 12-vector method reads `element.forces` (local end forces, no member
load). Slots 2 and 8 are `Vy`; slots 6 and 12 are the end moments Asap
integrates into `My`.
"""
function _strong_weak_peaks(My, Vy, Mz, Vz)
    mu = isempty(My) ? 0.0 : mapreduce(abs, max, My)
    vu = isempty(Vy) ? 0.0 : mapreduce(abs, max, Vy)
    mu_w = isempty(Mz) ? 0.0 : mapreduce(abs, max, Mz)
    vu_w = isempty(Vz) ? 0.0 : mapreduce(abs, max, Vz)
    return (Mu = mu, Vu = vu, Mu_weak = mu_w, Vu_weak = vu_w)
end

"""Largest |Vy| and the axial at that station. `Nu` is compression-positive."""
function _concurrent_strong_shear(P, Vy)
    isempty(Vy) && return 0.0, 0.0
    i_at = first(eachindex(Vy))
    vu = abs(Float64(Vy[i_at]))
    for i in eachindex(Vy)
        a = abs(Float64(Vy[i]))
        a > vu || continue
        vu = a
        i_at = i
    end
    # Asap axial is tension-positive. RC shear Nu is compression-positive.
    Nu = checkbounds(Bool, P, i_at) ? -Float64(P[i_at]) : 0.0
    return vu, Nu
end

"""
Drop shear rows another row covers: no more `Vu`, no less compression `Nu`,
and the same `Tu`. Vc rises with compression in ACI 318-11 Eq. (11-4) and
Eq. (11-8), so a covered row never governs a shear constraint.
"""
function _prune_covered_shear(rows::Vector{BeamShearCase})
    kept = BeamShearCase[]
    for (i, r) in enumerate(rows)
        # A higher sagging or hogging moment is its own flexure case. Shear
        # coverage does not drop it.
        covered = any(enumerate(rows)) do (j, o)
            j != i && o.Tu == r.Tu && o.Vu >= r.Vu && o.Nu <= r.Nu &&
                o.Mu_pos >= r.Mu_pos && o.Mu_neg >= r.Mu_neg &&
                (o.Vu > r.Vu || o.Nu < r.Nu || o.Mu_pos > r.Mu_pos ||
                 o.Mu_neg > r.Mu_neg || j < i)
        end
        covered || push!(kept, r)
    end
    return kept
end

function _strong_weak_peaks(f::AbstractVector{<:Real})
    n = length(f)
    mu = 0.0
    vu = 0.0
    n >= 2 && (vu = max(vu, abs(f[2])))
    n >= 8 && (vu = max(vu, abs(f[8])))
    n >= 6 && (mu = max(mu, abs(f[6])))
    n >= 12 && (mu = max(mu, abs(f[12])))
    return (Mu = mu, Vu = vu)
end

"""
Station forces for `el` from a caller-supplied global displacement vector.

Mirrors `Asap.ElementForceAndDisplacement`'s force path (`R * K * u_e` then
`accumulate_force!` for the case loads) without reading `node.displacement`.
Used so pattern-case `u` from `Asap.solve(model, cases)` can be evaluated
without mutating `model.u` (full-load deflections stay on `model.u`).
"""
function _element_forces_from_u(el, u_global::AbstractVector{<:Real}, loads; resolution::Int=200)
    dofs = Asap.etype2DOF[typeof(el)]
    ep = Asap.ElementProps(el)
    L = ep.L
    rng = range(0, L, resolution)
    u_e = u_global[el.globalID]
    Ku = el.K * u_e
    Flocal = el.R * Ku
    @inbounds for i in 1:12
        Flocal[i] *= dofs[i]
    end
    Pstart  = -Flocal[1]
    Vystart =  Flocal[2]
    Mystart =  Flocal[6]
    Vzstart =  Flocal[3]
    Mzstart = -Flocal[5]
    P  = fill(Pstart, resolution)
    My = Vector{Float64}(undef, resolution)
    Vy = fill(Vystart, resolution)
    Mz = Vector{Float64}(undef, resolution)
    Vz = fill(Vzstart, resolution)
    @inbounds for i in 1:resolution
        My[i] = Vystart * rng[i] - Mystart
        Mz[i] = Vzstart * rng[i] - Mzstart
    end
    for load in loads
        Asap.accumulate_force!(load, rng, P, My, Vy, Mz, Vz, ep)
    end
    return (P=P, My=My, Vy=Vy, Mz=Mz, Vz=Vz)
end

"""
Pattern-case (loads, u) pairs for member sizing, or `nothing` if only the
full-load solve applies.

Prefers the cache written by `_solve_with_patterns!`. If that is missing but
dead/live splits exist and `params` still requests patterns, re-solves with
the cached K factorization (ACI 318-11 §13.7.6, corpus: aci-318-11, page 261).
"""
function _pattern_demand_cases(struc::BuildingStructure, params::DesignParameters)
    cached = _get_pattern_solve_cache(struc)
    if cached !== nothing
        # Prefer the cache so callers that omit `params` still envelope
        # patterns — but never reuse a pre-K / pre-GravityLoad `pattern_u`
        # (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261).
        if !_pattern_cache_is_current(struc)
            _refresh_pattern_solve_cache!(struc)
            cached = _get_pattern_solve_cache(struc)
        end
        if cached !== nothing
            cases, u_cases = cached
            n_el = length(struc.asap_model.frame_elements)
            n_el == 0 && return nothing
            return [(u, Asap.get_elemental_loads(loads, n_el)) for (u, loads) in zip(u_cases, cases)]
        end
    end
    use = params.pattern_loading != :none &&
          !isempty(struc.cell_dead_loads) &&
          any(!isempty, values(struc.cell_dead_loads)) &&
          _should_run_patterns(struc, params)
    (use && struc.asap_model.processed) || return nothing
    cases = _generate_pattern_cases(struc)
    length(cases) <= 1 && return nothing
    u_cases = Asap.solve(struc.asap_model, cases, struc.asap_rigid_links)
    n_el = length(struc.asap_model.frame_elements)
    n_el == 0 && return nothing
    return [(u, Asap.get_elemental_loads(loads, n_el)) for (u, loads) in zip(u_cases, cases)]
end

"""
    column_force_envelopes(struc, params; resolution=200) -> Dict{Int, NamedTuple}

Per-column strength envelope from the frame, keyed by column index, with
the same force sources as [`member_group_demands`](@ref) for a column
group: the full-load solve plus the pattern cases of
[`_pattern_demand_cases`](@ref) (ACI 318-11 §13.7.6.3–13.7.6.4, corpus:
aci-318-11, page 261), sampled along each segment.

Entries (N, N·m): `Pu` the largest compression (tension counts as zero),
`Pu_t` the largest tension, `My`/`Mz` the peak moments about the element's
local y and z axes, and signed `(M1y, M2y)`/`(M1z, M2z)` end moments in the
ACI 318-19 convention, each pair from the one case with the largest `|M2|`
on that axis. Local y and z are not tied to the section's strong and weak
axes here; callers check both assignments.
"""
function column_force_envelopes(struc::BuildingStructure, params::DesignParameters;
                                resolution::Int = 200)
    out = Dict{Int, NamedTuple}()
    model = struc.asap_model
    (model === nothing || isempty(model.frame_elements)) && return out
    element_loads = Asap.get_elemental_loads(model)
    cases = _pattern_demand_cases(struc, params)
    for (ci, col) in enumerate(struc.columns)
        Pu = Pu_t = My = Mz = 0.0
        segs = segment_indices(col)
        n_case = cases === nothing ? 1 : 1 + length(cases)
        My_s = zeros(n_case); My_e = zeros(n_case)
        Mz_s = zeros(n_case); Mz_e = zeros(n_case)
        saw = false
        for (sp, seg_idx) in enumerate(segs)
            edge_idx = struc.segments[seg_idx].edge_idx
            edge_idx < 1 && continue
            els = _frame_element_indices(struc, edge_idx)
            for (cp, el_idx) in enumerate(els)
                el = model.frame_elements[el_idx]
                loads = element_loads[el.elementID]
                full = Asap.ElementForceAndDisplacement(el, loads; resolution).forces
                sets = cases === nothing ? (full,) : (full, (begin
                    u, case_map = c
                    ld = el.elementID <= length(case_map) ? case_map[el.elementID] :
                         Asap.AbstractLoad[]
                    _element_forces_from_u(el, u, ld; resolution)
                end for c in cases)...)
                saw = true
                for (k, f) in enumerate(sets)
                    Pu = max(Pu, -minimum(f.P))
                    Pu_t = max(Pu_t, maximum(f.P))
                    My = max(My, maximum(abs, f.My))
                    Mz = max(Mz, maximum(abs, f.Mz))
                    if sp == 1 && cp == 1
                        My_s[k] = f.My[1]; Mz_s[k] = f.Mz[1]
                    end
                    if sp == length(segs) && cp == length(els)
                        My_e[k] = f.My[end]; Mz_e[k] = f.Mz[end]
                    end
                end
            end
        end
        saw || continue
        M1y = M2y = M1z = M2z = 0.0
        for k in 1:n_case
            a1, a2 = _fem_to_aci_endmoments(My_s[k], My_e[k])
            a2 > M2y && ((M1y, M2y) = (a1, a2))
            b1, b2 = _fem_to_aci_endmoments(Mz_s[k], Mz_e[k])
            b2 > M2z && ((M1z, M2z) = (b1, b2))
        end
        out[ci] = (Pu = max(Pu, 0.0), Pu_t = max(Pu_t, 0.0), My = My, Mz = Mz,
                   M1y = M1y, M2y = M2y, M1z = M1z, M2z = M2z)
    end
    return out
end

"""
    member_group_demands(struc; member_edge_group=:beams, resolution=200, params=DesignParameters())

Compute governing demands and geometry for each `MemberGroup` by enveloping ASAP internal
forces across all segments of all members in the group.

Conventions:
- gravity bending (strong axis) demand uses `My`
- weak-axis bending demand uses `Mz`
- shear demand uses `Vy`/`Vz` (mapped to weak/strong)
- beam deflection is the chord offset from the span's supports
  ([`_relative_service_deflection`](@ref))

For columns (`member_edge_group == :columns`), signed end moments are
extracted at the start of the first segment and the end of the last
segment of each member, then converted to ACI 318-19 / AISC 360-16
`(M1, M2)` convention via `_fem_to_aci_endmoments`. The group's
`M1x/M2x/M1y/M2y` are taken from the column with the largest |M2|.
This lets the slenderness path compute `Cm = 0.6 − 0.4·(M1/M2)`
instead of falling back on the conservative `M1 = 0` stand-in.

Beam groups always get service deflections from unfactored live and
superimposed dead ([`_relative_service_deflection`](@ref)), whatever
`params.pattern_loading` is: `δ_max_LL` from live alone and `δ_max_total`
from superimposed dead plus live. Column and strut
groups carry no deflection demand (their checkers have no deflection limit).
`service_deflection = false` skips the service solve and leaves both at 0 (no
check); pass it only when no deflection limit applies.

Pattern cases (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261)
envelope STRENGTH from per-case station forces (signed M+/M− and shears).
The per-DOF abs envelope on `el.forces` is not used as a sizing source.

`L_totals[g]` is the length of the longest member in group `g` (the sum of
that member's segments), not the sum over the group's members.

The checker compares `δ_max / L_total` against the limit. Each beam is cut into
spans at its supports ([`_member_span_bounds`](@ref)); `δ/L` is taken per span
with that span's length, and the group's governing ratio `r` is returned as
`δ_max = r · L_total`. A node where a beam only carries another beam is not a
support, so the span is not shortened there.

`shell_demands` maps a beam index to its [`ShellBeamDemand`](@ref). Each beam
group's sagging moment, hogging moment, and strong-axis shear become the larger
of the frame-model value and the shell value. The shell never lowers a demand.
Deflection here is the frame model's alone. Story-shell deflection is a
separate per-span check and never enters these demands.

`case_rows`, when given for columns, is filled with one vector per returned
group: a [`ColumnCaseRow`](@ref) for each member and pattern case, with that
case's axial force and moments together. The group demand pairs the largest
axial force of any case with the largest moment of any case, which does not
bound a reinforced concrete section below its balanced point.

Returns `(group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)`.
"""
function member_group_demands(struc::BuildingStructure;
    member_edge_group::Union{Symbol, AbstractVector{Symbol}, Tuple{Vararg{Symbol}}}=:beams,
    resolution::Int=200,
    params::DesignParameters=DesignParameters(),
    shell_demands::Union{Nothing, AbstractDict{Int, ShellBeamDemand}}=nothing,
    case_rows::Union{Nothing, Vector{Vector{ColumnCaseRow}}}=nothing,
    beam_shear_cases::Union{Nothing, Vector{Vector{BeamShearCase}}}=nothing,
    service_deflection::Bool=true)
    isempty(struc.asap_model.frame_elements) && throw(ArgumentError("ASAP model is empty. Call `to_asap!(struc)` before sizing."))
    stale = Asap.stale_frame_elements(struc.asap_model)
    isempty(stale) || throw(ArgumentError(
        "member demands: $(length(stale)) frame elements (first $(first(stale))) carry " *
        "stiffness from an earlier section. Rebuild the model after installing " *
        "sections (`update_analysis!(struc, :stiffness)`) before reading its forces."))

    skel = struc.skeleton
    groups = member_edge_group isa Symbol ? (member_edge_group,) : member_edge_group
    beam_edge_ids = Set{Int}()
    for g in groups
        union!(beam_edge_ids, get(skel.groups_edges, g, Int[]))
    end

    member_type = if member_edge_group === :columns || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :columns in member_edge_group)
        :columns
    elseif member_edge_group === :struts || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :struts in member_edge_group)
        :struts
    else
        :beams
    end
    member_array = member_type == :columns ? struc.columns :
                   member_type == :struts ? struc.struts : struc.beams

    # Always rebuild — groups are member-type-specific, and the shared dict
    # may hold stale groups from a previous call with a different member type.
    build_member_groups!(struc; member_type=member_type)

    all_group_ids = sort(collect(keys(struc.member_groups)))
    n_groups = length(all_group_ids)

    # Use lazy-cached element-to-loads map (avoids O(n_loads) rebuild per call)
    element_loads = Asap.get_elemental_loads(struc.asap_model)

    # Unshored composite: dead load on the steel inertia, each live pattern
    # on the composite inertia (AISC 360-22 Commentary §I3.1b, corpus:
    # aisc-360-22, PDF p. 500). Built after the stage so the steel dead load
    # has been sampled. Nothing when the mesh is absent or the beam is shored.
    staged = member_type === :beams ? _unshored_stage!(struc; resolution = resolution) : nothing
    split_patterns = _unshored_pattern_forces(struc; resolution = resolution)
    # Pattern cases (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11,
    # page 261): per-case station forces, not the per-DOF abs envelope on
    # el.forces. Skipped when the unshored split above already has a case
    # per pattern. `nothing` ⇒ full-load only.
    pattern_cases = split_patterns === nothing ?
        _pattern_demand_cases(struc, params) : nothing
    if split_patterns === nothing
        split_patterns = _unshored_pattern_forces(struc; resolution = resolution)
    end
    n_pat = if split_patterns !== nothing
        length(split_patterns)
    elseif pattern_cases === nothing
        1
    else
        length(pattern_cases)
    end

    # Signed end moments are the column curvature for Eq. A-8-4. Beams and
    # struts carry load between their supports, so they use §8.2.1(b)
    # (Cm = 1.0) instead of that ratio. AISC 360-16 App. 8 §8.2.1
    # (corpus: aisc-360-16, PDF page 306).
    extract_end_moments = member_type === :columns
    case_rows === nothing || extract_end_moments || throw(ArgumentError(
        "case_rows are per-case column demands; member_edge_group must be :columns"))
    beam_shear_cases === nothing || member_type === :beams || throw(ArgumentError(
        "beam_shear_cases are per-case beam shears; member_edge_group must be beams"))
    par_rows = case_rows === nothing ? nothing : [ColumnCaseRow[] for _ in 1:n_groups]
    par_shear = beam_shear_cases === nothing ? nothing :
        [BeamShearCase[] for _ in 1:n_groups]

    # Preallocated per-group parallel storage
    par_has  = Vector{Bool}(undef, n_groups)
    par_Pu_c = Vector{Float64}(undef, n_groups)
    par_Pu_t = Vector{Float64}(undef, n_groups)
    par_Mux  = Vector{Float64}(undef, n_groups)
    par_Mux_pos = Vector{Float64}(undef, n_groups)
    par_Mux_neg = Vector{Float64}(undef, n_groups)
    par_Muy  = Vector{Float64}(undef, n_groups)
    par_Vus  = Vector{Float64}(undef, n_groups)
    par_Vuw  = Vector{Float64}(undef, n_groups)
    par_Ir   = Vector{Float64}(undef, n_groups)
    par_L    = Vector{Float64}(undef, n_groups)
    par_Lb   = Vector{Float64}(undef, n_groups)
    par_Cb   = Vector{Float64}(undef, n_groups)
    par_Kx   = Vector{Float64}(undef, n_groups)
    par_Ky   = Vector{Float64}(undef, n_groups)
    # Signed (M1, M2) per group, ACI 318-19 sign convention. Selected from the
    # member with the largest |M2| in each axis. Defaulted to (0,0) when no
    # column member is present (e.g., beam/strut groups).
    par_M1x = zeros(Float64, n_groups); par_M2x = zeros(Float64, n_groups)
    par_M1y = zeros(Float64, n_groups); par_M2y = zeros(Float64, n_groups)

    Threads.@threads for g in 1:n_groups
        gid = all_group_ids[g]
        mg = struc.member_groups[gid]

        # Group envelope: max |P| paired with max |M| (not a concurrent case).
        # CONSERVATIVE under gravity-only. Pu_t and Mux_neg are stored on the
        # demand and forwarded by the steel sizers into the existing H1 check
        # (AISC 360-16 §H1.1 page 133, §H1.2 page 134 — corpus: aisc-360-16).
        Pu_comp = 0.0; Pu_tens = 0.0
        Mux = 0.0; Mux_pos = 0.0; Mux_neg = 0.0; Muy = 0.0
        Vu_strong = 0.0; Vu_weak = 0.0
        L_total = 0.0; Lb_gov = 0.0; Cb_gov = Inf
        Kx_gov = 0.0; Ky_gov = 0.0
        has_any = false
        I_ref = 0.0

        # End-moment selection (column groups only). M1 and M2 come from the
        # same pattern case — the case with the largest |M2| on that axis —
        # so Cm is not mixed across non-concurrent load patterns
        # (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261).
        best_M2x = 0.0; best_M1x = 0.0
        best_M2y = 0.0; best_M1y = 0.0

        for m_idx in mg.member_indices
            m = member_array[m_idx]
            Kx_gov = max(Kx_gov, m.base.Kx)
            Ky_gov = max(Ky_gov, m.base.Ky)
            L_member = 0.0

            seg_list = segment_indices(m)
            n_segs = length(seg_list)

            # Per-case end-moment scratch (FEM internal-moment convention).
            # Walked in segment order: start = f.M[1] of first segment, end =
            # f.M[end] of last segment, both from the same pattern case.
            case_My_s = zeros(Float64, n_pat); case_My_e = zeros(Float64, n_pat)
            case_Mz_s = zeros(Float64, n_pat); case_Mz_e = zeros(Float64, n_pat)
            saw_first_seg = false; saw_last_seg = false
            # Per-case compression and moment peaks for `case_rows`.
            case_Pc = zeros(Float64, n_pat)
            case_Mx = zeros(Float64, n_pat); case_My = zeros(Float64, n_pat)
            # Per-case shear for `beam_shear_cases`. An unshored composite
            # diagram is one more case past n_pat. -1 marks a case not seen.
            n_shear = n_pat + (staged === nothing ? 0 : 1)
            case_Vu = fill(-1.0, n_shear)
            case_Nu = zeros(Float64, n_shear)
            case_Mu_pos = zeros(Float64, n_shear)
            case_Mu_neg = zeros(Float64, n_shear)

            for (seg_pos, seg_idx) in enumerate(seg_list)
                seg = struc.segments[seg_idx]
                edge_idx = seg.edge_idx
                edge_idx in beam_edge_ids || continue

                has_any = true
                len_val = to_meters(seg.L)
                lb_val  = to_meters(seg.Lb)
                L_member += len_val
                Lb_gov = max(Lb_gov, lb_val)
                Cb_gov = min(Cb_gov, seg.Cb)

                frame_idxs = _frame_element_indices(struc, edge_idx)
                for (child_pos, el_idx) in enumerate(frame_idxs)
                el = struc.asap_model.frame_elements[el_idx]
                el_loads = element_loads[el.elementID]

                fd = Asap.ElementForceAndDisplacement(el, el_loads; resolution=resolution)

                force_sets = if split_patterns !== nothing
                    ntuple(i -> begin
                        f = get(split_patterns[i], el.elementID, nothing)
                        f === nothing ? fd.forces : f
                    end, length(split_patterns))
                elseif pattern_cases === nothing
                    (fd.forces,)
                else
                    ntuple(i -> begin
                        u_case, case_map = pattern_cases[i]
                        loads_i = el.elementID <= length(case_map) ? case_map[el.elementID] :
                            Asap.AbstractLoad[]
                        _element_forces_from_u(el, u_case, loads_i; resolution=resolution)
                    end, length(pattern_cases))
                end
                if staged !== nothing && haskey(staged.forces, el.elementID)
                    force_sets = (force_sets..., staged.forces[el.elementID])
                end

                for (ci, f) in enumerate(force_sets)
                    min_P = minimum(f.P); max_P = maximum(f.P)
                    if min_P < 0; Pu_comp = max(Pu_comp, abs(min_P)); end
                    if max_P > 0; Pu_tens = max(Pu_tens, max_P); end

                    peaks = _strong_weak_peaks(f.My, f.Vy, f.Mz, f.Vz)
                    Mux = max(Mux, peaks.Mu)
                    sag, hog = _asap_signed_My_envelopes(el, f.My)
                    if member_type === :beams
                        Mux_pos = max(Mux_pos, sag)
                        Mux_neg = max(Mux_neg, hog)
                        case_Mu_pos[ci] = max(case_Mu_pos[ci], sag)
                        case_Mu_neg[ci] = max(case_Mu_neg[ci], hog)
                    end
                    Vu_strong = max(Vu_strong, peaks.Vu)
                    if par_shear !== nothing && member_type === :beams
                        vu_i, Nu_i = _concurrent_strong_shear(f.P, f.Vy)
                        if vu_i > case_Vu[ci]
                            case_Vu[ci] = vu_i
                            case_Nu[ci] = Nu_i
                        end
                    end
                    Muy = max(Muy, peaks.Mu_weak)
                    Vu_weak = max(Vu_weak, peaks.Vu_weak)

                    if extract_end_moments && ci <= n_pat
                        case_Pc[ci] = max(case_Pc[ci], -min_P)
                        case_Mx[ci] = max(case_Mx[ci], peaks.Mu)
                        case_My[ci] = max(case_My[ci], peaks.Mu_weak)
                        if seg_pos == 1 && child_pos == 1
                            case_My_s[ci] = Float64(f.My[1])
                            case_Mz_s[ci] = Float64(f.Mz[1])
                            saw_first_seg = true
                        end
                        if seg_pos == n_segs && child_pos == length(frame_idxs)
                            case_My_e[ci] = Float64(f.My[end])
                            case_Mz_e[ci] = Float64(f.Mz[end])
                            saw_last_seg = true
                        end
                    end
                end

                I_current = ustrip(u"m^4", el.section.Ix)
                I_ref = max(I_ref, I_current)
                end
            end
            # Every member in the group gets the same section, so the group is
            # checked at its longest member (AISC 360-16 §E2 Lc = K·L; F2.2 Lb).
            L_total = max(L_total, L_member)

            if extract_end_moments && saw_first_seg && saw_last_seg
                for ci in 1:n_pat
                    M1x_m, M2x_m = _fem_to_aci_endmoments(case_My_s[ci], case_My_e[ci])
                    M1y_m, M2y_m = _fem_to_aci_endmoments(case_Mz_s[ci], case_Mz_e[ci])
                    if M2x_m > best_M2x
                        best_M2x = M2x_m; best_M1x = M1x_m
                    end
                    if M2y_m > best_M2y
                        best_M2y = M2y_m; best_M1y = M1y_m
                    end
                    par_rows === nothing || push!(par_rows[g], ColumnCaseRow(
                        case_Pc[ci], case_Mx[ci], case_My[ci], M1x_m, M2x_m, M1y_m, M2y_m))
                end
            elseif par_rows !== nothing && L_member > 0
                # No end moments for Cm: the case peaks stand in for M2 with
                # M1 = 0, as in the group envelope.
                for ci in 1:n_pat
                    push!(par_rows[g], ColumnCaseRow(case_Pc[ci], case_Mx[ci], case_My[ci],
                                                     0.0, case_Mx[ci], 0.0, case_My[ci]))
                end
            end
            if par_shear !== nothing && member_type === :beams
                for ci in eachindex(case_Vu)
                    case_Vu[ci] < 0 && continue
                    push!(par_shear[g], BeamShearCase(case_Vu[ci], case_Nu[ci], 0.0,
                                                      case_Mu_pos[ci], case_Mu_neg[ci]))
                end
            end
        end

        par_has[g]  = has_any
        par_Pu_c[g] = Pu_comp; par_Pu_t[g] = Pu_tens
        par_Mux[g]  = Mux;     par_Muy[g]  = Muy
        par_Mux_pos[g] = member_type === :beams ? Mux_pos : Mux
        par_Mux_neg[g] = member_type === :beams ? Mux_neg : Mux
        par_Vus[g]  = Vu_strong; par_Vuw[g] = Vu_weak
        par_Ir[g]   = I_ref
        par_L[g]    = L_total; par_Lb[g]   = Lb_gov
        par_Cb[g]   = Cb_gov;  par_Kx[g]   = Kx_gov; par_Ky[g] = Ky_gov
        par_M1x[g] = best_M1x; par_M2x[g] = best_M2x
        par_M1y[g] = best_M1y; par_M2y[g] = best_M2y
    end

    if shell_demands !== nothing && !isempty(shell_demands)
        member_type === :beams || throw(ArgumentError("shell demands apply to beams only"))
        for g in 1:n_groups
            par_has[g] || continue
            for m_idx in struc.member_groups[all_group_ids[g]].member_indices
                d = get(shell_demands, m_idx, nothing)
                d === nothing && continue
                par_Mux_pos[g] = max(par_Mux_pos[g], d.Mu_pos)
                par_Mux_neg[g] = max(par_Mux_neg[g], d.Mu_neg)
                par_Mux[g] = max(par_Mux[g], d.Mu_pos, d.Mu_neg)
                par_Vus[g] = max(par_Vus[g], d.Vu)
            end
            # Shell demands have no axial. A shear they raise above the frame
            # cases is one row with Nu = 0, so it is not credited with frame
            # compression.
            if par_shear !== nothing
                peak = isempty(par_shear[g]) ? 0.0 : maximum(c.Vu for c in par_shear[g])
                par_Vus[g] > peak + 1.0 &&
                    push!(par_shear[g], BeamShearCase(par_Vus[g], 0.0, 0.0,
                                                      par_Mux_pos[g], par_Mux_neg[g]))
            end
        end
    end
    # ── Service deflection (beams): live, and superimposed dead + live ──
    # Each beam reports its own chord offset over the span between supports.
    par_r_LL    = zeros(Float64, n_groups)
    par_r_total = zeros(Float64, n_groups)
    if member_type === :beams && service_deflection
        el_idxs = Set{Int}()
        for g in 1:n_groups
            par_has[g] || continue
            for m_idx in struc.member_groups[all_group_ids[g]].member_indices
                for seg_idx in segment_indices(member_array[m_idx])
                    edge_idx = struc.segments[seg_idx].edge_idx
                    edge_idx in beam_edge_ids || continue
                    union!(el_idxs, _frame_element_indices(struc, edge_idx))
                end
            end
        end
        _, _, ratios = _relative_service_deflection(struc, el_idxs)
        for g in 1:n_groups
            par_has[g] || continue
            r_ll = 0.0
            r_tot = 0.0
            for m_idx in struc.member_groups[all_group_ids[g]].member_indices
                r_ll = max(r_ll, ratios[m_idx][1])
                r_tot = max(r_tot, ratios[m_idx][2])
            end
            par_r_LL[g] = r_ll
            par_r_total[g] = r_tot
        end
    end

    # Sequential filter & renumber indices
    group_ids = UInt64[]
    demands   = StructuralSizer.MemberDemand{Float64, Nothing}[]
    L_totals  = Float64[]
    Lb_govs   = Float64[]
    Cb_govs   = Float64[]
    Kx_govs   = Float64[]
    Ky_govs   = Float64[]

    case_rows === nothing || empty!(case_rows)
    beam_shear_cases === nothing || empty!(beam_shear_cases)
    for g in 1:n_groups
        par_has[g] || continue
        push!(group_ids, all_group_ids[g])
        g_idx = length(group_ids)
        case_rows === nothing || push!(case_rows, par_rows[g])
        beam_shear_cases === nothing ||
            push!(beam_shear_cases, _prune_covered_shear(par_shear[g]))

        # The checker divides by L_total; this returns the governing span ratio.
        # A computed chord offset of zero is a beam that does not sag between
        # its supports. `MemberDemand` reads 0 as "skip", so a computed zero is
        # stored as a negligible sag and the check passes.
        δ_ll_adj    = par_r_LL[g] * par_L[g]
        δ_total_adj = par_r_total[g] * par_L[g]
        if service_deflection && δ_total_adj == 0
            δ_total_adj = 1e-12
        end

        # Column groups carry signed (M1, M2) from the frame analysis.
        # Beams and struts are loaded between supports, so Cm = 1.0
        # (AISC 360-16 App. 8 §8.2.1(b), corpus: aisc-360-16, PDF page 306).
        if extract_end_moments
            d = StructuralSizer.MemberDemand(g_idx;
                Pu_c=par_Pu_c[g], Pu_t=par_Pu_t[g],
                Mux=par_Mux[g], Muy=par_Muy[g],
                M1x=par_M1x[g], M2x=par_M2x[g],
                M1y=par_M1y[g], M2y=par_M2y[g],
                Vu_strong=par_Vus[g], Vu_weak=par_Vuw[g],
                δ_max_LL=δ_ll_adj, δ_max_total=δ_total_adj,
                I_ref=par_Ir[g],
                transverse_load=false)
        else
            d = StructuralSizer.MemberDemand(g_idx;
                Pu_c=par_Pu_c[g], Pu_t=par_Pu_t[g],
                Mux=par_Mux[g],
                Mux_pos=par_Mux_pos[g], Mux_neg=par_Mux_neg[g],
                Muy=par_Muy[g],
                Vu_strong=par_Vus[g], Vu_weak=par_Vuw[g],
                δ_max_LL=δ_ll_adj, δ_max_total=δ_total_adj,
                I_ref=par_Ir[g],
                transverse_load=true)
        end

        push!(demands, d)
        push!(L_totals, par_L[g])
        push!(Lb_govs, par_Lb[g])
        push!(Cb_govs, par_Cb[g])
        push!(Kx_govs, par_Kx[g])
        push!(Ky_govs, par_Ky[g])
    end

    return group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs
end

"""
    size_steel_members!(struc; catalog, material, member_edge_group, ...)

Discrete, simultaneous catalog-based sizing for steel members using a MIP.
Respects `Member.group_id` by solving at the group level.

Uses `AISCChecker` for capacity checks and `StructuralSizer.to_asap_section`
for ASAP model updates.

# Arguments
- `catalog`: Steel section catalog (default: all W shapes)
- `material`: Steel grade (default: A992_Steel)
- `member_edge_group`: Which edge group to size — `:beams`, `:columns`, `:struts` (default: `:beams`)
- `deflection_limit`: L/δ ratio, e.g. `1/360`. `nothing` = strength-only (default: `nothing`)
- `params`: design parameters passed to [`member_group_demands`](@ref) (pattern cases)

Side effects:
- populates/overwrites `struc.member_groups[gid].section`
- populates each `member.section` and `member.volumes`
- updates ASAP element sections for all member segments in `member_edge_group`
"""
function size_steel_members!(
    struc::BuildingStructure;
    catalog=StructuralSizer.all_W(),
    material=StructuralSizer.A992_Steel,
    member_edge_group::Symbol=:beams,
    max_depth=Inf * u"m",
    n_max_sections::Integer=0,
    solver::Symbol=:auto,
    resolution::Int=200,
    reanalyze::Bool=true,
    gravity_factor::Quantity=GRAVITY,
    deflection_limit::Union{Nothing, Real}=nothing,  # e.g., 1/360
    params::DesignParameters=DesignParameters(),
    skel = struc.skeleton,
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[])))
    
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group,
                             resolution=resolution, params=params,
                             service_deflection=deflection_limit !== nothing)
    member_edge_group === :beams &&
        _require_service_deflections(demands, group_ids, deflection_limit !== nothing)

    # Determine member array from edge group name (must match member_group_demands logic)
    member_array = if member_edge_group === :columns || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :columns in member_edge_group)
        struc.columns
    elseif member_edge_group === :struts || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :struts in member_edge_group)
        struc.struts
    else
        struc.beams
    end

    # Convert to SteelMemberGeometry objects for new API
    geometries = [StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)
                  for (L, Lb, Cb, Kx, Ky) in zip(L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)]
    
    # Create AISC checker with design constraints
    checker = StructuralSizer.AISCChecker(;
        max_depth=max_depth,
        deflection_limit=deflection_limit,
    )
    
    # Choose solver: binary search (fast, per-group optimal) when there are no
    # shared-section constraints; MIP when n_max_sections is active.
    if n_max_sections > 0
        result = StructuralSizer.optimize_discrete(
            checker, demands, geometries, catalog, material;
            n_max_sections=n_max_sections,
            optimizer=solver,
        )
        solver_name = "MIP"
    else
        result = StructuralSizer.optimize_binary_search(
            checker, demands, geometries, catalog, material,
        )
        solver_name = "binary search"
    end

    # Apply results to member groups + ASAP elements + individual members
    for (g_idx, gid) in enumerate(group_ids)
        chosen_template = result.sections[g_idx]
        
        # Create a copy with the specific material for this group
        # (Catalog sections usually have material=nothing)
        chosen = copy(chosen_template)
        chosen.material = material

        mg = struc.member_groups[gid]
        mg.section = chosen

        # Build ASAP section once per group
        asap_sec = StructuralSizer.to_asap_section(chosen, material)

        for m_idx in mg.member_indices
            m = member_array[m_idx]  # Index into appropriate member array
            
            # Compute total length and store section/volume on member
            # Ensure L_total has units (skeleton may use plain Float64)
            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(
                _volume_key(material) => StructuralSizer.self_weight_area(chosen) * L_total))

            # Update ASAP elements
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.frame_elements[edge_idx].section = asap_sec
            end
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
    end

    defl_str = isnothing(deflection_limit) ? "none" : "L/$(Int(round(1/deflection_limit)))"
    @info "Sized $(length(group_ids)) steel member groups via $solver_name" n_max_sections=n_max_sections deflection_limit=defl_str
    return struc
end

