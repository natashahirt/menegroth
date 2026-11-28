function _register_session_routes!()

    # ─── POST /reset ─────────────────────────────────────────────────
    # Wipe all session-scoped state so the next interaction starts fresh.
    # Grasshopper should call this on plugin load / document change.
    @post "/reset" function (_::HTTP.Request)
        st = status_string(SERVER_STATUS)
        if st != "idle"
            return _json_resp(503, Dict(
                "status" => "running",
                "message" => "Server is busy. Wait until idle before resetting.",
            ))
        end
        reset_session_state!(DESIGN_CACHE; reason="explicit POST /reset")
        with_cache_write!(DESIGN_CACHE) do c
            c.geometry_hash = ""
            c.skeleton = nothing
            c.structure = nothing
            c.last_result = nothing
            c.last_design = nothing
            c.last_api_params_json = Dict{String, Any}()
            c.design_version = 0
        end
        _reset_design_logs!()
        lock(_CHAT_STRUCTURE_CACHE.lock) do
            _CHAT_STRUCTURE_CACHE.geometry_hash = ""
            _CHAT_STRUCTURE_CACHE.structure = nothing
            _CHAT_STRUCTURE_CACHE.digest = nothing
        end
        return _json_ok(Dict("status" => "ok", "message" => "Design cache and session insights cleared. Chat history preserved — use reset_session in POST /chat to clear conversation."))
    end

    return nothing
end
