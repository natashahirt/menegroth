using StructuralSynthesizer
using StructuralSizer
using Asap
using Test
using Unitful
using Dates

# =============================================================================
# Chat Tool Dispatch Tests
#
# Three test layers:
#   1. Unit — _dispatch_chat_tool with no design loaded (error paths, schema tools)
#   2. Integration — full design_building → tool dispatch → verify payloads
#   3. LLM Smoke — live OpenAI API call to verify evidence-first protocol
#
# Layer 3 requires CHAT_LLM_API_KEY env var or secrets/openai_api_key file.
# If absent, those tests are skipped with @test_skip.
# =============================================================================

const SS = StructuralSynthesizer

# ─── Helpers ──────────────────────────────────────────────────────────────────

"""
    _build_test_design()

Build a small 2×2-bay, 1-story flat-plate structure and run `design_building`.
Returns `(struc, design)`.
"""
function _build_test_design()
    skel = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)

    params = DesignParameters(
        name = "chat_tool_test",
        materials = MaterialOptions(concrete = NWC_4000),
        floor = FlatPlateOptions(method = DDM()),
        max_iterations = 2,
    )

    design = design_building(struc, params)
    return struc, design
end

"""Load a design into the module-level DESIGN_CACHE so tool dispatch can find it."""
function _load_into_cache!(struc, design)
    DESIGN_CACHE.structure = struc
    DESIGN_CACHE.last_design = design
    DESIGN_CACHE.geometry_hash = "test_chat_tools"
end

"""Reset DESIGN_CACHE and session state to a clean slate."""
function _clear_cache!()
    DESIGN_CACHE.structure = nothing
    DESIGN_CACHE.last_design = nothing
    DESIGN_CACHE.geometry_hash = ""
    empty!(SS.DESIGN_HISTORY)
    SS.clear_session_insights!()
end

# Shorthand for the internal dispatch function
dispatch = SS._dispatch_chat_tool

# =============================================================================
# Layer 1: Unit Tests — No design loaded
# =============================================================================

@testset "Chat Tool Dispatch — Unit (no design)" begin

    _clear_cache!()

    @testset "unknown tool → error with available list" begin
        r = dispatch("totally_fake_tool", Dict{String, Any}())
        @test r["error"] == "unknown_tool"
        @test occursin("Available", r["message"])
    end

    @testset "list_experiments — no design needed" begin
        r = dispatch("list_experiments", Dict{String, Any}())
        @test haskey(r, "experiments")
        @test length(r["experiments"]) >= 4
    end

    @testset "get_session_insights — empty session" begin
        r = dispatch("get_session_insights", Dict{String, Any}())
        @test r["n_insights"] == 0
    end

    @testset "record_insight + retrieval round-trip" begin
        r = dispatch("record_insight", Dict{String, Any}(
            "category"       => "observation",
            "summary"        => "Test insight from chat tool test",
            "detail"         => "Just checking the round-trip.",
            "confidence"     => 0.85,
            "related_checks" => ["punching_shear"],
            "related_params" => ["slab_thickness"],
        ))
        @test r["ok"] == true

        r2 = dispatch("get_session_insights", Dict{String, Any}())
        @test r2["n_insights"] >= 1
        summaries = [ins["summary"] for ins in r2["insights"]]
        @test "Test insight from chat tool test" in summaries

        # Filter by category
        r3 = dispatch("get_session_insights", Dict{String, Any}("category" => "observation"))
        @test r3["n_insights"] >= 1

        # Filter by wrong category → 0
        r4 = dispatch("get_session_insights", Dict{String, Any}("category" => "dead_end"))
        @test r4["n_insights"] == 0

        SS.clear_session_insights!()
    end

    @testset "clarify_user_intent bool coercion" begin
        r = dispatch("clarify_user_intent", Dict{String, Any}(
            "id" => "decision",
            "prompt" => "Pick one",
            "allow_multiple" => "true",
            "options" => [
                Dict("id" => "a", "label" => "A"),
                Dict("id" => "b", "label" => "B"),
            ],
        ))
        @test r["ok"] == true
        @test r["clarification"]["allow_multiple"] == true
    end

    @testset "record_insight numeric coercion + validation" begin
        r = dispatch("record_insight", Dict{String, Any}(
            "category" => "observation",
            "summary" => "String numeric coercion",
            "design_index" => "0",
            "confidence" => "0.7",
        ))
        @test r["ok"] == true

        r_bad = dispatch("record_insight", Dict{String, Any}(
            "category" => "observation",
            "summary" => "Bad confidence",
            "confidence" => "nope",
        ))
        @test r_bad["error"] == "invalid_confidence"
    end

    @testset "record_insight — missing summary → error" begin
        r = dispatch("record_insight", Dict{String, Any}("category" => "dead_end"))
        @test r["error"] == "missing_summary"
    end

    @testset "design-dependent tools → no_design" begin
        for tool in ["get_result_summary", "get_condensed_result",
                      "get_diagnose_summary", "get_diagnose",
                      "get_current_params", "get_solver_trace"]
            r = dispatch(tool, Dict{String, Any}())
            @test r["error"] == "no_design"
        end
    end

    @testset "get_situation_card — partial (no geometry)" begin
        r = dispatch("get_situation_card", Dict{String, Any}())
        @test r["has_geometry"] == false
        @test r["has_design"] == false
    end

    @testset "get_lever_map — full and filtered" begin
        r = dispatch("get_lever_map", Dict{String, Any}())
        @test haskey(r, "punching_shear")
        @test haskey(r, "flexure")

        r2 = dispatch("get_lever_map", Dict{String, Any}("check" => "punching_shear"))
        @test haskey(r2, "punching_shear")
        @test !haskey(r2, "flexure")
    end

    @testset "explain_field" begin
        r = dispatch("explain_field", Dict{String, Any}("field" => "floor_type"))
        @test !haskey(r, "error") || r["error"] != "unknown_tool"
    end

    @testset "validate_params — compatible combo" begin
        r = dispatch("validate_params", Dict{String, Any}(
            "params" => Dict{String, Any}("floor_type" => "flat_plate"),
        ))
        @test r["ok"] == true
        @test isempty(r["violations"])
    end

    @testset "get_applicability schema" begin
        r = dispatch("get_applicability", Dict{String, Any}())
        @test haskey(r, "rules") || haskey(r, "floor_types")
    end
end

# =============================================================================
# Layer 2: Integration Tests — With a real design
# =============================================================================

@testset "Chat Tool Dispatch — Integration (with design)" begin

    struc, design = _build_test_design()
    _load_into_cache!(struc, design)

    @testset "get_situation_card — populated" begin
        r = dispatch("get_situation_card", Dict{String, Any}())
        @test r["has_geometry"] == true
        @test r["has_design"] == true
        @test haskey(r, "health")
        @test haskey(r["health"], "all_pass")
        @test haskey(r["health"], "critical_ratio")
        @test haskey(r["health"], "n_failing")
        @test haskey(r, "session")
    end

    @testset "get_building_summary" begin
        r = dispatch("get_building_summary", Dict{String, Any}())
        @test haskey(r, "n_stories")
        @test haskey(r, "n_columns")
        @test r["n_stories"] >= 1
        @test r["n_columns"] >= 1
        # structural_flags only present when non-empty
        if haskey(r, "structural_flags")
            @test r["structural_flags"] isa AbstractVector
        end
    end

    @testset "get_diagnose_summary — structure" begin
        r = dispatch("get_diagnose_summary", Dict{String, Any}())
        @test haskey(r, "by_type")
        @test haskey(r, "top_critical")
        @test haskey(r, "failure_breakdown")
        @test haskey(r, "n_total_elements")
        @test r["n_total_elements"] >= 0
    end

    @testset "get_result_summary" begin
        r = dispatch("get_result_summary", Dict{String, Any}())
        @test !haskey(r, "error")
    end

    @testset "query_elements — columns" begin
        r = dispatch("query_elements", Dict{String, Any}("type" => "column"))
        @test !haskey(r, "error")
        @test haskey(r, "elements") || haskey(r, "columns")
    end

    @testset "query_elements — failing only" begin
        r = dispatch("query_elements", Dict{String, Any}("ok" => false))
        @test !haskey(r, "error")
    end

    @testset "query_elements — string arg coercion" begin
        r = dispatch("query_elements", Dict{String, Any}(
            "min_ratio" => "0.0",
            "max_ratio" => "2.0",
            "ok" => "false",
        ))
        @test !haskey(r, "error")

        r_bad = dispatch("query_elements", Dict{String, Any}("min_ratio" => "bad"))
        @test r_bad["error"] == "invalid_min_ratio"
    end

    @testset "get_current_params" begin
        r = dispatch("get_current_params", Dict{String, Any}())
        @test !haskey(r, "error")
    end

    @testset "get_solver_trace — default tier" begin
        r = dispatch("get_solver_trace", Dict{String, Any}())
        # May be empty if no trace events were emitted, but should not error
        @test !haskey(r, "error") || r["error"] != "unknown_tool"
    end

    @testset "get_solver_trace — full tier" begin
        r = dispatch("get_solver_trace", Dict{String, Any}("tier" => "full"))
        @test !haskey(r, "error") || r["error"] != "unknown_tool"
    end

    @testset "explain_trace_lookup — breadcrumb microscope round-trip (best effort)" begin
        trace = dispatch("get_solver_trace", Dict{String, Any}("tier" => "decisions"))
        if haskey(trace, "events") && trace["events"] isa AbstractVector
            # Find the first breadcrumb group event that includes top_elements[] with lookup
            lookup = nothing
            for ev in trace["events"]
                !(ev isa AbstractDict) && continue
                data = get(ev, "data", nothing)
                !(data isa AbstractDict) && continue
                get(data, "breadcrumbs_kind", "") == "member_group" || continue
                tops = get(data, "top_elements", nothing)
                !(tops isa AbstractVector) && continue
                isempty(tops) && continue
                first_top = tops[1]
                (first_top isa AbstractDict) || continue
                lk = get(first_top, "lookup", nothing)
                (lk isa AbstractDict) || continue
                lookup = lk
                break
            end

            if isnothing(lookup)
                @info "No breadcrumb lookup key found in trace (trace may be empty or filtered out of tier=decisions)"
                @test true
            else
                r = dispatch("explain_trace_lookup", Dict{String, Any}("lookup" => lookup))
                # Best effort: tool may return a structured error if the lookup is malformed
                # or if the design doesn't contain the necessary artifacts.
                if haskey(r, "error")
                    @info "explain_trace_lookup returned error" error=r["error"] message=get(r, "message", "")
                    @test true
                else
                    @test haskey(r, "checks")
                    @test haskey(r, "governing_check")
                    @test haskey(r, "governing_ratio")
                end
            end
        else
            @info "No solver trace events; skipping explain_trace_lookup round-trip"
            @test true
        end
    end

    @testset "run_experiment — punching (best effort)" begin
        col_ids = collect(keys(design.columns))
        if isempty(col_ids)
            @info "No columns; skipping punching experiment"
            @test true
        else
            cid = first(col_ids)
            r = dispatch("run_experiment", Dict{String, Any}(
                "type" => "punching",
                "args" => Dict{String, Any}("col_idx" => cid, "c1_in" => 20.0, "c2_in" => 20.0),
            ))
            # Acceptable: either succeeds or returns a specific data-missing error
            @test haskey(r, "experiment") || haskey(r, "error")
            if haskey(r, "error")
                @test r["error"] in ["no_punching_data", "col_not_found", "missing_col_idx"]
            end
        end
    end

    @testset "run_experiment — deflection (best effort)" begin
        slab_ids = collect(keys(design.slabs))
        if isempty(slab_ids)
            @info "No slabs; skipping deflection experiment"
            @test true
        else
            sid = first(slab_ids)
            r = dispatch("run_experiment", Dict{String, Any}(
                "type" => "deflection",
                "args" => Dict{String, Any}("slab_idx" => sid, "deflection_limit" => "L_480"),
            ))
            @test haskey(r, "experiment") || haskey(r, "error")
        end
    end

    @testset "run_experiment — string numeric args" begin
        col_ids = collect(keys(design.columns))
        if isempty(col_ids)
            @test true
        else
            cid = string(first(col_ids))
            r = dispatch("run_experiment", Dict{String, Any}(
                "type" => "pm_column",
                "args" => Dict{String, Any}("col_idx" => cid, "section_size" => "18"),
            ))
            @test haskey(r, "experiment") || haskey(r, "error")
        end
    end

    @testset "run_experiment — missing type → error" begin
        r = dispatch("run_experiment", Dict{String, Any}("args" => Dict{String, Any}()))
        @test r["error"] == "missing_type"
    end

    @testset "batch_experiments — empty list" begin
        r = dispatch("batch_experiments", Dict{String, Any}("experiments" => Any[]))
        @test haskey(r, "results")
        @test isempty(r["results"])
    end

    @testset "batch_experiments — invalid payload shape" begin
        r = dispatch("batch_experiments", Dict{String, Any}("experiments" => "not-an-array"))
        @test r["error"] == "invalid_experiments"
    end

    @testset "suggest_next_action — requires goal" begin
        r = dispatch("suggest_next_action", Dict{String, Any}())
        @test r["error"] == "missing_goal"
    end

    @testset "suggest_next_action — fix_failures" begin
        r = dispatch("suggest_next_action", Dict{String, Any}("goal" => "fix_failures"))
        @test !haskey(r, "error") || r["error"] != "unknown_tool"
    end

    _clear_cache!()
end

# =============================================================================
# Layer 3: LLM Smoke Test — Live OpenAI API
#
# Verifies that when given our tool definitions and system prompt, the LLM
# reaches for tools (evidence-first) rather than immediately generating advice.
# =============================================================================

@testset "Chat Tool Dispatch — LLM Smoke (OpenAI API)" begin

    api_key = get(ENV, "CHAT_LLM_API_KEY", "")
    if isempty(api_key)
        # @__DIR__ = StructuralSynthesizer/test/api → repo root is 3 levels up
        repo_root = joinpath(@__DIR__, "..", "..", "..")
        key_file = joinpath(repo_root, "secrets", "openai_api_key")
        if isfile(key_file)
            raw = strip(read(key_file, String))
            api_key = SS.normalize_llm_api_key_secret(raw)
        end
    end

    if isempty(api_key)
        @warn "Skipping LLM smoke tests — no API key (set CHAT_LLM_API_KEY or secrets/openai_api_key)"
        @test_skip "LLM smoke: no API key"
    else
        using HTTP
        using JSON3

        model    = get(ENV, "CHAT_LLM_MODEL", "gpt-4o-mini")
        base_url = get(ENV, "CHAT_LLM_BASE_URL", "https://api.openai.com")
        url      = "$base_url/v1/chat/completions"
        headers  = ["Content-Type" => "application/json", "Authorization" => "Bearer $api_key"]

        tools = SS._openai_tool_specs()

        system_prompt = """You are a structural engineering design assistant with access to diagnostic tools.

CRITICAL PROTOCOL — EVIDENCE-FIRST:
1. ALWAYS call a diagnostic tool before making any recommendation.
2. Start with get_situation_card to understand the current state.
3. Use get_diagnose_summary to understand failures before suggesting fixes.
4. Use get_lever_map to find which parameters affect a given check.
5. Use run_experiment to test what-if scenarios before recommending changes.
6. NEVER guess or invent parameter values — always look them up first."""

        function _call_openai(user_msg; max_tokens=300)
            payload = Dict(
                "model"    => model,
                "messages" => [
                    Dict("role" => "system",  "content" => system_prompt),
                    Dict("role" => "user",    "content" => user_msg),
                ],
                "tools"               => tools,
                "tool_choice"         => "auto",
                "parallel_tool_calls" => false,
                "stream"              => false,
                "max_tokens"          => max_tokens,
            )
            resp = HTTP.post(url, headers, JSON3.write(payload); status_exception=false)
            @test resp.status == 200
            body = JSON3.read(String(resp.body))
            msg  = body.choices[1].message
            tc_names = String[]
            if haskey(msg, :tool_calls) && !isnothing(msg.tool_calls)
                for tc in msg.tool_calls
                    push!(tc_names, string(tc.function.name))
                end
            end
            return (message=msg, tool_names=tc_names)
        end

        @testset "orientation — LLM calls a diagnostic tool first" begin
            r = _call_openai("I have a building that needs structural design help. What's going on?")
            @info "Orientation test — LLM tool calls: $(r.tool_names)"

            orientation_tools = ["get_situation_card", "get_diagnose_summary",
                                 "get_building_summary", "get_current_params"]

            if isempty(r.tool_names)
                @test_broken false  # LLM should call tools, not respond with text
                @info "LLM responded with text instead of calling tools"
            else
                @test any(t -> t in orientation_tools, r.tool_names)
            end
        end

        @testset "failure diagnosis — LLM uses lever map or diagnose" begin
            r = _call_openai("Column 3 is failing in punching shear (ratio 1.35). What should I do?")
            @info "Failure test — LLM tool calls: $(r.tool_names)"

            diagnostic_tools = ["get_lever_map", "get_diagnose_summary", "get_diagnose",
                                "query_elements", "run_experiment", "get_situation_card",
                                "get_solver_trace"]

            if isempty(r.tool_names)
                @test_broken false
                @info "LLM responded with text instead of calling tools"
            else
                @test any(t -> t in diagnostic_tools, r.tool_names)
            end
        end

        @testset "what-if — LLM reaches for experiment or lever tools" begin
            r = _call_openai("Would increasing column size from 16×16 to 20×20 inches fix the punching shear failure on column 1?")
            @info "What-if test — LLM tool calls: $(r.tool_names)"

            experiment_tools = ["run_experiment", "get_lever_map", "get_diagnose_summary",
                                "query_elements", "get_situation_card", "batch_experiments"]

            if isempty(r.tool_names)
                @test_broken false
                @info "LLM responded with text instead of calling tools"
            else
                @test any(t -> t in experiment_tools, r.tool_names)
            end
        end

        @testset "API response structure" begin
            # Verify that our tool specs are valid OpenAI format
            @test !isempty(tools)
            for spec in tools
                @test spec["type"] == "function"
                @test haskey(spec["function"], "name")
                @test haskey(spec["function"], "description")
                @test haskey(spec["function"], "parameters")
            end
        end

        @testset "tool spec completeness — all registered tools have specs" begin
            schema = api_tool_schema()
            schema_names = Set(string(entry["name"]) for entry in schema)
            spec_names   = Set(spec["function"]["name"] for spec in tools)

            for name in schema_names
                @test name in spec_names
            end
        end
    end
end
