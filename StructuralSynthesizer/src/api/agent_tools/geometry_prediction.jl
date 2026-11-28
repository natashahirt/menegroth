# ─── Geometry Remediation Evaluation ──────────────────────────────────────────

"""
    _geometry_remediation_eval(design, diag, failing_checks) -> Vector{Dict}

For each failing check, evaluate whether the actual geometry exceeds the
`GEOMETRY_REMEDIATION_MAP` thresholds. Returns matched remediations with
quantified gaps and specific Grasshopper instructions.
"""
function _geometry_remediation_eval(
    design::BuildingDesign,
    diag::Dict,
    failing_checks::Vector{Dict{String, Any}},
)::Vector{Dict{String, Any}}
    results = Dict{String, Any}[]
    struc = design.structure
    skel = struc.skeleton

    # Extract geometry metrics from the cached geometry
    edge_lengths_m = Float64[]
    if !isnothing(skel.geometry)
        for len in skel.geometry.edge_lengths
            lm = try ustrip(u"m", len) catch; Float64(len) end
            lm > 0.1 && push!(edge_lengths_m, lm)
        end
    end
    max_span_m = isempty(edge_lengths_m) ? 0.0 : maximum(edge_lengths_m)
    max_span_ft = max_span_m * 3.28084

    story_heights_m = Float64[]
    zs = skel.stories_z
    if length(zs) > 1
        for i in 2:length(zs)
            dz = try ustrip(u"m", zs[i] - zs[i-1]) catch; Float64(zs[i] - zs[i-1]) end
            push!(story_heights_m, abs(dz))
        end
    end
    max_story_m = isempty(story_heights_m) ? 0.0 : maximum(story_heights_m)

    n_columns = haskey(skel.groups_edges, :columns) ? length(skel.groups_edges[:columns]) : 0

    for fc in failing_checks
        check = get(fc, "check", "")
        norm_check = _lever_norm(check)
        remed = get(GEOMETRY_REMEDIATION_MAP, norm_check, nothing)
        isnothing(remed) && continue

        governs_when = get(remed, "geometry_likely_governs_when", Dict())
        matched = false
        gap_description = ""

        # Evaluate condition based on available thresholds
        thresh_span = get(governs_when, "max_span_m", nothing)
        thresh_story = get(governs_when, "max_story_height_m", nothing)
        thresh_trib = get(governs_when, "max_trib_area_m2", nothing)

        if !isnothing(thresh_span) && max_span_m > thresh_span
            matched = true
            target_ft = round(thresh_span * 3.28084; digits=0)
            gap_description = "Max span $(round(max_span_ft; digits=0)) ft exceeds " *
                "target ~$(target_ft) ft. Reduce by ~$(round(max_span_ft - target_ft; digits=0)) ft."
        end

        if !isnothing(thresh_story) && max_story_m > thresh_story
            matched = true
            target_ft = round(thresh_story * 3.28084; digits=0)
            actual_ft = round(max_story_m * 3.28084; digits=0)
            gap_description *= isempty(gap_description) ? "" : " "
            gap_description *= "Max story height $(actual_ft) ft exceeds target ~$(target_ft) ft."
        end

        !matched && continue

        push!(results, Dict{String, Any}(
            "check"        => check,
            "n_failing"    => get(fc, "n_failing", 0),
            "rationale"    => get(governs_when, "rationale", ""),
            "gap"          => gap_description,
            "actions"      => get(remed, "geometric_actions", []),
            "geometry_now" => Dict{String, Any}(
                "max_span_ft"    => round(max_span_ft; digits=1),
                "max_story_ft"   => round(max_story_m * 3.28084; digits=1),
                "n_columns"      => n_columns,
            ),
        ))
    end

    return results
end

# ─── Geometric Sensitivity Tool ──────────────────────────────────────────────

"""
    agent_predict_geometry_effect(variable, direction) -> Dict{String, Any}

Predict the structural effects of changing a geometric variable. Uses the static
`GEOMETRIC_SENSITIVITY_MAP` for scaling laws and economical ranges.
"""
function agent_predict_geometry_effect(
    variable::String,
    direction::String,
)::Dict{String, Any}
    valid_dirs = ["increase", "decrease"]
    direction in valid_dirs || return Dict{String, Any}(
        "error"   => "invalid_direction",
        "message" => "Direction must be one of: $(join(valid_dirs, ", ")). Got: \"$direction\".",
    )

    entry = get(GEOMETRIC_SENSITIVITY_MAP, variable, nothing)
    if isnothing(entry)
        available = sort(collect(keys(GEOMETRIC_SENSITIVITY_MAP)))
        return Dict{String, Any}(
            "error"     => "unknown_variable",
            "message"   => "Variable \"$variable\" not found. Available: $(join(available, ", ")).",
            "available" => available,
        )
    end

    # Build effects list, flipping direction labels for "decrease"
    effects = Dict{String, Any}[]
    for eff in get(entry, "affects", [])
        raw_dir = get(eff, "direction", "")
        effective_dir = if direction == "decrease"
            # Flip: "increase_span → worse" becomes "decrease_span → better"
            if occursin("worse", raw_dir)
                replace(raw_dir, "worse" => "better")
            elseif occursin("better", raw_dir)
                replace(raw_dir, "better" => "worse")
            elseif occursin("larger", raw_dir)
                replace(raw_dir, "larger" => "smaller")
            elseif occursin("thicker", raw_dir)
                replace(raw_dir, "thicker" => "thinner")
            else
                raw_dir
            end
        else
            raw_dir
        end

        push!(effects, Dict{String, Any}(
            "check"        => get(eff, "check", ""),
            "relationship" => get(eff, "relationship", ""),
            "direction"    => effective_dir,
            "explanation"  => get(eff, "explanation", ""),
        ))
    end

    result = Dict{String, Any}(
        "variable"          => variable,
        "direction"         => direction,
        "affected_checks"   => effects,
        "economical_ranges" => get(entry, "typical_economical_ranges", Dict()),
        "trade_offs"        => get(entry, "trade_offs", ""),
    )

    return result
end

