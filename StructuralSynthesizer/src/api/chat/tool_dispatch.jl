# Timeout for a quick-check design run. Large complex buildings can take 2-5 min
# for a full design; this cap keeps the conversational loop responsive.
const QUICK_DESIGN_TIMEOUT_S = 60.0

# ─── Tool dispatch ────────────────────────────────────────────────────────────

const _NO_DESIGN_HINT   = "No solved design on the server yet. Run Design from Grasshopper (POST /design) first. Until then, use the geometry digest and predict_geometry_effect for qualitative advice."
const _NO_GEOMETRY_HINT = "Server-cached geometry comes from a Grasshopper Design run (POST /design). If a digest is in the prompt, you can still advise on geometry changes via predict_geometry_effect — but run_design and get_building_summary require server geometry."
const CHAT_AUTOWAIT_TIMEOUT_S = 90.0

"""
Upper bound for POST /chat blocking on an in-flight `POST /design` (e.g. Grasshopper).
Uses SSE heartbeats so clients show progress; default matches the Grasshopper poll horizon (~1 h).
Override with env `CHAT_PRE_CHAT_DESIGN_WAIT_TIMEOUT_S` (positive seconds).
"""
function _pre_chat_design_wait_timeout_s()::Float64
    s = strip(get(ENV, "CHAT_PRE_CHAT_DESIGN_WAIT_TIMEOUT_S", ""))
    isempty(s) && return 3600.0
    v = tryparse(Float64, s)
    (isnothing(v) || !isfinite(v) || v <= 0.0) && return 3600.0
    return v
end

# Tools that should prefer waiting for an in-flight design to finish so they
# return the freshest cached result set rather than stale data.
const _TOOLS_REQUIRE_FRESH_DESIGN = Set([
    "get_situation_card",
    "get_result_summary",
    "get_condensed_result",
    "get_current_params",
    "get_design_history",
    "get_diagnose_summary",
    "get_diagnose",
    "query_elements",
    "get_solver_trace",
    "explain_trace_lookup",
    "run_experiment",
    "batch_experiments",
    "suggest_next_action",
    "compare_designs",
    "narrate_element",
    "narrate_comparison",
])

"""Read `DESIGN_CACHE.last_design` under lock to avoid torn reads."""
function _get_last_design()::Union{BuildingDesign, Nothing}
    lock(DESIGN_CACHE.lock) do
        DESIGN_CACHE.last_design
    end
end

"""Wait for the async design loop to return to idle."""
function _wait_until_server_idle(; timeout_s::Float64=CHAT_AUTOWAIT_TIMEOUT_S)::Symbol
    timedwait(() -> status_string(SERVER_STATUS) == "idle", timeout_s; pollint=1.0)
end

"""
Wait until `SERVER_STATUS` is idle, emitting periodic SSE `design_wait` events so the
client connection stays alive and the UI can show that chat is blocked on the design job.

Returns `:ok` or `:timed_out`.
"""
function _wait_until_server_idle_sse!(
    stream::HTTP.Stream;
    timeout_s::Float64,
    heartbeat_s::Float64=15.0,
    pollint::Float64=1.0,
)::Symbol
    t0 = time()
    last_hb = t0
    while status_string(SERVER_STATUS) != "idle"
        now = time()
        if now - t0 >= timeout_s
            return :timed_out
        end
        if now - last_hb >= heartbeat_s
            elapsed = round(Int, now - t0)
            payload = Dict{String, Any}(
                "type"          => "design_wait",
                "phase"         => "polling",
                "message"       => "Waiting for the in-flight design run to finish…",
                "elapsed_s"     => elapsed,
                "server_status" => status_string(SERVER_STATUS),
            )
            write(stream, "data: $(JSON3.write(payload))\n\n")
            last_hb = now
        end
        sleep(pollint)
    end
    return :ok
end

"""Infer coordinate-unit string for chat quick-check runs from cached context."""
function _quick_check_coord_unit()::String
    # Prefer latest solved design context when available.
    d = _get_last_design()
    if !isnothing(d)
        du = d.params.display_units
        return du.units[:length] == u"ft" ? "feet" : "meters"
    end

    # Fallback: infer from cached geometry story elevations.
    struc = with_cache_read(c -> c.structure, DESIGN_CACHE)
    if !isnothing(struc)
        zvals = Float64[]
        for z in struc.skeleton.stories_z
            push!(zvals, z isa Unitful.Quantity ? ustrip(u"m", z) : Float64(z))
        end
        if !isempty(zvals)
            zmax = maximum(abs.(zvals))
            # Meter-coordinate buildings are typically < ~250 m tall.
            # Far larger magnitudes usually indicate feet coordinates.
            return zmax > 250.0 ? "feet" : "meters"
        end
    end
    return "meters"
end

"""
Check if the effective geometry hash (resolved from building_geometry or client_geometry_hash)
differs from the server's cached geometry. Returns a directional warning string, or `nothing`
if aligned or unknown.
"""
function _stale_geometry_warning(args::Dict{String, Any})::Union{Nothing, String}
    cli = strip(string(get(args, "client_geometry_hash", "")))
    resolved = lock(_CHAT_STRUCTURE_CACHE.lock) do
        h = _CHAT_STRUCTURE_CACHE.geometry_hash
        isempty(h) ? "" : h
    end
    effective = !isempty(resolved) ? resolved : cli
    isempty(effective) && return nothing
    srv = strip(_server_geometry_hash())
    isempty(srv) && return nothing
    effective == srv && return nothing

    history = get_design_history_entries()
    client_is_old = any(strip(e.geometry_hash) == effective for e in history)
    if client_is_old
        return "NOTE: The server's cached design (hash=$srv) is NEWER than the chat geometry hash ($effective). " *
               "A Design was completed since the last geometry snapshot. " *
               "Results are current — report them to the user."
    else
        return "GEOMETRY MISMATCH: This tool executed against the server's cached geometry (hash=$srv), " *
               "which differs from the client's current model (hash=$effective). " *
               "Results apply to the CACHED model, not the current Grasshopper geometry. " *
               "Tell the user to run Design from Grasshopper to update the server."
    end
end

"""
Evaluate DDM/EFM applicability checks against actual geometry.

Uses slab panel spans and story count to report which method prerequisites are
met or violated. Returns a Dict with per-method verdicts.
"""
function _evaluate_applicability_against_geometry(struc::BuildingStructure)::Dict{String, Any}
    slabs = struc.slabs
    n_stories = length(struc.skeleton.stories)

    aspect_ratios = Float64[]
    for s in slabs
        l1 = ustrip(u"m", s.spans.primary)
        l2 = ustrip(u"m", s.spans.secondary)
        l2 > 0 && push!(aspect_ratios, l1 / l2)
    end

    ddm_checks = Dict{String, Any}[]

    # DDM §13.6.2.2: minimum 3 continuous spans in each direction
    push!(ddm_checks, Dict{String, Any}(
        "check" => "ddm_min_spans",
        "clause" => "ACI 318 §13.6.2.2",
        "description" => "≥3 continuous spans in each direction",
        "status" => n_stories >= 1 && length(slabs) >= 3 ? "likely_ok" : "may_violate",
        "note" => "$(length(slabs)) slab panels, $(n_stories) stories. Full continuous-span count requires frame topology analysis.",
    ))

    # DDM §13.6.2.2: aspect ratio 0.5 ≤ l₂/l₁ ≤ 2.0
    if !isempty(aspect_ratios)
        min_ar = minimum(aspect_ratios)
        max_ar = maximum(aspect_ratios)
        in_range = all(0.5 .<= aspect_ratios .<= 2.0)
        push!(ddm_checks, Dict{String, Any}(
            "check" => "ddm_aspect_ratio",
            "clause" => "ACI 318 §13.6.2.2",
            "description" => "Panel aspect ratio 0.5 ≤ l₂/l₁ ≤ 2.0",
            "status" => in_range ? "ok" : "violates",
            "min_aspect" => round(min_ar; digits=2),
            "max_aspect" => round(max_ar; digits=2),
        ))
    end

    # DDM §13.6.2.5: successive span lengths differ by ≤ 1/3 of longer span
    primary_spans = [ustrip(u"m", s.spans.primary) for s in slabs]
    sort!(primary_spans)
    span_diff_ok = true
    if length(primary_spans) >= 2
        for i in 2:length(primary_spans)
            diff = abs(primary_spans[i] - primary_spans[i-1])
            if diff > primary_spans[i] / 3
                span_diff_ok = false
                break
            end
        end
    end
    push!(ddm_checks, Dict{String, Any}(
        "check" => "ddm_span_difference",
        "clause" => "ACI 318 §13.6.2.5",
        "description" => "Successive spans differ ≤ ⅓ of longer span",
        "status" => span_diff_ok ? "ok" : "may_violate",
    ))

    return Dict{String, Any}(
        "n_slabs" => length(slabs),
        "n_stories" => n_stories,
        "ddm_checks" => ddm_checks,
        "efm_note" => "EFM (Equivalent Frame Method) handles unequal spans and pattern loading but is built on rectangular panels in rows of supports. Preferred when DDM span checks fail on a rectangular grid.",
        "fea_note" => "FEA handles any panel shape, including skewed, triangular, concave, and holed panels. Use it for irregular geometry.",
    )
end

"""
    _dispatch_chat_tool(tool, args) -> Dict

Dispatch a named structural tool call from the agent. Returns a
JSON-serialisable result dict.

Phase 1 — Orientation:
- `get_situation_card`       — single-call snapshot: geometry + params + health + history + trace availability.
- `get_building_summary`     — detailed geometry summary (stories, spans, counts, regularity).
- `get_design_history`       — past designs in session (params, pass/fail, EC).
- `get_current_params`       — fully resolved parameter set from the last design.
- `get_api_params_ssot`      — raw API JSON merge base (patch debugging; prefer get_current_params for narration).

Phase 2 — Diagnosis:
- `get_diagnose_summary`     — lightweight failure overview: counts, top-5 critical, failure breakdown.
- `get_diagnose`             — high-resolution per-element diagnostics.
- `query_elements`           — filtered element subset from /diagnose data.
- `get_solver_trace`         — tiered solver decision trace.
- `get_lever_map`            — which parameters affect a given failure check.
- `get_implemented_provisions` — design code clause index.
- `explain_field`            — parameter definition, units, range, related checks.
- `get_result_summary`       — structured JSON summary of the latest design result.
- `get_condensed_result`     — plain-text condensed result summary (~500 tokens).
- `get_applicability`        — compact method/floor eligibility rules.

Phase 3 — Exploration:
- `run_experiment`           — instant micro-experiment on a single element.
- `list_experiments`         — available experiment types and arg schemas.
- `batch_experiments`        — run multiple experiments in one call.
- `validate_params`          — check a params patch for compatibility violations.
- `run_design`               — fast parameter-only what-if check (60 s timeout).
- `compare_designs`          — delta table: previous vs latest session history entry.
- `suggest_next_action`      — ranked parameter changes for a goal.

Session Insights:
- `record_insight`           — record a structured learning from a design iteration.
- `get_session_insights`     — retrieve accumulated learnings.

Phase 4 — Communication:
- `narrate_element`          — plain-English explanation of one element.
- `narrate_comparison`       — plain-English previous vs latest run comparison.
- `clarify_user_intent`      — structured multiple-choice clarification.
"""
function _dispatch_chat_tool(tool::String, args::Dict{String, Any})::Dict{String, Any}
    design = _get_last_design()
    struc = with_cache_read(c -> c.structure, DESIGN_CACHE)

    # If a design is currently running, wait briefly for completion on tools
    # that consume result-layer data so the assistant responds with fresh data.
    if tool in _TOOLS_REQUIRE_FRESH_DESIGN && status_string(SERVER_STATUS) != "idle"
        wait_state = _wait_until_server_idle()
        if wait_state == :timed_out
            return Dict{String, Any}(
                "error" => "design_still_running",
                "message" => "A design run is still in progress. I waited, but it has not completed yet.",
                "recovery_hint" => "Retry in a moment, or poll GET /status until idle.",
                "status" => status_string(SERVER_STATUS),
            )
        end
        design = _get_last_design()
        struc = with_cache_read(c -> c.structure, DESIGN_CACHE)
    end

    if tool == "get_result_summary"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return report_summary_json(design)

    elseif tool == "get_condensed_result"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return Dict("text" => condense_result(design))

    elseif tool == "get_applicability"
        base = api_applicability_schema()
        # Enrich with geometry evaluation when geometry is available
        struc_local = with_cache_read(c -> c.structure, DESIGN_CACHE)
        if !isnothing(struc_local)
            base["geometry_evaluation"] = _evaluate_applicability_against_geometry(struc_local)
        end
        return base

    elseif tool == "clarify_user_intent"
        clarification_id = string(get(args, "id", ""))
        prompt_text      = string(get(args, "prompt", ""))
        allow_multiple_raw = get(args, "allow_multiple", false)
        allow_multiple = something(_chat_coerce_bool(allow_multiple_raw), false)
        rationale        = string(get(args, "rationale", ""))
        required_for     = string(get(args, "required_for", ""))
        session_id       = string(get(args, "session_id", ""))
        options_raw      = get(args, "options", Any[])

        isempty(prompt_text) && return Dict(
            "ok"      => false,
            "error"   => "prompt_required",
            "message" => "clarify_user_intent requires a non-empty 'prompt' field.",
        )

        if !(options_raw isa AbstractVector) || isempty(options_raw)
            return Dict(
                "ok"      => false,
                "error"   => "options_required",
                "message" => "clarify_user_intent requires a non-empty options array.",
            )
        end

        options = Vector{Dict{String, String}}()
        for (i, raw_opt) in enumerate(options_raw)
            if raw_opt isa AbstractDict
                oid = string(get(raw_opt, "id", get(raw_opt, :id, "opt_$(i)")))
                lbl = string(get(raw_opt, "label", get(raw_opt, :label, "")))
                isempty(lbl) && continue
                push!(options, Dict("id" => oid, "label" => lbl))
            else
                lbl = string(raw_opt)
                isempty(lbl) && continue
                push!(options, Dict("id" => "opt_$(i)", "label" => lbl))
            end
        end

        isempty(options) && return Dict(
            "ok"      => false,
            "error"   => "options_invalid",
            "message" => "clarify_user_intent options must contain at least one non-empty label.",
        )

        # Limit to four choices for a manageable UI interaction.
        length(options) > 4 && (options = options[1:4])

        isempty(clarification_id) && (clarification_id = lowercase(replace(prompt_text[1:min(end, 24)], r"[^a-zA-Z0-9]+" => "_")))
        is_new = _remember_clarification!(session_id, clarification_id)

        return Dict(
            "ok"      => true,
            "type"    => "clarification",
            "duplicate" => !is_new,
            "clarification" => Dict(
                "id"             => clarification_id,
                "prompt"         => prompt_text,
                "options"        => options,
                "allow_multiple" => allow_multiple,
                "rationale"      => rationale,
                "required_for"   => required_for,
            ),
        )

    # ── Session Insights ──────────────────────────────────────────────────
    elseif tool == "record_insight"
        cat_str = string(get(args, "category", "observation"))
        cat = Symbol(cat_str)
        summary_str = string(get(args, "summary", ""))
        isempty(summary_str) && return Dict("error" => "missing_summary", "message" => "Provide a 'summary' for the insight.")
        detail_str = string(get(args, "detail", ""))
        checks = String[string(c) for c in get(args, "related_checks", String[])]
        params = String[string(p) for p in get(args, "related_params", String[])]
        didx = _chat_coerce_int(get(args, "design_index", 0))
        isnothing(didx) && return Dict("error" => "invalid_design_index", "message" => "design_index must be an integer (0 for general).")
        conf = _chat_coerce_float(get(args, "confidence", 0.5))
        isnothing(conf) && return Dict("error" => "invalid_confidence", "message" => "confidence must be numeric in [0, 1].")
        (conf < 0.0 || conf > 1.0) && return Dict("error" => "invalid_confidence", "message" => "confidence must be in [0, 1]. Got: $conf")

        insight = SessionInsight(;
            category = cat,
            summary = summary_str,
            detail = detail_str,
            related_checks = checks,
            related_params = params,
            design_index = didx,
            confidence = conf,
        )
        record_session_insight!(insight)
        n_total = length(SESSION_INSIGHTS)
        return Dict{String, Any}(
            "ok" => true,
            "message" => "Insight recorded ($(n_total) total in session).",
            "insight" => Dict("category" => cat_str, "summary" => summary_str),
        )

    elseif tool == "get_session_insights"
        cat_arg = get(args, "category", nothing)
        cat = isnothing(cat_arg) ? nothing : Symbol(string(cat_arg))
        check_arg = get(args, "check", nothing)
        check = isnothing(check_arg) ? nothing : string(check_arg)
        param_arg = get(args, "param", nothing)
        param = isnothing(param_arg) ? nothing : string(param_arg)
        min_conf = _chat_coerce_float(get(args, "min_confidence", 0.0))
        isnothing(min_conf) && return Dict("error" => "invalid_min_confidence", "message" => "min_confidence must be numeric.")

        insights = get_session_insights(; category=cat, check=check, param=param, min_confidence=min_conf)
        return Dict{String, Any}(
            "n_insights" => length(insights),
            "insights" => session_insights_to_json(insights),
            "note" => isempty(insights) ? "No insights recorded yet. Use record_insight after observing design outcomes." : nothing,
        )

    # ── Phase 1: Orientation ────────────────────────────────────────────────
    elseif tool == "get_situation_card"
        cli = string(get(args, "client_geometry_hash", ""))
        geo_hash, dv = with_cache_read(c -> (c.geometry_hash, c.design_version), DESIGN_CACHE)
        resolved = lock(_CHAT_STRUCTURE_CACHE.lock) do
            h = _CHAT_STRUCTURE_CACHE.geometry_hash
            isempty(h) ? "" : h
        end
        return agent_situation_card(
            struc,
            design,
            get_design_history_entries();
            server_geometry_hash = geo_hash,
            client_geometry_hash = cli,
            resolved_geometry_hash = resolved,
            design_version = dv,
        )

    elseif tool == "get_building_summary"
        # `design_building` prepares an owned copy and leaves the cached input
        # structure without members. The summary describes the designed building.
        source = !isnothing(design) ? design.structure : struc
        isnothing(source) && return Dict("error" => "no_geometry", "message" => "No geometry loaded. Submit geometry via POST /design first.", "recovery_hint" => _NO_GEOMETRY_HINT)
        return agent_building_summary(source)

    elseif tool == "get_geometry_digest"
        # Try the chat-side structure cache first (from building_geometry in POST /chat)
        cached_digest = lock(_CHAT_STRUCTURE_CACHE.lock) do
            _CHAT_STRUCTURE_CACHE.digest
        end
        if !isnothing(cached_digest)
            cached_digest["_source"] = "chat_structure_cache"
            cached_digest["_plaintext"] = _structure_digest_plaintext(cached_digest)
            return cached_digest
        end
        # Fall back: the designed copy when a design exists, otherwise the cached input.
        source = !isnothing(design) ? design.structure : struc
        if !isnothing(source)
            digest = try
                _structure_geometry_digest(source)
            catch e
                @warn "get_geometry_digest: digest from server structure failed" exception=(e, catch_backtrace())
                nothing
            end
            if !isnothing(digest)
                digest["_source"] = "design_cache_structure"
                digest["_plaintext"] = _structure_digest_plaintext(digest)
                return digest
            end
        end
        return Dict{String, Any}(
            "error" => "no_geometry",
            "message" => "No geometry available. Neither chat building_geometry nor server POST /design geometry is loaded.",
            "recovery_hint" => _NO_GEOMETRY_HINT,
        )

    elseif tool == "get_current_params"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return agent_current_params(design)

    elseif tool == "get_api_params_ssot"
        return agent_api_params_ssot()

    elseif tool == "get_design_history"
        entries = get_design_history_entries()
        isempty(entries) && return Dict("history" => [], "message" => "No designs in session history yet.")
        return Dict("history" => design_history_to_json(entries), "count" => length(entries))

    # ── Phase 2: Diagnosis ───────────────────────────────────────────────────
    elseif tool == "get_diagnose_summary"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        return agent_diagnose_summary(design)

    elseif tool == "get_diagnose"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        units_arg = get(args, "units", nothing)
        report_units = nothing
        if !isnothing(units_arg)
            units_str = lowercase(strip(string(units_arg)))
            if units_str in ("imperial", "metric")
                report_units = Symbol(units_str)
            else
                return Dict("error" => "invalid_units", "message" => "units must be \"imperial\" or \"metric\".")
            end
        end
        return design_to_diagnose(design; report_units=report_units)

    elseif tool == "query_elements"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        min_ratio_raw = get(args, "min_ratio", nothing)
        max_ratio_raw = get(args, "max_ratio", nothing)
        ok_raw = get(args, "ok", nothing)
        min_ratio = isnothing(min_ratio_raw) ? nothing : _chat_coerce_float(min_ratio_raw)
        max_ratio = isnothing(max_ratio_raw) ? nothing : _chat_coerce_float(max_ratio_raw)
        ok_val = isnothing(ok_raw) ? nothing : _chat_coerce_bool(ok_raw)
        ( !isnothing(min_ratio_raw) && isnothing(min_ratio) ) && return Dict("error" => "invalid_min_ratio", "message" => "min_ratio must be numeric.")
        ( !isnothing(max_ratio_raw) && isnothing(max_ratio) ) && return Dict("error" => "invalid_max_ratio", "message" => "max_ratio must be numeric.")
        ( !isnothing(ok_raw) && isnothing(ok_val) ) && return Dict("error" => "invalid_ok", "message" => "ok must be boolean (true/false).")
        story_raw = get(args, "story", nothing)
        story_val = isnothing(story_raw) ? nothing : _chat_coerce_int(story_raw)
        return agent_query_elements(design;
            type             = let t = get(args, "type", nothing); isnothing(t) ? nothing : string(t) end,
            min_ratio        = min_ratio,
            max_ratio        = max_ratio,
            governing_check  = let gc = get(args, "governing_check", nothing); isnothing(gc) ? nothing : string(gc) end,
            ok               = ok_val,
            story            = story_val,
        )

    elseif tool == "get_solver_trace"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        tier_arg    = lowercase(strip(string(get(args, "tier", "failures"))))
        element_arg = get(args, "element", nothing)
        layer_arg   = get(args, "layer", nothing)
        !(tier_arg in ("summary", "failures", "decisions", "full")) &&
            return Dict("error" => "invalid_tier", "message" => "tier must be one of: summary, failures, decisions, full.")
        tier_sym    = Symbol(tier_arg)
        layer_sym   = if isnothing(layer_arg)
            nothing
        else
            layer_str = lowercase(strip(string(layer_arg)))
            if layer_str in ("pipeline", "workflow", "sizing", "optimizer", "checker", "slab")
                Symbol(layer_str)
            else
                return Dict("error" => "invalid_layer", "message" => "layer must be one of: pipeline, workflow, sizing, optimizer, checker, slab.")
            end
        end
        return agent_solver_trace(design;
            tier    = tier_sym,
            element = isnothing(element_arg) ? nothing : string(element_arg),
            layer   = layer_sym,
        )

    elseif tool == "explain_trace_lookup"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        lookup_raw = get(args, "lookup", nothing)
        isnothing(lookup_raw) && return Dict("error" => "missing_lookup", "message" => "Provide a 'lookup' object from a breadcrumb bundle (top_elements[].lookup).")
        lookup = lookup_raw isa AbstractDict ? Dict{String, Any}(string(k) => v for (k, v) in lookup_raw) :
                 Dict{String, Any}("raw" => lookup_raw)
        return agent_explain_trace_lookup(design; lookup=lookup)

    elseif tool == "get_lever_map"
        check_arg = get(args, "check", nothing)
        return get_lever_map(; check=isnothing(check_arg) ? nothing : string(check_arg))

    elseif tool == "get_implemented_provisions"
        code_arg = get(args, "code", nothing)
        return get_provisions(; code=isnothing(code_arg) ? nothing : string(code_arg))

    elseif tool == "explain_field"
        field = get(args, "field", nothing)
        isnothing(field) && return Dict("error" => "missing_field", "message" => "Provide a 'field' argument (e.g., \"deflection_limit\").")
        return agent_explain_field(string(field))

    elseif tool == "get_provision_rationale"
        section = get(args, "section", nothing)
        isnothing(section) && return Dict("error" => "missing_section", "message" => "Provide a 'section' argument (e.g., \"22.6\", \"H1\", \"ACI_318.22.6\", or a check family like \"punching_shear\").")
        entry = get_provision_ontology(string(section))
        if isnothing(entry)
            return Dict{String, Any}(
                "error"   => "provision_not_found",
                "message" => "No ontology entry for \"$section\". " *
                    "Available sections: $(join(sort(collect(keys(PROVISION_ONTOLOGY))), ", ")). " *
                    "Check families: $(join(sort(collect(keys(CHECK_FAMILY_TO_PROVISION))), ", ")).",
                "recovery_hint" => "Try a section number (\"22.6\"), full key (\"ACI_318.22.6\"), or check family name (\"punching_shear\").",
            )
        end
        return entry

    # ── Phase 3: Exploration ─────────────────────────────────────────────────
    elseif tool == "compare_designs"
        return agent_compare_previous_vs_current()

    elseif tool == "suggest_next_action"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        goal = get(args, "goal", nothing)
        isnothing(goal) && return Dict("error" => "missing_goal", "message" => "Provide a 'goal' argument (fix_failures, reduce_column_size, reduce_slab_thickness, reduce_ec).")
        return agent_suggest_next_action(design, string(goal))

    elseif tool == "predict_geometry_effect"
        variable  = get(args, "variable", nothing)
        direction = get(args, "direction", nothing)
        isnothing(variable) && return Dict("error" => "missing_variable", "message" => "Provide 'variable' (span_length, story_height, column_count, column_spacing_uniformity, plan_aspect_ratio).")
        isnothing(direction) && return Dict("error" => "missing_direction", "message" => "Provide 'direction' (increase, decrease).")
        return agent_predict_geometry_effect(string(variable), string(direction))

    elseif tool == "run_experiment"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        exp_type = get(args, "type", nothing)
        exp_args = get(args, "args", Dict{String, Any}())
        isnothing(exp_type) && return Dict("error" => "missing_type", "message" => "Provide experiment 'type' (punching, pm_column, beam, punching_reinforcement, punching_column_downsize, deflection, catalog_screen).")
        !(exp_args isa AbstractDict) && return Dict("error" => "invalid_args", "message" => "run_experiment args must be an object.")
        exp_args_dict = Dict{String, Any}(string(k) => v for (k, v) in exp_args)
        result = evaluate_experiment(design, string(exp_type), exp_args_dict)
        geo_warn = _stale_geometry_warning(args)
        !isnothing(geo_warn) && (result["geometry_warning"] = geo_warn)
        return result

    elseif tool == "list_experiments"
        return list_experiments()

    elseif tool == "batch_experiments"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        experiments_raw = get(args, "experiments", Any[])
        !(experiments_raw isa AbstractVector) && return Dict("error" => "invalid_experiments", "message" => "experiments must be an array of {type,args} objects.")
        for e in experiments_raw
            !(e isa AbstractDict) && return Dict("error" => "invalid_experiments", "message" => "Each experiments entry must be an object with type and args.")
        end
        experiments = [Dict{String, Any}(string(k) => v for (k, v) in e) for e in experiments_raw]
        return batch_evaluate(design, experiments)

    # ── Phase 4: Communication ───────────────────────────────────────────────
    elseif tool == "narrate_element"
        isnothing(design) && return Dict("error" => "no_design", "message" => "No design has been run yet.", "recovery_hint" => _NO_DESIGN_HINT)
        etype    = get(args, "element_type", nothing)
        eid      = _chat_coerce_int(get(args, "element_id", nothing))
        audience = get(args, "audience", "architect")
        (isnothing(etype) || isnothing(eid)) && return Dict("error" => "missing_args", "message" => "Provide element_type and element_id.")
        return agent_narrate_element(design, string(etype), eid, string(audience))

    elseif tool == "narrate_comparison"
        audience = get(args, "audience", "architect")
        return agent_narrate_comparison(string(audience))

    # ── Original tools ───────────────────────────────────────────────────────
    elseif tool == "validate_params"
        param_patch = Dict{String, Any}(string(k) => v for (k, v) in get(args, "params", Dict()))
        if isempty(param_patch)
            return Dict{String, Any}(
                "ok" => true,
                "violations" => Dict{String, Any}[],
                "warnings" => String[],
                "note" => "Empty params patch — nothing to validate.",
            )
        end
        merge_raw = get(args, "merge_with_ssot", true)
        merge_ssot = merge_raw isa Bool ? merge_raw :
            (merge_raw isa Integer ? merge_raw != 0 :
             merge_raw isa AbstractString ? lowercase(strip(string(merge_raw))) in ("true", "1", "yes", "y") : true)
        patch_norm = _normalize_flat_patch(param_patch)
        to_validate = merge_ssot ? _chat_merge_api_params_patch(patch_norm) : patch_norm
        res = _validate_params_patch(to_validate)
        res["validated_against_ssot"] = merge_ssot
        return res

    elseif tool == "run_design"
        # ── Guard: server state ──────────────────────────────────────────────
        if status_string(SERVER_STATUS) != "idle"
            return Dict(
                "error"          => "server_busy",
                "message"        => "A design is already running. Wait until the server is idle, then retry.",
                "recovery_hint"  => "Wait for the current design to finish, then retry.",
            )
        end
        cached_struc = with_cache_read(c -> c.structure, DESIGN_CACHE)
        isnothing(cached_struc) && return Dict(
            "error"          => "no_geometry",
            "message"        => "No server-cached geometry for run_design. Run Design from Grasshopper (POST /design) first. A chat digest does not populate the design cache.",
            "recovery_hint"  => _NO_GEOMETRY_HINT,
        )

        param_patch_raw = get(args, "params", nothing)
        isnothing(param_patch_raw) && return Dict(
            "error"   => "params_required",
            "message" => "Provide the parameter patch in args.params.",
        )
        !(param_patch_raw isa AbstractDict) && return Dict(
            "error"   => "invalid_params",
            "message" => "args.params must be an object (key-value parameter patch).",
        )

        # ── Classify patch keys ──────────────────────────────────────────────
        patch_dict = Dict{String, Any}(string(k) => v for (k, v) in param_patch_raw)
        api_keys, geo_hints, other_unknown = _classify_patch(patch_dict)

        # If the patch is ENTIRELY geometric (no API params changed), skip the
        # design run and return actionable Grasshopper guidance instead.
        if isempty(api_keys) && !isempty(geo_hints)
            return Dict(
                "error"            => "geometric_change_required",
                "geometric_fields" => geo_hints,
                "message"          => "This recommendation requires changing the building geometry in Grasshopper. " *
                    "The following are geometry properties, not API parameters: $(join(geo_hints, ", ")). " *
                    "Adjust the Rhino model or the GeometryInput component, then re-run the design from Grasshopper.",
                "note"             => "run_design only applies changes to API parameters (floor type, material, loads, sizing strategy, etc.). " *
                    "Geometric changes — column positions, bay dimensions, story heights, setbacks — must be made in Grasshopper.",
            )
        end

        # Promote flat nested keys (e.g. "punching_strategy") into their proper
        # sub-struct so JSON3 deserialization sees them.
        patch_dict = _normalize_flat_patch(patch_dict)

        # ── Single source of truth: merge patch into server api_params snapshot ──
        # (last POST /design or last successful chat run_design), then overwrite
        # that snapshot entirely after success — no separate "original" params.
        merged = _chat_merge_api_params_patch(patch_dict)

        # Build fast-mode patch: force skip_visualization and cap iterations/MIP
        # to keep the conversational loop responsive.
        fast_patch = copy(merged)
        fast_patch["skip_visualization"]  = true
        max_iter = something(_chat_coerce_int(get(fast_patch, "max_iterations", 20)), 20)
        mip_limit = something(_chat_coerce_float(get(fast_patch, "mip_time_limit_sec", 30.0)), 30.0)
        fast_patch["max_iterations"]      = max(1, min(max_iter, 2))
        fast_patch["mip_time_limit_sec"]  = max(1.0, min(mip_limit, 20.0))

        # ── Acquire server lock ──────────────────────────────────────────────
        if !try_start!(SERVER_STATUS)
            return Dict("error" => "server_busy", "message" => "Server became busy — retry in a moment.", "recovery_hint" => "Wait for the current design to finish, then retry.")
        end

        # ── Parse params ─────────────────────────────────────────────────────
        local fast_params
        coord_unit_assumed = _quick_check_coord_unit()
        try
            api_params = JSON3.read(JSON3.write(fast_patch), APIParams)
            fast_params = json_to_params(api_params, coord_unit_assumed)
        catch e
            finish!(SERVER_STATUS)
            return Dict("error" => "param_parse_failed", "message" => sprint(showerror, e))
        end

        # ── Run design with timeout ──────────────────────────────────────────
        # The async task always calls finish!() in its finally block, so the
        # server returns to idle even if we time out and return early here.
        result_ref = Ref{Any}(nothing)
        error_ref  = Ref{Any}(nothing)

        cached_geo_hash = with_cache_read(c -> c.geometry_hash, DESIGN_CACHE)

        design_task = @async begin
            try
                tc = TraceCollector()
                # Param-only changes reuse the cached incremental DesignSession
                # (same decision as POST /design); prepare-affecting / uncertain
                # changes run cold. The returned BuildingDesign is consumed
                # identically regardless of which path produced it. Session
                # reads/writes + engine mutation happen under DESIGN_CACHE.lock
                # inside the helper; this task is serialized by SERVER_STATUS.
                d = _design_with_incremental!(cached_struc, fast_params; tc=tc)
                output = design_to_json(d; geometry_hash=cached_geo_hash)
                s = d.summary
                n_fail = count(p -> !p.second.ok, d.columns) +
                         count(p -> !p.second.ok, d.beams) +
                         count(p -> !_slab_design_ok(p.second), d.slabs) +
                         count(p -> !p.second.ok, d.foundations)
                full_params = try
                    agent_current_params(d)
                catch
                    Dict{String, Any}()
                end
                history_entry = DesignHistoryEntry(;
                    geometry_hash=cached_geo_hash,
                    params_patch=patch_dict,
                    cumulative_params=full_params,
                    all_pass=s.all_checks_pass,
                    critical_ratio=s.critical_ratio,
                    critical_element=s.critical_element,
                    embodied_carbon=ustrip(u"kgCO2e", s.embodied_carbon),
                    n_columns=length(d.columns),
                    n_beams=length(d.beams),
                    n_slabs=length(d.slabs),
                    n_failing=n_fail,
                    source="run_design",
                )
                publish_design_success!(
                    DESIGN_CACHE, output, d, copy(merged), history_entry)
                result_ref[] = d
            catch e
                @error "run_design task failed" exception=(e, catch_backtrace())
                error_ref[] = e
            finally
                finish!(SERVER_STATUS)
            end
        end

        wait_status = timedwait(() -> istaskdone(design_task), QUICK_DESIGN_TIMEOUT_S; pollint=2.0)

        if wait_status == :timed_out
            # Task still running in the background; server will become idle when it finishes.
            return Dict(
                "error"         => "timeout",
                "timeout_s"     => QUICK_DESIGN_TIMEOUT_S,
                "message"       => "Quick check timed out after $(Int(QUICK_DESIGN_TIMEOUT_S))s. " *
                    "This parameter combination triggers a long computation (large building, slow optimizer, or EFM/FEA). " *
                    "The design is still running in the background — check GET /status and try get_condensed_result when idle.",
                "recovery_hint" => "Design took too long. Simplify params or run from Grasshopper for a full run.",
                "suggestions"   => [
                    "Reduce mip_time_limit_sec to 15 and retry.",
                    "Try validate_params first to check compatibility before a full run.",
                    "Run the full design from Grasshopper instead.",
                ],
            )
        end

        if !isnothing(error_ref[])
            return Dict(
                "error"          => "design_failed",
                "message"        => sprint(showerror, error_ref[]),
                "params_rolled_back" => true,
                "recovery_hint"  => "The design failed and the parameter snapshot was rolled back to its pre-attempt state. " *
                    "Retrying with the same params will re-apply the patch correctly.",
            )
        end

        design = result_ref[]

        # ── Build result ─────────────────────────────────────────────────────
        warnings = String[]
        if !isempty(geo_hints)
            push!(warnings, "Geometric hints ignored (not API parameters): $(join(geo_hints, ", ")). Apply these changes in Grasshopper.")
        end
        if !isempty(other_unknown)
            push!(warnings, "Unknown fields ignored: $(join(other_unknown, ", ")).")
        end

        geo_warn = _stale_geometry_warning(args)
        !isnothing(geo_warn) && push!(warnings, geo_warn)

        n_history = length(get_design_history_entries())
        guidance_parts = String["RECORD: Call record_insight to log what this run taught you."]
        if n_history >= 2
            push!(guidance_parts,
                "COMPARE: Call compare_designs (no arguments) — it compares the **previous** run to **this** run automatically. " *
                "Present as previous → current; do not use 'design A/B' labels.")
        end
        if n_history >= 3
            push!(guidance_parts,
                "SMALL DELTAS: After a geometry-driven change (earlier run), a later parameter-only tweak " *
                "(e.g. punching_strategy) often moves embodied carbon and critical_ratio only slightly — " *
                "rebar/studs vs thicker columns can trade steel for concrete without a big EC swing. " *
                "Say so if compare_designs shows tiny deltas; do not imply the run failed to apply.")
        end
        if !design.summary.all_checks_pass
            push!(guidance_parts,
                "FAILURES: Call get_diagnose_summary to identify which checks are failing and why.")
        end

        result = Dict(
            "ok"               => true,
            "quick_check"      => true,
            "coord_unit_assumed" => coord_unit_assumed,
            "applied_params"   => api_keys,
            "summary"          => condense_result(design),
            "all_pass"         => design.summary.all_checks_pass,
            "critical_element" => design.summary.critical_element,
            "critical_ratio"   => design.summary.critical_ratio,
            "embodied_carbon_kgco2e" => round(ustrip(u"kgCO2e", design.summary.embodied_carbon); digits=0),
            "n_failing"        => n_fail,
            "warnings"         => warnings,
            "note"             => "Quick-check result: visualization skipped, max 2 sizing iterations, MIP capped at 20s. " *
                "Ratios may shift slightly in a full run. The canvas will update on next Grasshopper solve.",
            "_guidance"        => join(guidance_parts, "\n"),
        )
        return result

    elseif tool == "get_response_guidelines"
        return agent_response_guidelines()

    else
        return Dict(
            "error"   => "unknown_tool",
            "message" => "Unknown tool: \"$tool\". Available: " *
                "get_situation_card, get_building_summary, get_geometry_digest, get_design_history, get_current_params, get_api_params_ssot, " *
                "get_diagnose_summary, get_diagnose, query_elements, get_solver_trace, " *
                "get_lever_map, get_implemented_provisions, get_provision_rationale, explain_field, " *
                "get_result_summary, get_condensed_result, get_applicability, explain_trace_lookup, " *
                "run_experiment, list_experiments, batch_experiments, " *
                "validate_params, run_design, compare_designs, suggest_next_action, predict_geometry_effect, " *
                "record_insight, get_session_insights, get_response_guidelines, " *
                "narrate_element, narrate_comparison, clarify_user_intent.",
        )
    end
end

