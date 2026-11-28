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

