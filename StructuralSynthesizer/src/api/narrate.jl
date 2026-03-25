# =============================================================================
# Narrate — audience-aware plain-English explanations for the LLM agent
#
# narrate_element:    explain one element's design for an architect or engineer
# narrate_comparison: explain the difference between two designs
# =============================================================================

"""
    agent_narrate_element(design::BuildingDesign, element_type::String,
                          element_id::Int, audience::String) -> Dict{String, Any}

Compose a plain-English paragraph about one element, using data from
the /diagnose output. Architect version uses physical analogies and scale
references; engineer version uses code clauses and ratios.
"""
function agent_narrate_element(
    design::BuildingDesign,
    element_type::String,
    element_id::Int,
    audience::String,
)::Dict{String, Any}

    valid_types = ["column", "beam", "slab", "foundation"]
    element_type in valid_types || return Dict(
        "error"   => "invalid_type",
        "message" => "element_type must be one of: $(join(valid_types, ", ")).",
    )
    audience in ("architect", "engineer") || return Dict(
        "error"   => "invalid_audience",
        "message" => "audience must be \"architect\" or \"engineer\".",
    )

    diag = design_to_diagnose(design)
    type_key = element_type * "s"
    elements = get(diag, type_key, [])

    elem = nothing
    for e in elements
        if get(e, "id", -1) == element_id
            elem = e
            break
        end
    end

    isnothing(elem) && return Dict(
        "error"   => "element_not_found",
        "message" => "No $element_type with id=$element_id found in the design.",
    )

    governing   = get(elem, "governing_check", "unknown")
    ratio       = get(elem, "governing_ratio", 0.0)
    mode        = get(elem, "governing_mode", "")
    ok          = get(elem, "ok", true)
    levers      = get(elem, "levers", String[])
    description = get(elem, "limit_state_description", "")
    scale_ref   = get(elem, "scale_ref", nothing)
    ec          = get(elem, "ec_kgco2e", nothing)

    # Build checks summary
    checks = get(elem, "checks", [])
    checks_summary = join([
        "$(get(c, "name", "?")) (ratio=$(get(c, "ratio", "?")))"
        for c in checks
    ], ", ")

    if audience == "architect"
        narrative = _narrate_architect(element_type, element_id, governing, ratio,
                                       ok, mode, scale_ref, ec, description, levers)
    else
        narrative = _narrate_engineer(element_type, element_id, governing, ratio,
                                      ok, mode, checks_summary, ec, description, levers, checks)
    end

    return Dict{String, Any}(
        "narrative"    => narrative,
        "element_type" => element_type,
        "element_id"   => element_id,
        "audience"     => audience,
        "key_facts"    => Dict{String, Any}(
            "governing_check" => governing,
            "ratio"           => ratio,
            "ok"              => ok,
            "mode"            => mode,
            "ec_kgco2e"       => ec,
        ),
    )
end

function _narrate_architect(type, id, governing, ratio, ok, mode, scale_ref, ec, description, levers)
    status = ok ? "passes all checks" : "is failing"
    utilization = round(ratio * 100; digits=0)

    parts = String[]
    push!(parts, "$(_capitalize(type)) $id $status and is $(utilization)% utilized.")

    if !isnothing(scale_ref) && !isempty(scale_ref)
        push!(parts, "Physically, $scale_ref.")
    end

    if !isempty(description)
        push!(parts, description)
    end

    if mode == "minimum_governed"
        push!(parts, "This element is already at its minimum practical size — it can't get smaller with the current system.")
    end

    if !ok && !isempty(levers)
        push!(parts, "To address this, you could adjust: $(join(levers, ", ")).")
    end

    if !isnothing(ec) && ec > 0
        push!(parts, "Its carbon footprint is approximately $(round(ec; digits=0)) kgCO2e.")
    end

    return join(parts, " ")
end

function _narrate_engineer(type, id, governing, ratio, ok, mode, checks_summary, ec, description, levers, checks)
    status = ok ? "OK" : "FAILING"

    parts = String[]
    push!(parts, "$(_capitalize(type)) $id: $status (governing: $governing, ratio=$(round(ratio; digits=3))).")
    push!(parts, "Checks: $checks_summary.")

    # Include code clauses from checks
    for c in checks
        clause = get(c, "code_clause", nothing)
        if !isnothing(clause) && get(c, "name", "") == governing
            push!(parts, "Governing clause: $clause.")
            break
        end
    end

    if mode == "minimum_governed"
        push!(parts, "Mode: minimum-governed (large headroom — element at catalog/code minimum).")
    else
        push!(parts, "Mode: structural demand governs sizing.")
    end

    if !ok && !isempty(levers)
        push!(parts, "Recommended levers: $(join(levers, ", ")).")
    end

    if !isnothing(ec) && ec > 0
        push!(parts, "Embodied carbon: $(round(ec; digits=0)) kgCO2e.")
    end

    return join(parts, " ")
end

_capitalize(s::String) = isempty(s) ? s : uppercase(s[1:1]) * s[2:end]

# ─── Comparison Narration ─────────────────────────────────────────────────────

"""
    agent_narrate_comparison(index_a::Int, index_b::Int, audience::String) -> Dict{String, Any}

Compose a plain-English paragraph comparing two designs from session history.
"""
function agent_narrate_comparison(index_a::Int, index_b::Int, audience::String)::Dict{String, Any}
    audience in ("architect", "engineer") || return Dict(
        "error"   => "invalid_audience",
        "message" => "audience must be \"architect\" or \"engineer\".",
    )

    delta = agent_compare_designs(index_a, index_b)
    haskey(delta, "error") && return delta

    a = delta["design_a"]
    b = delta["design_b"]
    d = delta["deltas"]
    changed = delta["changed_params"]

    if audience == "architect"
        narrative = _narrate_comparison_architect(a, b, d, changed)
    else
        narrative = _narrate_comparison_engineer(a, b, d, changed)
    end

    return Dict{String, Any}(
        "narrative" => narrative,
        "audience"  => audience,
        "deltas"    => d,
        "changed_params" => changed,
    )
end

function _narrate_comparison_architect(a, b, d, changed)
    parts = String[]

    if d["pass_improved"]
        push!(parts, "The new design fixes all structural issues — every element now passes.")
    elseif d["pass_regressed"]
        push!(parts, "Warning: the new design introduced failures that weren't present before.")
    elseif b["all_pass"] && a["all_pass"]
        push!(parts, "Both designs pass all checks.")
    end

    Δ_ec = d["embodied_carbon_delta"]
    if abs(Δ_ec) > 10
        pct = round(Δ_ec / max(a["embodied_carbon"], 1.0) * 100; digits=0)
        direction = Δ_ec < 0 ? "less" : "more"
        push!(parts, "The new design uses about $(abs(round(Δ_ec; digits=0))) kgCO2e $direction carbon ($(abs(pct))% change).")
    end

    Δ_fail = d["n_failing_delta"]
    if Δ_fail != 0
        direction = Δ_fail < 0 ? "fewer" : "more"
        push!(parts, "There are $(abs(Δ_fail)) $direction failing elements.")
    end

    if !isempty(changed)
        push!(parts, "Changed parameters: $(join(keys(changed), ", ")).")
    end

    isempty(parts) && push!(parts, "The two designs are very similar in overall performance.")
    return join(parts, " ")
end

function _narrate_comparison_engineer(a, b, d, changed)
    parts = String[]

    Δ_ratio = d["critical_ratio_delta"]
    push!(parts, "Critical ratio: $(a["critical_ratio"]) -> $(b["critical_ratio"]) (Δ=$(round(Δ_ratio; digits=4))).")

    push!(parts, "Failing elements: $(a["n_failing"]) -> $(b["n_failing"]).")

    Δ_ec = d["embodied_carbon_delta"]
    push!(parts, "Embodied carbon: $(a["embodied_carbon"]) -> $(b["embodied_carbon"]) kgCO2e (Δ=$(round(Δ_ec; digits=0))).")

    if !isempty(changed)
        for (k, v) in changed
            push!(parts, "  $k: $(v["from"]) -> $(v["to"])")
        end
    end

    if d["pass_improved"]
        push!(parts, "Result: all checks now pass.")
    elseif d["pass_regressed"]
        push!(parts, "WARNING: regression — checks no longer pass.")
    end

    return join(parts, " ")
end
