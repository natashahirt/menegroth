# =============================================================================
# Beam sizing against the story shell
# =============================================================================
#
# Two models describe the same floor. Each quantity has one owner, and no
# value from one model is folded into the other's.
#
#   Quantity                         Owner          Where it is checked
#   ───────────────────────────────  ─────────────  ──────────────────────────────
#   Factored M⁺, M⁻, V               both           larger of frame and shell
#                                                   (`ShellBeamDemand` raises
#                                                   `MemberDemand`, never lowers)
#   Stud fields, per combination     shell          composite per-station check
#   Composite I_LB / I_neg map       frame model    recorded as a stiffness
#                                                   profile (section, anchors)
#                                    shell          the profile placed on the
#                                                   shell's own sagging regions
#                                                   from the pass before
#   Live-load deflection             frame model    `MemberDemand.δ_max_LL`,
#                                                   scaled by `I_ref`
#                                    shell          per span, on its own length
#                                                   (`RCShellSpan`, `SteelShellSpan`)
#   Total deflection, steel          frame model    `MemberDemand.δ_max_total`,
#                                                   staged dead on steel when
#                                                   unshored
#   Total deflection, RC             frame model    closed form, when used
#                                    shell          `RCShellSpan` long-term total
#
# Where frame and shell both own a check, both must pass.

"""Stories with at least one slab panel."""
function _story_shell_levels(struc)
    slab_faces = Set(struc.cells[ci].face_idx for slab in struc.slabs for ci in slab.cell_indices)
    return sort!([lvl for (lvl, story) in struc.skeleton.stories
                  if any(f -> f in slab_faces, story.faces)])
end

"""
Stories that `design_building` designs with the story shell: every slab
panel on the story is a one-way or two-way concrete slab, and no wall takes
load from any of them.

# ENGINEERING JUDGMENT
The story shell holds the slab up at column centres and on beams only. A
wall-supported edge would be free in it, so the slab would sag where it
hogs over the wall and the top bars there would be missed. Such a story
keeps its panels `:not_analyzed`.
"""
function _story_shell_design_levels(struc)
    level_of = Dict(f => lvl for (lvl, story) in struc.skeleton.stories for f in story.faces)
    kinds = Dict{Int, Set{Symbol}}()
    for slab in struc.slabs, ci in slab.cell_indices
        cell = struc.cells[ci]
        lvl = get(level_of, cell.face_idx, nothing)
        lvl === nothing && continue
        sym = cell.floor_type === :unknown ? slab.floor_type : cell.floor_type
        push!(get!(Set{Symbol}, kinds, lvl), sym)
    end
    on_walls = Set{Int}()
    for wall in struc.walls, ci in keys(wall.tributary_cell_areas)
        lvl = get(level_of, struc.cells[ci].face_idx, nothing)
        lvl === nothing || push!(on_walls, lvl)
    end
    return sort!([lvl for (lvl, ks) in kinds
                  if ks ⊆ (:one_way, :two_way) && !(lvl in on_walls)])
end

"""
Keep the larger peak, and every moment field, when a beam is in more than
one story shell.
"""
function _merge_shell_demand!(into::Dict{Int, ShellBeamDemand}, from)
    for (i, d) in from
        old = get(into, i, nothing)
        into[i] = old === nothing ? d : ShellBeamDemand(
            max(old.Mu_pos, d.Mu_pos), max(old.Mu_neg, d.Mu_neg), max(old.Vu, d.Vu),
            vcat(old.moment_fields, d.moment_fields))
    end
    return into
end

"""
    size_beams_with_story_shell!(struc, opts=nothing; levels, max_passes=6,
                                 shell_kwargs=(;), shells, shell_demands,
                                 shell_spans, shell_regions, kwargs...) -> NamedTuple

Size beams from their tributary demand, then resize them against the story
shell until the sections stop changing.

Each pass solves the shell of every story in `levels` with the current
sections and resizes with [`size_beams!`](@ref), which takes the larger of
the tributary demand and the [`ShellBeamDemand`](@ref). A beam's stiffness
sets how much load the shell sends it, so a pass that changes a section is
followed by another. `shell_kwargs` go to [`build_story_shell`](@ref) and
[`solve_story_shell!`](@ref); `kwargs` go to `size_beams!`.

Each story is meshed once and kept in `shells` (level → [`StoryShell`](@ref)).
A caller that passes its own `shells` reuses those meshes on a later call.
Passes solve strength only until the sections hold. The cracked service
solve then joins every remaining pass, and the loop converges only on a pass
that ran it. `shell_kwargs.service = false` leaves it out.

`shell_demands`, `shell_spans` and `shell_regions` are a previous call's
`demands`, `spans` and `regions`. The first sizing then keeps them, so the
beams do not drop back to their tributary sections, and the service solve
runs from the first pass.

A story that is not `:analyzed` throws: one of its beams would be sized
without its shell demand. A composite steel beam is checked on each load
combination's shell moment field as well (see [`size_beams!`](@ref)), and its
shell stiffness is the composite inertia of the section from the pass before.
That inertia is placed on the shell's own sagging regions from the pass
before (the combination with the greatest sagging peak); the first pass uses
the frame model's. Each beam's service-shell spans are a separate deflection
check (see the ownership table at the top of this file).

Returns `(converged, passes, demands, spans, regions, shells,
service_converged, region_mismatch)`. `converged` is true when a pass that
ran the service solve changed no section and moved no composite beam's
sagging regions by more than `region_tol` (fraction of its length).
`service_converged` is false when a cracked service solve stopped on its
iteration cap. `region_mismatch` maps each composite beam to that last
movement: how far the regions its shell stiffness was placed on sit from the
regions the solve produced.

# ENGINEERING JUDGMENT
`region_tol = 0.05` is a convergence threshold, not a code limit. Deferring
the service solve until strength holds changes no converged section: the
loop stops only on a pass where both strength and service hold.
"""
function size_beams_with_story_shell!(struc::BuildingStructure,
                                      opts::Union{StructuralSizer.BeamOptions, Nothing} = nothing;
                                      levels = nothing,
                                      max_passes::Int = 6,
                                      shell_kwargs = (;),
                                      region_tol::Real = 0.05,
                                      shells::AbstractDict{Int, StoryShell} = Dict{Int, StoryShell}(),
                                      shell_demands = nothing,
                                      shell_spans = nothing,
                                      shell_regions = nothing,
                                      kwargs...)
    max_passes >= 1 || throw(ArgumentError("max_passes must be at least 1"))
    lvls = levels === nothing ? _story_shell_levels(struc) : collect(levels)
    isempty(lvls) && throw(ArgumentError("no story has a slab panel for the story shell"))
    # Catalog shapes carry no material. The shell uses each beam's recorded
    # steel when sizing wrote one, and this options' steel otherwise.
    # `sustained_live_fraction` stays the building-wide value: it is the
    # occupancy, not a per-level beam property.
    if opts isa StructuralSizer.SteelBeamOptions && !haskey(shell_kwargs, :steel)
        shell_kwargs = merge((steel = opts.material,), shell_kwargs)
    end
    if opts isa StructuralSizer.ConcreteBeamOptions &&
            !haskey(shell_kwargs, :sustained_live_fraction)
        shell_kwargs = merge((sustained_live_fraction = opts.sustained_live_fraction,),
                             shell_kwargs)
    end

    build_kwargs, solve_kwargs, want_service = _split_shell_kwargs(shell_kwargs)

    size_beams!(struc, opts; shell_demands = shell_demands, shell_spans = shell_spans,
                kwargs...)
    demands = Dict{Int, ShellBeamDemand}()
    spans = Dict{Int, Vector{Any}}()
    service_on = want_service && shell_spans !== nothing
    service_converged = true
    next_regions = shell_regions === nothing ? Dict{Int, Vector{NamedTuple}}() :
                   Dict{Int, Vector{NamedTuple}}(shell_regions)
    shifts = Dict{Int, Float64}()
    # Diagnosis only. SS_TRACE_SHELL_PASSES=1 prints each pass's section
    # changes and whether the section vector repeats an earlier pass.
    tracing = get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1"
    history = tracing ? Vector{Vector{String}}() : nothing
    if tracing
        println("—— story-shell sizing on levels $(join(lvls, ", ")) ——")
        tributary = [_story_beam_section(struc, b) for b in struc.beams]
        _trace_shell_pass!(history, 0, struc.beams,
                           fill!(Vector{Any}(undef, length(tributary)), nothing), tributary,
                           Dict{Int, ShellBeamDemand}(), false)
    end
    for pass in 1:max_passes
        empty!(demands)
        empty!(spans)
        used = Dict{Int, Vector{NamedTuple}}()
        for level in lvls
            shell = get!(shells, level) do
                build_story_shell(struc, level; composite_regions = next_regions,
                                  build_kwargs...)
            end
            res = solve_story_shell!(shell, struc; composite_regions = next_regions,
                                     solve_kwargs..., service = service_on)
            res.analysis_status === :analyzed || throw(ArgumentError(
                "story $level shell was not analyzed: $(join(res.reasons, "; "))"))
            _merge_shell_demand!(demands, res.beam_demands)
            _merge_shell_spans!(spans, res.service_spans)
            merge!(used, res.composite_regions)
            service_on && (service_converged &= res.service_converged)
        end
        before = [_story_beam_section(struc, b) for b in struc.beams]
        size_beams!(struc, opts; shell_demands = demands,
                    shell_spans = service_on ? spans : nothing, kwargs...)
        after = [_story_beam_section(struc, b) for b in struc.beams]
        shifts = _region_shifts(demands, used)
        next_regions = _next_shell_regions(demands, used)
        held = all(_sections_identical(a, b) for (a, b) in zip(before, after))
        settled = all(<=(region_tol), values(shifts))
        tracing && _trace_shell_pass!(history, pass, struc.beams, before, after,
                                      demands, service_on)
        if held && settled
            (service_on || !want_service) &&
                return (converged = true, passes = pass, demands = demands, spans = spans,
                        regions = next_regions, shells = shells,
                        service_converged = service_converged, region_mismatch = shifts)
            service_on = true
        end
    end
    moving = sort!([i for (i, m) in shifts if m > region_tol])
    @warn "Beam sections or composite sagging regions still changed after " *
          "$max_passes story-shell passes" regions_moving = moving
    return (converged = false, passes = max_passes, demands = demands, spans = spans,
            regions = next_regions, shells = shells,
            service_converged = service_converged, region_mismatch = shifts)
end

const _SHELL_BUILD_KEYS = (:target_edge, :concrete, :steel, :support_points)

"""
`shell_kwargs` split into the keywords of [`build_story_shell`](@ref) and of
[`solve_story_shell!`](@ref). Material goes to the build, which keeps it.
`service` is left out of both: the pass loop decides it.
"""
function _split_shell_kwargs(kw)
    nt = NamedTuple(kw)
    build = (; (k => nt[k] for k in keys(nt) if k in _SHELL_BUILD_KEYS)...)
    solve = (; (k => nt[k] for k in keys(nt) if !(k in _SHELL_BUILD_KEYS) && k !== :service)...)
    return build, solve, get(nt, :service, true)
end

"""
Sagging regions of the shell field in `fields` with the greatest sagging
peak, or `nothing` when there are no fields.
"""
function _governing_shell_regions(fields)
    isempty(fields) && return nothing
    shell = [StructuralSizer.positive_moment_regions(f; breakpoints = f.breakpoints)
             for f in fields]
    peak(rs) = isempty(rs) ? -Inf : maximum(r -> r.M_peak, rs)
    return shell[argmax(k -> peak(shell[k]), eachindex(shell))]
end

"""
Largest distance, as a fraction of the beam, between matching zero-moment
boundaries of two lists of sagging regions. `Inf` when they have a different
number of regions. Zero when `b` is `nothing`.
"""
function _region_shift(a, b)
    b === nothing && return 0.0
    length(a) == length(b) || return Inf
    worst = 0.0
    for (ra, rb) in zip(a, b)
        worst = max(worst, abs(ra.s_left - rb.s_left), abs(ra.s_right - rb.s_right))
    end
    return worst
end

"""
    composite_region_mismatch(profile, fields) -> Float64

Largest distance, as a fraction of the beam, between a zero-moment boundary
of the frame model's sagging regions (`profile.regions`) and the matching
boundary of the shell field in `fields` with the greatest sagging peak.
`Inf` when the two have a different number of sagging regions. Zero when
there are no fields.

Both are in the station coordinate of [`beam_signed_moment_field`](@ref).
"""
composite_region_mismatch(profile, fields) =
    _region_shift(profile.regions, _governing_shell_regions(fields))

"""
For each composite beam the shell solved, how far the sagging regions its
stiffness was placed on (`used`) sit from the regions that solve produced.
"""
function _region_shifts(demands, used)
    out = Dict{Int, Float64}()
    for (i, regions) in used
        d = get(demands, i, nothing)
        d === nothing && continue
        out[i] = _region_shift(regions, _governing_shell_regions(d.moment_fields))
    end
    return out
end

"""Governing shell sagging regions of each composite beam, for the next pass."""
function _next_shell_regions(demands, used)
    out = Dict{Int, Vector{NamedTuple}}()
    for i in keys(used)
        d = get(demands, i, nothing)
        d === nothing && continue
        gov = _governing_shell_regions(d.moment_fields)
        gov === nothing || (out[i] = gov)
    end
    return out
end

"""
Print the beams whose section changed on this pass, and whether the section
vector repeats an earlier pass.

`pass` 0 is the tributary sizing that precedes the shell. Active only when
`SS_TRACE_SHELL_PASSES=1`. The sizing result is unchanged.
"""
function _trace_shell_pass!(history, pass, beams, before, after, demands, service_on)
    tags = String[_section_tag(s) for s in after]
    earlier = findfirst(==(tags), history)
    push!(history, tags)
    changed = Int[]
    for i in eachindex(beams)
        _sections_identical(before[i], after[i]) || push!(changed, i)
    end
    kind = earlier === nothing ? "new" : "repeats pass $(earlier - 1)"
    println("shell pass $pass  service=$(service_on)  changed=$(length(changed))/$(length(beams))  $kind")
    isempty(changed) && return history
    by = Dict{Any, Vector{Int}}()
    for i in changed
        gid = something(group_id(beams[i]), Symbol("beam", i))
        push!(get!(() -> Int[], by, gid), i)
    end
    for gid in sort!(collect(keys(by)); by = string)
        idx = by[gid]
        i = idx[1]
        mus = [get(demands, j, nothing) for j in idx]
        mus = filter(!isnothing, mus)
        demand = if isempty(mus)
            ""
        else
            # N·m → kip·ft, N → kip. Display only.
            pos = maximum(d.Mu_pos for d in mus) / 1355.8179483314004
            neg = maximum(d.Mu_neg for d in mus) / 1355.8179483314004
            vu = maximum(d.Vu for d in mus) / 4448.2216152605
            "  Mu+=$(round(pos; digits=1)) Mu-=$(round(neg; digits=1)) kip·ft  Vu=$(round(vu; digits=1)) kip"
        end
        println("  group $gid  n=$(length(idx))  $(_section_tag(before[i])) → $(_section_tag(after[i]))$demand")
    end
    return history
end

_section_tag(::Nothing) = "none"
function _section_tag(s)
    nm = hasproperty(s, :name) ? s.name : nothing
    nm === nothing || return string(nm)
    return string(nameof(typeof(s)))
end

"""Concatenate every story's spans of one beam. The worst span governs."""
function _merge_shell_spans!(into, from)
    for (i, list) in from
        append!(get!(() -> Any[], into, i), list)
    end
    return into
end

"""
One vector of `T` spans per demand group, in `group_ids` order. Spans of
another type (the other material's record) are left out. `nothing` stays
`nothing`.
"""
function _group_shell_spans(struc, group_ids, shell_spans, ::Type{T}) where {T}
    shell_spans === nothing && return nothing
    out = Vector{Vector{T}}(undef, length(group_ids))
    for (g, gid) in enumerate(group_ids)
        list = T[]
        for m_idx in struc.member_groups[gid].member_indices
            for sp in get(shell_spans, m_idx, ())
                sp isa T && push!(list, sp)
            end
        end
        out[g] = list
    end
    return out
end
