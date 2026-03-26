# =============================================================================
# Narrate — audience-aware LLM explanations for the agent
#
# narrate_element:    explain one element's design
#   - Presets: architect / engineer (fixed single-paragraph style).
#   - Free-text audience: treated as a reader persona in the system prompt; JSON
#     facts stay in the user message (Grasshopper Element Inspector).
# narrate_comparison: explain the difference between two designs (same audience rules)
# =============================================================================

using HTTP

"""
    _audience_profile(audience::String) -> NamedTuple

Classify the narration audience:

- `kind` is `:architect` or `:engineer` for the two preset styles (case-insensitive).
- Any other non-empty string is `kind === :persona` and `text` is the trimmed original
  (preserved for language, tone, and format hints — e.g. Grasshopper \"Custom…\").
- The legacy token `custom` (alone) maps to a neutral default persona line.
- Empty string falls back to `:architect`.
"""
function _audience_profile(audience::String)
    s = strip(audience)
    if isempty(s)
        return (kind=:architect, text="architect")
    end
    sl = lowercase(s)
    sl == "architect" && return (kind=:architect, text="architect")
    sl == "engineer" && return (kind=:engineer, text="engineer")
    sl == "custom" && return (kind=:persona, text="A reader who wants a concise, neutral explanation without fluff or architectural analogies.")
    return (kind=:persona, text=s)
end

"""
    agent_narrate_element(design::BuildingDesign, element_type::String,
                          element_id::Int, audience::String) -> Dict{String, Any}

Compose a plain-English paragraph about one element using the configured
LLM. The model is grounded with /diagnose output facts.
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
    profile = _audience_profile(audience)
    audience_out = profile.text

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
    ec          = get(elem, "ec_kgco2e", nothing)

    llm_narrative = _narrate_element_llm(elem, element_type, element_id, profile)
    if isnothing(llm_narrative)
        bullets = _element_basic_fallback_bullets(diag, elem, element_type, element_id)
        return Dict{String, Any}(
            "narrative"       => join(["- $b" for b in bullets], "\n"),
            "bullet_points"   => bullets,
            "narrative_source" => "deterministic_basic_fallback",
            "llm_status"      => "unavailable",
            "message"         => "LLM narration unavailable; returning deterministic basic facts.",
            "recovery_hint"   => "Check CHAT_LLM_API_KEY and CHAT_LLM_BASE_URL, then retry for LLM narration.",
            "element_type"    => element_type,
            "element_id"      => element_id,
            "audience"        => audience_out,
            "key_facts"       => Dict{String, Any}(
                "governing_check" => governing,
                "ratio"           => ratio,
                "ok"              => ok,
                "mode"            => mode,
                "ec_kgco2e"       => ec,
            ),
        )
    end

    return Dict{String, Any}(
        "narrative"    => llm_narrative,
        "narrative_source" => "llm",
        "element_type" => element_type,
        "element_id"   => element_id,
        "audience"     => audience_out,
        "key_facts"    => Dict{String, Any}(
            "governing_check" => governing,
            "ratio"           => ratio,
            "ok"              => ok,
            "mode"            => mode,
            "ec_kgco2e"       => ec,
        ),
    )
end

function _element_basic_fallback_bullets(
    diag::Dict,
    elem::Dict,
    element_type::String,
    element_id::Int,
)::Vector{String}
    bullets = String[]
    push!(bullets, "Element: $element_type #$element_id")

    analysis_method = string(get(diag, "analysis_method", "not available in current results"))
    push!(bullets, "Analysis method: $analysis_method")

    section = get(elem, "section", nothing)
    !isnothing(section) && !isempty(string(section)) && push!(bullets, "Section/size: $(section)")

    # Material is not consistently explicit in current per-element diagnose payload.
    # Prefer explicit fields; otherwise clearly report unavailable.
    material = if haskey(elem, "material")
        string(get(elem, "material", ""))
    elseif haskey(elem, "shape")
        "shape=$(get(elem, "shape", "unknown")); material not explicitly provided"
    else
        "not explicitly provided in current results"
    end
    push!(bullets, "Material: $material")

    if haskey(elem, "thickness")
        t = get(elem, "thickness", "n/a")
        tu = get(elem, "thickness_unit", "")
        push!(bullets, "Sizing result: thickness=$(t) $(tu)")
    elseif haskey(elem, "depth")
        d = get(elem, "depth", "n/a")
        du = get(elem, "depth_unit", "")
        push!(bullets, "Sizing result: depth=$(d) $(du)")
    elseif haskey(elem, "c1") || haskey(elem, "c2")
        c1 = get(elem, "c1", "n/a")
        c2 = get(elem, "c2", "n/a")
        u = get(elem, "section_unit", "")
        push!(bullets, "Sizing result: c1=$(c1), c2=$(c2) $(u)")
    elseif haskey(elem, "length") || haskey(elem, "width")
        l = get(elem, "length", "n/a")
        w = get(elem, "width", "n/a")
        lu = get(elem, "length_unit", "")
        push!(bullets, "Sizing result: length=$(l), width=$(w) $(lu)")
    end

    ok = get(elem, "ok", true)
    ratio = get(elem, "governing_ratio", "n/a")
    gchk = get(elem, "governing_check", "unknown")
    mode = get(elem, "governing_mode", "unknown")
    push!(bullets, "Status: $(ok ? "PASS" : "FAIL"), governing_check=$(gchk), governing_ratio=$(ratio), mode=$(mode)")

    checks = get(elem, "checks", Any[])
    if checks isa AbstractVector && !isempty(checks)
        brief = String[]
        for c in checks
            name = get(c, "name", "?")
            r = get(c, "ratio", "n/a")
            push!(brief, "$(name):$(r)")
            length(brief) >= 4 && break
        end
        push!(bullets, "Check ratios: $(join(brief, ", "))")
    end

    ec = get(elem, "ec_kgco2e", nothing)
    !isnothing(ec) && push!(bullets, "Embodied carbon: $(ec) kgCO2e")

    return bullets
end

function _narrate_element_llm(
    elem::Dict,
    element_type::String,
    element_id::Int,
    profile,
)::Union{String, Nothing}
    _llm_configured() || return nothing

    # Keep generation tightly grounded in diagnose output to avoid fabrication.
    facts = Dict{String, Any}(
        "element_type" => element_type,
        "element_id" => element_id,
        "audience" => profile.text,
        "diagnose" => elem,
    )
    facts_json = JSON3.write(facts)

    grounding = """
Rules (non-negotiable):
- Use only facts present in the JSON the user message provides under "diagnose".
- If a field is missing, say "not available in current results" instead of guessing.
- Be numerically faithful to the provided values; do not invent checks, clauses, or ratios.
"""

    if profile.kind === :persona
        persona_block = strip(profile.text)
        system_prompt = string(
            """
You are a structural engineering explainer for Menegroth.

The user you are assisting describes themselves as:

""",
            persona_block,
            """

Explain the selected structural element to them in a way that fits that description — including natural language (e.g. respond in German if they are a German-speaking user), tone, level of detail, and presentation (e.g. ASCII tables if they want tables). Adapt format to their preferences; do not force a rigid outline.

""",
            grounding,
        )
        user_prompt = """
The user is asking about this one structural element. Give them the explanation.

JSON facts (ground truth):
$facts_json
"""
        temperature = 0.35
        max_tokens = 520
    else
        audience_style = profile.kind === :architect ?
            "Use plain language with physical intuition and avoid code jargon." :
            "Use concise engineering language and mention governing check details when available."

        system_prompt = """
You are a structural engineering explainer for Menegroth.

$grounding
- Write exactly one paragraph, 3-6 sentences.
- Do not include bullet points, headings, or markdown.
"""
        user_prompt = """
Write a narrative for this one element.
$audience_style

JSON facts:
$facts_json
"""
        temperature = 0.2
        max_tokens = 320
    end

    body = JSON3.write(Dict(
        "model" => _chat_llm_model(),
        "messages" => [
            Dict("role" => "system", "content" => system_prompt),
            Dict("role" => "user", "content" => user_prompt),
        ],
        "stream" => false,
        "temperature" => temperature,
        "max_tokens" => max_tokens,
    ))
    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(_chat_llm_api_key())",
    ]
    url = rstrip(_chat_llm_base_url(), '/') * "/v1/chat/completions"

    try
        r = HTTP.post(
            url,
            headers,
            body;
            connect_timeout=10,
            readtimeout=90,
            status_exception=false,
            cookies=false,
        )
        if r.status >= 400
            @warn "LLM narrate unavailable (HTTP error)" status=r.status
            return nothing
        end

        obj = JSON3.read(String(r.body))
        if !haskey(obj, :choices) || length(obj.choices) == 0
            @warn "LLM narrate unavailable (missing choices)"
            return nothing
        end
        msg = get(obj.choices[1], :message, nothing)
        isnothing(msg) && return nothing
        content = get(msg, :content, nothing)
        isnothing(content) && return nothing
        text = strip(string(content))
        isempty(text) && return nothing
        return replace(text, r"\s+" => " ")
    catch e
        @warn "LLM narrate unavailable (request failed)" error=_compact_llm_error(e)
        return nothing
    end
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

Compose a plain-English paragraph comparing two designs using the configured
LLM, grounded in the structured deltas from `agent_compare_designs`.
"""
function agent_narrate_comparison(index_a::Int, index_b::Int, audience::String)::Dict{String, Any}
    profile = _audience_profile(audience)
    audience_out = profile.text

    delta = agent_compare_designs(index_a, index_b)
    haskey(delta, "error") && return delta

    a = delta["design_a"]
    b = delta["design_b"]
    d = delta["deltas"]
    changed = delta["changed_params"]

    llm_narrative = _narrate_comparison_llm(a, b, d, changed, profile)
    if isnothing(llm_narrative)
        return Dict{String, Any}(
            "error"         => "llm_unavailable",
            "message"       => "Narration is LLM-only and no template fallback is used.",
            "recovery_hint" => "Check CHAT_LLM_API_KEY and CHAT_LLM_BASE_URL, then retry.",
            "audience"      => audience_out,
            "deltas"        => d,
            "changed_params" => changed,
        )
    end

    return Dict{String, Any}(
        "narrative" => llm_narrative,
        "narrative_source" => "llm",
        "audience"  => audience_out,
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

function _narrate_comparison_llm(
    a::Dict,
    b::Dict,
    d::Dict,
    changed::Dict,
    profile,
)::Union{String, Nothing}
    _llm_configured() || return nothing

    facts = Dict{String, Any}(
        "audience" => profile.text,
        "design_a" => a,
        "design_b" => b,
        "deltas" => d,
        "changed_params" => changed,
    )
    facts_json = JSON3.write(facts)

    grounding = """
Rules (non-negotiable):
- Use only facts present in the JSON the user message provides.
- If a field is missing, say "not available in current results" instead of guessing.
- Be numerically faithful to the provided values.
"""

    if profile.kind === :persona
        persona_block = strip(profile.text)
        system_prompt = string(
            """
You are a structural engineering explainer for Menegroth.

The user you are assisting describes themselves as:

""",
            persona_block,
            """

Compare design A and design B for them in a way that fits that description — language, tone, level of detail, and format (e.g. ASCII tables if they want tables).

""",
            grounding,
        )
        user_prompt = """
The user wants a comparison of two designs. Respond for them.

JSON facts (ground truth):
$facts_json
"""
        temperature = 0.35
        max_tokens = 560
    else
        audience_style = profile.kind === :architect ?
            "Use plain language focused on implications, risk, and design intent." :
            "Use concise engineering language focused on checks, ratios, and trade-offs."

        system_prompt = """
You are a structural engineering explainer for Menegroth.

$grounding
- Write exactly one paragraph, 4-7 sentences.
- Do not include bullet points, headings, or markdown.
"""
        user_prompt = """
Write a comparison narrative between design A and design B.
$audience_style

JSON facts:
$facts_json
"""
        temperature = 0.2
        max_tokens = 380
    end

    body = JSON3.write(Dict(
        "model" => _chat_llm_model(),
        "messages" => [
            Dict("role" => "system", "content" => system_prompt),
            Dict("role" => "user", "content" => user_prompt),
        ],
        "stream" => false,
        "temperature" => temperature,
        "max_tokens" => max_tokens,
    ))
    headers = [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(_chat_llm_api_key())",
    ]
    url = rstrip(_chat_llm_base_url(), '/') * "/v1/chat/completions"

    try
        r = HTTP.post(
            url,
            headers,
            body;
            connect_timeout=10,
            readtimeout=90,
            status_exception=false,
            cookies=false,
        )
        if r.status >= 400
            @warn "LLM comparison narrate unavailable (HTTP error)" status=r.status
            return nothing
        end

        obj = JSON3.read(String(r.body))
        if !haskey(obj, :choices) || length(obj.choices) == 0
            @warn "LLM comparison narrate unavailable (missing choices)"
            return nothing
        end
        msg = get(obj.choices[1], :message, nothing)
        isnothing(msg) && return nothing
        content = get(msg, :content, nothing)
        isnothing(content) && return nothing
        text = strip(string(content))
        isempty(text) && return nothing
        return replace(text, r"\s+" => " ")
    catch e
        @warn "LLM comparison narrate unavailable (request failed)" error=_compact_llm_error(e)
        return nothing
    end
end
