# =============================================================================
# API Routes — Oxygen HTTP endpoint definitions
# =============================================================================

using HTTP
using Oxygen

# ─── Global state ─────────────────────────────────────────────────────────────

const DESIGN_CACHE = DesignCache()
const SERVER_STATUS = ServerStatus()
const DESIGN_LOG_LINES = String[]
const DESIGN_LOG_LOCK = ReentrantLock()
const DESIGN_LOG_BASE_INDEX = Ref(0)
const DESIGN_LOG_MAX_LINES = 2000

"""Best-effort integer coercion for route/query values."""
function _route_coerce_int(x)::Union{Int, Nothing}
    isnothing(x) && return nothing
    x isa Integer && return Int(x)
    if x isa Real
        return isinteger(x) ? Int(x) : nothing
    elseif x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        i = tryparse(Int, s)
        !isnothing(i) && return i
        f = tryparse(Float64, s)
        (!isnothing(f) && isfinite(f) && isinteger(f)) && return Int(f)
    end
    return nothing
end

"""Best-effort float coercion for route/body values."""
function _route_coerce_float(x)::Union{Float64, Nothing}
    isnothing(x) && return nothing
    x isa Real && return Float64(x)
    if x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        return tryparse(Float64, replace(s, "," => ""))
    end
    return nothing
end

function _reset_design_logs!()
    lock(DESIGN_LOG_LOCK) do
        empty!(DESIGN_LOG_LINES)
        DESIGN_LOG_BASE_INDEX[] = 0
    end
    return nothing
end

function _append_design_log!(line::AbstractString)
    clean = isempty(line) ? "" : strip(String(line))
    lock(DESIGN_LOG_LOCK) do
        push!(DESIGN_LOG_LINES, clean)
        while length(DESIGN_LOG_LINES) > DESIGN_LOG_MAX_LINES
            popfirst!(DESIGN_LOG_LINES)
            DESIGN_LOG_BASE_INDEX[] += 1
        end
    end
    return nothing
end

function _read_design_logs_since(since::Int)
    lock(DESIGN_LOG_LOCK) do
        base = DESIGN_LOG_BASE_INDEX[]
        total = base + length(DESIGN_LOG_LINES)
        clamped = max(0, min(since, total))
        start_abs = max(clamped, base)
        start_local = start_abs - base + 1
        lines = start_local <= length(DESIGN_LOG_LINES) ?
            DESIGN_LOG_LINES[start_local:end] :
            String[]
        return (base=base, next_since=total, lines=copy(lines))
    end
end

function _query_int(req::HTTP.Request, key::String, default::Int=0)
    target = String(req.target)
    qidx = findfirst('?', target)
    qidx === nothing && return default
    query = target[qidx + 1:end]
    for pair in split(query, '&')
        kv = split(pair, '='; limit=2)
        length(kv) == 2 || continue
        kv[1] == key || continue
        v = _route_coerce_int(kv[2])
        return isnothing(v) ? default : v
    end
    return default
end

"""Return query param value for key, or nothing if absent/invalid."""
function _query_string(req::HTTP.Request, key::String)::Union{String, Nothing}
    target = String(req.target)
    qidx = findfirst('?', target)
    qidx === nothing && return nothing
    query = target[qidx + 1:end]
    for pair in split(query, '&')
        kv = split(pair, '='; limit=2)
        length(kv) == 2 || continue
        strip(lowercase(kv[1])) == key || continue
        return strip(kv[2])
    end
    return nothing
end

# ─── JSON helpers ─────────────────────────────────────────────────────────────

"""Build a JSON HTTP response with the given status code."""
function _json_resp(status_code::Int, obj)
    body = JSON3.write(obj)
    return HTTP.Response(status_code, ["Content-Type" => "application/json"], body)
end

"""HTTP 200 JSON response."""
_json_ok(obj) = _json_resp(200, obj)
"""HTTP 400 JSON response."""
_json_bad(obj) = _json_resp(400, obj)
"""HTTP 500 JSON response."""
_json_err(obj) = _json_resp(500, obj)

"""Parse a JSON request body into `APIInput`, returning `(input, nothing)` on
success or `(nothing, HTTP.Response)` with a 400 error on parse failure."""
function _parse_json_body(req::HTTP.Request)
    try
        input = JSON3.read(String(req.body), APIInput)
        return (input, nothing)
    catch e
        resp = _json_bad(Dict(
            "status" => "error",
            "error" => "ParseError",
            "message" => "Invalid JSON: $(sprint(showerror, e))",
        ))
        return (nothing, resp)
    end
end

"""Build a standard 400 validation-error response from a `ValidationResult`."""
function _validation_error_response(vr::ValidationResult)
    structured = [
        Dict(
            "field" => e.field,
            "value" => e.value,
            "constraint" => e.constraint,
            "allowed" => e.allowed,
            "message" => e.message,
        )
        for e in vr.errors
    ]
    return _json_bad(Dict(
        "status" => "error",
        "error" => "ValidationError",
        "message" => "Validation failed: $(length(vr.errors)) error(s)",
        "errors" => structured,
    ))
end

# ─── Route registration ──────────────────────────────────────────────────────

"""Register all API routes with the Oxygen router."""
function register_routes!()

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
            "has_result" => !isnothing(DESIGN_CACHE.last_result),
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
                "POST /chat" => "LLM chat endpoint (SSE streaming). Body: {mode, messages, params?, geometry_summary?, building_geometry? (same JSON as POST /design geometry, without params), geometry? (alias), session_id?, client_geometry_hash?}. " *
                    "When building_geometry is present, the server derives the same geometry hash as POST /design (params excluded) and injects GEOMETRY_CONTEXT (aligned_with_server, geometry_stale) into the system prompt; client_geometry_hash is optional when structured geometry is sent. " *
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

    # ─── POST /design ─────────────────────────────────────────────────────
    @post "/design" function (req::HTTP.Request)
        (input, err) = _parse_json_body(req)
        !isnothing(err) && return err

        vr = validate_input(input)
        !vr.ok && return _validation_error_response(vr)

        # Queue if server is busy
        if !try_start!(SERVER_STATUS)
            enqueue!(SERVER_STATUS, input)
            _append_design_log!("Request queued while another design is running.")
            return _json_ok(Dict(
                "status" => "queued",
                "message" => "Request queued; will run after current job completes.",
            ))
        end

        # Run design in background so we can return before App Runner's 120s request limit.
        # Client polls GET /status until idle then GET /result for the result.
        DESIGN_CACHE.last_result = nothing
        _reset_design_logs!()
        _append_design_log!("Design request accepted.")
        @async _run_design_loop(input)
        return _json_resp(202, Dict(
            "status" => "accepted",
            "message" => "Design started. Poll GET /status until idle, then GET /result for the result.",
        ))
    end

    # ─── GET /logs ───────────────────────────────────────────────────────
    @get "/logs" function (req::HTTP.Request)
        since = _query_int(req, "since", 0)
        payload = _read_design_logs_since(since)
        return _json_ok(Dict(
            "status" => status_string(SERVER_STATUS),
            "base" => payload.base,
            "next_since" => payload.next_since,
            "lines" => payload.lines,
        ))
    end

    # ─── GET /diagnose ───────────────────────────────────────────────────
    # Returns a high-resolution, machine-readable diagnostic JSON for the last
    # completed design. Three-layer output: engineering (per-element checks),
    # architectural (narrative + goal recommendations), and constraints
    # (lever impact estimates). Designed for LLM agent consumption.
    # Query params:
    #   ?units=imperial|metric  — override display units
    @get "/diagnose" function (req::HTTP.Request)
        st = status_string(SERVER_STATUS)
        if st != "idle"
            return _json_resp(503, Dict(
                "status"  => "running",
                "message" => "Design still in progress. Poll GET /status until idle.",
            ))
        end
        if isnothing(DESIGN_CACHE.last_design)
            return _json_resp(404, Dict(
                "status"  => "error",
                "message" => "No design available. Submit a design first.",
            ))
        end
        report_units = nothing
        units_val = _query_string(req, "units")
        if units_val in ("imperial", "metric")
            report_units = Symbol(units_val)
        end
        try
            payload = if isnothing(report_units)
                get_cached_diagnose(DESIGN_CACHE, DESIGN_CACHE.last_design)
            else
                design_to_diagnose(DESIGN_CACHE.last_design; report_units=report_units)
            end
            return _json_ok(payload)
        catch e
            @error "Diagnose generation failed" exception=(e, catch_backtrace())
            return _json_err(Dict(
                "status"  => "error",
                "message" => "Diagnose generation failed: $(sprint(showerror, e))",
            ))
        end
    end

    # ─── GET /report ─────────────────────────────────────────────────────
    # Returns the engineering report for the last completed design.
    # Query params:
    #   ?units=imperial|metric  — override display units
    #   ?format=json            — structured JSON summary instead of plain text
    @get "/report" function (req::HTTP.Request)
        st = status_string(SERVER_STATUS)
        if st != "idle"
            return _json_resp(503, Dict(
                "status" => "running",
                "message" => "Design still in progress. Poll GET /status until idle.",
            ))
        end
        if isnothing(DESIGN_CACHE.last_design)
            return _json_resp(404, Dict(
                "status" => "error",
                "message" => "No design available. Submit a design first.",
            ))
        end
        report_units = nothing
        units_val = _query_string(req, "units")
        if units_val in ("imperial", "metric")
            report_units = Symbol(units_val)
        end
        fmt = _query_string(req, "format")
        try
            if fmt == "json"
                summary = report_summary_json(DESIGN_CACHE.last_design; report_units=report_units)
                return _json_ok(summary)
            else
                buf = IOBuffer()
                engineering_report(DESIGN_CACHE.last_design; io=buf, report_units=report_units)
                report_text = String(take!(buf))
                return HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], report_text)
            end
        catch e
            @error "Report generation failed" exception=(e, catch_backtrace())
            return _json_err(Dict(
                "status" => "error",
                "message" => "Report generation failed: $(sprint(showerror, e))",
            ))
        end
    end

    # ─── POST /rebuild_visualization ─────────────────────────────────────
    # Rebuilds only the visualization mesh at a new target edge length (meters).
    # Requires a completed design in cache. Body: {"target_edge_m": 0.5}
    @post "/rebuild_visualization" function (req::HTTP.Request)
        st = status_string(SERVER_STATUS)
        if st != "idle"
            return _json_resp(503, Dict(
                "status" => "running",
                "message" => "Server is busy. Wait until idle.",
            ))
        end
        design = DESIGN_CACHE.last_design
        if isnothing(design)
            return _json_resp(404, Dict(
                "status" => "error",
                "message" => "No cached design. Run POST /design first.",
            ))
        end

        body = try
            JSON3.read(String(req.body))
        catch e
            return _json_bad(Dict("status" => "error", "message" => "Invalid JSON: $(sprint(showerror, e))"))
        end

        target_edge_raw = get(body, :target_edge_m, nothing)
        target_edge_val = _route_coerce_float(target_edge_raw)
        if isnothing(target_edge_val) || target_edge_val <= 0
            return _json_bad(Dict(
                "status" => "error",
                "message" => "target_edge_m must be a positive number (meters). Got: $(repr(target_edge_raw))",
            ))
        end
        target_edge = Float64(target_edge_val) * u"m"

        _append_design_log!("Rebuilding visualization mesh (target_edge=$(target_edge_val) m).")
        try
            build_analysis_model!(design; target_edge_length=target_edge)
        catch e
            @warn "rebuild_visualization: build_analysis_model! failed" exception=(e, catch_backtrace())
            _append_design_log!("Visualization rebuild failed: $(sprint(showerror, e))")
            return _json_err(Dict(
                "status" => "error",
                "message" => "build_analysis_model! failed: $(sprint(showerror, e))",
            ))
        end

        du = design.params.display_units
        viz = _serialize_visualization(design, du)

        # Patch the cached result with the new visualization
        prev = DESIGN_CACHE.last_result
        if !isnothing(prev) && prev isa APIOutput
            DESIGN_CACHE.last_result = APIOutput(
                status             = prev.status,
                compute_time_s     = prev.compute_time_s,
                phase_timings      = prev.phase_timings,
                length_unit        = prev.length_unit,
                thickness_unit     = prev.thickness_unit,
                volume_unit        = prev.volume_unit,
                mass_unit          = prev.mass_unit,
                summary            = prev.summary,
                slabs              = prev.slabs,
                columns            = prev.columns,
                beams              = prev.beams,
                foundations         = prev.foundations,
                geometry_hash      = prev.geometry_hash,
                visualization      = viz,
            )
        end

        _append_design_log!("Visualization rebuild complete.")
        return _json_ok(Dict("status" => "ok", "visualization" => viz))
    end

    # ─── GET /result ─────────────────────────────────────────────────────
    # Returns the last completed design result (for async submit-then-poll flow).
    # Use after POST /design returns 202 or "queued": poll GET /status until idle, then GET /result.
    @get "/result" function (req::HTTP.Request)
        st = status_string(SERVER_STATUS)
        if st != "idle"
            return _json_resp(503, Dict(
                "status" => "running",
                "message" => "Design still in progress. Poll GET /status until idle.",
            ))
        end
        if isnothing(DESIGN_CACHE.last_result)
            return _json_resp(404, Dict(
                "status" => "error",
                "message" => "No result available. Submit a design first.",
            ))
        end
        # Plain JSON (no gzip) — avoids client parse errors with AutomaticDecompression.
        return _json_resp(200, DESIGN_CACHE.last_result)
    end

    # ─── Chat routes (LLM-powered assistant) ─────────────────────────
    register_chat_routes!()

    return nothing
end

# ─── Design execution ─────────────────────────────────────────────────────────

"""
    _run_design_loop(input::APIInput) -> Nothing

Execute the design pipeline asynchronously. After completion, checks for
queued requests and processes them before returning to idle. Results are
stored in `DESIGN_CACHE.last_result` for retrieval via `GET /result`.
"""
function _run_design_loop(input::APIInput)
    current_input = input

    try
        while true
            _append_design_log!("Starting design execution.")
            _execute_design(current_input)
            _append_design_log!("Design execution finished.")

            next_input = finish!(SERVER_STATUS)
            if isnothing(next_input)
                _append_design_log!("Server is idle.")
                break
            else
                _append_design_log!("Dequeued next request.")
                current_input = next_input
            end
        end
    catch e
        @error "Design loop crashed — resetting server status" exception=(e, catch_backtrace())
        _append_design_log!("Design loop crashed: $(sprint(showerror, e))")
        DESIGN_CACHE.last_result = APIError(
            status = "error",
            error = string(typeof(e)),
            message = sprint(showerror, e),
            traceback = sprint(Base.show_backtrace, catch_backtrace()),
        )
        finish!(SERVER_STATUS)
    end

    return nothing
end

"""
    _execute_design(input::APIInput) -> HTTP.Response

Run a single design iteration. Uses the geometry cache when possible.
"""
function _execute_design(input::APIInput)
    try
        geo_hash = compute_geometry_hash(input)
        params = json_to_params(input.params, input.units)

        # Check cache — skip skeleton rebuild if geometry unchanged
        if is_geometry_cached(DESIGN_CACHE, geo_hash)
            @info "Geometry cache hit — reusing skeleton/structure"
            _append_design_log!("Geometry cache hit: reusing structure.")
            struc = DESIGN_CACHE.structure
        else
            @info "Building new skeleton from JSON input"
            _append_design_log!("Building new skeleton from input.")
            skel = json_to_skeleton(input)
            
            # Validate that we have at least 2 stories (after rebuild_stories!)
            n_vertices = length(skel.vertices)
            n_stories = length(skel.stories_z)
            if n_stories < 2
                # Collect unique Z coordinates for debugging
                unique_z_debug = if n_vertices > 0
                    z_vals = [ustrip(Meshes.coords(v).z) for v in skel.vertices]
                    sort(unique(round.(z_vals, digits=4)))
                else
                    Float64[]
                end
                
                error_msg = if n_vertices == 0
                    "No vertices found in geometry."
                elseif n_stories == 0
                    "Failed to infer story elevations from $(n_vertices) vertices. " *
                    "Unique Z coordinates: $(unique_z_debug)."
                else
                    "Need at least 2 story elevations (got $n_stories). " *
                    "Found unique Z coordinates: $(unique_z_debug). " *
                    "Ensure vertices have different Z coordinates."
                end
                
                validation_err = Dict(
                    "status" => "error",
                    "error" => "ValidationError",
                    "message" => error_msg,
                    "errors" => [error_msg],
                )
                DESIGN_CACHE.last_result = validation_err
                _append_design_log!("Validation error: $error_msg")
                return _json_bad(validation_err)
            end
            
            struc = BuildingStructure(skel)
            DESIGN_CACHE.geometry_hash = geo_hash
            DESIGN_CACHE.skeleton = skel
            DESIGN_CACHE.structure = struc
        end

        # Thread TraceCollector so solver_trace is populated for GET /diagnose, chat tools
        # (get_solver_trace), and JSON serialization — same as interactive Julia runs.
        tc = TraceCollector()
        design = design_building(struc, params; tc=tc)
        _append_design_log!("Design sizing completed.")
        
        # Build analysis model for visualization (if not already built).
        # This is a fallback — normally built inside design_building before restore.
        if !params.skip_visualization && isnothing(design.asap_model)
            _append_design_log!("Building analysis model for visualization (fallback).")
            target_edge = isnothing(params.visualization_target_edge_m) ? nothing : params.visualization_target_edge_m * u"m"
            try
                build_analysis_model!(design; target_edge_length=target_edge)
            catch e
                @warn "Fallback build_analysis_model! failed — proceeding without shell mesh" exception=(e, catch_backtrace())
                _append_design_log!("Analysis model build failed: $(sprint(showerror, e)). Proceeding with frame-only visualization.")
            end
        end

        output = design_to_json(design; geometry_hash=geo_hash)
        lock(DESIGN_CACHE.lock) do
            DESIGN_CACHE.last_result = output
            DESIGN_CACHE.last_design = design
        end
        invalidate_diagnose_cache!(DESIGN_CACHE)
        _append_design_log!("Design result serialized.")

        # Record in session history for compare_designs / get_design_history
        s = design.summary
        n_fail = count(p -> !p.second.ok, design.columns) +
                 count(p -> !p.second.ok, design.beams) +
                 count(p -> !(p.second.converged && p.second.deflection_ok && p.second.punching_ok), design.slabs) +
                 count(p -> !p.second.ok, design.foundations)
        record_design_history!(DesignHistoryEntry(;
            geometry_hash    = geo_hash,
            all_pass         = s.all_checks_pass,
            critical_ratio   = s.critical_ratio,
            critical_element = s.critical_element,
            embodied_carbon  = s.embodied_carbon,
            n_columns        = length(design.columns),
            n_beams          = length(design.beams),
            n_slabs          = length(design.slabs),
            n_failing        = n_fail,
            source           = "design",
        ))

        return _json_ok(output)

    catch e
        if e isa PreSizingValidationError
            @warn "Pre-sizing validation failed" errors=e.errors
            _append_design_log!("Pre-sizing validation failed: $(join(e.errors, "; "))")
            resp = Dict(
                "status" => "error",
                "error" => "ValidationError",
                "message" => "Method applicability check failed: $(length(e.errors)) violation(s)",
                "errors" => e.errors,
            )
            DESIGN_CACHE.last_result = resp
            return _json_bad(resp)
        end
        @error "Design failed" exception=(e, catch_backtrace())
        _append_design_log!("Design failed: $(sprint(showerror, e))")
        err = APIError(
            status = "error",
            error = string(typeof(e)),
            message = sprint(showerror, e),
            traceback = sprint(Base.show_backtrace, catch_backtrace()),
        )
        DESIGN_CACHE.last_result = err
        return _json_err(err)
    end
end
