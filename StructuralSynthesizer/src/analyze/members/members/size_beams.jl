# =============================================================================
# Beam Sizing Dispatcher
# =============================================================================

"""
    size_beams!(struc, opts; method=:discrete, ...)

Size beams, dispatching on material (steel vs concrete) and method (:discrete / :nlp).

# Dispatch Table
| Options type         | method     | Implementation                           |
|:---------------------|:-----------|:-----------------------------------------|
| SteelBeamOptions     | :discrete  | `size_steel_members!`                    |
| ConcreteBeamOptions  | :discrete  | MIP via `size_beams` or `size_tbeams`    |
| ConcreteBeamOptions  | :nlp       | NLP via `size_rc_beams_nlp` / `_tbeams`  |

If no options are provided, falls back to `struc.design_parameters.beams`,
then to `SteelBeamOptions()`.

Note: `BuildingStructure` has no `design_parameters` field as of this writing
(see `building_types/structure.jl`), so the `struc.design_parameters` fallback is
an inert backstop kept for a future harness-gated addition of the field.

The concrete beam path extracts Mu, Vu, and Nu from the Asap analysis
results and passes them through to the ACI 318 beam checker. When Nu > 0
(axial compression from frame action), Vc is increased per ACI §22.5.6.1.

When `ConcreteBeamOptions.include_flange = true`, the dispatcher automatically:
- Reads slab thicknesses from `struc.slabs` (slabs must be sized first)
- Computes effective flange widths per ACI 318-11 §8.12.2 / §8.12.3 at the
  governing sagging station of each beam's per-side tributary profile
- Routes to `size_tbeams` (discrete) or `size_rc_tbeams_nlp` (NLP)

When `SteelBeamOptions.composite = true`, each beam group is sized with a
`PerStationComposite`: per-side tributary profiles and the exact moment field,
re-solved at the sagging station of each candidate section (AISC 360-22
§I3.1a / §I8). The stud diameter, length, and Fu come from the options.
Thickness and concrete come from the sized slab unless the options override
the thickness. There is no nominal stud. Hogging stays on Chapter F until
`Asr` and negative-region anchors are provided.

`shell_demands` (beam index → [`ShellBeamDemand`](@ref)) raises each group's
sagging moment, hogging moment, and shear to the story-shell value where that
is larger. See [`size_beams_with_story_shell!`](@ref). A composite beam's
shell moment fields, one per load combination, are also checked for sagging
strength and anchors on their own zeros (`strength_fields` of
`PerStationComposite`).

# Example
```julia
# Steel beams with L/360 deflection check
size_beams!(struc, SteelBeamOptions(deflection_limit = 1/360))

# RC rectangular beams (discrete catalog MIP)
size_beams!(struc, ConcreteBeamOptions(material = NWC_5000))

# RC T-beams — auto-detects flange from slab data
size_beams!(struc, ConcreteBeamOptions(material = NWC_5000, include_flange = true))
```
"""
function size_beams!(
    struc::BuildingStructure,
    opts::Union{StructuralSizer.BeamOptions, Nothing} = nothing;
    method::Union{Symbol, Nothing} = nothing,
    resolution::Int = 200,
    reanalyze::Bool = true,
    gravity_factor::Quantity = GRAVITY,
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
    # ACI 318-11 §10.10.4.1 — cracked-stiffness reduction factor applied to concrete
    # beam sections only (threaded from params.beam_I_factor by the design workflow).
    # Default 0.35 keeps callers that do not pass it byte-identical.
    I_factor::Real = 0.35,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    # Slab concrete for AISC Chapter I when `SteelBeamOptions.composite` is set.
    # Ignored for concrete and PixelFrame beams, and when composite is false.
    # A `nothing` composite kwarg means "read it from the beam options".
    composite_concrete = nothing,
    composite_t_slab = nothing,
    composite_anchor = nothing,
    composite_shored = nothing,
    composite_cp_class = nothing,
    composite_slab_type = nothing,
    composite_deck_hr = nothing,
    composite_deck_wr = nothing,
    composite_deck_orientation = nothing,
    # Beam index → ShellBeamDemand from `analyze_story_shell`. Raises, never lowers.
    shell_demands = nothing,
    # Beam index → spans of the cracked service shell: `RCShellSpan`s for
    # concrete, `SteelShellSpan`s for steel. A separate deflection check on
    # discrete sizing; it never changes the frame-model deflection demand.
    shell_spans = nothing,
    # Group id → `(section = s, exact = Bool)`. Discrete steel, and rectangular
    # discrete concrete; see `_apply_section_floor`. `nothing` leaves every group free.
    section_floor = nothing,
    # `gid -> Bool`: size only the beam groups it accepts. `nothing` sizes every
    # beam group, one pass per framing level when framing exists
    # (see `_beam_sizing_passes`). Not specialized: each level's predicate is a
    # different closure, and specializing this function on each one recompiles it.
    @nospecialize(group_filter = nothing),
    # ENGINEERING JUDGMENT. `false` sizes shear as Vu ≤ φVc, with no stirrup
    # credit. The head-face pass uses it. The ordinary pass leaves it true:
    # ACI 318-11 §11.1.1 permits Vc + Vs.
    stirrup_shear::Bool = true,
    # ENGINEERING JUDGMENT (`DesignParameters.rib_head_stirrups`): whether a
    # story-depth rib piece that frames into a solid head is credited stirrups.
    rib_head_stirrups::Bool = true,
)
    dp = (hasproperty(struc, :design_parameters) && !isnothing(struc.design_parameters)) ?
         struc.design_parameters : nothing

    # Universal size-time gate backstop (Phase B fix cycle 4): when NO explicit
    # `member_group_overrides` kwarg is threaded, default it from the structure's
    # design parameters so any struc-only caller (`size_members!`, or a bare
    # `size_beams!(struc, ...)`) still reaches the honor-or-throw gid gate in
    # `_size_beams_impl!` rather than silently dropping an effective override. An
    # explicit non-`nothing` kwarg ALWAYS wins, so the `design_building` /
    # `redesign_incremental!` path (which threads `params.member_group_overrides`
    # explicitly) is UNCHANGED and byte-identical. `dp === nothing` / a missing /
    # `nothing` / empty field stays `nothing` → strict no-op. NOTE: as of this writing
    # `BuildingStructure` has NO `design_parameters` field (see
    # building_types/structure.jl) and it is never assigned in the SS source, so `dp`
    # is `nothing` here and this default is an inert backstop; the authoritative
    # universal coverage is the explicit thread at core/size.jl's `size!`.
    # (Engineering sizing knobs — no code citation.)
    if member_group_overrides === nothing && dp !== nothing &&
       hasproperty(dp, :member_group_overrides) &&
       !isnothing(dp.member_group_overrides) && !isempty(dp.member_group_overrides)
        member_group_overrides = dp.member_group_overrides
    end

    effective_opts = if !isnothing(opts)
        opts
    elseif !isnothing(dp) && !isnothing(dp.beams)
        dp.beams
    else
        obj = !isnothing(dp) ? resolve_objective(dp.optimize_for) : StructuralSizer.MinWeight()
        StructuralSizer.SteelBeamOptions(objective=obj)
    end

    # Resolve strategy: explicit `method` kwarg wins, else read from opts field
    strategy = if !isnothing(method)
        method
    elseif hasproperty(effective_opts, :sizing_strategy)
        effective_opts.sizing_strategy
    else
        :discrete
    end

    # Rib groups with a story depth go to the rib-line sizer, before the
    # girders they load. Every other group stays with the catalog sizer.
    owned = story_rib_groups(struc)
    rib_ids = sort!(UInt64[g for g in keys(owned)
                           if group_filter === nothing || group_filter(g)])
    if !isempty(owned) && group_filter !== nothing
        inner = group_filter
        group_filter = gid -> !haskey(owned, gid) && inner(gid)
    end
    if !isempty(rib_ids)
        size_rib_lines!(struc, rib_ids; fallback = effective_opts, resolution,
                        gravity_factor, I_factor, stirrup_shear, rib_head_stirrups)
        _reanalyze_after_section_change!(struc)
    end

    if group_filter === nothing
        passes = _beam_sizing_passes(struc, effective_opts)
        if length(passes) > 1
            for (k, pass) in enumerate(passes)
                # The caller's `method` and composite kwargs describe the
                # building-wide options. A level's own options carry theirs.
                own = pass.own
                # A level's own options carry method and composite settings.
                # Call the one-pass function, not size_beams!: a recursive call
                # makes inference chase this closure until subtype checking
                # does not finish.
                pass_method = own ? nothing : method
                pass_opts = pass.opts
                pass_strategy = if !isnothing(pass_method)
                    pass_method
                elseif hasproperty(pass_opts, :sizing_strategy)
                    pass_opts.sizing_strategy
                else
                    :discrete
                end
                _size_beams_one!(struc, pass_opts, pass_strategy;
                            resolution, reanalyze = false, gravity_factor,
                            member_group_overrides =
                                _overrides_in(member_group_overrides, pass.accept),
                            I_factor, tc, composite_concrete,
                            composite_t_slab = own ? nothing : composite_t_slab,
                            composite_anchor = own ? nothing : composite_anchor,
                            composite_shored = own ? nothing : composite_shored,
                            composite_cp_class = own ? nothing : composite_cp_class,
                            composite_slab_type = own ? nothing : composite_slab_type,
                            composite_deck_hr = own ? nothing : composite_deck_hr,
                            composite_deck_wr = own ? nothing : composite_deck_wr,
                            composite_deck_orientation =
                                own ? nothing : composite_deck_orientation,
                            shell_demands, shell_spans, section_floor,
                            group_filter = pass.accept, stirrup_shear)
                # The next pass reads forces from the sections just installed.
                # The cached unshored split was sampled before those sections.
                if k < length(passes) || reanalyze
                    mesh = _composite_mesh(struc)
                    mesh === nothing || _clear_unshored_stage!(mesh)
                    _reanalyze_after_section_change!(struc)
                end
            end
            _verify_tbeam_flanges(struc, nothing)
            return struc
        end
        # One pass left: it must still skip the story-owned ribs.
        isempty(owned) || (group_filter = only(passes).accept)
    end

    result = _size_beams_one!(struc, effective_opts, strategy;
                              resolution, reanalyze, gravity_factor,
                              member_group_overrides, I_factor, tc,
                              composite_concrete, composite_t_slab, composite_anchor,
                              composite_shored, composite_cp_class, composite_slab_type,
                              composite_deck_hr, composite_deck_wr, composite_deck_orientation,
                              shell_demands, shell_spans, section_floor, group_filter,
                              stirrup_shear)
    _verify_tbeam_flanges(struc, group_filter)
    # A single pass solves inside the sizer, before the solid-head sections
    # exist. The framing path solves through `_reanalyze_after_section_change!`,
    # which hangs them on the frame first.
    written = apply_solid_head_frame_sections!(struc)
    if reanalyze && !isempty(written) && !isempty(struc.asap_model.frame_elements)
        _reanalyze_after_section_change!(struc)
    end
    return result
end

"""One sizing pass. `group_filter` is not specialized: each level's predicate is a different closure."""
function _size_beams_one!(
    struc::BuildingStructure,
    effective_opts,
    strategy;
    resolution::Int = 200,
    reanalyze::Bool = true,
    gravity_factor::Quantity = GRAVITY,
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
    I_factor::Real = 0.35,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    composite_concrete = nothing,
    composite_t_slab = nothing,
    composite_anchor = nothing,
    composite_shored = nothing,
    composite_cp_class = nothing,
    composite_slab_type = nothing,
    composite_deck_hr = nothing,
    composite_deck_wr = nothing,
    composite_deck_orientation = nothing,
    shell_demands = nothing,
    shell_spans = nothing,
    section_floor = nothing,
    @nospecialize(group_filter = nothing),
    stirrup_shear::Bool = true,
)
    section_floor === nothing || _section_floor_supported(effective_opts, strategy) ||
        throw(ArgumentError(
            "section_floor applies to discrete steel beams and to rectangular " *
            "discrete concrete beams only"))
    StructuralSizer.emit!(tc, :sizing, "size_beams!", "", :enter;
                          opts_type=string(typeof(effective_opts)),
                          strategy=string(strategy))

    # `BuildingStructure` has no `design_parameters` field, so this branch does not
    # run. The live call is `_size_beams_columns!`, from `DesignParameters`.
    if hasproperty(struc, :design_parameters) && !isnothing(struc.design_parameters) && struc.design_parameters.collinear_grouping
        group_collinear_members!(struc; member_type=:beams)
    end

    # [P1 symmetric honor-path allowlist, fix cycle 8] The honor-or-throw contract
    # requires every EFFECTIVE member_group_overrides entry to be honored exactly OR
    # refused with a pinned `member_group_overrides` ArgumentError — never a silent drop
    # and never a bare MethodError. This allowlist is a NECESSARY-NOT-SUFFICIENT prefilter,
    # NOT "the single honoring path": it establishes only the three dispatch preconditions
    # that route to the size-time gid gate — steel opts + resolved `strategy == :discrete` +
    # `opts.sizing_strategy == :discrete`, which reaches
    # `_size_beams_impl!(::SteelBeamOptions, ::Val{:discrete})`. HONORABILITY ADDITIONALLY
    # requires `opts.n_max_sections == 0`, a single-material catalog, a non-composite demand,
    # and the target gid to be a REAL emitted beam group — all enforced downstream in the
    # size-time gid gate (see the MIRROR-PARITY INVARIANT there), not here. Every other
    # dispatch combination cannot honor an override: a non-:discrete
    # resolved `strategy` dispatches to a `Val` overload that either does not exist for
    # steel (`Val{:nlp}` → bare MethodError) or discards the mask; a non-:discrete
    # `opts.sizing_strategy` makes StructuralSizer branch its NLP path
    # (members/optimize/api.jl:123) INDEPENDENTLY of the Val dispatch and drop the mask;
    # and a non-steel opts type dispatches to a concrete / PixelFrame overload that
    # accepts-and-IGNORES the kwarg (a silent drop). The prior cycle-7 guard keyed on only
    # ONE input (`opts.sizing_strategy`), so a forced `method=:nlp` with the default
    # `opts.sizing_strategy=:discrete` slipped past it into the missing steel `Val{:nlp}`
    # overload (bare MethodError — a contract violation). Inverting that enumerated refusal
    # into a POSITIVE allowlist on the single real honoring path closes ALL THREE
    # nondeterministic dimensions — both `method` directions, pure :nlp, and non-steel opts
    # — in one condition, with no asymmetry left. Guarded by an effective-override check
    # (`has_eff`) so a no-override / vacuous (all-unset) dict stays byte-identical: the
    # allowlist is not triggered and control reaches the unchanged pre-fix dispatch (a pure
    # :nlp no-override call still raises the same MethodError as before; the normal
    # :discrete path is untouched). SteelBeamOptions always has `sizing_strategy`; the
    # `hasproperty` ternary is defensive. The message reports the actual opts type, resolved
    # strategy, and (if present) opts.sizing_strategy so a concrete / nlp / forced-method
    # call gets an accurate, material-correct diagnostic (fixes the cycle-7 steel-worded
    # misfire on a concrete-nlp direct call). (Engineering-scope guard — no code citation.)
    has_eff = member_group_overrides !== nothing &&
              any(o -> _is_effective(o), values(member_group_overrides))
    on_honor_path = (effective_opts isa StructuralSizer.SteelBeamOptions) &&
                    (strategy == :discrete) &&
                    (hasproperty(effective_opts, :sizing_strategy) ?
                        effective_opts.sizing_strategy == :discrete : false)
    if has_eff && !on_honor_path
        throw(ArgumentError(_mgo_refusal_message(
            "per-group overrides are honored only on the steel-discrete batched size_beams! " *
            "path (SteelBeamOptions with resolved strategy :discrete AND opts.sizing_strategy " *
            ":discrete), whose size-time gid gate carries the honor-or-throw contract; this " *
            "call has opts type $(typeof(effective_opts)) and resolved strategy :$(strategy)" *
            (hasproperty(effective_opts, :sizing_strategy) ?
                " with opts.sizing_strategy :$(effective_opts.sizing_strategy)" : "") *
            ". Any other opts type, resolved strategy, or opts.sizing_strategy routes to a " *
            "path that cannot honor the override — a missing steel Val{:nlp} overload " *
            "(MethodError), the StructuralSizer NLP branch (members/optimize/api.jl:123) that " *
            "ignores the catalog/feasible mask, or a non-steel overload that accepts and " *
            "drops the kwarg — so it is refused fail-loud")))
    end

    result = if effective_opts isa StructuralSizer.SteelBeamOptions
        _size_beams_impl!(struc, effective_opts, Val(strategy);
                          resolution, reanalyze, gravity_factor,
                          member_group_overrides, I_factor,
                          composite_concrete, composite_t_slab, composite_anchor,
                          composite_shored, composite_cp_class, composite_slab_type,
                          composite_deck_hr, composite_deck_wr, composite_deck_orientation,
                          shell_demands, shell_spans, section_floor, group_filter)
    elseif effective_opts isa StructuralSizer.ConcreteBeamOptions && strategy == :discrete
        _size_beams_impl!(struc, effective_opts, Val(strategy);
                          resolution, reanalyze, gravity_factor,
                          member_group_overrides, I_factor, shell_demands,
                          shell_spans, section_floor, group_filter, stirrup_shear)
    else
        _size_beams_impl!(struc, effective_opts, Val(strategy);
                          resolution, reanalyze, gravity_factor,
                          member_group_overrides, I_factor, shell_demands,
                          shell_spans, group_filter)
    end
    StructuralSizer.emit!(tc, :sizing, "size_beams!", "", :exit)
    return result
end

"""
One beam-sizing pass: `opts` for the groups `accept` keeps.

`accept === nothing` keeps every group. `own` is true when `opts` came from
`FramingLevel.beam_options` rather than the building-wide options, so the
caller's composite keyword arguments do not apply.
"""
struct _BeamSizingPass
    opts
    accept::Union{Nothing, Function}
    own::Bool
end

"""
    _beam_sizing_passes(struc, default_opts) -> Vector{_BeamSizingPass}

No materialized framing level: one pass over every beam group with
`default_opts`. That is the pre-framing path.

Materialized framing: one pass per framing level, from the slab outward
(level 1, then 2, …), then one pass for every group no level owns — the
primary girders, and any override aimed at a group that does not exist.
A level uses its `beam_options` when set and `default_opts` otherwise.
Levels at the same number that share the same options are one pass.

`n_max_sections` applies inside a pass, not across passes.
"""
function _beam_sizing_passes(struc::BuildingStructure, default_opts)
    levels = NamedTuple[]
    for slab in struc.slabs
        for fl in slab.framing_levels
            fl.group_id === nothing && continue
            # A level with a story rib depth is sized by `size_rib_lines!`.
            push!(levels, (level = fl.level, slab_idx = fl.slab_idx,
                           group_ids = level_group_ids(fl),
                           sizing_ids = fl.rib_stem === nothing ?
                                        level_sizing_group_ids(fl) : UInt64[],
                           beam_options = fl.beam_options))
        end
    end
    isempty(levels) && return [_BeamSizingPass(default_opts, nothing, false)]

    sort!(levels, by = fl -> (fl.level, fl.slab_idx))
    claimed = Set{UInt64}()
    passes = _BeamSizingPass[]
    i = 1
    while i <= length(levels)
        first = levels[i]
        own = first.beam_options !== nothing
        opts = own ? first.beam_options : default_opts
        groups = Set{UInt64}()
        while i <= length(levels)
            nxt = levels[i]
            nxt.level == first.level || break
            nxt_own = nxt.beam_options !== nothing
            nxt_own == own || break
            own && (nxt.beam_options === opts || break)
            union!(groups, nxt.sizing_ids)
            union!(claimed, nxt.group_ids)
            i += 1
        end
        accept = let g = groups
            gid -> gid in g
        end
        # A level whose ribs are all story-owned has nothing for the catalog.
        isempty(groups) || push!(passes, _BeamSizingPass(opts, accept, own))
    end
    # Groups no level claimed, including an override gid that matches nothing.
    rest = let c = claimed
        gid -> !(gid in c)
    end
    push!(passes, _BeamSizingPass(default_opts, rest, false))
    return passes
end

"""
    _beam_opts_by_group(struc, default_opts) -> Dict{UInt64, Any}

The beam options each sizing group actually uses. A framing level with its
own `beam_options` owns its groups; every other group uses `default_opts`.
The same split as [`_beam_sizing_passes`](@ref).
"""
function _beam_opts_by_group(struc::BuildingStructure, default_opts)
    out = Dict{UInt64, Any}()
    for pass in _beam_sizing_passes(struc, default_opts)
        for beam in struc.beams
            gid = group_id(beam)
            gid === nothing && continue
            pass.accept === nothing || pass.accept(gid) || continue
            out[gid] = pass.opts
        end
    end
    return out
end

"""Overrides whose group this pass sizes, or `nothing` when it sizes none."""
function _overrides_in(overrides, accept)
    overrides === nothing && return nothing
    accept === nothing && return overrides
    sub = Dict{UInt64, MemberGroupSizingOverride}()
    for (gid, ovr) in overrides
        accept(gid) && (sub[gid] = ovr)
    end
    return isempty(sub) ? nothing : sub
end

"""
Demands for the beam groups `accept` keeps. `nothing` keeps every beam group.
`service_deflection = false` skips the service deflection solve; pass it only
when no deflection limit applies.

On a floor with one-way concrete joists, each group's strength demand is the
larger of the frame solve and a solve with the joist ends pinned
([`_pinned_joist_releases`](@ref)). Service deflections are the frame solve's.
"""
function _beam_group_demands(struc::BuildingStructure, accept; resolution::Int,
                             shell_demands, service_deflection::Bool = true)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group = BEAM_GROUP_SYMBOLS,
                             resolution = resolution, shell_demands = shell_demands,
                             service_deflection = service_deflection)
    releases = _pinned_joist_releases(struc)
    if !isempty(releases)
        pinned_ids, pinned = _with_pinned_joists(struc, releases) do
            member_group_demands(struc; member_edge_group = BEAM_GROUP_SYMBOLS,
                                 resolution = resolution, service_deflection = false)[1:2]
        end
        pinned_ids == group_ids || error(
            "pinned-joist solve returned different beam groups than the frame solve")
        demands = [_envelope_demand(a, b) for (a, b) in zip(demands, pinned)]
    end
    accept === nothing &&
        return group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs
    keep = [i for (i, gid) in enumerate(group_ids) if accept(gid)]
    return group_ids[keep], demands[keep], L_totals[keep], Lb_govs[keep],
           Cb_govs[keep], Kx_govs[keep], Ky_govs[keep]
end

# --- Steel beams (discrete) — calls public StructuralSizer.size_beams ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelBeamOptions,
    ::Val{:discrete};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
    # Accepted for the uniform `size_beams!` dispatch but inert here: the cracked-stiffness
    # I_factor (ACI 318-11 §10.10.4.1) applies to concrete sections only, and this is the
    # steel path. `_apply_beam_results!` branches per group material, so steel groups never
    # pass I_factor to to_asap_section regardless of this value.
    I_factor::Real = 0.35,
    composite_concrete = nothing,
    composite_t_slab = nothing,
    composite_anchor = nothing,
    composite_shored = nothing,
    composite_cp_class = nothing,
    composite_slab_type = nothing,
    composite_deck_hr = nothing,
    composite_deck_wr = nothing,
    composite_deck_orientation = nothing,
    # Pass 1 searches the catalog on the steel model. Pass 2 confirms that
    # one section on the composite deflection. The catalog runs again only
    # when the confirmation fails, and a changed section is confirmed once.
    # `composite_solved_search` is the one open search after the same steel
    # section, with a heavier stud layout, still misses its solved deflection.
    composite_pass::Int = 1,
    prior_section_keys = nothing,
    composite_lock::Bool = false,
    composite_solved_search::Bool = false,
    # Searches already run after a rejected confirmation; see `_composite_ratchet_floors`.
    composite_ratchet::Int = 0,
    shell_demands = nothing,
    shell_spans = nothing,
    section_floor = nothing,
    @nospecialize(group_filter = nothing),
)
    if opts.composite && composite_anchor === nothing
        composite_anchor_from_options(opts)
    end
    # A pass after the fallback confirms one section. It does not search.
    composite_lock = composite_lock || composite_pass > 2
    skel = struc.skeleton
    edge_ids_in_group = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids_in_group, get(skel.groups_edges, g, Int[]))
    end
    # Later passes already carry the self-weight moved onto the child elements.
    composite_pass == 1 && _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    has_limit = opts.deflection_limit !== nothing || opts.total_deflection_limit !== nothing
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        _beam_group_demands(struc, group_filter; resolution, shell_demands,
                            service_deflection = has_limit)

    # DEFINITIVE size-time gid gate (Run 4 / Phase B, [P1-2] + [P2-3]). `group_ids`
    # here is the REAL steel-beam group set the sizer actually emits: collinear-MERGED
    # (`group_collinear_members!` ran in `_size_beams_columns!` before this call
    # when `collinear_grouping` is set) AND
    # par_has-FILTERED (`member_group_demands` drops groups with no segment on a
    # :beams edge). Every EFFECTIVE `member_group_overrides` entry MUST target one of
    # these gids — anything else can never be honored on this path and would be
    # SILENTLY DROPPED, so we refuse fail-loud (pinned `member_group_overrides`
    # ArgumentError) BEFORE any BuildingDesign is produced. Runs BEFORE the empty-group
    # early return so an override under a floor that emits NO steel beam group (every
    # beam par_has-absent) is refused too, never silently dropped. This single gate:
    #   [P1-2] a collinear beam gid IS in `group_ids` → HONORED (no unreliable
    #          door-side reproduction of collinear grouping is needed);
    #   [P2-3] a par_has-absent beam gid is NOT in `group_ids` → REFUSED (no silent drop);
    #   a column / strut gid, or any unknown / garbage gid, is NOT in `group_ids` → REFUSED.
    # Fires on ALL BuildingDesign-producing paths that size beams (from-scratch
    # `design_building` and incremental `redesign_incremental!` both route
    # `_size_beams_columns!` → `size_beams!` → here). (Engineering-scope guard —
    # catalog / deflection_limit / max_depth are sizing knobs, no code citation.)
    if member_group_overrides !== nothing
        # MIRROR-PARITY INVARIANT (Phase B). Every front-door refusal in
        # `_assert_member_group_overrides_unsupported` (design_types.jl) that guards an
        # EFFECTIVE per-group override has a size-time backstop so a DIRECT caller who
        # bypasses the params front door (e.g. a bare `size_beams!` / `_size_beams_impl!`)
        # is still refused fail-loud — never silently dropped, never mis-honored. Front-door
        # check → size-time backstop:
        #   (1)  floor-type never sizes beams per-group → refused pre-sizing at the
        #        floor-type-determinable doors (design_building / size! / redesign / vary).
        #   (2)  non-steel beam opts → the `size_beams!` cycle-8 honor-path allowlist.
        #   (3)  n_max_sections > 0 (couples member groups) → THIS gate (cycle 9, below).
        #   (4)  multi-material catalog → THIS gate (the multi-material mirror below).
        #   (4b) sizing_strategy != :discrete → the `size_beams!` allowlist AND THIS gate
        #        (the 4b mirror below).
        #   (5)  looser deflection_limit / max_depth → THIS gate (per-gid loop below).
        #   composite demand → THIS gate (`_assert_no_composite_override`); gid membership
        #        → THIS gate (the `honorable_beam_gids` check). These two have no front-door
        #        analog — both need the real size-time `group_ids` / demands in scope here.
        # INVARIANT: no front-door refusal may exist without a size-time backstop here, so a
        # direct caller can never bypass the honor-or-throw contract.
        # (Engineering-scope guard — no code citation.)
        #
        # [P1 coupling mirror, fix cycle 9] Mirror front-door check (3)
        # (`_assert_member_group_overrides_unsupported`, design_types.jl:644): steel beam
        # options that set `n_max_sections > 0` COUPLE member groups — the shared-section MIP
        # constrains all groups to at most n_max distinct sections, so per-group feasible
        # narrowing is NOT exact-first-safe. `_beam_override_union_and_feasible` builds a
        # per-group mask that assumes each group is sized INDEPENDENTLY, but with a
        # section-count cap the coupled MIP could force a masked group's choice onto a
        # coupled group and mis-honor the per-group override (the SZ layer itself refuses this
        # combination with a bare ArgumentError, discrete_mip.jl:224 — but that message is not
        # pinned to `member_group_overrides`). Refuse fail-loud (pinned
        # `member_group_overrides` ArgumentError) so this path is unreachable even if a caller
        # skips the front-door guard, exactly as the multi-material mirror (#4) below
        # backstops a caller that skips the front door. Placed BEFORE
        # `_beam_override_union_and_feasible` is called / the mask is built, so the coupled MIP
        # is never reached with an effective override. `n_max_sections == 0` (the default) is
        # untouched → byte-identical. Guarded by an effective-override check so an
        # empty/vacuous dict stays a strict no-op. (Engineering-scope guard — no code
        # citation.)
        if opts.n_max_sections > 0 &&
                any(o -> _is_effective(o), values(member_group_overrides))
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set n_max_sections=$(opts.n_max_sections) > 0, which " *
                "couples member groups so per-group feasible narrowing is not " *
                "exact-first-safe; the batched size_beams! mask assumes independent " *
                "per-group sizing, but the coupled shared-section MIP would mis-honor the " *
                "per-group override, so Phase B refuses rather than mis-honor")))
        end
        # [P1/P2 defense-in-depth, fix cycle 5] Mirror front-door check 4
        # (`_assert_member_group_overrides_unsupported`, design_types.jl:648): a
        # MULTI-material steel catalog (`opts.materials !== nothing`) routes
        # `size_beams` → `size_columns` through the MULTI-material `optimize_discrete`,
        # whose `feasible` mask is EXPANDED-index space (k = (m-1)*n_sec + j). But
        # `_beam_override_union_and_feasible` builds a SINGLE-material-space mask
        # (indices 1..length(union_cat)); the multi-material solver would silently
        # reinterpret it as material-1-only (every index ≤ n_sec passes the hard range
        # check), collapsing the whole optimization to material 1. Refuse fail-loud
        # (pinned `member_group_overrides` ArgumentError) so this path is unreachable
        # even if a caller skips the front-door guard. Single-material
        # (`opts.materials === nothing`) is untouched → byte-identical. Guarded by an
        # effective-override check so an empty/vacuous dict stays a strict no-op.
        # (Engineering-scope guard — no code citation.)
        if opts.materials !== nothing &&
                any(o -> _is_effective(o), values(member_group_overrides))
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set a multi-material catalog (opts.materials); the " *
                "batched per-group feasible mask is single-material-space (1..n_sec) " *
                "while the multi-material optimize_discrete expects expanded indices " *
                "k = (m-1)*n_sec + j, so an override mask would be silently reinterpreted " *
                "as material-1-only and collapse the optimization; Phase B refuses " *
                "multi-material overrides on this batched path")))
        end
        # [P1/P2 silent-drop mirror, fix cycle 7] Mirror front-door check (4b)
        # (`_assert_member_group_overrides_unsupported`, design_types.jl:657) and the
        # `size_beams!` pre-dispatch guard, keyed on `opts.sizing_strategy != :discrete`.
        # This IS the :discrete `_size_beams_impl!` overload, so the `Val` dispatch that
        # reached here is `:discrete` — but a caller can force `method=:discrete` while
        # leaving `opts.sizing_strategy=:nlp`, and `StructuralSizer.size_beams` branches the
        # NLP path on `opts.sizing_strategy` INDEPENDENTLY of this dispatch
        # (members/optimize/api.jl:123), ignoring the catalog/feasible mask → silent drop.
        # Belt-and-suspenders: the PRIMARY refusal is the `size_beams!` guard above, but
        # this backstops a DIRECT `_size_beams_impl!(..., ::Val{:discrete})` call that skips
        # it, exactly as the multi-material mirror (#4) above backstops a caller that skips
        # the front door, and it also protects a future accept-and-drop steel `Val{:nlp}`
        # overload. Guarded by an effective-override check so a vacuous dict stays a strict
        # no-op. (Engineering-scope guard — no code citation.)
        if opts.sizing_strategy != :discrete &&
                any(o -> _is_effective(o), values(member_group_overrides))
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set sizing_strategy=:$(opts.sizing_strategy); per-group " *
                "overrides are honored only on the steel-discrete batched size_beams! path. " *
                "A non-:discrete strategy routes through the StructuralSizer NLP path " *
                "(members/optimize/api.jl:123), which branches on opts.sizing_strategy " *
                "independently of the Val dispatch and ignores the catalog/feasible mask, so " *
                "the per-group override would be silently dropped")))
        end
        honorable_beam_gids = Set(group_ids)
        for (gid, ovr) in member_group_overrides
            _is_effective(ovr) || continue
            gid in honorable_beam_gids || throw(ArgumentError(_mgo_refusal_message(
                "override targets member group $(gid), which is NOT among the " *
                "$(length(honorable_beam_gids)) steel beam groups the batched " *
                "size_beams! path emits at size time (collinear-merged and " *
                "par_has-filtered); a column / strut group, an unknown gid, or a beam " *
                "group with no segment on a :beams edge is not sized per-group here and " *
                "would be silently dropped")))
            # [P2 looser-knob, fix cycle 6] Mirror front-door check 5
            # (`_assert_member_group_overrides_unsupported`, design_types.jl): a per-group
            # knob set LOOSER than the global steel-beam knob is a SILENT NO-OP on this
            # batched path — `_beam_override_union_and_feasible` always INTERSECTS the
            # per-group feasible mask with the GLOBAL AISCChecker screening, so a per-group
            # knob can only ever TIGHTEN a group; a looser knob is silently clamped by the
            # global screening (structurally conservative, but violates honor-or-throw). A
            # DIRECT `size_beams!(struc, opts; member_group_overrides=...)` — or a
            # `run_target!` that bypasses the `redesign_incremental!` wrapper guard — skips
            # the front door, so this size-time gate must re-check looseness itself. Units
            # match the front door EXACTLY: `deflection_limit` is a dimensionless L/δ RATIO,
            # so LOOSER means a numerically LARGER ratio (a `nothing` global limit is the
            # loosest possible, so any finite per-group ratio is then a honored tightening);
            # `max_depth` is a Unitful length cap, LOOSER means LARGER. A tightening or equal
            # knob stays HONORED (byte-identical). (Engineering-scope guard — no code citation.)
            if ovr.deflection_limit !== nothing && opts.deflection_limit !== nothing &&
                    ovr.deflection_limit > opts.deflection_limit
                throw(ArgumentError(_mgo_refusal_message(
                    "override on beam group $(gid) sets deflection_limit=$(ovr.deflection_limit), " *
                    "LOOSER than the global deflection_limit=$(opts.deflection_limit) (larger " *
                    "L/δ ratio); the batched size_beams! mask can only tighten, so a looser " *
                    "per-group limit would be silently ignored")))
            end
            if ovr.max_depth !== nothing && ovr.max_depth > opts.max_depth
                throw(ArgumentError(_mgo_refusal_message(
                    "override on beam group $(gid) sets max_depth=$(ovr.max_depth), LOOSER " *
                    "than the global max_depth=$(opts.max_depth); the batched size_beams! " *
                    "mask can only tighten, so a looser per-group cap would be silently " *
                    "ignored")))
            end
        end

        # Phase B is STEEL-beam-only: a bare-steel Ix mask must never be applied to a
        # COMPOSITE beam demand (whose code check uses I_LB, AISC 360-16 Commentary
        # I3.2). Refuse fail-loud rather than over-restrict. Also fires when
        # `opts.composite` enables the Chapter I sentinel on the size_beams call
        # below (demands from `member_group_demands` still carry composite=nothing).
        _assert_no_composite_override(group_ids, demands, member_group_overrides;
                                      opts_composite=opts.composite)
    end

    isempty(group_ids) && return struc

    geometries = [StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)
                  for (L, Lb, Cb, Kx, Ky) in zip(L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)]

    Mu_vec = [d.Mux for d in demands]
    Mux_pos_vec = [d.Mux_pos for d in demands]
    Mux_neg_vec = [d.Mux_neg for d in demands]
    Vu_vec = [d.Vu_strong for d in demands]
    # Analysis Pu_c (compression magnitude, SI N) → size_beams `Pu=` for H1 when > 0.
    # Pu_t is the tension magnitude. AISC 360-16 §H1.1 (compression + flexure,
    # corpus: aisc-360-16, page 133) and §H1.2 (flexure + tension, same equations,
    # Pc = φt·Pn, page 134).
    Pu_vec = [d.Pu_c * u"N" for d in demands]
    Pu_t_vec = [d.Pu_t * u"N" for d in demands]
    δ_LL_vec   = [d.δ_max_LL for d in demands]
    δ_total_vec = [d.δ_max_total for d in demands]
    I_ref_v  = [d.I_ref for d in demands]
    _require_service_deflections(demands, group_ids, has_limit)

    # `SteelBeamOptions.composite` builds one PerStationComposite per group from
    # the per-side tributary profiles and the exact moment field. The checker
    # re-solves the sagging station for each candidate section. The Bool
    # sentinel is only the fallback when composite is off.
    composite_kw = if opts.composite
        anchor = composite_anchor === nothing ?
            composite_anchor_from_options(opts) : composite_anchor
        t_slab = composite_t_slab === nothing ? opts.composite_t_slab : composite_t_slab
        shored = composite_shored === nothing ? opts.composite_shored : composite_shored
        cp = composite_cp_class === nothing ? opts.composite_cp_class : composite_cp_class
        slab_type = composite_slab_type === nothing ? opts.composite_slab_type : composite_slab_type
        hr = composite_deck_hr === nothing ? composite_deck_hr_wr(opts).hr : composite_deck_hr
        wr = composite_deck_wr === nothing ? composite_deck_hr_wr(opts).wr : composite_deck_wr
        orient = composite_deck_orientation === nothing ?
            opts.composite_deck_orientation : composite_deck_orientation
        composite_payloads_for_groups(
            struc, group_ids, L_totals, composite_concrete, opts.material.E;
            t_slab = t_slab, anchor = anchor, shored = shored, cp_class = cp,
            slab_type = slab_type, deck_hr = hr, deck_wr = wr,
            deck_orientation = orient,
            deck_e_mid_ht = opts.composite_deck_e_mid_ht,
            deck_anchorage_spacing = opts.composite_deck_anchorage_spacing,
            deck_pitch = slab_type === :deck ? composite_deck_pitch(opts) : nothing,
            L_twist = opts.composite_twist_spacing,
            deck_attachment = deck_attachment_from_options(opts),
            d_rebar = opts.composite_d_rebar === nothing ? 0.0u"m" : opts.composite_d_rebar,
            shell_fields = _shell_moment_fields_by_beam(shell_demands),
            # The confirmation uses the solved deflection. The search after the
            # first failed confirmation still scales by inertia, so a stiffer
            # section or more studs on the same section can clear it. The one
            # search after that same section's studs still miss uses the solved
            # deflection, and its studs stay the strength layout.
            variable_inertia = composite_lock || composite_pass > 2 ||
                               composite_solved_search)
    else
        nothing
    end
    # Same δ, I_ref, span, and limits the checker just used for I_need.
    service_needs = composite_kw === nothing ? nothing :
        _composite_install_service(demands, geometries, opts, composite_kw)

    # Honor per-group restrictions on STEEL beam groups from an EFFECTIVE
    # per-design `member_group_overrides` entry. The batched call uses a UNION
    # catalog and a per-group `feasible` mask (see
    # `_beam_override_union_and_feasible`). A framing level's catalog is its
    # `beam_options`, not a field on the group. Every group with no effective
    # override keeps the full default catalog. With no effective override we
    # take the unmasked path (feasible === nothing).
    has_eff_override =
        member_group_overrides !== nothing &&
        any(gid -> (o = get(member_group_overrides, gid, nothing)) !== nothing &&
                   _is_effective(o), group_ids)

    # Confirmation checks the section already on the beam and does not
    # walk the catalog. That takes precedence over a per-group override
    # mask: the question is whether this solved section passes.
    catalog_kw, feasible_kw = if composite_lock
        _composite_lock_catalog(struc, group_ids)
    elseif has_eff_override
        _beam_override_union_and_feasible(
            struc, opts, group_ids, L_totals, δ_LL_vec, I_ref_v, member_group_overrides)
    else
        nothing, nothing
    end
    if !composite_lock && section_floor !== nothing
        catalog_kw, feasible_kw = _apply_section_floor(opts, group_ids, catalog_kw,
                                                       feasible_kw, section_floor)
    end
    result = StructuralSizer.size_beams(
        Mu_vec, Vu_vec, geometries, opts;
        Pu = Pu_vec, Pu_t = Pu_t_vec,
        Mux_pos = Mux_pos_vec, Mux_neg = Mux_neg_vec,
        δ_max_vec = any(>(0), δ_LL_vec)   ? δ_LL_vec   : nothing,
        δ_max_total_vec = any(>(0), δ_total_vec) ? δ_total_vec : nothing,
        I_ref_vec = any(>(0), I_ref_v)    ? I_ref_v    : nothing,
        catalog = catalog_kw,
        feasible = feasible_kw,
        composite = composite_kw,
        shell_spans = _group_shell_spans(struc, group_ids, shell_spans,
                                         StructuralSizer.SteelShellSpan),
    )

    member_array = struc.beams
    mat = opts.material
    _apply_beam_results!(struc, result, group_ids, member_array, edge_ids_in_group, mat)

    # invokelatest: this closure calls the function that created it. A direct
    # call makes inference of this pass include itself until subtype checking
    # does not finish.
    again = function (; pass, keys, lock = false, solved_search = false,
                      floor = section_floor, ratchet = composite_ratchet)
        Base.invokelatest(_size_beams_impl!, struc, opts, Val(:discrete);
                          resolution, reanalyze, gravity_factor,
                          member_group_overrides, I_factor,
                          composite_concrete, composite_t_slab, composite_anchor,
                          composite_shored, composite_cp_class, composite_slab_type,
                          composite_deck_hr, composite_deck_wr,
                          composite_deck_orientation,
                          composite_pass = pass, prior_section_keys = keys,
                          composite_lock = lock,
                          composite_solved_search = solved_search,
                          composite_ratchet = ratchet,
                          shell_demands, shell_spans,
                          section_floor = floor, group_filter)
    end
    # A reselected section is confirmed on its own solved model. A stiffer
    # section draws more moment, so it can still miss. Then every group keeps
    # at least its current section and the catalog is searched again on the
    # solved deflection. The rejected group has to move up, so this ends.
    confirm = function (keys)
        try
            return again(; pass = 3, keys = keys, lock = true)
        catch e
            _composite_lock_rejected(e) || rethrow()
            floors = _composite_ratchet_floors(struc, opts, group_ids, section_floor,
                                               composite_ratchet)
            floors === nothing && rethrow()
            return again(; pass = 2, keys = keys, lock = false, solved_search = true,
                         floor = floors, ratchet = composite_ratchet + 1)
        end
    end

    shored_now = composite_shored === nothing ? opts.composite_shored : composite_shored
    if opts.composite && composite_kw !== nothing && composite_pass == 1
        installed = _install_composite_analysis!(struc, result, group_ids, composite_kw,
                                                 opts.material, shored_now;
                                                 resolution = resolution,
                                                 service = service_needs)
        if installed
            _note_composite_section_pass!(struc, 1, result.sections)
            keys = _section_choice_keys(result.sections)
            # Confirm that section on its own composite deflection. Search
            # the catalog again only when the confirmation fails.
            try
                return again(; pass = 2, keys = keys, lock = true)
            catch e
                _composite_lock_rejected(e) || rethrow()
                return again(; pass = 2, keys = keys, lock = false)
            end
        end
    elseif opts.composite && composite_kw !== nothing && composite_pass == 2
        keys_now = _section_choice_keys(result.sections)
        changed = prior_section_keys !== nothing && keys_now != prior_section_keys
        if composite_lock
            changed && throw(ArgumentError(
                "Composite confirmation returned a different section"))
            # Same section, already solved at install. Put the zero parent
            # back. The stage cache and the composite stiffness stay.
            _restore_composite_parents!(struc)
            _note_composite_section_pass!(struc, 2, result.sections)
            if reanalyze
                Asap.update!(struc.asap_model; values_only = true)
                _solve_struc_model!(struc)
            end
        elseif composite_solved_search
            # Solved deflection, catalog open. A heavier steel section can
            # pass here. The same section already failed this check.
            if !changed
                throw(ArgumentError(
                    "No feasible sections: the composite confirmation rejected " *
                    "this section, and the solved-deflection search did not find another"))
            end
            _reanalyze_changed_composite!(struc, result, group_ids, composite_kw,
                                          opts.material, shored_now;
                                          resolution = resolution,
                                          service = service_needs)
            _note_composite_section_pass!(struc, 2, result.sections)
            # Pass 3 is locked by `composite_pass > 2`.
            return confirm(keys_now)
        elseif changed
            # The confirmation failed and the catalog chose another section.
            # Solve that section, then check it alone.
            _reanalyze_changed_composite!(struc, result, group_ids, composite_kw,
                                          opts.material, shored_now;
                                          resolution = resolution,
                                          service = service_needs)
            _note_composite_section_pass!(struc, 2, result.sections)
            return confirm(keys_now)
        else
            # Same steel section. The scaling search asked for a heavier stud
            # layout. Those studs are the design: install them and confirm on
            # the solved deflection.
            _reanalyze_changed_composite!(struc, result, group_ids, composite_kw,
                                          opts.material, shored_now;
                                          resolution = resolution,
                                          service = service_needs)
            try
                return again(; pass = 2, keys = keys_now, lock = true)
            catch e
                _composite_lock_rejected(e) || rethrow()
                # One open search on the solved deflection. Pass 3 would lock
                # the catalog, so this stays pass 2 with the flag set.
                return again(; pass = 2, keys = keys_now, lock = false,
                             solved_search = true)
            end
        end
    elseif opts.composite && composite_kw !== nothing && composite_pass > 2
        _restore_composite_parents!(struc)
        _note_composite_section_pass!(struc, composite_pass, result.sections)
        if reanalyze
            Asap.update!(struc.asap_model; values_only = true)
            _solve_struc_model!(struc)
        end
    elseif reanalyze
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
    end

    @info "Sized $(length(group_ids)) steel beam groups via size_beams API"
    return struc
end

"""Beam index → its story-shell moment fields, or `nothing` when there are none."""
function _shell_moment_fields_by_beam(shell_demands)
    shell_demands === nothing && return nothing
    out = Dict{Int, Vector{ShellMomentField}}()
    for (i, d) in shell_demands
        isempty(d.moment_fields) || (out[i] = d.moment_fields)
    end
    return isempty(out) ? nothing : out
end

"""Steel NLP has no Chapter I path. A missing stud field is reported before that."""
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelBeamOptions,
    ::Val{:nlp};
    kwargs...,
)
    if opts.composite
        composite_anchor_from_options(opts)
        throw(ArgumentError(
            "Composite steel beam sizing runs on sizing_strategy=:discrete. " *
            "The NLP path does not run the Chapter I check."))
    end
    throw(MethodError(_size_beams_impl!, (struc, opts, Val(:nlp))))
end

# --- Per-group override narrowing for the batched steel-beam path (Run 4 / Phase B) ---
#
# Stable identity key for a catalog section (W-shapes carry a unique `name`).
_beam_sec_key(s) = (nameof(typeof(s)),
                    (hasproperty(s, :name) && getfield(s, :name) !== nothing) ?
                        getfield(s, :name) : objectid(s))

_section_choice_key(::Nothing) = nothing
_section_choice_key(s) = _beam_sec_key(s)
_section_choice_keys(sections) = [_section_choice_key(s) for s in sections]

"""Catalog holding only the section already on each beam group.

The confirmation pass asks whether that solved section passes. It does
not lay out studs for the rest of the catalog.
"""
function _composite_lock_catalog(struc::BuildingStructure, group_ids)
    chosen = Vector{Any}(undef, length(group_ids))
    for (i, gid) in enumerate(group_ids)
        mg = struc.member_groups[gid]
        isempty(mg.member_indices) && throw(ArgumentError(
            "Composite confirmation has no beam in group $gid"))
        sec = section(struc.beams[mg.member_indices[1]])
        sec === nothing && throw(ArgumentError(
            "Composite confirmation has no section on group $gid"))
        chosen[i] = sec
    end
    # Concrete element type: optimize_discrete requires AbstractVector{<:AbstractSection}.
    sectype = mapreduce(typeof, typejoin, chosen)
    catalog = Vector{sectype}()
    feasible = Vector{Vector{Int}}(undef, length(chosen))
    for (i, sec) in enumerate(chosen)
        j = findfirst(s -> _field_identical(s, sec), catalog)
        if j === nothing
            push!(catalog, sec)
            j = length(catalog)
        end
        feasible[i] = Int[j]
    end
    return catalog, feasible
end

"""Objective of `s` per unit length under `opts`, the order the catalog search minimizes."""
_section_objective(opts, s) =
    StructuralSizer.objective_value(opts.objective, s, opts.material, 1.0u"m")

"""
    _section_floor_supported(opts, strategy) -> Bool

`section_floor` is honored for discrete steel beams and for rectangular
discrete concrete beams. T-beams, NLP, and other materials are not.
"""
function _section_floor_supported(opts, strategy)
    strategy == :discrete || return false
    opts isa StructuralSizer.SteelBeamOptions && return true
    return opts isa StructuralSizer.ConcreteBeamOptions && !opts.include_flange
end

"""
    _apply_section_floor(opts, group_ids, catalog, feasible, floors) -> (catalog, feasible)

Narrow each floored group's candidates. A floor `(section = s, exact = false)`
keeps `s` and every section whose objective is strictly greater; the search
then keeps `s` while it passes and otherwise takes the lightest heavier
section that does. `exact = true` keeps `s` alone. A section of equal
objective never replaces a passing `s`. Groups without a floor are unchanged.

The mask only narrows: every candidate still goes through the full checker.
Groups are sized independently here, so `n_max_sections` and multi-material
catalogs are refused. Concrete T-beams are refused: their catalog is a web
plus a flange, not this rectangular list.
"""
function _apply_section_floor(opts::StructuralSizer.SteelBeamOptions, group_ids,
                              catalog, feasible, floors)
    opts.n_max_sections == 0 || throw(ArgumentError(
        "section_floor needs n_max_sections = 0: a shared-section cap couples the groups"))
    opts.materials === nothing || throw(ArgumentError(
        "section_floor needs a single-material catalog"))
    cat = catalog === nothing ?
        (opts.custom_catalog === nothing ?
            StructuralSizer.steel_column_catalog(opts.section_type, opts.catalog) :
            opts.custom_catalog) :
        catalog
    return _narrow_to_section_floor(opts, group_ids, cat, feasible, floors)
end

function _apply_section_floor(opts::StructuralSizer.ConcreteBeamOptions, group_ids,
                              catalog, feasible, floors)
    opts.n_max_sections == 0 || throw(ArgumentError(
        "section_floor needs n_max_sections = 0: a shared-section cap couples the groups"))
    opts.materials === nothing || throw(ArgumentError(
        "section_floor needs a single-material catalog"))
    opts.include_flange && throw(ArgumentError(
        "section_floor does not apply to T-beam sizing"))
    cat = catalog === nothing ?
        (opts.custom_catalog === nothing ?
            StructuralSizer.rc_beam_catalog(opts.catalog) :
            opts.custom_catalog) :
        catalog
    return _narrow_to_section_floor(opts, group_ids, cat, feasible, floors)
end

"Keep each floor section and, unless the floor is exact, every strictly heavier one."
function _narrow_to_section_floor(opts, group_ids, cat, feasible, floors)
    obj = [_section_objective(opts, s) for s in cat]
    out = feasible === nothing ? [collect(eachindex(cat)) for _ in group_ids] :
                                 [copy(f) for f in feasible]
    for (i, gid) in enumerate(group_ids)
        fl = get(floors, gid, nothing)
        fl === nothing && continue
        o_floor = _section_objective(opts, fl.section)
        filter!(out[i]) do j
            _sections_identical(cat[j], fl.section) ||
                (!fl.exact && obj[j] > o_floor * (1 + 1e-9))
        end
    end
    return cat, out
end

"""
Size rectangular concrete beams. With `section_floor`, each group keeps its
floor or a strictly heavier section. A named catalog grows one tier when
nothing in that set passes; a feasibility mask would otherwise stop that
growth. Without a floor, a row-F frame floor is applied exactly as before.
"""
function _rectangular_rc_beam_result(struc, opts, group_ids, Mu, Vu, Mu_neg, Nu,
                                    geoms, shell_spans, section_floor)
    has_frame = any(gid -> haskey(struc.frame_section_floors, gid), group_ids)
    if has_frame
        (opts.materials === nothing && opts.n_max_sections == 0) ||
            _refuse_frame_floors(struc, group_ids, "this concrete beam sizing")
    end
    objective_of = s -> StructuralSizer.objective_value(opts.objective, s, opts.material, 1.0u"m")
    if section_floor === nothing
        floor_kw = (;)
        if has_frame
            cat = isnothing(opts.custom_catalog) ?
                StructuralSizer.rc_beam_catalog(opts.catalog) : opts.custom_catalog
            floor_kw = (; catalog = cat,
                        feasible = _frame_floor_mask(struc, group_ids, cat, objective_of))
        end
        return StructuralSizer.size_beams(Mu, Vu, geoms, opts; Mu_neg = Mu_neg, Nu = Nu,
                                          shell_spans = shell_spans, floor_kw...)
    end

    tier = (opts.catalog_constraint === :soft && opts.custom_catalog === nothing) ?
        opts.catalog : nothing
    cat = opts.custom_catalog === nothing ?
        StructuralSizer.rc_beam_catalog(opts.catalog) : opts.custom_catalog
    while true
        frame_feasible = has_frame ?
            _frame_floor_mask(struc, group_ids, cat, objective_of) : nothing
        catalog_kw, feasible_kw = _apply_section_floor(opts, group_ids, cat,
                                                       frame_feasible, section_floor)
        try
            return StructuralSizer.size_beams(Mu, Vu, geoms, opts; Mu_neg = Mu_neg, Nu = Nu,
                                              shell_spans = shell_spans,
                                              catalog = catalog_kw, feasible = feasible_kw)
        catch e
            grown = tier isa Symbol ? StructuralSizer.grow_rc_beam_catalog(cat, tier) : nothing
            (grown !== nothing && e isa ArgumentError &&
                startswith(e.msg, "No feasible sections for group")) || rethrow()
            cat, nxt = grown
            depth_in = round(Int, ustrip(u"inch", maximum(s -> s.h, cat)))
            @warn "RC beam sizing: no section in the :$tier catalog passes the section floor; " *
                  "retrying with :$nxt added (depths to $(depth_in) in)." reason = e.msg
            tier = nxt
        end
    end
end

"""
    _frame_floor_mask(struc, group_ids, catalog, objective_of) -> Union{Nothing, Vector{Vector{Int}}}

`struc.frame_section_floors` as a per-group catalog mask. A floored group
keeps its floor section and every section whose objective is strictly
greater. The optimizer still checks each one against the group's own demands.
`nothing` when no group in `group_ids` has a floor.
"""
function _frame_floor_mask(struc, group_ids, catalog, objective_of)
    floors = struc.frame_section_floors
    any(gid -> haskey(floors, gid), group_ids) || return nothing
    obj = [objective_of(s) for s in catalog]
    out = Vector{Vector{Int}}(undef, length(group_ids))
    for (i, gid) in enumerate(group_ids)
        fl = get(floors, gid, nothing)
        if fl === nothing
            out[i] = collect(eachindex(catalog))
            continue
        end
        o_floor = objective_of(fl)
        same = [j for j in eachindex(catalog) if _sections_identical(catalog[j], fl)]
        if isempty(same)
            _refuse_frame_floors(struc, [gid],
                "this sizing catalog (the row F floor is not in it)")
        end
        out[i] = sort!(union(same, [j for j in eachindex(catalog)
                                    if obj[j] > o_floor * (1 + 1e-9)]))
    end
    return out
end

"""Refuse a sizing path that cannot keep the row F section floors of `group_ids`."""
function _refuse_frame_floors(struc, group_ids, path::AbstractString)
    for gid in group_ids
        haskey(struc.frame_section_floors, gid) || continue
        throw(ArgumentError(
            "member group $gid has a row F section floor, and $path cannot keep it. " *
            "Use :discrete sizing with a single-material catalog and n_max_sections = 0."))
    end
    return nothing
end

_composite_lock_rejected(::Any) = false
_composite_lock_rejected(e::ArgumentError) = occursin("No feasible sections", e.msg)

"""Searches allowed after rejected composite confirmations before the rejection is final."""
const COMPOSITE_RATCHET_MAX = 6

"""
    _composite_ratchet_floors(struc, opts, group_ids, section_floor, ratchet) -> Dict or nothing

Floors for the search after a rejected confirmation. Each group keeps its
installed section or a heavier one. An exact caller floor is kept as given.
`nothing` when no search is left: the limit is reached, or the options
cannot take a floor (a shared-section cap or a multi-material catalog).
"""
function _composite_ratchet_floors(struc, opts, group_ids, section_floor, ratchet::Int)
    ratchet < COMPOSITE_RATCHET_MAX || return nothing
    (opts.n_max_sections == 0 && opts.materials === nothing) || return nothing
    floors = section_floor === nothing ? Dict{Any, Any}() : Dict{Any, Any}(section_floor)
    for gid in group_ids
        fl = get(floors, gid, nothing)
        fl !== nothing && fl.exact && continue
        mg = struc.member_groups[gid]
        isempty(mg.member_indices) && continue
        sec = section(struc.beams[first(mg.member_indices)])
        sec === nothing && continue
        floors[gid] = (section = sec, exact = false)
    end
    return floors
end

# [P2 section-identity, fix cycle 4] Structural (value-level) equality of two catalog
# section FIELDS. `_beam_sec_key` keys identity on `(typename, name)` only, so two
# sections that share a name but differ in PROPERTIES (e.g. a hand-modified
# ISymmSection named "W14X22" with a reduced Ix) collide. Section types (e.g.
# `ISymmSection`) are MUTABLE structs, so Julia's default `==`/`===` is identity-based,
# not value-based — hence a recursive field-by-field comparison. A field is identical
# when it is the SAME MUTABLE object (`===` = genuine identity), or — for any composite
# (mutable or immutable) — when it matches field-by-field by recursion, bottoming out at
# leaves that are the same object or value-equal under `isequal` (so a `missing` field
# matches `missing`, and unit-aware Unitful quantities match — cycle-3's bare `==`
# wrongly refused a `missing` field because `missing == missing === missing`, not
# `true`). Immutable composites (e.g. a `Metal` material) are still recursed field-by-
# field rather than trusted to `===`, so that distinct-but-value-equal sub-objects
# (e.g. a freshly-built `Metal`) compare by VALUE, not identity, and the recursion is
# depth-capped against a self-referential field graph — see the leaf checks below.
# Leaf comparison is `isequal`-based (fix cycle 6, reverting the cycle-5 NaN-poison
# rule): `isequal(NaN, NaN) === true`, so two sections both carrying the SAME unset
# sentinel field (e.g. `Metal.cost::Float64` defaults to NaN — StructuralSizer
# materials/types.jl:79) are value-equal and dedup byte-identically, while a genuinely
# DIFFERING field (e.g. a reduced Ix, or `cost = 5.0` vs unset — `isequal(NaN, 5.0)
# === false`) still resolves to "not identical" so the caller refuses rather than
# silently substitutes.
# (Engineering-scope guard — no code citation.)
# [P2 section-identity, fix cycle 5] Recursion depth cap for `_field_identical`. A
# self-referential (a field pointing back to its own struct) or pathologically deep
# section-field graph would otherwise recurse unboundedly and StackOverflow. Genuine
# catalog sections are shallow (ISymmSection → material → scalar leaves, depth ~3), so
# this generous cap never trips on a real section; on overflow `_field_identical`
# returns `false` (NOT identical) — the conservative choice, so the caller refuses a
# name collision rather than silently substituting. (Engineering-scope guard — no
# code citation.)
const _FIELD_IDENTICAL_MAX_DEPTH = 64

function _field_identical(x, y, depth::Int = 0)
    # [P2 section-identity, fix cycle 6] The cycle-5 NaN-poison rule (a NaN leaf on
    # either side ⇒ NOT identical) was an OVER-correction: `Metal.cost::Float64`
    # defaults to NaN as an "unspecified" sentinel (StructuralSizer materials/types.jl:79),
    # so two GENUINELY value-equal sections both carrying the same material (cost == NaN)
    # wrongly compared "not identical" and triggered a spurious pinned refusal on a
    # LEGITIMATE honorable override. The correct semantics are `isequal`:
    # `isequal(NaN, NaN) === true` (two unset sentinels do NOT differ) while
    # `isequal(NaN, 5.0) === false` (genuinely different). A REAL differing field is
    # still caught by the field-by-field recursion below, so a name-colliding section
    # with DIFFERING properties is still refused (cycle-4 concern stays closed).
    depth >= _FIELD_IDENTICAL_MAX_DEPTH && return false
    # Genuine object identity (the SAME MUTABLE object) is always identical — an object
    # is itself, so there is no substitution risk. Restricted to MUTABLE `x` so that
    # immutable composites (e.g. a `Metal`) fall through to the field-by-field recursion
    # below and are compared by VALUE, keeping two distinct-but-value-equal immutables
    # (freshly built vs cached) on the same footing.
    (x === y && ismutable(x)) && return true
    # Arrays compare element by element. Since Julia 1.11 an Array is a struct
    # whose fields hold a memory pointer, so the field recursion below would
    # call two equal arrays different.
    if x isa AbstractArray || y isa AbstractArray
        (typeof(x) === typeof(y) && size(x) == size(y)) || return false
        return all(_field_identical(a, b, depth + 1) for (a, b) in zip(x, y))
    end
    # Composite (a struct with fields, mutable or immutable): recurse field-by-field so
    # distinct-but-value-equal sub-objects are compared by value, not identity.
    # `typeof` must match so units / type params agree.
    if typeof(x) === typeof(y) && isstructtype(typeof(x)) && !isempty(fieldnames(typeof(x)))
        for f in fieldnames(typeof(x))
            _field_identical(getfield(x, f), getfield(y, f), depth + 1) || return false
        end
        return true
    end
    # Leaf / heterogeneous values: the SAME object, or value-equal under `isequal` (so a
    # `missing` field matches `missing`, `isequal(NaN, NaN) === true` matches two unset
    # sentinels, equal Strings match, and equal same-unit Unitful quantities match).
    # Anything else (including `isequal(NaN, 5.0) === false`) differs.
    x === y && return true
    isequal(x, y) === true && return true
    # [P2 signed-zero, fix cycle 7] Additionally dedup a same-typed numeric leaf that is
    # value-equal but NOT `isequal`. The only such case is `0.0 == -0.0 === true` while
    # `isequal(0.0, -0.0) === false`, so a hand-built override section carrying a signed
    # zero on a numeric field that collides (by type + name) with a `+0.0` catalog field is
    # treated as identical instead of SPURIOUSLY refused. The `typeof(x) === typeof(y)`
    # guard blocks a Unitful `DimensionError` from a cross-type `==` (dimensioned vs
    # dimensionless), and `(x == y) === true` keeps `NaN == NaN === false` — so a NaN leaf
    # is only ever matched via the `isequal` clause above, never here (the cycle-5
    # NaN-substitution hazard is NOT reintroduced). A genuinely differing numeric leaf (the
    # cycle-4 reduced-Ix regression) fails both clauses and still refuses.
    # (Engineering-scope guard — no code citation.)
    typeof(x) === typeof(y) && x isa Number && (x == y) === true && return true
    return false
end

function _sections_identical(a, b)
    a === b && return true
    typeof(a) === typeof(b) || return false
    for f in fieldnames(typeof(a))
        _field_identical(getfield(a, f), getfield(b, f)) || return false
    end
    return true
end

"""
    _assert_no_composite_override(group_ids, demands, member_group_overrides;
                                  opts_composite=false)

Refuse fail-loud (pinned `member_group_overrides` `ArgumentError`) if any group
carrying an EFFECTIVE per-design override is sized as COMPOSITE — either via
`demand.composite !== nothing` or via `SteelBeamOptions.composite` / the
`composite=` kwarg forwarded into batched `size_beams`.

Phase B is STEEL-beam-only. The batched feasible mask
([`_beam_override_union_and_feasible`](@ref)) gates deflection on the bare-steel
`Ix`, whereas the composite code check uses the lower-bound composite inertia
`I_LB` (AISC 360-16 Commentary I3.2; `is_feasible` composite overload in
`members/codes/aisc/checker.jl`, `I_LB > Ix`). Applying the bare-`Ix` mask to a
composite group would OVER-restrict it, so we refuse rather than size it against
the wrong stiffness. `member_group_demands` still builds
`MemberDemand{Float64, Nothing}`; production composite is enabled by
`composite=` on `size_beams`, so `opts_composite` must be checked here too.
(Engineering-scope guard — the cited mechanics is only that `I_LB > Ix` for
composite sections.)
"""
function _assert_no_composite_override(
    group_ids::Vector{UInt64},
    demands,
    member_group_overrides::Dict{UInt64, MemberGroupSizingOverride};
    opts_composite::Bool = false,
)
    for (i, gid) in enumerate(group_ids)
        ovr = get(member_group_overrides, gid, nothing)
        (ovr !== nothing && _is_effective(ovr)) || continue
        (demands[i].composite === nothing && !opts_composite) || throw(ArgumentError(_mgo_refusal_message(
            "override on beam group $(gid) targets a COMPOSITE beam demand; the " *
            "batched size_beams! mask gates deflection on bare-steel Ix while the " *
            "composite code check uses I_LB (AISC 360-16 Commentary I3.2), so Phase B " *
            "refuses composite-beam overrides rather than over-restrict the group")))
    end
    return nothing
end

"""
    _beam_override_union_and_feasible(struc, opts, group_ids, L_totals,
                                      δ_LL_vec, I_ref_v, member_group_overrides)
        -> (union_cat, feasible)

Build a UNION catalog (default ∪ every group's override catalog) and a per-group
`feasible` index mask (indices into `union_cat`) so that ONE batched
`StructuralSizer.size_beams` call can honor per-group `member_group_overrides` on
steel beam groups while leaving every other group byte-identical.

The mask is INTERSECTED with `size_beams -> optimize_discrete`'s internal capacity
screening (which always still runs `AISCChecker` on the global `opts`), so it can
only ever NARROW a group's candidate set — never admit an unchecked section. An
override therefore *tightens* a group relative to the global default; a knob set
LOOSER than the global default is clamped by the global screening (conservative /
safe by construction).

Per-knob precedence on this batched path. A framing level's catalog is its
`beam_options`, which is a separate pass, not a mask inside this one:
- `catalog`         : `override.catalog` > default
- `max_depth`       : `override.max_depth` > `opts.max_depth`
- `deflection_limit`: `override.deflection_limit` > `opts.deflection_limit`

Groups with NO effective override get the full default catalog and NO external
depth/deflection filter — the internal global `AISCChecker` governs them exactly
as before (byte-identical). `total_deflection_limit` is not an override field, so
the global `opts.total_deflection_limit` continues to apply to every group.
"""
function _beam_override_union_and_feasible(
    struc::BuildingStructure,
    opts::StructuralSizer.SteelBeamOptions,
    group_ids::Vector{UInt64},
    L_totals::Vector,
    δ_LL_vec::Vector,
    I_ref_v::Vector,
    member_group_overrides::Dict{UInt64, MemberGroupSizingOverride},
)
    # Default catalog — mirror the exact precedence used inside
    # StructuralSizer.size_columns (custom_catalog > material-default).
    default_cat = opts.custom_catalog === nothing ?
        StructuralSizer.steel_column_catalog(opts.section_type, opts.catalog) :
        opts.custom_catalog

    # Union catalog: default sections FIRST (original order preserved so non-override
    # groups' feasible index order is unchanged), override-only extras appended.
    union_cat = collect(default_cat)
    key2idx = Dict{Any, Int}()
    for (j, s) in enumerate(union_cat)
        get!(key2idx, _beam_sec_key(s), j)
    end
    n_default = length(union_cat)

    resolved_cats = Vector{Any}(undef, length(group_ids))
    for (i, gid) in enumerate(group_ids)
        ovr = get(member_group_overrides, gid, nothing)
        eff = ovr !== nothing && _is_effective(ovr)
        # A group with no EFFECTIVE override keeps the full default catalog.
        if !eff
            resolved_cats[i] = nothing          # no effective override → default catalog membership
            continue
        end
        # Catalog precedence on this batched path: override.catalog > default.
        rc = _first_set(ovr.catalog, default_cat)
        resolved_cats[i] = rc
        for s in rc
            k = _beam_sec_key(s)
            existing = get(key2idx, k, nothing)
            if existing === nothing
                push!(union_cat, s)
                key2idx[k] = length(union_cat)
            elseif !_sections_identical(s, union_cat[existing])
                # [P2 section-identity, fix cycle 3] An override-catalog section whose
                # `(typename, name)` key COLLIDES an existing union section (a default or
                # a previously-added override) but whose PROPERTIES DIFFER would be
                # silently mapped onto the existing section's index by the `key2idx`
                # dedup below — substituting a DIFFERENT section (e.g. a hand-modified
                # "W14X22" with a reduced Ix) for the one the user supplied, then sizing
                # / reporting against the wrong stiffness. Refuse fail-loud (pinned
                # `member_group_overrides` ArgumentError) rather than size against the
                # wrong section. Genuinely IDENTICAL sections still dedup byte-identically
                # (the `steel_column_catalog` sections and `W(name)` share the cached
                # `W_CATALOG` singletons, so `_sections_identical` short-circuits `===`).
                # (Engineering-scope guard — no code citation.)
                nm = (hasproperty(s, :name) && getfield(s, :name) !== nothing) ?
                        getfield(s, :name) : "<unnamed>"
                throw(ArgumentError(_mgo_refusal_message(
                    "override on beam group $(gid) supplies a $(nameof(typeof(s))) named " *
                    "\"$(nm)\" whose (type, name) identity collides a DIFFERENT section " *
                    "already in the batched catalog but with differing properties; the " *
                    "section-identity dedup keys on (type, name) only and would silently " *
                    "substitute the existing section, so Phase B refuses the ambiguous " *
                    "override rather than size against the wrong section")))
            end
        end
    end

    default_idxs = collect(1:n_default)
    feasible = Vector{Vector{Int}}(undef, length(group_ids))
    for (i, gid) in enumerate(group_ids)
        rc = resolved_cats[i]
        if rc === nothing
            feasible[i] = copy(default_idxs)    # internal global checker governs → byte-identical
            continue
        end
        # rc !== nothing ⇒ this group carried an EFFECTIVE override (first loop), so
        # its entry is present; depth/deflection knobs fall through to the global
        # `opts` when the override leaves them unset ([A-revert]).
        ovr = member_group_overrides[gid]
        resolved_depth = _first_set(ovr.max_depth, opts.max_depth)
        resolved_defl  = _first_set(ovr.deflection_limit, opts.deflection_limit)
        δ_LL  = δ_LL_vec[i]
        I_ref = I_ref_v[i]
        L_m   = L_totals[i] isa Unitful.Quantity ? ustrip(u"m", L_totals[i]) : Float64(L_totals[i])
        idxs = Int[]
        for s in rc
            # Depth narrowing — identical `section_depth(s) <= max_depth` gate the
            # AISCChecker applies (StructuralSizer src/members/codes/aisc/checker.jl).
            StructuralSizer.section_depth(s) <= resolved_depth || continue
            # LL-deflection narrowing — identical formula to AISCChecker.is_feasible
            # (aisc/checker.jl): δ_scaled = δ_max_LL * I_ref / Ix; ratio = δ_scaled / L.
            if resolved_defl !== nothing && I_ref > 0 && δ_LL > 0
                Ix_m4 = ustrip(u"m^4", StructuralSizer.Ix(s))
                (δ_LL * I_ref / Ix_m4) / L_m <= resolved_defl || continue
            end
            push!(idxs, key2idx[_beam_sec_key(s)])
        end
        feasible[i] = sort!(unique!(idxs))
    end

    return union_cat, feasible
end

"""`:standard_pan` is not a catalog yet. `:mip` is the sizing path."""
function _require_known_rib_form(opts)
    opts.rib_form == :mip && return nothing
    opts.rib_form == :standard_pan && throw(ArgumentError(
        "rib_form=:standard_pan has no pan list yet. Use rib_form=:mip."))
    throw(ArgumentError("rib_form must be :mip or :standard_pan; got :$(opts.rib_form)"))
end

# --- Shared helper: apply MIP/NLP beam results to the BuildingStructure ---
"""
    _apply_beam_results!(struc, result, group_ids, member_array, edge_ids_in_group, mat)

Apply sized sections (from MIP `result.sections`) to member groups, members, and ASAP elements.

When the result comes from multi-material optimization (`hasproperty(result, :materials_chosen)`),
each group uses its own material from `result.materials_chosen[g_idx]`. Otherwise, the single
`mat` argument is used for all groups.
"""
function _apply_beam_results!(
    struc::BuildingStructure,
    result,
    group_ids::Vector{UInt64},
    member_array,
    edge_ids_in_group::Set{Int},
    mat::StructuralSizer.AbstractMaterial;
    # ACI 318-11 §10.10.4.1 — cracked-stiffness reduction for concrete beam sections.
    # Default 0.35 matches to_asap_section's concrete-beam default (byte-identical no-op).
    I_factor::Real = 0.35,
    # Longitudinal rebar grade when `mat` is plain concrete. Steel beams leave this nothing.
    rebar=nothing,
)
    has_multi_mat = hasproperty(result, :materials_chosen)

    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        group_mat = has_multi_mat ? result.materials_chosen[g_idx] : mat

        mg = struc.member_groups[gid]
        mg.section = chosen

        # I_factor applies to concrete sections only (ACI 318-11 §10.10.4.1); the Metal
        # to_asap_section overloads take no such kwarg, so branch per group material.
        asap_sec = if group_mat isa StructuralSizer.Concrete
            StructuralSizer.to_asap_section(chosen, group_mat; I_factor=I_factor)
        else
            StructuralSizer.to_asap_section(chosen, group_mat)
        end

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            _record_member_check!(m, chosen, result, g_idx)
            # Concrete and rebar are separate keys. `vol_key` alone stored gross
            # area as concrete and dropped the longitudinal steel.
            set_volumes!(m, member_material_volumes(chosen, L_total, group_mat; rebar=rebar))

            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.frame_elements[edge_idx].section = asap_sec
            end
        end
    end
end

# --- Concrete beams (discrete MIP) ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.ConcreteBeamOptions,
    ::Val{:discrete};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
    # Accepted for a uniform `size_beams!` dispatch but NOT honored here: per-group
    # member_group_overrides are only threaded into the STEEL discrete path this
    # increment. `_assert_member_group_overrides_unsupported` refuses any EFFECTIVE
    # override that would reach non-steel-beam sizing, so this is always nothing/vacuous.
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
    # ACI 318-11 §10.10.4.1 — cracked-stiffness reduction for concrete beam sections,
    # threaded from params.beam_I_factor (default 0.35).
    I_factor::Real = 0.35,
    shell_demands = nothing,
    shell_spans = nothing,
    # Group id → `(section, exact)`. Rectangular beams only; see `_apply_section_floor`.
    section_floor = nothing,
    @nospecialize(group_filter = nothing),
    stirrup_shear::Bool = true,
)
    # DEFENSE-IN-DEPTH layer-symmetric guard (Phase B). This non-steel overload
    # ACCEPTS `member_group_overrides` for uniform `size_beams!` dispatch but does NOT
    # honor it (Phase B honors per-group overrides only on the steel-discrete beam
    # path). Public callers never reach here with an EFFECTIVE override — front-door
    # check (2) (`_assert_member_group_overrides_unsupported`, design_types.jl) and the
    # `size_beams!` honor-path allowlist both refuse a non-steel effective override
    # upstream — so this guard is a backstop for a DIRECT call to this private helper,
    # making the mirror-parity layer symmetric with the steel `Val{:discrete}` overload's
    # size-time gid gate. Gated by an effective-override check so a no/vacuous override is
    # byte-identical (this overload otherwise ignores the kwarg). (Engineering-scope guard
    # — no code citation.)
    if member_group_overrides !== nothing &&
            any(o -> _is_effective(o), values(member_group_overrides))
        throw(ArgumentError(_mgo_refusal_message(
            "non-steel beam sizing ($(typeof(opts))) does not honor per-group " *
            "member_group_overrides this increment (Phase B is steel-discrete-beam-only); " *
            "refuse fail-loud rather than silently drop")))
    end

    skel = struc.skeleton
    edge_ids_in_group = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids_in_group, get(skel.groups_edges, g, Int[]))
    end

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        _beam_group_demands(struc, group_filter; resolution, shell_demands)

    isempty(group_ids) && return struc

    member_array = struc.beams
    grouped_spans = _group_shell_spans(struc, group_ids, shell_spans,
                                       StructuralSizer.RCShellSpan)

    # Build demand vectors with Unitful SI units.
    # Mu = sagging (Mux_pos); Mu_neg = hogging. Nu is signed: tension
    # (Pu_t > 0) is negative so ACI 318-11 §11.2.2.3 Eq. (11-8) reduces Vc;
    # otherwise compression Pu_c uses §11.2.1.2 Eq. (11-4).
    # ENGINEERING JUDGMENT: compression/shear concurrency is not tracked —
    # the group envelope Pu is applied to the group envelope Vu.
    Mu = [d.Mux_pos * u"N*m"  for d in demands]
    Mu_neg = [d.Mux_neg * u"N*m" for d in demands]
    _store_hogging_envelopes!(struc, group_ids, demands)
    Vu = [d.Vu_strong * u"N"   for d in demands]
    Nu = [d.Pu_t > 0 ? -d.Pu_t * u"N" : d.Pu_c * u"N" for d in demands]

    # Build geometries (L_totals are Float64 in meters)
    geoms = [StructuralSizer.ConcreteMemberGeometry(L) for L in L_totals]

    # ── T-beam path (include_flange = true) ──
    if opts.include_flange
        section_floor === nothing || throw(ArgumentError(
            "section_floor does not apply to T-beam sizing"))
        isempty(struc.slabs) && error(
            "include_flange=true but no slabs found. Size slabs first.")
        _require_known_rib_form(opts)
        _refuse_frame_floors(struc, group_ids, "T-beam sizing")

        specs = _compute_flange_params(struc, group_ids)

        valid = findall(!isnothing, specs)
        if isempty(valid)
            @warn "include_flange=true but no beams have adjacent slabs — " *
                  "falling back to rectangular beam sizing"
        else
            # One shared section when the floor asks for one rib size; ribs and
            # girders never share a batch. Otherwise each group is its own batch.
            batches = if opts.uniform_geometry
                kinds = [filter(i -> (specs[i].joist_spacing !== nothing) == rib, valid)
                         for rib in (true, false)]
                filter(!isempty, kinds)
            else
                [[i] for i in valid]
            end
            # ENGINEERING JUDGMENT: every rib in this pass uses the thickest
            # topping any rib bay was given, so the flange is one thickness.
            # ACI 318-11 §8.12 takes hf as the slab that is there. A bay still
            # cast thinner than this value is named by the warning.
            rib_hf = [specs[i].hf for i in valid if specs[i].joist_spacing !== nothing]
            floor_hf = isempty(rib_hf) ? nothing : maximum(rib_hf)
            if floor_hf !== nothing && any(hf -> hf < floor_hf, rib_hf)
                @warn "Rib flanges use the thickest topping on this pass " *
                      "($(floor_hf)). A bay whose slab is thinner is not " *
                      "thickened by this pass." maxlog = 1
            end
            # Group id → (demand index, joist spacing the checker was given).
            checked_as = Dict{UInt64, Tuple{Int, Any}}()
            for idxs in batches
                ribs = all(specs[i].joist_spacing !== nothing for i in idxs)
                hf = ribs && floor_hf !== nothing ? floor_hf :
                    minimum(specs[i].hf for i in idxs)
                spacings = [specs[i].joist_spacing for i in idxs
                            if specs[i].joist_spacing !== nothing]
                js = isempty(spacings) ? nothing : maximum(spacings)
                batch = Set(group_ids[idxs])
                rib_max = _rib_web_max(opts, js)
                # ACI 318-11 §8.12.2: each candidate web gets its own flange.
                bf_cache = Dict{typeof(1.0u"m"), typeof(1.0u"m")}()
                bf_of = bw -> get!(bf_cache, uconvert(u"m", bw)) do
                    minimum(_group_flange_width(struc, specs[i], bw; hf, batch,
                                                rib_web_max = rib_max) for i in idxs)
                end
                spans = grouped_spans === nothing ? nothing : grouped_spans[idxs]
                result = _size_tbeams_escalating(
                    Mu[idxs], Vu[idxs], geoms[idxs], opts;
                    flange_width     = bf_of,
                    flange_thickness = hf,
                    joist_spacing    = js,
                    Mu_neg           = Mu_neg[idxs],
                    Nu               = Nu[idxs],
                    sustained_live_fraction = opts.sustained_live_fraction,
                    shell_spans      = spans,
                    stirrup_shear    = stirrup_shear,
                )
                _apply_beam_results!(struc, result, group_ids[idxs], member_array,
                                     edge_ids_in_group, opts.material; I_factor=I_factor,
                                     rebar=opts.rebar_material)
                for i in idxs
                    checked_as[group_ids[i]] = (i, result.joist_spacing)
                end
            end
            recheck = function (mi, sec)
                i, js = checked_as[group_id(member_array[mi])]
                return StructuralSizer.check_tbeam_section(
                    sec, Mu[i], Vu[i], geoms[i], opts;
                    Mu_neg = Mu_neg[i], Nu = Nu[i], joist_spacing = js,
                    sustained_live_fraction = opts.sustained_live_fraction,
                    shell_span = grouped_spans === nothing ? nothing : grouped_spans[i],
                    stirrup_shear = stirrup_shear)
            end
            _share_collinear_rib_bars!(struc, group_ids, specs, opts;
                                       uniform = opts.uniform_geometry,
                                       I_factor = I_factor,
                                       edge_ids = edge_ids_in_group,
                                       rebar = opts.rebar_material,
                                       recheck = recheck)
            missing = findall(isnothing, specs)
            if !isempty(missing)
                spans = grouped_spans === nothing ? nothing : grouped_spans[missing]
                result = StructuralSizer.size_beams(
                    Mu[missing], Vu[missing], geoms[missing], opts;
                    Mu_neg = Mu_neg[missing], Nu = Nu[missing], shell_spans = spans)
                _apply_beam_results!(struc, result, group_ids[missing], member_array,
                                     edge_ids_in_group, opts.material; I_factor=I_factor,
                                     rebar=opts.rebar_material)
            end

            if reanalyze
                Asap.process!(struc.asap_model)
                _solve_struc_model!(struc)
            end

            fc_psi = round(Int, ustrip(u"psi", opts.material.fc′))
            @info "Sized $(length(valid)) RC T-beam groups via MIP" fc_psi uniform=opts.uniform_geometry

            return struc
        end
    end

    # ── Rectangular beam path (default) ──
    result = _rectangular_rc_beam_result(struc, opts, group_ids, Mu, Vu, Mu_neg, Nu,
                                         geoms, grouped_spans, section_floor)

    _apply_beam_results!(struc, result, group_ids, member_array,
                         edge_ids_in_group, opts.material; I_factor=I_factor,
                         rebar=opts.rebar_material)

    if reanalyze
        Asap.process!(struc.asap_model)
        _solve_struc_model!(struc)
    end

    fc_psi = round(Int, ustrip(u"psi", opts.material.fc′))
    @info "Sized $(length(group_ids)) RC beam groups via MIP" fc_psi=fc_psi

    return struc
end

# --- Concrete beams (NLP) ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.ConcreteBeamOptions,
    ::Val{:nlp};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
    # Accepted for uniform `size_beams!` dispatch, NOT honored here (non-steel path;
    # the guard refuses effective overrides that would reach it — always nothing/vacuous).
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
    # ACI 318-11 §10.10.4.1 — cracked-stiffness reduction for concrete beam sections,
    # threaded from params.beam_I_factor (default 0.35). All sections here are concrete
    # (ConcreteBeamOptions.material), so it is passed to every to_asap_section call below.
    I_factor::Real = 0.35,
    shell_demands = nothing,
    shell_spans = nothing,
    @nospecialize(group_filter = nothing),
)
    # DEFENSE-IN-DEPTH layer-symmetric guard (Phase B). This non-steel overload
    # ACCEPTS `member_group_overrides` for uniform `size_beams!` dispatch but does NOT
    # honor it (Phase B honors per-group overrides only on the steel-discrete beam
    # path). Public callers never reach here with an EFFECTIVE override — front-door
    # check (2) (`_assert_member_group_overrides_unsupported`, design_types.jl) and the
    # `size_beams!` honor-path allowlist both refuse a non-steel effective override
    # upstream — so this guard is a backstop for a DIRECT call to this private helper,
    # making the mirror-parity layer symmetric with the steel `Val{:discrete}` overload's
    # size-time gid gate. Gated by an effective-override check so a no/vacuous override is
    # byte-identical (this overload otherwise ignores the kwarg). (Engineering-scope guard
    # — no code citation.)
    if member_group_overrides !== nothing &&
            any(o -> _is_effective(o), values(member_group_overrides))
        throw(ArgumentError(_mgo_refusal_message(
            "non-steel beam sizing ($(typeof(opts))) does not honor per-group " *
            "member_group_overrides this increment (Phase B is steel-discrete-beam-only); " *
            "refuse fail-loud rather than silently drop")))
    end

    skel = struc.skeleton
    edge_ids_in_group = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids_in_group, get(skel.groups_edges, g, Int[]))
    end

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        _beam_group_demands(struc, group_filter; resolution, shell_demands)

    isempty(group_ids) && return struc
    _refuse_frame_floors(struc, group_ids, "concrete beam NLP sizing")

    member_array = struc.beams

    # Sagging / hogging faces. NLP post-checks Mu_neg (top steel is not a DV)
    # and may return :infeasible instead of deepening. Nu is signed: tension
    # (Pu_t > 0) is negative so ACI 318-11 §11.2.2.3 Eq. (11-8) reduces Vc;
    # otherwise compression Pu_c uses §11.2.1.2 Eq. (11-4).
    Mu = [d.Mux_pos * u"N*m"  for d in demands]
    Mu_neg = [d.Mux_neg * u"N*m" for d in demands]
    _store_hogging_envelopes!(struc, group_ids, demands)
    Vu = [d.Vu_strong * u"N" for d in demands]
    Nu = [d.Pu_t > 0 ? -d.Pu_t * u"N" : d.Pu_c * u"N" for d in demands]

    # Map ConcreteBeamOptions → NLPBeamOptions (shared material fields)
    stirrup_int = parse(Int, replace(string(opts.transverse_bar_size), "no" => ""))
    nlp_opts = StructuralSizer.NLPBeamOptions(
        material       = opts.material,
        rebar_material = opts.rebar_material,
        cover      = opts.cover,
        stirrup_size = stirrup_int,
        max_depth  = opts.max_depth,
        max_width  = isfinite(opts.max_width) ? opts.max_width : 24.0u"inch",
        objective  = opts.objective,
    )

    # ── T-beam path (include_flange = true) ──
    if opts.include_flange
        isempty(struc.slabs) && error(
            "include_flange=true but no slabs found. Size slabs first.")

        specs = _compute_flange_params(struc, group_ids)
        # The flange widens with the web, so the narrowest web the NLP may pick
        # gives a flange no candidate exceeds (ACI 318-11 §8.12.2).
        bf_vec = [s === nothing ? nothing :
                  _group_flange_width(struc, s, nlp_opts.min_width; batch = Set([gid]))
                  for (s, gid) in zip(specs, group_ids)]
        rib_hf = [s.hf for s in specs if s !== nothing && s.joist_spacing !== nothing]
        floor_hf = isempty(rib_hf) ? nothing : maximum(rib_hf)
        hf_vec = [s === nothing ? nothing :
                  (s.joist_spacing !== nothing && floor_hf !== nothing ? floor_hf : s.hf)
                  for s in specs]

        # NLP supports per-beam bf/hf vectors
        # Groups without slabs → fall back to rectangular NLP
        tbeam_idx = findall(!isnothing, bf_vec)
        rect_idx  = findall(isnothing, bf_vec)

        mat = opts.material
        n_feasible = 0

        if !isempty(tbeam_idx)
            Mu_t  = Mu[tbeam_idx]
            Vu_t  = Vu[tbeam_idx]
            bf_t  = [bf_vec[i] for i in tbeam_idx]
            hf_t  = [hf_vec[i] for i in tbeam_idx]

            # ACI 318-11 §8.13.2 and §8.13.3 are constraints when a rib inside
            # the width bounds can meet them. Otherwise §8.13.4 applies: the
            # rib is a beam, and §8.13.8 does not.
            requested = [specs[i].joist_spacing for i in tbeam_idx]
            spacing_t = [StructuralSizer.joist_nlp_spacing(s, nlp_opts, hf)
                         for (s, hf) in zip(requested, hf_t)]
            if any(!isnothing, requested) && any(isnothing, spacing_t)
                @warn "ACI 318-11 §8.13.2 and §8.13.3 cannot be met inside the " *
                      "rib width bounds; those ribs are sized as beams and do not " *
                      "receive the §8.13.8 shear increase." maxlog=4
            end
            t_results = StructuralSizer.size_rc_tbeams_nlp(Mu_t, Vu_t, bf_t, hf_t, nlp_opts;
                                                          Mu_neg=Mu_neg[tbeam_idx],
                                                          Nu=Nu[tbeam_idx],
                                                          joist_spacing=spacing_t)

            for (k, g_idx) in enumerate(tbeam_idx)
                r = t_results[k]
                r.status in (:optimal, :feasible) || continue
                n_feasible += 1

                gid = group_ids[g_idx]
                chosen = r.section
                mg = struc.member_groups[gid]
                mg.section = chosen
                asap_sec = StructuralSizer.to_asap_section(chosen, mat; I_factor=I_factor)  # ACI 318-11 §10.10.4.1

                for m_idx in mg.member_indices
                    m = member_array[m_idx]
                    L_raw = sum(struc.segments[i].L for i in segment_indices(m))
                    L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
                    set_section!(m, chosen)
                    set_volumes!(m, MaterialVolumes(_volume_key(mat) => StructuralSizer.self_weight_area(chosen) * L_total))
                    for seg_idx in segment_indices(m)
                        edge_idx = struc.segments[seg_idx].edge_idx
                        edge_idx in edge_ids_in_group || continue
                        struc.asap_model.frame_elements[edge_idx].section = asap_sec
                    end
                end
            end
            _share_collinear_rib_bars!(struc, group_ids, specs, opts;
                                       uniform = opts.uniform_geometry,
                                       I_factor = I_factor,
                                       edge_ids = edge_ids_in_group,
                                       rebar = opts.rebar_material)
        end

        # Rectangular fallback for groups without slabs
        if !isempty(rect_idx)
            Mu_r = Mu[rect_idx]
            Vu_r = Vu[rect_idx]
            r_results = StructuralSizer.size_rc_beams_nlp(Mu_r, Vu_r, nlp_opts;
                                                         Mu_neg=Mu_neg[rect_idx],
                                                         Nu=Nu[rect_idx])

            for (k, g_idx) in enumerate(rect_idx)
                r = r_results[k]
                r.status in (:optimal, :feasible) || continue
                n_feasible += 1

                gid = group_ids[g_idx]
                chosen = r.section
                mg = struc.member_groups[gid]
                mg.section = chosen
                asap_sec = StructuralSizer.to_asap_section(chosen, mat; I_factor=I_factor)  # ACI 318-11 §10.10.4.1

                for m_idx in mg.member_indices
                    m = member_array[m_idx]
                    L_raw = sum(struc.segments[i].L for i in segment_indices(m))
                    L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
                    set_section!(m, chosen)
                    set_volumes!(m, MaterialVolumes(_volume_key(mat) => StructuralSizer.self_weight_area(chosen) * L_total))
                    for seg_idx in segment_indices(m)
                        edge_idx = struc.segments[seg_idx].edge_idx
                        edge_idx in edge_ids_in_group || continue
                        struc.asap_model.frame_elements[edge_idx].section = asap_sec
                    end
                end
            end
        end

        if reanalyze
            Asap.process!(struc.asap_model)
            _solve_struc_model!(struc)
        end

        fc_psi = round(Int, ustrip(u"psi", mat.fc′))
        n_total = length(group_ids)
        n_tbeam = length(tbeam_idx)
        @info "Sized $n_feasible/$n_total RC beam groups via NLP ($(n_tbeam) T-beam)" fc_psi

        return struc
    end

    # ── Rectangular NLP path (default) ──
    results = StructuralSizer.size_rc_beams_nlp(Mu, Vu, nlp_opts; Mu_neg=Mu_neg, Nu=Nu)

    mat = opts.material
    n_feasible = 0
    for (g_idx, gid) in enumerate(group_ids)
        r = results[g_idx]
        r.status in (:optimal, :feasible) || continue
        n_feasible += 1

        chosen = r.section

        mg = struc.member_groups[gid]
        mg.section = chosen

        asap_sec = StructuralSizer.to_asap_section(chosen, mat; I_factor=I_factor)  # ACI 318-11 §10.10.4.1

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(_volume_key(mat) => StructuralSizer.self_weight_area(chosen) * L_total))

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

    fc_psi = round(Int, ustrip(u"psi", mat.fc′))
    n_total = length(group_ids)
    @info "Sized $n_feasible/$n_total RC beam groups via NLP" fc_psi=fc_psi

    return struc
end

# --- PixelFrame beams (discrete MIP) ---
function _size_beams_impl!(
    struc::BuildingStructure,
    opts::StructuralSizer.PixelFrameBeamOptions,
    ::Val{:discrete};
    resolution::Int,
    reanalyze::Bool,
    gravity_factor::Quantity,
    # Accepted for uniform `size_beams!` dispatch, NOT honored here (non-steel path;
    # the guard refuses effective overrides that would reach it — always nothing/vacuous).
    member_group_overrides::Union{Nothing, Dict{UInt64, MemberGroupSizingOverride}} = nothing,
    # Accepted for the uniform `size_beams!` dispatch but inert here: this PixelFrame path
    # builds its own ASAP sections (ACI 318-11 §10.10.4.1 cracked-stiffness factor is
    # applied internally by its own to_asap_section call), so the beam I_factor is unused.
    I_factor::Real = 0.35,
    shell_demands = nothing,
    shell_spans = nothing,
    @nospecialize(group_filter = nothing),
)
    # DEFENSE-IN-DEPTH layer-symmetric guard (Phase B). This non-steel overload
    # ACCEPTS `member_group_overrides` for uniform `size_beams!` dispatch but does NOT
    # honor it (Phase B honors per-group overrides only on the steel-discrete beam
    # path). Public callers never reach here with an EFFECTIVE override — front-door
    # check (2) (`_assert_member_group_overrides_unsupported`, design_types.jl) and the
    # `size_beams!` honor-path allowlist both refuse a non-steel effective override
    # upstream — so this guard is a backstop for a DIRECT call to this private helper,
    # making the mirror-parity layer symmetric with the steel `Val{:discrete}` overload's
    # size-time gid gate. Gated by an effective-override check so a no/vacuous override is
    # byte-identical (this overload otherwise ignores the kwarg). (Engineering-scope guard
    # — no code citation.)
    if member_group_overrides !== nothing &&
            any(o -> _is_effective(o), values(member_group_overrides))
        throw(ArgumentError(_mgo_refusal_message(
            "non-steel beam sizing ($(typeof(opts))) does not honor per-group " *
            "member_group_overrides this increment (Phase B is steel-discrete-beam-only); " *
            "refuse fail-loud rather than silently drop")))
    end

    skel = struc.skeleton
    edge_ids_in_group = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids_in_group, get(skel.groups_edges, g, Int[]))
    end

    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)

    # Extract demands from analysis (MemberDemand in SI: N, N·m, m)
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        _beam_group_demands(struc, group_filter; resolution, shell_demands)

    isempty(group_ids) && return struc

    member_array = struc.beams

    # Build demand vectors with Unitful SI units
    Mu = [d.Mux * u"N*m"      for d in demands]
    Vu = [d.Vu_strong * u"N"   for d in demands]

    # Build geometries (L_totals are Float64 in meters)
    geoms = [StructuralSizer.ConcreteMemberGeometry(L) for L in L_totals]

    # Call PixelFrame beam sizing (validates pixel divisibility, runs MIP)
    result = StructuralSizer.size_beams(Mu, Vu, geoms, opts)

    # Build per-pixel material pool from catalog
    cat = if !isnothing(opts.custom_catalog)
        opts.custom_catalog
    else
        StructuralSizer.generate_pixelframe_catalog(;
            StructuralSizer._pf_catalog_kwargs(opts)...)
    end
    material_pool = unique(s.material for s in cat)

    # Build checker for per-pixel assignment
    checker = StructuralSizer.PixelFrameChecker(;
        StructuralSizer._pf_checker_kwargs(opts)...)

    # Strip pixel length to mm at the boundary
    px_mm = StructuralSizer._pf_pixel_mm(opts)

    # Apply results to member groups + ASAP elements + individual members
    for (g_idx, gid) in enumerate(group_ids)
        chosen = result.sections[g_idx]
        n_px = result.n_pixels[g_idx]

        mg = struc.member_groups[gid]
        mg.section = chosen

        # Build ASAP section for FEA stiffness update
        asap_sec = StructuralSizer.to_asap_section(chosen)

        # Build uniform pixel demands (same demand for all pixels in this group)
        # The MIP already selected the governing section; per-pixel relaxation
        # assigns the lowest-carbon material at each pixel position.
        pixel_demands = [demands[g_idx] for _ in 1:n_px]

        # Build PixelFrameDesign with per-pixel material assignment
        design = StructuralSizer.build_pixel_design(
            chosen,
            L_totals[g_idx] * u"m",
            px_mm,
            pixel_demands,
            material_pool,
            checker,
        )

        for m_idx in mg.member_indices
            m = member_array[m_idx]

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_pixel_design!(m, design)

            # Compute volumes from per-pixel material assignment
            pv = StructuralSizer.pixel_volumes(design)
            vols = MaterialVolumes()
            for (mat, vol) in pv
                vols[mat] = vol
            end
            set_volumes!(m, vols)

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

    n_total = length(group_ids)
    λs = join(string.(opts.λ_values), ",")
    @info "Sized $n_total PixelFrame beam groups via MIP" layups=λs pixel_mm=StructuralSizer._pf_pixel_mm(opts)

    return struc
end

"""
Keep each RC beam group's factored hogging envelope on its member beams
(`Beam.Mu_neg_envelope`, N·m). Detailing reads it for top bars, so the bars
match the moment the section was sized for, not the last solved case.
"""
function _store_hogging_envelopes!(struc, group_ids, demands)
    for (gid, d) in zip(group_ids, demands)
        for m_idx in struc.member_groups[gid].member_indices
            struc.beams[m_idx].Mu_neg_envelope = Float64(d.Mux_neg)
        end
    end
    return struc
end

"""
Size the batch from `opts.catalog_size_tbeam`. A demand the ordinary catalog
cannot carry is sized again from the heavy catalog (`large_rc_tbeams`, webs
to 30 in and depths to 48 in). A heavy catalog that also has no section
still throws.

The result carries `joist_spacing`: the spacing the checker was given, which
is `nothing` once §8.13.4 sized the batch as beams.
"""
_no_feasible_section(err) =
    err isa ArgumentError && occursin("No feasible sections", err.msg)

function _size_tbeams_escalating(Mu, Vu, geoms, opts; kwargs...)
    kw = (; kwargs...)
    used = (; joist_spacing = get(kw, :joist_spacing, nothing))
    cat = opts.catalog_size_tbeam
    try
        return merge(StructuralSizer.size_tbeams(Mu, Vu, geoms, opts;
                                                 catalog_size = cat, kw...), used)
    catch err
        _no_feasible_section(err) || rethrow()
        # The joist catalog keeps only ribs that meet ACI 318-11 §8.13.2 and
        # §8.13.3 (corpus: aci-318-11, page 120). None of them can carry this
        # demand, so §8.13.4 sizes the member as a beam and §8.13.8 does not apply.
        if get(kw, :joist_spacing, nothing) !== nothing
            @warn "No joist rib meeting ACI 318-11 §8.13.2 and §8.13.3 can carry " *
                  "this demand. §8.13.4 sizes it as a beam, and §8.13.8 does not apply." maxlog = 4
            return _size_tbeams_escalating(Mu, Vu, geoms, opts;
                                           merge(kw, (joist_spacing = nothing,))...)
        end
        cat === :large && rethrow()
        @warn "RC T-beam demand exceeds the $cat catalog; sizing from the heavy catalog" maxlog = 4
        return merge(StructuralSizer.size_tbeams(Mu, Vu, geoms, opts;
                                                 catalog_size = :large, kw...), used)
    end
end
