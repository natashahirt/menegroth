# =============================================================================
# Agent Tools — implementation functions for LLM agent tool dispatch
#
# Phase 1 (Orientation): get_building_summary, get_current_params
# Phase 2 (Diagnosis):   query_elements, explain_field
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

    return Dict{String, Any}(
        "n_stories"     => n_stories,
        "n_columns"     => n_cols,
        "n_beams"       => n_beams,
        "n_slabs"       => n_slabs,
        "n_foundations"  => n_fdns,
        "story_heights" => height_stats,
        "span_stats"    => span_stats,
        "regularity"    => regularity,
    )
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
