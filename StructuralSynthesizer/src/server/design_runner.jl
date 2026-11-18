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
        with_cache_write!(c -> (c.last_result = APIError(
            status = "error",
            error = string(typeof(e)),
            message = sprint(showerror, e),
            traceback = sprint(Base.show_backtrace, catch_backtrace()),
        )), DESIGN_CACHE)
        finish!(SERVER_STATUS)
    end

    return nothing
end

"""
    _design_with_incremental!(struc, params; tc=nothing) -> BuildingDesign

Produce the `BuildingDesign` for `(struc, params)` on the current geometry,
reusing the cached incremental [`DesignSession`](@ref) via
[`redesign_incremental!`](@ref) when the change is **param-only**, otherwise
running a cold [`design_building`](@ref). Shared by POST /design
([`_execute_design`](@ref)) and chat `run_design` so both endpoints take the
exact same decision.

Routing (Phase 2 P0-1 plumbing — never changes a numeric result):

- Kill switch OFF (`SS_API_INCREMENTAL=false`): byte-identical to the historical
  cold-only behavior — a plain `design_building`, no session work at all.
- A cached `session` exists AND no prepare-affecting field differs from the
  session BASE params ([`_param_only_change`](@ref)): reuse it via
  `redesign_incremental!`. On ANY exception the broken session is dropped and we
  fall through to cold — the cold path is the equivalence reference, so when in
  doubt we always return the cold result.
- Otherwise (no session, prepare-affecting change, or incremental failure): run
  cold, then eagerly (re)build a fresh `DesignSession(struc, params)` so the
  NEXT param-only change can reuse it. If session construction throws, the
  session is nil'd and the (already-computed) cold result is still returned.

`DESIGN_CACHE.session` reads/writes and the fresh-session store happen under
`DESIGN_CACHE.lock` (the engine is NOT concurrency-safe). To keep status polling
responsive, the (seconds-to-minutes) `redesign_incremental!` / `design_building`
sizing runs OUTSIDE the lock: the lock is held ONLY to (a) read the session
handle and evaluate [`_param_only_change`](@ref), then released; and (b) store
results / construct the fresh session afterward. This is safe only because
`SERVER_STATUS` serializes designs (`try_start!`/`finish!` spanning the helper at
both call sites — POST /design via `_run_design_loop`, chat `run_design` via its
`@async` task), so no second design can mutate the engine while the lock is
released.
"""
function _design_with_incremental!(struc::BuildingStructure, params::DesignParameters;
                                   tc::Union{Nothing, StructuralSizer.TraceCollector}=nothing)
    # Kill switch OFF → byte-identical historical cold-only path (no session).
    if !_api_incremental_enabled()
        design = _design_building_inplace(struc, params; tc=tc)
        _append_design_log!("Design sizing completed.")
        return design
    end

    # ── Decide the path under a SHORT lock, then release it (Fix #2). ──
    # Only the session read and the param-only predicate run under the lock;
    # the slow sizing below runs lock-free so GET /status, /result, etc. are not
    # blocked. `lock(...) do ... end` always releases the lock even if the
    # predicate throws, and the surrounding try routes any predicate throw to
    # cold (Fix #3): a throw in changed_param_fields/content_hash must never
    # escape as HTTP 500 — cold is always the fallback.
    session = nothing
    use_incremental = false
    try
        session, use_incremental = lock(DESIGN_CACHE.lock) do
            s = DESIGN_CACHE.session
            (isnothing(s) || !_param_only_change(s, params)) && return (nothing, false)
            return (s, true)
        end
    catch e
        @warn "Incremental predicate evaluation failed — falling back to cold design_building" exception=(e, catch_backtrace())
        _append_design_log!("Incremental predicate failed: $(sprint(showerror, e)). Falling back to cold.")
        lock(DESIGN_CACHE.lock) do
            clear_session!(DESIGN_CACHE)  # drop the suspect session; cold path rebuilds it
        end
        session = nothing
        use_incremental = false
    end

    # ── Incremental reuse: engine mutation runs OUTSIDE the lock. ──
    if use_incremental
        try
            d = redesign_incremental!(session.engine, params; tc=tc)
            _append_design_log!("Design sizing completed (incremental reuse).")
            return d
        catch e
            @warn "Incremental redesign failed — falling back to cold design_building" exception=(e, catch_backtrace())
            _append_design_log!("Incremental redesign failed: $(sprint(showerror, e)). Falling back to cold.")
            lock(DESIGN_CACHE.lock) do
                clear_session!(DESIGN_CACHE)  # drop the broken session; cold path rebuilds it
            end
        end
    end

    # ── Cold path: one session construction is both the fresh execution and
    # the reusable engine. The former implementation ran `design_building` and
    # then executed the entire design again while constructing this session.
    try
        fresh_session = DesignSession(struc, params; tc=tc)
        design = base_design(fresh_session)
        lock(DESIGN_CACHE.lock) do
            DESIGN_CACHE.session = fresh_session
            DESIGN_CACHE.session_base_params = fresh_session.context.params
        end
        _append_design_log!("Design sizing completed (fresh session).")
        return design
    catch e
        # Session setup and cold design now share the same lifecycle. Retain a
        # compatibility fallback only so an incremental-only infrastructure
        # defect cannot make the API unavailable.
        @warn "Fresh DesignSession failed — falling back to compatibility cold path" exception=(e, catch_backtrace())
        lock(DESIGN_CACHE.lock) do
            clear_session!(DESIGN_CACHE)
        end
        design = _design_building_inplace(struc, params; tc=tc)
        _append_design_log!("Design sizing completed (compatibility cold path).")
        return design
    end
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
            struc = with_cache_read(c -> c.structure, DESIGN_CACHE)
        else
            @info "Building new skeleton from JSON input"
            _append_design_log!("Building new skeleton from input.")
            prev_hash = with_cache_read(c -> c.geometry_hash, DESIGN_CACHE)
            if !isempty(prev_hash) && prev_hash != geo_hash
                reset_session_state!(DESIGN_CACHE; reason="geometry hash changed (POST /design)")
                lock(_CHAT_STRUCTURE_CACHE.lock) do
                    _CHAT_STRUCTURE_CACHE.geometry_hash = ""
                    _CHAT_STRUCTURE_CACHE.structure = nothing
                    _CHAT_STRUCTURE_CACHE.digest = nothing
                end
                _append_design_log!("Geometry changed — design history/insights cleared (chat preserved).")
            end
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
                
                validation_err = APIError(
                    status = "error",
                    error = "ValidationError",
                    message = error_msg,
                    traceback = "",
                )
                with_cache_write!(c -> (c.last_result = validation_err), DESIGN_CACHE)
                _append_design_log!("Validation error: $error_msg")
                return _json_bad(validation_err)
            end
            
            struc = BuildingStructure(skel)
            lock(DESIGN_CACHE.lock) do
                DESIGN_CACHE.geometry_hash = geo_hash
                DESIGN_CACHE.skeleton = skel
                DESIGN_CACHE.structure = struc
            end
        end

        # Thread TraceCollector so solver_trace is populated for GET /diagnose, chat tools
        # (get_solver_trace), and JSON serialization — same as interactive Julia runs.
        tc = TraceCollector()
        # Param-only changes reuse the cached incremental DesignSession; anything
        # prepare-affecting / uncertain runs cold. Returns the SAME BuildingDesign
        # the cold path would, which the entire downstream tail consumes unchanged.
        design = _design_with_incremental!(struc, params; tc=tc)
        
        # Build analysis model for visualization (if not already built).
        # This is a fallback — normally built inside design_building before restore.
        if !params.skip_visualization && isnothing(design.asap_model)
            _append_design_log!("Building analysis model for visualization (fallback).")
            target_edge = isnothing(params.visualization_target_edge_m) ? nothing : params.visualization_target_edge_m * u"m"
            try
                build_analysis_model!(design; target_edge_length=target_edge)
            catch e
                @warn "Fallback build_analysis_model! failed — the design model is the solved analysis frame" exception=(e, catch_backtrace())
                _append_design_log!("Analysis model build failed: $(sprint(showerror, e)). The design model is the solved analysis frame.")
            end
        end
        isnothing(design.asap_model) && port_analysis_model!(design)

        output = design_to_json(design; geometry_hash=geo_hash)
        api_params_snapshot = try
            JSON3.read(JSON3.write(input.params), Dict{String, Any})
        catch
            Dict{String, Any}()
        end
        # Prepare the history snapshot before publication. No cache-visible
        # success state changes until all artifacts are ready.
        s = design.summary
        n_fail = count(p -> !p.second.ok, design.columns) +
                 count(p -> !p.second.ok, design.beams) +
                 count(p -> !_slab_design_ok(p.second), design.slabs) +
                 count(p -> !p.second.ok, design.foundations)
        api_patch = try
            JSON3.read(JSON3.write(input.params), Dict{String, Any})
        catch
            Dict{String, Any}()
        end
        full_params = try agent_current_params(design) catch; Dict{String, Any}() end
        history_entry = DesignHistoryEntry(;
            geometry_hash     = geo_hash,
            params_patch      = api_patch,
            cumulative_params = full_params,
            all_pass          = s.all_checks_pass,
            critical_ratio    = s.critical_ratio,
            critical_element  = s.critical_element,
            embodied_carbon   = ustrip(u"kgCO2e", s.embodied_carbon),
            n_columns         = length(design.columns),
            n_beams           = length(design.beams),
            n_slabs           = length(design.slabs),
            n_failing         = n_fail,
            source            = "design",
        )
        publish_design_success!(
            DESIGN_CACHE, output, design, api_params_snapshot, history_entry)
        _append_design_log!("Design result serialized and published.")

        return _json_ok(output)

    catch e
        if e isa PreSizingValidationError
            @warn "Pre-sizing validation failed" errors=e.errors
            detail = join(e.errors, "; ")
            _append_design_log!("Pre-sizing validation failed: $detail")
            resp = APIError(
                status = "error",
                error = "ValidationError",
                message = "Method applicability check failed ($(length(e.errors)) violation(s)): $detail",
                traceback = "",
            )
            with_cache_write!(c -> (c.last_result = resp), DESIGN_CACHE)
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
        with_cache_write!(c -> (c.last_result = err), DESIGN_CACHE)
        return _json_err(err)
    end
end
