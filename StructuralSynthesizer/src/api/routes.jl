# =============================================================================
# API Routes — Oxygen HTTP endpoint definitions
# =============================================================================

using Oxygen
using HTTP

# ─── Global state ─────────────────────────────────────────────────────────────

const DESIGN_CACHE = DesignCache()
const SERVER_STATUS = ServerStatus()

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

# ─── Route registration ──────────────────────────────────────────────────────

"""Register all API routes with the Oxygen router."""
function register_routes!()

    # ─── GET /health ──────────────────────────────────────────────────────
    @get "/health" function (_::HTTP.Request)
        return _json_ok(Dict("status" => "ok"))
    end

    # ─── GET /status ──────────────────────────────────────────────────────
    @get "/status" function (_::HTTP.Request)
        return _json_ok(Dict("status" => status_string(SERVER_STATUS)))
    end

    # ─── GET /schema ──────────────────────────────────────────────────────
    @get "/schema" function (_::HTTP.Request)
        schema_doc = Dict(
            "input" => Dict(
                "units" => "Required. Coordinate units: feet, inches, meters, mm",
                "vertices" => "Array of [x,y,z] arrays",
                "edges" => Dict("beams" => "[[v1,v2],...]", "columns" => "[[v1,v2],...]"),
                "supports" => "Array of vertex indices (1-based)",
                "stories_z" => "Array of story elevations in coordinate units",
                "faces" => "Optional. {\"floor\": [[[x,y,z],...]], \"roof\": [...], \"grade\": [...]}",
                "params" => Dict(
                    "unit_system" => "imperial or metric (output display)",
                    "loads" => "floor_LL_psf, roof_LL_psf, floor_SDL_psf, ...",
                    "floor_type" => "flat_plate, flat_slab, one_way, vault",
                    "materials" => "concrete, rebar, steel names",
                    "fire_rating" => "0, 1, 1.5, 2, 3, or 4 hours",
                ),
            ),
            "endpoints" => Dict(
                "POST /design" => "Run full design pipeline",
                "POST /validate" => "Validate input without running design",
                "GET /health" => "Server health check",
                "GET /status" => "Server state: idle, running, queued",
                "GET /schema" => "This documentation",
            ),
        )
        return _json_ok(schema_doc)
    end

    # ─── POST /validate ───────────────────────────────────────────────────
    @post "/validate" function (req::HTTP.Request)
        local input
        try
            input = JSON3.read(String(req.body), APIInput)
        catch e
            return _json_bad(Dict(
                "status" => "error",
                "error" => "ParseError",
                "message" => "Invalid JSON: $(sprint(showerror, e))",
            ))
        end

        result = validate_input(input)
        if result.ok
            return _json_ok(Dict("status" => "ok", "message" => "Input is valid."))
        else
            return _json_bad(Dict(
                "status" => "error",
                "error" => "ValidationError",
                "errors" => result.errors,
            ))
        end
    end

    # ─── POST /design ─────────────────────────────────────────────────────
    @post "/design" function (req::HTTP.Request)
        local input
        try
            input = JSON3.read(String(req.body), APIInput)
        catch e
            return _json_bad(Dict(
                "status" => "error",
                "error" => "ParseError",
                "message" => "Invalid JSON: $(sprint(showerror, e))",
            ))
        end

        # Validate
        vr = validate_input(input)
        if !vr.ok
            return _json_bad(Dict(
                "status" => "error",
                "error" => "ValidationError",
                "errors" => vr.errors,
            ))
        end

        # Queue if server is busy
        if !try_start!(SERVER_STATUS)
            enqueue!(SERVER_STATUS, input)
            return _json_ok(Dict(
                "status" => "queued",
                "message" => "Request queued; will run after current job completes.",
            ))
        end

        # Run design (may loop if queued requests arrive)
        return _run_design_loop(input)
    end

    return nothing
end

# ─── Design execution ─────────────────────────────────────────────────────────

"""
    _run_design_loop(input::APIInput) -> HTTP.Response

Execute the design pipeline. After completion, checks for queued requests
and processes them before returning to idle.
"""
function _run_design_loop(input::APIInput)
    local last_response
    current_input = input

    while true
        last_response = _execute_design(current_input)

        # Check for queued request
        next_input = finish!(SERVER_STATUS)
        if isnothing(next_input)
            break  # No queued request → idle
        else
            current_input = next_input
        end
    end

    return last_response
end

"""
    _execute_design(input::APIInput) -> HTTP.Response

Run a single design iteration. Uses the geometry cache when possible.
"""
function _execute_design(input::APIInput)
    try
        geo_hash = compute_geometry_hash(input)
        params = json_to_params(input.params)

        # Check cache — skip skeleton rebuild if geometry unchanged
        if is_geometry_cached(DESIGN_CACHE, geo_hash)
            @info "Geometry cache hit — reusing skeleton/structure"
            struc = DESIGN_CACHE.structure
        else
            @info "Building new skeleton from JSON input"
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
                
                return _json_bad(Dict(
                    "status" => "error",
                    "error" => "ValidationError",
                    "errors" => [error_msg],
                ))
            end
            
            struc = BuildingStructure(skel)
            DESIGN_CACHE.geometry_hash = geo_hash
            DESIGN_CACHE.skeleton = skel
            DESIGN_CACHE.structure = struc
        end

        design = design_building(struc, params)
        
        # Build analysis model for visualization (if not already built)
        if isnothing(design.asap_model)
            build_analysis_model!(design)
        end
        
        output = design_to_json(design; geometry_hash=geo_hash)
        DESIGN_CACHE.last_result = output

        return _json_ok(output)

    catch e
        @error "Design failed" exception=(e, catch_backtrace())
        err = APIError(
            status = "error",
            error = string(typeof(e)),
            message = sprint(showerror, e),
            traceback = sprint(Base.show_backtrace, catch_backtrace()),
        )
        return _json_err(err)
    end
end
