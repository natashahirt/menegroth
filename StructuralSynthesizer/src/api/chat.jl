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

TOOLS (descriptions in tool specs — consult use_when for details):
  Orient:      get_situation_card (FIRST), get_building_summary, get_current_params, get_design_history
  Diagnose:    get_diagnose_summary (FIRST), get_diagnose, query_elements, get_solver_trace, get_lever_map
  Explore:     run_experiment (FAST), validate_params → run_design, compare_designs, suggest_next_action
  Communicate: narrate_element, narrate_comparison, get_result_summary, get_condensed_result, clarify_user_intent
  Reference:   explain_field, get_implemented_provisions, get_applicability, get_provision_rationale
  Memory:      record_insight (after every design), get_session_insights (before recommending)
  Experiments: list_experiments, batch_experiments

TOOL SELECTION (match intent → sequence):
  Start of conversation     → get_situation_card; if no design yet → baseline per BASELINE DESIGN block
  "Why is X failing?"       → get_diagnose_summary → get_provision_rationale(governing_check) → narrate_element
  "What should I change?"   → get_diagnose_summary → suggest_next_action → validate_params
  "Would bigger col help?"  → run_experiment(punching/pm_column)
  "Try changing X"          → run_experiment → validate_params → run_design → compare_designs (if ≥2 designs)
  "Explain this"            → narrate_element / narrate_comparison
  "Compare" / "Did it help?"→ compare_designs + get_design_history
  "What does X do?"         → explain_field(X) — returns schema + rationale + related structural checks
  "Why does the code say…?" → get_provision_rationale(section_or_check) — mechanism, philosophy, misconceptions
  Always: validate_params before run_design. record_insight after each design. get_session_insights before recommending.

CLIENT GEOMETRY VS SERVER TOOLS:
  POST /chat may include building_geometry JSON and/or geometry_summary narrative — use them.
  get_situation_card.has_geometry only reflects server cache from POST /design, NOT prompt geometry.
  For span_stats, slab_panel_plan, member counts: server cache needed → suggest Design run.

EVIDENCE-FIRST PROTOCOL (mandatory):
  1. OBSERVE — call a diagnostic tool (get_diagnose_summary, query_elements, get_solver_trace).
  2. CITE — reference specific ratios, check names, trace events.
  3. CONSULT — get_lever_map(check=<governing_check>) for actionable parameters.
  4. RECOMMEND — grounded in evidence from steps 1–3.
  5. VERIFY — validate_params → run_design → compare_designs.
  NEVER skip 1–3 for numerical claims. If no design exists, discuss qualitatively only.

GEOMETRY VS PARAMETERS (mandatory):
  GEOMETRY (Grasshopper): column positions, spans, story heights, plan shape — CANNOT change via API.
  PARAMETERS (API): floor_type, materials, loads, method, sizing — CAN change via run_design.
  Geometric recommendations → tell user what to change in Grasshopper; do NOT call run_design with geometric keys.

GEOMETRY HASH / STALE CACHE:
  If GEOMETRY_CONTEXT.geometry_stale is true, cached tools describe the last solved model, not current geometry.
  Explain directional effects qualitatively; do NOT invent numerical results for unsolved geometry.
  get_design_history is valid: entries include geometry_hash for cross-geometry awareness.

EPISTEMIC BOUNDARY:
  You lack direct code text (ACI, AISC, ASCE 7). All code logic is in the solver.
  Quote code_clause / limit_state_description from tool results. Do NOT invent section numbers or formulas.
  Use get_implemented_provisions to check code coverage. If unsure, say so.

SCOPE LIMITS — the solver CANNOT:
  ✗ Lateral/seismic analysis (gravity only)  ✗ Connection design  ✗ Progressive collapse/blast
  ✗ Vibration serviceability  ✗ PT concrete  ✗ Composite deck slabs  ✗ Timber/masonry
  ✗ Geometry modification  ✗ Multi-objective Pareto  ✗ Non-rectangular grids for DDM/EFM (use FEA)
"""

# Appended to both design and results preambles — prevents fabricated "reduced from X to Y" when no prior design exists in session.
const _SESSION_DESIGN_HISTORY_RULE = """
SESSION HISTORY (no fabricated before/after):
- NEVER say "reduced from X to Y" or "improved vs baseline" unless get_design_history has ≥2 entries or compare_designs was called with valid indices.
- n_designs=0|1 → report absolute metrics only; no comparison language.
- Entries include geometry_hash. Prefer same-hash comparisons; flag cross_geometry_comparison explicitly.
- Stale geometry → cached diagnostics describe last solved model, not current geometry.
"""

# Design mode only — establishes a real baseline before iteration language.
const _DESIGN_MODE_BASELINE_WORKFLOW = """
BASELINE DESIGN:
- No design yet (n_designs=0) → no solver ratios/EC to cite. Use prompt geometry qualitatively.
- BUILDING GEOMETRY in the prompt (JSON/narrative) = user's model. Do NOT say you "cannot see" it.
  Server-side analytics (slab_panel_plan, member counts) require POST /design.
- Valid params → either run_design for baseline, or ask user first.
- Once n_designs≥1, use compare_designs when can_compare_deltas is true.
"""

const _DESIGN_SYSTEM_PREAMBLE = """
You are a structural engineering design assistant for the Menegroth automated design system.
Your role is to help the user choose appropriate design parameters for their building.

GEOMETRY IN THE PROMPT:
- When BUILDING GEOMETRY appears below, the client may send (1) structured `building_geometry` JSON — same schema as Design Run geometry (vertices, edges, supports, faces, units), plus (2) optional `geometry_summary` narrative. Parse and reason over the structured fields when present; use the narrative as a supplement. This is separate from get_situation_card.has_geometry, which only reflects whether the server has ingested the model via POST /design.

IMPORTANT RULES:
- All code provisions (ACI 318, AISC 360, ASCE 7) are enforced by the solver — rely on tool outputs for code-level detail. Do not invent or cite specific code clauses unless a tool result provides them.
- If you are uncertain about a parameter, ask the user a clarifying question.
- When recommending parameter changes, output a JSON code block with only the changed fields.
- In that same JSON object, always include a top-level string field `_history_label` (exact key) with a VERY brief label (≤6 words, no quotes/newlines) summarizing the change for the Grasshopper params history list (e.g. `"_history_label": "Increase floor live load"`). It is metadata only — not a structural parameter.
- Explain your reasoning by referencing solver results (check ratios, governing checks, code_clause fields). If no tool output covers the point, say so rather than guessing.
- Ask guiding questions to understand the project: occupancy, spans, desired aesthetics, sustainability goals.

$_DESIGN_MODE_BASELINE_WORKFLOW

GEOMETRY AND IRREGULARITY:
- True plan irregularity (setbacks, re-entrant corners, non-orthogonal grids, free-form columns) must be inferred from geometry cues: vertical regularity lines, grid-pattern / column-position section, floor panel shapes (quads vs triangles), and tool outputs — NOT from span-length CV alone.
- Span CV in summaries aggregates ALL beam edge lengths (X-oriented, Y-oriented, etc.). Different bay sizes in X vs Y produce a high CV even on a perfectly rectangular orthogonal grid — that is normal, not "irregular spans."
- Do NOT claim torsional effects or "irregular geometry" from beam span variability or span_stats.cv alone. get_building_summary includes slab_panel_plan (slab face outlines in plan): use plan_shape_classification and quad corner deviation from 90° to distinguish non-orthogonal/skewed panels from an orthogonal grid with different X vs Y bay sizes. Read span_cv_note; use get_applicability (and DDM/EFM applicability rules) when discussing whether the slab method fits the actual grid and panels.
- When story heights vary significantly, the geometry summary flags vertical irregularity — that is separate from plan regularity.
- For non-rectangular column layouts, closest-spacing values are more meaningful than gridline spacings.
$_TOOLS_GUIDANCE
$_SESSION_DESIGN_HISTORY_RULE
$_CLARIFICATION_INSTRUCTION
$_NEXT_QUESTIONS_INSTRUCTION

KEY PARAMETERS (use explain_field for full detail on any parameter):
  floor_type:        flat_plate | flat_slab | one_way | vault — biggest system lever. flat_plate vs flat_slab: same two-way slab pipeline (DDM/EFM/FEA from method); flat_slab adds solver-built drop panels at columns (extra depth for punching / column region) while flat_plate does not inject drops. one_way and vault use different solver paths.
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

GEOMETRY IN THE PROMPT:
- If BUILDING GEOMETRY appears in this chat's system prompt (structured JSON and/or narrative), treat it as the user's model — same source as Design Run when the client sends `building_geometry`. It may differ from server-cached geometry when GEOMETRY_CONTEXT.geometry_stale is true — follow GEOMETRY_CONTEXT and tool payloads, not assumptions.

IMPORTANT RULES:
- Explain structural engineering concepts clearly for the user's level of expertise.
- Reference specific check ratios, element IDs, and failure modes from the results data.
- If a check fails, explain what it means physically and suggest parameter changes that might help.
- Code provisions are enforced by the solver — quote code_clause and limit_state_description fields from results rather than inventing clause numbers or formulas.
- When suggesting parameter changes, output a JSON code block with only the changed fields.
- In that same JSON object, include `_history_label` (string): VERY brief (≤6 words) summary for the params history UI, same rules as design mode.

GEOMETRY AND IRREGULARITY:
- Do not attribute failures to "irregular geometry" based only on beam span statistics or CV — use slab_panel_plan / plan_shape_classification (situation card geometry includes the same summary) and get_applicability, not span_stats alone.
- When discussing failing elements, correlate with real geometry features when tools/summary support them: re-entrant corners, setbacks, non-orthogonal grids, triangular panels — not merely different span lengths in X vs Y.
- If member counts vary by level, there may be transfer conditions — flag when the geometry summary shows that.
$_TOOLS_GUIDANCE
$_SESSION_DESIGN_HISTORY_RULE
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

"""Counts for quick orientation before scanning full vertex/edge arrays."""
function _chat_structured_geometry_stats(g::Dict{String, Any})::Dict{String, Any}
    verts = get(g, "vertices", [])
    nv = verts isa AbstractVector ? length(verts) : 0
    eg = get(g, "edges", nothing)
    nb, nc, nz = 0, 0, 0
    if eg isa AbstractDict
        b = get(eg, "beams", [])
        c = get(eg, "columns", [])
        z = get(eg, "braces", [])
        nb = b isa AbstractVector ? length(b) : 0
        nc = c isa AbstractVector ? length(c) : 0
        nz = z isa AbstractVector ? length(z) : 0
    end
    sup = get(g, "supports", [])
    ns = sup isa AbstractVector ? length(sup) : 0
    sz = get(g, "stories_z", [])
    nzs = sz isa AbstractVector ? length(sz) : 0
    nfaces = 0
    try
        faces = get(g, "faces", nothing)
        if faces isa AbstractDict
            for (_, polys) in pairs(faces)
                polys isa AbstractVector && (nfaces += length(polys))
            end
        end
    catch
    end
    return Dict{String, Any}(
        "units"                 => get(g, "units", ""),
        "n_vertices"            => nv,
        "n_beam_edges"          => nb,
        "n_column_edges"        => nc,
        "n_brace_edges"         => nz,
        "n_supports"            => ns,
        "n_stories_z_entries"   => nzs,
        "n_face_polygon_loops"  => nfaces,
    )
end

"""
Append structured design geometry JSON and/or the optional human Summary line to the system prompt.
Structured data is the same model the client sends to POST /design (without `params`).
"""
function _append_chat_building_geometry_sections!(
    parts::Vector,
    geometry_summary::String,
    structured::Union{Nothing, Dict{String, Any}},
)
    if !isnothing(structured)
        stats = _chat_structured_geometry_stats(structured)
        json_txt = JSON3.write(structured)
        push!(parts, "\n\nBUILDING GEOMETRY (structured — same JSON as Design Run geometry, without params):\n")
        push!(parts, "Schema: units (string); vertices: array of [x,y,z] in those units; edges: {beams, columns, braces} arrays of [i,j] 1-based vertex indices; supports: vertex indices; faces: object mapping category (e.g. floor, roof, grade) to arrays of polygon loops (each loop: array of [x,y,z] points). Optional stories_z if the client sends it.\n")
        push!(parts, "Quick counts: ", JSON3.write(stats), "\n")
        if length(json_txt) > _MAX_CHAT_BUILDING_GEOMETRY_JSON_CHARS
            push!(parts, "Full geometry JSON omitted (length ", string(length(json_txt)), " chars > limit ", string(_MAX_CHAT_BUILDING_GEOMETRY_JSON_CHARS), "). Use the counts above, the narrative summary if present, or run Design so the server caches the structure.\n")
        else
            push!(parts, "Full geometry JSON:\n", json_txt, "\n")
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

"""True when chat-resolved geometry (body or client hash) disagrees with the server's last POST /design hash."""
function _geometry_prompt_stale(
    resolved::Union{Nothing, String},
    client_geometry_hash::String,
)::Bool
    srv = strip(DESIGN_CACHE.geometry_hash)
    isempty(srv) && return false
    if !isnothing(resolved) && !isempty(resolved)
        return resolved != srv
    end
    return _geometry_stale_for_client(client_geometry_hash)
end

"""True when client hash is present and differs from the server's cached POST /design geometry."""
function _geometry_stale_for_client(client_geometry_hash::String)::Bool
    cli = strip(client_geometry_hash)
    srv = strip(DESIGN_CACHE.geometry_hash)
    !isempty(cli) && !isempty(srv) && cli != srv
end

"""Merge geometry alignment fields into tool JSON for the LLM (optional client_geometry_hash in args)."""
function _attach_geometry_alignment!(result::Dict{String, Any}, args::Dict{String, Any})
    cli = strip(string(get(args, "client_geometry_hash", "")))
    isempty(cli) && return result
    srv = strip(DESIGN_CACHE.geometry_hash)
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
    structured_geometry::Union{Nothing, Dict{String, Any}} = nothing,
)
    resolved_h, res_src, derived_h = _chat_geometry_resolution(structured_geometry, client_geometry_hash)
    stale = _geometry_prompt_stale(resolved_h, client_geometry_hash)
    srv = strip(DESIGN_CACHE.geometry_hash)
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

GEOMETRY / CACHE MISMATCH (MANDATORY):
- Resolved geometry fingerprint for this chat request ($how): $res_show
- server_cached_geometry_hash (last completed POST /design on this server): $srv
The BUILDING GEOMETRY section(s) below describe the CURRENT client model when present (structured JSON and/or narrative).
Any \"LATEST RESULTS\" or \"DETAILED RESULTS\" section would refer to the SERVER hash above — a different model. Those sections are OMITTED from this prompt because they would mislead you.
Do not estimate forces, utilization ratios, pass/fail, embodied carbon, or element-level behavior for the current geometry using old cache data. Tell the user to run Design in Grasshopper so POST /design refreshes the server for this geometry.
You SHOULD give short, mechanism-level expectations for how the design problem may shift with this geometry change (spans, columns, stories, panel shapes) — without fabricated numbers. You may still discuss parameters, scope, and past runs via get_design_history / compare_designs (use geometry_hash and comparison_note).
"""
    else
        ""
    end

    if mode == "design"
        parts = [_DESIGN_SYSTEM_PREAMBLE, geo_ctx_block]
        !isempty(stale_note) && push!(parts, stale_note)
        _append_chat_building_geometry_sections!(parts, geometry_summary, structured_geometry)
        if !isnothing(params_json) && !isempty(string(params_json))
            push!(parts, "\n\nCURRENT PARAMETERS:\n", JSON3.write(params_json))
        end
        if !stale && !isnothing(DESIGN_CACHE.last_design)
            push!(parts, "\n\nLATEST RESULTS SUMMARY:\n", condense_result(DESIGN_CACHE.last_design))
        end
        return join(parts)
    elseif mode == "results"
        parts = [_RESULTS_SYSTEM_PREAMBLE, geo_ctx_block]
        !isempty(stale_note) && push!(parts, stale_note)
        if !stale && !isnothing(DESIGN_CACHE.last_design)
            push!(parts, condense_result(DESIGN_CACHE.last_design))
            push!(parts, "\n\nDETAILED RESULTS:\n", JSON3.write(report_summary_json(DESIGN_CACHE.last_design)))
        end
        _append_chat_building_geometry_sections!(parts, geometry_summary, structured_geometry)
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

const MAX_AGENT_TOOL_ROUNDS = 8

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
                        _dispatch_chat_tool(tool_name, args_dict)
                    end
                    if !isnothing(args_dict)
                        _attach_geometry_alignment!(result, args_dict)
                    elseif !isempty(client_geometry_hash)
                        _attach_geometry_alignment!(result, Dict{String, Any}("client_geometry_hash" => client_geometry_hash))
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
            full_text = "I executed the requested tool calls but did not receive a final response message. Please retry."
        end

        if !isempty(full_text)
            write(stream, "data: $(JSON3.write(Dict("token" => full_text)))\n\n")
        end

        suggestions        = _extract_suggestions(full_text)
        clarification_data = _extract_clarification_prompt(full_text)

        # Evidence-first enforcement: warn when no tools were called but the
        # response appears to contain numerical structural claims.
        if isempty(tool_actions) && _contains_numerical_claims(full_text)
            warning = "\n\n⚠️ This response was generated without consulting structural tools. Numerical results should be verified with a tool call."
            write(stream, "data: $(JSON3.write(Dict("token" => warning)))\n\n")
            full_text *= warning
            @warn "Evidence-first warning triggered — no tool calls but numerical claims detected"
        end

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

    return Dict{String, Any}(
        "ok" => isempty(violations),
        "violations" => violations,
        "warnings" => warnings,
    )
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

"""Read `DESIGN_CACHE.last_design` under lock to avoid torn reads."""
function _get_last_design()::Union{BuildingDesign, Nothing}
    lock(DESIGN_CACHE.lock) do
        DESIGN_CACHE.last_design
    end
end

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
        return agent_situation_card(
            DESIGN_CACHE.structure,
            DESIGN_CACHE.last_design,
            get_design_history_entries();
            server_geometry_hash = DESIGN_CACHE.geometry_hash,
            client_geometry_hash = cli,
        )

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
        report_units = nothing
        if !isnothing(units_arg)
            units_str = lowercase(strip(string(units_arg)))
            if units_str in ("imperial", "metric")
                report_units = Symbol(units_str)
            else
                return Dict("error" => "invalid_units", "message" => "units must be \"imperial\" or \"metric\".")
            end
        end
        return design_to_diagnose(DESIGN_CACHE.last_design; report_units=report_units)

    elseif tool == "query_elements"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        min_ratio_raw = get(args, "min_ratio", nothing)
        max_ratio_raw = get(args, "max_ratio", nothing)
        ok_raw = get(args, "ok", nothing)
        min_ratio = isnothing(min_ratio_raw) ? nothing : _chat_coerce_float(min_ratio_raw)
        max_ratio = isnothing(max_ratio_raw) ? nothing : _chat_coerce_float(max_ratio_raw)
        ok_val = isnothing(ok_raw) ? nothing : _chat_coerce_bool(ok_raw)
        ( !isnothing(min_ratio_raw) && isnothing(min_ratio) ) && return Dict("error" => "invalid_min_ratio", "message" => "min_ratio must be numeric.")
        ( !isnothing(max_ratio_raw) && isnothing(max_ratio) ) && return Dict("error" => "invalid_max_ratio", "message" => "max_ratio must be numeric.")
        ( !isnothing(ok_raw) && isnothing(ok_val) ) && return Dict("error" => "invalid_ok", "message" => "ok must be boolean (true/false).")
        return agent_query_elements(DESIGN_CACHE.last_design;
            type             = let t = get(args, "type", nothing); isnothing(t) ? nothing : string(t) end,
            min_ratio        = min_ratio,
            max_ratio        = max_ratio,
            governing_check  = let gc = get(args, "governing_check", nothing); isnothing(gc) ? nothing : string(gc) end,
            ok               = ok_val,
        )

    elseif tool == "get_solver_trace"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
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
                "hint"    => "Try a section number (\"22.6\"), full key (\"ACI_318.22.6\"), or check family name (\"punching_shear\").",
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
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        goal = get(args, "goal", nothing)
        isnothing(goal) && return Dict("error" => "missing_goal", "message" => "Provide a 'goal' argument (fix_failures, reduce_column_size, reduce_slab_thickness, reduce_ec).")
        return agent_suggest_next_action(DESIGN_CACHE.last_design, string(goal))

    elseif tool == "run_experiment"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        exp_type = get(args, "type", nothing)
        exp_args = get(args, "args", Dict{String, Any}())
        isnothing(exp_type) && return Dict("error" => "missing_type", "message" => "Provide experiment 'type' (punching, pm_column, deflection, catalog_screen).")
        !(exp_args isa AbstractDict) && return Dict("error" => "invalid_args", "message" => "run_experiment args must be an object.")
        exp_args_dict = Dict{String, Any}(string(k) => v for (k, v) in exp_args)
        return evaluate_experiment(DESIGN_CACHE.last_design, string(exp_type), exp_args_dict)

    elseif tool == "list_experiments"
        return list_experiments()

    elseif tool == "batch_experiments"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        experiments_raw = get(args, "experiments", Any[])
        !(experiments_raw isa AbstractVector) && return Dict("error" => "invalid_experiments", "message" => "experiments must be an array of {type,args} objects.")
        for e in experiments_raw
            !(e isa AbstractDict) && return Dict("error" => "invalid_experiments", "message" => "Each experiments entry must be an object with type and args.")
        end
        experiments = [Dict{String, Any}(string(k) => v for (k, v) in e) for e in experiments_raw]
        return batch_evaluate(DESIGN_CACHE.last_design, experiments)

    # ── Phase 4: Communication ───────────────────────────────────────────────
    elseif tool == "narrate_element"
        isnothing(DESIGN_CACHE.last_design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        etype    = get(args, "element_type", nothing)
        eid      = _chat_coerce_int(get(args, "element_id", nothing))
        audience = get(args, "audience", "architect")
        (isnothing(etype) || isnothing(eid)) && return Dict("error" => "missing_args", "message" => "Provide element_type and element_id.")
        return agent_narrate_element(DESIGN_CACHE.last_design, string(etype), eid, string(audience))

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
                tc = TraceCollector()
                d = design_building(DESIGN_CACHE.structure, fast_params; tc=tc)
                DESIGN_CACHE.last_design = d
                DESIGN_CACHE.last_result = design_to_json(d; geometry_hash=DESIGN_CACHE.geometry_hash)
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
            geometry_hash    = DESIGN_CACHE.geometry_hash,
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
                "get_lever_map, get_implemented_provisions, get_provision_rationale, explain_field, " *
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

        system_prompt = _build_system_prompt(mode, params_json, geometry_summary, client_geometry_hash, structured_geo)
        budgeted      = _budget_messages(system_prompt, messages, MAX_CONTEXT_TOKENS)

        HTTP.setstatus(stream, 200)
        HTTP.setheader(stream, "Content-Type"  => "text/event-stream")
        HTTP.setheader(stream, "Cache-Control" => "no-cache")
        HTTP.setheader(stream, "Connection"    => "keep-alive")
        startwrite(stream)

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

        t0     = time()
        result = _dispatch_chat_tool(tool, args)
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
