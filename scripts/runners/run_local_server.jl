# Local API server for large models that exceed App Runner memory limits.
# Usage: julia --project=StructuralSynthesizer scripts/runners/run_local_server.jl
#
# Grasshopper defaults to http://localhost:8080 — no URL change needed.
# For chat, set CHAT_LLM_API_KEY or place key in secrets/openai_api_key.

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

# Load LLM key from secrets file if not already in ENV
let key_file = joinpath(@__DIR__, "..", "..", "secrets", "openai_api_key")
    if !haskey(ENV, "CHAT_LLM_API_KEY") && isfile(key_file)
        raw = strip(read(key_file, String))
        if !isempty(raw)
            ENV["CHAT_LLM_API_KEY"] = raw
            println("[local] CHAT_LLM_API_KEY loaded from secrets/openai_api_key")
        end
    end
end
if !haskey(ENV, "CHAT_LLM_BASE_URL")
    ENV["CHAT_LLM_BASE_URL"] = "https://api.openai.com"
end
if !haskey(ENV, "CHAT_LLM_MODEL")
    ENV["CHAT_LLM_MODEL"] = "gpt-4o"
end

using StructuralSynthesizer

const PORT = parse(Int, get(ENV, "PORT", get(ENV, "SIZER_PORT", "8080")))
const HOST = get(ENV, "SIZER_HOST", "localhost")

@info "Registering API routes..."
register_routes!()

@info "Local server starting on http://$HOST:$PORT"
@info "Endpoints: POST /design, /validate, /chat, /reset  GET /health, /status, /schema, /result, /report, /diagnose, /logs"

using Oxygen
serve(; host=HOST, port=PORT)
