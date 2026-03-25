"""
Minimal Julia script to test direct connectivity to the OpenAI API.
Sends the smallest possible valid chat completions request to isolate
whether ECONNRESET is a network/proxy issue or a request-body issue.

Usage:
  julia --project=StructuralSynthesizer scripts/runners/test_openai_direct.jl
"""

using HTTP
using JSON3

function _compact_error(e)::String
    type_str = string(typeof(e))
    if occursin("RequestError", type_str) && hasproperty(e, :error)
        return "RequestError: $(sprint(showerror, getproperty(e, :error)))"
    end
    return sprint(showerror, e)
end

function main()
    key_path = joinpath(@__DIR__, "..", "..", "secrets", "openai_api_key")
    api_key = isfile(key_path) ? strip(read(key_path, String)) : get(ENV, "CHAT_LLM_API_KEY", "")
    if isempty(api_key)
        println(stderr, "[openai_direct] ERROR: no API key found in secrets/openai_api_key or CHAT_LLM_API_KEY")
        exit(1)
    end
    println("[openai_direct] key prefix: ", first(api_key, 10), "...")

    # ── Test 1: tiny non-streaming request ─────────────────────────────────────
    println("[openai_direct] Test 1 — tiny non-streaming POST (no stream)...")
    body_small = JSON3.write(Dict(
        "model"    => "gpt-4o-mini",
        "messages" => [Dict("role" => "user", "content" => "Say OK")],
        "stream"   => false,
        "max_tokens" => 5,
    ))
    println("[openai_direct]   body size: ", length(body_small), " bytes")

    try
        r = HTTP.post(
            "https://api.openai.com/v1/chat/completions",
            ["Content-Type" => "application/json", "Authorization" => "Bearer $api_key"],
            body_small;
            connect_timeout = 10,
            readtimeout     = 30,
            status_exception = false,
        )
        println("[openai_direct]   status: ", r.status)
        resp = String(r.body)
        println("[openai_direct]   body (first 200): ", resp[1:min(end, 200)])
        r.status == 200 && println("[openai_direct]   Test 1 PASS")
        r.status != 200 && println(stderr, "[openai_direct]   Test 1 FAIL — non-200")
    catch e
        println(stderr, "[openai_direct]   Test 1 ERROR: ", _compact_error(e))
    end

    # ── Test 2: large streaming request (simulate real chat call) ───────────────
    println("[openai_direct] Test 2 — large streaming POST (~20 KB body)...")
    big_content = "You are a structural engineering assistant. " ^ 400   # ~18 KB
    body_large = JSON3.write(Dict(
        "model"    => "gpt-4o-mini",
        "messages" => [
            Dict("role" => "system",  "content" => big_content),
            Dict("role" => "user",    "content" => "Say OK"),
        ],
        "stream"   => true,
        "max_tokens" => 5,
    ))
    println("[openai_direct]   body size: ", length(body_large), " bytes")

    try
        buf = IOBuffer()
        HTTP.open("POST",
            "https://api.openai.com/v1/chat/completions",
            ["Content-Type" => "application/json", "Authorization" => "Bearer $api_key"];
            body=body_large,
            connect_timeout=10,
            readtimeout=30,
            require_ssl_verification=false,
        ) do io
            while !eof(io)
                line = String(readline(io))
                write(buf, line * "\n")
            end
        end
        result = String(take!(buf))
        println("[openai_direct]   got ", length(result), " bytes from stream")
        occursin("data:", result) && println("[openai_direct]   Test 2 PASS (SSE data found)")
        !occursin("data:", result) && println(stderr, "[openai_direct]   Test 2 FAIL — no SSE data")
    catch e
        println(stderr, "[openai_direct]   Test 2 ERROR: ", _compact_error(e))
    end
end

main()
