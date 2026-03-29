# =============================================================================
# Tests for the LLM chat backend: system prompt assembly, suggestions
# extraction, session history, tool dispatch, and schema structure.
# These are offline unit tests — no real LLM connection is required.
# =============================================================================

using StructuralSynthesizer
using StructuralSynthesizer:
    _extract_suggestions,
    _extract_clarification_prompt,
    _get_history, _append_history!, _clear_history!,
    _remember_clarification!, CHAT_CLARIFICATION_KEYS,
    CHAT_HISTORY, _SUGGESTIONS_START, _SUGGESTIONS_END, _CLARIFY_START, _CLARIFY_END,
    _dispatch_chat_tool, _classify_patch,
    _build_turn_summary, _normalize_clarification,
    _query_int, _route_coerce_int, _route_coerce_float,
    _build_system_prompt, _estimate_tokens, MAX_CONTEXT_TOKENS, _SYSTEM_PROMPT_BUDGET_FRACTION,
    agent_response_guidelines, agent_building_summary,
    api_applicability_schema, api_params_schema_structured, api_tool_schema
using Test
using HTTP

println("Testing chat API…")

@testset "Chat API" begin

    # ─── Route parsing/coercion helpers ─────────────────────────────────────
    @testset "Route coercion helpers" begin
        @test _route_coerce_int(5) == 5
        @test _route_coerce_int("7") == 7
        @test _route_coerce_int("7.0") == 7
        @test isnothing(_route_coerce_int("7.2"))
        @test isnothing(_route_coerce_int("bad"))

        @test _route_coerce_float(0.5) == 0.5
        @test _route_coerce_float("0.5") == 0.5
        @test _route_coerce_float("1,200.25") == 1200.25
        @test isnothing(_route_coerce_float("bad"))
    end

    @testset "_query_int tolerates numeric strings" begin
        req_ok = HTTP.Request("GET", "/logs?since=12")
        @test _query_int(req_ok, "since", 0) == 12

        req_float = HTTP.Request("GET", "/logs?since=12.0")
        @test _query_int(req_float, "since", 0) == 12

        req_bad = HTTP.Request("GET", "/logs?since=bad")
        @test _query_int(req_bad, "since", 9) == 9
    end

    # ─── Suggestions extraction ─────────────────────────────────────────────
    @testset "Suggestions extraction" begin
        text_with_suggestions = """
        Here is my analysis of the flat plate system.

        The spans are moderate and DDM is applicable.

        $_SUGGESTIONS_START
        • What live load do you anticipate for this occupancy?
        • Should we prioritize embodied carbon or structural efficiency?
        • Would you like to explore a flat slab with drop panels?
        $_SUGGESTIONS_END
        """

        suggestions = _extract_suggestions(text_with_suggestions)
        @test length(suggestions) == 3
        @test any(s -> occursin("live load", s), suggestions)
        @test any(s -> occursin("embodied carbon", s), suggestions)
        @test any(s -> occursin("flat slab", s), suggestions)
    end

    @testset "Suggestions extraction — no block" begin
        @test _extract_suggestions("No suggestions block here.") == String[]
    end

    @testset "Suggestions extraction — malformed block (missing end)" begin
        text = """
        Analysis complete.
        $_SUGGESTIONS_START
        • Question one
        """
        @test _extract_suggestions(text) == String[]
    end

    @testset "Suggestions extraction — mixed bullet styles" begin
        text = """
        Result.
        $_SUGGESTIONS_START
        • Bullet with dot
        - Dash bullet
        * Star bullet
        $_SUGGESTIONS_END
        """
        suggestions = _extract_suggestions(text)
        @test length(suggestions) == 3
    end

    @testset "Clarification extraction — valid block" begin
        text = """
        Let's lock one priority before proceeding.
        $_CLARIFY_START
        {"id":"design_priority","prompt":"Which objective should dominate?","options":[{"id":"carbon","label":"Minimize embodied carbon"},{"id":"cost","label":"Minimize cost"}],"allow_multiple":false,"required_for":"target optimization direction"}
        $_CLARIFY_END
        """
        c = _extract_clarification_prompt(text)
        @test !isnothing(c)
        @test c["id"] == "design_priority"
        @test c["allow_multiple"] == false
    end

    @testset "Clarification extraction — malformed block" begin
        bad = """
        $_CLARIFY_START
        not-json
        $_CLARIFY_END
        """
        @test isnothing(_extract_clarification_prompt(bad))
    end

    # ─── Session history ────────────────────────────────────────────────────
    @testset "Session history" begin
        session = "test_session_$(rand(1000:9999))"

        # Empty history for new session
        @test _get_history(session) == []

        # Append and retrieve
        _append_history!(session, "user", "Hello!")
        _append_history!(session, "assistant", "Hi there!")

        h = _get_history(session)
        @test length(h) == 2
        @test h[1]["role"] == "user"
        @test h[1]["content"] == "Hello!"
        @test h[2]["role"] == "assistant"
        @test h[2]["content"] == "Hi there!"

        # Clear specific session
        _clear_history!(session)
        @test _get_history(session) == []
    end

    @testset "Session history — clear all" begin
        _append_history!("sess_a", "user", "msg a")
        _append_history!("sess_b", "user", "msg b")
        _clear_history!("all")
        @test _get_history("sess_a") == []
        @test _get_history("sess_b") == []
    end

    # ─── Tool dispatch (offline — no server required) ───────────────────────
    @testset "Tool dispatch — unknown tool" begin
        result = _dispatch_chat_tool("nonexistent_tool", Dict{String,Any}())
        @test haskey(result, "error")
        @test result["error"] == "unknown_tool"
    end

    @testset "Tool dispatch — validate_params (no violations)" begin
        args = Dict{String,Any}(
            "params" => Dict("floor_type" => "flat_plate", "column_type" => "rc_rect"),
        )
        result = _dispatch_chat_tool("validate_params", args)
        @test haskey(result, "ok")
        @test result["ok"] == true
        @test isempty(result["violations"])
    end

    @testset "Tool dispatch — validate_params (violation)" begin
        # flat_plate/flat_slab require RC columns; steel_w should be rejected.
        args = Dict{String,Any}(
            "params" => Dict("floor_type" => "flat_plate", "column_type" => "steel_w"),
        )
        result = _dispatch_chat_tool("validate_params", args)
        @test haskey(result, "ok")
        @test result["ok"] == false
        @test !isempty(result["violations"])
    end

    @testset "Tool dispatch — get_applicability" begin
        result = _dispatch_chat_tool("get_applicability", Dict{String,Any}())
        @test haskey(result, "rules")
        @test haskey(result["rules"], "floor_type")
        @test haskey(result["rules"], "analysis_method")
    end

    @testset "Tool dispatch — clarify_user_intent" begin
        args = Dict{String,Any}(
            "id" => "design_priority",
            "prompt" => "What should we optimize first?",
            "options" => Any[
                Dict("id" => "carbon", "label" => "Embodied carbon"),
                Dict("id" => "cost", "label" => "Cost"),
            ],
            "allow_multiple" => false,
            "session_id" => "clarify_test_sess",
        )
        result = _dispatch_chat_tool("clarify_user_intent", args)
        @test result["ok"] == true
        @test result["type"] == "clarification"
        @test haskey(result, "clarification")
        @test result["clarification"]["id"] == "design_priority"
        @test length(result["clarification"]["options"]) == 2
    end

    @testset "Tool dispatch — get_result_summary (no design)" begin
        # With no cached design, expect a no_design error.
        result = _dispatch_chat_tool("get_result_summary", Dict{String,Any}())
        @test haskey(result, "error")
        @test result["error"] == "no_design"
    end

    @testset "Tool dispatch — run_design (no geometry)" begin
        result = _dispatch_chat_tool("run_design", Dict{String,Any}(
            "params" => Dict("floor_type" => "flat_plate"),
        ))
        @test haskey(result, "error")
        # Expect either no_geometry or server_busy (no cached structure in test env)
        @test result["error"] in ("no_geometry", "server_busy")
    end

    @testset "Tool dispatch — run_design rejects purely geometric patch" begin
        result = _dispatch_chat_tool("run_design", Dict{String,Any}(
            "params" => Dict("column_spacing" => 25, "bay_width" => 30),
        ))
        @test haskey(result, "error")
        # If no geometry is cached, run_design exits earlier with no_geometry.
        # If geometry is cached, the geometric-only patch is rejected explicitly.
        @test result["error"] in ("no_geometry", "geometric_change_required")
        if result["error"] == "geometric_change_required"
            @test haskey(result, "geometric_fields")
            @test !isempty(result["geometric_fields"])
        end
    end

    # ─── Patch classification ────────────────────────────────────────────────
    @testset "Patch classification — all API params" begin
        api_keys, geo_hints, other = _classify_patch(Dict(
            "floor_type" => "flat_slab",
            "column_type" => "rc_rect",
            "max_iterations" => 3,
        ))
        @test length(api_keys) == 3
        @test isempty(geo_hints)
        @test isempty(other)
    end

    @testset "Patch classification — purely geometric" begin
        api_keys, geo_hints, other = _classify_patch(Dict(
            "column_spacing" => 25,
            "bay_width" => 30,
            "story_height" => 12,
        ))
        @test isempty(api_keys)
        @test length(geo_hints) == 3
        @test isempty(other)
    end

    @testset "Patch classification — mixed API + geometric" begin
        api_keys, geo_hints, other = _classify_patch(Dict(
            "floor_type" => "flat_plate",   # API
            "column_spacing" => 25,          # geometric
        ))
        @test "floor_type" in api_keys
        @test "column_spacing" in geo_hints
    end

    @testset "Patch classification — unknown non-geometric key" begin
        _, geo, other = _classify_patch(Dict("totally_fake_param" => 42))
        @test isempty(geo)
        @test "totally_fake_param" in other
    end

    # ─── Applicability schema structure ─────────────────────────────────────
    @testset "api_applicability_schema structure" begin
        schema = api_applicability_schema()

        @test haskey(schema, "rules")
        rules = schema["rules"]

        # floor_type entry with compatibility checks
        @test haskey(rules, "floor_type")
        ft = rules["floor_type"]
        @test haskey(ft, "compatibility_checks")
        compat = ft["compatibility_checks"]
        @test haskey(compat, "rules")
        @test compat["rules"] isa Vector
        @test !isempty(compat["rules"])

        # analysis_method entry with per-method applicability checks
        @test haskey(rules, "analysis_method")
        methods = rules["analysis_method"]
        @test haskey(methods, "applicability_checks")
        app = methods["applicability_checks"]
        @test haskey(app, "DDM")
        @test haskey(app, "EFM")
        @test haskey(app, "FEA")

        ddm = app["DDM"]
        @test haskey(ddm, "code_basis")
        @test haskey(ddm, "hard_checks")
        @test ddm["hard_checks"] isa Vector
        @test !isempty(ddm["hard_checks"])
    end

    # ─── Structured params schema has guidance and compatibility ───────────
    @testset "api_params_schema_structured — floor_type has guidance & compat" begin
        schema = api_params_schema_structured()
        @test haskey(schema, "floor_type")
        ft = schema["floor_type"]
        @test haskey(ft, "guidance")
        @test !isempty(ft["guidance"])
        @test haskey(ft, "compatibility_checks")
    end

    @testset "api_params_schema_structured — method has applicability_checks" begin
        schema = api_params_schema_structured()
        @test haskey(schema, "floor_options")
        @test haskey(schema["floor_options"], "fields")
        @test haskey(schema["floor_options"]["fields"], "method")
        method_field = schema["floor_options"]["fields"]["method"]
        @test haskey(method_field, "applicability_checks")
        app = method_field["applicability_checks"]
        @test haskey(app, "DDM")
        @test haskey(app, "EFM")
        @test haskey(app, "FEA")
    end

    # ─── Turn summary contract ───────────────────────────────────────────────

    @testset "Turn summary — always has required keys" begin
        s = _build_turn_summary()
        @test s["type"] == "agent_turn_summary"
        @test s["suggested_next_questions"] == String[]
        @test isnothing(s["clarification_prompt"])
        @test !haskey(s, "tool_actions")
    end

    @testset "Turn summary — with suggestions and clarification" begin
        s = _build_turn_summary(;
            suggestions = ["Try X", "Try Y"],
            clarification_data = Dict(
                "id" => "prio",
                "prompt" => "Which priority?",
                "options" => [Dict("id" => "a", "label" => "A"), Dict("id" => "b", "label" => "B")],
            ),
        )
        @test length(s["suggested_next_questions"]) == 2
        clar = s["clarification_prompt"]
        @test !isnothing(clar)
        @test clar["id"] == "prio"
        @test clar["allow_multiple"] == false
    end

    @testset "Turn summary — with tool actions" begin
        actions = [Dict{String,Any}("tool" => "validate_params", "status" => "ok", "elapsed_ms" => 12)]
        s = _build_turn_summary(; tool_actions=actions)
        @test haskey(s, "tool_actions")
        @test length(s["tool_actions"]) == 1
    end

    # ─── Normalizer ──────────────────────────────────────────────────────────

    @testset "Normalize clarification — fills defaults" begin
        raw = Dict("prompt" => "Q?", "options" => [Dict("id" => "a", "label" => "A")])
        n = _normalize_clarification(raw)
        @test n["id"] == "clarify"
        @test n["allow_multiple"] == false
    end

    @testset "Normalize clarification — rejects missing prompt" begin
        @test isnothing(_normalize_clarification(Dict("options" => [])))
    end

    @testset "Normalize clarification — rejects nothing" begin
        @test isnothing(_normalize_clarification(nothing))
    end

    # ─── Dedup: duplicate clarification dispatch ─────────────────────────────

    @testset "Clarify dedup — second dispatch returns duplicate:true" begin
        sess = "dedup_test_$(rand(1000:9999))"
        args = Dict{String,Any}(
            "id"         => "same_id",
            "prompt"     => "Which priority?",
            "options"    => Any[Dict("id" => "a", "label" => "A"), Dict("id" => "b", "label" => "B")],
            "session_id" => sess,
        )
        r1 = _dispatch_chat_tool("clarify_user_intent", args)
        @test r1["ok"] == true
        @test r1["duplicate"] == false

        r2 = _dispatch_chat_tool("clarify_user_intent", args)
        @test r2["ok"] == true
        @test r2["duplicate"] == true

        # Clean up
        _clear_history!(sess)
    end

    # ─── Tool schema ─────────────────────────────────────────────────────────

    @testset "api_tool_schema — has clarify_user_intent" begin
        registry = api_tool_schema()
        @test registry isa Vector
        @test !isempty(registry)
        names = [t["name"] for t in registry]
        @test "clarify_user_intent" in names
        @test "validate_params" in names
        @test "run_design" in names
        @test "get_building_summary" in names
    end

    # ─── get_response_guidelines dispatch ─────────────────────────────────

    @testset "Tool dispatch — get_response_guidelines" begin
        result = _dispatch_chat_tool("get_response_guidelines", Dict{String,Any}())
        @test !haskey(result, "error")
        @test haskey(result, "tool_selection_recipes")
        @test haskey(result, "required_sequences")
        @test haskey(result, "scope_limits")
        @test haskey(result, "epistemic_boundary")
        @test haskey(result, "anti_patterns")
        @test haskey(result, "geometry_recovery_rule")
        @test haskey(result, "geometry_remediation")
        @test haskey(result, "geometry_what_if")
        @test haskey(result, "geometry_hash_stale_cache")
        @test haskey(result, "client_geometry_vs_server")
        @test haskey(result, "irregularity_rules")
        @test haskey(result, "key_parameters")
        @test result["scope_limits"] isa Vector
        @test !isempty(result["scope_limits"])
        @test result["tool_selection_recipes"] isa Vector
        @test result["key_parameters"] isa Vector
    end

    @testset "api_tool_schema — has get_response_guidelines" begin
        registry = api_tool_schema()
        names = [t["name"] for t in registry]
        @test "get_response_guidelines" in names
    end

    @testset "agent_response_guidelines — direct call" begin
        g = agent_response_guidelines()
        @test g isa Dict{String, Any}
        @test haskey(g, "tool_selection_recipes")
        @test g["tool_selection_recipes"] isa Vector
        @test !isempty(g["tool_selection_recipes"])
        @test haskey(g["tool_selection_recipes"][1], "intent")
        @test haskey(g["tool_selection_recipes"][1], "sequence")
        @test haskey(g, "required_sequences")
        @test g["key_parameters"] isa Vector
    end

    # ─── System prompt token budget ──────────────────────────────────────

    @testset "System prompt — design mode stays under token budget" begin
        prompt = _build_system_prompt("design", nothing, "")
        tokens = _estimate_tokens(prompt)
        budget = round(Int, MAX_CONTEXT_TOKENS * _SYSTEM_PROMPT_BUDGET_FRACTION)
        @test tokens <= budget
        @test occursin("structural engineering design assistant", prompt)
        @test occursin("EVIDENCE-FIRST", prompt)
    end

    @testset "System prompt — results mode stays under token budget" begin
        prompt = _build_system_prompt("results", nothing, "")
        tokens = _estimate_tokens(prompt)
        budget = round(Int, MAX_CONTEXT_TOKENS * _SYSTEM_PROMPT_BUDGET_FRACTION)
        @test tokens <= budget
        @test occursin("structural engineering results analyst", prompt)
        @test occursin("EVIDENCE-FIRST", prompt)
    end

    @testset "System prompt — design mode with geometry gets opening analysis" begin
        prompt = _build_system_prompt("design", nothing, "", "", Dict{String, Any}("vertices" => []))
        @test occursin("OPENING ANALYSIS", prompt)
        @test occursin("GEOMETRY READ", prompt)
    end

    @testset "System prompt — unknown mode returns fallback" begin
        prompt = _build_system_prompt("unknown", nothing, "")
        @test prompt == "You are a helpful structural engineering assistant."
    end

end # @testset "Chat API"
