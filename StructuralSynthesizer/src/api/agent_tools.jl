# =============================================================================
# Agent Tools — implementation functions for LLM agent tool dispatch
#
# Phase 1 (Orientation): get_building_summary, get_current_params
# Phase 2 (Diagnosis):   query_elements, explain_field, get_solver_trace
# Phase 3 (Exploration):  compare_designs, suggest_next_action
# =============================================================================

using Statistics: mean, std

# ─── Phase 1: Orientation ─────────────────────────────────────────────────────

"""
    agent_building_summary(struc::BuildingStructure) -> Dict{String, Any}

Geometry-only summary: stories, member counts, span statistics, regularity.
Does not require a completed design.
"""
function agent_building_summary(struc::BuildingStructure)::Dict{String, Any}
    skel = struc.skeleton
    n_stories = length(skel.stories)
    n_cols    = length(struc.columns)
    n_beams   = length(struc.beams)
    n_slabs   = length(struc.slabs)
    n_fdns    = length(struc.foundations)

    # Story heights from skeleton.stories_z (may be Unitful or plain Float64)
    story_z = sort(skel.stories_z)
    story_heights = Float64[]
    for i in 2:length(story_z)
        dz = story_z[i] - story_z[i-1]
        push!(story_heights, try ustrip(u"m", dz) catch; Float64(dz) end)
    end

    # Edge lengths for span statistics
    beam_lengths = Float64[]
    if !isnothing(skel.geometry)
        for len in skel.geometry.edge_lengths
            lm = try ustrip(u"m", len) catch; Float64(len) end
            lm > 0.1 && push!(beam_lengths, lm)
        end
    end

    span_stats = if !isempty(beam_lengths)
        mn = minimum(beam_lengths)
        mx = maximum(beam_lengths)
        μ  = mean(beam_lengths)
        cv = length(beam_lengths) > 1 ? std(beam_lengths) / μ : 0.0
        Dict{String, Any}(
            "min_m"  => round(mn; digits=2),
            "max_m"  => round(mx; digits=2),
            "mean_m" => round(μ;  digits=2),
            "cv"     => round(cv; digits=3),
            "n_edges" => length(beam_lengths),
        )
    else
        nothing
    end

    height_stats = if !isempty(story_heights)
        Dict{String, Any}(
            "min_m" => round(minimum(story_heights); digits=2),
            "max_m" => round(maximum(story_heights); digits=2),
            "total_m" => round(sum(story_heights); digits=2),
        )
    else
        nothing
    end

    # Regularity classification
    regularity = "regular"
    if !isnothing(span_stats) && span_stats["cv"] > 0.15
        regularity = "irregular_spans"
    end
    if !isempty(story_heights) && maximum(story_heights) - minimum(story_heights) > 0.3
        if regularity == "regular"
            regularity = "irregular_heights"
        else
            regularity = "irregular_spans_and_heights"
        end
    end

    # Structural semantics: flags that help the LLM identify important characteristics
    flags = String[]

    if !isempty(beam_lengths)
        max_span_ft = maximum(beam_lengths) * 3.28084
        if max_span_ft > 30.0
            push!(flags, "long_spans_over_30ft")
        end
        if span_stats !== nothing && span_stats["cv"] > 0.25
            push!(flags, "highly_variable_spans")
        end
    end

    if !isempty(story_heights)
        if maximum(story_heights) - minimum(story_heights) > 0.5
            push!(flags, "variable_story_heights")
        end
        if any(h -> h > 5.0, story_heights)
            push!(flags, "tall_story_over_5m")
        end
    end

    if n_stories > 1
        col_per_story = try
            [count(c -> c.second isa StructuralSizer.AbstractMember, struc.columns)]
        catch
            Int[]
        end
        if length(col_per_story) > 1 && maximum(col_per_story) != minimum(col_per_story)
            push!(flags, "varying_columns_per_level")
        end
    end

    if n_slabs > 0 && n_cols > 0
        slab_to_col = n_slabs / n_cols
        if slab_to_col > 2.0
            push!(flags, "high_slab_to_column_ratio")
        end
    end

    result = Dict{String, Any}(
        "n_stories"     => n_stories,
        "n_columns"     => n_cols,
        "n_beams"       => n_beams,
        "n_slabs"       => n_slabs,
        "n_foundations"  => n_fdns,
        "story_heights" => height_stats,
        "span_stats"    => span_stats,
        "regularity"    => regularity,
    )

    if !isempty(flags)
        result["structural_flags"] = flags
    end

    return result
end

"""
    agent_current_params(design::BuildingDesign) -> Dict{String, Any}

Return the fully resolved parameter set from the last design, formatted for
the agent. Uses `_diagnose_design_context` from diagnose.jl as the core.
"""
function agent_current_params(design::BuildingDesign)::Dict{String, Any}
    params = design.params
    du = params.display_units

    ctx = _diagnose_design_context(params, du)

    ctx["optimize_for"]    = string(params.optimize_for)
    ctx["max_iterations"]  = params.max_iterations
    ctx["fire_rating"]     = params.fire_rating
    ctx["pattern_loading"] = string(params.pattern_loading)

    # Material details
    mats = params.materials
    ctx["materials"] = Dict{String, Any}(
        "concrete_fc_psi" => try round(ustrip(u"psi", mats.concrete.fc); digits=0) catch; nothing end,
        "rebar_fy_ksi"    => try round(ustrip(u"ksi", mats.rebar.fy); digits=1) catch; nothing end,
        "steel_Fy_ksi"    => try round(ustrip(u"ksi", mats.steel.Fy); digits=1) catch; nothing end,
    )

    return ctx
end

"""
    agent_situation_card(struc, design, history) -> Dict{String, Any}

Single-call orientation snapshot. Combines geometry overview, resolved params,
results health, and session history status into one compact payload so the
LLM can orient itself without multiple tool calls.
"""
function agent_situation_card(
    struc::Union{BuildingStructure, Nothing},
    design::Union{BuildingDesign, Nothing},
    history::Vector{DesignHistoryEntry},
)::Dict{String, Any}
    card = Dict{String, Any}("has_geometry" => !isnothing(struc), "has_design" => !isnothing(design))

    if !isnothing(struc)
        card["geometry"] = agent_building_summary(struc)
    end

    if !isnothing(design)
        card["params"] = agent_current_params(design)

        s = design.summary
        n_fail = count(p -> !p.second.ok, design.columns) +
                 count(p -> !p.second.ok, design.beams) +
                 count(p -> !(p.second.converged && p.second.deflection_ok && p.second.punching_ok), design.slabs) +
                 count(p -> !p.second.ok, design.foundations)
        card["health"] = Dict{String, Any}(
            "all_pass"         => s.all_checks_pass,
            "critical_ratio"   => round(s.critical_ratio; digits=3),
            "critical_element" => s.critical_element,
            "embodied_carbon"  => round(s.embodied_carbon; digits=0),
            "n_elements"       => length(design.columns) + length(design.beams) +
                                  length(design.slabs) + length(design.foundations),
            "n_failing"        => n_fail,
        )
        card["has_trace"] = !isempty(design.solver_trace)
    end

    card["session"] = Dict{String, Any}(
        "n_designs" => length(history),
        "latest_passed" => isempty(history) ? nothing : last(history).all_pass,
    )

    return card
end

"""
    agent_diagnose_summary(design::BuildingDesign) -> Dict{String, Any}

Lightweight failure overview: counts by element type, top-N critical elements,
and failure breakdown by governing check — without the full per-element dump.
Designed for progressive disclosure: call this first, then `get_diagnose` or
`query_elements` for detail.
"""
function agent_diagnose_summary(design::BuildingDesign)::Dict{String, Any}
    diag = design_to_diagnose(design)
    eng = get(diag, "engineering", Dict())

    type_stats = Dict{String, Any}()
    all_elements = Pair{Float64, Dict{String, Any}}[]
    check_counts = Dict{String, Int}()

    for (etype, plural) in [("column", "columns"), ("beam", "beams"),
                             ("slab", "slabs"), ("foundation", "foundations")]
        elems = get(eng, plural, Any[])
        n_total = length(elems)
        n_fail = count(e -> !get(e, "ok", true), elems)
        type_stats[etype] = Dict{String, Any}("total" => n_total, "failing" => n_fail)

        for e in elems
            ratio = get(e, "governing_ratio", 0.0)
            push!(all_elements, ratio => e)
            if !get(e, "ok", true)
                gc = get(e, "governing_check", "unknown")
                check_counts[gc] = get(check_counts, gc, 0) + 1
            end
        end
    end

    sort!(all_elements; by=first, rev=true)
    top_n = min(5, length(all_elements))
    top_critical = [Dict{String, Any}(
        "type"             => get(e, "type", ""),
        "id"               => get(e, "id", ""),
        "governing_ratio"  => round(ratio; digits=3),
        "governing_check"  => get(e, "governing_check", ""),
        "ok"               => get(e, "ok", true),
    ) for (ratio, e) in all_elements[1:top_n]]

    # Rank failure checks by frequency
    sorted_checks = sort(collect(check_counts); by=last, rev=true)
    failure_breakdown = [Dict("check" => k, "count" => v) for (k, v) in sorted_checks]

    return Dict{String, Any}(
        "by_type"           => type_stats,
        "top_critical"      => top_critical,
        "failure_breakdown" => failure_breakdown,
        "n_total_elements"  => length(all_elements),
        "n_total_failing"   => sum(s -> s["failing"], values(type_stats)),
        "note"              => "Use query_elements or get_diagnose for full per-element detail.",
    )
end

# ─── Phase 2: Diagnosis ──────────────────────────────────────────────────────

"""
    agent_query_elements(design::BuildingDesign; kwargs...) -> Dict{String, Any}

Run `design_to_diagnose` and filter elements by the given criteria.
"""
function agent_query_elements(
    design::BuildingDesign;
    type::Union{String, Nothing}=nothing,
    min_ratio::Union{Float64, Nothing}=nothing,
    max_ratio::Union{Float64, Nothing}=nothing,
    governing_check::Union{String, Nothing}=nothing,
    ok::Union{Bool, Nothing}=nothing,
)::Dict{String, Any}
    diag = design_to_diagnose(design)

    function _matches(d::Dict)
        if !isnothing(min_ratio)
            get(d, "governing_ratio", 0.0) < min_ratio && return false
        end
        if !isnothing(max_ratio)
            get(d, "governing_ratio", 0.0) > max_ratio && return false
        end
        if !isnothing(governing_check)
            get(d, "governing_check", "") != governing_check && return false
        end
        if !isnothing(ok)
            get(d, "ok", true) != ok && return false
        end
        return true
    end

    results = Dict{String, Any}()
    type_map = Dict(
        "column"     => "columns",
        "beam"       => "beams",
        "slab"       => "slabs",
        "foundation" => "foundations",
    )

    types_to_check = isnothing(type) ? keys(type_map) : [type]
    total = 0

    for t in types_to_check
        key = get(type_map, t, t * "s")
        elements = get(diag, key, [])
        matched = filter(_matches, elements)
        if !isempty(matched)
            results[key] = matched
            total += length(matched)
        end
    end

    results["total_matched"] = total
    results["unit_system"]   = get(diag, "unit_system", "imperial")
    return results
end

"""
    agent_explain_field(field_name::String) -> Dict{String, Any}

Look up a field in `api_params_schema_structured()` and return its metadata.
"""
function agent_explain_field(field_name::String)::Dict{String, Any}
    schema = api_params_schema_structured()
    fn_lower = lowercase(field_name)

    # Walk the schema looking for the field
    for (top_key, top_val) in schema
        if lowercase(string(top_key)) == fn_lower
            return Dict{String, Any}(
                "field"   => string(top_key),
                "details" => top_val,
            )
        end
        if top_val isa Dict
            for (sub_key, sub_val) in top_val
                full_key = "$(top_key).$(sub_key)"
                if lowercase(string(sub_key)) == fn_lower || lowercase(full_key) == fn_lower
                    return Dict{String, Any}(
                        "field"   => full_key,
                        "details" => sub_val,
                    )
                end
                if sub_val isa Dict
                    for (inner_key, inner_val) in sub_val
                        full_inner = "$(top_key).$(sub_key).$(inner_key)"
                        if lowercase(string(inner_key)) == fn_lower || lowercase(full_inner) == fn_lower
                            return Dict{String, Any}(
                                "field"   => full_inner,
                                "details" => inner_val,
                            )
                        end
                    end
                end
            end
        end
    end

    return Dict{String, Any}(
        "error"   => "field_not_found",
        "message" => "Field \"$field_name\" not found in the parameter schema. " *
                     "Use get_applicability or check the /schema endpoint for valid field names.",
    )
end

# ─── Phase 3: Exploration ─────────────────────────────────────────────────────

"""
    agent_compare_designs(index_a::Int, index_b::Int) -> Dict{String, Any}

Compare two designs from session history. Index 0 means "current" (latest).
"""
function agent_compare_designs(index_a::Int, index_b::Int)::Dict{String, Any}
    history = get_design_history_entries()
    isempty(history) && return Dict("error" => "no_history", "message" => "No designs in session history yet.")

    function _get_entry(idx)
        idx == 0 && return last(history)
        (idx < 1 || idx > length(history)) && return nothing
        return history[idx]
    end

    a = _get_entry(index_a)
    b = _get_entry(index_b)
    isnothing(a) && return Dict("error" => "invalid_index", "message" => "index_a=$index_a is out of range (1..$(length(history)), or 0 for current).")
    isnothing(b) && return Dict("error" => "invalid_index", "message" => "index_b=$index_b is out of range (1..$(length(history)), or 0 for current).")

    # Compute deltas
    Δ_ratio = round(b.critical_ratio - a.critical_ratio; digits=4)
    Δ_ec    = round(b.embodied_carbon - a.embodied_carbon; digits=0)
    Δ_fail  = b.n_failing - a.n_failing

    # Find params that differ
    all_keys = union(keys(a.params_patch), keys(b.params_patch))
    changed_params = Dict{String, Any}()
    for k in all_keys
        va = get(a.params_patch, k, nothing)
        vb = get(b.params_patch, k, nothing)
        if va != vb
            changed_params[k] = Dict("from" => va, "to" => vb)
        end
    end

    return Dict{String, Any}(
        "design_a" => Dict(
            "index"          => index_a == 0 ? length(history) : index_a,
            "all_pass"       => a.all_pass,
            "critical_ratio" => a.critical_ratio,
            "embodied_carbon" => a.embodied_carbon,
            "n_failing"      => a.n_failing,
            "source"         => a.source,
        ),
        "design_b" => Dict(
            "index"          => index_b == 0 ? length(history) : index_b,
            "all_pass"       => b.all_pass,
            "critical_ratio" => b.critical_ratio,
            "embodied_carbon" => b.embodied_carbon,
            "n_failing"      => b.n_failing,
            "source"         => b.source,
        ),
        "deltas" => Dict(
            "critical_ratio_delta"  => Δ_ratio,
            "embodied_carbon_delta" => Δ_ec,
            "n_failing_delta"       => Δ_fail,
            "pass_improved"         => !a.all_pass && b.all_pass,
            "pass_regressed"        => a.all_pass && !b.all_pass,
        ),
        "changed_params" => changed_params,
    )
end

"""
    agent_suggest_next_action(design::BuildingDesign, goal::String) -> Dict{String, Any}

Return ranked parameter suggestions for the given goal by pulling from
the /diagnose architectural and constraint layers.
"""
function agent_suggest_next_action(design::BuildingDesign, goal::String)::Dict{String, Any}
    valid_goals = ["fix_failures", "reduce_column_size", "reduce_slab_thickness", "reduce_ec"]
    goal in valid_goals || return Dict(
        "error"   => "invalid_goal",
        "message" => "Goal must be one of: $(join(valid_goals, ", ")). Got: \"$goal\".",
    )

    diag = design_to_diagnose(design)
    arch = get(diag, "architectural", Dict())
    cons = get(diag, "constraints", Dict())

    recs = get(arch, "goal_recommendations", [])
    impacts = get(cons, "lever_impacts", [])

    # Filter recommendations matching this goal
    goal_recs = filter(r -> get(r, "goal", "") == goal, recs)

    # Map goal to related lever impacts
    goal_params = Dict(
        "fix_failures"          => ["punching_strategy", "deflection_limit", "column_catalog", "beam_catalog"],
        "reduce_column_size"    => ["punching_strategy", "column_catalog"],
        "reduce_slab_thickness" => ["deflection_limit"],
        "reduce_ec"             => ["deflection_limit", "punching_strategy"],
    )
    related_params = get(goal_params, goal, String[])
    goal_impacts = filter(i -> get(i, "parameter", "") in related_params, impacts)

    summary = get(diag, "agent_summary", Dict())

    return Dict{String, Any}(
        "goal"               => goal,
        "recommendations"    => goal_recs,
        "lever_impacts"      => goal_impacts,
        "current_status"     => Dict(
            "all_pass"       => get(summary, "all_pass", false),
            "critical_ratio" => get(summary, "critical_ratio", 0.0),
            "n_failing"      => get(summary, "n_failing", 0),
        ),
        "note" => "Recommendations are from the /diagnose architectural layer. " *
                  "Lever impacts are analytical or estimated — use run_design for exact results.",
    )
end

# ─── Phase 2 continued: Solver Trace ─────────────────────────────────────────
#
# Core serialization helpers (serialize_trace_event, build_stage_timeline,
# filter_trace, TIER_EVENT_FILTERS, etc.) live in StructuralSizer.trace so
# they can be tested independently. This function assembles the LLM-facing
# response Dict using those shared primitives.
# ─────────────────────────────────────────────────────────────────────────────

"""
    agent_solver_trace(design::BuildingDesign; tier, element, layer) -> Dict{String, Any}

Tiered serializer for the solver decision trace. Returns a structured Dict
optimized for LLM consumption.

# Tiers (progressive disclosure)
- `:summary`   — pipeline/workflow enter/exit only (~5–15 events)
- `:failures`  — summary + all failure/fallback events
- `:decisions` — failures + decision/iteration events
- `:full`      — every recorded event

# Filters
- `element::String` — restrict to events matching this `element_id`
- `layer::Symbol`   — restrict to events from this trace layer

The return Dict includes metadata (`tier`, `total_events`, `shown_events`,
`layers_present`) so the LLM knows what it's seeing and can request a
deeper tier or narrower filter if needed.
"""
function agent_solver_trace(
    design::BuildingDesign;
    tier::Symbol = :failures,
    element::Union{String, Nothing} = nothing,
    layer::Union{Symbol, Nothing} = nothing,
)::Dict{String, Any}
    events = design.solver_trace

    if isempty(events)
        return Dict{String, Any}(
            "tier"         => string(tier),
            "total_events" => 0,
            "shown_events" => 0,
            "events"       => Any[],
            "note"         => "No solver trace available. The design may have been run " *
                              "without tracing enabled, or from Grasshopper (which does " *
                              "not yet pass a TraceCollector).",
        )
    end

    tier in StructuralSizer.TRACE_TIERS || return Dict{String, Any}(
        "error"   => "invalid_tier",
        "message" => "Tier must be one of: $(join(StructuralSizer.TRACE_TIERS, ", ")). Got: :$tier",
    )

    filtered = StructuralSizer.filter_trace(events; tier, element, layer)

    layers_present = sort(unique(string(ev.layer) for ev in events))
    elements_present = sort(unique(ev.element_id for ev in events if !isempty(ev.element_id)))

    serialized = StructuralSizer.serialize_trace_event.(filtered)
    timeline   = StructuralSizer.build_stage_timeline(events)

    result = Dict{String, Any}(
        "tier"              => string(tier),
        "total_events"      => length(events),
        "shown_events"      => length(serialized),
        "layers_present"    => layers_present,
        "elements_present"  => elements_present,
        "stage_timeline"    => timeline,
        "events"            => serialized,
    )

    if !isnothing(element)
        result["filter_element"] = element
    end
    if !isnothing(layer)
        result["filter_layer"] = string(layer)
    end

    if tier == :summary && any(ev -> ev.event_type in (:failure, :fallback), events)
        result["hint"] = "Failures detected in trace. Use tier=failures to see them."
    elseif tier == :failures && any(ev -> ev.event_type in (:decision, :iteration), events)
        n_decisions = count(ev -> ev.event_type in (:decision, :iteration), events)
        result["hint"] = "$n_decisions decision/iteration events available. Use tier=decisions for detail."
    end

    return result
end
