# ─── Suggestions extraction ───────────────────────────────────────────────────

"""
    _extract_suggestions(full_text) -> Vector{String}

Parse bullet items from the `$_SUGGESTIONS_START` … `$_SUGGESTIONS_END` block
embedded in `full_text`. Returns an empty vector if the block is absent or
malformed.
"""
function _extract_suggestions(full_text::String)::Vector{String}
    # Try exact delimiters first, then case/whitespace-insensitive fallback.
    block = _extract_delimited_block(full_text, _SUGGESTIONS_START, _SUGGESTIONS_END)
    if isnothing(block)
        block = _extract_delimited_block_fuzzy(full_text, "NEXT QUESTIONS", "END")
    end
    isnothing(block) && return String[]

    suggestions = String[]
    for line in split(block, '\n')
        s = strip(line)
        isempty(s) && continue
        # Accept bullet markers: •, -, *, numbered (1.), or bare text lines.
        s = replace(s, r"^(?:[•\-\*]\s*|\d+\.\s*)" => "")
        s = strip(s)
        isempty(s) || push!(suggestions, s)
    end
    return suggestions
end

"""Extract text between exact start/end delimiters, or nothing."""
function _extract_delimited_block(text::String, start_delim::String, end_delim::String)::Union{String, Nothing}
    si = findfirst(start_delim, text)
    isnothing(si) && return nothing
    ei = findnext(end_delim, text, last(si) + 1)
    isnothing(ei) && return nothing
    b = last(si) + 1
    e = first(ei) - 1
    b > e && return nothing
    return strip(text[b:e])
end

"""Fuzzy extraction: match `---<keyword>---` with flexible whitespace/dashes."""
function _extract_delimited_block_fuzzy(text::String, start_kw::String, end_kw::String)::Union{String, Nothing}
    start_re = Regex("---\\s*" * start_kw * "\\s*---", "i")
    end_re   = Regex("---\\s*" * end_kw * "\\s*---", "i")
    sm = match(start_re, text)
    isnothing(sm) && return nothing
    em = match(end_re, text, sm.offset + length(sm.match))
    isnothing(em) && return nothing
    b = sm.offset + length(sm.match)
    e = em.offset - 1
    b > e && return nothing
    return strip(text[b:e])
end

"""
    _extract_clarification_prompt(full_text) -> Union{Dict{String, Any}, Nothing}

Parse a JSON clarification payload from the `$_CLARIFY_START` ... `$_CLARIFY_END`
block. Returns `nothing` when absent or malformed.
"""
function _extract_clarification_prompt(full_text::String)::Union{Dict{String, Any}, Nothing}
    # Try exact delimiters first, then fuzzy fallback.
    payload = _extract_delimited_block(full_text, _CLARIFY_START, _CLARIFY_END)
    if isnothing(payload)
        payload = _extract_delimited_block_fuzzy(full_text, "CLARIFY", "END.?CLARIFY")
    end
    isnothing(payload) && return nothing

    payload = strip(payload)
    isempty(payload) && return nothing

    try
        raw = JSON3.read(payload)
        prompt = Dict{String, Any}(string(k) => v for (k, v) in raw)
        haskey(prompt, "prompt") || return nothing
        haskey(prompt, "options") || return nothing
        return prompt
    catch
        return nothing
    end
end

"""
    _strip_marker_blocks(text) -> String

Remove machine-readable delimiter blocks (suggestions and clarification) from
the assistant text so the client displays clean prose. The structured data is
delivered separately via the `agent_turn_summary` SSE event.
"""
function _strip_marker_blocks(text::String)::String
    out = text
    # Delimiter constants contain only dashes/letters/spaces — safe to embed literally.
    sug_re = Regex("\\Q$(_SUGGESTIONS_START)\\E[\\s\\S]*?\\Q$(_SUGGESTIONS_END)\\E", "s")
    out = replace(out, sug_re => "")
    clar_re = Regex("\\Q$(_CLARIFY_START)\\E[\\s\\S]*?\\Q$(_CLARIFY_END)\\E", "s")
    out = replace(out, clar_re => "")
    # Fuzzy variants the LLM might use
    out = replace(out, r"---+\s*NEXT\s*QUESTIONS\s*---+[\s\S]*?---+\s*END\s*---+"si => "")
    out = replace(out, r"---+\s*CLARIFY\s*---+[\s\S]*?---+\s*END[- ]?CLARIFY\s*---+"si => "")
    return strip(out)
end

# ─── Turn summary contract ────────────────────────────────────────────────────

"""
    _normalize_clarification(raw) -> Union{Dict{String,Any}, Nothing}

Ensure a clarification payload uses the canonical shape:
`{id, prompt, options[{id,label}], allow_multiple, rationale?, required_for?}`.
Returns `nothing` when the input is absent or not a dict.
"""
function _normalize_clarification(raw)::Union{Dict{String, Any}, Nothing}
    isnothing(raw) && return nothing
    !(raw isa AbstractDict) && return nothing
    d = Dict{String, Any}(string(k) => v for (k, v) in raw)
    haskey(d, "prompt") || return nothing
    haskey(d, "options") || return nothing

    d["id"]             = get(d, "id", "clarify")
    d["allow_multiple"] = get(d, "allow_multiple", false)

    opts = d["options"]
    if opts isa AbstractVector
        normalized = Dict{String, String}[]
        for (i, o) in enumerate(opts)
            if o isa AbstractDict
                oid = string(get(o, "id", get(o, :id, "opt_$i")))
                lbl = string(get(o, "label", get(o, :label, "")))
                isempty(lbl) && continue
                push!(normalized, Dict("id" => oid, "label" => lbl))
            else
                lbl = string(o)
                isempty(lbl) && continue
                push!(normalized, Dict("id" => "opt_$i", "label" => lbl))
            end
        end
        isempty(normalized) && return nothing
        d["options"] = normalized
    end
    return d
end

"""
    _preprocess_clarification_response(messages) -> Vector

If the last user message starts with `[CLARIFICATION_RESPONSE ...]`, parse
the structured fields and insert a system message that presents the selection
in plain language so the LLM can skip bracket parsing.
"""
function _preprocess_clarification_response(messages)
    isempty(messages) && return messages
    last_msg = messages[end]
    content = string(get(last_msg, "content", get(last_msg, :content, "")))
    role = string(get(last_msg, "role", get(last_msg, :role, "")))
    role == "user" || return messages

    m = match(r"^\[CLARIFICATION_RESPONSE\s+id=(\S+)\s+options=([^\]]*)\]\s*(.*)"s, strip(content))
    isnothing(m) && return messages

    clar_id = m.captures[1]
    selected = filter(!isempty, split(m.captures[2], ","))
    extra_text = strip(string(m.captures[3]))

    ctx = "The user responded to clarification \"$clar_id\" by selecting: $(join(selected, ", "))."
    if !isempty(extra_text)
        ctx *= " Additional context: \"$extra_text\""
    end
    ctx *= " Incorporate this choice and proceed — do NOT re-ask the same clarification."

    out = collect(messages)
    # Insert a system context message before the user message.
    insert!(out, length(out), Dict("role" => "system", "content" => ctx))
    return out
end

"""
    _contains_numerical_claims(text) -> Bool

Heuristic check for text that appears to contain specific numerical structural
claims (ratios, percentages near pass/fail language, utilization values, EC
totals, material quantities, or fabricated comparison deltas) that should have
been grounded in tool evidence.
"""
function _contains_numerical_claims(text::AbstractString)::Bool
    isempty(text) && return false
    has_ratio = occursin(r"(?:ratio|utilization|DCR)\s*(?:of|=|is|:)\s*\d+\.\d+"i, text)
    has_pct = occursin(r"\d{1,3}(?:\.\d+)?%\s*(?:utilization|capacity|overloaded|stressed)"i, text)
    has_passfail_number = occursin(r"(?:pass|fail|exceed|violat)\w*\s+(?:at|with|by)\s+\d+\.\d+"i, text)
    has_specific_value = occursin(r"(?:φ[PVM]n|ϕ[PVM]n|Vu|Mu|Pu)\s*(?:=|of|is)\s*[\d,]+\.?\d*\s*(?:kip|kN|psi|ksi|MPa)"i, text)
    has_ec = occursin(r"\d[\d,]+\s*(?:kgCO2e|kgCO₂e|kg\s*CO2)"i, text)
    has_material_qty = occursin(r"\d[\d,]*\.?\d*\s*(?:ft[³3]|m[³3]|lb|kg|kip)\b"i, text)
    has_delta_claim = occursin(r"(?:increase|decrease|reduced|changed|rose|fell|dropped|gained)\w*\s+(?:of|by|from)\s+[\d,]+"i, text)
    return has_ratio || has_pct || has_passfail_number || has_specific_value ||
           has_ec || has_material_qty || has_delta_claim
end

# ─── Per-inference grounding messages ─────────────────────────────────────────

"""
    _most_recent_design_snapshot() -> String

Short authoritative summary of the latest cached design results, injected as a
system message into the conversation before every LLM inference so the model
cannot contradict real numbers. Returns a no-design fallback when nothing is cached.
"""
function _most_recent_design_snapshot()::String
    design = _get_last_design()
    isnothing(design) && return (
        "MOST RECENT DESIGN RESULTS: No design has been run yet. " *
        "Do not invent ratios, pass/fail status, embodied carbon, or material quantities.")
    s = design.summary
    conc_m3  = round(ustrip(u"m^3", s.concrete_volume); digits=1)
    steel_kg = round(ustrip(u"kg",  s.steel_weight); digits=0)
    rebar_kg = round(ustrip(u"kg",  s.rebar_weight); digits=0)
    ec       = round(ustrip(u"kgCO2e", s.embodied_carbon); digits=0)
    n_fail_cols  = count(p -> !p.second.ok, design.columns)
    n_fail_beams = count(p -> !p.second.ok, design.beams)
    n_fail_slabs = count(p -> !_slab_design_ok(p.second), design.slabs)
    n_fail_fdns  = count(p -> !p.second.ok, design.foundations)
    n_fail = n_fail_cols + n_fail_beams + n_fail_slabs + n_fail_fdns

    "MOST RECENT DESIGN RESULTS (authoritative — do not contradict these numbers):\n" *
    "all_pass=$(s.all_checks_pass), critical_element=\"$(s.critical_element)\", " *
    "critical_ratio=$(round(s.critical_ratio; digits=3)), " *
    "embodied_carbon=$(Int(ec)) kgCO2e, " *
    "concrete=$(conc_m3) m³, steel=$(Int(steel_kg)) kg, rebar=$(Int(rebar_kg)) kg, " *
    "n_failing=$n_fail (cols=$n_fail_cols beams=$n_fail_beams slabs=$n_fail_slabs fdns=$n_fail_fdns).\n" *
    "If you need detail beyond these totals, call a tool. Do not extrapolate or invent."
end

const _TOOLS_FIRST_INSTRUCTION =
    "BEFORE responding to the user: identify which tools you need to answer accurately. " *
    "If the user asks about results, comparisons, or any quantitative data not in the " *
    "MOST RECENT DESIGN RESULTS above, call the appropriate tool FIRST. " *
    "Do not generate a text response until you have tool evidence for every numerical " *
    "claim you plan to make."

