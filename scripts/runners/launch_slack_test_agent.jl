# =============================================================================
# Launch a Cursor Cloud Agent that posts a test message to Slack as the bot.
#
# Prerequisites:
#   1. CURSOR_API_KEY set in your environment (same key as in GitHub secrets).
#   2. SLACK_BOT_TOKEN (Bot User OAuth Token, xoxb-...) in Cursor workspace /
#      agent environment secrets, with im:write and chat:write.
#      Locally you can mirror the token in secrets/slack_bot_token (gitignored);
#      that file is not sent to the Cloud Agent — use Cursor secrets for the
#      agent, or run slack_bot_local_smoke.jl to test the token without Cursor.
#
# Usage:
#   set CURSOR_API_KEY=your_key
#   julia scripts/runners/launch_slack_test_agent.jl
#
# The agent opens a DM with the configured user and posts via chat.postMessage
# so the message appears from the app, not from a human Slack account.
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
using Dates
using HTTP
using JSON
using Base64

const api_key = get(ENV, "CURSOR_API_KEY", "")
if isempty(api_key)
    error("CURSOR_API_KEY is not set. Set it in your environment and run again.")
end

prompt = raw"""
Your only task: send one short test message to Slack **as the bot** (not via the Cursor user Slack integration).

1. The Bot User OAuth token is in the environment variable `SLACK_BOT_TOKEN` in this environment.
2. Open (or reuse) a DM with Slack user `U0AKVLWEJ7J` using the Slack Web API:
   - POST `https://slack.com/api/conversations.open` with JSON body `{"users":"U0AKVLWEJ7J"}`, headers `Authorization: Bearer $SLACK_BOT_TOKEN` and `Content-Type: application/json`.
3. From the response, read `channel.id` and POST to `https://slack.com/api/chat.postMessage` with JSON `{"channel":"<that id>","text":"Test from Menegroth Slack bot (Cursor agent)"}` and the same auth header.
4. Use `curl` or an equivalent shell command. Confirm `ok: true` in both responses, or report the `error` field from Slack.

If `SLACK_BOT_TOKEN` is not set, say so and do not invent a token.
"""

repo = "https://github.com/natashahirt/menegroth"
branch = "cursor/slack-test"

body = Dict(
    "prompt" => Dict("text" => prompt),
    "model" => "gpt-5.2",
    "source" => Dict("repository" => repo, "ref" => "main"),
    "target" => Dict("autoCreatePr" => false, "branchName" => branch),
)

auth = base64encode(api_key * ":")

println("Launching Cursor agent (repo=$repo, branch=$branch)...")
resp = HTTP.post(
    "https://api.cursor.com/v0/agents";
    headers = ["Content-Type" => "application/json", "Authorization" => "Basic $auth"],
    body = JSON.json(body),
)

println("Status: ", resp.status)
println(String(resp.body))

if resp.status != 200
    exit(1)
end

# Parse and show agent id if present
try
    r = JSON.parse(String(resp.body))
    if haskey(r, "id")
        println("Agent id: ", r["id"])
    end
    if haskey(r, "error")
        println("Error: ", r["error"])
        exit(1)
    end
catch
end
