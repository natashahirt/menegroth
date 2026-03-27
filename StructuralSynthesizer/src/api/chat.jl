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

# Server-side conversation history keyed by session_id (typically geometry hash).
const CHAT_HISTORY      = Dict{String, Vector{Dict{String, String}}}()
const CHAT_HISTORY_LOCK = ReentrantLock()
const CHAT_HISTORY_MAX_SESSIONS = 20  # evict LRU when cap reached
const CHAT_CLARIFICATION_KEYS = Dict{String, Set{String}}()

# Delimiters that the LLM is instructed to wrap its next-steps block in.
# Keep these unique enough that the LLM won't produce them accidentally.
const _SUGGESTIONS_START = "---NEXT QUESTIONS---"
const _SUGGESTIONS_END   = "---END---"
const _CLARIFY_START     = "---CLARIFY---"
const _CLARIFY_END       = "---END-CLARIFY---"

# ─── Token budget ─────────────────────────────────────────────────────────────

"""Approximate token count via character-length heuristic (1 token ≈ 4 chars)."""
_estimate_tokens(text::AbstractString) = cld(length(text), 4)

"""
    _budget_messages(system_prompt, messages, max_tokens) -> Vector

Fit the message history within the context budget, preserving the most recent
messages first. Older messages are dropped and replaced with a truncation marker.
"""
function _budget_messages(system_prompt::String, messages::Vector, max_tokens::Int)
    sys_tokens = _estimate_tokens(system_prompt)
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

# ─── Session history ──────────────────────────────────────────────────────────

"""Return a copy of stored messages for `session_id`, or an empty vector."""
function _get_history(session_id::String)
    lock(CHAT_HISTORY_LOCK) do
        copy(get(CHAT_HISTORY, session_id, Dict{String, String}[]))
    end
end

"""
    _append_history!(session_id, role, content)

Append one message to the session history. Evicts the oldest session when the
`CHAT_HISTORY_MAX_SESSIONS` cap is reached.
"""
function _append_history!(session_id::String, role::String, content::String)
    lock(CHAT_HISTORY_LOCK) do
        if !haskey(CHAT_HISTORY, session_id)
            if length(CHAT_HISTORY) >= CHAT_HISTORY_MAX_SESSIONS
                delete!(CHAT_HISTORY, first(keys(CHAT_HISTORY)))
            end
            CHAT_HISTORY[session_id] = Dict{String, String}[]
        end
        push!(CHAT_HISTORY[session_id], Dict("role" => role, "content" => content))
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

CLARIFICATION MODE (when key intent is missing):
If you need a constrained user choice, include a machine-readable clarification block:

$_CLARIFY_START
{"id":"short_key","prompt":"question text","options":[{"id":"opt_a","label":"Option A"},{"id":"opt_b","label":"Option B"}],"allow_multiple":false,"required_for":"decision this unblocks","rationale":"why this matters"}
$_CLARIFY_END

Rules:
- Emit at most ONE clarification block per response.
- Keep options to 2-4 concise choices.
- Use this only when user intent is genuinely ambiguous.

INTERPRETING CLARIFICATION RESPONSES:
When the user replies with a message prefixed `[CLARIFICATION_RESPONSE id=<key> options=<comma_ids>]`,
this is a structured answer to a previous clarification prompt you issued. The `id` matches the
clarification you sent, and `options` lists the selected option IDs. Treat the human-readable text
after the bracket as additional context. Incorporate the selection into your reasoning and proceed
— do NOT re-ask the same clarification.
"""

const _TOOLS_GUIDANCE = """

TOOLS — WHAT YOU CAN AND CANNOT DO:
You have access to structural tools via POST /chat/action. Use them to ground recommendations in computed results rather than estimates.

ORIENTATION (understand the building):
- get_situation_card: PREFERRED FIRST CALL. Single-call snapshot: geometry overview + resolved params + results health + session history + trace availability. Works even with no geometry/design (returns what's available).
- get_building_summary: Detailed geometry only (stories, spans, regularity). Use when you need more geometry detail than the situation card provides.
- get_current_params: Full resolved parameter set. Use when you need parameter detail beyond the situation card.
- get_design_history: Past designs in this session (params, pass/fail, critical ratio, EC). Prevents re-suggesting things already tried.

DIAGNOSIS (what's wrong and why — progressive disclosure):
- get_diagnose_summary: PREFERRED FIRST DIAGNOSTIC. Lightweight overview: counts by type, top-5 critical elements, failure breakdown by check. ~200 tokens.
- get_diagnose: FULL per-element diagnostics — governing checks, demand/capacity, code clauses, levers, embodied carbon, recommendations. Use after get_diagnose_summary when you need detail. Optional arg: units ("imperial"|"metric").
- query_elements: Filter elements by type, ratio range, governing_check, story, or pass/fail. Use to drill into specific failures.
- get_solver_trace: Tiered solver decision trace — WHY the solver chose sections, fell back, converged/diverged. Tiers: "summary" (pipeline overview), "failures" (default — all failures/fallbacks), "decisions" (+ iteration/decision detail), "full" (everything). Optional filters: element (e.g. "slab_2"), layer (e.g. "optimizer").
- get_lever_map: Which parameters/geometry changes affect a given failure check. ALWAYS consult before recommending a fix. Arg: check (e.g. "punching_shear", "deflection").
- get_implemented_provisions: List of all design code clauses the solver implements. Optional arg: code (e.g., "ACI_318").
- explain_field: Definition, units, valid values, and related checks for any API parameter. Arg: field (e.g., "deflection_limit").
- get_applicability: DDM/EFM/FEA eligibility rules for the current geometry.

EXPLORATION (what to try):
- run_experiment: INSTANT micro-experiment on a single element using cached data. Types: "punching" (vary column size/slab thickness), "pm_column" (try alt RC section), "deflection" (change limit), "catalog_screen" (screen multiple sizes). Much faster than run_design — use to narrow down options first.
- list_experiments: See available experiment types and their argument schemas.
- batch_experiments: Run multiple experiments in one call (e.g. screen 5 column sizes).
- validate_params: Check a params patch for compatibility violations. Fast, no geometry needed. Always call this before run_design.
- run_design: FAST PARAMETER-ONLY what-if check (skips visualization, max 2 iterations, 20 s MIP cap, 60 s total timeout). Use after narrowing with experiments.
- compare_designs: Delta table between two designs from history (pass/fail, ratios, EC, changed governing checks). Args: index_a, index_b.
- suggest_next_action: Ranked parameter changes for a goal. Arg: goal ("fix_failures"|"reduce_column_size"|"reduce_slab_thickness"|"reduce_ec").

COMMUNICATION (explain to the user):
- narrate_element: Plain-English explanation of one element's design. Args: element_type, element_id, audience ("architect"|"engineer"|"custom").
- narrate_comparison: Plain-English comparison of two designs. Args: index_a, index_b, audience ("architect"|"engineer"|"custom").
- get_result_summary: Per-element JSON summary (check ratios, sections, failures).
- get_condensed_result: ~500-token plain-text result summary.
- clarify_user_intent: Structured multiple-choice clarification payload for the UI.

TOOL SELECTION POLICY — match user intent to tool sequence:
  START OF CONVERSATION            -> get_situation_card (always, before anything else)
  "What is this building?"         -> get_situation_card covers this; get_building_summary if more detail needed
  "Why is element X failing?"      -> get_diagnose_summary → query_elements(ok=false) → narrate_element
  "Why did the solver pick that?"  -> get_solver_trace(tier=failures), drill with tier=decisions or element filter
  "What should I change?"          -> get_diagnose_summary → suggest_next_action(goal) → validate_params
  "Would a bigger column help?"   -> run_experiment(type=punching or pm_column) for instant check
  "Try changing X"                 -> run_experiment first to preview → validate_params → run_design → compare_designs
  "Explain this to me"             -> narrate_element or narrate_comparison
  "Did it help?" / "Compare"       -> compare_designs + get_design_history
  "Does the solver check X?"       -> get_implemented_provisions
  "What does parameter Y do?"      -> explain_field(Y)
  Always start with get_situation_card. Then get_diagnose_summary for failure overview.
  Use get_diagnose or query_elements only when you need specific element detail.
  Use get_solver_trace when the user needs to understand WHY, not just WHAT.
  Always validate_params before run_design. Always compare_designs after run_design.
  After each design iteration, use record_insight to capture what you learned.
  Before making recommendations, check get_session_insights for accumulated learnings.

EVIDENCE-FIRST REASONING:
Before making any recommendation, you MUST have tool evidence. Follow this protocol:
  1. OBSERVE: Call a diagnostic tool (get_diagnose_summary, query_elements, get_solver_trace) to get data.
  2. CITE: Reference specific ratios, check names, or trace events in your explanation.
  3. CONSULT LEVERS: Call get_lever_map(check=<governing_check>) to see which parameters actually affect this failure.
  4. RECOMMEND: Suggest a parameter change from the lever map, grounded in the evidence.
  5. VERIFY: Use validate_params → run_design → compare_designs to confirm.
  NEVER skip steps 1–3 and jump to recommendations based on general structural knowledge.
  If you catch yourself saying "typically" or "usually" without citing a tool result, stop and call a tool first.

EPISTEMIC BOUNDARY — WHAT YOU KNOW AND DO NOT KNOW:
You do NOT have direct access to ACI 318, AISC 360, ASCE 7, IBC, or any building-code text.
All code-based logic is implemented inside the deterministic structural solver.
Your role is to INTERPRET and COMMUNICATE solver outputs, not to independently derive or cite code provisions.

When referencing a code check:
  1. If a tool result includes a code_clause field, quote it verbatim (e.g., "The solver reports this check per ACI 318-19 §22.4.2").
  2. If a tool result includes a limit_state_description, use that text.
  3. Otherwise, say "the solver applies [check name] per the relevant code provision" — do NOT invent a section number.
  4. NEVER fabricate equations, load-combination formulas, or clause numbers.
  5. Use get_implemented_provisions to check whether a specific code clause is implemented before claiming it is or is not.
  6. If the user asks for code-text knowledge you do not have, say so and suggest consulting the standard directly.

SOLVER SCOPE LIMITS — WHAT THE SYSTEM CANNOT DO:
The solver has specific boundaries. Do NOT suggest actions outside these:
  ✗ Lateral load analysis (wind, seismic) — gravity framing only in current version.
  ✗ Connection design — member sizing only; no bolted/welded joint checks.
  ✗ Progressive collapse or blast loading.
  ✗ Serviceability vibration checks (walking, rhythmic).
  ✗ Pre/post-tensioned concrete — mild reinforcement only.
  ✗ Composite steel deck slabs — concrete flat plate/flat slab/one-way/vault only.
  ✗ Timber or masonry structural systems.
  ✗ Geometry modification — column positions, spans, story heights are set in Grasshopper.
  ✗ Multi-objective Pareto optimization — single objective (weight, carbon, or cost).
  ✗ Non-rectangular column grids for DDM/EFM — use FEA for irregular layouts.
  If the user asks about any of these, clearly state it is outside the current solver scope.

CRITICAL CONSTRAINT — GEOMETRY VS. PARAMETERS:
The system has two completely separate layers:
  1. GEOMETRY (Grasshopper/Rhino): column positions, bay spans, story heights, plan shape, number of columns — these are defined in the CAD model and CANNOT be changed via run_design or any API call.
  2. PARAMETERS (API): floor system type, analysis method, material specs, loads, sizing strategy, iteration limits — these CAN be changed via run_design.

When you recommend a GEOMETRIC change (e.g., "add columns", "reduce column spacing", "shorten spans", "change story height", "add a shear wall"), you MUST:
  1. Clearly tell the user it is a geometry change.
  2. Explain exactly what to change in the Grasshopper model (which GeometryInput parameter, which Rhino element, etc.).
  3. Do NOT call run_design with geometric keys — it will be rejected.

When you recommend a PARAMETER change (floor_type, column_type, analysis method, loads, etc.), you MAY call run_design to show a quick result. Always validate_params first.
"""

const _DESIGN_SYSTEM_PREAMBLE = """
You are a structural engineering design assistant for the Menegroth automated design system.
Your role is to help the user choose appropriate design parameters for their building.

IMPORTANT RULES:
- All code provisions (ACI 318, AISC 360, ASCE 7) are enforced by the solver — rely on tool outputs for code-level detail. Do not invent or cite specific code clauses unless a tool result provides them.
- If you are uncertain about a parameter, ask the user a clarifying question.
- When recommending parameter changes, output a JSON code block with only the changed fields.
- Explain your reasoning by referencing solver results (check ratios, governing checks, code_clause fields). If no tool output covers the point, say so rather than guessing.
- Ask guiding questions to understand the project: occupancy, spans, desired aesthetics, sustainability goals.

GEOMETRY AND IRREGULARITY:
- The building geometry may be irregular: L-shaped plans, setbacks, varying story heights, non-rectangular bays, free-form column layouts, mixed panel shapes.
- Do NOT assume a rectangular plan or uniform grid. Read the geometry summary carefully.
- If the geometry summary indicates irregularity (varying plan extents, non-rectangular grid, triangular panels, varying member counts per level), factor this into every recommendation.
- Irregular geometries may require special attention to: torsional effects, transfer beams at setbacks, varying slab panel sizes, column load redistribution, and diaphragm continuity.
- When span lengths are highly variable (high CV), a single floor_type may not be optimal for all bays — note this to the user.
- For non-rectangular column layouts, closest-spacing values are more meaningful than gridline spacings.
$_TOOLS_GUIDANCE
$_CLARIFICATION_INSTRUCTION
$_NEXT_QUESTIONS_INSTRUCTION

KEY PARAMETERS (use explain_field for full detail on any parameter):
  floor_type:        flat_plate | flat_slab | one_way | vault — controls floor system, biggest design lever
  column_type:       rc_rect | rc_circular | steel_w | steel_hss | pixelframe
  beam_type:         steel_w | rc_rect | rc_tbeam | steel_hss | pixelframe
  method:            DDM | DDM_SIMPLIFIED | EFM | EFM_HARDY_CROSS | FEA — analysis method for slab design
  deflection_limit:  L_240 | L_360 | L_480 — stricter limit → thicker slabs
  punching_strategy: grow_columns | reinforce_first | reinforce_last — how punching shear failures are resolved
  loads:             floor_LL_psf, roof_LL_psf, floor_SDL_psf, roof_SDL_psf, wall_SDL_psf
  materials:         concrete, column_concrete, rebar, steel — material grades
  column_catalog:    controls available section pool for column optimizer
  optimize_for:      weight | carbon | cost — optimization objective
  fire_rating:       0 | 1 | 1.5 | 2 | 3 | 4 hours — affects cover, thickness, fire protection
  size_foundations:   true/false — enable foundation sizing
"""

const _RESULTS_SYSTEM_PREAMBLE = """
You are a structural engineering results analyst for the Menegroth automated design system.
Your role is to help the user understand their building's design results.

IMPORTANT RULES:
- Explain structural engineering concepts clearly for the user's level of expertise.
- Reference specific check ratios, element IDs, and failure modes from the results data.
- If a check fails, explain what it means physically and suggest parameter changes that might help.
- Code provisions are enforced by the solver — quote code_clause and limit_state_description fields from results rather than inventing clause numbers or formulas.
- When suggesting parameter changes, output a JSON code block with only the changed fields.

GEOMETRY AND IRREGULARITY:
- The building geometry may be irregular. Read the geometry summary carefully — do not assume a simple rectangular plan.
- Irregular geometries often cause localized failures: re-entrant corners concentrate stress, setbacks create load-path discontinuities, non-uniform bays produce uneven demand-capacity ratios.
- When discussing failing elements, correlate their location with geometry features (e.g., "this column is at a setback transition" or "this beam spans a non-rectangular bay").
- If member counts vary by level, there may be transfer conditions — flag these as critical.
$_TOOLS_GUIDANCE
$_CLARIFICATION_INSTRUCTION
$_NEXT_QUESTIONS_INSTRUCTION
DESIGN RESULTS SUMMARY:
"""

function _build_system_prompt(mode::String, params_json, geometry_summary::String)
    if mode == "design"
        parts = [_DESIGN_SYSTEM_PREAMBLE]
        if !isempty(geometry_summary)
            push!(parts, "\n\nBUILDING GEOMETRY:\n", geometry_summary)
        end
        if !isnothing(params_json) && !isempty(string(params_json))
            push!(parts, "\n\nCURRENT PARAMETERS:\n", JSON3.write(params_json))
        end
        if !isnothing(DESIGN_CACHE.last_design)
            push!(parts, "\n\nLATEST RESULTS SUMMARY:\n", condense_result(DESIGN_CACHE.last_design))
        end
        return join(parts)
    elseif mode == "results"
        parts = [_RESULTS_SYSTEM_PREAMBLE]
        if !isnothing(DESIGN_CACHE.last_design)
            push!(parts, condense_result(DESIGN_CACHE.last_design))
            push!(parts, "\n\nDETAILED RESULTS:\n", JSON3.write(report_summary_json(DESIGN_CACHE.last_design)))
        end
        if !isempty(geometry_summary)
            push!(parts, "\n\nBUILDING GEOMETRY:\n", geometry_summary)
        end
        if !isnothing(params_json) && !isempty(string(params_json))
            push!(parts, "\n\nDESIGN PARAMETERS:\n", JSON3.write(params_json))
        end
        return join(parts)
    else
        return "You are a helpful structural engineering assistant."
    end
end

# ─── Suggestions extraction ───────────────────────────────────────────────────

"""
    _extract_suggestions(full_text) -> Vector{String}

Parse bullet items from the `$_SUGGESTIONS_START` … `$_SUGGESTIONS_END` block
embedded in `full_text`. Returns an empty vector if the block is absent or
malformed.
"""
function _extract_suggestions(full_text::String)::Vector{String}
    start_idx = findfirst(_SUGGESTIONS_START, full_text)
    isnothing(start_idx) && return String[]
    end_idx = findfirst(_SUGGESTIONS_END, full_text)
    isnothing(end_idx) && return String[]

    block_start = last(start_idx) + 1
    block_end   = first(end_idx) - 1
    block_start > block_end && return String[]

    block = full_text[block_start:block_end]
    suggestions = String[]
    for line in split(block, '\n')
        s = strip(line)
        isempty(s) && continue
        if startswith(s, "•") || startswith(s, "-") || startswith(s, "*")
            item = strip(lstrip(s, ['•', '-', '*', ' ']))
            isempty(item) || push!(suggestions, item)
        end
    end
    return suggestions
end

"""
    _extract_clarification_prompt(full_text) -> Union{Dict{String, Any}, Nothing}

Parse a JSON clarification payload from the `$_CLARIFY_START` ... `$_CLARIFY_END`
block. Returns `nothing` when absent or malformed.
"""
function _extract_clarification_prompt(full_text::String)::Union{Dict{String, Any}, Nothing}
    start_idx = findfirst(_CLARIFY_START, full_text)
    isnothing(start_idx) && return nothing
    end_idx = findfirst(_CLARIFY_END, full_text)
    isnothing(end_idx) && return nothing

    block_start = last(start_idx) + 1
    block_end   = first(end_idx) - 1
    block_start > block_end && return nothing

    payload = strip(full_text[block_start:block_end])
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
    _build_turn_summary(; suggestions, clarification_data, tool_actions) -> Dict

Canonical turn-summary event.  Guarantees `suggested_next_questions` is always
present (empty array when absent) and `clarification_prompt` is either a valid
dict or `nothing`.  `tool_actions` is an optional array of tool-action records.
"""
function _build_turn_summary(;
    suggestions::Vector{String}         = String[],
    clarification_data                  = nothing,
    tool_actions::Vector{Dict{String,Any}} = Dict{String,Any}[],
)::Dict{String, Any}
    summary = Dict{String, Any}(
        "type"                     => "agent_turn_summary",
        "suggested_next_questions" => suggestions,
        "clarification_prompt"     => _normalize_clarification(clarification_data),
    )
    if !isempty(tool_actions)
        summary["tool_actions"] = tool_actions
    end
    return summary
end

# ─── LLM streaming client ────────────────────────────────────────────────────

const MAX_AGENT_TOOL_ROUNDS = 4

"""Read dictionary values by string/symbol key with fallback."""
function _dict_get(d, key::String, default=nothing)
    if d isa AbstractDict
        haskey(d, key) && return d[key]
        sym = Symbol(key)
        haskey(d, sym) && return d[sym]
    end
    return default
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

    if base_type == "array" && !haskey(schema, "items")
        schema["items"] = Dict{String, Any}("type" => "string")
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
        desc = string(get(entry, "description", ""))
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
                        _dispatch_chat_tool(tool_name, args_dict)
                    end
                    elapsed_ms = round(Int, (time() - t0) * 1000)

                    push!(tool_actions, Dict{String, Any}(
                        "tool" => tool_name,
                        "status" => haskey(result, "error") ? "error" : "ok",
                        "elapsed_ms" => elapsed_ms,
                        "summary" => _tool_action_summary(result),
                    ))

                    push!(tool_results, Dict{String, Any}(
                        "role" => "tool",
                        "tool_call_id" => call_id,
                        "content" => JSON3.write(result),
                    ))
                end

                push!(conversation, Dict{String, Any}(
                    "role" => "assistant",
                    "content" => assistant_content,
                    "tool_calls" => assistant_tool_calls,
                ))
                append!(conversation, tool_results)
                continue
            end

            full_text = assistant_content
            break
        end

        if isempty(full_text) && !isempty(tool_actions)
            full_text = "I executed the requested tool calls but did not receive a final response message. Please retry."
        end

        if !isempty(full_text)
            write(stream, "data: $(JSON3.write(Dict("token" => full_text)))\n\n")
        end

        suggestions        = _extract_suggestions(full_text)
        clarification_data = _extract_clarification_prompt(full_text)

        # Persist assistant turn to server-side history.
        if !isempty(session_id) && !isempty(full_text)
            _append_history!(session_id, "assistant", full_text)
        end

        summary = _build_turn_summary(;
            suggestions        = suggestions,
            clarification_data = clarification_data,
            tool_actions       = tool_actions,
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
- `run_experiment`           — instant micro-experiment on a single element (punching, P-M, deflection, catalog screen).
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
const _NO_DESIGN_HINT   = "Run a design from Grasshopper before opening Results Assistant."
const _NO_GEOMETRY_HINT = "Submit geometry via the GeometryInput component first."

function _dispatch_chat_tool(tool::String, args::Dict{String, Any})::Dict{String, Any}
    if tool == "get_result_summary"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return report_summary_json(DESIGN_CACHE.last_design)

    elseif tool == "get_condensed_result"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return Dict("text" => condense_result(DESIGN_CACHE.last_design))

    elseif tool == "get_applicability"
        return api_applicability_schema()

    elseif tool == "clarify_user_intent"
        clarification_id = string(get(args, "id", ""))
        prompt_text      = string(get(args, "prompt", ""))
        allow_multiple   = Bool(get(args, "allow_multiple", false))
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
        didx = Int(get(args, "design_index", 0))
        conf = Float64(get(args, "confidence", 0.5))

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
        min_conf = Float64(get(args, "min_confidence", 0.0))

        insights = get_session_insights(; category=cat, check=check, param=param, min_confidence=min_conf)
        return Dict{String, Any}(
            "n_insights" => length(insights),
            "insights" => session_insights_to_json(insights),
            "note" => isempty(insights) ? "No insights recorded yet. Use record_insight after observing design outcomes." : nothing,
        )

    # ── Phase 1: Orientation ────────────────────────────────────────────────
    elseif tool == "get_situation_card"
        return agent_situation_card(DESIGN_CACHE.structure, DESIGN_CACHE.last_design, get_design_history_entries())

    elseif tool == "get_building_summary"
        isnothing(DESIGN_CACHE.structure) && return Dict("error" => "no_geometry", "message" => "No geometry loaded. Submit geometry via POST /design first.", "recovery_hint" => _NO_GEOMETRY_HINT)
        return agent_building_summary(DESIGN_CACHE.structure)

    elseif tool == "get_current_params"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return agent_current_params(DESIGN_CACHE.last_design)

    elseif tool == "get_design_history"
        entries = get_design_history_entries()
        isempty(entries) && return Dict("history" => [], "message" => "No designs in session history yet.")
        return Dict("history" => design_history_to_json(entries), "count" => length(entries))

    # ── Phase 2: Diagnosis ───────────────────────────────────────────────────
    elseif tool == "get_diagnose_summary"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return agent_diagnose_summary(DESIGN_CACHE.last_design)

    elseif tool == "get_diagnose"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        units_arg = get(args, "units", nothing)
        report_units = isnothing(units_arg) ? nothing : Symbol(units_arg)
        return design_to_diagnose(DESIGN_CACHE.last_design; report_units=report_units)

    elseif tool == "query_elements"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return agent_query_elements(DESIGN_CACHE.last_design;
            type             = get(args, "type", nothing),
            min_ratio        = let v = get(args, "min_ratio", nothing); isnothing(v) ? nothing : Float64(v) end,
            max_ratio        = let v = get(args, "max_ratio", nothing); isnothing(v) ? nothing : Float64(v) end,
            governing_check  = get(args, "governing_check", nothing),
            ok               = let v = get(args, "ok", nothing); isnothing(v) ? nothing : Bool(v) end,
        )

    elseif tool == "get_solver_trace"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        tier_arg    = get(args, "tier", "failures")
        element_arg = get(args, "element", nothing)
        layer_arg   = get(args, "layer", nothing)
        tier_sym    = Symbol(tier_arg)
        layer_sym   = isnothing(layer_arg) ? nothing : Symbol(layer_arg)
        return agent_solver_trace(DESIGN_CACHE.last_design;
            tier    = tier_sym,
            element = isnothing(element_arg) ? nothing : string(element_arg),
            layer   = layer_sym,
        )

    elseif tool == "explain_trace_lookup"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        lookup_raw = get(args, "lookup", nothing)
        isnothing(lookup_raw) && return Dict("error" => "missing_lookup", "message" => "Provide a 'lookup' object from a breadcrumb bundle (top_elements[].lookup).")
        lookup = lookup_raw isa AbstractDict ? Dict{String, Any}(string(k) => v for (k, v) in lookup_raw) :
                 Dict{String, Any}("raw" => lookup_raw)
        return agent_explain_trace_lookup(DESIGN_CACHE.last_design; lookup=lookup)

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

    # ── Phase 3: Exploration ─────────────────────────────────────────────────
    elseif tool == "compare_designs"
        idx_a = get(args, "index_a", nothing)
        idx_b = get(args, "index_b", nothing)
        (isnothing(idx_a) || isnothing(idx_b)) && return Dict("error" => "missing_args", "message" => "Provide index_a and index_b (1-based history index, or 0 for current).")
        return agent_compare_designs(Int(idx_a), Int(idx_b))

    elseif tool == "suggest_next_action"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        goal = get(args, "goal", nothing)
        isnothing(goal) && return Dict("error" => "missing_goal", "message" => "Provide a 'goal' argument (fix_failures, reduce_column_size, reduce_slab_thickness, reduce_ec).")
        return agent_suggest_next_action(DESIGN_CACHE.last_design, string(goal))

    elseif tool == "run_experiment"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        exp_type = get(args, "type", nothing)
        exp_args = get(args, "args", Dict{String, Any}())
        isnothing(exp_type) && return Dict("error" => "missing_type", "message" => "Provide experiment 'type' (punching, pm_column, deflection, catalog_screen).")
        exp_args_dict = Dict{String, Any}(string(k) => v for (k, v) in exp_args)
        return evaluate_experiment(DESIGN_CACHE.last_design, string(exp_type), exp_args_dict)

    elseif tool == "list_experiments"
        return list_experiments()

    elseif tool == "batch_experiments"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        experiments_raw = get(args, "experiments", Any[])
        experiments = [Dict{String, Any}(string(k) => v for (k, v) in e) for e in experiments_raw]
        return batch_evaluate(DESIGN_CACHE.last_design, experiments)

    # ── Phase 4: Communication ───────────────────────────────────────────────
    elseif tool == "narrate_element"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        etype    = get(args, "element_type", nothing)
        eid      = get(args, "element_id", nothing)
        audience = get(args, "audience", "architect")
        (isnothing(etype) || isnothing(eid)) && return Dict("error" => "missing_args", "message" => "Provide element_type and element_id.")
        return agent_narrate_element(DESIGN_CACHE.last_design, string(etype), Int(eid), string(audience))

    elseif tool == "narrate_comparison"
        idx_a    = get(args, "index_a", nothing)
        idx_b    = get(args, "index_b", nothing)
        audience = get(args, "audience", "architect")
        (isnothing(idx_a) || isnothing(idx_b)) && return Dict("error" => "missing_args", "message" => "Provide index_a and index_b.")
        return agent_narrate_comparison(Int(idx_a), Int(idx_b), string(audience))

    # ── Original tools ───────────────────────────────────────────────────────
    elseif tool == "validate_params"
        # Validate a params patch against the compatibility rules in the schema
        # without requiring a full geometry input.
        schema_rules = get(get(api_applicability_schema(), "rules", Dict()), "floor_type", Dict())
        compat = get(schema_rules, "compatibility_checks", Dict())
        rules  = get(compat, "rules", Any[])

        param_patch  = Dict{String, Any}(string(k) => v for (k, v) in get(args, "params", Dict()))
        floor_type   = get(param_patch, "floor_type", nothing)
        column_type  = get(param_patch, "column_type", nothing)
        beam_type    = get(param_patch, "beam_type", nothing)

        violations = String[]
        for rule in rules
            when_clause = get(rule, "when", Dict())
            rejects     = get(rule, "rejects", Dict())

            # Determine whether the rule's "when" condition is active.
            when_floor = get(when_clause, "floor_type", nothing)
            active = false
            if !isnothing(when_floor) && !isnothing(floor_type)
                active = when_floor isa Vector ? floor_type in when_floor : floor_type == when_floor
            end
            active || continue

            reject_cols  = get(rejects, "column_type", String[])
            reject_beams = get(rejects, "beam_type",   String[])
            rule_id      = get(rule, "id", "rule")

            if !isnothing(column_type) && column_type in reject_cols
                push!(violations, "$rule_id: column_type \"$column_type\" is incompatible with floor_type \"$floor_type\"")
            end
            if !isnothing(beam_type) && beam_type in reject_beams
                push!(violations, "$rule_id: beam_type \"$beam_type\" is incompatible with floor_type \"$floor_type\"")
            end
        end
        return Dict("ok" => isempty(violations), "violations" => violations)

    elseif tool == "run_design"
        # ── Guard: server state ──────────────────────────────────────────────
        if status_string(SERVER_STATUS) != "idle"
            return Dict(
                "error"          => "server_busy",
                "message"        => "A design is already running. Wait until the server is idle, then retry.",
                "recovery_hint"  => "Wait for the current design to finish, then retry.",
            )
        end
        isnothing(DESIGN_CACHE.structure) && return Dict(
            "error"          => "no_geometry",
            "message"        => "No geometry loaded. Submit geometry via POST /design first.",
            "recovery_hint"  => _NO_GEOMETRY_HINT,
        )

        param_patch_raw = get(args, "params", nothing)
        isnothing(param_patch_raw) && return Dict(
            "error"   => "params_required",
            "message" => "Provide the parameter patch in args.params.",
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
        fast_patch["max_iterations"]      = min(get(fast_patch, "max_iterations", 20), 2)
        fast_patch["mip_time_limit_sec"]  = min(get(fast_patch, "mip_time_limit_sec", 30.0), 20.0)

        # ── Acquire server lock ──────────────────────────────────────────────
        if !try_start!(SERVER_STATUS)
            return Dict("error" => "server_busy", "message" => "Server became busy — retry in a moment.", "recovery_hint" => "Wait for the current design to finish, then retry.")
        end

        # ── Parse params ─────────────────────────────────────────────────────
        local fast_params
        try
            api_params = JSON3.read(JSON3.write(fast_patch), APIParams)
            fast_params = json_to_params(api_params, "feet")
        catch e
            finish!(SERVER_STATUS)
            return Dict("error" => "param_parse_failed", "message" => sprint(showerror, e))
        end

        # ── Run design with timeout ──────────────────────────────────────────
        # The async task always calls finish!() in its finally block, so the
        # server returns to idle even if we time out and return early here.
        result_ref = Ref{Any}(nothing)
        error_ref  = Ref{Any}(nothing)

        design_task = @async begin
            try
                d = design_building(DESIGN_CACHE.structure, fast_params)
                DESIGN_CACHE.last_design = d
                DESIGN_CACHE.last_result = design_to_json(d; geometry_hash=DESIGN_CACHE.geometry_hash)
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

        return Dict(
            "ok"               => true,
            "quick_check"      => true,
            "applied_params"   => api_keys,
            "summary"          => condense_result(design),
            "all_pass"         => design.summary.all_checks_pass,
            "critical_element" => design.summary.critical_element,
            "critical_ratio"   => design.summary.critical_ratio,
            "warnings"         => warnings,
            "note"             => "Quick-check result: visualization skipped, max 2 sizing iterations, MIP capped at 20s. " *
                "Ratios may shift slightly in a full run. The canvas will update on next Grasshopper solve.",
        )

    else
        return Dict(
            "error"   => "unknown_tool",
            "message" => "Unknown tool: \"$tool\". Available: " *
                "get_situation_card, get_building_summary, get_design_history, get_current_params, " *
                "get_diagnose_summary, get_diagnose, query_elements, get_solver_trace, " *
                "get_lever_map, get_implemented_provisions, explain_field, " *
                "get_result_summary, get_condensed_result, get_applicability, " *
                "run_experiment, list_experiments, batch_experiments, " *
                "validate_params, run_design, compare_designs, suggest_next_action, " *
                "record_insight, get_session_insights, " *
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

        if mode == "results" && isnothing(DESIGN_CACHE.last_design)
            HTTP.setstatus(stream, 404)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            startwrite(stream)
            write(stream, JSON3.write(Dict(
                "error"          => "no_design",
                "message"        => "No design results available. Run a design first.",
                "recovery_hint"  => "Run a design from Grasshopper before opening Results Assistant.",
            )))
            return
        end

        params_json      = get(parsed, :params, nothing)
        geometry_summary = string(get(parsed, :geometry_summary, ""))
        session_id       = string(get(parsed, :session_id, ""))

        # Persist the latest user message to server-side history.
        if !isempty(session_id) && !isempty(messages)
            last_msg = messages[end]
            role    = string(get(last_msg, "role",    get(last_msg, :role,    "user")))
            content = string(get(last_msg, "content", get(last_msg, :content, "")))
            _append_history!(session_id, role, content)
        end

        system_prompt = _build_system_prompt(mode, params_json, geometry_summary)
        budgeted      = _budget_messages(system_prompt, messages, MAX_CONTEXT_TOKENS)

        HTTP.setstatus(stream, 200)
        HTTP.setheader(stream, "Content-Type"  => "text/event-stream")
        HTTP.setheader(stream, "Cache-Control" => "no-cache")
        HTTP.setheader(stream, "Connection"    => "keep-alive")
        startwrite(stream)

        _stream_llm_to_sse(stream, system_prompt, budgeted; session_id=session_id)
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

        t0     = time()
        result = _dispatch_chat_tool(tool, args)
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
