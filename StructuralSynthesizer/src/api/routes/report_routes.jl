function _register_report_routes!()

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
        cached_design = with_cache_read(c -> c.last_design, DESIGN_CACHE)
        if isnothing(cached_design)
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
                get_cached_diagnose(DESIGN_CACHE, cached_design)
            else
                design_to_diagnose(cached_design; report_units=report_units)
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
        cached_design = with_cache_read(c -> c.last_design, DESIGN_CACHE)
        if isnothing(cached_design)
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
                summary = report_summary_json(cached_design; report_units=report_units)
                return _json_ok(summary)
            else
                buf = IOBuffer()
                engineering_report(cached_design; io=buf, report_units=report_units)
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

    return nothing
end
