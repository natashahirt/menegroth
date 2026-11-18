"""
    agent_suggest_next_action(design::BuildingDesign, goal::String) -> Dict{String, Any}

Return ranked parameter suggestions for the given goal by pulling from
the /diagnose architectural and constraint layers.
"""
function agent_suggest_next_action(design::BuildingDesign, goal::String)::Dict{String, Any}
    valid_goals = ["fix_failures", "reduce_column_size", "reduce_slab_thickness", "reduce_ec"]
    goal in valid_goals || return Dict(
        "error"   => "invalid_goal",
        "message" => "Goal must be one of: $(join(valid_goals, ", ")). Got: \"$goal\".",
    )

    diag = get_cached_diagnose(DESIGN_CACHE, design)
    arch = get(diag, "architectural", Dict())
    cons = get(diag, "constraints", Dict())

    recs = get(arch, "goal_recommendations", [])
    impacts = get(cons, "lever_impacts", [])

    goal_recs = filter(r -> get(r, "goal", "") == goal, recs)

    goal_params = Dict(
        "fix_failures"          => ["punching_strategy", "deflection_limit", "column_catalog", "beam_catalog"],
        "reduce_column_size"    => ["punching_strategy", "column_catalog"],
        "reduce_slab_thickness" => ["deflection_limit"],
        "reduce_ec"             => ["punching_strategy", "deflection_limit", "uniform_column_sizing"],
    )

    # deflection_limit is a secondary lever — geometric changes (shorter spans,
    # added columns) are far more effective for reducing slab thickness / EC.
    _secondary_params = Set(["deflection_limit"])
    related_params = get(goal_params, goal, String[])
    goal_impacts = filter(i -> get(i, "parameter", "") in related_params, impacts)

    summary = get(diag, "agent_summary", Dict())

    # ── Runtime failure analysis ──
    failing_checks = _extract_failing_checks(diag)
    ranked_actions = _rank_actions_by_failure(goal, failing_checks, related_params)

    # Tag secondary levers so the LLM presents them as optional, not primary
    for action in ranked_actions
        if get(action, "parameter", "") in _secondary_params
            action["priority"] = "secondary"
            action["priority_note"] = "Geometric changes (reducing spans, adding columns) are " *
                "far more effective. Relaxing deflection limit is a secondary option if the " *
                "project can tolerate additional deflection."
        end
    end

    # ── Geometry remediation evaluation (non-fatal on error) ──
    geo_remediations = try
        _geometry_remediation_eval(design, diag, failing_checks)
    catch e
        @warn "Geometry remediation eval failed — skipping" exception=(e, catch_backtrace())
        Dict{String, Any}[]
    end

    # ── Parameter headroom from size warnings ──
    size_warnings = get(diag, "size_warnings", Any[])
    any_exhausted = any(w -> get(w, "parameter_headroom", "") == "none", size_warnings)
    param_headroom = any_exhausted ? "exhausted" : "available"

    # ── System dependency context ──
    floor_type = _extract_floor_type(design)
    sys_context = isnothing(floor_type) ? nothing : get_system_dependencies(floor_type)

    # ── Build tl;dr summary for fast LLM parsing ──
    total_failing_n = sum(get(fc, "n_failing", 0) for fc in failing_checks; init=0)
    check_parts = [
        "$(get(fc, "check", "?")): $(get(fc, "n_failing", 0)) elements"
        for fc in failing_checks[1:min(end, 3)]
    ]
    top_action = isempty(ranked_actions) ? "none" :
        "$(get(ranked_actions[1], "parameter", "?")) (addresses $(round(Int, get(ranked_actions[1], "coverage_fraction", 0.0) * 100))% of failures)"

    tldr = if total_failing_n == 0
        "All checks pass. Goal: $goal."
    elseif !isempty(geo_remediations)
        geo_gap = get(geo_remediations[1], "gap", "")
        "Geometry is the bottleneck: $geo_gap Parameter changes alone cannot resolve this. " *
        "$(length(failing_checks)) check families failing ($(join(check_parts, ", ")))."
    else
        "$(length(failing_checks)) check families failing ($(join(check_parts, ", "))). Top action: $top_action."
    end

    result = Dict{String, Any}(
        "goal"               => goal,
        "tldr"               => tldr,
        "ranked_actions"     => ranked_actions,
        "failing_checks"     => failing_checks,
        "parameter_headroom" => param_headroom,
        "current_status"     => Dict(
            "all_pass"       => get(summary, "all_pass", false),
            "critical_ratio" => get(summary, "critical_ratio", 0.0),
            "n_failing"      => total_failing_n,
        ),
    )

    if !isempty(geo_remediations)
        result["geometry_actions"] = geo_remediations
    end

    if !isnothing(sys_context)
        result["system_context"] = sys_context
    end

    if !isempty(goal_recs) || !isempty(goal_impacts)
        result["raw_data"] = Dict{String, Any}(
            "recommendations" => goal_recs,
            "lever_impacts"   => goal_impacts,
        )
    end

    # Inline guidance — geometry bottleneck vs parameter path
    _geometry_first_goals = Set(["reduce_slab_thickness", "reduce_ec"])
    result["_guidance"] = if !isempty(geo_remediations)
        "GEOMETRY IS THE BOTTLENECK: Present geometry_actions FIRST with quantitative targets " *
        "and Grasshopper instructions. Parameter changes are secondary. " *
        "Use predict_geometry_effect to explain the structural reasoning."
    elseif goal in _geometry_first_goals
        "PRIORITIZE GEOMETRY: For $goal, reducing span lengths (adding columns, " *
        "subdividing bays) in Grasshopper is the primary lever — deflection scales with L⁴. " *
        "Relaxing deflection_limit (L/360→L/240) is a secondary, optional measure only if " *
        "the project can tolerate more deflection and has no sensitive partitions/equipment. " *
        "If uniform_column_sizing is per_story or building, switching to off (independent " *
        "sizing) eliminates excess material in lightly-loaded columns — a quick parameter win. " *
        "Present geometry changes first, then mention deflection_limit relaxation and " *
        "uniform_column_sizing=off as additional options the user may consider."
    else
        "NEXT STEP: Call validate_params before run_design to test recommended parameter changes."
    end

    return result
end

"""
Extract a frequency-sorted list of failing check families from diagnose data.

The diagnose dict stores elements under `engineering.columns`, `engineering.beams`,
`engineering.slabs`, `engineering.foundations`. Each element has top-level `ok`,
`governing_check`, and `governing_ratio` fields.
"""
function _extract_failing_checks(diag::Dict)::Vector{Dict{String, Any}}
    check_counts = Dict{String, Int}()
    check_worst = Dict{String, Float64}()

    for plural in ("columns", "beams", "slabs", "foundations")
        elems = get(diag, plural, Any[])
        !(elems isa AbstractVector) && continue
        for elem in elems
            !(elem isa AbstractDict) && continue
            ok = get(elem, "ok", true)
            ok && continue
            gc = string(get(elem, "governing_check", "unknown"))
            ratio_raw = get(elem, "governing_ratio", 0.0)
            ratio = ratio_raw isa Number ? Float64(ratio_raw) : 0.0
            check_counts[gc] = get(check_counts, gc, 0) + 1
            check_worst[gc] = max(get(check_worst, gc, 0.0), ratio)
        end
    end

    sorted = sort(collect(check_counts); by=last, rev=true)
    return [Dict{String, Any}(
        "check"       => name,
        "n_failing"   => count,
        "worst_ratio" => get(check_worst, name, 0.0),
    ) for (name, count) in sorted]
end

"""
Rank actionable parameters by how many distinct failing check families they address,
using LEVER_SURFACE_MAP to connect parameters to checks and PROVISION_ONTOLOGY for
cross-references.
"""
function _rank_actions_by_failure(
    goal::String,
    failing_checks::Vector{Dict{String, Any}},
    related_params::Vector{String},
)::Vector{Dict{String, Any}}
    total_failing = sum(get(fc, "n_failing", 0) for fc in failing_checks; init=0)

    failing_by_norm = Dict{String, Dict{String, Any}}()
    for fc in failing_checks
        cn = get(fc, "check", "")
        failing_by_norm[_lever_norm(cn)] = fc
    end

    param_scores = Dict{String, Dict{String, Any}}()
    for param in related_params
        addressed = String[]
        addressed_count = 0
        provisions_involved = Dict{String, Any}[]
        for (check_name, lever_info) in LEVER_SURFACE_MAP
            params_list = get(lever_info, "parameters", String[])
            fc = get(failing_by_norm, _lever_norm(check_name), nothing)
            if param in params_list && !isnothing(fc)
                push!(addressed, check_name)
                addressed_count += get(fc, "n_failing", 0)
                for prov in get_provisions_for_check(check_name)
                    push!(provisions_involved, Dict{String, Any}(
                        "section"              => get(prov, "section", ""),
                        "provision"            => get(prov, "provision", ""),
                        "failure_consequence"  => get(prov, "failure_consequence", ""),
                    ))
                end
            end
        end
        direction = _lever_direction(param)
        rationale = get_code_rationale(param)
        entry = Dict{String, Any}(
            "parameter"         => param,
            "addresses_checks"  => addressed,
            "addresses_n"       => addressed_count,
            "coverage_fraction" => total_failing > 0 ? addressed_count / total_failing : 0.0,
            "direction"         => direction,
            "provisions"        => unique(provisions_involved),
        )
        if !isnothing(rationale)
            entry["rationale"] = rationale
        end
        param_scores[param] = entry
    end

    sorted = sort(collect(values(param_scores)); by=d -> -get(d, "addresses_n", 0))
    return sorted
end

function _lever_direction(param::String)::String
    for (_, lever_info) in LEVER_SURFACE_MAP
        params_list = get(lever_info, "parameters", String[])
        if param in params_list
            return get(lever_info, "direction", "")
        end
    end
    return ""
end

"""
Extract floor_type string from a BuildingDesign for system dependency lookup.
"""
function _extract_floor_type(design::BuildingDesign)::Union{String, Nothing}
    try
        params = design.params
        if hasproperty(params, :floor_type)
            ft = params.floor_type
            return ft isa Symbol ? string(ft) : string(ft)
        end
    catch
    end
    return nothing
end

# ─── Meta-tool: full behavioral rules on demand ─────────────────────────────

"""
    agent_response_guidelines() -> Dict{String, Any}

Return the full set of behavioral rules, scope limits, anti-patterns, and
tool selection recipes. The system prompt is intentionally lean; the LLM
calls this tool when it needs detailed guidance.
"""
function agent_response_guidelines()::Dict{String, Any}
    Dict{String, Any}(
        # ── Tool Selection Recipes ─────────────────────────────────────────
        # Match user intent to tool sequence. Each key describes the user's
        # question; the value is the recommended tool chain.
        "tool_selection_recipes" => [
            Dict("intent" => "Start of conversation",
                 "sequence" => "get_situation_card → read digest → recommend initial parameters"),
            Dict("intent" => "Why is X failing?",
                 "sequence" => "get_diagnose_summary → get_provision_rationale → narrate_element"),
            Dict("intent" => "What should I change?",
                 "sequence" => "get_diagnose_summary → suggest_next_action → validate_params"),
            Dict("intent" => "Would a bigger column help? / punching shear concern",
                 "sequence" => "run_experiment(type=punching, args={col_idx from diagnose, c1_in=larger}) — INSTANT, no full re-run"),
            Dict("intent" => "What if I use a different column section?",
                 "sequence" => "run_experiment(type=pm_column, args={col_idx, section_size}) or batch_experiments to screen multiple sizes"),
            Dict("intent" => "What if I use a different beam section?",
                 "sequence" => "run_experiment(type=beam, args={beam_idx, section_size=\"W16X40\"}) — tests flexure, shear, LTB via full AISC checker"),
            Dict("intent" => "Can I add shear studs or stirrups for punching?",
                 "sequence" => "run_experiment(type=punching_reinforcement, args={col_idx, reinforcement_type=\"studs\"}) — designs full stud/stirrup layout and checks if column passes"),
            Dict("intent" => "Would reinforce_first / grow_columns / reinforce_last help?",
                 "sequence" => "get_lever_map(check=punching…) then run_experiment: punching (larger c1/c2), punching_reinforcement (studs), punching_column_downsize (min plan at fixed Vu/Mub). Global strategy change → validate_params→run_design."),
            Dict("intent" => "What about a different deflection limit?",
                 "sequence" => "run_experiment(type=deflection, args={slab_idx, deflection_limit}) — " *
                               "BUT NOTE: deflection_limit relaxation (L/360→L/240) is a SECONDARY lever. " *
                               "Always recommend geometric changes first (shorter spans, added columns). " *
                               "Only suggest deflection relaxation as an additional option if the project " *
                               "can tolerate more deflection (no sensitive partitions/equipment)."),
            Dict("intent" => "Which column sizes would work?",
                 "sequence" => "run_experiment(type=catalog_screen, args={col_idx, candidates=[...]}) or batch_experiments with multiple pm_column checks"),
            Dict("intent" => "Would stronger concrete / different material help?",
                 "sequence" => "run_experiment(type=punching, args={col_idx, fc_in=5000}) — BUT NOTE: the punching micro-experiment holds column size constant. In a full redesign higher f'c lets the column sizer pick SMALLER columns, which may NET-WORSEN punching (smaller b₀). Always caveat this coupling when interpreting results."),
            Dict("intent" => "How can I reduce embodied carbon / lower-carbon building?",
                 "sequence" => "suggest_next_action(goal=reduce_ec) → prioritize geometric changes (shorter spans, " *
                               "added columns) as the PRIMARY lever for reducing slab concrete volume. " *
                               "Deflection limit relaxation is SECONDARY. " *
                               "If uniform_column_sizing is per_story/building, switching to off removes excess " *
                               "column material (quick parameter win). " *
                               "run_experiment on critical elements to quantify savings → validate_params → run_design"),
            Dict("intent" => "Try changing X (global parameter change)",
                 "sequence" => "run_experiment first for instant preview → validate_params → run_design → compare_designs (no args: previous vs latest)"),
            Dict("intent" => "Explain this element/result",
                 "sequence" => "narrate_element or narrate_comparison"),
            Dict("intent" => "Compare runs",
                 "sequence" => "compare_designs (previous vs latest); get_design_history only to list past runs"),
            Dict("intent" => "What does parameter X do?",
                 "sequence" => "explain_field(X)"),
            Dict("intent" => "Missing geometry data",
                 "sequence" => "get_geometry_digest — never claim data is unavailable without calling this first"),
            Dict("intent" => "Carbon / sustainability (pre-design)",
                 "sequence" => "get_situation_card → quote digest → recommend shorter spans, optimize_for=carbon, predict_geometry_effect — ONLY systems from PARAMETER SPACE card"),
            Dict("intent" => "What is the EC / embodied carbon / carbon intensity?",
                 "sequence" => "get_diagnose_summary — returns total_ec_kgco2e and per-element ec_kgco2e. " *
                               "For EC intensity (per ft² or per m²), divide total_ec by floor area from get_geometry_digest. " *
                               "NEVER fabricate numbers — always call the tool first."),
            Dict("intent" => "What is the critical ratio / does the design pass / what's failing?",
                 "sequence" => "get_diagnose_summary — returns all_pass, critical_ratio, critical_element, governing_check_distribution, per-type stats"),
            Dict("intent" => "What are the slab thicknesses / column sizes / beam sections?",
                 "sequence" => "query_elements(type=slabs/columns/beams) or get_diagnose for full per-element data. NEVER guess dimensions."),
            Dict("intent" => "What are the current spans / heights / geometry?",
                 "sequence" => "get_geometry_digest — returns spans, story heights, column count, plan area. NEVER recall from memory."),
        ],

        "required_sequences" => [
            "get_situation_card before run_design (confirm has_geometry)",
            "validate_params before run_design",
            "record_insight after each design run",
            "get_session_insights before recommending",
        ],

        # ── Parameter Space (generated from schema — single source of truth) ──
        "parameter_space" => _parameter_space_card(),

        # ── Epistemic Boundary ────────────────────────────────────────────
        "epistemic_boundary" =>
            "All code logic is in the solver. Quote code_clause / limit_state_description from tool results. " *
            "Never invent section numbers or formulas. Use get_implemented_provisions to check coverage.",

        # ── Anti-patterns (FORBIDDEN) ─────────────────────────────────────
        "anti_patterns" => [
            "Filler openings ('I'd be happy to help…')",
            "Listing all floor types without recommending one for THIS geometry",
            "Asking what the digest already answers (spans, stories, column count)",
            "Generic descriptions that could apply to any building",
            "Claiming geometry is missing without calling get_geometry_digest first",
            "Hedging ('some spans exceeding…') — quote the EXACT min–max from the digest",
            "Calling run_design when has_geometry is false",
            "Calling suggest_next_action / run_experiment / diagnose when has_design is false",
            "Confusing 'no server cache' with 'no digest' — the digest can exist without a design run",
            "Recommending systems outside the PARAMETER SPACE card (PT, composite deck, voided/bubble/waffle slab, timber, CLT, modular, passive cooling, etc.)",
            "Inventing structural trade-offs not grounded in tool data. WRONG: 'reducing spans may increase punching shear due to higher tributary areas'. " *
                "CORRECT: reducing spans REDUCES tributary area (∝ L²), which REDUCES punching demand. " *
                "Always use predict_geometry_effect or get_lever_map to verify directional effects before stating them.",
            "Claiming higher f'c always improves punching (system coupling: column sizer may pick smaller columns, shrinking b₀). " *
                "Always caveat with the coupling effect and recommend a micro-experiment.",
            "Treating reinforce_first and grow_columns as equivalent for punching (grow_columns increases b₀ directly; " *
                "reinforce_first adds studs but columns stay at P-M minimum — may be smaller).",
            "Answering retrieval questions (EC, ratio, thickness, area, section size) from memory or by fabricating numbers. " *
                "ALWAYS call the relevant tool (get_diagnose_summary, query_elements, get_geometry_digest, get_current_params) " *
                "before quoting ANY number. If you haven't called a tool, you don't have the data.",
            "Suggesting changes to SOLVER OUTPUTS as user actions. WRONG: 'increase slab thickness to 13 in', " *
                "'use a larger column section', 'change beam to W21×50'. Slab thickness, column size, beam section, " *
                "and rebar layout are determined by the optimization — the user cannot set them directly. " *
                "Instead recommend changes to DESIGN PARAMETERS (floor_type, optimize_for, material grades, " *
                "punching_strategy, fire_rating, column_catalog, etc.) or GEOMETRY (column positions, spans in Grasshopper) " *
                "that will cause the solver to produce adequate sections.",
            "Interpreting 0.0 deflection/punching ratios on non-converged slabs as real results. " *
                "A non-converged slab never completed its design checks — its ratios are default placeholders. " *
                "Always flag non-convergence explicitly and explain the failure_reason, not the 0.0 ratio.",
            "Using the CLARIFY block for suggested follow-ups. " *
                "WRONG: emitting a CLARIFY block with options like 'Ask about results', 'Let me know what to focus on'. " *
                "Those are SUGGESTIONS, not clarifications. The CLARIFY block is ONLY for genuine blocking ambiguity " *
                "where you cannot proceed without the user's choice. Suggested next actions go in the SUGGESTIONS block.",
            "Comparing the latest run against run 1 instead of the immediately previous run. " *
                "After run N, compare_designs should use index_a=N-1, index_b=N (previous vs latest). " *
                "WRONG: comparing run 3 against run 1 and attributing all improvement to the last parameter change. " *
                "If run 2 had a geometry change and run 3 had a parameter change, comparing 3 vs 1 conflates both. " *
                "Always compare adjacent runs unless the user explicitly asks for a different comparison.",
        ],

        # ── Geometry Rules ────────────────────────────────────────────────
        "geometry_rules" => Dict{String, Any}(
            "recovery" =>
                "If geometry seems missing → call get_geometry_digest. Only report 'unavailable' if that tool errors.",
            "remediation" =>
                "When parameter_headroom='exhausted' → present geometry changes FIRST (Grasshopper), then parameter tweaks. Use predict_geometry_effect for reasoning. Surface critical size_warnings.",
            "geometry_first_for_slabs" =>
                "For reduce_slab_thickness / reduce_ec goals, ALWAYS recommend geometric changes " *
                "(shorter spans, added columns) as the PRIMARY lever. Deflection ∝ L⁴ makes span " *
                "reduction far more effective than deflection limit relaxation. Relaxing " *
                "deflection_limit (L/360→L/240) is a SECONDARY, optional suggestion — only if the " *
                "project can tolerate more deflection and has no sensitive partitions or equipment.",
            "what_if" =>
                "For span/column/height questions → call predict_geometry_effect. Present trade-offs quantitatively.",
            "stale_cache" =>
                "Check geometry_context.alignment: " *
                "'server_behind_client' → cached results are for the OLD model, do not report as current. " *
                "'client_behind_server' → server has NEWER results, report them to the user. " *
                "'aligned' → hashes match, results are current. " *
                "'unknown' → cannot determine, explain directional effects only — no invented numbers.",
            "client_vs_server" =>
                "has_geometry = server cache from POST /design. A prompt digest can exist without has_geometry. Quote the digest for layout advice; solver data requires a Design run.",
        ),

        # ── Irregularity Interpretation ───────────────────────────────────
        "irregularity_rules" => Dict{String, Any}(
            "span_cv" =>
                "span_stats.cv aggregates X+Y beam lengths. Different bay sizes in each direction produce high CV on a regular grid — not irregular.",
            "true_irregularity" =>
                "Infer from plan_shape_classification, quad corner deviation, tributary area CV, and grid_regularity — NOT span CV alone.",
            "vertical" =>
                "Varying story heights are flagged separately from plan regularity.",
            "column_layouts" =>
                "Non-rectangular layouts: closest-spacing values > gridline spacings.",
        ),
    )
end
