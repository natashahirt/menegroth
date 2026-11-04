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
    size_beams_with_story_shell!(struc, opts=nothing; levels, max_passes=4,
                                 shell_kwargs=(;), kwargs...) -> NamedTuple

Size beams from their tributary demand, then resize them against the story
shell until the sections stop changing.

Each pass solves the shell of every story in `levels` with the current
sections and resizes with [`size_beams!`](@ref), which takes the larger of
the tributary demand and the [`ShellBeamDemand`](@ref). A beam's stiffness
sets how much load the shell sends it, so a pass that changes a section is
followed by another. `shell_kwargs` go to [`analyze_story_shell`](@ref);
`kwargs` go to `size_beams!`.

A story that is not `:analyzed` throws: one of its beams would be sized
without its shell demand. A composite steel beam is checked on each load
combination's shell moment field as well (see [`size_beams!`](@ref)), and its
shell stiffness is the composite inertia of the section from the pass before.
That inertia is placed on the shell's own sagging regions from the pass
before (the combination with the greatest sagging peak); the first pass uses
the frame model's. Each beam's service-shell spans are a separate deflection
check (see the ownership table at the top of this file).

Returns `(converged, passes, demands, service_converged, region_mismatch)`.
`converged` is true when a pass changed no section and moved no composite
beam's sagging regions by more than `region_tol` (fraction of its length).
`service_converged` is false when a cracked service solve stopped on its
iteration cap. `region_mismatch` maps each composite beam to that last
movement: how far the regions its shell stiffness was placed on sit from the
regions the solve produced.

# ENGINEERING JUDGMENT
`region_tol = 0.05` is a convergence threshold, not a code limit.
"""
function size_beams_with_story_shell!(struc::BuildingStructure,
                                      opts::Union{StructuralSizer.BeamOptions, Nothing} = nothing;
                                      levels = nothing,
                                      max_passes::Int = 4,
                                      shell_kwargs = (;),
                                      region_tol::Real = 0.05,
                                      kwargs...)
    max_passes >= 1 || throw(ArgumentError("max_passes must be at least 1"))
    lvls = levels === nothing ? _story_shell_levels(struc) : collect(levels)
    isempty(lvls) && throw(ArgumentError("no story has a slab panel for the story shell"))
    # Catalog shapes carry no material; the shell takes the options' steel.
    if opts isa StructuralSizer.SteelBeamOptions && !haskey(shell_kwargs, :steel)
        shell_kwargs = merge((steel = opts.material,), shell_kwargs)
    end
    if opts isa StructuralSizer.ConcreteBeamOptions &&
            !haskey(shell_kwargs, :sustained_live_fraction)
        shell_kwargs = merge((sustained_live_fraction = opts.sustained_live_fraction,),
                             shell_kwargs)
    end

    size_beams!(struc, opts; kwargs...)
    demands = Dict{Int, ShellBeamDemand}()
    spans = Dict{Int, Vector{Any}}()
    service_converged = true
    next_regions = Dict{Int, Vector{NamedTuple}}()
    shifts = Dict{Int, Float64}()
    for pass in 1:max_passes
        empty!(demands)
        empty!(spans)
        used = Dict{Int, Vector{NamedTuple}}()
        for level in lvls
            res = analyze_story_shell(struc, level; composite_regions = next_regions,
                                      shell_kwargs...)
            res.analysis_status === :analyzed || throw(ArgumentError(
                "story $level shell was not analyzed: $(join(res.reasons, "; "))"))
            _merge_shell_demand!(demands, res.beam_demands)
            _merge_shell_spans!(spans, res.service_spans)
            merge!(used, res.composite_regions)
            service_converged &= res.service_converged
        end
        before = [_story_beam_section(struc, b) for b in struc.beams]
        size_beams!(struc, opts; shell_demands = demands, shell_spans = spans, kwargs...)
        after = [_story_beam_section(struc, b) for b in struc.beams]
        shifts = _region_shifts(demands, used)
        next_regions = _next_shell_regions(demands, used)
        held = all(_sections_identical(a, b) for (a, b) in zip(before, after))
        settled = all(<=(region_tol), values(shifts))
        held && settled &&
            return (converged = true, passes = pass, demands = demands,
                    service_converged = service_converged, region_mismatch = shifts)
    end
    moving = sort!([i for (i, m) in shifts if m > region_tol])
    @warn "Beam sections or composite sagging regions still changed after " *
          "$max_passes story-shell passes" regions_moving = moving
    return (converged = false, passes = max_passes, demands = demands,
            service_converged = service_converged, region_mismatch = shifts)
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
