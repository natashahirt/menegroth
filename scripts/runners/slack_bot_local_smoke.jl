# =============================================================================
# Local smoke test: post a DM via Slack Web API using SLACK_BOT_TOKEN.
#
# Token resolution (first match wins):
#   1. Environment variable SLACK_BOT_TOKEN
#   2. File repo-root secrets/slack_bot_token (gitignored; single line, no quotes)
#
# Posting target:
#   - Default: open a DM with SLACK_USER_ID (requires Slack app scope im:write).
#   - If SLACK_SMOKE_CHANNEL is set (e.g. C0AL4NPK1SA), post there only (chat:write
#     on that channel is enough; invite the bot to the channel first).
#
# Usage (from repo root):
#   julia --project=StructuralSynthesizer scripts/runners/slack_bot_local_smoke.jl
# =============================================================================

using Pkg
const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
Pkg.activate(joinpath(REPO_ROOT, "StructuralSynthesizer"))

using HTTP
using JSON

const SLACK_USER_ID = "U0AKVLWEJ7J"
const TEST_TEXT = "Test from Menegroth Slack bot (local smoke)"

function resolve_slack_token()::String
    env = strip(get(ENV, "SLACK_BOT_TOKEN", ""))
    isempty(env) || return env
    path = joinpath(REPO_ROOT, "secrets", "slack_bot_token")
    isfile(path) || error(
        "Set SLACK_BOT_TOKEN or create secrets/slack_bot_token (see AGENTS.md).",
    )
    return strip(read(path, String))
end

function slack_json_post(token::AbstractString, url::AbstractString, body::AbstractDict)
    return HTTP.post(
        url;
        headers = [
            "Authorization" => "Bearer $token",
            "Content-Type" => "application/json; charset=utf-8",
        ],
        body = JSON.json(body),
    )
end

function main()
    token = resolve_slack_token()
    channel = strip(get(ENV, "SLACK_SMOKE_CHANNEL", ""))
    if isempty(channel)
        open_resp = slack_json_post(
            token,
            "https://slack.com/api/conversations.open",
            Dict("users" => SLACK_USER_ID),
        )
        open_body = JSON.parse(String(open_resp.body))
        println(JSON.json(open_body, 2))
        get(open_body, "ok", false) ||
            error("conversations.open failed: $(get(open_body, "error", "?"))")
        channel = open_body["channel"]["id"]
    else
        println("(SLACK_SMOKE_CHANNEL set — skipping conversations.open)")
    end

    post_resp = slack_json_post(
        token,
        "https://slack.com/api/chat.postMessage",
        Dict("channel" => channel, "text" => TEST_TEXT),
    )
    post_body = JSON.parse(String(post_resp.body))
    println(JSON.json(post_body, 2))
    get(post_body, "ok", false) ||
        error("chat.postMessage failed: $(get(post_body, "error", "?"))")

    ts = post_body["ts"]
    link_resp = HTTP.post(
        "https://slack.com/api/chat.getPermalink";
        headers = [
            "Authorization" => "Bearer $token",
            "Content-Type" => "application/x-www-form-urlencoded",
        ],
        body = "channel=$(channel)&message_ts=$(ts)",
    )
    link_body = JSON.parse(String(link_resp.body))
    if get(link_body, "ok", false)
        println("Permalink: ", link_body["permalink"])
    end
end

main()
