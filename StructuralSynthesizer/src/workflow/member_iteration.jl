# =============================================================================
# Uniform Column Size Harmonization
# =============================================================================

"""
    harmonize_uniform_column_sizes!(struc, params) -> Int

Post-pipeline pass that promotes column sizes within each uniformity group to
the governing (largest) member.  Groups are defined by `params.uniform_column_sizing`:

- `:per_story` — one group per `Column.story`
- `:building`  — single group for all columns

Returns the number of columns that were enlarged.

A larger column has at least the axial and flexural capacity of the smaller
one. Its stiffness also changes the unbalanced moment each slab joint sends
into it, so punching and the full-load column check are not assumed to hold;
the caller re-checks them.

For **RC columns** (`c1`/`c2` dimensions), the maximum `c1` and `c2` within
each group are propagated.  For **steel columns** (catalog sections), the
section with the largest cross-sectional area is propagated.  After
propagation, ASAP element sections and structural offsets are refreshed.
"""
function harmonize_uniform_column_sizes!(struc::BuildingStructure, params::DesignParameters)
    mode = params.uniform_column_sizing
    mode === :off && return 0

    columns = struc.columns
    isempty(columns) && return 0

    # --- Build groups: story → indices (or single group for :building) ---
    groups = Dict{Int, Vector{Int}}()
    for (i, col) in enumerate(columns)
        key = mode === :building ? 0 : col.story
        push!(get!(Vector{Int}, groups, key), i)
    end

    col_opts = params.columns
    is_steel = col_opts isa StructuralSizer.SteelColumnOptions

    changed = 0

    for (_, indices) in groups
        length(indices) <= 1 && continue

        if is_steel
            changed += _harmonize_steel_group!(struc, indices)
        else
            changed += _harmonize_rc_group!(struc, params, indices)
        end
    end

    if changed > 0
        update_structural_offsets!(struc; input_is_centerline=params.geometry_is_centerline)
        _resolve_after_column_change!(struc)
        @info "Uniform column harmonization: $changed columns enlarged" mode=string(mode)
    end

    return changed
end

"""Promote RC columns in `indices` to max(c1) × max(c2). Returns count of enlarged columns."""
function _harmonize_rc_group!(struc::BuildingStructure, params::DesignParameters, indices::Vector{Int})
    columns = struc.columns
    cols = [columns[i] for i in indices]

    sized = filter(c -> !isnothing(c.c1) && !isnothing(c.c2), cols)
    isempty(sized) && return 0

    gov_c1 = maximum(c.c1 for c in sized)
    gov_c2 = maximum(c.c2 for c in sized)

    changed = 0
    for i in indices
        col = columns[i]
        (isnothing(col.c1) || isnothing(col.c2)) && continue
        already = col.c1 == gov_c1 && col.c2 == gov_c2
        if already && !isempty(volumes(col))
            continue
        end

        col.c1 = gov_c1
        col.c2 = gov_c2
        already || (changed += 1)

        # A column that already matches keeps its section. One that grew, or
        # that never received a section, gets the same bar assignment as
        # reconciliation. Volumes are written either way when they were empty.
        if !already || isnothing(section(col))
            _assign_flat_plate_column_section!(col)
        end

        # Gross section area as a single concrete volume counted the rebar
        # volume at the concrete coefficient and left rebar carbon at zero.
        _set_rc_column_volumes!(
            col,
            something(col.concrete, column_concrete(params)),
            column_rebar(params),
        )
        already && continue
        _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
    end

    return changed
end

"""Promote steel columns in `indices` to the heaviest section. Returns count of changed columns."""
function _harmonize_steel_group!(struc::BuildingStructure, indices::Vector{Int})
    columns = struc.columns

    # Find governing section (largest cross-sectional area)
    gov_sec = nothing
    gov_area = -Inf
    gov_vols = nothing
    for i in indices
        sec = section(columns[i])
        isnothing(sec) && continue
        a = ustrip(u"m^2", StructuralSizer.section_area(sec))
        if a > gov_area
            gov_area = a
            gov_sec = sec
            gov_vols = volumes(columns[i])
        end
    end
    isnothing(gov_sec) && return 0

    gov_mat_key = (isnothing(gov_vols) || isempty(gov_vols)) ?
        StructuralSizer.A992_Steel : first(keys(gov_vols))
    asap_sec = StructuralSizer.to_asap_section(gov_sec, gov_mat_key)

    changed = 0
    for i in indices
        col = columns[i]
        sec = section(col)
        isnothing(sec) && continue
        sec === gov_sec && continue
        a = ustrip(u"m^2", StructuralSizer.section_area(sec))
        a >= gov_area && continue

        set_section!(col, gov_sec)
        !isnothing(gov_vols) && !isempty(gov_vols) && set_volumes!(col, copy(gov_vols))
        changed += 1

        _install_column_frame_section!(struc, col, asap_sec)
    end

    return changed
end

"""Extract compressive axial force (N) for a column from the Asap model.

Asap local `P` is negative in compression (same convention as
`member_group_demands`). Tension is not folded into compression via `abs`.
"""
function _column_asap_Pu(struc::BuildingStructure, col)
    Pu = 0.0
    for seg_idx in segment_indices(col)
        seg = struc.segments[seg_idx]
        edge_idx = seg.edge_idx
        (edge_idx < 1 || edge_idx > length(struc.asap_model.frame_elements)) && continue
        el = struc.asap_model.frame_elements[edge_idx]
        isempty(el.forces) && continue
        n_dof = length(el.forces)
        P_start = el.forces[1]
        P_end = n_dof >= 7 ? el.forces[7] : P_start
        Pu = max(Pu, max(0.0, -P_start), max(0.0, -P_end))
    end
    return Pu
end

"""Rebuild K, re-solve, and refresh pattern `(u, loads)` after a section change."""
function _reanalyze_after_section_change!(struc::BuildingStructure)
    # The solid head weighs only the projection below the topping, and that
    # depth is the rib section this solve is about to read.
    apply_solid_head_frame_sections!(struc)
    if struc.asap_model.processed
        Asap.update!(struc.asap_model)
    else
        Asap.process!(struc.asap_model)
    end
    # `update!` does not re-realize a parametric frame element.
    isempty(Asap.stale_frame_elements(struc.asap_model)) || Asap.process!(struc.asap_model)
    _solve_struc_model!(struc)
    _refresh_pattern_solve_cache!(struc)
    return struc
end

"""Columns for a floor with no beam edges.

A wall-supported two-way slab is concrete, and its columns are concrete in the
cascade's column materials ([`concrete_column_options`](@ref)). Any other
beamless floor keeps the steel default. An explicit `params.columns` is
applied by the caller and never reaches here.
"""
function _beamless_column_options(struc::BuildingStructure, params::DesignParameters)
    floor_types = Set(s.floor_type for s in struc.slabs)
    if :two_way in floor_types &&
       all(ft -> ft in (:two_way, :grade, :roof), floor_types)
        return concrete_column_options(params)
    end
    return StructuralSizer.SteelColumnOptions()
end

"""
Iterative beam + column sizing for beam-based floor systems.

Beams and columns are coupled: beam self-weight affects column demands, and
column stiffness affects beam moments. This loop converges their sizes.
"""
function _size_beams_columns!(struc::BuildingStructure, params::DesignParameters;
                              tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    # Defensive guard: slab-only systems should not run beam sizing.
    # This keeps flat-plate/flat-slab workflows resilient even if an upstream
    # caller accidentally routes into the beam+column stage.
    if !isempty(struc.slabs)
        floor_types = Set(s.floor_type for s in struc.slabs)
        if all(ft -> ft in (:flat_plate, :flat_slab, :grade, :roof), floor_types)
            # [P1 fix cycle 3] Honor-or-throw invariant on the SLAB-ONLY skip branch.
            # Beam sizing is about to be skipped, so no steel beam group will be sized
            # and an EFFECTIVE per-group `member_group_overrides` entry can never be
            # honored on this path — materializing a BuildingDesign anyway would
            # SILENTLY DROP it (the exact safety hazard the feature exists to prevent).
            # The floor-type door (`_assert_member_group_overrides_unsupported`) already
            # refuses flat_plate/flat_slab effective overrides, so the residual exposure
            # closed here is a slab-only :grade/:roof geometry. Empty / all-unset
            # (vacuous) overrides stay a strict no-op (byte-identical). Uses the SAME
            # effectiveness test as the rest of the feature (`_is_effective`).
            # (catalog / deflection_limit / max_depth are engineering sizing knobs — no
            # code citation.)
            if any(_is_effective, values(params.member_group_overrides))
                throw(ArgumentError(_mgo_refusal_message(
                    "beam sizing is skipped for a slab-only floor system " *
                    "(floor_types=$(collect(floor_types))) in the beam+column stage, so " *
                    "no steel beam group is sized and the per-group override cannot be " *
                    "honored")))
            end
            @warn "Skipping beam sizing for slab-only floor system in beam+column stage" floor_types=collect(floor_types)
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                                  outcome="skipped", reason="slab_only_system",
                                  floor_types=collect(string.(collect(floor_types))))
            _design_flat_plate_members!(struc, params; tc=tc)
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :exit;
                                  outcome="skipped")
            return struc
        end
    end

    beam_opts   = something(params.beams,   StructuralSizer.SteelBeamOptions())
    column_opts = something(params.columns, StructuralSizer.SteelColumnOptions())
    skel = struc.skeleton
    beam_edge_ids = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(beam_edge_ids, get(skel.groups_edges, g, Int[]))
    end

    # Skip beam sizing when no beam edges (e.g. beam-based floor type but geometry has no beams)
    if isempty(beam_edge_ids)
        # [P1 fix cycle 3] Honor-or-throw invariant on the NO-BEAM-EDGES skip branch.
        # Beam sizing is skipped (columns only), so an EFFECTIVE per-group
        # `member_group_overrides` entry targets a steel beam group that will never be
        # sized on this path; producing a BuildingDesign would SILENTLY DROP it. This
        # fires on a NON-flat steel floor that has columns but no :beams edge group,
        # on BOTH `design_building` and `redesign_incremental!` (both route through
        # `_size_beams_columns!`). Empty / all-unset (vacuous) overrides stay a strict
        # no-op (byte-identical). (Engineering sizing knobs — no code citation.)
        if any(_is_effective, values(params.member_group_overrides))
            throw(ArgumentError(_mgo_refusal_message(
                "beam sizing is skipped because the geometry has no :beams edges " *
                "(sizing columns only), so no steel beam group is sized and the " *
                "per-group override cannot be honored")))
        end
        column_opts = something(params.columns, _beamless_column_options(struc, params))
        @warn "Skipping beam sizing: no beam edges in geometry. Sizing columns only."
        StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                              outcome="skipped_beams", reason="no_beam_edges")
        # Self-weight, coating, and stiffness follow the section, so columns
        # are re-sized until a pass changes none of them.
        converged = false
        for _ in 1:max(1, params.max_iterations)
            before = [section(c) for c in struc.columns]
            size_columns!(struc, column_opts; reanalyze=false, tc=tc,
                          I_factor=params.column_I_factor,  # ACI 318-11 §10.10.4.1
                          gravity_factor=member_self_weight_acceleration(params))
            _harmonize_columns!(struc, params)
            _sync_fire_coating_loads!(struc, params)
            update_analysis!(struc, :stiffness; tc)
            if all(_sections_identical(a, section(c)) for (a, c) in zip(before, struc.columns))
                converged = true
                break
            end
        end
        _record_member_convergence!(struc, converged)
        StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :exit;
                              outcome="columns_only", converged=converged)
        return struc
    end

    StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :enter;
                          n_beams=length(beam_edge_ids), n_columns=length(struc.columns),
                          beam_type=string(typeof(beam_opts)),
                          column_type=string(typeof(column_opts)))

    # Run 4 / Phase B: forward per-group member_group_overrides into the batched
    # beam sizing. `nothing`/vacuous overrides route the pre-Phase-B path verbatim
    # (byte-identical); an effective steel-beam-group override narrows only that
    # group. Un-honorable targets are already refused upstream by the guard.
    mgo = isempty(params.member_group_overrides) ? nothing : params.member_group_overrides
    beam_kwargs = (; reanalyze = false, tc = tc, member_group_overrides = mgo,
                   I_factor = params.beam_I_factor,
                   gravity_factor = member_self_weight_acceleration(params),
                   rib_head_stirrups = params.rib_head_stirrups,
                   composite_concrete = resolve_slab_concrete(params.materials),
                   composite_option_kwargs(beam_opts)...)

    # Optional: separate collinear beams share one section. Edges of a single
    # beam are already one member and do not depend on this flag.
    params.collinear_grouping && group_collinear_members!(struc; member_type=:beams)

    # A grillage story is the rib frame. The story shell does not also size
    # those ribs. A story that mixes the two throws.
    shell_levels = setdiff(_story_shell_design_levels(struc), exclusive_grillage_stories(struc))
    if isempty(shell_levels)
        _clear_story_shell_wall_axials!(struc)
        # A ribbed story's stem is screened on the demands of the last member
        # loop, and the loop runs again until the screen keeps every stem.
        has_ribs = !isempty(_rib_stories(struc, beam_opts))
        rib_kwargs = (; I_factor = params.beam_I_factor,
                      gravity_factor = member_self_weight_acceleration(params),
                      rib_head_stirrups = params.rib_head_stirrups)
        converged, iters_used = false, 0
        for round in 1:(has_ribs ? RIB_SCREEN_ROUNDS : 1)
            if has_ribs
                moved = screen_rib_stems!(struc, params; fallback = beam_opts, rib_kwargs...)
                round > 1 && !moved && break
                _reanalyze_after_section_change!(struc)
            end
            converged, n = _iterate_beams_columns!(struc, params, beam_opts,
                                                   column_opts, beam_kwargs; tc = tc)
            iters_used += n
        end
        has_ribs && report_rib_deflection!(struc, params; fallback = beam_opts)
    else
        converged, iters_used = _size_with_story_shell!(struc, params, beam_opts,
                                                        column_opts, beam_kwargs,
                                                        shell_levels; tc = tc)
    end

    # ACI 318-11 §9.5.3.3 after the beams exist. At most two further member
    # sizings: one on the thickness the first αfm allows, and one if those
    # beams change αfm enough that the slab must move again.
    for _ in 1:2
        _recheck_two_way_thickness!(struc, params, beam_opts) || break
        converged, iters_used = _resize_beams_after_thickness!(
            struc, params, beam_opts, column_opts, beam_kwargs, shell_levels; tc = tc)
    end
    _record_member_convergence!(struc, converged)

    StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :exit;
                          converged=converged,
                          iterations=iters_used)
    return struc
end

"""
Size beams, re-solve, size columns (then uniform column sizing and fire
coating) and re-solve, until one pass changes no beam and no column section.
`shell_demands` and `shell_spans` go to every `size_beams!` call. Returns
`(converged, iterations)`.

At that fixed point each beam was sized on a model with the final column
sections, and each column on the final beams, so every member passed its
sizer's checks on the final analysis. A loop that returns to a section state
it already left is settled by [`_check_settle!`](@ref): a design is kept only
when every group passes the analysis of those sections. A loop that reaches
`max_iterations` without a repeat returns `converged = false`.
"""
function _iterate_beams_columns!(struc, params, beam_opts, column_opts, beam_kwargs;
                                 tc = nothing, shell_demands = nothing,
                                 shell_spans = nothing, upward_only::Bool = false)
    max_iter = params.max_iterations
    history = _MemberState[]
    for iter in 1:max_iter
        beams_before = [_story_beam_section(struc, b) for b in struc.beams]
        columns_before = [section(c) for c in struc.columns]
        size_beams!(struc, beam_opts; shell_demands = shell_demands,
                    shell_spans = shell_spans,
                    section_floor = upward_only ? _section_floors(struc) : nothing,
                    beam_kwargs...)
        # The solid head is the bays around each column. A failing check grows
        # those bays, which adds beams, so the next pass sizes against them.
        grow_building_solid_heads!(struc, params; fallback = beam_opts)
        _sync_fire_coating_loads!(struc, params)
        update_analysis!(struc, :stiffness; tc)
        size_columns!(struc, column_opts; reanalyze=false, tc=tc,
                      I_factor=params.column_I_factor,
                      gravity_factor=member_self_weight_acceleration(params))
        _harmonize_columns!(struc, params)
        _sync_fire_coating_loads!(struc, params)
        update_analysis!(struc, :stiffness; tc)
        held = length(beams_before) == length(struc.beams) &&
               all(_sections_identical(a, _story_beam_section(struc, b))
                   for (a, b) in zip(beams_before, struc.beams)) &&
               all(_sections_identical(a, section(c))
                   for (a, c) in zip(columns_before, struc.columns))
        if get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1" && !held
            for (k, (a, b)) in enumerate(zip(beams_before, struc.beams))
                s = _story_beam_section(struc, b)
                _sections_identical(a, s) ||
                    println("  pass $iter  beam $k  $(_section_tag(a)) → $(_section_tag(s))")
            end
        end
        state = _member_state(struc)
        if held
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                                  outcome="converged", iterations=iter)
            return (true, iter)
        end
        earlier = findfirst(s -> _member_state_identical(s, state), history)
        push!(history, state)
        if earlier !== nothing
            ok = _check_settle!(struc, history[earlier:end - 1], params, beam_opts,
                                column_opts, beam_kwargs;
                                shell_demands, shell_spans, tc)
            StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                                  outcome = ok ? "check_settle" : "check_settle_failed",
                                  iterations = iter)
            return (ok, iter)
        end
    end
    StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                          outcome="max_iterations", iterations=max_iter)
    return (false, max_iter)
end

"""
Beam and column sizing for the stories in `levels`, which the story shell
designs (see [`_story_shell_design_levels`](@ref)).

The first round resizes the beams against the story shell
([`size_beams_with_story_shell!`](@ref)), then runs the beam and column loop
with those shell demands held. Columns are rotational springs on the shell
and beam stiffness sets the shell's beam demands, so a round that changed a
beam or a column after the shell has not yet checked those sections.

When that round does not hold and the sections can be checked one at a time,
later rounds do not free-pick. [`_reconcile_shell_frame!`](@ref) solves the
shell on the sections the frame left and resizes only the groups that fail
it. A passing group keeps its section. Each story is meshed once.

With steel discrete beams, rounds after the first start upward-only from the
sections before them. When those rounds settle, one more round runs the
story-shell trim (a lighter design is kept only when it converges lighter),
with up to `max_rounds` further rounds to settle again.

When the rounds settle, the slab bars on each story come from a shell solve
with the final beam and column sections. Each slab on those stories records
`converged` and, when the rounds did not settle, why. Returns
`(converged, iterations)`, where `converged` requires the shell of the
installed sections and the frame of those sections to both pass.
"""
function _size_with_story_shell!(struc, params, beam_opts, column_opts, beam_kwargs,
                                 levels; tc = nothing, max_rounds::Int = 3)
    shells = Dict{Int, StoryShell}()
    shell_kwargs = (; concrete = resolve_slab_concrete(params.materials),
                    column_concrete = column_concrete(params),
                    rebar = resolve_slab_rebar(params.materials))
    seed = (demands = nothing, spans = nothing, regions = nothing)
    converged, iters = false, 0
    held = false
    # Discrete steel and rectangular concrete beams only move up once the first
    # shell call settles, so a beam that attracts load and fails cannot trade
    # places with a lighter one. T-beams are not floored; a later round checks
    # the sections in place instead of free-picking them again.
    upward_only = _shell_ratchet_ok(struc, beam_opts, beam_kwargs)
    checkable = _round_checkable(struc, beam_opts, column_opts)
    floor = nothing
    tried_trim = !upward_only
    trim_now = false
    round = 0
    limit = max_rounds
    while round < limit
        round += 1
        columns_before = [section(c) for c in struc.columns]
        sb = size_beams_with_story_shell!(struc, beam_opts; levels = levels, shells = shells,
                                          shell_kwargs = shell_kwargs,
                                          shell_demands = seed.demands,
                                          shell_spans = seed.spans,
                                          shell_regions = seed.regions,
                                          section_floor = floor,
                                          trim_continuing = trim_now,
                                          beam_kwargs...)
        trim_now = false
        beams_after_shell = [_story_beam_section(struc, b) for b in struc.beams]
        converged, n = _iterate_beams_columns!(struc, params, beam_opts, column_opts,
                                               beam_kwargs; tc = tc,
                                               shell_demands = sb.demands,
                                               shell_spans = sb.spans,
                                               upward_only = upward_only)
        iters += n
        beams_held = length(beams_after_shell) == length(struc.beams) &&
                     all(_sections_identical(a, _story_beam_section(struc, b))
                         for (a, b) in zip(beams_after_shell, struc.beams))
        columns_held = all(_sections_identical(a, section(c))
                           for (a, c) in zip(columns_before, struc.columns))
        held = sb.converged && sb.service_converged && beams_held && columns_held
        get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1" &&
            println("story-shell round $round  shell_converged=$(sb.converged)  " *
                    "service_converged=$(sb.service_converged)  beams_held=$beams_held  " *
                    "columns_held=$columns_held  frame_loop_converged=$converged")
        if get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1" && !columns_held
            for (k, (a, c)) in enumerate(zip(columns_before, struc.columns))
                b = section(c)
                _sections_identical(a, b) && continue
                diff = a === nothing || b === nothing || typeof(a) !== typeof(b) ? [:type] :
                       [f for f in fieldnames(typeof(a))
                        if !_field_identical(getfield(a, f), getfield(b, f))]
                dims(s) = hasproperty(s, :b) && hasproperty(s, :h) ? "$(s.b)×$(s.h)" : _section_tag(s)
                println("  column $k  $(a === nothing ? "none" : dims(a)) → $(dims(b))  fields=$(diff)")
            end
        end
        StructuralSizer.emit!(tc, :workflow, "_size_beams_columns!", "", :decision;
                              outcome = "story_shell_round",
                              round = round, shell_passes = sb.passes,
                              shell_converged = sb.converged, beams_held = beams_held,
                              columns_held = columns_held)
        if held
            (tried_trim || floor === nothing) && break
            # Rounds after the first started upward-only from the round before,
            # so sections never came down. Try the trim once on the settled
            # demands, with its own round budget.
            tried_trim = true
            trim_now = true
            limit = round + max_rounds
        end
        seed = (demands = sb.demands, spans = sb.spans, regions = sb.regions)
        upward_only && (floor = _section_floors(struc))
        # A checkable catalog keeps the sections this round left and tests
        # them against a shell solved on those sections. Another free pass
        # would replace a group that already passes.
        checkable && break
    end
    if !held && checkable
        closed = _reconcile_shell_frame!(struc, params, beam_opts, column_opts, beam_kwargs,
                                         levels, shells; shell_kwargs = shell_kwargs,
                                         seed_regions = seed.regions)
        iters += closed.attempts
        closed.held && (converged = true; held = true)
        get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1" &&
            println("story-shell reconcile held=$(closed.held)  attempts=$(closed.attempts)")
    end
    held || @warn "Story-shell sizing did not settle after $round rounds" levels
    _record_story_shell_wall_axials!(struc, shells)
    _record_story_shell_convergence!(struc, held)
    return (converged && held, iters)
end

"""
Record whether beam and column sizing settled. A loop that ran out of
iterations leaves `struc.stage_diagnostics[:members]`, which `capture_design`
reports and which marks the design not converged.
"""
function _record_member_convergence!(struc, converged::Bool)
    if converged
        delete!(struc.stage_diagnostics, :members)
    else
        struc.stage_diagnostics[:members] =
            "Beam and column sizing did not settle within max_iterations; " *
            "member demands may not match the final sections."
    end
    return struc
end

"""
Write `converged` onto every slab the story shell designed. A slab that did
not settle also records `failure_reason` and `failing_check`.
"""
function _record_story_shell_convergence!(struc, held::Bool)
    extra = held ? (converged = true,) :
            (converged = false, failure_reason = "non_convergence",
             failing_check = "story_shell")
    for slab in struc.slabs
        dd = slab.design_details
        dd isa NamedTuple && get(dd, :analysis_source, nothing) === :story_shell || continue
        slab.design_details = merge(dd, extra)
    end
    return struc
end

"""
Size the beams and columns again after a two-way slab thickness change.

The new slab self-weight goes on the model first. Returns `(converged, iterations)`.
"""
function _resize_beams_after_thickness!(struc, params, beam_opts, column_opts,
                                        beam_kwargs, shell_levels; tc = nothing)
    update_analysis!(struc, :loads; params, tc)
    isempty(shell_levels) &&
        return _iterate_beams_columns!(struc, params, beam_opts, column_opts, beam_kwargs;
                                       tc = tc)
    return _size_with_story_shell!(struc, params, beam_opts, column_opts, beam_kwargs,
                                   shell_levels; tc = tc)
end

function _edge_is_beam(skel, edge)
    for g in BEAM_GROUP_SYMBOLS
        edge in get(skel.groups_edges, g, Int[]) && return true
    end
    return false
end

function _beam_on_edge(struc, edge)
    for beam in struc.beams
        for seg_idx in beam.base.segment_indices
            struc.segments[seg_idx].edge_idx == edge && return beam
        end
    end
    return nothing
end

"""
`(E, Ib)` of a sized beam. `Ib` is the stem, or the steel `Ix`.
The slab flange is not included: that sentence was not readable.
"""
function _beam_stem_stiffness(beam, beam_opts)
    sec = section(beam)
    sec === nothing && return nothing
    if sec isa StructuralSizer.RCBeamSection
        hasproperty(beam_opts, :material) || return nothing
        mat = beam_opts.material
        E = mat isa StructuralSizer.ReinforcedConcreteMaterial ? mat.concrete.E :
            mat isa StructuralSizer.Concrete ? mat.E : nothing
        E === nothing && return nothing
        return (E, sec.b * sec.h^3 / 12)
    elseif sec isa StructuralSizer.RCTBeamSection
        hasproperty(beam_opts, :material) || return nothing
        mat = beam_opts.material
        mat isa StructuralSizer.ReinforcedConcreteMaterial || return nothing
        return (mat.concrete.E, sec.bw * sec.h^3 / 12)
    elseif hasproperty(sec, :Ix) && hasproperty(beam_opts, :material) &&
           hasproperty(beam_opts.material, :E)
        return (beam_opts.material.E, sec.Ix)
    end
    return nothing
end

"""True when the slab does not continue across `edge`."""
function _edge_discontinuous(struc, edge, face)
    skel = struc.skeleton
    for (f, es) in enumerate(skel.face_edge_indices)
        f == face && continue
        edge in es || continue
        ci = findfirst(c -> c.face_idx == f, struc.cells)
        ci === nothing && return true
        return struc.cells[ci].floor_type in (:unknown, :grade)
    end
    return true
end

"""
αfm of one panel when every edge has a sized beam and a tributary width.
`nothing` when §9.5.3.3 does not apply (a side has no beam).
"""
function _panel_alpha(struc, cell, h, Ecs, beam_opts)
    skel = struc.skeleton
    face = cell.face_idx
    edges = skel.face_edge_indices[face]
    alphas = Float64[]
    discontinuous = false
    for edge in edges
        _edge_is_beam(skel, edge) || return nothing
        beam = _beam_on_edge(struc, edge)
        beam === nothing && return nothing
        stiff = _beam_stem_stiffness(beam, beam_opts)
        stiff === nothing && return nothing
        ls = tributary_width_scalar(beam)
        (ls === nothing || ls <= 0u"m") && return nothing
        Is = StructuralSizer.slab_strip_inertia(ls, h)
        α = StructuralSizer.beam_slab_alpha_f(stiff[1], stiff[2], Ecs, Is)
        push!(alphas, α)
        if _edge_discontinuous(struc, edge, face) && α < 0.80
            discontinuous = true
        end
    end
    return (αfm = StructuralSizer.panel_alpha_fm(alphas), discontinuous = discontinuous)
end

"""
    _recheck_two_way_thickness!(struc, params, beam_opts) -> Bool

Set each two-way slab to ACI 318-11 §9.5.3.3 with the beams now in place.
Returns `true` when a thickness changed. A panel without beams on all sides
leaves the slab on the §9.5.3.3(a) thickness it was given.
"""
function _recheck_two_way_thickness!(struc, params, beam_opts)
    changed = false
    concrete = resolve_slab_concrete(params.materials)
    fy = resolve_slab_rebar(params.materials).Fy
    for slab in struc.slabs
        slab.floor_type === :two_way || continue
        slab.result isa StructuralSizer.CIPSlabResult || continue
        h_now = StructuralSizer.total_depth(slab.result)
        required = typeof(1.0u"inch")[]
        for ci in slab.cell_indices
            cell = struc.cells[ci]
            info = _panel_alpha(struc, cell, h_now, concrete.E, beam_opts)
            info === nothing && (required = Length[]; break)
            ln = max(cell.spans.primary, cell.spans.secondary)
            short = min(cell.spans.primary, cell.spans.secondary)
            ustrip(u"m", short) > 0 || (required = Length[]; break)
            β = ustrip(u"m", ln) / ustrip(u"m", short)
            push!(required, StructuralSizer.min_thickness(
                StructuralSizer.TwoWay(), ln; fy = fy, αfm = info.αfm, β = β,
                discontinuous_edge = info.discontinuous))
        end
        isempty(required) && continue
        h = ceil(ustrip(u"inch", maximum(required)) * 2 - 1e-6) / 2 * u"inch"
        abs(ustrip(u"inch", h - h_now)) < 0.05 && continue
        sw = StructuralSizer.slab_self_weight(h, concrete.ρ)
        h_m = uconvert(u"m", h)
        slab.result = StructuralSizer.CIPSlabResult(h_m, h_m, uconvert(u"kPa", sw))
        for ci in slab.cell_indices
            struc.cells[ci].self_weight = slab.result.self_weight
        end
        changed = true
    end
    return changed
end

