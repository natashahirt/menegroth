# =============================================================================
# LLM API key normalization
# =============================================================================
#
# Users sometimes paste into `secrets/openai_api_key` or shell env:
#   CHAT_LLM_API_KEY=sk-...
#   {"CHAT_LLM_API_KEY":"sk-..."}
# instead of the raw key. OpenAI then receives the whole string as Bearer token
# and returns 401. `normalize_llm_api_key_secret` extracts the actual secret.

"""
    normalize_llm_api_key_secret(raw) -> String

Return the OpenAI (or compatible) API key string from `raw`, stripping UTF-8 BOM,
optional `export`/`CHAT_LLM_API_KEY=` prefixes, one-line JSON wrappers, and a
single layer of surrounding quotes. Requires `JSON3` to be in scope (loaded via
`schema.jl` before this file is included).
"""
function normalize_llm_api_key_secret(raw::AbstractString)::String
    s = strip(String(raw))
    s = replace(s, "\ufeff" => "")
    s = strip(s)
    isempty(s) && return ""

    if startswith(s, '{')
        try
            obj = JSON3.read(s)
            if obj isa AbstractDict && haskey(obj, "CHAT_LLM_API_KEY")
                return normalize_llm_api_key_secret(string(obj["CHAT_LLM_API_KEY"]))
            end
        catch
        end
    end

    m = match(r"^(?:export\s+)?CHAT_LLM_API_KEY\s*=\s*(.+)$"is, s)
    if m !== nothing
        return normalize_llm_api_key_secret(String(m[1]))
    end

    if length(s) >= 2
        if startswith(s, '"') && endswith(s, '"')
            return normalize_llm_api_key_secret(chop(s; head=1, tail=1))
        end
        if startswith(s, '\'') && endswith(s, '\'')
            return normalize_llm_api_key_secret(chop(s; head=1, tail=1))
        end
    end

    return s
end
