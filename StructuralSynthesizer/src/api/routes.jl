# =============================================================================
# API Routes — Oxygen HTTP endpoint definitions
# =============================================================================

using Oxygen
using HTTP

# ─── Global state ─────────────────────────────────────────────────────────────

const DESIGN_CACHE = DesignCache()
const SERVER_STATUS = ServerStatus()
const DESIGN_LOG_LINES = String[]
const DESIGN_LOG_LOCK = ReentrantLock()
const DESIGN_LOG_BASE_INDEX = Ref(0)
const DESIGN_LOG_MAX_LINES = 2000

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
        try
            return parse(Int, kv[2])
        catch
            return default
        end
    end
    return default
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
    return _json_bad(Dict(
        "status" => "error",
        "error" => "ValidationError",
        "message" => "Validation failed: $(length(vr.errors)) error(s)",
        "errors" => vr.errors,
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
        return _json_ok(Dict("state" => status_string(SERVER_STATUS)))
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
            "endpoints" => Dict(
                "POST /design" => "Start design (returns 202 immediately; poll GET /status then GET /result)",
                "POST /validate" => "Validate input without running design",
                "GET /health" => "Server health check",
                "GET /status" => "Server status payload: {state, message?}; states: idle, running, queued",
                "GET /env-check" => "Whether Gurobi env vars are set (presence only, no values)",
                "GET /logs?since=N" => "Streaming design logs; returns lines after cursor N",
                "GET /result" => "Last completed design result (after POST /design and status idle)",
                "GET /schema" => "This documentation",
            ),
        )
        return _json_ok(schema_doc)
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

    # ─── GET /result ─────────────────────────────────────────────────────
    # Returns the last completed design result (for async submit-then-poll flow).
    # Use after POST /design returns 202 or "queued": poll GET /status until idle, then GET /result.
    @get "/result" function (_::HTTP.Request)
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
        return _json_ok(DESIGN_CACHE.last_result)
    end

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

        design = design_building(struc, params)
        _append_design_log!("Design sizing completed.")
        
        # Build analysis model for visualization (if not already built)
        if isnothing(design.asap_model)
            _append_design_log!("Building analysis model for visualization.")
            build_analysis_model!(design)
        end
        
        output = design_to_json(design; geometry_hash=geo_hash)
        DESIGN_CACHE.last_result = output
        _append_design_log!("Design result serialized.")

        return _json_ok(output)

    catch e
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
