# Server-side conversation history keyed by session_id (typically geometry hash).
# OrderedDict preserves insertion order for correct LRU eviction via first(keys(...)).
const CHAT_HISTORY      = OrderedDict{String, Vector{Dict{String, String}}}()
const CHAT_HISTORY_LOCK = ReentrantLock()
const CHAT_HISTORY_MAX_SESSIONS = 20
const CHAT_CLARIFICATION_KEYS = OrderedDict{String, Set{String}}()

# Delimiters that the LLM is instructed to wrap its next-steps block in.
# Keep these unique enough that the LLM won't produce them accidentally.
const _SUGGESTIONS_START = "---NEXT QUESTIONS---"
const _SUGGESTIONS_END   = "---END---"
const _CLARIFY_START     = "---CLARIFY---"
const _CLARIFY_END       = "---END-CLARIFY---"

# Human-readable labels for tool_progress SSE events.
const _TOOL_DISPLAY_LABELS = Dict{String, String}(
    "get_situation_card"       => "Checking status",
    "get_building_summary"     => "Analyzing geometry",
    "get_geometry_digest"      => "Computing geometry digest",
    "get_current_params"       => "Reading parameters",
    "get_api_params_ssot"      => "Reading API params snapshot",
    "get_design_history"       => "Fetching design history",
    "get_diagnose_summary"     => "Summarizing diagnostics",
    "get_diagnose"             => "Running diagnostics",
    "query_elements"           => "Querying elements",
    "get_implemented_provisions" => "Looking up code provisions",
    "get_lever_map"            => "Mapping design levers",
    "explain_field"            => "Explaining parameter",
    "get_provision_rationale"  => "Fetching code rationale",
    "validate_params"          => "Validating parameters",
    "run_design"               => "Running design",
    "compare_designs"          => "Comparing designs",
    "suggest_next_action"      => "Suggesting next steps",
    "predict_geometry_effect"  => "Predicting geometry effect",
    "run_experiment"           => "Running experiment",
    "list_experiments"         => "Listing experiments",
    "batch_experiments"        => "Running experiments",
    "narrate_element"          => "Narrating element",
    "narrate_comparison"       => "Narrating comparison",
    "get_solver_trace"         => "Reading solver trace",
    "explain_trace_lookup"     => "Explaining trace entry",
    "get_result_summary"       => "Summarizing results",
    "get_condensed_result"     => "Condensing results",
    "get_applicability"        => "Checking applicability",
    "clarify_user_intent"      => "Asking clarification",
    "record_insight"           => "Recording insight",
    "get_session_insights"     => "Fetching insights",
    "get_response_guidelines"  => "Loading guidelines",
)

# ─── Token budget ─────────────────────────────────────────────────────────────

"""Approximate token count via character-length heuristic (1 token ≈ 4 chars)."""
_estimate_tokens(text::AbstractString) = cld(length(text), 4)

"""Recursively replace `Inf`/`-Inf`/`NaN` with JSON-safe values in nested Dict/Vector structures."""
function _sanitize_ieee_specials(x::AbstractDict)
    Dict{String, Any}(string(k) => _sanitize_ieee_specials(v) for (k, v) in pairs(x))
end
_sanitize_ieee_specials(x::AbstractVector) = [_sanitize_ieee_specials(v) for v in x]
_sanitize_ieee_specials(x::AbstractFloat) = isfinite(x) ? x : (isnan(x) ? nothing : (x > 0 ? 1.0e308 : -1.0e308))
_sanitize_ieee_specials(x) = x

"""
    _truncate_tool_result(json_str::String; max_chars=MAX_TOOL_RESULT_CHARS) -> String

Cap a tool result JSON string at `max_chars`. When truncated, the result is
replaced with a summary indicating the original size and advising the LLM
to use more specific queries.
"""
function _truncate_tool_result(json_str::String; max_chars::Int=MAX_TOOL_RESULT_CHARS)::String
    length(json_str) <= max_chars && return json_str
    return "{\"_truncated\":true,\"original_chars\":$(length(json_str)),\"max_chars\":$max_chars," *
           "\"note\":\"Tool result too large for context window. Use more targeted queries " *
           "(query_elements with filters, get_diagnose_summary instead of get_diagnose, " *
           "get_condensed_result instead of get_result_summary).\"," *
           "\"preview\":$(JSON3.write(json_str[1:min(2000, max_chars)]))}"
end

"""
    _budget_messages(system_prompt, messages, max_tokens) -> Vector

Fit the message history within the context budget, preserving the most recent
messages first. Older messages are dropped and replaced with a truncation marker.
"""
function _budget_messages(system_prompt::String, messages::Vector, max_tokens::Int)
    sys_tokens = _estimate_tokens(system_prompt)
    sys_budget = round(Int, max_tokens * _SYSTEM_PROMPT_BUDGET_FRACTION)
    if sys_tokens > sys_budget
        @warn "System prompt is large" sys_tokens sys_budget max_tokens pct=round(100 * sys_tokens / max_tokens; digits=1)
    end
    remaining  = max_tokens - sys_tokens
    remaining <= 0 && return []

    budgeted = []
    total    = 0
    for msg in reverse(messages)
        content = get(msg, "content", "")
        cost = _estimate_tokens(string(content)) + 10
        if total + cost > remaining
            @warn "Chat context budget exceeded; truncating older messages" dropped=(length(messages) - length(budgeted))
            pushfirst!(budgeted, Dict("role" => "user", "content" => "[Earlier messages truncated to fit context window]"))
            break
        end
        pushfirst!(budgeted, msg)
        total += cost
    end
    return budgeted
end

"""
    _compact_conversation!(conversation, system_prompt, max_tokens)

Mid-conversation compaction: if the accumulated conversation (system + messages)
exceeds 85% of the token budget, truncate the *content* of older tool-result
messages (keeping the most recent 3 tool results intact).  This prevents the
multi-round agent loop from silently blowing the context window.
"""
function _compact_conversation!(conversation::Vector, system_prompt::String, max_tokens::Int)
    total = _estimate_tokens(system_prompt)
    for msg in conversation
        total += _estimate_tokens(string(get(msg, "content", ""))) + 10
    end
    threshold = round(Int, max_tokens * 0.85)
    total <= threshold && return nothing

    # Find tool-result messages (role == "tool") and compact all but the last 3.
    tool_indices = [i for (i, m) in enumerate(conversation) if get(m, "role", "") == "tool"]
    keep_count = min(3, length(tool_indices))
    compact_indices = tool_indices[1:end-keep_count]
    isempty(compact_indices) && return nothing

    for idx in compact_indices
        old_content = string(get(conversation[idx], "content", ""))
        old_len = length(old_content)
        if old_len > 500
            conversation[idx] = Dict{String, Any}(
                "role" => "tool",
                "tool_call_id" => get(conversation[idx], "tool_call_id", ""),
                "content" => "{\"_compacted\":true,\"original_chars\":$old_len," *
                             "\"note\":\"Earlier tool result compacted to fit context window. " *
                             "Call the tool again if you need this data.\"}",
            )
        end
    end

    new_total = _estimate_tokens(system_prompt)
    for msg in conversation
        new_total += _estimate_tokens(string(get(msg, "content", ""))) + 10
    end
    @info "Mid-conversation compaction" before_tokens=total after_tokens=new_total budget=max_tokens compacted_messages=length(compact_indices)
    return nothing
end

# ─── Session history ──────────────────────────────────────────────────────────

"""Return a copy of stored messages for `session_id`, or an empty vector.
Marks the session as recently used (LRU touch)."""
function _get_history(session_id::String)
    lock(CHAT_HISTORY_LOCK) do
        msgs = get(CHAT_HISTORY, session_id, nothing)
        isnothing(msgs) && return Dict{String, String}[]
        # Touch: move to end of OrderedDict for LRU freshness.
        delete!(CHAT_HISTORY, session_id)
        CHAT_HISTORY[session_id] = msgs
        return copy(msgs)
    end
end

"""
    _append_history!(session_id, role, content)

Append one message to the session history. Evicts the oldest session when the
`CHAT_HISTORY_MAX_SESSIONS` cap is reached.
"""
function _append_history!(session_id::String, role::String, content::String)
    lock(CHAT_HISTORY_LOCK) do
        if haskey(CHAT_HISTORY, session_id)
            # Move to end for LRU freshness.
            msgs = CHAT_HISTORY[session_id]
            delete!(CHAT_HISTORY, session_id)
            push!(msgs, Dict("role" => role, "content" => content))
            CHAT_HISTORY[session_id] = msgs
        else
            if length(CHAT_HISTORY) >= CHAT_HISTORY_MAX_SESSIONS
                delete!(CHAT_HISTORY, first(keys(CHAT_HISTORY)))
            end
            CHAT_HISTORY[session_id] = [Dict("role" => role, "content" => content)]
        end
    end
end

"""
    _clear_history!(session_id)

Clear history for a specific session. Pass `"all"` to wipe every session.
"""
function _clear_history!(session_id::String)
    lock(CHAT_HISTORY_LOCK) do
        if session_id == "all"
            empty!(CHAT_HISTORY)
            empty!(CHAT_CLARIFICATION_KEYS)
        else
            delete!(CHAT_HISTORY, session_id)
            delete!(CHAT_CLARIFICATION_KEYS, session_id)
        end
    end
end

"""Register clarification IDs seen for a session. Returns true when newly added."""
function _remember_clarification!(session_id::String, clarification_id::String)::Bool
    isempty(session_id) && return true
    isempty(clarification_id) && return true
    lock(CHAT_HISTORY_LOCK) do
        seen = get!(CHAT_CLARIFICATION_KEYS, session_id, Set{String}())
        clarification_id in seen && return false
        push!(seen, clarification_id)
        return true
    end
end

