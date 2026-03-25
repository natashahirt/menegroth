# =============================================================================
# Smoke test: POST /chat against a running sizer_bootstrap server.
#
# Prerequisites: start the API first, e.g.
#   SIZER_PORT=18080 julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
#
# Usage (from repo root):
#   julia --project=StructuralSynthesizer scripts/runners/test_chat_smoke.jl
#
# Optional ENV:
#   CHAT_TEST_BASE_URL — default http://127.0.0.1:18080
# =============================================================================

using HTTP
using JSON3

const BASE = get(ENV, "CHAT_TEST_BASE_URL", "http://127.0.0.1:18080")

function wait_for_schema!(base::String; max_wait_s::Float64 = 120.0, interval_s::Float64 = 1.0)
    deadline = time() + max_wait_s
    while time() < deadline
        try
            r = HTTP.get(string(base, "/schema"); connect_timeout=5, readtimeout=10)
            r.status == 200 && return true
        catch
        end
        sleep(interval_s)
    end
    return false
end

function main()
    println("[chat_smoke] base URL: ", BASE)
    println("[chat_smoke] waiting for GET /schema (full API ready)...")
    wait_for_schema!(BASE) || error("Timed out waiting for GET /schema — is the server running on $BASE ?")

    body = JSON3.write(Dict(
        "mode" => "design",
        "messages" => [Dict("role" => "user", "content" => "Reply with exactly: OK")],
        "geometry_summary" => "smoke test — no real building",
        "params" => Dict("floor_type" => "flat_plate", "column_type" => "rc_rect"),
    ))

    println("[chat_smoke] POST /chat ...")
    r = HTTP.post(
        string(BASE, "/chat");
        body=body,
        headers=["Content-Type" => "application/json"],
        connect_timeout=10,
        readtimeout=120,
        status_exception=false,
    )

    if r.status == 503
        println(stderr, "[chat_smoke] FAIL: 503 — CHAT_LLM_API_KEY not set on server?")
        exit(1)
    end
    r.status != 200 && error("Unexpected status $(r.status): $(String(r.body))")

    text = String(r.body)
    got_token = occursin("\"token\"", text)
    got_summary = occursin("agent_turn_summary", text)
    got_upstream_llm_err = occursin("llm_unavailable", text)
    println("[chat_smoke] response bytes: ", length(text))
    println("[chat_smoke] saw token events: ", got_token)
    println("[chat_smoke] saw agent_turn_summary: ", got_summary)

    if got_token || got_summary
        println("[chat_smoke] PASS (LLM streamed)")
        exit(0)
    end

    # Server pipeline is OK (JSON parsed, SSE opened) but OpenAI returned an error
    # (network, key, billing, firewall). Still counts as a smoke-test pass for Menegroth.
    if got_upstream_llm_err
        println("[chat_smoke] PASS (Menegroth /chat OK; OpenAI upstream error — check key, billing, proxy, or firewall)")
        println(stderr, "[chat_smoke] first 600 chars of stream:\n", text[1:min(end, 600)])
        exit(0)
    end

    println(stderr, "[chat_smoke] FAIL: no SSE tokens or llm_unavailable marker")
    println(stderr, text[1:min(end, 800)])
    exit(1)
end

main()
