# =============================================================================
# Chat — LLM-powered conversational endpoint via SSE streaming
#
# POST /chat          — stream LLM chat response (SSE); stores exchange in
#                       session history when session_id is provided.
# POST /chat/action   — invoke a structural tool from the agent mid-conversation.
# GET  /chat/history  — retrieve stored conversation history for a session.
# DELETE /chat/history — clear stored history (call on new geometry load).
# =============================================================================

# ─── Configuration ───────────────────────────────────────────────────────────
#
# IMPORTANT: Read configuration at request time, not at module precompile time.
# Also fall back to `secrets/openai_api_key` at the repo root when ENV is empty —
# some server stacks (or load orders) may not propagate bootstrap-set ENV into
# the HTTP handler the same way `julia scripts/api/sizer_bootstrap.jl` does interactively.

"""`StructuralSynthesizer/src/api/` → repo root `menegroth/`."""
function _repo_root_secrets_path()::String
    joinpath(@__DIR__, "..", "..", "..", "secrets", "openai_api_key")
end

function _chat_llm_api_key()::String
    k = get(ENV, "CHAT_LLM_API_KEY", "")
    k = normalize_llm_api_key_secret(k)
    !isempty(k) && return k
    path = _repo_root_secrets_path()
    isfile(path) || return ""
    k = normalize_llm_api_key_secret(read(path, String))
    isempty(k) && return ""
    ENV["CHAT_LLM_API_KEY"] = k
    return k
end

function _chat_llm_base_url()::String
    u = get(ENV, "CHAT_LLM_BASE_URL", "")
    !isempty(u) && return u
    return "https://api.openai.com"
end

function _chat_llm_model()::String
    m = get(ENV, "CHAT_LLM_MODEL", "")
    !isempty(m) && return m
    return "gpt-4o"
end

_llm_configured() = !isempty(_chat_llm_api_key())

"""
    _read_stream_request_body(stream::HTTP.Stream) -> String

Oxygen passes `HTTP.Stream`; the POST body is often already buffered in
`stream.message.body`. Reading only `read(stream)` can return EOF if the stack
already consumed the body into `Request.body` — use that first.
"""
function _read_stream_request_body(stream::HTTP.Stream)::String
    req = stream.message
    if !isempty(req.body)
        return String(req.body)
    end
    HTTP.startread(stream)
    return String(read(stream))
end

"""
    _compact_llm_error(e) -> String

Return a user-facing error string that avoids dumping full HTTP request payloads
from `HTTP.RequestError` (which can include large prompt bodies).
"""
function _compact_llm_error(e)::String
    type_str = string(typeof(e))
    if occursin("RequestError", type_str)
        if hasproperty(e, :error)
            inner = sprint(showerror, getproperty(e, :error))
            inner = replace(inner, r"\s+" => " ")
            return "OpenAI request failed: $(inner)"
        end
        return "OpenAI request failed (HTTP transport error)."
    end

    msg = sprint(showerror, e)
    msg = replace(msg, r"\s+" => " ")
    return msg[1:min(end, 320)]
end

const MAX_CONTEXT_TOKENS = 120_000

const MAX_TOOL_RESULT_CHARS = 60_000

"""Target: system prompt should use at most this fraction of the total budget."""
const _SYSTEM_PROMPT_BUDGET_FRACTION = 0.45

using OrderedCollections: OrderedDict

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

# ─── System prompt assembly ───────────────────────────────────────────────────

# Appended to every system prompt so the LLM emits machine-parseable next-steps.
const _NEXT_QUESTIONS_INSTRUCTION = """

RESPONSE FORMAT REQUIREMENT:
You MUST end every response with a structured suggestions block using these exact markers (machine-parsed by the client — do not modify them):

$_SUGGESTIONS_START
• [concise question or action for the user, under 15 words]
• [concise question or action for the user, under 15 words]
• [concise question or action for the user, under 15 words]
$_SUGGESTIONS_END

2–3 items maximum. This block must be the very last element in your response.
"""

const _CLARIFICATION_INSTRUCTION = """

CLARIFICATION (when user intent is genuinely ambiguous):
Include at most ONE machine-readable block per response:

$_CLARIFY_START
{"id":"short_key","prompt":"question text","options":[{"id":"opt_a","label":"Option A"},{"id":"opt_b","label":"Option B"}],"allow_multiple":false,"required_for":"decision this unblocks","rationale":"why this matters"}
$_CLARIFY_END

Keep options to 2–4 concise choices. Only use when truly ambiguous.

When the user replies with `[CLARIFICATION_RESPONSE id=<key> options=<comma_ids>]`, incorporate the selection and proceed — do NOT re-ask the same clarification.
"""

const _TOOL_INDEX = """

TOOLS (each tool description includes USE WHEN guidance):
  Orient:      get_situation_card (FIRST), get_building_summary, get_geometry_digest, get_current_params, get_design_history
  Diagnose:    get_diagnose_summary (FIRST — returns total_ec_kgco2e, critical_ratio, pass/fail, per-element EC), get_diagnose, query_elements, get_solver_trace, get_lever_map
  Explore:     run_experiment (FAST), validate_params → run_design, compare_designs, suggest_next_action
  Communicate: narrate_element, narrate_comparison, get_result_summary, get_condensed_result, clarify_user_intent
  Reference:   explain_field, get_provision_rationale, get_applicability, get_response_guidelines
  Memory:      record_insight, get_session_insights
  Experiments: list_experiments, batch_experiments

  REQUIRED: get_situation_card before run_design (confirm has_geometry). validate_params before run_design. record_insight after each design. get_session_insights before recommending.
  FOR ANY "what is X?" QUESTION: call the relevant tool BEFORE answering. Never quote numbers from memory.

MICRO-EXPERIMENTS — PREFER OVER FULL REDESIGN FOR QUICK WHAT-IFS:
  run_experiment is INSTANT (~0.1s) and uses the cached design — no full re-run.
  ALWAYS use run_experiment FIRST when the user asks about:
    - Punching shear (column size): "would a bigger column help?" → run_experiment(type=punching, args={col_idx, c1_in?, c2_in?})
    - Punching shear (concrete): "what if I use 5000 psi?" → run_experiment(type=punching, args={col_idx, fc_in=5000})
      ⚠ CAVEAT: This holds column size constant. In a full redesign, higher f'c lets the sizer
      pick SMALLER columns (less area for axial), which shrinks b₀ and may NET-WORSEN punching.
      Always explain this coupling when presenting f'c results for punching.
    - Column sizing: "what if I use a W14x82?" → run_experiment(type=pm_column, args={col_idx, section_size})
    - Beam sizing: "what if I use a W16x40?" → run_experiment(type=beam, args={beam_idx, section_size})
    - Shear reinforcement: "can I add studs?" → run_experiment(type=punching_reinforcement, args={col_idx, reinforcement_type="studs"})
    - Deflection: "what about L/480?" → run_experiment(type=deflection, args={slab_idx, deflection_limit})
    - Section screening: "which column sizes work?" → run_experiment(type=catalog_screen, args={col_idx, candidates})
    - Any "would X help?" / "what's the effect of Y?" question about a single element
  Use batch_experiments to test multiple alternatives at once (e.g. screen 5 column sizes).
  Only escalate to run_design when you need to test a GLOBAL parameter change across all elements.

TOOL USAGE RULES — DO NOT SKIP THESE:
  DIAGNOSING FAILURES:
    "How do I fix X?" → get_lever_map(check=X) FIRST — it tells you exactly which parameters and geometry changes affect that check. NEVER guess at fixes without consulting the lever map.
    "Why is the column so big?" / "Why did the solver pick this section?" → get_solver_trace(tier=failures) then explain_trace_lookup on the relevant breadcrumb. The trace shows the solver's actual reasoning.
    "Why did X fail?" → get_provision_rationale(section=check_family) for the code mechanism, then narrate_element for plain-English explanation.

  EXPLAINING RESULTS:
    When the user asks to explain an element or result → call narrate_element or narrate_comparison. Do NOT write your own explanation — these tools produce calibrated, evidence-based narratives from the actual design data.

  ANALYSIS METHOD CHOICE:
    "Should I use DDM, EFM, or FEA?" → get_applicability — it evaluates DDM prerequisite checks against the actual geometry and tells you which methods are valid.

  SESSION MEMORY:
    After EVERY run_design → call record_insight with what you learned (sensitivity, dead_end, discovery).
    Before recommending a change → call get_session_insights to avoid repeating dead ends.
    These are REQUIRED sequences, not optional.
"""

const _DESIGN_SYSTEM_PREAMBLE = """
You are a structural engineering design assistant for the Menegroth automated design system.
Help the user choose design parameters for their building.

SAFETY:
  Code provisions (ACI 318, AISC 360, ASCE 7) are enforced by the solver.
  NEVER invent numbers — no fabricated EC totals, ratios, areas, thicknesses, or quantities.
  NEVER invent clause numbers or formulas — only cite what tool results provide.
  Every quantitative claim MUST come from either:
    (a) the CACHED DESIGN SUMMARY / LATEST RESULTS SUMMARY in this system prompt, OR
    (b) a tool call you made in this conversation.
  If the number is not in (a) or (b), call a tool before quoting it.

EVIDENCE-FIRST:
  After a design exists → OBSERVE (get_diagnose_summary) → CITE ratios/checks → CONSULT get_lever_map → RECOMMEND.
  Before any design → use the geometry digest and predict_geometry_effect for qualitative guidance. Do NOT invent ratios, pass/fail, or EC totals.
  For single-element what-ifs → use run_experiment FIRST (instant, no re-run). Only escalate to run_design for global changes.
  When the user asks "would X help?" or "what about Y?" → run_experiment to get real numbers, then present the result.

RETRIEVAL QUESTIONS — CALL A TOOL IF DATA IS NOT IN THE SYSTEM PROMPT:
  You may quote numbers directly from the CACHED DESIGN SUMMARY or LATEST RESULTS SUMMARY above.
  For anything NOT already in this prompt, call the relevant tool FIRST:
    - Per-element EC breakdown → get_diagnose_summary (returns total_ec_kgco2e and per-element ec_kgco2e)
    - Detailed checks, per-element ratios → get_diagnose_summary or query_elements
    - Element dimensions, sections → query_elements or get_diagnose
    - Geometry (spans, heights, floor area, column count) → get_geometry_digest
    - Current parameters → get_current_params
    - Design history / comparison → get_design_history or compare_designs
    - Derived metrics (e.g. EC intensity = EC/area) → call get_geometry_digest for area, then compute
  NEVER answer a factual question by guessing. If the data is not in this prompt and you haven't called a tool, call one.

STRUCTURAL REASONING — DO NOT HALLUCINATE TRADE-OFFS:
  NEVER invent structural relationships. Use predict_geometry_effect or get_lever_map to verify directions.
  Key relationships to get RIGHT:
    - Reducing spans REDUCES tributary area (∝ L²) → REDUCES punching demand. Never claim shorter spans increase punching load.
    - Higher f'c increases Vc in isolation BUT the column sizer may pick SMALLER columns (less area for axial), shrinking b₀ → may NET-WORSEN punching. Always caveat.
    - grow_columns directly increases b₀ (most reliable punching fix). reinforce_first adds studs but does NOT grow columns — different mechanism.
    - For slab thickness / deflection / embodied carbon: GEOMETRY FIRST. Reducing spans (adding columns, subdividing bays) is the primary lever (deflection ∝ L⁴). Relaxing deflection_limit (L/360→L/240) is a secondary, optional suggestion — only mention it as an additional option if the project can tolerate more deflection and has no sensitive partitions or equipment.
    - uniform_column_sizing = off (independent sizing) is an embodied-carbon reduction strategy: each column is right-sized to its own demand. per_story/building promote every column to the governing (largest) section, adding unnecessary material to lightly-loaded columns. Mention this trade-off when the user asks about reducing carbon or material use.
  If uncertain about a directional effect, call predict_geometry_effect or run a micro-experiment. Do not guess.

SERVER CACHE GATES:
  has_geometry (from get_situation_card) = geometry on the server from Grasshopper POST /design, NOT text in this chat.
  has_design = a solved design exists on the server.
  run_design requires has_geometry. If false → tell user to run Design from Grasshopper; meanwhile advise from the digest.
  suggest_next_action, run_experiment, diagnose, query_elements, get_solver_trace require has_design.

GEOMETRY vs PARAMETERS:
  GEOMETRY (Grasshopper) — column positions, spans, heights, plan shape. Cannot change via API.
  PARAMETERS (API) — floor_type, materials, loads, method, sizing. Change via run_design.
  For geometry changes → tell user what to adjust in Grasshopper.

$(_parameter_space_card())

GEOMETRY DIGEST:
  If a digest appears below, it is authoritative — quote it. If you think geometry is missing, call get_geometry_digest before saying so.

PARAMETER CHANGES:
  Output a JSON code block with only changed fields. Include `_history_label` (≤6 words).

SESSION HISTORY:
  No comparison language ("reduced from X to Y") unless get_design_history has ≥2 entries.

For anti-patterns and detailed rules, call get_response_guidelines.
$_TOOL_INDEX
$_CLARIFICATION_INSTRUCTION
$_NEXT_QUESTIONS_INSTRUCTION
"""

const _RESULTS_SYSTEM_PREAMBLE = """
You are a structural engineering results analyst for the Menegroth automated design system.
Help the user understand their building's design results.

SAFETY:
  Code provisions are enforced by the solver.
  NEVER invent numbers — no fabricated EC totals, ratios, areas, thicknesses, or quantities.
  NEVER invent clause numbers or formulas — only cite what tool results provide.
  Every quantitative claim MUST come from either:
    (a) the CACHED DESIGN SUMMARY in this system prompt, OR
    (b) a tool call you made in this conversation.
  If the number is not in (a) or (b), call a tool before quoting it.

EVIDENCE-FIRST:
  OBSERVE (get_diagnose_summary) → CITE ratios/checks → CONSULT get_lever_map → RECOMMEND.
  For single-element what-ifs → use run_experiment FIRST (instant, no re-run). Only escalate to run_design for global changes.
  When the user asks "would X help?" or "what about Y?" → run_experiment to get real numbers, then present the result.

RETRIEVAL QUESTIONS — CALL A TOOL IF DATA IS NOT IN THE SYSTEM PROMPT:
  You may quote numbers directly from the CACHED DESIGN SUMMARY above.
  For anything NOT already in this prompt, call the relevant tool FIRST:
    - Per-element EC breakdown → get_diagnose_summary (returns total_ec_kgco2e and per-element ec_kgco2e)
    - Detailed checks, per-element ratios → get_diagnose_summary or query_elements
    - Element dimensions, sections → query_elements or get_diagnose
    - Geometry (spans, heights, floor area, column count) → get_geometry_digest
    - Current parameters → get_current_params
    - Design history / comparison → get_design_history or compare_designs
    - Derived metrics (e.g. EC intensity = EC/area) → call get_geometry_digest for area, then compute
  NEVER answer a factual question by guessing. If the data is not in this prompt and you haven't called a tool, call one.

STRUCTURAL REASONING — DO NOT HALLUCINATE TRADE-OFFS:
  NEVER invent structural relationships. Use predict_geometry_effect or get_lever_map to verify directions.
  Key relationships to get RIGHT:
    - Reducing spans REDUCES tributary area (∝ L²) → REDUCES punching demand. Never claim shorter spans increase punching load.
    - Higher f'c increases Vc in isolation BUT the column sizer may pick SMALLER columns, shrinking b₀ → may NET-WORSEN punching. Always caveat.
    - grow_columns directly increases b₀ (most reliable punching fix). reinforce_first adds studs but does NOT grow columns — different mechanism.
    - For slab thickness / deflection / embodied carbon: GEOMETRY FIRST. Reducing spans (adding columns, subdividing bays) is the primary lever (deflection ∝ L⁴). Relaxing deflection_limit (L/360→L/240) is a secondary, optional suggestion — only mention it as an additional option if the project can tolerate more deflection and has no sensitive partitions or equipment.
    - uniform_column_sizing = off (independent sizing) is an embodied-carbon reduction strategy: each column is right-sized to its own demand. per_story/building promote every column to the governing (largest) section, adding unnecessary material to lightly-loaded columns. Mention this trade-off when the user asks about reducing carbon or material use.
  If uncertain about a directional effect, call predict_geometry_effect or run a micro-experiment. Do not guess.

GEOMETRY vs PARAMETERS:
  GEOMETRY (Grasshopper) — column positions, spans, heights, plan shape. Cannot change via API.
  PARAMETERS (API) — floor_type, materials, loads, method, sizing. Change via run_design.
  For geometry changes → tell user what to adjust in Grasshopper.

$(_parameter_space_card())

GEOMETRY DIGEST:
  If a digest appears below, it is authoritative — quote it. When GEOMETRY_CONTEXT.geometry_stale is true, cached results describe the last solved model, not current geometry.

PARAMETER CHANGES:
  Output a JSON code block with only changed fields. Include `_history_label` (≤6 words).

SESSION HISTORY:
  No comparison language unless get_design_history has ≥2 entries.

For anti-patterns and detailed rules, call get_response_guidelines.
$_TOOL_INDEX
$_CLARIFICATION_INSTRUCTION
$_NEXT_QUESTIONS_INSTRUCTION
DESIGN RESULTS SUMMARY:
"""

"""Max characters of structured geometry JSON in the chat system prompt (limits context size)."""
const _MAX_CHAT_BUILDING_GEOMETRY_JSON_CHARS = 120_000

"""
    _parse_chat_building_geometry(raw) -> Union{Nothing, Dict{String, Any}}

Normalize `building_geometry` or `geometry` from POST /chat into a string-keyed dict. Expected
shape matches the geometry section of POST /design (Grasshopper `BuildingGeometry.ToJson()`):
`units`, `vertices`, `edges`::{beams,columns,braces}, `supports`, `faces`::{category -> polygons}, optional `stories_z`.
"""
function _parse_chat_building_geometry(raw)::Union{Nothing, Dict{String, Any}}
    isnothing(raw) && return nothing
    if raw isa Dict{String, Any}
        return raw
    end
    if raw isa AbstractDict
        return Dict{String, Any}(string(k) => v for (k, v) in pairs(raw))
    end
    try
        d = JSON3.read(JSON3.write(raw))
        d isa AbstractDict || return nothing
        return Dict{String, Any}(string(k) => v for (k, v) in pairs(d))
    catch
        return nothing
    end
end

# ─── Chat-side structure cache ────────────────────────────────────────────────
#
# When POST /chat receives `building_geometry`, we build a lightweight
# BuildingSkeleton → BuildingStructure → initialize! to get real structural
# data (cells, slabs, members, tributaries) without running the solver.
# The result is cached by geometry hash to avoid re-initializing every turn.

mutable struct _ChatStructureCache
    geometry_hash::String
    structure::Union{BuildingStructure, Nothing}
    digest::Union{Dict{String, Any}, Nothing}
    lock::ReentrantLock
end
_ChatStructureCache() = _ChatStructureCache("", nothing, nothing, ReentrantLock())

const _CHAT_STRUCTURE_CACHE = _ChatStructureCache()

"""
    _chat_initialize_structure(geo_dict) -> (BuildingStructure, String)

Build a real `BuildingStructure` from chat `building_geometry` JSON.
Returns `(structure, geometry_hash)` or throws on failure.

Uses `json_to_skeleton` → `BuildingStructure` → `initialize!` with default
loads/material/floor options — enough to compute cells, slabs, members, and
tributaries without running the full design solver.
"""
function _chat_initialize_structure(geo_dict::Dict{String, Any})
    api_input = _api_input_geometry_only_from_chat_dict(geo_dict)
    geo_hash = compute_geometry_hash(api_input)

    skel = json_to_skeleton(api_input)
    struc = BuildingStructure(skel)
    initialize!(struc)  # defaults: flat_plate, GravityLoads(), NWC_4000
    return (struc, geo_hash)
end

"""
    _chat_geometry_sse_emit!(stream, phase; kwargs...)

Emit one SSE `data:` line with `type` = `geometry_init` for client loading traces.
`stream` may be `nothing` (no-op).
"""
function _chat_geometry_sse_emit!(
    stream::Union{Nothing, HTTP.Stream},
    phase::String;
    message::Union{Nothing, String} = nothing,
    geometry_hash_prefix::Union{Nothing, String} = nothing,
    elapsed_ms::Union{Nothing, Int} = nothing,
    cached::Union{Nothing, Bool} = nothing,
    extra::Union{Nothing, Dict{String, Any}} = nothing,
)
    isnothing(stream) && return
    d = Dict{String, Any}("type" => "geometry_init", "phase" => phase)
    !isnothing(message) && (d["message"] = message)
    !isnothing(geometry_hash_prefix) && (d["geometry_hash_prefix"] = geometry_hash_prefix)
    !isnothing(elapsed_ms) && (d["elapsed_ms"] = elapsed_ms)
    !isnothing(cached) && (d["cached"] = cached)
    if !isnothing(extra)
        for (k, v) in extra
            d[string(k)] = v
        end
    end
    write(stream, "data: $(JSON3.write(d))\n\n")
    return nothing
end

"""
    _chat_get_or_build_structure(geo_dict; sse_stream=nothing) -> Union{BuildingStructure, Nothing}

Thread-safe access to the chat structure cache. Returns a fully initialized
`BuildingStructure` with cells, members, and tributaries computed.
Returns `nothing` if initialization fails (logs warning).

When `sse_stream` is set, emits phased `geometry_init` SSE events for the UI.
"""
function _chat_get_or_build_structure(
    geo_dict::Dict{String, Any};
    sse_stream::Union{Nothing, HTTP.Stream} = nothing,
)::Union{BuildingStructure, Nothing}
    geo_hash = try
        compute_geometry_hash(_api_input_geometry_only_from_chat_dict(geo_dict))
    catch
        _chat_geometry_sse_emit!(
            sse_stream, "error";
            message = "Could not compute geometry hash for structure build.",
        )
        return nothing
    end
    hp = length(geo_hash) >= 8 ? geo_hash[1:8] : geo_hash

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        if _CHAT_STRUCTURE_CACHE.geometry_hash == geo_hash && !isnothing(_CHAT_STRUCTURE_CACHE.structure)
            _chat_geometry_sse_emit!(
                sse_stream, "cache_hit_structure";
                message = "Reusing initialized BuildingStructure from server cache (same geometry).",
                geometry_hash_prefix = hp,
                cached = true,
            )
            return _CHAT_STRUCTURE_CACHE.structure
        end
    end

    _chat_geometry_sse_emit!(
        sse_stream, "start";
        message = "Building analytical model from geometry (no structural solver).",
        geometry_hash_prefix = hp,
    )
    _chat_geometry_sse_emit!(
        sse_stream, "skeleton";
        message = "Parsing vertices, edges, faces, supports → BuildingSkeleton…",
        geometry_hash_prefix = hp,
    )
    t_skel = time()
    struc = try
        api_input = _api_input_geometry_only_from_chat_dict(geo_dict)
        skel = json_to_skeleton(api_input)
        _chat_geometry_sse_emit!(
            sse_stream, "skeleton_done";
            message = "Skeleton built.",
            geometry_hash_prefix = hp,
            elapsed_ms = round(Int, (time() - t_skel) * 1000),
            extra = Dict{String, Any}(
                "n_vertices" => length(skel.vertices),
                "n_edges" => length(skel.edges),
            ),
        )
        _chat_geometry_sse_emit!(
            sse_stream, "initialize";
            message = "initialize! — cells, slabs, framing, column tributaries…",
            geometry_hash_prefix = hp,
        )
        t_ini = time()
        struc = BuildingStructure(skel)
        initialize!(struc)
        _chat_geometry_sse_emit!(
            sse_stream, "initialize_done";
            message = "Structure initialized.",
            geometry_hash_prefix = hp,
            elapsed_ms = round(Int, (time() - t_ini) * 1000),
            extra = Dict{String, Any}(
                "n_cells" => length(struc.cells),
                "n_slabs" => length(struc.slabs),
                "n_beams" => length(struc.beams),
                "n_columns" => length(struc.columns),
            ),
        )
        struc
    catch e
        _chat_geometry_sse_emit!(
            sse_stream, "error";
            message = "Structure build failed: $(sprint(showerror, e))",
            geometry_hash_prefix = hp,
        )
        @warn "Chat structure initialization failed — falling back to raw JSON analysis" exception=(e, catch_backtrace())
        return nothing
    end

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        _CHAT_STRUCTURE_CACHE.geometry_hash = geo_hash
        _CHAT_STRUCTURE_CACHE.structure = struc
        _CHAT_STRUCTURE_CACHE.digest = nothing  # invalidate cached digest
    end
    return struc
end

"""
    _structure_geometry_digest(struc::BuildingStructure) -> Dict{String, Any}

Extract a rich geometry digest from an initialized `BuildingStructure`.
Includes real structural data: cell spans, slab panels, member lengths,
column tributary areas with variation metrics, beam spans, story info,
and grid regularity flags.

This replaces the raw-JSON `_chat_structured_geometry_stats` approach with
data computed by the same pipeline the solver uses.
"""
function _structure_geometry_digest(struc::BuildingStructure)::Dict{String, Any}
    skel = struc.skeleton
    result = Dict{String, Any}()
    warnings = String[]
    flags = String[]
    to_ft(x) = ustrip(u"ft", x)
    to_m2(x) = ustrip(u"m^2", x)

    # ── Counts ────────────────────────────────────────────────────────────
    result["n_cells"] = length(struc.cells)
    result["n_slabs"] = length(struc.slabs)
    result["n_beams"] = length(struc.beams)
    result["n_columns"] = length(struc.columns)
    result["n_stories"] = length(skel.stories)
    result["n_vertices"] = length(skel.vertices)
    result["n_supports"] = length(struc.supports)

    # ── Story heights ─────────────────────────────────────────────────────
    if length(skel.stories_z) >= 2
        sorted_z = sort(skel.stories_z)
        heights_ft = [to_ft(sorted_z[i+1] - sorted_z[i]) for i in 1:length(sorted_z)-1]
        result["stories"] = Dict{String, Any}(
            "n_stories" => length(sorted_z),
            "story_heights_ft" => round.(heights_ft; digits=2),
            "min_ft" => round(minimum(heights_ft); digits=2),
            "max_ft" => round(maximum(heights_ft); digits=2),
            "source" => "stories_z",
        )
        if maximum(heights_ft) > 18.0
            push!(flags, "tall_story_>18ft")
        end
    end

    # ── Cell spans ────────────────────────────────────────────────────────
    if !isempty(struc.cells)
        cell_data = Dict{String, Any}[]
        areas_ft2 = Float64[]
        primary_spans_ft = Float64[]
        secondary_spans_ft = Float64[]
        for (i, cell) in enumerate(struc.cells)
            a_ft2 = ustrip(u"ft^2", cell.area)
            p_ft = to_ft(cell.spans.primary)
            s_ft = to_ft(cell.spans.secondary)
            push!(areas_ft2, a_ft2)
            push!(primary_spans_ft, p_ft)
            push!(secondary_spans_ft, s_ft)
            push!(cell_data, Dict{String, Any}(
                "idx" => i,
                "area_ft2" => round(a_ft2; digits=1),
                "primary_span_ft" => round(p_ft; digits=2),
                "secondary_span_ft" => round(s_ft; digits=2),
                "position" => string(cell.position),
                "floor_type" => string(cell.floor_type),
            ))
        end
        result["cells"] = Dict{String, Any}(
            "count" => length(cell_data),
            "area_ft2" => Dict{String, Any}(
                "min" => round(minimum(areas_ft2); digits=1),
                "max" => round(maximum(areas_ft2); digits=1),
                "mean" => round(sum(areas_ft2) / length(areas_ft2); digits=1),
            ),
            "primary_span_ft" => Dict{String, Any}(
                "min" => round(minimum(primary_spans_ft); digits=2),
                "max" => round(maximum(primary_spans_ft); digits=2),
                "mean" => round(sum(primary_spans_ft) / length(primary_spans_ft); digits=2),
            ),
            "secondary_span_ft" => Dict{String, Any}(
                "min" => round(minimum(secondary_spans_ft); digits=2),
                "max" => round(maximum(secondary_spans_ft); digits=2),
                "mean" => round(sum(secondary_spans_ft) / length(secondary_spans_ft); digits=2),
            ),
            "positions" => Dict{String, Int}(
                string(k) => count(c -> c.position == k, struc.cells)
                for k in unique(c.position for c in struc.cells)
            ),
        )
        # Truncate per-cell detail if too many
        if length(cell_data) <= 30
            result["cells"]["detail"] = cell_data
        else
            result["cells"]["detail_note"] = "$(length(cell_data)) cells (detail truncated). Use stats above."
        end
    end

    # ── Slab panels ───────────────────────────────────────────────────────
    if !isempty(struc.slabs)
        slab_data = Dict{String, Any}[]
        for (i, slab) in enumerate(struc.slabs)
            p_ft = to_ft(slab.spans.primary)
            s_ft = to_ft(slab.spans.secondary)
            ratio = s_ft > 0.01 ? round(p_ft / s_ft; digits=2) : 0.0
            push!(slab_data, Dict{String, Any}(
                "idx" => i,
                "n_cells" => length(slab.cell_indices),
                "primary_span_ft" => round(p_ft; digits=2),
                "secondary_span_ft" => round(s_ft; digits=2),
                "aspect_ratio" => ratio,
                "position" => string(slab.position),
                "floor_type" => string(slab.floor_type),
            ))
        end
        result["slabs"] = Dict{String, Any}(
            "count" => length(slab_data),
            "detail" => slab_data,
        )
    end

    # ── Beam spans ────────────────────────────────────────────────────────
    if !isempty(struc.beams)
        beam_spans_ft = Float64[]
        x_spans = Float64[]
        y_spans = Float64[]
        for beam in struc.beams
            L_ft = to_ft(beam.base.L)
            push!(beam_spans_ft, L_ft)
            seg_indices = beam.base.segment_indices
            if !isempty(seg_indices)
                seg = struc.segments[first(seg_indices)]
                vi1, vi2 = skel.edge_indices[seg.edge_idx]
                v1 = skel.vertices[vi1]
                v2 = skel.vertices[vi2]
                dx = abs(ustrip(u"m", Meshes.coords(v2).x - Meshes.coords(v1).x))
                dy = abs(ustrip(u"m", Meshes.coords(v2).y - Meshes.coords(v1).y))
                if dx >= dy
                    push!(x_spans, L_ft)
                else
                    push!(y_spans, L_ft)
                end
            end
        end
        beam_stats = Dict{String, Any}(
            "count" => length(beam_spans_ft),
            "all" => _stats_dict(beam_spans_ft, "ft"),
        )
        !isempty(x_spans) && (beam_stats["x_direction"] = _stats_dict(x_spans, "ft"))
        !isempty(y_spans) && (beam_stats["y_direction"] = _stats_dict(y_spans, "ft"))
        result["beam_spans"] = beam_stats

        max_span_ft = maximum(beam_spans_ft)
        if max_span_ft > 30.0
            push!(flags, "long_beam_span_>30ft ($(round(max_span_ft; digits=1)) ft)")
        end
    end

    # ── Column heights ────────────────────────────────────────────────────
    if !isempty(struc.columns)
        col_heights_ft = [to_ft(col.base.L) for col in struc.columns]
        result["column_heights"] = _stats_dict(col_heights_ft, "ft")
    end

    # ── Column tributary areas ────────────────────────────────────────────
    if !isempty(struc.columns)
        trib_areas_ft2 = Float64[]
        per_column = Dict{String, Any}[]
        # Group by position for within-class CV (the real irregularity signal)
        by_position = Dict{Symbol, Vector{Float64}}()
        for (i, col) in enumerate(struc.columns)
            At = column_tributary_area(struc, col)
            if !isnothing(At)
                a_ft2 = ustrip(u"ft^2", At)
                push!(trib_areas_ft2, a_ft2)
                pos = col.position
                haskey(by_position, pos) || (by_position[pos] = Float64[])
                push!(by_position[pos], a_ft2)
                push!(per_column, Dict{String, Any}(
                    "idx" => i,
                    "story" => col.story,
                    "position" => string(pos),
                    "tributary_ft2" => round(a_ft2; digits=1),
                    "height_ft" => round(to_ft(col.base.L); digits=2),
                ))
            end
        end
        if !isempty(trib_areas_ft2)
            mean_a = sum(trib_areas_ft2) / length(trib_areas_ft2)
            std_a = length(trib_areas_ft2) > 1 ? sqrt(sum((x - mean_a)^2 for x in trib_areas_ft2) / (length(trib_areas_ft2) - 1)) : 0.0
            cv_overall = mean_a > 0 ? std_a / mean_a : 0.0
            sorted = sort(trib_areas_ft2)
            p10 = sorted[max(1, round(Int, 0.1 * length(sorted)))]
            p90 = sorted[min(length(sorted), round(Int, 0.9 * length(sorted)))]

            # Within-position CV: measures true grid irregularity, filtering out the
            # natural corner/edge/interior variation present in any regular grid.
            within_cvs = Float64[]
            position_stats = Dict{String, Any}()
            for (pos, areas) in by_position
                n = length(areas)
                m = sum(areas) / n
                s = n > 1 ? sqrt(sum((x - m)^2 for x in areas) / (n - 1)) : 0.0
                wcv = m > 0 ? s / m : 0.0
                push!(within_cvs, wcv)
                position_stats[string(pos)] = Dict{String, Any}(
                    "count" => n,
                    "mean_ft2" => round(m; digits=1),
                    "cv" => round(wcv; digits=3),
                )
            end
            max_within_cv = isempty(within_cvs) ? 0.0 : maximum(within_cvs)

            trib_stats = Dict{String, Any}(
                "count" => length(trib_areas_ft2),
                "min_ft2" => round(minimum(trib_areas_ft2); digits=1),
                "max_ft2" => round(maximum(trib_areas_ft2); digits=1),
                "mean_ft2" => round(mean_a; digits=1),
                "cv_overall" => round(cv_overall; digits=3),
                "cv_within_position" => round(max_within_cv; digits=3),
                "p10_ft2" => round(p10; digits=1),
                "p90_ft2" => round(p90; digits=1),
                "by_position" => position_stats,
            )

            # Irregularity classification uses within-position CV to avoid
            # flagging the natural 4:2:1 ratio of interior:edge:corner tributaries.
            regularity = if max_within_cv < 0.15
                "regular"
            elseif max_within_cv < 0.30
                "moderately_irregular"
            else
                "irregular"
            end
            trib_stats["grid_regularity"] = regularity
            trib_stats["interpretation"] = if regularity == "regular"
                "Column tributary areas are consistent within each position class " *
                "(corner/edge/interior) — grid is regular. DDM assumptions apply."
            elseif regularity == "moderately_irregular"
                "Moderate within-position tributary variation (max CV=$(round(max_within_cv; digits=2))). " *
                "Some same-position columns carry different loads — check punching shear. Consider FEA."
            else
                "Large within-position tributary variation (max CV=$(round(max_within_cv; digits=2))). " *
                "Grid is irregular — DDM regularity assumptions may not hold. FEA recommended. " *
                "Punching shear likely governs at high-tributary columns."
            end
            result["column_tributaries"] = trib_stats

            if regularity != "regular"
                push!(flags, "irregular_grid_tributaries ($(regularity), within-position CV=$(round(max_within_cv; digits=2)))")
            end

            if length(per_column) <= 40
                trib_stats["per_column"] = per_column
            else
                trib_stats["per_column_note"] = "$(length(per_column)) columns (detail truncated)."
            end
        end
    end

    # ── Envelope ──────────────────────────────────────────────────────────
    if !isempty(skel.vertices)
        xs = [ustrip(u"ft", Meshes.coords(v).x) for v in skel.vertices]
        ys = [ustrip(u"ft", Meshes.coords(v).y) for v in skel.vertices]
        zs = [ustrip(u"ft", Meshes.coords(v).z) for v in skel.vertices]
        result["envelope"] = Dict{String, Any}(
            "footprint_x_ft" => round(maximum(xs) - minimum(xs); digits=2),
            "footprint_y_ft" => round(maximum(ys) - minimum(ys); digits=2),
            "total_height_ft" => round(maximum(zs) - minimum(zs); digits=2),
            "unit" => "ft",
        )
    end

    # ── Structural flags ──────────────────────────────────────────────────
    !isempty(flags) && (result["structural_flags"] = flags)
    !isempty(warnings) && (result["warnings"] = warnings)
    result["source"] = "BuildingStructure_initialized"
    result["unit_system"] = "imperial"
    return result
end

"""Helper: compute min/max/mean/CV stats dict from a numeric vector."""
function _stats_dict(vals::Vector{Float64}, unit::String)::Dict{String, Any}
    n = length(vals)
    n == 0 && return Dict{String, Any}("count" => 0)
    mn = minimum(vals)
    mx = maximum(vals)
    mean_v = sum(vals) / n
    std_v = n > 1 ? sqrt(sum((x - mean_v)^2 for x in vals) / (n - 1)) : 0.0
    cv = mean_v > 0 ? std_v / mean_v : 0.0
    return Dict{String, Any}(
        "count" => n,
        "min" => round(mn; digits=2),
        "max" => round(mx; digits=2),
        "mean" => round(mean_v; digits=2),
        "cv" => round(cv; digits=3),
        "unit" => unit,
    )
end

"""
    _structure_digest_plaintext(d::Dict{String, Any}) -> String

Render the structure-based geometry digest as a compact LLM-readable block.
"""
function _structure_digest_plaintext(d::Dict{String, Any})::String
    lines = String["── STRUCTURE-BASED GEOMETRY DIGEST (authoritative — MUST USE) ──"]
    push!(lines, "MANDATORY: Quote the numbers below directly. Do NOT say spans are unknown or need further analysis.")
    push!(lines, "Source: BuildingStructure (skeleton → initialize! — same pipeline as solver)")

    # Counts
    push!(lines, "Elements: $(get(d, "n_cells", 0)) cells, $(get(d, "n_slabs", 0)) slabs, " *
                  "$(get(d, "n_beams", 0)) beams, $(get(d, "n_columns", 0)) columns")

    # Stories
    st = get(d, "stories", nothing)
    if !isnothing(st)
        n = get(st, "n_stories", "?")
        push!(lines, "Stories: $n levels")
        sh = get(st, "story_heights_ft", nothing)
        if !isnothing(sh) && !isempty(sh)
            push!(lines, "  Heights: $(join(sh, ", ")) ft")
        end
    end

    # Envelope
    env = get(d, "envelope", nothing)
    if !isnothing(env)
        push!(lines, "Footprint: $(env["footprint_x_ft"]) × $(env["footprint_y_ft"]) ft")
        push!(lines, "Total height: $(env["total_height_ft"]) ft")
    end

    # Cell spans
    cells = get(d, "cells", nothing)
    if !isnothing(cells)
        ps = get(cells, "primary_span_ft", nothing)
        ss = get(cells, "secondary_span_ft", nothing)
        if !isnothing(ps)
            push!(lines, "Cell primary spans: $(ps["min"])–$(ps["max"]) ft (mean $(ps["mean"]) ft)")
        end
        if !isnothing(ss)
            push!(lines, "Cell secondary spans: $(ss["min"])–$(ss["max"]) ft (mean $(ss["mean"]) ft)")
        end
        pos = get(cells, "positions", nothing)
        if !isnothing(pos)
            push!(lines, "  Positions: " * join(["$k=$v" for (k, v) in pos], ", "))
        end
    end

    # Beam spans
    bs = get(d, "beam_spans", nothing)
    if !isnothing(bs)
        all_s = get(bs, "all", nothing)
        if !isnothing(all_s)
            push!(lines, "Beam spans: $(all_s["min"])–$(all_s["max"]) ft (mean $(all_s["mean"]) ft, $(all_s["count"]) beams)")
        end
        xd = get(bs, "x_direction", nothing)
        yd = get(bs, "y_direction", nothing)
        if !isnothing(xd)
            push!(lines, "  X-direction: $(xd["min"])–$(xd["max"]) ft ($(xd["count"]) beams)")
        end
        if !isnothing(yd)
            push!(lines, "  Y-direction: $(yd["min"])–$(yd["max"]) ft ($(yd["count"]) beams)")
        end
    end

    # Column heights
    ch = get(d, "column_heights", nothing)
    if !isnothing(ch)
        push!(lines, "Column heights: $(ch["min"])–$(ch["max"]) ft (mean $(ch["mean"]) ft)")
    end

    # Column tributaries
    ct = get(d, "column_tributaries", nothing)
    if !isnothing(ct)
        push!(lines, "Column tributary areas: $(ct["min_ft2"])–$(ct["max_ft2"]) ft² (mean $(ct["mean_ft2"]) ft²)")
        cv_overall = get(ct, "cv_overall", get(ct, "cv", "?"))
        cv_within = get(ct, "cv_within_position", "?")
        push!(lines, "  Overall CV=$(cv_overall), within-position CV=$(cv_within), p10=$(ct["p10_ft2"]) ft², p90=$(ct["p90_ft2"]) ft²")
        bp = get(ct, "by_position", nothing)
        if !isnothing(bp)
            for (pos, ps) in bp
                push!(lines, "  $(pos): n=$(ps["count"]), mean=$(ps["mean_ft2"]) ft², CV=$(ps["cv"])")
            end
        end
        push!(lines, "  Grid regularity: $(ct["grid_regularity"])")
        interp = get(ct, "interpretation", nothing)
        !isnothing(interp) && push!(lines, "  → $interp")
    end

    # Slab panels (compact)
    slabs = get(d, "slabs", nothing)
    if !isnothing(slabs) && !isempty(get(slabs, "detail", []))
        details = slabs["detail"]
        types_count = Dict{String, Int}()
        for s in details
            ft = get(s, "floor_type", "unknown")
            types_count[ft] = get(types_count, ft, 0) + 1
        end
        push!(lines, "Slab panels: $(slabs["count"]) (" * join(["$v×$k" for (k, v) in types_count], ", ") * ")")
    end

    # Flags
    fl = get(d, "structural_flags", nothing)
    if !isnothing(fl) && !isempty(fl)
        push!(lines, "⚡ Structural flags: " * join(fl, ", "))
    end

    push!(lines, "── END DIGEST ──")
    return join(lines, "\n") * "\n"
end

"""
    _chat_get_structure_digest(geo_dict; sse_stream=nothing) -> Union{Dict{String, Any}, Nothing}

Get (or compute + cache) a structure-based geometry digest.
Returns `nothing` if structure initialization fails.

When `sse_stream` is set, emits `geometry_init` phases (`cache_hit_digest`, `digest`,
`digest_done`, `complete`, `fallback`) for client loading traces.
"""
function _chat_get_structure_digest(
    geo_dict::Dict{String, Any};
    sse_stream::Union{Nothing, HTTP.Stream} = nothing,
)::Union{Dict{String, Any}, Nothing}
    t0 = time()
    geo_hash = try
        compute_geometry_hash(_api_input_geometry_only_from_chat_dict(geo_dict))
    catch
        _chat_geometry_sse_emit!(
            sse_stream, "error";
            message = "Could not compute geometry hash for digest.",
        )
        return nothing
    end
    hp = length(geo_hash) >= 8 ? geo_hash[1:8] : geo_hash

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        if _CHAT_STRUCTURE_CACHE.geometry_hash == geo_hash && !isnothing(_CHAT_STRUCTURE_CACHE.digest)
            d = _CHAT_STRUCTURE_CACHE.digest
            _chat_geometry_sse_emit!(
                sse_stream, "cache_hit_digest";
                message = "Geometry digest already cached for this model.",
                geometry_hash_prefix = hp,
                cached = true,
            )
            _chat_geometry_sse_emit!(
                sse_stream, "complete";
                message = "Geometry ready for assistant.",
                geometry_hash_prefix = hp,
                elapsed_ms = round(Int, (time() - t0) * 1000),
                cached = true,
                extra = Dict{String, Any}(
                    "structure_digest_ok" => true,
                    "n_cells" => get(d, "n_cells", 0),
                    "n_slabs" => get(d, "n_slabs", 0),
                    "n_beams" => get(d, "n_beams", 0),
                    "n_columns" => get(d, "n_columns", 0),
                ),
            )
            return d
        end
    end

    struc = _chat_get_or_build_structure(geo_dict; sse_stream=sse_stream)
    if isnothing(struc)
        _chat_geometry_sse_emit!(
            sse_stream, "fallback";
            message = "Using lightweight raw-JSON geometry stats (structure init unavailable).",
            geometry_hash_prefix = hp,
            extra = Dict{String, Any}("structure_digest_ok" => false),
        )
        _chat_geometry_sse_emit!(
            sse_stream, "complete";
            message = "Geometry preprocessing finished (fallback mode).",
            geometry_hash_prefix = hp,
            elapsed_ms = round(Int, (time() - t0) * 1000),
            extra = Dict{String, Any}("structure_digest_ok" => false),
        )
        return nothing
    end

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        if _CHAT_STRUCTURE_CACHE.geometry_hash == geo_hash && !isnothing(_CHAT_STRUCTURE_CACHE.digest)
            d = _CHAT_STRUCTURE_CACHE.digest
            _chat_geometry_sse_emit!(
                sse_stream, "complete";
                message = "Geometry ready for assistant.",
                geometry_hash_prefix = hp,
                elapsed_ms = round(Int, (time() - t0) * 1000),
                cached = true,
                extra = Dict{String, Any}(
                    "structure_digest_ok" => true,
                    "n_cells" => get(d, "n_cells", 0),
                    "n_slabs" => get(d, "n_slabs", 0),
                    "n_beams" => get(d, "n_beams", 0),
                    "n_columns" => get(d, "n_columns", 0),
                ),
            )
            return d
        end
    end

    _chat_geometry_sse_emit!(
        sse_stream, "digest";
        message = "Computing assistant geometry digest (spans, tributaries, flags)…",
        geometry_hash_prefix = hp,
    )
    t_d = time()
    digest = try
        _structure_geometry_digest(struc)
    catch e
        _chat_geometry_sse_emit!(
            sse_stream, "error";
            message = "Digest failed: $(sprint(showerror, e))",
            geometry_hash_prefix = hp,
        )
        @warn "Structure geometry digest failed" exception=(e, catch_backtrace())
        _chat_geometry_sse_emit!(
            sse_stream, "fallback";
            message = "Digest computation failed; assistant will use raw JSON stats if available.",
            geometry_hash_prefix = hp,
            extra = Dict{String, Any}("structure_digest_ok" => false),
        )
        _chat_geometry_sse_emit!(
            sse_stream, "complete";
            message = "Geometry preprocessing finished (digest error).",
            geometry_hash_prefix = hp,
            elapsed_ms = round(Int, (time() - t0) * 1000),
            extra = Dict{String, Any}("structure_digest_ok" => false),
        )
        return nothing
    end

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        _CHAT_STRUCTURE_CACHE.digest = digest
    end
    _chat_geometry_sse_emit!(
        sse_stream, "digest_done";
        message = "Digest computed.",
        geometry_hash_prefix = hp,
        elapsed_ms = round(Int, (time() - t_d) * 1000),
    )
    _chat_geometry_sse_emit!(
        sse_stream, "complete";
        message = "Geometry ready for assistant.",
        geometry_hash_prefix = hp,
        elapsed_ms = round(Int, (time() - t0) * 1000),
        extra = Dict{String, Any}(
            "structure_digest_ok" => true,
            "n_cells" => get(digest, "n_cells", 0),
            "n_slabs" => get(digest, "n_slabs", 0),
            "n_beams" => get(digest, "n_beams", 0),
            "n_columns" => get(digest, "n_columns", 0),
        ),
    )
    return digest
end

# ─── Pre-design geometry analysis (raw JSON → enriched stats for LLM) ────────
#
# These helpers operate on the raw building_geometry dict from POST /chat,
# requiring no BuildingSkeleton or Unitful — pure arithmetic on JSON arrays.
# The goal is to give the LLM concrete numbers (spans, heights, panel shapes)
# at opening-analysis time, before any POST /design.

"""Unit string → scale factor to meters.  Falls back to 1.0 (assume meters)."""
function _chat_geo_unit_to_m(units::String)::Float64
    s = lowercase(strip(units))
    s in ("feet", "ft")        && return 0.3048
    s in ("inches", "in")      && return 0.0254
    s in ("meters", "m", "")   && return 1.0
    s in ("millimeters", "mm") && return 0.001
    s in ("centimeters", "cm") && return 0.01
    return 1.0
end

"""Display-unit label from the geometry's unit string (\"ft\", \"m\", etc.)."""
function _chat_geo_unit_label(units::String)::String
    s = lowercase(strip(units))
    s in ("feet", "ft")        && return "ft"
    s in ("inches", "in")      && return "in"
    s in ("meters", "m", "")   && return "m"
    s in ("millimeters", "mm") && return "mm"
    s in ("centimeters", "cm") && return "cm"
    return s
end

"""Extract `[x,y,z]` from a raw JSON vertex entry. Returns `nothing` on bad data."""
function _chat_geo_vertex(v)::Union{Nothing, NTuple{3,Float64}}
    (v isa AbstractVector && length(v) >= 3) || return nothing
    try
        return (Float64(v[1]), Float64(v[2]), Float64(v[3]))
    catch
        return nothing
    end
end

"""Euclidean distance between two 3D vertices (in raw coordinate units)."""
function _chat_geo_dist(a::NTuple{3,Float64}, b::NTuple{3,Float64})::Float64
    return sqrt((b[1]-a[1])^2 + (b[2]-a[2])^2 + (b[3]-a[3])^2)
end

"""
Compute edge lengths (in raw units) for a set of `[i,j]` 1-based index pairs.
Returns a vector of lengths, skipping any edge with bad vertex references.
"""
function _chat_geo_edge_lengths(verts::AbstractVector, edges::AbstractVector)::Vector{Float64}
    lengths = Float64[]
    for e in edges
        (e isa AbstractVector && length(e) >= 2) || continue
        i, j = try (Int(e[1]), Int(e[2])) catch; continue end
        (1 <= i <= length(verts) && 1 <= j <= length(verts)) || continue
        a = _chat_geo_vertex(verts[i])
        b = _chat_geo_vertex(verts[j])
        (isnothing(a) || isnothing(b)) && continue
        d = _chat_geo_dist(a, b)
        d > 0.0 && push!(lengths, d)
    end
    return lengths
end

"""
Classify a horizontal beam edge as primarily X- or Y-oriented based on which
plan-projection delta dominates.  Returns `:x`, `:y`, or `:diagonal`.
"""
function _chat_geo_beam_direction(a::NTuple{3,Float64}, b::NTuple{3,Float64})::Symbol
    dx = abs(b[1] - a[1])
    dy = abs(b[2] - a[2])
    total = dx + dy
    total < 1e-9 && return :diagonal
    dx / total > 0.7 && return :x
    dy / total > 0.7 && return :y
    return :diagonal
end

"""
Compute beam span stats with directional breakdown.
Returns `(all_stats, x_stats, y_stats)` where each is a Dict or `nothing`.
"""
function _chat_geo_beam_span_stats(
    verts::AbstractVector, beam_edges::AbstractVector, unit_label::String,
)::Tuple{Union{Nothing,Dict{String,Any}}, Union{Nothing,Dict{String,Any}}, Union{Nothing,Dict{String,Any}}}
    all_lengths = Float64[]
    x_lengths   = Float64[]
    y_lengths   = Float64[]
    for e in beam_edges
        (e isa AbstractVector && length(e) >= 2) || continue
        i, j = try (Int(e[1]), Int(e[2])) catch; continue end
        (1 <= i <= length(verts) && 1 <= j <= length(verts)) || continue
        a = _chat_geo_vertex(verts[i])
        b = _chat_geo_vertex(verts[j])
        (isnothing(a) || isnothing(b)) && continue
        d = _chat_geo_dist(a, b)
        d < 1e-6 && continue
        push!(all_lengths, d)
        dir = _chat_geo_beam_direction(a, b)
        dir == :x && push!(x_lengths, d)
        dir == :y && push!(y_lengths, d)
    end

    _make_stats = (ls::Vector{Float64}, label::String) -> begin
        isempty(ls) && return nothing
        mn = minimum(ls)
        mx = maximum(ls)
        μ  = sum(ls) / length(ls)
        cv = length(ls) > 1 ? sqrt(sum((l - μ)^2 for l in ls) / (length(ls) - 1)) / μ : 0.0
        Dict{String, Any}(
            "min"  => round(mn; digits=2),
            "max"  => round(mx; digits=2),
            "mean" => round(μ;  digits=2),
            "cv"   => round(cv; digits=3),
            "n"    => length(ls),
            "unit" => unit_label,
            "basis" => label,
        )
    end

    all_s = _make_stats(all_lengths, "all_beam_edges")
    x_s   = _make_stats(x_lengths,   "x_direction_beams")
    y_s   = _make_stats(y_lengths,   "y_direction_beams")
    return (all_s, x_s, y_s)
end

"""
Compute story heights from `stories_z` array.
Returns `(heights_in_units, stats_dict)` or `([], nothing)`.
"""
function _chat_geo_story_analysis(stories_z::AbstractVector, unit_label::String)
    zs = Float64[]
    for z in stories_z
        try push!(zs, Float64(z)) catch; end
    end
    sort!(zs)
    length(zs) < 2 && return (Float64[], nothing)

    heights = Float64[zs[i] - zs[i-1] for i in 2:length(zs)]
    filter!(h -> h > 0, heights)
    isempty(heights) && return (Float64[], nothing)

    stats = Dict{String, Any}(
        "n_stories"  => length(heights),
        "heights"    => round.(heights; digits=2),
        "min"        => round(minimum(heights); digits=2),
        "max"        => round(maximum(heights); digits=2),
        "total"      => round(sum(heights); digits=2),
        "unit"       => unit_label,
    )
    if maximum(heights) - minimum(heights) > 0.01 * maximum(heights)
        stats["regularity"] = "variable"
    else
        stats["regularity"] = "uniform"
    end
    return (heights, stats)
end

"""
Analyse slab panels from the `faces` dict in raw geometry JSON.
Computes panel topology (tri/quad/other), aspect ratios, and corner orthogonality.
"""
function _chat_geo_panel_analysis(faces_dict, unit_label::String)::Union{Nothing, Dict{String, Any}}
    (faces_dict isa AbstractDict) || return nothing

    slab_polys = Any[]
    for cat in ("floor", "roof")
        polys = get(faces_dict, cat, nothing)
        if isnothing(polys)
            polys = get(faces_dict, Symbol(cat), nothing)
        end
        polys isa AbstractVector && append!(slab_polys, polys)
    end
    isempty(slab_polys) && return nothing

    n_tri, n_quad, n_other = 0, 0, 0
    panel_aspects = Float64[]
    quad_corner_devs = Float64[]
    quad_max_devs = Float64[]
    panel_max_spans = Float64[]
    panel_min_spans = Float64[]
    n_quad_orthogonal = 0

    for poly in slab_polys
        poly isa AbstractVector || continue
        pts_xy = NTuple{2,Float64}[]
        for pt in poly
            (pt isa AbstractVector && length(pt) >= 2) || continue
            try
                push!(pts_xy, (Float64(pt[1]), Float64(pt[2])))
            catch; end
        end
        nv = length(pts_xy)
        nv < 3 && continue

        if nv == 3
            n_tri += 1
        elseif nv == 4
            n_quad += 1
        else
            n_other += 1
        end

        # Edge lengths of this panel
        edge_ls = Float64[]
        for i in 1:nv
            j = i == nv ? 1 : i + 1
            push!(edge_ls, hypot(pts_xy[j][1] - pts_xy[i][1], pts_xy[j][2] - pts_xy[i][2]))
        end
        filter!(l -> l > 1e-6, edge_ls)
        if !isempty(edge_ls)
            push!(panel_max_spans, maximum(edge_ls))
            push!(panel_min_spans, minimum(edge_ls))
            mn_e = minimum(edge_ls)
            mn_e > 1e-4 && push!(panel_aspects, maximum(edge_ls) / mn_e)
        end

        # Quad corner orthogonality
        if nv == 4
            angs = Float64[]
            for i in 1:4
                im = i == 1 ? 4 : i - 1
                ip = i == 4 ? 1 : i + 1
                p_im, p_i, p_ip = pts_xy[im], pts_xy[i], pts_xy[ip]
                v1x, v1y = p_im[1] - p_i[1], p_im[2] - p_i[2]
                v2x, v2y = p_ip[1] - p_i[1], p_ip[2] - p_i[2]
                nv1 = hypot(v1x, v1y)
                nv2 = hypot(v2x, v2y)
                (nv1 < 1e-9 || nv2 < 1e-9) && continue
                d = clamp((v1x * v2x + v1y * v2y) / (nv1 * nv2), -1.0, 1.0)
                push!(angs, rad2deg(acos(d)))
            end
            if length(angs) == 4
                devs = [abs(a - 90.0) for a in angs]
                append!(quad_corner_devs, devs)
                push!(quad_max_devs, maximum(devs))
                if sum(devs) / 4 < 6.0
                    n_quad_orthogonal += 1
                end
            end
        end
    end

    n_panels = n_tri + n_quad + n_other
    n_panels == 0 && return nothing

    aspect_stats = if !isempty(panel_aspects)
        μ = sum(panel_aspects) / length(panel_aspects)
        Dict{String, Any}(
            "min"  => round(minimum(panel_aspects); digits=2),
            "max"  => round(maximum(panel_aspects); digits=2),
            "mean" => round(μ; digits=2),
            "n"    => length(panel_aspects),
        )
    else
        nothing
    end

    q_mean_dev = isempty(quad_corner_devs) ? nothing : sum(quad_corner_devs) / length(quad_corner_devs)
    q_max_dev  = isempty(quad_max_devs) ? nothing : maximum(quad_max_devs)

    classification = if n_other > 0 || (n_quad == 0 && n_tri > 0) || n_tri / n_panels > 0.35
        "triangular_mixed_or_complex_panels"
    elseif n_quad > 0 && !isnothing(q_mean_dev) && !isnothing(q_max_dev) &&
           (q_mean_dev > 8.0 || q_max_dev > 15.0)
        "non_orthogonal_or_skewed_quads"
    elseif n_quad > 0 && !isnothing(aspect_stats) && !isnothing(q_mean_dev) &&
           aspect_stats["mean"] > 1.0 &&
           (let cv_a = length(panel_aspects) > 1 ? sqrt(sum((a - sum(panel_aspects)/length(panel_aspects))^2 for a in panel_aspects) / (length(panel_aspects)-1)) / (sum(panel_aspects)/length(panel_aspects)) : 0.0; cv_a > 0.28 end) &&
           q_mean_dev <= 8.0
        "orthogonal_cells_variable_bay_aspect"
    elseif n_quad > 0 && !isnothing(q_mean_dev) && q_mean_dev <= 8.0
        "orthogonal_rectangular_cells"
    else
        "undetermined"
    end

    result = Dict{String, Any}(
        "n_panels"  => n_panels,
        "topology"  => Dict{String, Any}(
            "triangular" => n_tri, "quadrilateral" => n_quad, "other" => n_other,
        ),
        "plan_shape_classification" => classification,
        "panel_edge_aspect_ratio" => aspect_stats,
    )

    if !isempty(panel_max_spans)
        result["panel_max_edge"] = Dict{String,Any}(
            "min" => round(minimum(panel_max_spans); digits=2),
            "max" => round(maximum(panel_max_spans); digits=2),
            "unit" => unit_label,
        )
    end

    if !isnothing(q_mean_dev) || !isnothing(q_max_dev)
        result["quad_corner_deviation_from_90_deg"] = Dict{String, Any}(
            "mean" => round(something(q_mean_dev, 0.0); digits=2),
            "max"  => round(something(q_max_dev, 0.0); digits=2),
        )
    end

    ortho_frac = n_quad > 0 ? n_quad_orthogonal / n_quad : nothing
    if !isnothing(ortho_frac)
        result["fraction_quads_orthogonal"] = round(ortho_frac; digits=3)
    end

    return result
end

"""
Compute column grid analysis: unique XY positions, nearest-neighbour spacing,
edge vs interior classification via convex hull membership.
"""
function _chat_geo_column_grid_analysis(
    verts::AbstractVector, column_edges::AbstractVector, unit_label::String,
)::Union{Nothing, Dict{String, Any}}
    # Collect unique column base XY positions (use the lower-z endpoint of each column edge)
    col_xy = NTuple{2,Float64}[]
    for e in column_edges
        (e isa AbstractVector && length(e) >= 2) || continue
        i, j = try (Int(e[1]), Int(e[2])) catch; continue end
        (1 <= i <= length(verts) && 1 <= j <= length(verts)) || continue
        a = _chat_geo_vertex(verts[i])
        b = _chat_geo_vertex(verts[j])
        (isnothing(a) || isnothing(b)) && continue
        base = a[3] <= b[3] ? a : b
        xy = (round(base[1]; digits=6), round(base[2]; digits=6))
        xy in col_xy || push!(col_xy, xy)
    end
    length(col_xy) < 2 && return nothing

    # Nearest-neighbour distances
    nn_dists = Float64[]
    for (idx, p) in enumerate(col_xy)
        dmin = Inf
        for (jdx, q) in enumerate(col_xy)
            idx == jdx && continue
            d = hypot(q[1] - p[1], q[2] - p[2])
            d < dmin && (dmin = d)
        end
        dmin < Inf && push!(nn_dists, dmin)
    end

    nn_stats = if !isempty(nn_dists)
        Dict{String, Any}(
            "min"  => round(minimum(nn_dists); digits=2),
            "max"  => round(maximum(nn_dists); digits=2),
            "mean" => round(sum(nn_dists) / length(nn_dists); digits=2),
            "unit" => unit_label,
        )
    else
        nothing
    end

    # Grid regularity: cluster X and Y coordinates independently
    xs = sort(unique(round(p[1]; digits=3) for p in col_xy))
    ys = sort(unique(round(p[2]; digits=3) for p in col_xy))

    grid_info = Dict{String, Any}(
        "n_unique_positions" => length(col_xy),
        "n_gridlines_x"     => length(xs),
        "n_gridlines_y"     => length(ys),
    )

    if length(xs) >= 2
        x_spacings = Float64[xs[i] - xs[i-1] for i in 2:length(xs)]
        grid_info["gridline_spacings_x"] = round.(x_spacings; digits=2)
        grid_info["gridline_spacings_x_unit"] = unit_label
    end
    if length(ys) >= 2
        y_spacings = Float64[ys[i] - ys[i-1] for i in 2:length(ys)]
        grid_info["gridline_spacings_y"] = round.(y_spacings; digits=2)
        grid_info["gridline_spacings_y_unit"] = unit_label
    end

    # Simple convex hull edge/interior split using 2D cross-product test
    n_edge = 0
    n_interior = 0
    if length(col_xy) >= 3
        hull = _chat_geo_convex_hull_2d(col_xy)
        hull_set = Set(hull)
        for p in col_xy
            if p in hull_set
                n_edge += 1
            else
                n_interior += 1
            end
        end
        grid_info["n_edge_columns"] = n_edge
        grid_info["n_interior_columns"] = n_interior
    end

    result = Dict{String, Any}("grid" => grid_info)
    !isnothing(nn_stats) && (result["nearest_neighbour_spacing"] = nn_stats)
    return result
end

"""Simple 2D convex hull (Andrew's monotone chain). Returns hull points in order."""
function _chat_geo_convex_hull_2d(points::Vector{NTuple{2,Float64}})::Vector{NTuple{2,Float64}}
    pts = sort(points; by=p->(p[1], p[2]))
    n = length(pts)
    n <= 2 && return pts

    _cross(o, a, b) = (a[1]-o[1])*(b[2]-o[2]) - (a[2]-o[2])*(b[1]-o[1])

    lower = NTuple{2,Float64}[]
    for p in pts
        while length(lower) >= 2 && _cross(lower[end-1], lower[end], p) <= 0
            pop!(lower)
        end
        push!(lower, p)
    end
    upper = NTuple{2,Float64}[]
    for p in reverse(pts)
        while length(upper) >= 2 && _cross(upper[end-1], upper[end], p) <= 0
            pop!(upper)
        end
        push!(upper, p)
    end
    pop!(lower)
    pop!(upper)
    return vcat(lower, upper)
end

"""
Compute building envelope: bounding box, footprint dimensions, total height.
"""
function _chat_geo_envelope(verts::AbstractVector, unit_label::String)::Union{Nothing, Dict{String, Any}}
    xs, ys, zs = Float64[], Float64[], Float64[]
    for v in verts
        pt = _chat_geo_vertex(v)
        isnothing(pt) && continue
        push!(xs, pt[1]); push!(ys, pt[2]); push!(zs, pt[3])
    end
    (isempty(xs) || isempty(ys) || isempty(zs)) && return nothing

    lx = maximum(xs) - minimum(xs)
    ly = maximum(ys) - minimum(ys)
    lz = maximum(zs) - minimum(zs)
    ar = ly > 1e-6 ? lx / ly : nothing

    result = Dict{String, Any}(
        "footprint_x" => round(lx; digits=2),
        "footprint_y" => round(ly; digits=2),
        "total_height" => round(lz; digits=2),
        "unit" => unit_label,
    )
    !isnothing(ar) && (result["footprint_aspect_ratio"] = round(ar; digits=2))
    return result
end

"""
Generate structural semantic flags and advisory warnings from pre-design geometry.
Flags are terse tokens for programmatic use; warnings are human-readable sentences
the LLM should surface. Warnings are advisory — the user may dismiss them.
"""
function _chat_geo_flags_and_warnings(
    beam_stats_all, beam_stats_x, beam_stats_y,
    story_heights::Vector{Float64}, story_stats,
    panel_analysis,
    column_analysis,
    envelope,
    to_m::Float64, unit_label::String,
)::Tuple{Vector{String}, Vector{String}}
    flags    = String[]
    warnings = String[]

    # ── Beam span flags ──────────────────────────────────────────────────
    if !isnothing(beam_stats_all)
        max_span_m = beam_stats_all["max"] * to_m
        max_span_u = beam_stats_all["max"]

        if max_span_m > 12.2   # ~40 ft
            push!(flags, "very_long_spans")
            push!(warnings,
                "Max beam span $(round(max_span_u; digits=1)) $unit_label " *
                "($(round(max_span_m * 3.28084; digits=1)) ft) is very long for a flat plate/slab system. " *
                "Typical economical flat plate spans are 20–30 ft. Consider reducing column spacing in Grasshopper, " *
                "or switching to a one-way beam-and-slab or steel framing system.")
        elseif max_span_m > 9.1  # ~30 ft
            push!(flags, "long_spans_over_30ft")
            push!(warnings,
                "Max beam span $(round(max_span_u; digits=1)) $unit_label " *
                "($(round(max_span_m * 3.28084; digits=1)) ft) exceeds 30 ft. " *
                "This is at the upper range for flat plate/slab construction — expect thick slabs, " *
                "high self-weight, and potential deflection governance. Review carefully.")
        end

        min_span_m = beam_stats_all["min"] * to_m
        if min_span_m < 1.5  # ~5 ft — suspiciously short
            push!(flags, "very_short_span")
            push!(warnings,
                "Min beam span $(round(beam_stats_all["min"]; digits=1)) $unit_label " *
                "($(round(min_span_m * 3.28084; digits=1)) ft) is unusually short. " *
                "Verify this is intentional and not a modeling artifact in Grasshopper.")
        end

        if beam_stats_all["cv"] > 0.25
            push!(flags, "diverse_beam_edge_lengths")
        end
    end

    # Directional span note (different X vs Y bay sizes are normal, not irregular)
    if !isnothing(beam_stats_x) && !isnothing(beam_stats_y)
        ratio = max(beam_stats_x["mean"], beam_stats_y["mean"]) /
                max(min(beam_stats_x["mean"], beam_stats_y["mean"]), 1e-6)
        if ratio > 2.0
            push!(flags, "large_x_y_span_ratio")
            push!(warnings,
                "Mean X-direction span ($(beam_stats_x["mean"]) $unit_label) and " *
                "Y-direction span ($(beam_stats_y["mean"]) $unit_label) differ by a factor of " *
                "$(round(ratio; digits=1)). This is not necessarily irregular, but two-way slab " *
                "methods assume roughly comparable spans in both directions. For very elongated " *
                "panels, a one-way slab system may be more appropriate.")
        end
    end

    # ── Story height flags ───────────────────────────────────────────────
    if !isempty(story_heights)
        max_h_m = maximum(story_heights) * to_m
        min_h_m = minimum(story_heights) * to_m

        if max_h_m > 6.0  # ~20 ft
            push!(flags, "tall_story_over_6m")
            push!(warnings,
                "Tallest story height $(round(maximum(story_heights); digits=1)) $unit_label " *
                "($(round(max_h_m * 3.28084; digits=1)) ft) is over 20 ft. " *
                "Long unsupported column lengths increase slenderness effects and may require " *
                "larger column sections. Verify this is intended (e.g. lobby, double-height space).")
        end

        if min_h_m < 2.5  # ~8 ft
            push!(flags, "short_story_under_2_5m")
            push!(warnings,
                "Shortest story height $(round(minimum(story_heights); digits=1)) $unit_label " *
                "($(round(min_h_m * 3.28084; digits=1)) ft) is under 8 ft. " *
                "This may not accommodate slab depth plus MEP clearance. " *
                "Verify in Grasshopper — could be a modeling artifact.")
        end

        if length(story_heights) > 1 &&
           maximum(story_heights) - minimum(story_heights) > 0.15 * maximum(story_heights)
            push!(flags, "variable_story_heights")
        end
    end

    # ── Slab panel flags ─────────────────────────────────────────────────
    if !isnothing(panel_analysis)
        cls = get(panel_analysis, "plan_shape_classification", "")
        if cls == "non_orthogonal_or_skewed_quads"
            push!(flags, "non_orthogonal_slab_panel_corners")
            push!(warnings,
                "Slab panels have non-orthogonal corners (mean deviation from 90° > 8°). " *
                "DDM and EFM assume orthogonal grids — consider using FEA method, " *
                "or adjusting geometry to a rectangular grid in Grasshopper.")
        elseif cls == "triangular_mixed_or_complex_panels"
            push!(flags, "mixed_or_triangulated_slab_panels")
            push!(warnings,
                "Slab panels include triangular or complex polygon shapes. " *
                "This requires FEA analysis — DDM and EFM are not applicable. " *
                "Consider simplifying to rectangular panels if using DDM/EFM.")
        elseif cls == "orthogonal_cells_variable_bay_aspect"
            push!(flags, "orthogonal_grid_different_bay_sizes_in_plan")
        end

        ar = get(panel_analysis, "panel_edge_aspect_ratio", nothing)
        if !isnothing(ar)
            max_ar = get(ar, "max", 1.0)
            if max_ar > 2.0
                push!(flags, "high_panel_aspect_ratio")
                if max_ar > 3.0
                    push!(warnings,
                        "Panel aspect ratio up to $(round(max_ar; digits=1)):1. " *
                        "ACI 318 §8.10.2.3 limits DDM to panels with long/short ≤ 2 " *
                        "(EFM is less restrictive but still assumes roughly rectangular bays). " *
                        "Consider using FEA, or adjusting column spacing to reduce aspect ratio.")
                end
            end
        end
    end

    # ── Column grid flags ────────────────────────────────────────────────
    if !isnothing(column_analysis)
        nn = get(column_analysis, "nearest_neighbour_spacing", nothing)
        if !isnothing(nn)
            max_nn_m = nn["max"] * to_m
            min_nn_m = nn["min"] * to_m
            if max_nn_m > 15.0  # ~49 ft
                push!(flags, "wide_column_spacing")
                push!(warnings,
                    "Max nearest-neighbour column spacing is $(nn["max"]) $unit_label " *
                    "($(round(max_nn_m * 3.28084; digits=1)) ft). Some columns are very widely spaced — " *
                    "verify the column grid is complete in Grasshopper.")
            end
            if min_nn_m < 1.5  # ~5 ft — columns suspiciously close
                push!(flags, "very_close_columns")
                push!(warnings,
                    "Min nearest-neighbour column spacing is $(nn["min"]) $unit_label " *
                    "($(round(min_nn_m * 3.28084; digits=1)) ft). Columns may be duplicated or " *
                    "placed too close together — verify in Grasshopper.")
            end
        end
    end

    # ── Envelope sanity ──────────────────────────────────────────────────
    if !isnothing(envelope)
        h_m = get(envelope, "total_height", 0.0) * to_m
        if h_m > 60.0
            push!(flags, "tall_building")
            push!(warnings,
                "Building total height $(envelope["total_height"]) $unit_label " *
                "($(round(h_m * 3.28084; digits=0)) ft) is significant. " *
                "This solver handles gravity only — lateral/seismic analysis is outside scope. " *
                "Ensure lateral system is designed separately.")
        end
    end

    # ── Geometry sanity checks ───────────────────────────────────────────
    # Zero-length edges already filtered by length calcs; duplicate vertices
    # are detectable but expensive for large models — skip for now.

    return (flags, warnings)
end

"""
Enriched geometry statistics computed from raw `building_geometry` JSON.
Provides the LLM with concrete span, height, panel, and column grid data
at chat-opening time — before any POST /design.
"""
function _chat_structured_geometry_stats(g::Dict{String, Any})::Dict{String, Any}
    units_str  = string(get(g, "units", ""))
    to_m       = _chat_geo_unit_to_m(units_str)
    unit_label = _chat_geo_unit_label(units_str)
    verts      = get(g, "vertices", [])
    nv         = verts isa AbstractVector ? length(verts) : 0
    eg         = get(g, "edges", nothing)

    beam_edges   = Any[]
    column_edges = Any[]
    brace_edges  = Any[]
    if eg isa AbstractDict
        b = get(eg, "beams", []);   b isa AbstractVector && (beam_edges = b)
        c = get(eg, "columns", []); c isa AbstractVector && (column_edges = c)
        z = get(eg, "braces", []);  z isa AbstractVector && (brace_edges = z)
    end

    sup = get(g, "supports", [])
    ns  = sup isa AbstractVector ? length(sup) : 0
    sz  = get(g, "stories_z", [])
    nzs = sz isa AbstractVector ? length(sz) : 0

    nfaces = 0
    faces_dict = get(g, "faces", nothing)
    try
        if faces_dict isa AbstractDict
            for (_, polys) in pairs(faces_dict)
                polys isa AbstractVector && (nfaces += length(polys))
            end
        end
    catch; end

    # ── Counts (always present) ──────────────────────────────────────────
    result = Dict{String, Any}(
        "units"                => units_str,
        "n_vertices"           => nv,
        "n_beam_edges"         => length(beam_edges),
        "n_column_edges"       => length(column_edges),
        "n_brace_edges"        => length(brace_edges),
        "n_supports"           => ns,
        "n_stories_z_entries"  => nzs,
        "n_face_polygon_loops" => nfaces,
    )

    # ── Beam span statistics with directional breakdown ──────────────────
    beam_all, beam_x, beam_y = _chat_geo_beam_span_stats(verts, beam_edges, unit_label)
    if !isnothing(beam_all)
        result["beam_spans"] = Dict{String, Any}("all" => beam_all)
        !isnothing(beam_x) && (result["beam_spans"]["x_direction"] = beam_x)
        !isnothing(beam_y) && (result["beam_spans"]["y_direction"] = beam_y)
        result["beam_spans"]["note"] =
            "all mixes X- and Y-oriented members. Different orthogonal bay sizes inflate CV — " *
            "that is normal geometry, not plan irregularity. Use x_direction/y_direction for per-axis spans."
    end

    # ── Column height statistics ─────────────────────────────────────────
    col_lengths = _chat_geo_edge_lengths(verts, column_edges)
    if !isempty(col_lengths)
        result["column_heights"] = Dict{String, Any}(
            "min"  => round(minimum(col_lengths); digits=2),
            "max"  => round(maximum(col_lengths); digits=2),
            "mean" => round(sum(col_lengths) / length(col_lengths); digits=2),
            "n"    => length(col_lengths),
            "unit" => unit_label,
        )
    end

    # ── Story analysis ───────────────────────────────────────────────────
    story_heights_raw, story_stats = _chat_geo_story_analysis(
        sz isa AbstractVector ? sz : [], unit_label,
    )
    if !isnothing(story_stats)
        story_stats["source"] = "stories_z"
        result["stories"] = story_stats
    else
        # Fallback: infer story elevations from unique vertex Z levels when
        # stories_z is omitted by the client payload.
        vz = Float64[]
        for v in verts
            pt = _chat_geo_vertex(v)
            isnothing(pt) && continue
            push!(vz, pt[3])
        end
        if !isempty(vz)
            uniqz = sort(unique(round.(vz; digits=6)))
            result["n_unique_vertex_z"] = length(uniqz)
            inf_heights, inf_stats = _chat_geo_story_analysis(uniqz, unit_label)
            if !isnothing(inf_stats)
                inf_stats["source"] = "inferred_from_vertex_z"
                result["stories"] = inf_stats
                story_heights_raw = inf_heights
            end
        end
    end

    # ── Slab panel analysis ──────────────────────────────────────────────
    panel_analysis = _chat_geo_panel_analysis(faces_dict, unit_label)
    !isnothing(panel_analysis) && (result["slab_panels"] = panel_analysis)

    # ── Column grid analysis ─────────────────────────────────────────────
    col_grid = _chat_geo_column_grid_analysis(verts, column_edges, unit_label)
    !isnothing(col_grid) && (result["column_grid"] = col_grid)

    # ── Building envelope ────────────────────────────────────────────────
    envelope = _chat_geo_envelope(verts, unit_label)
    !isnothing(envelope) && (result["envelope"] = envelope)

    # ── Flags and warnings ───────────────────────────────────────────────
    flags, geo_warnings = _chat_geo_flags_and_warnings(
        beam_all, beam_x, beam_y,
        story_heights_raw, story_stats,
        panel_analysis, col_grid, envelope,
        to_m, unit_label,
    )
    !isempty(flags)       && (result["structural_flags"] = flags)
    !isempty(geo_warnings) && (result["warnings"] = geo_warnings)

    # ── Geometry data coverage (helps LLM avoid vague "missing detail" text) ─
    missing = String[]
    !haskey(result, "beam_spans") && push!(missing, "beam_spans_from_edges.beams")
    !haskey(result, "stories") && push!(missing, "story_heights_from_stories_z_or_vertex_z")
    !haskey(result, "column_heights") && push!(missing, "column_heights_from_edges.columns")
    !haskey(result, "slab_panels") && push!(missing, "slab_panel_shapes_from_faces.floor_or_roof")
    result["data_coverage"] = Dict{String, Any}(
        "missing_items" => missing,
        "has_all_primary_metrics" => isempty(missing),
    )
    result["unit_to_m"] = to_m

    return result
end

"""
Convert geometry stats dict into a concise plaintext digest that the LLM reads before the JSON.
Every critical number appears as a direct sentence — no nesting, no parsing required.
"""
function _geometry_digest_plaintext(stats::Dict{String, Any})::String
    lines = String["── GEOMETRY DIGEST (MANDATORY — quote these numbers directly, NEVER say they are missing) ──"]

    unit = get(stats, "units", "")
    nc = get(stats, "n_column_edges", 0)
    nb = get(stats, "n_beam_edges", 0)
    ns = get(stats, "n_supports", 0)
    nf = get(stats, "n_face_polygon_loops", 0)
    push!(lines, "Elements: $nb beams, $nc columns, $ns supports, $nf slab faces")

    # Beam spans
    bs = get(stats, "beam_spans", nothing)
    if !isnothing(bs)
        all_s = get(bs, "all", nothing)
        if !isnothing(all_s)
            u = get(all_s, "unit", unit)
            push!(lines, "Beam spans (all): min=$(all_s["min"]) $u, max=$(all_s["max"]) $u, mean=$(all_s["mean"]) $u, n=$(all_s["n"])")
        end
        xd = get(bs, "x_direction", nothing)
        if !isnothing(xd)
            u = get(xd, "unit", unit)
            push!(lines, "  X-direction: min=$(xd["min"]) $u, max=$(xd["max"]) $u, mean=$(xd["mean"]) $u")
        end
        yd = get(bs, "y_direction", nothing)
        if !isnothing(yd)
            u = get(yd, "unit", unit)
            push!(lines, "  Y-direction: min=$(yd["min"]) $u, max=$(yd["max"]) $u, mean=$(yd["mean"]) $u")
        end
    else
        push!(lines, "Beam spans: unavailable (no valid edges.beams payload).")
    end

    # Column heights
    ch = get(stats, "column_heights", nothing)
    if !isnothing(ch)
        u = get(ch, "unit", unit)
        push!(lines, "Column heights: min=$(ch["min"]) $u, max=$(ch["max"]) $u, mean=$(ch["mean"]) $u, n=$(ch["n"])")
    end

    # Stories
    st = get(stats, "stories", nothing)
    if !isnothing(st)
        n = get(st, "n_stories", nothing)
        !isnothing(n) && push!(lines, "Stories: $n")
        sh = get(st, "story_heights", nothing)
        if !isnothing(sh) && sh isa AbstractVector && !isempty(sh)
            u = get(st, "unit", unit)
            push!(lines, "Story heights: $(join(sh, ", ")) $u")
        end
        src = get(st, "source", "")
        !isempty(src) && push!(lines, "Story-height source: $src")
    else
        push!(lines, "Stories: unavailable (neither stories_z nor inferable vertex Z levels).")
    end

    # Column grid
    cg = get(stats, "column_grid", nothing)
    if !isnothing(cg)
        n_unique = get(cg, "n_unique_positions", nothing)
        !isnothing(n_unique) && push!(lines, "Column grid: $n_unique unique positions")
        nn = get(cg, "nearest_neighbour_spacing", nothing)
        if !isnothing(nn)
            u = get(nn, "unit", unit)
            push!(lines, "  Nearest-neighbour spacing: min=$(nn["min"]) $u, max=$(nn["max"]) $u")
        end
        edge_int = get(cg, "edge_vs_interior", nothing)
        if !isnothing(edge_int)
            push!(lines, "  Edge columns: $(get(edge_int, "edge", "?")), Interior columns: $(get(edge_int, "interior", "?"))")
        end
    end

    # Slab panels
    sp = get(stats, "slab_panels", nothing)
    if !isnothing(sp)
        cls = get(sp, "plan_shape_classification", "")
        n_panels = get(sp, "n_polygons", 0)
        push!(lines, "Slab panels: $n_panels panels, classification: $cls")
        ar = get(sp, "panel_edge_aspect_ratio", nothing)
        if !isnothing(ar)
            push!(lines, "  Aspect ratio: min=$(get(ar, "min", "?"))  max=$(get(ar, "max", "?"))  mean=$(get(ar, "mean", "?"))")
        end
    else
        push!(lines, "Slab panels: unavailable (faces.floor/roof not provided or empty).")
    end

    # Envelope
    env = get(stats, "envelope", nothing)
    if !isnothing(env)
        u = get(env, "unit", unit)
        fp = get(env, "footprint_dim", nothing)
        h = get(env, "total_height", nothing)
        if !isnothing(fp)
            push!(lines, "Footprint: $(fp["x"]) × $(fp["y"]) $u")
        end
        !isnothing(h) && push!(lines, "Total height: $h $u")
    end

    # Economical ranges from GEOMETRIC_SENSITIVITY_MAP
    span_ranges = get(get(GEOMETRIC_SENSITIVITY_MAP, "span_length", Dict()), "typical_economical_ranges", nothing)
    story_ranges = get(get(GEOMETRIC_SENSITIVITY_MAP, "story_height", Dict()), "typical_economical_ranges", nothing)
    if !isnothing(span_ranges)
        bs_all = get(get(stats, "beam_spans", Dict()), "all", nothing)
        if !isnothing(bs_all)
            max_span_m = get(bs_all, "max", 0.0)
            # Convert to meters if needed for comparison
            to_m = get(stats, "unit_to_m", 1.0)
            max_m = max_span_m * to_m
            if max_m > 9.1
                push!(lines, "⚡ Economical span ranges: " * join(["$k: $v" for (k, v) in span_ranges], "; "))
            end
        end
    end
    if !isnothing(story_ranges)
        story_data = get(stats, "stories", nothing)
        if !isnothing(story_data)
            sh = get(story_data, "story_heights", nothing)
            if !isnothing(sh) && sh isa AbstractVector && !isempty(sh)
                to_m = get(stats, "unit_to_m", 1.0)
                max_h = maximum(sh) * to_m
                if max_h > 4.5
                    push!(lines, "⚡ Economical story height ranges: " * join(["$k: $v" for (k, v) in story_ranges], "; "))
                end
            end
        end
    end

    # Flags
    flags = get(stats, "structural_flags", nothing)
    if !isnothing(flags) && !isempty(flags)
        push!(lines, "Structural flags: $(join(flags, ", "))")
    end

    cov = get(stats, "data_coverage", nothing)
    if cov isa AbstractDict
        missing = get(cov, "missing_items", String[])
        if missing isa AbstractVector && !isempty(missing)
            push!(lines, "Data gaps: $(join(string.(missing), ", ")).")
        else
            push!(lines, "Data coverage: complete for primary geometry metrics.")
        end
    end

    push!(lines, "── END DIGEST ──")
    return join(lines, "\n") * "\n"
end

"""
Append structured design geometry JSON and/or the optional human Summary line to the system prompt.

Prefers a **structure-based digest** (from `BuildingStructure` → `initialize!`) which provides
real cell spans, slab panels, member lengths, column tributary areas, and grid regularity analysis.
Falls back to the raw-JSON `_chat_structured_geometry_stats` approach if initialization fails.
"""
function _append_chat_building_geometry_sections!(
    parts::Vector,
    geometry_summary::String,
    structured::Union{Nothing, Dict{String, Any}},
)
    if !isnothing(structured)
        # Try the structure-based path first (real structural data)
        struc_digest = _chat_get_structure_digest(structured)

        if !isnothing(struc_digest)
            @info "Chat geometry: structure-based digest OK" n_cells=get(struc_digest, "n_cells", 0) n_beams=get(struc_digest, "n_beams", 0)
            push!(parts, "\n\nBUILDING GEOMETRY (structure-initialized — cells, members, tributaries computed):\n")
            push!(parts, _structure_digest_plaintext(struc_digest))

            warnings = get(struc_digest, "warnings", nothing)
            if !isnothing(warnings) && !isempty(warnings)
                push!(parts, "\n⚠ GEOMETRY WARNINGS:\n")
                for w in warnings
                    push!(parts, "  • ", w, "\n")
                end
            end

            push!(parts, "\nFull structure analysis JSON: ", JSON3.write(struc_digest), "\n")
        else
            @warn "Chat geometry: structure-based digest FAILED — using raw JSON fallback"
            stats = _chat_structured_geometry_stats(structured)
            json_txt = JSON3.write(structured)
            push!(parts, "\n\nBUILDING GEOMETRY (raw JSON analysis — structure init failed, using geometric approximation):\n")
            push!(parts, _geometry_digest_plaintext(stats))

            if haskey(stats, "warnings") && !isempty(stats["warnings"])
                push!(parts, "\n⚠ GEOMETRY WARNINGS (address these in your opening analysis — they are advisory, not blocking):\n")
                for w in stats["warnings"]
                    push!(parts, "  • ", w, "\n")
                end
            end

            push!(parts, "\nFull geometry analysis JSON (detail behind the digest above): ", JSON3.write(stats), "\n")
            if length(json_txt) > _MAX_CHAT_BUILDING_GEOMETRY_JSON_CHARS
                push!(parts, "Full geometry JSON omitted (length ", string(length(json_txt)), " chars > limit ", string(_MAX_CHAT_BUILDING_GEOMETRY_JSON_CHARS), "). Use the counts above, the narrative summary if present, or run Design so the server caches the structure.\n")
            else
                push!(parts, "Full geometry JSON:\n", json_txt, "\n")
            end
        end
    end
    if !isempty(strip(geometry_summary))
        label = isnothing(structured) ? "BUILDING GEOMETRY" : "BUILDING GEOMETRY (narrative summary — same model as structured block above when both are present)"
        push!(parts, "\n\n", label, ":\n", geometry_summary)
    end
    return nothing
end

"""
    _api_input_geometry_only_from_chat_dict(g) -> APIInput

Build an `APIInput` from chat `building_geometry` dict using default `params`, for hashing only.
Matches the geometry slice of POST /design / Grasshopper `BuildingGeometry.ToJson()`.
"""
function _api_input_geometry_only_from_chat_dict(g::Dict{String, Any})::APIInput
    edges_in = get(g, "edges", nothing)
    edges_blob = if edges_in isa AbstractDict
        Dict{String, Any}(
            "beams"   => collect(Any, get(edges_in, "beams", [])),
            "columns" => collect(Any, get(edges_in, "columns", [])),
            "braces"  => collect(Any, get(edges_in, "braces", [])),
        )
    else
        Dict{String, Any}("beams" => Any[], "columns" => Any[], "braces" => Any[])
    end
    faces_in = get(g, "faces", nothing)
    faces_blob = if faces_in isa AbstractDict
        Dict{String, Any}(string(k) => v for (k, v) in pairs(faces_in))
    else
        Dict{String, Any}()
    end
    blob = Dict{String, Any}(
        "units"      => string(get(g, "units", "feet")),
        "vertices"   => get(g, "vertices", Any[]),
        "edges"      => edges_blob,
        "supports"   => get(g, "supports", Any[]),
        "stories_z"  => get(g, "stories_z", Any[]),
        "faces"      => faces_blob,
        "params"     => Dict{String, Any}(),
    )
    return JSON3.read(JSON3.write(blob), APIInput)
end

"""SHA-256 geometry hash for chat `building_geometry`, or `nothing` if parsing fails."""
function _try_geometry_hash_from_chat_dict(g::Dict{String, Any})::Union{Nothing, String}
    try
        return compute_geometry_hash(_api_input_geometry_only_from_chat_dict(g))
    catch
        return nothing
    end
end

"""
Resolve which geometry fingerprint to compare to the server: prefer hash derived from structured
`building_geometry` when available; otherwise `client_geometry_hash`.
Returns `(resolved_hash_or_nothing, source, derived_or_nothing)` where `derived_or_nothing` is
the hash from structured JSON when that was attempted (even if resolution fell back to client).
"""
function _chat_geometry_resolution(
    structured::Union{Nothing, Dict{String, Any}},
    client_geometry_hash::String,
)::Tuple{Union{Nothing, String}, String, Union{Nothing, String}}
    derived::Union{Nothing, String} = nothing
    if !isnothing(structured)
        derived = _try_geometry_hash_from_chat_dict(structured)
        if !isnothing(derived) && !isempty(derived)
            return (derived, "building_geometry", derived)
        end
    end
    ch = strip(client_geometry_hash)
    !isempty(ch) && return (ch, "client_geometry_hash", derived)
    return (nothing, "none", derived)
end

"""Read the server-cached geometry hash under lock."""
function _server_geometry_hash()::String
    with_cache_read(c -> c.geometry_hash, DESIGN_CACHE)
end

"""True when chat-resolved geometry (body or client hash) disagrees with the server's last POST /design hash."""
function _geometry_prompt_stale(
    resolved::Union{Nothing, String},
    client_geometry_hash::String,
)::Bool
    srv = strip(_server_geometry_hash())
    isempty(srv) && return false
    if !isnothing(resolved) && !isempty(resolved)
        return resolved != srv
    end
    return _geometry_stale_for_client(client_geometry_hash)
end

"""True when client hash is present and differs from the server's cached POST /design geometry."""
function _geometry_stale_for_client(client_geometry_hash::String)::Bool
    cli = strip(client_geometry_hash)
    srv = strip(_server_geometry_hash())
    !isempty(cli) && !isempty(srv) && cli != srv
end

"""Merge geometry alignment fields into tool JSON for the LLM (optional client_geometry_hash in args)."""
function _attach_geometry_alignment!(result::Dict{String, Any}, args::Dict{String, Any})
    cli = strip(string(get(args, "client_geometry_hash", "")))
    isempty(cli) && return result
    srv = strip(_server_geometry_hash())
    result["client_geometry_hash"] = cli
    result["server_cached_geometry_hash"] = srv
    result["geometry_stale"] = !isempty(srv) && cli != srv
    return result
end

function _build_system_prompt(
    mode::String,
    params_json,
    geometry_summary::String,
    client_geometry_hash::String = "",
    structured_geometry::Union{Nothing, Dict{String, Any}} = nothing;
    max_tokens::Int = MAX_CONTEXT_TOKENS,
)
    resolved_h, res_src, derived_h = _chat_geometry_resolution(structured_geometry, client_geometry_hash)
    stale = _geometry_prompt_stale(resolved_h, client_geometry_hash)
    srv = strip(_server_geometry_hash())
    aligned = if isempty(srv) || isnothing(resolved_h) || isempty(resolved_h)
        "unknown"
    elseif resolved_h == srv
        "yes"
    else
        "no"
    end
    derived_str = isnothing(derived_h) ? "" : derived_h
    resolved_str = isnothing(resolved_h) ? "" : resolved_h
    geo_ctx = Dict{String, Any}(
        "server_cached_geometry_hash"           => srv,
        "client_geometry_hash"                    => strip(client_geometry_hash),
        "derived_from_building_geometry_hash"   => derived_str,
        "resolved_chat_geometry_hash"           => resolved_str,
        "resolved_source"                       => res_src,
        "aligned_with_server"                   => aligned,
        "geometry_stale"                        => stale,
    )
    geo_ctx_block = string("\n\nGEOMETRY_CONTEXT (authoritative for this turn — compare to BUILDING GEOMETRY below):\n", JSON3.write(geo_ctx), "\n")

    stale_note = if stale
        cli = strip(client_geometry_hash)
        res_show = !isempty(resolved_str) ? resolved_str : cli
        how = res_src == "building_geometry" ? "derived from structured building_geometry (same hash as POST /design geometry)" :
              res_src == "client_geometry_hash" ? "from client_geometry_hash" :
              "could not fully resolve from body; stale detection used client_geometry_hash fallback if present"
        """

GEOMETRY / CACHE MISMATCH:
  Prompt geometry ($how): $res_show
  Server cache (last POST /design): $srv
  These differ — cached results are OMITTED because they describe a different model.
  Do NOT invent ratios, pass/fail, or EC for the current geometry. Tell the user to run Design from Grasshopper.
  You may give mechanism-level expectations (qualitative) for how the design problem shifts, and discuss past runs via get_design_history.
"""
    else
        ""
    end

    sys_budget_tokens = round(Int, max_tokens * _SYSTEM_PROMPT_BUDGET_FRACTION)

    has_geometry_in_prompt = !isnothing(structured_geometry) || !isempty(strip(geometry_summary))

    if mode == "design"
        parts = [_DESIGN_SYSTEM_PREAMBLE, geo_ctx_block]
        !isempty(stale_note) && push!(parts, stale_note)

        # Context-dependent opening analysis for design mode (first turn only)
        cached_design = _get_last_design()
        if isnothing(cached_design) && has_geometry_in_prompt
            push!(parts, """

OPENING ANALYSIS (first response — no design yet):
  Prove you read THIS geometry. Lead with structural observations, not generic questions.

  1. GEOMETRY — quote exact spans, column count, story heights, aspect ratios from the digest.
  2. IMPLICATIONS — what governs: long spans → punching shear, high aspect ratio → DDM concern, tall stories → slenderness.
  3. PARAMETERS — recommend floor_type, column_type, method, optimize_for ONLY from the PARAMETER SPACE card. Tie each to a digest number. If spans exceed ~30 ft for flat_plate, recommend adding columns in Grasshopper or switching to one_way — never systems outside the card.
  4. WARNINGS — surface digest warnings with severity.
  5. QUESTIONS — only what the digest cannot answer (occupancy, fire rating, preferences).

  If geometry seems missing, call get_geometry_digest first.
""")
        end

        _append_chat_building_geometry_sections!(parts, geometry_summary, structured_geometry)
        if !isnothing(params_json) && !isempty(string(params_json))
            push!(parts, "\n\nCURRENT PARAMETERS:\n", JSON3.write(params_json))
        end
        if !stale && !isnothing(cached_design)
            push!(parts, "\n\nLATEST RESULTS SUMMARY (you may quote these numbers — they are authoritative):\n", condense_result(cached_design))
            push!(parts, "\nFor derived metrics not shown above, call the relevant tool. NEVER fabricate numbers.\n")
        end
        return _trim_system_prompt(parts, sys_budget_tokens)
    elseif mode == "results"
        parts = [_RESULTS_SYSTEM_PREAMBLE, geo_ctx_block]
        !isempty(stale_note) && push!(parts, stale_note)

        # Context-dependent opening analysis for results mode
        push!(parts, """

OPENING ANALYSIS (results exist):
  Lead with the critical failure mode for THIS geometry. Call get_diagnose_summary immediately.

  Example tone: "Punching shear governs at 4 of 9 interior columns (worst ratio 1.34 at col 5). With 28 ft spans and 12 in columns, the critical perimeter b₀ is too short. Most reliable fix: grow_columns to increase b₀ directly (e.g. test 16 in via run_experiment). reinforce_first adds shear studs but does NOT grow columns — columns may stay at P-M minimum. Higher f'c increases Vc in isolation but the sizer may pick smaller columns, net-worsening punching — always verify with an experiment."

  If parameter_headroom="exhausted" → recommend geometry changes first via suggest_next_action.
""")

        cached_design = _get_last_design()
        if !stale && !isnothing(cached_design)
            push!(parts, "\n\nCACHED DESIGN SUMMARY (you may quote these numbers directly — they are authoritative):\n")
            push!(parts, condense_result(cached_design))
            push!(parts, "\nFor derived metrics (e.g. EC intensity = EC / floor_area), call get_geometry_digest for the area. NEVER compute area by hand or from memory.\n")
            push!(parts, "\n\nDETAILED RESULTS:\n", JSON3.write(report_summary_json(cached_design)))
        end
        _append_chat_building_geometry_sections!(parts, geometry_summary, structured_geometry)
        if !isnothing(params_json) && !isempty(string(params_json))
            push!(parts, "\n\nDESIGN PARAMETERS:\n", JSON3.write(params_json))
        end
        return _trim_system_prompt(parts, sys_budget_tokens)
    else
        return "You are a helpful structural engineering assistant."
    end
end

"""
    _trim_system_prompt(parts::Vector, budget_tokens::Int) -> String

Join prompt `parts`, then progressively strip lower-priority content if the
result exceeds `budget_tokens`.  Trimming order (least → most important):

1. Full structure analysis JSON  (`Full structure analysis JSON:`)
2. Full geometry JSON blob       (`Full geometry JSON:`)
3. Detailed results JSON         (`DETAILED RESULTS:`)
4. Full geometry analysis JSON   (`Full geometry analysis JSON`)

The plain-text digest, warnings, condensed results summary, and preamble are
never trimmed — the LLM needs those for reasoning.
"""
function _trim_system_prompt(parts::Vector, budget_tokens::Int)::String
    prompt = join(parts)
    tok = _estimate_tokens(prompt)
    tok <= budget_tokens && return prompt

    # Each pattern: (regex for the section, replacement note).
    # Ordered from least to most important for reasoning.
    trim_stages = [
        (r"Full structure analysis JSON: [\s\S]*?(?=\n\n[A-Z]|\z)"s,
         "[Structure analysis JSON trimmed — plain-text digest above is authoritative]\n"),
        (r"Full geometry JSON:\n[\s\S]*?(?=\n\n[A-Z]|\z)"s,
         "[Full geometry JSON trimmed to fit context — use design tools for detail]\n"),
        (r"DETAILED RESULTS:\n[\s\S]*?(?=\n\n[A-Z]|\z)"s,
         "DETAILED RESULTS: [trimmed to fit context — use get_result_summary or get_condensed_result]\n"),
        (r"Full geometry analysis JSON \(detail behind the digest above\): [\s\S]*?(?=\n\n[A-Z]|\z)"s,
         "[Geometry analysis JSON trimmed — digest and warnings above are authoritative]\n"),
    ]

    for (pattern, replacement) in trim_stages
        prompt = replace(prompt, pattern => replacement)
        tok = _estimate_tokens(prompt)
        if tok <= budget_tokens
            @info "System prompt trimmed to fit budget" tokens=tok budget=budget_tokens
            return prompt
        end
    end

    @warn "System prompt still exceeds budget after all trims" tokens=tok budget=budget_tokens
    return prompt
end

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
claims (ratios, percentages near pass/fail language, utilization values) that
should have been grounded in tool evidence.
"""
function _contains_numerical_claims(text::AbstractString)::Bool
    isempty(text) && return false
    # Ratio patterns: "0.85", "1.02", percentage patterns near structural language
    has_ratio = occursin(r"(?:ratio|utilization|DCR)\s*(?:of|=|is|:)\s*\d+\.\d+"i, text)
    has_pct = occursin(r"\d{1,3}(?:\.\d+)?%\s*(?:utilization|capacity|overloaded|stressed)"i, text)
    has_passfail_number = occursin(r"(?:pass|fail|exceed|violat)\w*\s+(?:at|with|by)\s+\d+\.\d+"i, text)
    has_specific_value = occursin(r"(?:φ[PVM]n|ϕ[PVM]n|Vu|Mu|Pu)\s*(?:=|of|is)\s*[\d,]+\.?\d*\s*(?:kip|kN|psi|ksi|MPa)"i, text)
    return has_ratio || has_pct || has_passfail_number || has_specific_value
end

"""
    _extract_params_patch(text) -> Union{Dict{String,Any}, Nothing}

Extract a JSON code block from the assistant text that looks like a parameter
patch (contains at least one known API param key or a `_history_label`).
Returns the parsed dict with validation info, or `nothing` if no patch found.
"""
function _extract_params_patch(text::String)::Union{Dict{String, Any}, Nothing}
    isempty(text) && return nothing
    m = match(r"```json\s*\n([\s\S]*?)\n\s*```"i, text)
    isnothing(m) && return nothing
    json_str = strip(m.captures[1])
    isempty(json_str) && return nothing

    local parsed
    try
        parsed = Dict{String, Any}(string(k) => v for (k, v) in JSON3.read(json_str))
    catch
        return nothing
    end
    isempty(parsed) && return nothing

    api_keys, geo_hints, _ = _classify_patch(parsed)
    (isempty(api_keys) && !haskey(parsed, "_history_label")) && return nothing

    history_label = pop!(parsed, "_history_label", nothing)
    clean_patch = Dict{String, Any}(k => v for (k, v) in parsed if lowercase(k) in _API_PARAM_KEYS)
    isempty(clean_patch) && return nothing

    validation = _validate_params_patch(clean_patch)
    result = Dict{String, Any}(
        "patch"      => clean_patch,
        "valid"      => get(validation, "ok", false),
        "violations" => get(validation, "violations", []),
        "warnings"   => get(validation, "warnings", []),
    )
    if !isempty(geo_hints)
        result["geometric_hints"] = geo_hints
    end
    if !isnothing(history_label)
        result["history_label"] = string(history_label)
    end
    return result
end

"""
    _build_turn_summary(; suggestions, clarification_data, tool_actions, params_patch) -> Dict

Canonical turn-summary event.  Guarantees `suggested_next_questions` is always
present (empty array when absent) and `clarification_prompt` is either a valid
dict or `nothing`.  `tool_actions` is an optional array of tool-action records.
When `params_patch` is present, includes validated parameter changes for the
client's "Apply & Run" button.
"""
function _build_turn_summary(;
    suggestions::Vector{String}         = String[],
    clarification_data                  = nothing,
    tool_actions::Vector{Dict{String,Any}} = Dict{String,Any}[],
    params_patch::Union{Dict{String,Any}, Nothing} = nothing,
)::Dict{String, Any}
    summary = Dict{String, Any}(
        "type"                     => "agent_turn_summary",
        "suggested_next_questions" => suggestions,
        "clarification_prompt"     => _normalize_clarification(clarification_data),
    )
    if !isempty(tool_actions)
        summary["tool_actions"] = tool_actions
    end
    if !isnothing(params_patch)
        summary["params_patch"] = params_patch
    end
    return summary
end

# ─── LLM streaming client ────────────────────────────────────────────────────

const MAX_AGENT_TOOL_ROUNDS = 8

"""
    _emit_text_chunked(sse_stream, text; chunk_chars=80)

Emit pre-generated text to the SSE stream in small chunks so the client
receives incremental `token` events rather than one monolithic blob.
Chunks at whitespace boundaries near `chunk_chars` characters.
"""
function _emit_text_chunked(sse_stream::HTTP.Stream, text::String; chunk_chars::Int=80)
    isempty(text) && return
    pos = 1
    n = length(text)
    while pos <= n
        stop = min(pos + chunk_chars - 1, n)
        if stop < n
            sp = findprev(' ', text, stop)
            if !isnothing(sp) && sp >= pos
                stop = sp
            end
        end
        chunk = text[pos:stop]
        write(sse_stream, "data: $(JSON3.write(Dict("token" => chunk)))\n\n")
        pos = stop + 1
    end
end

"""Read dictionary values by string/symbol key with fallback."""
function _dict_get(d, key::String, default=nothing)
    if d isa AbstractDict
        haskey(d, key) && return d[key]
        sym = Symbol(key)
        haskey(d, sym) && return d[sym]
    end
    return default
end

"""Best-effort Integer coercion for tool args."""
function _chat_coerce_int(x)::Union{Int, Nothing}
    isnothing(x) && return nothing
    x isa Integer && return Int(x)
    if x isa Real
        return isinteger(x) ? Int(x) : nothing
    elseif x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        return tryparse(Int, s)
    end
    return nothing
end

"""Best-effort Float64 coercion for tool args."""
function _chat_coerce_float(x)::Union{Float64, Nothing}
    isnothing(x) && return nothing
    x isa Real && return Float64(x)
    if x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        return tryparse(Float64, replace(s, "," => ""))
    end
    return nothing
end

"""Best-effort Bool coercion for tool args."""
function _chat_coerce_bool(x)::Union{Bool, Nothing}
    isnothing(x) && return nothing
    x isa Bool && return x
    if x isa Integer
        x == 1 && return true
        x == 0 && return false
        return nothing
    elseif x isa AbstractString
        s = lowercase(strip(x))
        s in ("true", "t", "yes", "y", "1") && return true
        s in ("false", "f", "no", "n", "0") && return false
        return nothing
    end
    return nothing
end

"""
    _json_schema_from_tool_arg(desc) -> Dict{String, Any}

Convert one tool-arg descriptor from `TOOL_REGISTRY` into an OpenAI tool JSON schema.
"""
function _json_schema_from_tool_arg(desc::AbstractDict)::Dict{String, Any}
    d = Dict{String, Any}(string(k) => v for (k, v) in desc)
    t = lowercase(string(get(d, "type", "string")))
    base_type = if startswith(t, "integer")
        "integer"
    elseif startswith(t, "number")
        "number"
    elseif startswith(t, "boolean")
        "boolean"
    elseif startswith(t, "array")
        "array"
    elseif startswith(t, "object")
        "object"
    else
        "string"
    end

    schema = Dict{String, Any}("type" => base_type)
    haskey(d, "description") && (schema["description"] = string(d["description"]))
    haskey(d, "enum") && (schema["enum"] = collect(d["enum"]))

    if base_type == "array"
        items_desc = get(d, "items", nothing)
        if items_desc isa AbstractDict
            schema["items"] = _json_schema_from_tool_arg(Dict{String, Any}(string(k) => v for (k, v) in items_desc))
        elseif !haskey(schema, "items")
            schema["items"] = Dict{String, Any}("type" => "string")
        end
    end

    if base_type == "object"
        fields = get(d, "fields", Dict{String, Any}())
        if fields isa AbstractDict && !isempty(fields)
            props = Dict{String, Any}()
            req = String[]
            for (fk, fv) in fields
                if fv isa AbstractDict
                    fdesc = Dict{String, Any}(string(k) => v for (k, v) in fv)
                    props[string(fk)] = _json_schema_from_tool_arg(fdesc)
                    Bool(get(fdesc, "required", false)) && push!(req, string(fk))
                else
                    props[string(fk)] = Dict{String, Any}("type" => "string")
                end
            end
            schema["properties"] = props
            schema["additionalProperties"] = false
            !isempty(req) && (schema["required"] = req)
        end
    end
    return schema
end

"""
    _openai_tool_specs() -> Vector{Dict{String, Any}}

Build OpenAI tool-function specs from the backend tool registry.
"""
function _openai_tool_specs()::Vector{Dict{String, Any}}
    specs = Dict{String, Any}[]
    for entry in api_tool_schema()
        name = string(get(entry, "name", ""))
        isempty(name) && continue

        # Build a rich description from registry fields: description + use_when + returns.
        # The OpenAI tools payload only has a single `description` string, so we merge
        # the registry's separate fields here so the LLM sees when/why to call each tool.
        desc_parts = String[string(get(entry, "description", ""))]
        use_when = get(entry, "use_when", nothing)
        !isnothing(use_when) && !isempty(string(use_when)) && push!(desc_parts, "USE WHEN: " * string(use_when))
        returns = get(entry, "returns", nothing)
        !isnothing(returns) && !isempty(string(returns)) && push!(desc_parts, "RETURNS: " * string(returns))
        desc = join(desc_parts, " | ")

        args = get(entry, "args", Dict{String, Any}())

        params = Dict{String, Any}(
            "type" => "object",
            "properties" => Dict{String, Any}(),
            "additionalProperties" => false,
        )
        required = String[]
        if args isa AbstractDict
            for (arg_name, arg_desc) in args
                if arg_desc isa AbstractDict
                    d = Dict{String, Any}(string(k) => v for (k, v) in arg_desc)
                    params["properties"][string(arg_name)] = _json_schema_from_tool_arg(d)
                    Bool(get(d, "required", false)) && push!(required, string(arg_name))
                else
                    params["properties"][string(arg_name)] = Dict{String, Any}("type" => "string")
                end
            end
        end
        !isempty(required) && (params["required"] = required)

        push!(specs, Dict{String, Any}(
            "type" => "function",
            "function" => Dict{String, Any}(
                "name" => name,
                "description" => desc,
                "parameters" => params,
            ),
        ))
    end
    return specs
end

"""Normalize assistant message content into plain text."""
function _coerce_message_content(raw)::String
    isnothing(raw) && return ""
    raw isa AbstractString && return string(raw)
    if raw isa AbstractVector
        parts = String[]
        for item in raw
            if item isa AbstractDict
                txt = _dict_get(item, "text", nothing)
                !isnothing(txt) && push!(parts, string(txt))
            else
                push!(parts, string(item))
            end
        end
        return join(parts)
    end
    return string(raw)
end

"""
    _parse_tool_args(args_json) -> Union{Dict{String, Any}, Nothing}

Parse a JSON argument blob from OpenAI tool-calls into a mutable Dict.
"""
function _parse_tool_args(args_json::String)::Union{Dict{String, Any}, Nothing}
    s = strip(args_json)
    isempty(s) && return Dict{String, Any}()
    try
        raw = JSON3.read(s)
        raw isa AbstractDict || return nothing
        return Dict{String, Any}(string(k) => v for (k, v) in raw)
    catch
        return nothing
    end
end

"""Compact one-line summary of tool execution result for turn-summary telemetry."""
function _tool_action_summary(result::Dict{String, Any})::String
    haskey(result, "message") && return string(result["message"])[1:min(end, 240)]
    haskey(result, "note") && return string(result["note"])[1:min(end, 240)]
    if haskey(result, "error")
        return "error: " * string(result["error"])[1:min(end, 180)]
    end
    if haskey(result, "ok")
        return Bool(result["ok"]) ? "ok" : "not_ok"
    end
    return "completed"
end

"""
    _stream_llm_to_sse(stream, system_prompt, messages; session_id="")

Call the OpenAI-compatible chat completions endpoint and forward response text
as SSE token events.

If the model emits tool calls, execute them server-side via `_dispatch_chat_tool`,
append tool results to the chat context, and continue until a final assistant
message is produced (or `MAX_AGENT_TOOL_ROUNDS` is reached).
"""
function _stream_llm_to_sse(
    stream::HTTP.Stream,
    system_prompt::String,
    messages::Vector;
    session_id::String = "",
    client_geometry_hash::String = "",
)
    base_url = _chat_llm_base_url()
    api_key  = _chat_llm_api_key()
    model    = _chat_llm_model()

    url = rstrip(base_url, '/') * "/v1/chat/completions"

    conversation = vcat(
        [Dict("role" => "system", "content" => system_prompt)],
        messages,
    )
    tools = _openai_tool_specs()

    headers = [
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer $api_key",
    ]

    full_text = ""
    tool_actions = Dict{String, Any}[]

    try
        # Not `round` — that name shadows `Base.round` and breaks `round(Int, x)` below.
        for tool_round in 1:MAX_AGENT_TOOL_ROUNDS
            payload = Dict{String, Any}(
                "model" => model,
                "messages" => conversation,
                "stream" => false,
            )
            if !isempty(tools)
                payload["tools"] = tools
                payload["tool_choice"] = "auto"
                payload["parallel_tool_calls"] = false
            end

            r = HTTP.post(
                url,
                headers,
                JSON3.write(payload);
                connect_timeout=10,
                readtimeout=120,
                status_exception=false,
                cookies=false,
            )

            if r.status >= 400
                err_body = String(r.body)
                err_preview = err_body[1:min(end, 500)]
                throw(ErrorException("OpenAI returned HTTP $(r.status): $(err_preview)"))
            end

            resp = JSON3.read(String(r.body))
            choices = get(resp, :choices, nothing)
            (isnothing(choices) || isempty(choices)) && throw(ErrorException("OpenAI response missing choices."))
            msg = get(choices[1], :message, nothing)
            isnothing(msg) && throw(ErrorException("OpenAI response missing message payload."))

            assistant_content = _coerce_message_content(get(msg, :content, nothing))
            tool_calls_raw = get(msg, :tool_calls, nothing)

            if tool_calls_raw isa AbstractVector && !isempty(tool_calls_raw)
                assistant_tool_calls = Dict{String, Any}[]
                tool_results = Dict{String, Any}[]

                for (i, tc) in enumerate(tool_calls_raw)
                    fn_obj = _dict_get(tc, "function", Dict{String, Any}())
                    tool_name = string(_dict_get(fn_obj, "name", ""))
                    args_json = string(_dict_get(fn_obj, "arguments", "{}"))
                    call_id = string(_dict_get(tc, "id", "call_$(tool_round)_$(i)"))
                    isempty(call_id) && (call_id = "call_$(tool_round)_$(i)")

                    push!(assistant_tool_calls, Dict{String, Any}(
                        "id" => call_id,
                        "type" => "function",
                        "function" => Dict{String, Any}(
                            "name" => tool_name,
                            "arguments" => args_json,
                        ),
                    ))

                    # Emit tool-start progress event so the client can show live status.
                    write(stream, "data: $(JSON3.write(Dict{String,Any}(
                        "tool_progress" => Dict{String,Any}(
                            "tool"   => tool_name,
                            "label"  => get(_TOOL_DISPLAY_LABELS, tool_name, tool_name),
                            "status" => "running",
                            "round"  => tool_round,
                            "index"  => i,
                        ),
                    )))\n\n")

                    t0 = time()
                    args_dict = _parse_tool_args(args_json)
                    result = if isnothing(args_dict)
                        Dict{String, Any}(
                            "error" => "tool_args_parse_failed",
                            "message" => "Could not parse tool arguments as JSON.",
                            "tool" => tool_name,
                            "raw_arguments" => args_json,
                        )
                    else
                        if !isempty(client_geometry_hash)
                            args_dict["client_geometry_hash"] = client_geometry_hash
                        end
                        try
                            _dispatch_chat_tool(tool_name, args_dict)
                        catch e
                            @error "Chat tool execution failed" tool=tool_name exception=(e, catch_backtrace())
                            Dict{String, Any}(
                                "error" => "tool_execution_failed",
                                "tool" => tool_name,
                                "message" => sprint(showerror, e),
                                "recovery_hint" => "Retry this tool call; if it persists, run GET /status and share this error.",
                            )
                        end
                    end
                    if !isnothing(args_dict)
                        _attach_geometry_alignment!(result, args_dict)
                    elseif !isempty(client_geometry_hash)
                        _attach_geometry_alignment!(result, Dict{String, Any}("client_geometry_hash" => client_geometry_hash))
                    end
                    elapsed_ms = round(Int, (time() - t0) * 1000)
                    tool_status = haskey(result, "error") ? "error" : "ok"

                    # Emit tool-done progress event.
                    write(stream, "data: $(JSON3.write(Dict{String,Any}(
                        "tool_progress" => Dict{String,Any}(
                            "tool"       => tool_name,
                            "label"      => get(_TOOL_DISPLAY_LABELS, tool_name, tool_name),
                            "status"     => tool_status,
                            "round"      => tool_round,
                            "index"      => i,
                            "elapsed_ms" => elapsed_ms,
                        ),
                    )))\n\n")

                    push!(tool_actions, Dict{String, Any}(
                        "tool" => tool_name,
                        "status" => tool_status,
                        "elapsed_ms" => elapsed_ms,
                        "summary" => _tool_action_summary(result),
                    ))

                    result_json = JSON3.write(result)
                    result_json = _truncate_tool_result(result_json)
                    push!(tool_results, Dict{String, Any}(
                        "role" => "tool",
                        "tool_call_id" => call_id,
                        "content" => result_json,
                    ))
                end

                push!(conversation, Dict{String, Any}(
                    "role" => "assistant",
                    "content" => assistant_content,
                    "tool_calls" => assistant_tool_calls,
                ))
                append!(conversation, tool_results)

                # Mid-conversation context budget check: compress old tool
                # results if accumulated conversation is getting large.
                _compact_conversation!(conversation, system_prompt, MAX_CONTEXT_TOKENS)

                continue
            end

            full_text = assistant_content
            break
        end

        # The model may exhaust tool rounds or keep emitting tool calls without a final text turn.
        # Request one non-tool completion that summarizes tool results so the user always gets prose.
        if isempty(full_text) && !isempty(tool_actions)
            synth_conv = copy(conversation)
            push!(synth_conv, Dict{String, Any}(
                "role" => "user",
                "content" =>
                    "Summarize the tool results above for the user in complete sentences. " *
                    "If any tool returned an error, explain it and suggest recovery. " *
                    "If compare_designs or two run_design results are needed for a 'difference', say what is still missing. " *
                    "Do not call tools.",
            ))
            synth_payload = Dict{String, Any}(
                "model" => model,
                "messages" => synth_conv,
                "stream" => false,
            )
            try
                rs = HTTP.post(
                    url,
                    headers,
                    JSON3.write(synth_payload);
                    connect_timeout=10,
                    readtimeout=120,
                    status_exception=false,
                    cookies=false,
                )
                if rs.status < 400
                    resp2 = JSON3.read(String(rs.body))
                    choices2 = get(resp2, :choices, nothing)
                    if choices2 isa AbstractVector && !isempty(choices2)
                        msg2 = get(choices2[1], :message, nothing)
                        if !isnothing(msg2)
                            full_text = _coerce_message_content(get(msg2, :content, nothing))
                        end
                    end
                end
            catch e
                @warn "Chat synthesis pass failed" exception=(e,)
            end
        end

        if isempty(full_text) && !isempty(tool_actions)
            n_actions = length(tool_actions)
            tool_names = join(unique(string(get(a, "tool", "?")) for a in tool_actions), ", ")
            full_text = "I executed $n_actions tool calls ($tool_names) but hit the processing limit " *
                "before producing a summary. The tool results are available — please ask your " *
                "question again and I'll summarize them."
        end

        suggestions        = _extract_suggestions(full_text)
        clarification_data = _extract_clarification_prompt(full_text)

        # Strip machine-readable markers from the user-facing text.
        # The structured data is delivered via agent_turn_summary instead.
        display_text = _strip_marker_blocks(full_text)

        # Emit text as incremental token chunks for a responsive typing feel.
        if !isempty(display_text)
            _emit_text_chunked(stream, display_text)
        end

        # Evidence-first enforcement: warn when no tools were called but the
        # response appears to contain numerical structural claims.
        if isempty(tool_actions) && _contains_numerical_claims(display_text)
            warning = "\n\n⚠️ This response was generated without consulting structural tools. Numerical results should be verified with a tool call."
            write(stream, "data: $(JSON3.write(Dict("token" => warning)))\n\n")
            display_text *= warning
            full_text *= warning
            @warn "Evidence-first warning triggered — no tool calls but numerical claims detected"
        end

        # Persist assistant turn to server-side history.
        if !isempty(session_id) && !isempty(full_text)
            _append_history!(session_id, "assistant", full_text)
        end

        params_patch = _extract_params_patch(full_text)

        summary = _build_turn_summary(;
            suggestions        = suggestions,
            clarification_data = clarification_data,
            tool_actions       = tool_actions,
            params_patch       = params_patch,
        )

        # Attach context usage so the front-end can show a budget indicator.
        conv_tokens = sum(_estimate_tokens(string(get(m, "content", ""))) + 10 for m in conversation; init=0)
        sys_tokens  = _estimate_tokens(system_prompt)
        summary["context_usage"] = Dict{String, Any}(
            "system_prompt_tokens"  => sys_tokens,
            "conversation_tokens"   => conv_tokens,
            "total_tokens"          => sys_tokens + conv_tokens,
            "budget_tokens"         => MAX_CONTEXT_TOKENS,
            "utilization_pct"       => round(100 * (sys_tokens + conv_tokens) / MAX_CONTEXT_TOKENS; digits=1),
        )
        write(stream, "data: $(JSON3.write(summary))\n\n")

    catch e
        msg = _compact_llm_error(e)
        @error "LLM streaming request failed" exception=(e, catch_backtrace())
        write(stream, "data: $(JSON3.write(Dict(
            "error"         => "llm_unavailable",
            "message"       => msg,
            "recovery_hint" => "Retry in a moment, or check network connectivity and API key balance.",
        )))\n\n")
    end

    write(stream, "data: [DONE]\n\n")
end

# ─── Geometric recommendation detection ──────────────────────────────────────

# Known top-level keys of APIParams (keeps the LLM honest about what run_design can do).
const _API_PARAM_KEYS = Set([
    "floor_type", "floor_options", "column_type", "column_catalog",
    "column_sizing_strategy", "beam_type", "beam_catalog", "beam_sizing_strategy",
    "floor_ll", "roof_ll", "grade_ll", "floor_sdl", "roof_sdl", "wall_sdl",
    "concrete", "rebar", "steel", "deflection_limit", "punching_strategy",
    "vault_lambda", "max_iterations", "skip_visualization", "mip_time_limit_sec",
    "fea_target_edge_m", "steel_w_bounds", "steel_hss_bounds", "rc_rect_bounds",
    "rc_circular_bounds", "pixelframe_fc_preset", "pixelframe_fc_min_ksi",
    "pixelframe_fc_max_ksi", "pixelframe_fc_resolution_ksi", "fire_rating",
    "optimize_for", "size_foundations", "foundation_soil", "foundation_concrete",
    "foundation_strategy", "mat_coverage_threshold", "unit_system",
    "visualization_detail", "visualization_target_edge_m",
    "uniform_column_sizing",
])

# Keyword fragments that suggest a geometric (Grasshopper-side) change.
const _GEOMETRIC_PATTERNS = [
    "spacing", "span", "bay_width", "bay_depth", "story_height", "floor_height",
    "num_stories", "num_bays", "num_columns", "column_layout", "column_position",
    "grid_size", "grid_spacing", "plan_width", "plan_depth", "footprint",
    "bay_size", "cantilever", "setback", "opening",
]

"""
    _classify_patch(patch) -> (api_keys, geometric_hints, other_unknown)

Split a param patch dict into three sets:
- `api_keys`       : keys recognised as valid APIParams fields.
- `geometric_hints`: keys not in APIParams but matching geometric-change patterns.
- `other_unknown`  : remaining unrecognised keys (e.g. typos).
"""
function _classify_patch(patch::Dict)
    api_keys       = String[]
    geo_hints      = String[]
    other_unknown  = String[]
    for k in keys(patch)
        ks = lowercase(string(k))
        if ks in _API_PARAM_KEYS
            push!(api_keys, string(k))
        elseif any(p -> occursin(p, ks), _GEOMETRIC_PATTERNS)
            push!(geo_hints, string(k))
        else
            push!(other_unknown, string(k))
        end
    end
    return api_keys, geo_hints, other_unknown
end

"""
    _validate_params_patch(patch) -> Dict{String, Any}

Validate a params patch against the full schema: enum membership, numeric
ranges, unknown keys, and floor/column/beam compatibility rules.
Returns `{ok, violations, warnings}`.
"""
function _validate_params_patch(patch::Dict{String, Any})::Dict{String, Any}
    violations = Dict{String, Any}[]
    warnings   = String[]
    schema     = api_params_schema_structured()

    # 1. Check for unknown keys.
    api_keys, geo_hints, unknowns = _classify_patch(patch)
    for k in unknowns
        push!(warnings, "Unknown parameter \"$k\". Not a recognized API field.")
    end
    for k in geo_hints
        push!(warnings, "\"$k\" looks like a geometric parameter — geometry is set in Grasshopper, not via the API.")
    end

    # 2. Enum and range checks — walk top-level and nested fields.
    _check_schema_constraints!(violations, patch, schema, "")

    # 3. Compatibility rules (floor ↔ column ↔ beam).
    floor_type  = get(patch, "floor_type", nothing)
    column_type = get(patch, "column_type", nothing)
    beam_type   = get(patch, "beam_type", nothing)
    if !isnothing(floor_type)
        floor_schema = get(schema, "floor_type", nothing)
        if !isnothing(floor_schema)
            compat = get(floor_schema, "compatibility_checks", nothing)
            if !isnothing(compat)
                for rule in get(compat, "rules", Any[])
                    when_clause = get(rule, "when", Dict())
                    rejects     = get(rule, "rejects", Dict())
                    when_floor  = get(when_clause, "floor_type", nothing)
                    active = if !isnothing(when_floor)
                        when_floor isa Vector ? floor_type in when_floor : floor_type == when_floor
                    else
                        false
                    end
                    active || continue
                    rule_id = get(rule, "id", "compatibility")
                    sev     = get(rule, "severity", "error")
                    reject_cols  = get(rejects, "column_type", String[])
                    reject_beams = get(rejects, "beam_type",   String[])
                    if !isnothing(column_type) && column_type in reject_cols
                        push!(violations, Dict{String, Any}(
                            "field" => "column_type", "value" => column_type,
                            "constraint" => "compatibility",
                            "message" => "$rule_id: column_type \"$column_type\" incompatible with floor_type \"$floor_type\"",
                            "severity" => sev,
                        ))
                    end
                    if !isnothing(beam_type) && beam_type in reject_beams
                        push!(violations, Dict{String, Any}(
                            "field" => "beam_type", "value" => beam_type,
                            "constraint" => "compatibility",
                            "message" => "$rule_id: beam_type \"$beam_type\" incompatible with floor_type \"$floor_type\"",
                            "severity" => sev,
                        ))
                    end
                end
            end
        end
    end

    # 4. uniform_column_sizing + pixelframe compatibility
    # Only check when both fields are present in the patch; if column_type is not
    # in the patch we can't know the current type — full API validation catches it.
    ucs = get(patch, "uniform_column_sizing", nothing)
    if !isnothing(ucs) && lowercase(string(ucs)) != "off" && !isnothing(column_type)
        if column_type == "pixelframe"
            push!(violations, Dict{String, Any}(
                "field" => "uniform_column_sizing", "value" => ucs,
                "constraint" => "compatibility",
                "message" => "uniform_column_sizing \"$ucs\" is not supported with pixelframe columns.",
            ))
        end
    end

    # Field guidance: for each patched API key, show related checks from lever map
    field_guidance = Dict{String, Any}()
    for k in api_keys
        affected_checks = String[]
        for (check_name, lever_info) in LEVER_SURFACE_MAP
            params_list = get(lever_info, "parameters", String[])
            if k in params_list
                push!(affected_checks, check_name)
            end
        end
        if !isempty(affected_checks)
            field_guidance[k] = Dict{String, Any}(
                "affects_checks" => affected_checks,
                "impact" => get(get(schema, k, Dict()), "impact", nothing),
            )
        end
    end

    result = Dict{String, Any}(
        "ok" => isempty(violations),
        "violations" => violations,
        "warnings" => warnings,
    )
    !isempty(field_guidance) && (result["field_guidance"] = field_guidance)
    return result
end

function _check_schema_constraints!(violations, patch, schema, prefix)
    for (key, val) in patch
        full_key = isempty(prefix) ? key : "$(prefix).$(key)"
        spec = get(schema, key, nothing)
        isnothing(spec) && continue
        !isa(spec, Dict) && continue

        ptype = get(spec, "type", "")

        if ptype == "object"
            sub_fields = get(spec, "fields", nothing)
            if !isnothing(sub_fields) && val isa Dict
                _check_schema_constraints!(violations, Dict{String, Any}(string(k) => v for (k, v) in val), sub_fields, full_key)
            end
        elseif ptype == "enum"
            allowed = get(spec, "allowed", nothing)
            if !isnothing(allowed) && !(string(val) in [string(a) for a in allowed])
                push!(violations, Dict{String, Any}(
                    "field" => full_key, "value" => val,
                    "constraint" => "enum",
                    "allowed" => allowed,
                    "message" => "\"$full_key\" = \"$val\" not in allowed values: $(join(allowed, ", "))",
                ))
            end
        elseif ptype == "number" || ptype == "float" || ptype == "integer"
            rng = get(spec, "range", nothing)
            if !isnothing(rng) && length(rng) >= 2 && val isa Real
                lo, hi = rng[1], rng[2]
                if val < lo || val > hi
                    push!(violations, Dict{String, Any}(
                        "field" => full_key, "value" => val,
                        "constraint" => "range",
                        "range" => rng,
                        "message" => "\"$full_key\" = $val out of range [$lo, $hi]",
                    ))
                end
            end
        elseif ptype == "bool" || ptype == "boolean"
            if !(val isa Bool)
                push!(violations, Dict{String, Any}(
                    "field" => full_key, "value" => val,
                    "constraint" => "type",
                    "message" => "\"$full_key\" must be a boolean, got $(typeof(val))",
                ))
            end
        end
    end
end

# Timeout for a quick-check design run. Large complex buildings can take 2-5 min
# for a full design; this cap keeps the conversational loop responsive.
const QUICK_DESIGN_TIMEOUT_S = 60.0

# ─── Tool dispatch ────────────────────────────────────────────────────────────

"""
    _dispatch_chat_tool(tool, args) -> Dict

Dispatch a named structural tool call from the agent. Returns a
JSON-serialisable result dict.

Phase 1 — Orientation:
- `get_situation_card`       — single-call snapshot: geometry + params + health + history + trace availability.
- `get_building_summary`     — detailed geometry summary (stories, spans, counts, regularity).
- `get_design_history`       — past designs in session (params, pass/fail, EC).
- `get_current_params`       — fully resolved parameter set from the last design.

Phase 2 — Diagnosis:
- `get_diagnose_summary`     — lightweight failure overview: counts, top-5 critical, failure breakdown.
- `get_diagnose`             — high-resolution per-element diagnostics.
- `query_elements`           — filtered element subset from /diagnose data.
- `get_solver_trace`         — tiered solver decision trace (why it chose sections, fell back, converged). Use tier=summary → failures → decisions → full.
- `get_lever_map`            — which parameters affect a given failure check. Consult before recommending fixes.
- `get_implemented_provisions` — design code clause index.
- `explain_field`            — parameter definition, units, range, related checks.
- `get_result_summary`       — structured JSON summary of the latest design result.
- `get_condensed_result`     — plain-text condensed result summary (~500 tokens).
- `get_applicability`        — compact method/floor eligibility rules.

Phase 3 — Exploration:
- `run_experiment`           — instant micro-experiment on a single element (punching, P-M, beam, punching reinforcement, deflection, catalog screen).
- `list_experiments`         — available experiment types and arg schemas.
- `batch_experiments`        — run multiple experiments in one call.
- `validate_params`          — check a params patch for compatibility violations.
- `run_design`               — fast parameter-only what-if check (60 s timeout).
- `compare_designs`          — delta table between two designs from history.
- `suggest_next_action`      — ranked parameter changes for a goal.

Session Insights:
- `record_insight`           — record a structured learning from a design iteration.
- `get_session_insights`     — retrieve accumulated learnings (filterable by category/check/param).

Phase 4 — Communication:
- `narrate_element`          — plain-English explanation of one element.
- `narrate_comparison`       — plain-English comparison of two designs.
- `clarify_user_intent`      — structured multiple-choice clarification.
"""
const _NO_DESIGN_HINT   = "No solved design on the server yet. Run Design from Grasshopper (POST /design) first. Until then, use the geometry digest and predict_geometry_effect for qualitative advice."
const _NO_GEOMETRY_HINT = "Server-cached geometry comes from a Grasshopper Design run (POST /design). If a digest is in the prompt, you can still advise on geometry changes via predict_geometry_effect — but run_design and get_building_summary require server geometry."
const CHAT_AUTOWAIT_TIMEOUT_S = 90.0

"""
Upper bound for POST /chat blocking on an in-flight `POST /design` (e.g. Grasshopper).
Uses SSE heartbeats so clients show progress; default matches the Grasshopper poll horizon (~1 h).
Override with env `CHAT_PRE_CHAT_DESIGN_WAIT_TIMEOUT_S` (positive seconds).
"""
function _pre_chat_design_wait_timeout_s()::Float64
    s = strip(get(ENV, "CHAT_PRE_CHAT_DESIGN_WAIT_TIMEOUT_S", ""))
    isempty(s) && return 3600.0
    v = tryparse(Float64, s)
    (isnothing(v) || !isfinite(v) || v <= 0.0) && return 3600.0
    return v
end

# Tools that should prefer waiting for an in-flight design to finish so they
# return the freshest cached result set rather than stale data.
const _TOOLS_REQUIRE_FRESH_DESIGN = Set([
    "get_situation_card",
    "get_result_summary",
    "get_condensed_result",
    "get_current_params",
    "get_design_history",
    "get_diagnose_summary",
    "get_diagnose",
    "query_elements",
    "get_solver_trace",
    "explain_trace_lookup",
    "run_experiment",
    "batch_experiments",
    "suggest_next_action",
    "compare_designs",
    "narrate_element",
    "narrate_comparison",
])

"""Read `DESIGN_CACHE.last_design` under lock to avoid torn reads."""
function _get_last_design()::Union{BuildingDesign, Nothing}
    lock(DESIGN_CACHE.lock) do
        DESIGN_CACHE.last_design
    end
end

"""Wait for the async design loop to return to idle."""
function _wait_until_server_idle(; timeout_s::Float64=CHAT_AUTOWAIT_TIMEOUT_S)::Symbol
    timedwait(() -> status_string(SERVER_STATUS) == "idle", timeout_s; pollint=1.0)
end

"""
Wait until `SERVER_STATUS` is idle, emitting periodic SSE `design_wait` events so the
client connection stays alive and the UI can show that chat is blocked on the design job.

Returns `:ok` or `:timed_out`.
"""
function _wait_until_server_idle_sse!(
    stream::HTTP.Stream;
    timeout_s::Float64,
    heartbeat_s::Float64=15.0,
    pollint::Float64=1.0,
)::Symbol
    t0 = time()
    last_hb = t0
    while status_string(SERVER_STATUS) != "idle"
        now = time()
        if now - t0 >= timeout_s
            return :timed_out
        end
        if now - last_hb >= heartbeat_s
            elapsed = round(Int, now - t0)
            payload = Dict{String, Any}(
                "type"          => "design_wait",
                "phase"         => "polling",
                "message"       => "Waiting for the in-flight design run to finish…",
                "elapsed_s"     => elapsed,
                "server_status" => status_string(SERVER_STATUS),
            )
            write(stream, "data: $(JSON3.write(payload))\n\n")
            last_hb = now
        end
        sleep(pollint)
    end
    return :ok
end

"""Infer coordinate-unit string for chat quick-check runs from cached context."""
function _quick_check_coord_unit()::String
    # Prefer latest solved design context when available.
    d = _get_last_design()
    if !isnothing(d)
        du = d.params.display_units
        return du.units[:length] == u"ft" ? "feet" : "meters"
    end

    # Fallback: infer from cached geometry story elevations.
    struc = with_cache_read(c -> c.structure, DESIGN_CACHE)
    if !isnothing(struc)
        zvals = Float64[]
        for z in struc.skeleton.stories_z
            push!(zvals, z isa Unitful.Quantity ? ustrip(u"m", z) : Float64(z))
        end
        if !isempty(zvals)
            zmax = maximum(abs.(zvals))
            # Meter-coordinate buildings are typically < ~250 m tall.
            # Far larger magnitudes usually indicate feet coordinates.
            return zmax > 250.0 ? "feet" : "meters"
        end
    end
    return "meters"
end

"""
Check if the client geometry hash (from args) differs from the server's cached geometry.
Returns a warning string if stale, or `nothing` if aligned or unknown.
"""
function _stale_geometry_warning(args::Dict{String, Any})::Union{Nothing, String}
    cli = strip(string(get(args, "client_geometry_hash", "")))
    isempty(cli) && return nothing
    srv = strip(_server_geometry_hash())
    isempty(srv) && return nothing
    cli == srv && return nothing
    return "GEOMETRY MISMATCH: This tool executed against the server's cached geometry (hash=$srv), " *
           "which differs from the client's current model (hash=$cli). " *
           "Results apply to the CACHED model, not the current Grasshopper geometry. " *
           "Tell the user to run Design from Grasshopper to update the server before interpreting these results for the current model."
end

"""
Evaluate DDM/EFM applicability checks against actual geometry.

Uses slab panel spans and story count to report which method prerequisites are
met or violated. Returns a Dict with per-method verdicts.
"""
function _evaluate_applicability_against_geometry(struc::BuildingStructure)::Dict{String, Any}
    slabs = struc.slabs
    n_stories = length(struc.skeleton.stories)

    aspect_ratios = Float64[]
    for s in slabs
        l1 = ustrip(u"m", s.spans.primary)
        l2 = ustrip(u"m", s.spans.secondary)
        l2 > 0 && push!(aspect_ratios, l1 / l2)
    end

    ddm_checks = Dict{String, Any}[]

    # DDM §13.6.2.2: minimum 3 continuous spans in each direction
    push!(ddm_checks, Dict{String, Any}(
        "check" => "ddm_min_spans",
        "clause" => "ACI 318 §13.6.2.2",
        "description" => "≥3 continuous spans in each direction",
        "status" => n_stories >= 1 && length(slabs) >= 3 ? "likely_ok" : "may_violate",
        "note" => "$(length(slabs)) slab panels, $(n_stories) stories. Full continuous-span count requires frame topology analysis.",
    ))

    # DDM §13.6.2.2: aspect ratio 0.5 ≤ l₂/l₁ ≤ 2.0
    if !isempty(aspect_ratios)
        min_ar = minimum(aspect_ratios)
        max_ar = maximum(aspect_ratios)
        in_range = all(0.5 .<= aspect_ratios .<= 2.0)
        push!(ddm_checks, Dict{String, Any}(
            "check" => "ddm_aspect_ratio",
            "clause" => "ACI 318 §13.6.2.2",
            "description" => "Panel aspect ratio 0.5 ≤ l₂/l₁ ≤ 2.0",
            "status" => in_range ? "ok" : "violates",
            "min_aspect" => round(min_ar; digits=2),
            "max_aspect" => round(max_ar; digits=2),
        ))
    end

    # DDM §13.6.2.5: successive span lengths differ by ≤ 1/3 of longer span
    primary_spans = [ustrip(u"m", s.spans.primary) for s in slabs]
    sort!(primary_spans)
    span_diff_ok = true
    if length(primary_spans) >= 2
        for i in 2:length(primary_spans)
            diff = abs(primary_spans[i] - primary_spans[i-1])
            if diff > primary_spans[i] / 3
                span_diff_ok = false
                break
            end
        end
    end
    push!(ddm_checks, Dict{String, Any}(
        "check" => "ddm_span_difference",
        "clause" => "ACI 318 §13.6.2.5",
        "description" => "Successive spans differ ≤ ⅓ of longer span",
        "status" => span_diff_ok ? "ok" : "may_violate",
    ))

    return Dict{String, Any}(
        "n_slabs" => length(slabs),
        "n_stories" => n_stories,
        "ddm_checks" => ddm_checks,
        "efm_note" => "EFM (Equivalent Frame Method) has no geometric hard limits — it handles irregular spans, non-rectangular panels, and pattern loading. Preferred when DDM checks fail.",
        "fea_note" => "FEA has no applicability limits and handles any geometry including skewed/triangular panels.",
    )
end

function _dispatch_chat_tool(tool::String, args::Dict{String, Any})::Dict{String, Any}
    design = _get_last_design()
    struc = with_cache_read(c -> c.structure, DESIGN_CACHE)

    # If a design is currently running, wait briefly for completion on tools
    # that consume result-layer data so the assistant responds with fresh data.
    if tool in _TOOLS_REQUIRE_FRESH_DESIGN && status_string(SERVER_STATUS) != "idle"
        wait_state = _wait_until_server_idle()
        if wait_state == :timed_out
            return Dict{String, Any}(
                "error" => "design_still_running",
                "message" => "A design run is still in progress. I waited, but it has not completed yet.",
                "recovery_hint" => "Retry in a moment, or poll GET /status until idle.",
                "status" => status_string(SERVER_STATUS),
            )
        end
        design = _get_last_design()
        struc = with_cache_read(c -> c.structure, DESIGN_CACHE)
    end

    if tool == "get_result_summary"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return report_summary_json(design)

    elseif tool == "get_condensed_result"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return Dict("text" => condense_result(design))

    elseif tool == "get_applicability"
        base = api_applicability_schema()
        # Enrich with geometry evaluation when geometry is available
        struc_local = with_cache_read(c -> c.structure, DESIGN_CACHE)
        if !isnothing(struc_local)
            base["geometry_evaluation"] = _evaluate_applicability_against_geometry(struc_local)
        end
        return base

    elseif tool == "clarify_user_intent"
        clarification_id = string(get(args, "id", ""))
        prompt_text      = string(get(args, "prompt", ""))
        allow_multiple_raw = get(args, "allow_multiple", false)
        allow_multiple = something(_chat_coerce_bool(allow_multiple_raw), false)
        rationale        = string(get(args, "rationale", ""))
        required_for     = string(get(args, "required_for", ""))
        session_id       = string(get(args, "session_id", ""))
        options_raw      = get(args, "options", Any[])

        isempty(prompt_text) && return Dict(
            "ok"      => false,
            "error"   => "prompt_required",
            "message" => "clarify_user_intent requires a non-empty 'prompt' field.",
        )

        if !(options_raw isa AbstractVector) || isempty(options_raw)
            return Dict(
                "ok"      => false,
                "error"   => "options_required",
                "message" => "clarify_user_intent requires a non-empty options array.",
            )
        end

        options = Vector{Dict{String, String}}()
        for (i, raw_opt) in enumerate(options_raw)
            if raw_opt isa AbstractDict
                oid = string(get(raw_opt, "id", get(raw_opt, :id, "opt_$(i)")))
                lbl = string(get(raw_opt, "label", get(raw_opt, :label, "")))
                isempty(lbl) && continue
                push!(options, Dict("id" => oid, "label" => lbl))
            else
                lbl = string(raw_opt)
                isempty(lbl) && continue
                push!(options, Dict("id" => "opt_$(i)", "label" => lbl))
            end
        end

        isempty(options) && return Dict(
            "ok"      => false,
            "error"   => "options_invalid",
            "message" => "clarify_user_intent options must contain at least one non-empty label.",
        )

        # Limit to four choices for a manageable UI interaction.
        length(options) > 4 && (options = options[1:4])

        isempty(clarification_id) && (clarification_id = lowercase(replace(prompt_text[1:min(end, 24)], r"[^a-zA-Z0-9]+" => "_")))
        is_new = _remember_clarification!(session_id, clarification_id)

        return Dict(
            "ok"      => true,
            "type"    => "clarification",
            "duplicate" => !is_new,
            "clarification" => Dict(
                "id"             => clarification_id,
                "prompt"         => prompt_text,
                "options"        => options,
                "allow_multiple" => allow_multiple,
                "rationale"      => rationale,
                "required_for"   => required_for,
            ),
        )

    # ── Session Insights ──────────────────────────────────────────────────
    elseif tool == "record_insight"
        cat_str = string(get(args, "category", "observation"))
        cat = Symbol(cat_str)
        summary_str = string(get(args, "summary", ""))
        isempty(summary_str) && return Dict("error" => "missing_summary", "message" => "Provide a 'summary' for the insight.")
        detail_str = string(get(args, "detail", ""))
        checks = String[string(c) for c in get(args, "related_checks", String[])]
        params = String[string(p) for p in get(args, "related_params", String[])]
        didx = _chat_coerce_int(get(args, "design_index", 0))
        isnothing(didx) && return Dict("error" => "invalid_design_index", "message" => "design_index must be an integer (0 for general).")
        conf = _chat_coerce_float(get(args, "confidence", 0.5))
        isnothing(conf) && return Dict("error" => "invalid_confidence", "message" => "confidence must be numeric in [0, 1].")
        (conf < 0.0 || conf > 1.0) && return Dict("error" => "invalid_confidence", "message" => "confidence must be in [0, 1]. Got: $conf")

        insight = SessionInsight(;
            category = cat,
            summary = summary_str,
            detail = detail_str,
            related_checks = checks,
            related_params = params,
            design_index = didx,
            confidence = conf,
        )
        record_session_insight!(insight)
        n_total = length(SESSION_INSIGHTS)
        return Dict{String, Any}(
            "ok" => true,
            "message" => "Insight recorded ($(n_total) total in session).",
            "insight" => Dict("category" => cat_str, "summary" => summary_str),
        )

    elseif tool == "get_session_insights"
        cat_arg = get(args, "category", nothing)
        cat = isnothing(cat_arg) ? nothing : Symbol(string(cat_arg))
        check_arg = get(args, "check", nothing)
        check = isnothing(check_arg) ? nothing : string(check_arg)
        param_arg = get(args, "param", nothing)
        param = isnothing(param_arg) ? nothing : string(param_arg)
        min_conf = _chat_coerce_float(get(args, "min_confidence", 0.0))
        isnothing(min_conf) && return Dict("error" => "invalid_min_confidence", "message" => "min_confidence must be numeric.")

        insights = get_session_insights(; category=cat, check=check, param=param, min_confidence=min_conf)
        return Dict{String, Any}(
            "n_insights" => length(insights),
            "insights" => session_insights_to_json(insights),
            "note" => isempty(insights) ? "No insights recorded yet. Use record_insight after observing design outcomes." : nothing,
        )

    # ── Phase 1: Orientation ────────────────────────────────────────────────
    elseif tool == "get_situation_card"
        cli = string(get(args, "client_geometry_hash", ""))
        geo_hash = with_cache_read(c -> c.geometry_hash, DESIGN_CACHE)
        return agent_situation_card(
            struc,
            design,
            get_design_history_entries();
            server_geometry_hash = geo_hash,
            client_geometry_hash = cli,
        )

    elseif tool == "get_building_summary"
        isnothing(struc) && return Dict("error" => "no_geometry", "message" => "No geometry loaded. Submit geometry via POST /design first.", "recovery_hint" => _NO_GEOMETRY_HINT)
        return agent_building_summary(struc)

    elseif tool == "get_geometry_digest"
        # Try the chat-side structure cache first (from building_geometry in POST /chat)
        cached_digest = lock(_CHAT_STRUCTURE_CACHE.lock) do
            _CHAT_STRUCTURE_CACHE.digest
        end
        if !isnothing(cached_digest)
            cached_digest["_source"] = "chat_structure_cache"
            cached_digest["_plaintext"] = _structure_digest_plaintext(cached_digest)
            return cached_digest
        end
        # Fall back: build from the design cache's structure if available
        if !isnothing(struc)
            digest = try
                _structure_geometry_digest(struc)
            catch e
                @warn "get_geometry_digest: digest from server structure failed" exception=(e, catch_backtrace())
                nothing
            end
            if !isnothing(digest)
                digest["_source"] = "design_cache_structure"
                digest["_plaintext"] = _structure_digest_plaintext(digest)
                return digest
            end
        end
        return Dict{String, Any}(
            "error" => "no_geometry",
            "message" => "No geometry available. Neither chat building_geometry nor server POST /design geometry is loaded.",
            "recovery_hint" => _NO_GEOMETRY_HINT,
        )

    elseif tool == "get_current_params"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return agent_current_params(design)

    elseif tool == "get_design_history"
        entries = get_design_history_entries()
        isempty(entries) && return Dict("history" => [], "message" => "No designs in session history yet.")
        return Dict("history" => design_history_to_json(entries), "count" => length(entries))

    # ── Phase 2: Diagnosis ───────────────────────────────────────────────────
    elseif tool == "get_diagnose_summary"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return agent_diagnose_summary(design)

    elseif tool == "get_diagnose"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        units_arg = get(args, "units", nothing)
        report_units = nothing
        if !isnothing(units_arg)
            units_str = lowercase(strip(string(units_arg)))
            if units_str in ("imperial", "metric")
                report_units = Symbol(units_str)
            else
                return Dict("error" => "invalid_units", "message" => "units must be \"imperial\" or \"metric\".")
            end
        end
        return design_to_diagnose(design; report_units=report_units)

    elseif tool == "query_elements"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        min_ratio_raw = get(args, "min_ratio", nothing)
        max_ratio_raw = get(args, "max_ratio", nothing)
        ok_raw = get(args, "ok", nothing)
        min_ratio = isnothing(min_ratio_raw) ? nothing : _chat_coerce_float(min_ratio_raw)
        max_ratio = isnothing(max_ratio_raw) ? nothing : _chat_coerce_float(max_ratio_raw)
        ok_val = isnothing(ok_raw) ? nothing : _chat_coerce_bool(ok_raw)
        ( !isnothing(min_ratio_raw) && isnothing(min_ratio) ) && return Dict("error" => "invalid_min_ratio", "message" => "min_ratio must be numeric.")
        ( !isnothing(max_ratio_raw) && isnothing(max_ratio) ) && return Dict("error" => "invalid_max_ratio", "message" => "max_ratio must be numeric.")
        ( !isnothing(ok_raw) && isnothing(ok_val) ) && return Dict("error" => "invalid_ok", "message" => "ok must be boolean (true/false).")
        story_raw = get(args, "story", nothing)
        story_val = isnothing(story_raw) ? nothing : _chat_coerce_int(story_raw)
        return agent_query_elements(design;
            type             = let t = get(args, "type", nothing); isnothing(t) ? nothing : string(t) end,
            min_ratio        = min_ratio,
            max_ratio        = max_ratio,
            governing_check  = let gc = get(args, "governing_check", nothing); isnothing(gc) ? nothing : string(gc) end,
            ok               = ok_val,
            story            = story_val,
        )

    elseif tool == "get_solver_trace"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        tier_arg    = lowercase(strip(string(get(args, "tier", "failures"))))
        element_arg = get(args, "element", nothing)
        layer_arg   = get(args, "layer", nothing)
        !(tier_arg in ("summary", "failures", "decisions", "full")) &&
            return Dict("error" => "invalid_tier", "message" => "tier must be one of: summary, failures, decisions, full.")
        tier_sym    = Symbol(tier_arg)
        layer_sym   = if isnothing(layer_arg)
            nothing
        else
            layer_str = lowercase(strip(string(layer_arg)))
            if layer_str in ("pipeline", "workflow", "sizing", "optimizer", "checker", "slab")
                Symbol(layer_str)
            else
                return Dict("error" => "invalid_layer", "message" => "layer must be one of: pipeline, workflow, sizing, optimizer, checker, slab.")
            end
        end
        return agent_solver_trace(design;
            tier    = tier_sym,
            element = isnothing(element_arg) ? nothing : string(element_arg),
            layer   = layer_sym,
        )

    elseif tool == "explain_trace_lookup"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        lookup_raw = get(args, "lookup", nothing)
        isnothing(lookup_raw) && return Dict("error" => "missing_lookup", "message" => "Provide a 'lookup' object from a breadcrumb bundle (top_elements[].lookup).")
        lookup = lookup_raw isa AbstractDict ? Dict{String, Any}(string(k) => v for (k, v) in lookup_raw) :
                 Dict{String, Any}("raw" => lookup_raw)
        return agent_explain_trace_lookup(design; lookup=lookup)

    elseif tool == "get_lever_map"
        check_arg = get(args, "check", nothing)
        return get_lever_map(; check=isnothing(check_arg) ? nothing : string(check_arg))

    elseif tool == "get_implemented_provisions"
        code_arg = get(args, "code", nothing)
        return get_provisions(; code=isnothing(code_arg) ? nothing : string(code_arg))

    elseif tool == "explain_field"
        field = get(args, "field", nothing)
        isnothing(field) && return Dict("error" => "missing_field", "message" => "Provide a 'field' argument (e.g., \"deflection_limit\").")
        return agent_explain_field(string(field))

    elseif tool == "get_provision_rationale"
        section = get(args, "section", nothing)
        isnothing(section) && return Dict("error" => "missing_section", "message" => "Provide a 'section' argument (e.g., \"22.6\", \"H1\", \"ACI_318.22.6\", or a check family like \"punching_shear\").")
        entry = get_provision_ontology(string(section))
        if isnothing(entry)
            return Dict{String, Any}(
                "error"   => "provision_not_found",
                "message" => "No ontology entry for \"$section\". " *
                    "Available sections: $(join(sort(collect(keys(PROVISION_ONTOLOGY))), ", ")). " *
                    "Check families: $(join(sort(collect(keys(CHECK_FAMILY_TO_PROVISION))), ", ")).",
                "recovery_hint" => "Try a section number (\"22.6\"), full key (\"ACI_318.22.6\"), or check family name (\"punching_shear\").",
            )
        end
        return entry

    # ── Phase 3: Exploration ─────────────────────────────────────────────────
    elseif tool == "compare_designs"
        idx_a = _chat_coerce_int(get(args, "index_a", nothing))
        idx_b = _chat_coerce_int(get(args, "index_b", nothing))
        (isnothing(idx_a) || isnothing(idx_b)) && return Dict("error" => "missing_args", "message" => "Provide index_a and index_b (1-based history index, or 0 for current).")
        return agent_compare_designs(idx_a, idx_b)

    elseif tool == "suggest_next_action"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        goal = get(args, "goal", nothing)
        isnothing(goal) && return Dict("error" => "missing_goal", "message" => "Provide a 'goal' argument (fix_failures, reduce_column_size, reduce_slab_thickness, reduce_ec).")
        return agent_suggest_next_action(design, string(goal))

    elseif tool == "predict_geometry_effect"
        variable  = get(args, "variable", nothing)
        direction = get(args, "direction", nothing)
        isnothing(variable) && return Dict("error" => "missing_variable", "message" => "Provide 'variable' (span_length, story_height, column_count, column_spacing_uniformity, plan_aspect_ratio).")
        isnothing(direction) && return Dict("error" => "missing_direction", "message" => "Provide 'direction' (increase, decrease).")
        return agent_predict_geometry_effect(string(variable), string(direction))

    elseif tool == "run_experiment"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        exp_type = get(args, "type", nothing)
        exp_args = get(args, "args", Dict{String, Any}())
        isnothing(exp_type) && return Dict("error" => "missing_type", "message" => "Provide experiment 'type' (punching, pm_column, beam, punching_reinforcement, deflection, catalog_screen).")
        !(exp_args isa AbstractDict) && return Dict("error" => "invalid_args", "message" => "run_experiment args must be an object.")
        exp_args_dict = Dict{String, Any}(string(k) => v for (k, v) in exp_args)
        result = evaluate_experiment(design, string(exp_type), exp_args_dict)
        geo_warn = _stale_geometry_warning(args)
        !isnothing(geo_warn) && (result["geometry_warning"] = geo_warn)
        return result

    elseif tool == "list_experiments"
        return list_experiments()

    elseif tool == "batch_experiments"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        experiments_raw = get(args, "experiments", Any[])
        !(experiments_raw isa AbstractVector) && return Dict("error" => "invalid_experiments", "message" => "experiments must be an array of {type,args} objects.")
        for e in experiments_raw
            !(e isa AbstractDict) && return Dict("error" => "invalid_experiments", "message" => "Each experiments entry must be an object with type and args.")
        end
        experiments = [Dict{String, Any}(string(k) => v for (k, v) in e) for e in experiments_raw]
        return batch_evaluate(design, experiments)

    # ── Phase 4: Communication ───────────────────────────────────────────────
    elseif tool == "narrate_element"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        etype    = get(args, "element_type", nothing)
        eid      = _chat_coerce_int(get(args, "element_id", nothing))
        audience = get(args, "audience", "architect")
        (isnothing(etype) || isnothing(eid)) && return Dict("error" => "missing_args", "message" => "Provide element_type and element_id.")
        return agent_narrate_element(design, string(etype), eid, string(audience))

    elseif tool == "narrate_comparison"
        idx_a    = _chat_coerce_int(get(args, "index_a", nothing))
        idx_b    = _chat_coerce_int(get(args, "index_b", nothing))
        audience = get(args, "audience", "architect")
        (isnothing(idx_a) || isnothing(idx_b)) && return Dict("error" => "missing_args", "message" => "Provide index_a and index_b.")
        return agent_narrate_comparison(idx_a, idx_b, string(audience))

    # ── Original tools ───────────────────────────────────────────────────────
    elseif tool == "validate_params"
        param_patch = Dict{String, Any}(string(k) => v for (k, v) in get(args, "params", Dict()))
        if isempty(param_patch)
            return Dict{String, Any}(
                "ok" => true,
                "violations" => Dict{String, Any}[],
                "warnings" => String[],
                "note" => "Empty params patch — nothing to validate.",
            )
        end
        return _validate_params_patch(param_patch)

    elseif tool == "run_design"
        # ── Guard: server state ──────────────────────────────────────────────
        if status_string(SERVER_STATUS) != "idle"
            return Dict(
                "error"          => "server_busy",
                "message"        => "A design is already running. Wait until the server is idle, then retry.",
                "recovery_hint"  => "Wait for the current design to finish, then retry.",
            )
        end
        cached_struc = with_cache_read(c -> c.structure, DESIGN_CACHE)
        isnothing(cached_struc) && return Dict(
            "error"          => "no_geometry",
            "message"        => "No server-cached geometry for run_design. Run Design from Grasshopper (POST /design) first. A chat digest does not populate the design cache.",
            "recovery_hint"  => _NO_GEOMETRY_HINT,
        )

        param_patch_raw = get(args, "params", nothing)
        isnothing(param_patch_raw) && return Dict(
            "error"   => "params_required",
            "message" => "Provide the parameter patch in args.params.",
        )
        !(param_patch_raw isa AbstractDict) && return Dict(
            "error"   => "invalid_params",
            "message" => "args.params must be an object (key-value parameter patch).",
        )

        # ── Classify patch keys ──────────────────────────────────────────────
        patch_dict = Dict{String, Any}(string(k) => v for (k, v) in param_patch_raw)
        api_keys, geo_hints, other_unknown = _classify_patch(patch_dict)

        # If the patch is ENTIRELY geometric (no API params changed), skip the
        # design run and return actionable Grasshopper guidance instead.
        if isempty(api_keys) && !isempty(geo_hints)
            return Dict(
                "error"            => "geometric_change_required",
                "geometric_fields" => geo_hints,
                "message"          => "This recommendation requires changing the building geometry in Grasshopper. " *
                    "The following are geometry properties, not API parameters: $(join(geo_hints, ", ")). " *
                    "Adjust the Rhino model or the GeometryInput component, then re-run the design from Grasshopper.",
                "note"             => "run_design only applies changes to API parameters (floor type, material, loads, sizing strategy, etc.). " *
                    "Geometric changes — column positions, bay dimensions, story heights, setbacks — must be made in Grasshopper.",
            )
        end

        # Build fast-mode patch: force skip_visualization and cap iterations/MIP
        # to keep the conversational loop responsive.
        fast_patch = copy(patch_dict)
        fast_patch["skip_visualization"]  = true
        max_iter = something(_chat_coerce_int(get(fast_patch, "max_iterations", 20)), 20)
        mip_limit = something(_chat_coerce_float(get(fast_patch, "mip_time_limit_sec", 30.0)), 30.0)
        fast_patch["max_iterations"]      = max(1, min(max_iter, 2))
        fast_patch["mip_time_limit_sec"]  = max(1.0, min(mip_limit, 20.0))

        # ── Acquire server lock ──────────────────────────────────────────────
        if !try_start!(SERVER_STATUS)
            return Dict("error" => "server_busy", "message" => "Server became busy — retry in a moment.", "recovery_hint" => "Wait for the current design to finish, then retry.")
        end

        # ── Parse params ─────────────────────────────────────────────────────
        local fast_params
        coord_unit_assumed = _quick_check_coord_unit()
        try
            api_params = JSON3.read(JSON3.write(fast_patch), APIParams)
            fast_params = json_to_params(api_params, coord_unit_assumed)
        catch e
            finish!(SERVER_STATUS)
            return Dict("error" => "param_parse_failed", "message" => sprint(showerror, e))
        end

        # ── Run design with timeout ──────────────────────────────────────────
        # The async task always calls finish!() in its finally block, so the
        # server returns to idle even if we time out and return early here.
        result_ref = Ref{Any}(nothing)
        error_ref  = Ref{Any}(nothing)

        cached_geo_hash = with_cache_read(c -> c.geometry_hash, DESIGN_CACHE)

        design_task = @async begin
            try
                tc = TraceCollector()
                d = design_building(cached_struc, fast_params; tc=tc)
                lock(DESIGN_CACHE.lock) do
                    DESIGN_CACHE.last_design = d
                    DESIGN_CACHE.last_result = design_to_json(d; geometry_hash=cached_geo_hash)
                end
                invalidate_diagnose_cache!(DESIGN_CACHE)
                result_ref[] = d
            catch e
                @error "run_design task failed" exception=(e, catch_backtrace())
                error_ref[] = e
            finally
                finish!(SERVER_STATUS)
            end
        end

        wait_status = timedwait(() -> istaskdone(design_task), QUICK_DESIGN_TIMEOUT_S; pollint=2.0)

        if wait_status == :timed_out
            # Task still running in the background; server will become idle when it finishes.
            return Dict(
                "error"         => "timeout",
                "timeout_s"     => QUICK_DESIGN_TIMEOUT_S,
                "message"       => "Quick check timed out after $(Int(QUICK_DESIGN_TIMEOUT_S))s. " *
                    "This parameter combination triggers a long computation (large building, slow optimizer, or EFM/FEA). " *
                    "The design is still running in the background — check GET /status and try get_condensed_result when idle.",
                "recovery_hint" => "Design took too long. Simplify params or run from Grasshopper for a full run.",
                "suggestions"   => [
                    "Reduce mip_time_limit_sec to 15 and retry.",
                    "Try validate_params first to check compatibility before a full run.",
                    "Run the full design from Grasshopper instead.",
                ],
            )
        end

        if !isnothing(error_ref[])
            return Dict("error" => "design_failed", "message" => sprint(showerror, error_ref[]))
        end

        design = result_ref[]

        # ── Build result ─────────────────────────────────────────────────────
        warnings = String[]
        if !isempty(geo_hints)
            push!(warnings, "Geometric hints ignored (not API parameters): $(join(geo_hints, ", ")). Apply these changes in Grasshopper.")
        end
        if !isempty(other_unknown)
            push!(warnings, "Unknown fields ignored: $(join(other_unknown, ", ")).")
        end

        # Record in session history
        s = design.summary
        n_fail = count(p -> !p.second.ok, design.columns) +
                 count(p -> !p.second.ok, design.beams) +
                 count(p -> !(p.second.converged && p.second.deflection_ok && p.second.punching_ok), design.slabs) +
                 count(p -> !p.second.ok, design.foundations)
        record_design_history!(DesignHistoryEntry(;
            geometry_hash    = _server_geometry_hash(),
            params_patch     = patch_dict,
            all_pass         = s.all_checks_pass,
            critical_ratio   = s.critical_ratio,
            critical_element = s.critical_element,
            embodied_carbon  = s.embodied_carbon,
            n_columns        = length(design.columns),
            n_beams          = length(design.beams),
            n_slabs          = length(design.slabs),
            n_failing        = n_fail,
            source           = "run_design",
        ))

        geo_warn = _stale_geometry_warning(args)
        !isnothing(geo_warn) && push!(warnings, geo_warn)

        n_history = length(get_design_history_entries())
        guidance_parts = String["RECORD: Call record_insight to log what this run taught you."]
        if n_history >= 2
            push!(guidance_parts,
                "COMPARE: Call compare_designs to show the user what changed from the previous run.")
        end
        if !design.summary.all_checks_pass
            push!(guidance_parts,
                "FAILURES: Call get_diagnose_summary to identify which checks are failing and why.")
        end

        result = Dict(
            "ok"               => true,
            "quick_check"      => true,
            "coord_unit_assumed" => coord_unit_assumed,
            "applied_params"   => api_keys,
            "summary"          => condense_result(design),
            "all_pass"         => design.summary.all_checks_pass,
            "critical_element" => design.summary.critical_element,
            "critical_ratio"   => design.summary.critical_ratio,
            "warnings"         => warnings,
            "note"             => "Quick-check result: visualization skipped, max 2 sizing iterations, MIP capped at 20s. " *
                "Ratios may shift slightly in a full run. The canvas will update on next Grasshopper solve.",
            "_guidance"        => join(guidance_parts, "\n"),
        )
        return result

    elseif tool == "get_response_guidelines"
        return agent_response_guidelines()

    else
        return Dict(
            "error"   => "unknown_tool",
            "message" => "Unknown tool: \"$tool\". Available: " *
                "get_situation_card, get_building_summary, get_geometry_digest, get_design_history, get_current_params, " *
                "get_diagnose_summary, get_diagnose, query_elements, get_solver_trace, " *
                "get_lever_map, get_implemented_provisions, get_provision_rationale, explain_field, " *
                "get_result_summary, get_condensed_result, get_applicability, explain_trace_lookup, " *
                "run_experiment, list_experiments, batch_experiments, " *
                "validate_params, run_design, compare_designs, suggest_next_action, predict_geometry_effect, " *
                "record_insight, get_session_insights, get_response_guidelines, " *
                "narrate_element, narrate_comparison, clarify_user_intent.",
        )
    end
end

# ─── Route registration ───────────────────────────────────────────────────────

"""
    register_chat_routes!()

Register all chat-related endpoints. Called from `register_routes!()`.

Endpoints:
- `POST /chat`          — SSE streaming chat
- `POST /chat/action`   — structural tool dispatch
- `GET  /chat/history`  — retrieve session history
- `DELETE /chat/history`— clear session history

**Geometry init trace (SSE):** When the request includes structured `building_geometry`, the
response begins with one or more `data:` lines where the JSON object has `"type":"geometry_init"`.
Phases include: `opening` (immediate “why you’re waiting”), `start`, `skeleton`, `skeleton_done`,
`initialize`, `initialize_done`, `digest`, `digest_done`, `cache_hit_structure`, `cache_hit_digest`,
`fallback`, `error`, `complete`.
Each line may include `message`, `elapsed_ms`, `geometry_hash_prefix`, `cached`, and counts
(`n_cells`, etc.).

**Design completion wait (SSE):** If a full design (`POST /design`, e.g. Grasshopper) is in progress
when `/chat` is called, the handler opens the event stream immediately and emits `type:"design_wait"`
(`phase:"start"` then periodic `phase:"polling"` with `elapsed_s`) until the server is `idle`, then
`type:"design_ready"`, then the usual `token` / `agent_turn_summary` / `[DONE]` stream. Timeout: env
`CHAT_PRE_CHAT_DESIGN_WAIT_TIMEOUT_S` (default 3600 s).
"""
function register_chat_routes!()

    # ── POST /chat ──────────────────────────────────────────────────────────
    @post "/chat" function (stream::HTTP.Stream)
        req = stream.message

        if !_llm_configured()
            HTTP.setstatus(stream, 503)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            startwrite(stream)
            write(stream, JSON3.write(Dict(
                "error"          => "llm_not_configured",
                "message"        => "LLM chat is not available. Set CHAT_LLM_BASE_URL and CHAT_LLM_API_KEY environment variables.",
                "recovery_hint"  => "Check CHAT_LLM_API_KEY in server environment or secrets/openai_api_key.",
            )))
            return
        end

        local parsed
        try
            parsed = JSON3.read(_read_stream_request_body(stream))
        catch e
            HTTP.setstatus(stream, 400)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            startwrite(stream)
            write(stream, JSON3.write(Dict(
                "error"   => "invalid_json",
                "message" => "Could not parse request body as JSON: $(sprint(showerror, e))",
            )))
            return
        end

        mode = string(get(parsed, :mode, "design"))
        if mode ∉ ("design", "results")
            HTTP.setstatus(stream, 400)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            startwrite(stream)
            write(stream, JSON3.write(Dict(
                "error"   => "invalid_mode",
                "message" => "mode must be \"design\" or \"results\". Got: \"$mode\"",
            )))
            return
        end

        messages = collect(get(parsed, :messages, []))
        if isempty(messages)
            HTTP.setstatus(stream, 400)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            startwrite(stream)
            write(stream, JSON3.write(Dict(
                "error"   => "empty_messages",
                "message" => "messages array must contain at least one message.",
            )))
            return
        end

        sse_started = false
        wait_timeout_s = _pre_chat_design_wait_timeout_s()

        # If a full design is in progress, open SSE immediately and wait (with heartbeats) so the
        # client stays connected and the assistant can respond as soon as the run finishes.
        if status_string(SERVER_STATUS) != "idle"
            HTTP.setstatus(stream, 200)
            HTTP.setheader(stream, "Content-Type"  => "text/event-stream")
            HTTP.setheader(stream, "Cache-Control" => "no-cache")
            HTTP.setheader(stream, "Connection"    => "keep-alive")
            startwrite(stream)
            sse_started = true
            write(stream, "data: $(JSON3.write(Dict{String, Any}(
                "type"          => "design_wait",
                "phase"         => "start",
                "message"       => "A design run is in progress. Chat will continue automatically when it finishes.",
                "server_status" => status_string(SERVER_STATUS),
                "timeout_s"     => round(Int, wait_timeout_s),
            )))\n\n")
            wait_state = _wait_until_server_idle_sse!(stream; timeout_s=wait_timeout_s)
            if wait_state == :timed_out
                write(stream, "data: $(JSON3.write(Dict(
                    "error"          => "design_still_running",
                    "message"        => "Design run did not finish within $(Int(wait_timeout_s)) s. Chat stopped waiting.",
                    "recovery_hint"  => "Retry after GET /status is idle, or increase CHAT_PRE_CHAT_DESIGN_WAIT_TIMEOUT_S.",
                )))\n\n")
                write(stream, "data: [DONE]\n\n")
                return
            end
            write(stream, "data: $(JSON3.write(Dict{String, Any}(
                "type"    => "design_ready",
                "message" => "Design run finished. Generating the assistant response…",
            )))\n\n")
        end

        if mode == "results" && isnothing(_get_last_design())
            if sse_started
                write(stream, "data: $(JSON3.write(Dict(
                    "error"          => "no_design",
                    "message"        => "No design results available after the run completed.",
                    "recovery_hint"  => "Run a successful design from Grasshopper before opening Results Assistant.",
                )))\n\n")
                write(stream, "data: [DONE]\n\n")
            else
                HTTP.setstatus(stream, 404)
                HTTP.setheader(stream, "Content-Type" => "application/json")
                startwrite(stream)
                write(stream, JSON3.write(Dict(
                    "error"          => "no_design",
                    "message"        => "No design results available. Run a design first.",
                    "recovery_hint"  => "Run a design from Grasshopper before opening Results Assistant.",
                )))
            end
            return
        end

        params_json           = get(parsed, :params, nothing)
        geometry_summary      = string(get(parsed, :geometry_summary, get(parsed, "geometry_summary", "")))
        session_id            = string(get(parsed, :session_id, ""))
        client_geometry_hash  = string(get(parsed, :client_geometry_hash, ""))
        bg_raw = get(parsed, :building_geometry, get(parsed, "building_geometry", nothing))
        structured_geo = _parse_chat_building_geometry(bg_raw)
        if isnothing(structured_geo)
            g_raw = get(parsed, :geometry, get(parsed, "geometry", nothing))
            structured_geo = _parse_chat_building_geometry(g_raw)
        end

        # Persist the latest user message to server-side history.
        if !isempty(session_id) && !isempty(messages)
            last_msg = messages[end]
            role    = string(get(last_msg, "role",    get(last_msg, :role,    "user")))
            content = string(get(last_msg, "content", get(last_msg, :content, "")))
            _append_history!(session_id, role, content)
        end

        # Server-side clarification response pre-processing: when the last user
        # message is a structured clarification reply, parse it and inject a
        # system-context message so the LLM doesn't need to regex-parse brackets.
        messages = _preprocess_clarification_response(messages)

        # When structured geometry is present, open SSE immediately and stream
        # geometry-init phases so the client can show a loading trace while
        # BuildingStructure + digest run (can take tens of seconds on large models).
        early_sse_geo = !isnothing(structured_geo)
        if early_sse_geo
            if !sse_started
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type"  => "text/event-stream")
                HTTP.setheader(stream, "Cache-Control" => "no-cache")
                HTTP.setheader(stream, "Connection"    => "keep-alive")
                startwrite(stream)
                sse_started = true
            end
            _chat_geometry_sse_emit!(
                stream, "opening";
                message = "Loading your building geometry for the assistant — larger models can take a little while.",
            )
            _chat_get_structure_digest(structured_geo; sse_stream=stream)
        end

        system_prompt = _build_system_prompt(mode, params_json, geometry_summary, client_geometry_hash, structured_geo)
        budgeted      = _budget_messages(system_prompt, messages, MAX_CONTEXT_TOKENS)

        if !early_sse_geo && !sse_started
            HTTP.setstatus(stream, 200)
            HTTP.setheader(stream, "Content-Type"  => "text/event-stream")
            HTTP.setheader(stream, "Cache-Control" => "no-cache")
            HTTP.setheader(stream, "Connection"    => "keep-alive")
            startwrite(stream)
        end

        _stream_llm_to_sse(stream, system_prompt, budgeted; session_id=session_id, client_geometry_hash=client_geometry_hash)
    end

    # ── POST /chat/action ────────────────────────────────────────────────────
    @post "/chat/action" function (req::HTTP.Request)
        if !_llm_configured()
            return _json_resp(503, Dict(
                "error"          => "llm_not_configured",
                "message"        => "LLM is not configured. Tool calls require an active LLM setup.",
                "recovery_hint"  => "Check CHAT_LLM_API_KEY in server environment or secrets/openai_api_key.",
            ))
        end

        local parsed
        try
            parsed = JSON3.read(String(req.body))
        catch e
            return _json_bad(Dict(
                "error"   => "invalid_json",
                "message" => "Could not parse request body: $(sprint(showerror, e))",
            ))
        end

        tool = string(get(parsed, :tool, ""))
        if isempty(tool)
            return _json_bad(Dict("error" => "tool_required", "message" => "Specify a tool name in the 'tool' field."))
        end

        args_raw = get(parsed, :args, nothing)
        args = isnothing(args_raw) ?
            Dict{String, Any}() :
            Dict{String, Any}(string(k) => v for (k, v) in args_raw)

        client_gh = string(get(parsed, :client_geometry_hash, ""))
        if !isempty(client_gh)
            args["client_geometry_hash"] = client_gh
        end

        # When the client includes building_geometry, eagerly populate the
        # chat structure cache so geometry-dependent tools (get_geometry_digest,
        # get_situation_card, etc.) work without a prior POST /chat or /design.
        bg_raw = get(parsed, :building_geometry, get(parsed, "building_geometry", nothing))
        structured_geo = _parse_chat_building_geometry(bg_raw)
        if !isnothing(structured_geo)
            try
                _chat_get_structure_digest(structured_geo)
            catch e
                @warn "POST /chat/action: building_geometry structure init failed" exception=(e, catch_backtrace())
            end
        end

        t0     = time()
        result = try
            _dispatch_chat_tool(tool, args)
        catch e
            @error "POST /chat/action: tool execution failed" tool=tool exception=(e, catch_backtrace())
            Dict{String, Any}(
                "error"          => "tool_execution_failed",
                "tool"           => tool,
                "message"        => sprint(showerror, e),
                "recovery_hint"  => "Retry this tool call; if it persists, run GET /status and share this error.",
            )
        end
        _attach_geometry_alignment!(result, args)
        elapsed_ms = round(Int, (time() - t0) * 1000)

        result["_tool"]       = tool
        result["_elapsed_ms"] = elapsed_ms

        return _json_ok(result)
    end

    # ── GET /chat/history ────────────────────────────────────────────────────
    @get "/chat/history" function (req::HTTP.Request)
        session_id = _query_string(req, "session_id")
        if isnothing(session_id) || isempty(session_id)
            return _json_bad(Dict(
                "error"   => "session_id_required",
                "message" => "Provide a session_id query parameter.",
            ))
        end
        history = _get_history(session_id)
        return _json_ok(Dict(
            "session_id" => session_id,
            "messages"   => history,
            "count"      => length(history),
        ))
    end

    # ── DELETE /chat/history ─────────────────────────────────────────────────
    @delete "/chat/history" function (req::HTTP.Request)
        session_id = _query_string(req, "session_id")
        target = (isnothing(session_id) || isempty(session_id)) ? "all" : session_id
        _clear_history!(target)
        return _json_ok(Dict("status" => "ok", "cleared" => target))
    end

end
