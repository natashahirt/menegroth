# ─── LLM streaming client ────────────────────────────────────────────────────

const MAX_AGENT_TOOL_ROUNDS = 8

"""
    _emit_text_chunked(sse_stream, text; chunk_chars=80)

Emit pre-generated text to the SSE stream in small chunks so the client
receives incremental `token` events rather than one monolithic blob.
Chunks at whitespace boundaries near `chunk_chars` characters.
"""
function _emit_text_chunked(sse_stream::HTTP.Stream, text::String; chunk_chars::Int=80)
    isempty(text) && return
    pos = 1
    n = length(text)
    while pos <= n
        stop = min(pos + chunk_chars - 1, n)
        if stop < n
            sp = findprev(' ', text, stop)
            if !isnothing(sp) && sp >= pos
                stop = sp
            end
        end
        chunk = text[pos:stop]
        write(sse_stream, "data: $(JSON3.write(Dict("token" => chunk)))\n\n")
        pos = stop + 1
    end
end

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

    if base_type == "array"
        items_desc = get(d, "items", nothing)
        if items_desc isa AbstractDict
            schema["items"] = _json_schema_from_tool_arg(Dict{String, Any}(string(k) => v for (k, v) in items_desc))
        elseif !haskey(schema, "items")
            schema["items"] = Dict{String, Any}("type" => "string")
        end
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

        # Build a rich description from registry fields: description + use_when + returns.
        # The OpenAI tools payload only has a single `description` string, so we merge
        # the registry's separate fields here so the LLM sees when/why to call each tool.
        desc_parts = String[string(get(entry, "description", ""))]
        use_when = get(entry, "use_when", nothing)
        !isnothing(use_when) && !isempty(string(use_when)) && push!(desc_parts, "USE WHEN: " * string(use_when))
        returns = get(entry, "returns", nothing)
        !isnothing(returns) && !isempty(string(returns)) && push!(desc_parts, "RETURNS: " * string(returns))
        desc = join(desc_parts, " | ")

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
            # ── Ephemeral grounding messages (not persisted to history) ──
            # Inject authoritative design snapshot + tools-first instruction at
            # the tail of the conversation so they are the LLM's most recent context.
            n_injected = 0
            snapshot_msg = _most_recent_design_snapshot()
            push!(conversation, Dict{String, Any}("role" => "system", "content" => snapshot_msg))
            n_injected += 1
            if tool_round == 1
                push!(conversation, Dict{String, Any}("role" => "system", "content" => _TOOLS_FIRST_INSTRUCTION))
                n_injected += 1
            end

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

            local r
            try
                r = HTTP.post(
                    url,
                    headers,
                    JSON3.write(payload);
                    connect_timeout=10,
                    readtimeout=120,
                    status_exception=false,
                    cookies=false,
                )
            finally
                # Remove ephemeral grounding messages so they don't accumulate
                # in the conversation or leak into persisted history.
                for _ in 1:n_injected
                    pop!(conversation)
                end
            end

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

                    # Emit tool-start progress event so the client can show live status.
                    write(stream, "data: $(JSON3.write(Dict{String,Any}(
                        "tool_progress" => Dict{String,Any}(
                            "tool"   => tool_name,
                            "label"  => get(_TOOL_DISPLAY_LABELS, tool_name, tool_name),
                            "status" => "running",
                            "round"  => tool_round,
                            "index"  => i,
                        ),
                    )))\n\n")

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
                        try
                            _dispatch_chat_tool(tool_name, args_dict)
                        catch e
                            @error "Chat tool execution failed" tool=tool_name exception=(e, catch_backtrace())
                            Dict{String, Any}(
                                "error" => "tool_execution_failed",
                                "tool" => tool_name,
                                "message" => sprint(showerror, e),
                                "recovery_hint" => "Retry this tool call; if it persists, run GET /status and share this error.",
                                "INSTRUCTION" => "This tool call FAILED. You have NO results from it. " *
                                    "Tell the user the tool errored and show the error message. " *
                                    "Do NOT present fabricated results. Do NOT invent ratios, capacities, or outcomes.",
                            )
                        end
                    end
                    if !isnothing(args_dict)
                        _attach_geometry_alignment!(result, args_dict)
                    elseif !isempty(client_geometry_hash)
                        _attach_geometry_alignment!(result, Dict{String, Any}("client_geometry_hash" => client_geometry_hash))
                    end
                    elapsed_ms = round(Int, (time() - t0) * 1000)
                    tool_status = haskey(result, "error") ? "error" : "ok"

                    if tool_status == "error" && !haskey(result, "INSTRUCTION")
                        result["INSTRUCTION"] = "This tool call FAILED. You have NO results from it. " *
                            "Tell the user the tool errored and show the error message. " *
                            "Do NOT present fabricated results. Do NOT invent ratios, capacities, or outcomes."
                    end

                    # Emit tool-done progress event.
                    write(stream, "data: $(JSON3.write(Dict{String,Any}(
                        "tool_progress" => Dict{String,Any}(
                            "tool"       => tool_name,
                            "label"      => get(_TOOL_DISPLAY_LABELS, tool_name, tool_name),
                            "status"     => tool_status,
                            "round"      => tool_round,
                            "index"      => i,
                            "elapsed_ms" => elapsed_ms,
                        ),
                    )))\n\n")

                    push!(tool_actions, Dict{String, Any}(
                        "tool" => tool_name,
                        "status" => tool_status,
                        "elapsed_ms" => elapsed_ms,
                        "summary" => _tool_action_summary(result),
                    ))

                    result_safe = result isa AbstractDict ? _sanitize_ieee_specials(result) : result
                    result_json = JSON3.write(result_safe)
                    result_json = _truncate_tool_result(result_json)
                    push!(tool_results, Dict{String, Any}(
                        "role" => "tool",
                        "tool_call_id" => call_id,
                        "content" => result_json,
                    ))
                end

                push!(conversation, Dict{String, Any}(
                    "role" => "assistant",
                    "content" => assistant_content,
                    "tool_calls" => assistant_tool_calls,
                ))
                append!(conversation, tool_results)

                # Mid-conversation context budget check: compress old tool
                # results if accumulated conversation is getting large.
                _compact_conversation!(conversation, system_prompt, MAX_CONTEXT_TOKENS)

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
                    "If compare_designs (previous vs latest) is unavailable (e.g. only one run in history), say what is still missing. " *
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
            n_actions = length(tool_actions)
            tool_names = join(unique(string(get(a, "tool", "?")) for a in tool_actions), ", ")
            full_text = "I executed $n_actions tool calls ($tool_names) but hit the processing limit " *
                "before producing a summary. The tool results are available — please ask your " *
                "question again and I'll summarize them."
        end

        suggestions        = _extract_suggestions(full_text)
        clarification_data = _extract_clarification_prompt(full_text)

        # Strip machine-readable markers from the user-facing text.
        # The structured data is delivered via agent_turn_summary instead.
        display_text = _strip_marker_blocks(full_text)

        # Emit text as incremental token chunks for a responsive typing feel.
        if !isempty(display_text)
            _emit_text_chunked(stream, display_text)
        end

        # Evidence-first enforcement: warn when no tools were called but the
        # response appears to contain numerical structural claims.
        if isempty(tool_actions) && _contains_numerical_claims(display_text)
            warning = "\n\n⚠️ This response was generated without consulting structural tools. Numerical results should be verified with a tool call."
            write(stream, "data: $(JSON3.write(Dict("token" => warning)))\n\n")
            display_text *= warning
            full_text *= warning
            @warn "Evidence-first warning triggered — no tool calls but numerical claims detected"
        end

        # Evidence-first enforcement: warn when ALL tool calls errored but the
        # response still contains numerical claims (likely fabricated from error context).
        all_errored = !isempty(tool_actions) && all(a -> get(a, "status", "") == "error", tool_actions)
        if all_errored && _contains_numerical_claims(display_text)
            warning = "\n\n⚠️ All tool calls in this turn returned errors. The numerical results above may not be accurate — please retry or ask me to investigate the error."
            write(stream, "data: $(JSON3.write(Dict("token" => warning)))\n\n")
            display_text *= warning
            full_text *= warning
            @warn "Evidence-first warning triggered — all tools errored but numerical claims present"
        end

        # Persist assistant turn to server-side history.
        if !isempty(session_id) && !isempty(full_text)
            _append_history!(session_id, "assistant", full_text)
        end

        params_patch = _extract_params_patch(full_text)

        summary = _build_turn_summary(;
            suggestions        = suggestions,
            clarification_data = clarification_data,
            tool_actions       = tool_actions,
            params_patch       = params_patch,
        )

        # Attach context usage so the front-end can show a budget indicator.
        conv_tokens = sum(_estimate_tokens(string(get(m, "content", ""))) + 10 for m in conversation; init=0)
        sys_tokens  = _estimate_tokens(system_prompt)
        summary["context_usage"] = Dict{String, Any}(
            "system_prompt_tokens"  => sys_tokens,
            "conversation_tokens"   => conv_tokens,
            "total_tokens"          => sys_tokens + conv_tokens,
            "budget_tokens"         => MAX_CONTEXT_TOKENS,
            "utilization_pct"       => round(100 * (sys_tokens + conv_tokens) / MAX_CONTEXT_TOKENS; digits=1),
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

