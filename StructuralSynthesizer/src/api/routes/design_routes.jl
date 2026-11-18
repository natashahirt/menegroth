function _register_design_routes!()

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
        with_cache_write!(c -> (c.last_result = nothing), DESIGN_CACHE)
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

    return nothing
end

function _register_design_result_routes!()

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
        design = with_cache_read(c -> c.last_design, DESIGN_CACHE)
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

        lock(DESIGN_CACHE.lock) do
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
                    walls              = prev.walls,
                    seismic_story_drift = prev.seismic_story_drift,
                    scope_notes        = prev.scope_notes,
                    geometry_hash      = prev.geometry_hash,
                    visualization      = viz,
                )
            end
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
        cached_result = with_cache_read(c -> c.last_result, DESIGN_CACHE)
        if isnothing(cached_result)
            return _json_resp(404, Dict(
                "status" => "error",
                "message" => "No result available. Submit a design first.",
            ))
        end
        # Plain JSON (no gzip) — avoids client parse errors with AutomaticDecompression.
        return _json_resp(200, cached_result)
    end

    return nothing
end
