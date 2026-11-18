# =============================================================================
# Check-based settle for a cycling beam and column loop
# =============================================================================
#
# A discrete section fixed point need not exist: two stiffnesses can each make
# the sizer pick the other. When the loop returns to a section state it already
# left, each state in that cycle is re-analyzed and checked with the sizer's
# own checker. A state is kept only when every beam group and every column
# group passes that state's demands. Among those, the cheapest is installed.
# Otherwise each group keeps the cheapest section that passed in some state, or
# the costliest section if it passed in none, and that mix is checked the same
# way. Groups that still fail are sized again. A state already checked is not
# installed again.
#
# The story-shell rounds use the same rule at their boundary. The first round
# may free-pick. A later round solves the shell on the sections already in the
# model and resizes only the groups that fail that shell.

"""Beam and column sections, in member order, at the end of one sizing pass."""
struct _MemberState
    beams::Vector{Any}
    columns::Vector{Any}
end

_member_state(struc) = _MemberState([_story_beam_section(struc, b) for b in struc.beams],
                                    [section(c) for c in struc.columns])

function _member_state_identical(a::_MemberState, b::_MemberState)
    length(a.beams) == length(b.beams) || return false
    length(a.columns) == length(b.columns) || return false
    return all(_sections_identical(x, y) for (x, y) in zip(a.beams, b.beams)) &&
           all(_sections_identical(x, y) for (x, y) in zip(a.columns, b.columns))
end

"""
    _infeasible_group_indices(err) -> Union{Nothing, Vector{Int}}

1-based group positions named by a discrete sizer's "no feasible sections"
error. `nothing` when `err` is some other error.
"""
function _infeasible_group_indices(err)
    err isa ArgumentError || return nothing
    startswith(err.msg, "No feasible sections for group") || return nothing
    head = split(err.msg, ":"; limit = 2)[1]
    nums = [parse(Int, m.captures[1]) for m in eachmatch(r"(\d+)", head)]
    return isempty(nums) ? nothing : nums
end

"""
`(section, passed)` for one group. A section that passed in any state is
eligible, and the cheapest of those wins. A group that passed in none keeps
the costliest of its sections.
"""
function _pick_group_section(choices)
    best_pass, best_pass_cost = nothing, Inf
    best_any, best_any_cost = nothing, -Inf
    for (sec, passed, cost) in choices
        if passed && cost < best_pass_cost
            best_pass, best_pass_cost = sec, cost
        end
        if cost >= best_any_cost
            best_any, best_any_cost = sec, cost
        end
    end
    return (section = best_pass === nothing ? best_any : best_pass,
            passed = best_pass !== nothing)
end

_section_cost(opts, sec) = sec === nothing ? Inf : ustrip(_section_objective(opts, sec))

_member_length_m(struc, m) =
    sum(to_meters(struc.segments[i].L) for i in segment_indices(m); init = 0.0)

"""Options whose checker this settle can run on one installed section."""
function _settle_checkable(opts)
    discrete = opts.sizing_strategy === :discrete && opts.materials === nothing &&
               opts.n_max_sections == 0
    if opts isa StructuralSizer.ConcreteBeamOptions ||
       opts isa StructuralSizer.ConcreteColumnOptions
        return discrete
    elseif opts isa StructuralSizer.SteelBeamOptions
        return discrete && !opts.composite
    elseif opts isa StructuralSizer.SteelColumnOptions
        return discrete
    end
    return false
end

function _edge_ids(struc, symbols)
    ids = Set{Int}()
    for g in symbols
        union!(ids, get(struc.skeleton.groups_edges, g, Int[]))
    end
    return ids
end

"""Put `sec` on `member` and on the Asap elements of its edges in `edge_ids`."""
function _install_member_section!(struc, member, sec, edge_ids, mat, I_factor, rebar)
    set_section!(member, sec)
    set_volumes!(member, member_material_volumes(sec, _member_length_m(struc, member) * u"m",
                                                 mat; rebar = rebar))
    asap_sec = mat isa StructuralSizer.Concrete ?
        StructuralSizer.to_asap_section(sec, mat; I_factor = I_factor) :
        StructuralSizer.to_asap_section(sec, mat)
    for si in segment_indices(member)
        edge_idx = struc.segments[si].edge_idx
        edge_idx in edge_ids || continue
        struc.asap_model.frame_elements[edge_idx].section = asap_sec
    end
    if member isa Column &&
       (sec isa StructuralSizer.RCColumnSection || sec isa StructuralSizer.RCCircularSection)
        box = StructuralSizer.bounding_box(sec)
        member.c1 = box.width
        member.c2 = box.depth
    end
    return member
end

"""Install the sections in `state` and rebuild stiffness."""
function _install_state!(struc, state::_MemberState, beam_opts, column_opts, params)
    beam_edges = _edge_ids(struc, BEAM_GROUP_SYMBOLS)
    column_edges = _edge_ids(struc, (:columns,))
    opts_of = _beam_opts_by_group(struc, beam_opts)
    for (m, sec) in zip(struc.beams, state.beams)
        sec === nothing && continue
        opts = get(opts_of, group_id(m), beam_opts)
        rebar = opts isa StructuralSizer.ConcreteBeamOptions ? opts.rebar_material : nothing
        _install_member_section!(struc, m, sec, beam_edges, opts.material,
                                 params.beam_I_factor, rebar)
    end
    rebar_c = column_opts isa StructuralSizer.ConcreteColumnOptions ?
        column_opts.rebar_material : nothing
    mat_c = column_opts.material
    for (m, sec) in zip(struc.columns, state.columns)
        sec === nothing && continue
        _install_member_section!(struc, m, sec, column_edges, mat_c,
                                 params.column_I_factor, rebar_c)
    end
    _sync_fire_coating_loads!(struc, params)
    _reanalyze_after_section_change!(struc)
    return struc
end

"""
Positions in `pending` whose pinned section the sizer rejects.

`check(pending)` sizes exactly those groups, in that order, each group pinned
to its installed section. A "no feasible sections" error names positions in
the vector `check` was given. The function argument comes first so a `do`
block is `check`.
"""
function _pinned_failures(check, pending::Vector{Int})
    left = copy(pending)
    failed = Int[]
    guard = length(pending) + 1
    while !isempty(left) && guard > 0
        guard -= 1
        try
            check(left)
            return failed
        catch err
            idxs = _infeasible_group_indices(err)
            idxs === nothing && rethrow()
            all(i -> 1 <= i <= length(left), idxs) || rethrow()
            append!(failed, (left[i] for i in idxs))
            drop = Set(idxs)
            left = [g for (k, g) in enumerate(left) if k ∉ drop]
        end
    end
    error("pinned section check made no progress")
end

_catalog_of(sections) = mapreduce(typeof, typejoin, sections)[s for s in sections]

_first_section(struc, members, gid) =
    section(members[struc.member_groups[gid].member_indices[1]])

"""
Pass/fail and the checker's explanation per beam group, for the sections
currently installed. `nothing` when an option set cannot be checked this way.
"""
function _beam_group_report(struc, beam_opts; shell_demands, shell_spans, resolution::Int)
    opts_of = _beam_opts_by_group(struc, beam_opts)
    all(_settle_checkable, values(opts_of)) || return nothing
    needs_defl = any(values(opts_of)) do opts
        opts isa StructuralSizer.SteelBeamOptions &&
            (opts.deflection_limit !== nothing || opts.total_deflection_limit !== nothing)
    end
    group_ids, demands, L_totals, Lb, Cb, Kx, Ky =
        _beam_group_demands(struc, nothing; resolution, shell_demands,
                            service_deflection = needs_defl)
    passed = Dict{UInt64, Bool}()
    explanations = Dict{UInt64, Any}()
    hogging = Dict{UInt64, Float64}(gid => Float64(demands[i].Mux_neg)
                                    for (i, gid) in enumerate(group_ids))
    t_idx = Int[]
    rect = Dict{UInt, Vector{Int}}()
    steel = Dict{UInt, Vector{Int}}()
    for (i, gid) in enumerate(group_ids)
        opts = get(opts_of, gid, beam_opts)
        sec = _first_section(struc, struc.beams, gid)
        if opts isa StructuralSizer.ConcreteBeamOptions && opts.include_flange &&
           sec isa StructuralSizer.RCTBeamSection
            push!(t_idx, i)
        elseif sec === nothing
            passed[gid] = false
        elseif opts isa StructuralSizer.ConcreteBeamOptions
            push!(get!(() -> Int[], rect, objectid(opts)), i)
        else
            push!(get!(() -> Int[], steel, objectid(opts)), i)
        end
    end
    if !isempty(t_idx)
        specs = _compute_flange_params(struc, group_ids)
        spans = _group_shell_spans(struc, group_ids, shell_spans, StructuralSizer.RCShellSpan)
        for i in t_idx
            gid = group_ids[i]
            opts = get(opts_of, gid, beam_opts)
            sec = _first_section(struc, struc.beams, gid)
            d = demands[i]
            js = specs[i] === nothing ? nothing : specs[i].joist_spacing
            span = spans === nothing || isempty(spans[i]) ? nothing : spans[i]
            report = StructuralSizer.check_tbeam_section(
                sec, d.Mux_pos * u"N*m", d.Vu_strong * u"N",
                StructuralSizer.ConcreteMemberGeometry(L_totals[i]), opts;
                Mu_neg = d.Mux_neg * u"N*m",
                Nu = (d.Pu_t > 0 ? -d.Pu_t : d.Pu_c) * u"N",
                joist_spacing = js,
                sustained_live_fraction = opts.sustained_live_fraction,
                shell_span = span)
            passed[gid] = report.passed
            explanations[gid] = report
        end
    end
    spans_r = _group_shell_spans(struc, group_ids, shell_spans, StructuralSizer.RCShellSpan)
    for idxs in values(rect)
        opts = get(opts_of, group_ids[idxs[1]], beam_opts)
        failed = _rectangular_failures(struc, opts, idxs, group_ids, demands, L_totals, spans_r)
        for i in idxs
            passed[group_ids[i]] = i ∉ failed
        end
    end
    spans_s = _group_shell_spans(struc, group_ids, shell_spans, StructuralSizer.SteelShellSpan)
    for idxs in values(steel)
        opts = get(opts_of, group_ids[idxs[1]], beam_opts)
        limit = opts.deflection_limit !== nothing || opts.total_deflection_limit !== nothing
        failed = _steel_beam_failures(struc, opts, idxs, group_ids, demands, L_totals,
                                      Lb, Cb, Kx, Ky, spans_s, limit)
        for i in idxs
            passed[group_ids[i]] = i ∉ failed
        end
    end
    return (passed = passed, explanations = explanations, hogging = hogging)
end

"""Demand-row indices in `idxs` whose rectangular section the checker rejects."""
function _rectangular_failures(struc, opts, idxs, group_ids, demands, L_totals, spans)
    n = length(idxs)
    secs = [_first_section(struc, struc.beams, group_ids[i]) for i in idxs]
    geoms = [StructuralSizer.ConcreteMemberGeometry(L_totals[i]) for i in idxs]
    Mu = [demands[i].Mux_pos * u"N*m" for i in idxs]
    Mu_neg = [demands[i].Mux_neg * u"N*m" for i in idxs]
    Vu = [demands[i].Vu_strong * u"N" for i in idxs]
    Nu = [(demands[i].Pu_t > 0 ? -demands[i].Pu_t : demands[i].Pu_c) * u"N" for i in idxs]
    row_spans = spans === nothing ? nothing : [spans[i] for i in idxs]
    local_failed = _pinned_failures(collect(1:n)) do left
        StructuralSizer.size_beams(
            Mu[left], Vu[left], geoms[left], opts;
            Mu_neg = Mu_neg[left], Nu = Nu[left],
            catalog = _catalog_of(secs[left]),
            feasible = [[k] for k in eachindex(left)],
            shell_spans = row_spans === nothing ? nothing : row_spans[left])
    end
    return Set(idxs[k] for k in local_failed)
end

"""Demand-row indices in `idxs` whose steel section the checker rejects."""
function _steel_beam_failures(struc, opts, idxs, group_ids, demands, L_totals,
                              Lb, Cb, Kx, Ky, spans, limit::Bool)
    rows = [demands[i] for i in idxs]
    _require_service_deflections(rows, [group_ids[i] for i in idxs], limit)
    n = length(idxs)
    secs = [_first_section(struc, struc.beams, group_ids[i]) for i in idxs]
    geoms = [StructuralSizer.SteelMemberGeometry(L_totals[i]; Lb = Lb[i], Cb = Cb[i],
                                                 Kx = Kx[i], Ky = Ky[i]) for i in idxs]
    Mu = [demands[i].Mux for i in idxs]
    Vu = [demands[i].Vu_strong for i in idxs]
    Mu_pos = [demands[i].Mux_pos for i in idxs]
    Mu_neg = [demands[i].Mux_neg for i in idxs]
    Pu = [demands[i].Pu_c * u"N" for i in idxs]
    Pu_t = [demands[i].Pu_t * u"N" for i in idxs]
    δ_ll = [demands[i].δ_max_LL for i in idxs]
    δ_tot = [demands[i].δ_max_total for i in idxs]
    I_ref = [demands[i].I_ref for i in idxs]
    row_spans = spans === nothing ? nothing : [spans[i] for i in idxs]
    local_failed = _pinned_failures(collect(1:n)) do left
        StructuralSizer.size_beams(
            Mu[left], Vu[left], geoms[left], opts;
            Pu = Pu[left], Pu_t = Pu_t[left],
            Mux_pos = Mu_pos[left], Mux_neg = Mu_neg[left],
            δ_max_vec = any(>(0), δ_ll[left]) ? δ_ll[left] : nothing,
            δ_max_total_vec = any(>(0), δ_tot[left]) ? δ_tot[left] : nothing,
            I_ref_vec = any(>(0), I_ref[left]) ? I_ref[left] : nothing,
            catalog = _catalog_of(secs[left]),
            feasible = [[k] for k in eachindex(left)],
            shell_spans = row_spans === nothing ? nothing : row_spans[left])
    end
    return Set(idxs[k] for k in local_failed)
end

"""Pass/fail per column group for the sections currently installed."""
function _column_group_report(struc, opts; resolution::Int)
    _settle_checkable(opts) || return nothing
    isempty(struc.columns) && return Dict{UInt64, Bool}()
    if opts isa StructuralSizer.SteelColumnOptions
        group_ids, demands, L, Lb, Cb, Kx, Ky =
            member_group_demands(struc; member_edge_group = :columns, resolution = resolution,
                                 service_deflection = false)
        n = length(group_ids)
        n == 0 && return Dict{UInt64, Bool}()
        secs = [_first_section(struc, struc.columns, gid) for gid in group_ids]
        geoms = [StructuralSizer.SteelMemberGeometry(L[i]; Lb = Lb[i], Cb = Cb[i],
                                                     Kx = Kx[i], Ky = Ky[i]) for i in 1:n]
        Pu = [demands[i].Pu_c for i in 1:n]
        Pu_t = [demands[i].Pu_t for i in 1:n]
        Mux = [demands[i].Mux for i in 1:n]
        Muy = [demands[i].Muy for i in 1:n]
        have = [i for i in 1:n if secs[i] !== nothing]
        failed = [i for i in 1:n if secs[i] === nothing]
        append!(failed, _pinned_failures(have) do left
            StructuralSizer.size_columns(
                Pu[left], Mux[left], geoms[left], opts;
                Muy = Muy[left], Pu_t = Pu_t[left],
                catalog = _catalog_of(secs[left]),
                feasible = [[k] for k in eachindex(left)])
        end)
        bad = Set(failed)
        return Dict(group_ids[i] => i ∉ bad for i in 1:n)
    end
    case_rows = Vector{ColumnCaseRow}[]
    group_ids, demands, L, Lb, Cb, Kx, Ky =
        member_group_demands(struc; member_edge_group = :columns, resolution = resolution,
                             case_rows = case_rows, service_deflection = false)
    n = length(group_ids)
    n == 0 && return Dict{UInt64, Bool}()
    sets = _rc_column_demand_sets(opts, demands, case_rows)
    secs = [_first_section(struc, struc.columns, gid) for gid in group_ids]
    geoms = [StructuralSizer.ConcreteMemberGeometry(L[i]; Lu = Lb[i], kx = Kx[i], ky = Ky[i])
             for i in 1:n]
    have = [i for i in 1:n if secs[i] !== nothing]
    failed = [i for i in 1:n if secs[i] === nothing]
    append!(failed, _pinned_failures(have) do left
        StructuralSizer.size_columns(
            sets[left], geoms[left], opts;
            catalog = _catalog_of(secs[left]),
            feasible = [[k] for k in eachindex(left)])
    end)
    bad = Set(failed)
    return Dict(group_ids[i] => i ∉ bad for i in 1:n)
end

_all_passed(report) = all(values(report))

"""Index in `costs` of the cheapest entry among `eligible`. `argmin` returns that index, not a position in `eligible`."""
_cheapest_index(costs, eligible) = argmin(i -> costs[i], eligible)

function _state_cost(struc, state::_MemberState, beam_opts, column_opts)
    opts_of = _beam_opts_by_group(struc, beam_opts)
    total = 0.0
    for (m, sec) in zip(struc.beams, state.beams)
        opts = get(opts_of, group_id(m), beam_opts)
        total += _section_cost(opts, sec) * _member_length_m(struc, m)
    end
    for (m, sec) in zip(struc.columns, state.columns)
        total += _section_cost(column_opts, sec) * _member_length_m(struc, m)
    end
    return total
end

"""
One section per group: the cheapest that passed in any state, or the costliest
when none did. Members with no group keep the section of the last state.
"""
function _mixed_state(struc, states, beam_passed, column_passed, beam_opts, column_opts)
    opts_of = _beam_opts_by_group(struc, beam_opts)
    beams = Vector{Any}(undef, length(struc.beams))
    beam_choice = Dict{UInt64, Any}()
    for (mi, m) in enumerate(struc.beams)
        gid = group_id(m)
        if gid === nothing
            beams[mi] = states[end].beams[mi]
            continue
        end
        if !haskey(beam_choice, gid)
            opts = get(opts_of, gid, beam_opts)
            choices = [(states[k].beams[mi],
                        get(beam_passed[k], gid, true),
                        _section_cost(opts, states[k].beams[mi]))
                       for k in eachindex(states)]
            beam_choice[gid] = _pick_group_section(choices).section
        end
        beams[mi] = beam_choice[gid]
    end
    columns = Vector{Any}(undef, length(struc.columns))
    column_choice = Dict{UInt64, Any}()
    for (mi, m) in enumerate(struc.columns)
        gid = group_id(m)
        if gid === nothing
            columns[mi] = states[end].columns[mi]
            continue
        end
        if !haskey(column_choice, gid)
            choices = [(states[k].columns[mi],
                        get(column_passed[k], gid, true),
                        _section_cost(column_opts, states[k].columns[mi]))
                       for k in eachindex(states)]
            column_choice[gid] = _pick_group_section(choices).section
        end
        columns[mi] = column_choice[gid]
    end
    return _MemberState(beams, columns)
end

function _record_beam_checks!(struc, explanations, hogging)
    for m in struc.beams
        gid = group_id(m)
        gid === nothing && continue
        h = get(hogging, gid, nothing)
        h === nothing || (m.Mu_neg_envelope = h)
        expl = get(explanations, gid, nothing)
        expl === nothing && continue
        m.base.check = (section = section(m), explanation = expl)
    end
    return struc
end

_failing_ids(passed) = Set(gid for (gid, ok) in passed if !ok)

"""
Size the beam groups in `failing` for the analysis now on the model, then
size columns. Returns the installed state.
"""
function _resize_failures!(struc, failing, params, beam_opts, column_opts, beam_kwargs;
                           shell_demands, shell_spans)
    if !isempty(failing)
        sized = false
        for pass in _beam_sizing_passes(struc, beam_opts)
            accept = gid -> gid in failing && (pass.accept === nothing || pass.accept(gid))
            any(accept, failing) || continue
            # The next framing level reads the forces from the sections just
            # installed, the same as a multi-pass `size_beams!`.
            sized && _reanalyze_after_section_change!(struc)
            size_beams!(struc, pass.opts; beam_kwargs..., shell_demands, shell_spans,
                        group_filter = accept)
            sized = true
        end
        _sync_fire_coating_loads!(struc, params)
        _reanalyze_after_section_change!(struc)
    end
    size_columns!(struc, column_opts; reanalyze = false, tc = get(beam_kwargs, :tc, nothing),
                  I_factor = params.column_I_factor,
                  gravity_factor = member_self_weight_acceleration(params))
    _harmonize_columns!(struc, params)
    _sync_fire_coating_loads!(struc, params)
    _reanalyze_after_section_change!(struc)
    return _member_state(struc)
end

"""
    _check_settle!(struc, states, ...) -> Bool

`states` is one cycle, without the repeated closing state. Installs a checked
design and returns `true` when every beam and column group passes the analysis
of the sections left on the model.
"""
function _check_settle!(struc, states::Vector{_MemberState}, params, beam_opts, column_opts,
                        beam_kwargs; shell_demands = nothing, shell_spans = nothing, tc = nothing)
    opts_of = _beam_opts_by_group(struc, beam_opts)
    if !_settle_checkable(beam_opts) || !_settle_checkable(column_opts) ||
       !all(_settle_checkable, values(opts_of))
        @info "Check-based settle left the loop unsettled: these options are not checked section by section"
        return false
    end
    home = _member_state(struc)
    beam_passed = Vector{Dict{UInt64, Bool}}()
    beam_expl = Vector{Dict{UInt64, Any}}()
    beam_hog = Vector{Dict{UInt64, Float64}}()
    column_passed = Vector{Dict{UInt64, Bool}}()
    costs = Float64[]
    trace = get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1"
    for (k, state) in enumerate(states)
        _install_state!(struc, state, beam_opts, column_opts, params)
        beams = _beam_group_report(struc, beam_opts; shell_demands, shell_spans, resolution = 200)
        columns = _column_group_report(struc, column_opts; resolution = 200)
        if beams === nothing || columns === nothing
            _install_state!(struc, home, beam_opts, column_opts, params)
            return false
        end
        push!(beam_passed, beams.passed)
        push!(beam_expl, beams.explanations)
        push!(beam_hog, beams.hogging)
        push!(column_passed, columns)
        push!(costs, _state_cost(struc, state, beam_opts, column_opts))
        trace && println("  cycle state $k  cost=$(round(costs[end]; digits=1))  " *
                         "beams $(count(values(beams.passed)))/$(length(beams.passed))  " *
                         "columns $(count(values(columns)))/$(length(columns))")
    end
    full = [k for k in eachindex(states)
            if _all_passed(beam_passed[k]) && _all_passed(column_passed[k])]
    if !isempty(full)
        k = _cheapest_index(costs, full)
        _install_state!(struc, states[k], beam_opts, column_opts, params)
        _record_beam_checks!(struc, beam_expl[k], beam_hog[k])
        @info "Beam and column loop settled on checked cycle state $k of $(length(states))"
        StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                              outcome = "check_settle", state = k, n_states = length(states))
        return true
    end
    mixed = _mixed_state(struc, states, beam_passed, column_passed, beam_opts, column_opts)
    seen = _MemberState[states...]
    failing = Set{UInt64}()
    matched = findfirst(s -> _member_state_identical(mixed, s), seen)
    if matched === nothing
        _install_state!(struc, mixed, beam_opts, column_opts, params)
        beams = _beam_group_report(struc, beam_opts; shell_demands, shell_spans, resolution = 200)
        columns = _column_group_report(struc, column_opts; resolution = 200)
        push!(seen, _member_state(struc))
        if beams !== nothing && columns !== nothing &&
           _all_passed(beams.passed) && _all_passed(columns)
            _record_beam_checks!(struc, beams.explanations, beams.hogging)
            @info "Beam and column loop settled on a checked mix of the cycle"
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                                  outcome = "check_settle_mix")
            return true
        end
        beams !== nothing && (failing = _failing_ids(beams.passed))
    else
        # The mix is a state already checked. Put that state back on the model
        # before resizing the groups that failed in every state.
        matched == length(states) ||
            _install_state!(struc, states[matched], beam_opts, column_opts, params)
        gids = Set{UInt64}()
        for passed in beam_passed
            union!(gids, keys(passed))
        end
        failing = Set(gid for gid in gids
                      if all(p -> !get(p, gid, true), beam_passed))
    end
    for _ in 1:3
        state = _resize_failures!(struc, failing, params, beam_opts, column_opts, beam_kwargs;
                                  shell_demands, shell_spans)
        if any(s -> _member_state_identical(state, s), seen)
            @info "Check-based settle returned to a section state it had already checked"
            return false
        end
        push!(seen, state)
        beams = _beam_group_report(struc, beam_opts; shell_demands, shell_spans, resolution = 200)
        columns = _column_group_report(struc, column_opts; resolution = 200)
        if beams !== nothing && columns !== nothing &&
           _all_passed(beams.passed) && _all_passed(columns)
            _record_beam_checks!(struc, beams.explanations, beams.hogging)
            @info "Beam and column loop settled after resizing the groups that failed the cycle"
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                                  outcome = "check_settle_resized")
            return true
        end
        beams === nothing && return false
        failing = _failing_ids(beams.passed)
        columns === nothing && return false
        _all_passed(columns) || continue
        isempty(failing) && return false
    end
    @info "Check-based settle did not find a design that passes its own analysis"
    return false
end

_beam_sections_identical(a, b) =
    length(a) == length(b) && all(_sections_identical(x, y) for (x, y) in zip(a, b))

"""Put `sections` on the beams and rebuild the frame. Columns stay as they are."""
function _install_beam_sections!(struc, sections, beam_opts, I_factor)
    length(sections) == length(struc.beams) ||
        error("beam section state has a different beam count")
    beam_edges = _edge_ids(struc, BEAM_GROUP_SYMBOLS)
    opts_of = _beam_opts_by_group(struc, beam_opts)
    for (m, sec) in zip(struc.beams, sections)
        sec === nothing && continue
        opts = get(opts_of, group_id(m), beam_opts)
        rebar = opts isa StructuralSizer.ConcreteBeamOptions ? opts.rebar_material : nothing
        _install_member_section!(struc, m, sec, beam_edges, opts.material, I_factor, rebar)
    end
    _reanalyze_after_section_change!(struc)
    return struc
end

"""One section per beam group from a shell cycle. Same rule as [`_mixed_state`](@ref)."""
function _mixed_beams(struc, states, beam_passed, beam_opts)
    opts_of = _beam_opts_by_group(struc, beam_opts)
    out = Vector{Any}(undef, length(struc.beams))
    choice = Dict{UInt64, Any}()
    for (mi, m) in enumerate(struc.beams)
        gid = group_id(m)
        if gid === nothing
            out[mi] = states[end][mi]
            continue
        end
        if !haskey(choice, gid)
            opts = get(opts_of, gid, beam_opts)
            choices = [(states[k][mi], get(beam_passed[k], gid, true),
                        _section_cost(opts, states[k][mi])) for k in eachindex(states)]
            choice[gid] = _pick_group_section(choices).section
        end
        out[mi] = choice[gid]
    end
    return out
end

"""
    _check_shell_settle!(run, states, service_on, regions, pass, service_converged)

`states` is one cycle of beam-section vectors, without the repeated closing
state. Installs each, solves the story shells on those sections, and checks
the beams. Returns the pass result when a state passes, `nothing` when these
options cannot be checked section by section.
"""
function _check_shell_settle!(run, states, service_on, regions, pass, service_converged)
    struc, opts = run.struc, run.opts
    opts_of = _beam_opts_by_group(struc, opts)
    if !_settle_checkable(opts) || !all(_settle_checkable, values(opts_of))
        return nothing
    end
    I_factor = get(run.kwargs, :I_factor, 0.35)
    resolution = get(run.kwargs, :resolution, 200)
    trace = get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1"
    passed = Vector{Dict{UInt64, Bool}}()
    expl = Vector{Dict{UInt64, Any}}()
    hog = Vector{Dict{UInt64, Float64}}()
    solved = []
    costs = Float64[]
    for (k, state) in enumerate(states)
        _install_beam_sections!(struc, state, opts, I_factor)
        fresh = _gather_shell_demands!(run; service_on, regions)
        spans = service_on ? fresh.spans : nothing
        report = _beam_group_report(struc, opts; shell_demands = fresh.demands,
                                    shell_spans = spans, resolution = resolution)
        report === nothing && return nothing
        push!(passed, report.passed)
        push!(expl, report.explanations)
        push!(hog, report.hogging)
        push!(solved, fresh)
        push!(costs, _beams_objective(struc, opts))
        regions_ok = all(<=(run.region_tol), values(fresh.shifts))
        trace && println("  shell state $k  cost=$(round(costs[end]; digits=1))  " *
                         "beams $(count(values(report.passed)))/$(length(report.passed))  " *
                         "regions=$(regions_ok)  service=$(fresh.service_converged)")
    end
    function accept_state(k)
        fresh = solved[k]
        regions_ok = all(<=(run.region_tol), values(fresh.shifts))
        service_ok = !service_on || fresh.service_converged
        return regions_ok && service_ok && _all_passed(passed[k])
    end
    full = [k for k in eachindex(states) if accept_state(k)]
    if !isempty(full)
        k = _cheapest_index(costs, full)
        _install_beam_sections!(struc, states[k], opts, I_factor)
        _record_beam_checks!(struc, expl[k], hog[k])
        fresh = solved[k]
        @info "Story shell settled on checked cycle state $k of $(length(states))"
        return _shell_pass_result(; converged = true, passes = pass,
                                  demands = fresh.demands, spans = fresh.spans,
                                  regions = fresh.regions, service_on,
                                  service_converged = service_converged && fresh.service_converged,
                                  shifts = fresh.shifts)
    end
    mixed = _mixed_beams(struc, states, passed, opts)
    seen = Vector{Vector{Any}}(states)
    failing = Set{UInt64}()
    current = solved[end]
    matched = findfirst(s -> _beam_sections_identical(mixed, s), seen)
    if matched === nothing
        _install_beam_sections!(struc, mixed, opts, I_factor)
        current = _gather_shell_demands!(run; service_on, regions)
        spans = service_on ? current.spans : nothing
        report = _beam_group_report(struc, opts; shell_demands = current.demands,
                                    shell_spans = spans, resolution = resolution)
        push!(seen, [_story_beam_section(struc, b) for b in struc.beams])
        if report !== nothing && _all_passed(report.passed) &&
           all(<=(run.region_tol), values(current.shifts)) &&
           (!service_on || current.service_converged)
            _record_beam_checks!(struc, report.explanations, report.hogging)
            @info "Story shell settled on a checked mix of the cycle"
            return _shell_pass_result(; converged = true, passes = pass,
                                      demands = current.demands, spans = current.spans,
                                      regions = current.regions, service_on,
                                      service_converged = service_converged && current.service_converged,
                                      shifts = current.shifts)
        end
        report !== nothing && (failing = _failing_ids(report.passed))
    else
        matched == length(states) ||
            _install_beam_sections!(struc, states[matched], opts, I_factor)
        current = solved[matched]
        gids = Set{UInt64}()
        for p in passed
            union!(gids, keys(p))
        end
        failing = Set(gid for gid in gids if all(p -> !get(p, gid, true), passed))
    end
    for _ in 1:3
        if !isempty(failing)
            sized = false
            for sizing in _beam_sizing_passes(struc, opts)
                accept = gid -> gid in failing && (sizing.accept === nothing || sizing.accept(gid))
                any(accept, failing) || continue
                if sized
                    _reanalyze_after_section_change!(struc)
                    current = _gather_shell_demands!(run; service_on, regions = current.regions)
                end
                spans = service_on ? current.spans : nothing
                size_beams!(struc, sizing.opts; run.kwargs..., shell_demands = current.demands,
                            shell_spans = spans, group_filter = accept)
                sized = true
            end
        end
        _reanalyze_after_section_change!(struc)
        state = [_story_beam_section(struc, b) for b in struc.beams]
        if any(s -> _beam_sections_identical(state, s), seen)
            @info "Story-shell settle returned to a section state it had already checked"
            break
        end
        push!(seen, state)
        current = _gather_shell_demands!(run; service_on, regions = current.regions)
        spans = service_on ? current.spans : nothing
        report = _beam_group_report(struc, opts; shell_demands = current.demands,
                                    shell_spans = spans, resolution = resolution)
        if report !== nothing && _all_passed(report.passed) &&
           all(<=(run.region_tol), values(current.shifts)) &&
           (!service_on || current.service_converged)
            _record_beam_checks!(struc, report.explanations, report.hogging)
            @info "Story shell settled after resizing the groups that failed the cycle"
            return _shell_pass_result(; converged = true, passes = pass,
                                      demands = current.demands, spans = current.spans,
                                      regions = current.regions, service_on,
                                      service_converged = service_converged && current.service_converged,
                                      shifts = current.shifts)
        end
        report === nothing && break
        failing = _failing_ids(report.passed)
    end
    @info "Story-shell settle did not find a design that passes its own shell"
    return _shell_pass_result(; converged = false, passes = pass,
                              demands = current.demands, spans = current.spans,
                              regions = current.regions, service_on,
                              service_converged = service_converged && current.service_converged,
                              shifts = current.shifts)
end

"""Beam and column options the sizer can check one installed section at a time."""
function _round_checkable(struc, beam_opts, column_opts)
    (beam_opts === nothing || column_opts === nothing) && return false
    _settle_checkable(beam_opts) || return false
    _settle_checkable(column_opts) || return false
    return all(_settle_checkable, values(_beam_opts_by_group(struc, beam_opts)))
end

function _shell_frame_accept(fresh, beams, columns, service_on, region_tol)
    fresh === nothing && return false
    beams === nothing && return false
    columns === nothing && return false
    regions_ok = all(s -> s <= region_tol, values(fresh.shifts))
    service_ok = !service_on || fresh.service_converged
    return regions_ok && service_ok && _all_passed(beams.passed) && _all_passed(columns)
end

"""Put `kept` back on the column groups that passed. The sizer has no column filter."""
function _restore_passing_columns!(struc, kept, column_opts, params)
    isempty(kept) && return struc
    edges = _edge_ids(struc, (:columns,))
    rebar = column_opts isa StructuralSizer.ConcreteColumnOptions ?
        column_opts.rebar_material : nothing
    for m in struc.columns
        gid = group_id(m)
        gid === nothing && continue
        haskey(kept, gid) || continue
        sec = kept[gid]
        (sec === nothing || _sections_identical(section(m), sec)) && continue
        _install_member_section!(struc, m, sec, edges, column_opts.material,
                                 params.column_I_factor, rebar)
    end
    return struc
end

"""
Resize beam groups that failed the shell now solved, and column groups that
failed the frame. A passing group keeps its section. The column sizer re-picks
every group, so passing columns are put back afterward unless uniform column
sizing is on. Returns whether any section moved.
"""
function _resize_rejected!(run, failing_beams, column_passed, fresh, params, column_opts)
    struc = run.struc
    moved = false
    demands, spans, regions = fresh.demands, fresh.spans, fresh.regions
    if !isempty(failing_beams)
        sized = false
        for sizing in _beam_sizing_passes(struc, run.opts)
            accept = gid -> gid in failing_beams &&
                            (sizing.accept === nothing || sizing.accept(gid))
            any(accept, failing_beams) || continue
            if sized
                _reanalyze_after_section_change!(struc)
                fresh = _gather_shell_demands!(run; service_on = run.service_on,
                                               regions = regions)
                demands, spans, regions = fresh.demands, fresh.spans, fresh.regions
            end
            shell_spans = run.service_on ? spans : nothing
            size_beams!(struc, sizing.opts; run.kwargs..., shell_demands = demands,
                        shell_spans = shell_spans, group_filter = accept)
            sized = true
            moved = true
        end
    end
    if !_all_passed(column_passed)
        kept = Dict{UInt64, Any}()
        if params.uniform_column_sizing === :off
            for m in struc.columns
                gid = group_id(m)
                gid === nothing && continue
                get(column_passed, gid, false) || continue
                kept[gid] = section(m)
            end
        end
        size_columns!(struc, column_opts; reanalyze = false, tc = get(run.kwargs, :tc, nothing),
                      I_factor = params.column_I_factor,
                      gravity_factor = member_self_weight_acceleration(params))
        _restore_passing_columns!(struc, kept, column_opts, params)
        _harmonize_columns!(struc, params)
        moved = true
    end
    if moved
        fallback = params.beams
        raise_head_face_ribs!(struc, params, fallback;
                              I_factor = params.beam_I_factor,
                              gravity_factor = member_self_weight_acceleration(params))
        conform_rib_lines!(struc, params, fallback; I_factor = params.beam_I_factor)
        grow_building_solid_heads!(struc, params)
        _sync_fire_coating_loads!(struc, params)
        _reanalyze_after_section_change!(struc)
    end
    return moved
end

"""
    _reconcile_shell_frame!(...) -> NamedTuple

Solve the story shell on the sections already in the model and check every
beam and column. Groups that pass stay. Groups that fail are sized for that
shell, then the shell is solved again. Stops when a section vector repeats,
because that state was already checked. Returns `held = true` only when the
shell of the installed sections and the frame of those sections both pass.
"""
function _reconcile_shell_frame!(struc, params, beam_opts, column_opts, beam_kwargs,
                                 levels, shells; shell_kwargs, seed_regions = nothing,
                                 region_tol::Real = 0.05, attempts::Int = 4)
    build_kwargs, solve_kwargs, want_service = _split_shell_kwargs(shell_kwargs)
    run = (struc = struc, opts = beam_opts, levels = levels, shells = shells,
           build_kwargs = build_kwargs, solve_kwargs = solve_kwargs,
           want_service = want_service, service_on = want_service,
           region_tol = region_tol, kwargs = beam_kwargs, history = nothing)
    regions = seed_regions === nothing ? Dict{Int, Vector{NamedTuple}}() :
              Dict{Int, Vector{NamedTuple}}(seed_regions)
    seen = [_member_state(struc)]
    trace = get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1"
    resolution = get(beam_kwargs, :resolution, 200)
    last = nothing
    used = 0
    for _ in 1:attempts
        used += 1
        fresh = _gather_shell_demands!(run; service_on = want_service, regions = regions)
        regions = fresh.regions
        last = fresh
        spans = want_service ? fresh.spans : nothing
        beams = _beam_group_report(struc, beam_opts; shell_demands = fresh.demands,
                                   shell_spans = spans, resolution = resolution)
        columns = _column_group_report(struc, column_opts; resolution = resolution)
        if beams === nothing || columns === nothing
            return (held = false, demands = fresh.demands, spans = fresh.spans,
                    regions = fresh.regions, service_converged = fresh.service_converged,
                    attempts = used)
        end
        n_beam = length(beams.passed)
        n_col = length(columns)
        if trace
            bad_cols = [i for (i, m) in enumerate(struc.columns)
                        if !get(columns, group_id(m), true)]
            println("  shell reconcile $used  " *
                    "beams $(count(values(beams.passed)))/$n_beam  " *
                    "columns $(count(values(columns)))/$n_col  " *
                    "failing columns $bad_cols  " *
                    "regions=$(all(s -> s <= region_tol, values(fresh.shifts)))  " *
                    "service=$(fresh.service_converged)")
        end
        if _shell_frame_accept(fresh, beams, columns, want_service, region_tol)
            _record_beam_checks!(struc, beams.explanations, beams.hogging)
            @info "Story shell and frame agree on the installed sections"
            return (held = true, demands = fresh.demands, spans = fresh.spans,
                    regions = fresh.regions, service_converged = fresh.service_converged,
                    attempts = used)
        end
        # The last attempt stays as checked. Resizing it would leave a state
        # the shell has not seen.
        used == attempts && break
        failing = _failing_ids(beams.passed)
        moved = _resize_rejected!(run, failing, columns, fresh, params, column_opts)
        moved || break
        state = _member_state(struc)
        if any(s -> _member_state_identical(state, s), seen)
            @info "Shell reconcile returned to a section state it had already checked"
            break
        end
        push!(seen, state)
    end
    fresh = last
    return (held = false,
            demands = fresh === nothing ? Dict{Int, ShellBeamDemand}() : fresh.demands,
            spans = fresh === nothing ? Dict{Int, Vector{Any}}() : fresh.spans,
            regions = fresh === nothing ? regions : fresh.regions,
            service_converged = fresh === nothing ? false : fresh.service_converged,
            attempts = used)
end
