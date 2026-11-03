# =============================================================================
# Beam sizing against the story shell
# =============================================================================

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

Returns `(converged, passes, demands)`. `converged` is false when the last
pass still changed a section, so those sections were not solved in the shell.
"""
function size_beams_with_story_shell!(struc::BuildingStructure,
                                      opts::Union{StructuralSizer.BeamOptions, Nothing} = nothing;
                                      levels = nothing,
                                      max_passes::Int = 4,
                                      shell_kwargs = (;),
                                      kwargs...)
    max_passes >= 1 || throw(ArgumentError("max_passes must be at least 1"))
    lvls = levels === nothing ? _story_shell_levels(struc) : collect(levels)
    isempty(lvls) && throw(ArgumentError("no story has a slab panel for the story shell"))
    # Catalog shapes carry no material; the shell takes the options' steel.
    if opts isa StructuralSizer.SteelBeamOptions && !haskey(shell_kwargs, :steel)
        shell_kwargs = merge((steel = opts.material,), shell_kwargs)
    end

    size_beams!(struc, opts; kwargs...)
    demands = Dict{Int, ShellBeamDemand}()
    for pass in 1:max_passes
        empty!(demands)
        for level in lvls
            res = analyze_story_shell(struc, level; shell_kwargs...)
            res.analysis_status === :analyzed || throw(ArgumentError(
                "story $level shell was not analyzed: $(join(res.reasons, "; "))"))
            _merge_shell_demand!(demands, res.beam_demands)
        end
        before = [_story_beam_section(struc, b) for b in struc.beams]
        size_beams!(struc, opts; shell_demands = demands, kwargs...)
        after = [_story_beam_section(struc, b) for b in struc.beams]
        all(_sections_identical(a, b) for (a, b) in zip(before, after)) &&
            return (converged = true, passes = pass, demands = demands)
    end
    @warn "Beam sections still changed after $max_passes story-shell passes"
    return (converged = false, passes = max_passes, demands = demands)
end
