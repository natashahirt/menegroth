function _register_schema_routes!()

    # ─── GET /health ──────────────────────────────────────────────────────
    @get "/health" function (_::HTTP.Request)
        return _json_ok(Dict("status" => "ok"))
    end

    # ─── GET /status ──────────────────────────────────────────────────────
    @get "/status" function (_::HTTP.Request)
        state = status_string(SERVER_STATUS)
        payload = Dict(
            "status" => "ok",
            "mode" => "full",
            "ready" => true,
            "state" => state,
            "has_result" => with_cache_read(c -> !isnothing(c.last_result), DESIGN_CACHE),
            "message" => nothing,
            "error" => nothing,
        )
        return _json_ok(payload)
    end

    # ─── GET /env-check ───────────────────────────────────────────────────
    # Reports whether expected env vars are set (presence only; no values).
    # Use to verify Secrets Manager / App Runner config without exposing secrets.
    @get "/env-check" function (_::HTTP.Request)
        keys_to_check = ["GRB_WLSACCESSID", "GRB_WLSSECRET", "GRB_LICENSEID"]
        present = Dict(k => haskey(ENV, k) for k in keys_to_check)
        return _json_ok(present)
    end

    # ─── GET /schema ──────────────────────────────────────────────────────
    @get "/schema" function (_::HTTP.Request)
        schema_doc = Dict(
            "input" => api_input_schema(),
            "params_structured" => api_params_schema_structured(),
            "applicability" => api_applicability_schema(),
            "diagnose_schema" => api_diagnose_schema(),
            "endpoints" => Dict(
                "POST /design" => "Start design (returns 202 immediately; poll GET /status then GET /result)",
                "POST /validate" => "Validate input without running design",
                "GET /health" => "Server health check",
                "GET /status" => "Server status payload: {status, mode, ready, state, has_result, message, error}; state: idle, running, queued (or warming/error during bootstrap)",
                "GET /env-check" => "Whether Gurobi env vars are set (presence only, no values)",
                "GET /logs?since=N" => "Streaming design logs; returns lines after cursor N",
                "GET /result" => "Last completed design result (after POST /design and status idle)",
                "POST /rebuild_visualization" => "Rebuild visualization mesh only. Body: {\"target_edge_m\": <positive float>}. Requires a cached design.",
                "GET /report" => "Engineering report (plain text by default; ?format=json for structured summary)",
                "GET /diagnose" => "High-resolution agent diagnostic JSON: per-element checks with demand/capacity, governing_check, levers, embodied carbon, plus architectural narrative and lever impact estimates. ?units=imperial|metric",
                "POST /chat" => "LLM chat endpoint (SSE streaming). Body: {mode, messages, params?, geometry_summary?, building_geometry? (same JSON as POST /design geometry, without params), geometry? (alias), session_id?, client_geometry_hash?, reset_session?:bool}. " *
                    "When reset_session is true, all server-side conversation history, design history, and session insights are cleared before processing the message (use on Grasshopper restart or new session). " *
                    "When building_geometry is present, the server derives the same geometry hash as POST /design (params excluded) and injects GEOMETRY_CONTEXT (aligned_with_server, geometry_stale) into the system prompt; client_geometry_hash is optional when structured geometry is sent. " *
                    "If POST /design is in progress, SSE begins with {type:\"design_wait\", phase:\"start\"|\"polling\", message, elapsed_s?, server_status?} until idle, then {type:\"design_ready\"} (wait up to CHAT_PRE_CHAT_DESIGN_WAIT_TIMEOUT_S, default 3600 s). " *
                    "SSE events: {token:string}, " *
                    "{type:\"agent_turn_summary\", suggested_next_questions:string[], clarification_prompt?:{id,prompt,options:[{id,label}],allow_multiple,rationale?,required_for?}, tool_actions?:[{tool,status,elapsed_ms?,summary?}]}, " *
                    "error events: {error:string, message:string, recovery_hint:string}, " *
                    "[DONE]. All errors include recovery_hint.",
                "POST /chat/action" => "Agent tool dispatch. Body: {tool, args, client_geometry_hash?}. " *
                    "clarify_user_intent => {ok,type:\"clarification\",duplicate,clarification:{id,prompt,options:[{id,label}],allow_multiple,rationale?,required_for?}}. " *
                    "All error responses include recovery_hint. See GET /schema/tools for full registry.",
                "GET /chat/history" => "Retrieve stored conversation history. ?session_id=<hash>",
                "DELETE /chat/history" => "Clear conversation history. ?session_id=<hash> (omit to clear all)",
                "GET /schema/applicability" => "Compact method/floor applicability and compatibility rules for assistants",
                "GET /schema/diagnose" => "Versioned contract for GET /diagnose payload structure",
                "GET /schema/tools" => "Structured tool registry: name, description, phase, use_when, args, returns for all agent tools",
                "GET /schema/llm_contract" => "Versioned LLM contract: system capabilities, tools, parameters, scope limits, experiment types",
                "POST /reset" => "Clear all session state (design cache, history, insights, chat history). Call on Grasshopper restart or document change. Fails with 503 if server is busy.",
                "GET /schema" => "This documentation",
            ),
        )
        return _json_ok(schema_doc)
    end

    # ─── GET /schema/applicability ────────────────────────────────────────
    @get "/schema/applicability" function (_::HTTP.Request)
        return _json_ok(api_applicability_schema())
    end

    # ─── GET /schema/diagnose ─────────────────────────────────────────────
    @get "/schema/diagnose" function (_::HTTP.Request)
        return _json_ok(api_diagnose_schema())
    end

    # ─── GET /schema/tools ────────────────────────────────────────────────
    @get "/schema/tools" function (_::HTTP.Request)
        return _json_ok(api_tool_schema())
    end

    # ─── GET /schema/llm_contract ─────────────────────────────────────────
    @get "/schema/llm_contract" function (_::HTTP.Request)
        return _json_ok(api_llm_contract())
    end

    # ─── POST /validate ───────────────────────────────────────────────────
    @post "/validate" function (req::HTTP.Request)
        (input, err) = _parse_json_body(req)
        !isnothing(err) && return err

        result = validate_input(input)
        result.ok && return _json_ok(Dict("status" => "ok", "message" => "Input is valid."))
        return _validation_error_response(result)
    end

    return nothing
end
