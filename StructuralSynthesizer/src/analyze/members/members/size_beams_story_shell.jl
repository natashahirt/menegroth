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
#   M⁻, simple steel beam            frame model    the shell's is reported only
#   Stud fields, per combination     shell          composite per-station check
#   Stud fields, simple steel beam   frame model    composite per-station check
#   Composite I_LB / I_neg map       frame model    recorded as a stiffness
#                                                   profile; the shell reads it
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
one story shell. The beam stays `simple` only if every shell says so.
"""
function _merge_shell_demand!(into::Dict{Int, ShellBeamDemand}, from)
    for (i, d) in from
        old = get(into, i, nothing)
        into[i] = old === nothing ? d : ShellBeamDemand(
            max(old.Mu_pos, d.Mu_pos), max(old.Mu_neg, d.Mu_neg), max(old.Vu, d.Vu),
            vcat(old.moment_fields, d.moment_fields), old.simple && d.simple)
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
Each beam's service-shell spans are a separate deflection check (see the
ownership table at the top of this file).

Returns `(converged, passes, demands, service_converged, region_mismatch)`.
`converged` is false when the last pass still changed a section, so those
sections were not solved in the shell. `service_converged` is false when a
cracked service solve stopped on its iteration cap. `region_mismatch` maps
each composite beam not on simple connections to
[`composite_region_mismatch`](@ref): how far the
frame model's sagging regions, which placed `I_LB` and `I_neg`, sit from the
shell's. A beam past `region_tol` (fraction of its length) is warned about.

# ENGINEERING JUDGMENT
`region_tol = 0.05` is a reporting threshold, not a code limit.
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
    for pass in 1:max_passes
        empty!(demands)
        empty!(spans)
        for level in lvls
            res = analyze_story_shell(struc, level; shell_kwargs...)
            res.analysis_status === :analyzed || throw(ArgumentError(
                "story $level shell was not analyzed: $(join(res.reasons, "; "))"))
            _merge_shell_demand!(demands, res.beam_demands)
            _merge_shell_spans!(spans, res.service_spans)
            service_converged &= res.service_converged
        end
        before = [_story_beam_section(struc, b) for b in struc.beams]
        size_beams!(struc, opts; shell_demands = demands, shell_spans = spans, kwargs...)
        after = [_story_beam_section(struc, b) for b in struc.beams]
        all(_sections_identical(a, b) for (a, b) in zip(before, after)) &&
            return (converged = true, passes = pass, demands = demands,
                    service_converged = service_converged,
                    region_mismatch = _region_mismatches(struc, demands, region_tol))
    end
    @warn "Beam sections still changed after $max_passes story-shell passes"
    return (converged = false, passes = max_passes, demands = demands,
            service_converged = service_converged,
            region_mismatch = _region_mismatches(struc, demands, region_tol))
end

"""
    composite_region_mismatch(profile, fields) -> Float64

Largest distance, as a fraction of the beam, between a zero-moment boundary
of the frame model's sagging regions (`profile.regions`, where `I_LB` and
`I_neg` were placed) and the matching boundary of the shell field in
`fields` with the greatest sagging peak. `Inf` when the two have a different
number of sagging regions. Zero when there are no fields.

Both are in the station coordinate of [`beam_signed_moment_field`](@ref).
"""
function composite_region_mismatch(profile, fields)
    isempty(fields) && return 0.0
    shell = [StructuralSizer.positive_moment_regions(f; breakpoints = f.breakpoints)
             for f in fields]
    peak(rs) = isempty(rs) ? -Inf : maximum(r -> r.M_peak, rs)
    gov = shell[argmax(k -> peak(shell[k]), eachindex(shell))]
    length(gov) == length(profile.regions) || return Inf
    worst = 0.0
    for (a, b) in zip(profile.regions, gov)
        worst = max(worst, abs(a.s_left - b.s_left), abs(a.s_right - b.s_right))
    end
    return worst
end

"""
[`composite_region_mismatch`](@ref) for every beam with a matching profile.
Warns once, listing the beams past `tol`. A simple-connection steel beam is
left out: its studs follow the frame model's regions by design, and the
shell's hogging next to its supports is the slab's (see
[`analyze_story_shell`](@ref)).
"""
function _region_mismatches(struc, demands, tol)
    out = Dict{Int, Float64}()
    for (i, d) in demands
        d.simple && continue
        beam = struc.beams[i]
        prof = composite_stiffness_profile(struc, beam)
        prof === nothing && continue
        _sections_identical(prof.section, _story_beam_section(struc, beam)) || continue
        out[i] = composite_region_mismatch(prof, d.moment_fields)
    end
    far = sort!([i for (i, m) in out if m > tol])
    isempty(far) || @warn "Frame-model and shell sagging regions differ by more than " *
        "$(tol) of the span; I_LB / I_neg may sit in the wrong place" beams = far
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
