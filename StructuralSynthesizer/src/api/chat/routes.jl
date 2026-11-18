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
        reset_session         = something(_chat_coerce_bool(get(parsed, :reset_session, get(parsed, "reset_session", false))), false)
        bg_raw = get(parsed, :building_geometry, get(parsed, "building_geometry", nothing))
        structured_geo = _parse_chat_building_geometry(bg_raw)
        if isnothing(structured_geo)
            g_raw = get(parsed, :geometry, get(parsed, "geometry", nothing))
            structured_geo = _parse_chat_building_geometry(g_raw)
        end

        if reset_session
            _clear_history!("all")
            clear_design_history!()
            clear_session_insights!()
            @info "Chat session reset requested by client"
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
