# Ribbed stories: one rib depth per story, one web and bar size per rib line.
#
# A concrete rib level (waffle grillage or one-way joists) whose `rib_stem` is
# set is sized here, not by the catalog MIP. Every rib on the level has the
# overall depth `hf + rib_stem`. A rib set shares a web and a bottom bar size:
# a collinear line of grillage pieces across the story, or one joist group.
# See docs/sizing-map/ribbed-floors.md.

"""
    STANDARD_DOME_STEMS

Stems (below the topping) of the standard 30 in square dome forms: 8, 10, 12,
14, 16, and 20 in. Pass as `DesignParameters.rib_stems` to restrict a story
to standard forms.
"""
const STANDARD_DOME_STEMS = [8.0, 10.0, 12.0, 14.0, 16.0, 20.0] .* u"inch"

"""Most stem screens per member stage; each after the first follows a member loop."""
const RIB_SCREEN_ROUNDS = 3

"""True when `level` holds concrete T-beam ribs this module can own."""
function _story_rib_eligible(level::FramingLevel, fallback)
    opts = _level_concrete_options(level, fallback)
    opts === nothing && return false
    opts.include_flange || return false
    level.role == :joist || return false
    return rib_analysis(level) == :grillage || level.pattern isa LinearAxisPattern
end

"""Framing levels whose ribs have a story depth."""
function _story_rib_levels(struc)
    out = FramingLevel[]
    for slab in struc.slabs, fl in slab.framing_levels
        fl.rib_stem === nothing && continue
        fl.group_id === nothing && continue
        push!(out, fl)
    end
    return out
end

"""`group id => framing level` for every rib group with a story depth."""
function story_rib_groups(struc)
    out = Dict{UInt64, FramingLevel}()
    for fl in _story_rib_levels(struc)
        for gid in level_sizing_group_ids(fl)
            out[gid] = fl
        end
    end
    return out
end

"""
Rib sets among `gids`: vectors of group ids that share a web and a bar size.

A grillage piece joins every other story-owned piece on its collinear line
([`_collinear_rib_groups`](@ref)), including pieces outside `gids`, so a line
is always sized whole. A one-way joist group is its own set.
"""
function _rib_sets(struc, gids, owner)
    sets = Vector{Vector{UInt64}}()
    wanted = Set(gids)
    grill_beams = Int[]
    for (bi, beam) in enumerate(struc.beams)
        gid = group_id(beam)
        gid === nothing && continue
        fl = get(owner, gid, nothing)
        fl === nothing && continue
        rib_analysis(fl) == :grillage || continue
        _level_rib(fl, beam) || continue
        push!(grill_beams, bi)
    end
    placed = Set{UInt64}()
    for line in _collinear_rib_groups(struc, grill_beams)
        line_gids = unique!(UInt64[group_id(struc.beams[bi]) for bi in line])
        any(g -> g in wanted, line_gids) || continue
        push!(sets, line_gids)
        union!(placed, line_gids)
    end
    for gid in gids
        gid in placed && continue
        haskey(owner, gid) || continue
        push!(sets, [gid])
        push!(placed, gid)
    end
    return sets
end

"""
Strongest section the set's web and bar limits allow at depth `h`, for a set
no web and bar size can carry. It is installed so the frame has a stiffness,
and its failing check is recorded.
"""
function _strongest_rib_section(h, hf, bf, js, Mu_neg, fc_psi, fy_psi)
    webs = StructuralSizer.rib_set_webs(h, hf, js)
    bw = isempty(webs) ? StructuralSizer.MAX_JOIST_RIB_WIDTH : last(webs)
    bar = 8
    cover = 0.75u"inch"
    n = StructuralSizer._max_bars_in_width(ustrip(u"inch", bw), ustrip(u"inch", cover),
                                           ustrip(u"inch", StructuralSizer.rebar(3).diameter),
                                           ustrip(u"inch", StructuralSizer.rebar(bar).diameter),
                                           0.75)
    sec = StructuralSizer.RCTBeamSection(; bw, h, bf = max(bf, bw), hf, bar_size = bar,
                                         n_bars = max(n, 1), cover)
    return StructuralSizer._with_top_steel(sec, Mu_neg, fc_psi, fy_psi)
end

"""
    size_rib_lines!(struc, gids; fallback, resolution, gravity_factor, I_factor,
                    stirrup_shear, rib_head_stirrups) -> Dict{UInt64, NamedTuple}

Size the story-owned rib groups `gids` and every group on their rib lines.

Each set is [`StructuralSizer.size_rib_set`](@ref) at its level's depth
`hf + rib_stem`, on the frame's current demands. A piece that frames into a
solid head is checked with stirrups only when `rib_head_stirrups`
(ENGINEERING JUDGMENT, see `DesignParameters`). The chosen section goes on
every member of each group and on the frame. A set with no passing web and
bar size gets [`_strongest_rib_section`](@ref) and a failing check, and the
level's `rib_report` counts it.

Returns `group id => (ok, carbon, set)` for the groups sized.
"""
function size_rib_lines!(struc, gids; fallback, resolution::Int = 200, gravity_factor,
                         I_factor::Real, stirrup_shear::Bool = true,
                         rib_head_stirrups::Bool = true)
    owner = story_rib_groups(struc)
    gids = [g for g in gids if haskey(owner, g)]
    out = Dict{UInt64, NamedTuple}()
    isempty(gids) && return out
    _ensure_frame_demands!(struc)
    skel = struc.skeleton
    edge_ids = Set{Int}()
    for g in BEAM_GROUP_SYMBOLS
        union!(edge_ids, get(skel.groups_edges, g, Int[]))
    end
    _add_gravity_loads!(struc, edge_ids, gravity_factor)

    sets = _rib_sets(struc, gids, owner)
    needed = Set(g for s in sets for g in s)
    group_ids, demands, L_totals = _beam_group_demands(
        struc, g -> g in needed; resolution, shell_demands = nothing,
        service_deflection = false)[1:3]
    row = Dict(g => i for (i, g) in enumerate(group_ids))
    for s in sets, g in s
        haskey(row, g) || throw(ArgumentError(
            "rib group $g has no demand; the frame has no element for it"))
    end
    specs = _compute_flange_params(struc, group_ids)
    spec_of = Dict(g => specs[i] for (i, g) in enumerate(group_ids))
    faces = Set{UInt64}()
    rib_head_stirrups == stirrup_shear ||
        foreach(fl -> union!(faces, _head_face_group_ids(struc, fl)), unique(values(owner)))

    for set in sets
        fl = owner[first(set)]
        opts = _level_concrete_options(fl, fallback)
        opts === nothing && throw(ArgumentError(
            "slab $(fl.slab_idx) has a rib story depth and no concrete beam options"))
        set_specs = [spec_of[g] for g in set]
        any(isnothing, set_specs) && throw(ArgumentError(
            "a rib group on slab $(fl.slab_idx) has no slab flange"))
        spacings = [s.joist_spacing for s in set_specs if s.joist_spacing !== nothing]
        isempty(spacings) && throw(ArgumentError(
            "a rib set on slab $(fl.slab_idx) has no joist spacing"))
        js = maximum(spacings)
        # ENGINEERING JUDGMENT: one flange thickness per set, the thickest topping
        # any piece bears. ACI 318-11 §8.12 takes hf as the slab that is there.
        hf = maximum(s.hf for s in set_specs)
        h = uconvert(u"m", hf + fl.rib_stem)
        batch = Set(set)
        rib_max = _rib_web_max(opts, js)
        bf_of = (i, bw) -> _group_flange_width(struc, set_specs[i], bw; hf, batch,
                                               rib_web_max = rib_max)
        idx = [row[g] for g in set]
        d = demands[idx]
        Mu = [x.Mux_pos * u"N*m" for x in d]
        Mu_neg = [x.Mux_neg * u"N*m" for x in d]
        Vu = [x.Vu_strong * u"N" for x in d]
        Nu = [x.Pu_t > 0 ? -x.Pu_t * u"N" : x.Pu_c * u"N" for x in d]
        geoms = [StructuralSizer.ConcreteMemberGeometry(L_totals[i] * u"m") for i in idx]
        flags = [g in faces ? rib_head_stirrups : stirrup_shear for g in set]
        res = StructuralSizer.size_rib_set(Mu, Vu, geoms, opts; h, hf, flange_width = bf_of,
                                           joist_spacing = js, Mu_neg, Nu,
                                           stirrup_shear = flags)
        fc_psi = ustrip(u"psi", opts.material.fc′)
        fy_psi = ustrip(u"psi", opts.rebar_material.Fy)
        if !res.ok
            @warn "Rib set on slab $(fl.slab_idx) has no web and bar size at " *
                  "h = $(round(ustrip(u"inch", h); digits = 1)) in: $(res.reason)" maxlog = 4
        end
        for (k, g) in enumerate(set)
            sec = res.ok ? res.sections[k] :
                _strongest_rib_section(h, hf, bf_of(k, StructuralSizer.MAX_JOIST_RIB_WIDTH),
                                       js, Mu_neg[k], fc_psi, fy_psi)
            expl = StructuralSizer.check_tbeam_section(
                sec, Mu[k], Vu[k], geoms[k], opts; Mu_neg = Mu_neg[k], Nu = Nu[k],
                joist_spacing = js, stirrup_shear = flags[k])
            mg = struc.member_groups[g]
            mg.section = sec
            for mi in mg.member_indices
                _install_rib_section!(struc, mi, sec, opts.material; I_factor,
                                      rebar = opts.rebar_material, edge_ids)
                struc.beams[mi].base.check = (section = sec, explanation = expl)
            end
            L = geoms[k].L * length(mg.member_indices)
            out[g] = (ok = res.ok && expl.passed,
                      carbon = StructuralSizer.rib_section_carbon(sec, opts.material,
                                                                  opts.rebar_material, L),
                      set = set, reason = res.reason)
        end
    end
    _record_rib_reports!(struc, out, owner)
    return out
end

"""Fold the sized groups into each level's `rib_report`."""
function _record_rib_reports!(struc, sized, owner)
    by_level = Dict{UInt64, Vector{UInt64}}()
    for g in keys(sized)
        push!(get!(Vector{UInt64}, by_level, owner[g].group_id), g)
    end
    for fl in _story_rib_levels(struc)
        gs = get(by_level, fl.group_id, nothing)
        gs === nothing && continue
        prev = fl.rib_report === nothing ? Dict{UInt64, NamedTuple}() :
               copy(fl.rib_report.groups)
        for g in gs
            prev[g] = sized[g]
        end
        failed = [g for (g, r) in prev if !r.ok]
        old = fl.rib_report
        fl.rib_report = (
            stem = fl.rib_stem,
            groups = prev,
            n_sets = length(unique(r.set for r in values(prev))),
            n_failed = length(failed),
            carbon = sum((r.carbon for r in values(prev)); init = 0.0u"kgCO2e"),
            reasons = unique([prev[g].reason for g in failed]),
            deflection = old === nothing ? nothing : old.deflection,
            screen = old === nothing ? nothing : old.screen,
        )
    end
    return struc
end

"""Eligible rib levels by story index."""
function _rib_stories(struc, fallback)
    out = Dict{Int, Vector{FramingLevel}}()
    for slab in struc.slabs, fl in slab.framing_levels
        fl.group_id === nothing && continue
        _story_rib_eligible(fl, fallback) || continue
        push!(get!(Vector{FramingLevel}, out, _slab_story(struc, slab)), fl)
    end
    return out
end

"""Plan area (m²) of the bays cast solid on grillage level `fl`."""
function _solid_head_area(struc, fl)
    isempty(fl.solid_heads) && return 0.0
    arr, _ = grillage_bays(struc, struc.slabs[fl.slab_idx], fl)
    bays = unique(b for h in fl.solid_heads for b in h.bays)
    return sum((arr.bays[b].area for b in bays); init = 0.0)
end

"""
Size every rib on `levels` at stem `stem` and install the sections. Returns
`(ok, carbon)`: whether every set passed, and the embodied carbon of the rib
stems and bars plus the solid-head concrete below the topping (head area at
the current heads × `stem`). ENGINEERING JUDGMENT: head reinforcement is left
out of the comparison.
"""
function _size_story_stem!(struc, levels, stem; fallback, size_kwargs...)
    foreach(fl -> fl.rib_stem = stem, levels)
    gids = unique(UInt64[g for fl in levels for g in level_sizing_group_ids(fl)])
    sized = size_rib_lines!(struc, gids; fallback, size_kwargs...)
    apply_solid_head_frame_sections!(struc)
    carbon = sum((r.carbon for r in values(sized)); init = 0.0u"kgCO2e")
    for fl in levels
        A = _solid_head_area(struc, fl)
        A > 0 || continue
        conc = _level_concrete_options(fl, fallback).material
        carbon += uconvert(u"kgCO2e", A * u"m^2" * stem * conc.ρ * conc.ecc)
    end
    return (ok = all(r.ok for r in values(sized)), carbon = carbon)
end

"""
    screen_rib_stems!(struc, params; fallback, size_kwargs...) -> Bool

Pick each ribbed story's stem and check its service deflection.

`params.rib_stem` fixes every story's stem. Otherwise every stem in
`params.rib_stems` is sized on the frame's current demands
([`_size_story_stem!`](@ref)); among those whose every rib set passes, the
least embodied carbon whose cracked service deflection
([`story_rib_deflection`](@ref)) passes is chosen. With none passing
deflection the deepest strength-passing stem is kept, and with none passing
strength the deepest stem; the level's `rib_report` then shows the failure.

The chosen stem is installed, and each level's `rib_report` gets the story's
`deflection` and the `screen` trials. Returns `true` when any stem changed.
"""
function screen_rib_stems!(struc, params; fallback, size_kwargs...)
    changed = false
    for (lvl, levels) in sort!(collect(_rib_stories(struc, fallback)); by = first)
        before = [fl.rib_stem for fl in levels]
        opts = _level_concrete_options(first(levels), fallback)
        checked = Dict{Any, NamedTuple}()
        deflection(stem) = get!(checked, stem) do
            story_rib_deflection(struc, lvl;
                sustained_live_fraction = opts.sustained_live_fraction,
                limit = params.rib_deflection_limit,
                concrete = opts.material, rebar = opts.rebar_material)
        end
        screen = nothing
        if params.rib_stem !== nothing
            stem = params.rib_stem
        else
            stems = sort(params.rib_stems)
            isempty(stems) && throw(ArgumentError("rib_stems is empty"))
            trials = [(stem = s, _size_story_stem!(struc, levels, s; fallback, size_kwargs...)...)
                      for s in stems]
            strong = sort([t for t in trials if t.ok]; by = t -> t.carbon)
            chosen = nothing
            for t in strong
                _size_story_stem!(struc, levels, t.stem; fallback, size_kwargs...)
                if deflection(t.stem).ok
                    chosen = t
                    break
                end
            end
            stem = chosen !== nothing ? chosen.stem :
                   isempty(strong) ? last(stems) : maximum(t.stem for t in strong)
            screen = [(stem = t.stem, strength = t.ok, carbon = t.carbon,
                       deflection = haskey(checked, t.stem) ? checked[t.stem].ok : missing)
                      for t in trials]
        end
        _size_story_stem!(struc, levels, stem; fallback, size_kwargs...)
        _attach_rib_deflection!(levels, deflection(stem); screen)
        changed |= any(b -> b === nothing || b != stem, before)
    end
    return changed
end

function _attach_rib_deflection!(levels, d; screen = missing)
    for fl in levels
        fl.rib_report === nothing && continue
        s = screen === missing ? fl.rib_report.screen : screen
        fl.rib_report = merge(fl.rib_report, (deflection = d, screen = s))
    end
end

"""
    report_rib_deflection!(struc, params; fallback)

Check every ribbed story's cracked service deflection on the final sections
and heads ([`story_rib_deflection`](@ref)) and put it on each level's
`rib_report`.
"""
function report_rib_deflection!(struc, params; fallback)
    for (lvl, levels) in _rib_stories(struc, fallback)
        any(fl -> fl.rib_stem === nothing, levels) && continue
        opts = _level_concrete_options(first(levels), fallback)
        d = story_rib_deflection(struc, lvl;
            sustained_live_fraction = opts.sustained_live_fraction,
            limit = params.rib_deflection_limit,
            concrete = opts.material, rebar = opts.rebar_material)
        d.ok || @warn "Ribbed story $lvl fails service deflection: live " *
                      "$(round(d.live.ratio; digits = 2)), long-term " *
                      "$(round(d.long_term.ratio; digits = 2)) of the Table 9.5(b) limit"
        _attach_rib_deflection!(levels, d)
    end
    return struc
end
