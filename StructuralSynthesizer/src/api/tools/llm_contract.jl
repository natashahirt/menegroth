const _LLM_CONTRACT_VERSION = "1.2.2"

"""
    _generate_params_list() -> Vector{Dict{String, Any}}

Walk `api_params_schema_structured()` and flatten it into a compact parameter
list for the LLM contract. Nested `object` types are flattened with dot notation.
"""
function _generate_params_list()::Vector{Dict{String, Any}}
    schema = api_params_schema_structured()
    out = Dict{String, Any}[]
    _flatten_schema!(out, schema, "")
    return out
end

function _flatten_schema!(out::Vector{Dict{String, Any}}, schema::Dict, prefix::String)
    for (key, spec) in sort(collect(schema); by=first)
        name = isempty(prefix) ? key : "$(prefix).$(key)"
        if !isa(spec, Dict)
            continue
        end
        ptype = get(spec, "type", "")
        if ptype == "object"
            sub = get(spec, "fields", nothing)
            !isnothing(sub) && _flatten_schema!(out, sub, name)
        else
            entry = Dict{String, Any}("name" => name, "type" => ptype)
            allowed = get(spec, "allowed", nothing)
            !isnothing(allowed) && (entry["values"] = allowed)
            rng = get(spec, "range", nothing)
            !isnothing(rng) && (entry["range"] = rng)
            unit = get(spec, "unit", nothing)
            !isnothing(unit) && (entry["unit"] = unit)
            impact = get(spec, "impact", nothing)
            !isnothing(impact) && (entry["impact"] = impact)
            push!(out, entry)
        end
    end
end

"""
    api_llm_contract() -> Dict{String, Any}

Versioned machine-readable contract describing the system's capabilities,
tools, parameters, scope limits, and experiment types. Intended for LLM
consumption at session start or for external integrations.
"""
function api_llm_contract()::Dict{String, Any}
    tools_compact = [Dict{String, Any}(
        "name" => t["name"],
        "phase" => t["phase"],
        "description" => t["description"],
        "requires_design" => get(t, "requires_design", false),
        "requires_geometry" => get(t, "requires_geometry", false),
    ) for t in TOOL_REGISTRY]

    params_list = _generate_params_list()

    scope_limits = [
        "Cannot modify geometry (spans, heights, column grid) — geometry comes from Grasshopper",
        "Cannot add or remove structural members",
        "Cannot change load paths or framing topology",
        "Cannot perform lateral/seismic analysis — gravity only",
        "Cannot design connections or details",
        "Cannot model construction staging or time-dependent effects",
        "Cannot optimize across multiple floor types simultaneously",
        "Single-material per member type (no hybrid steel-concrete columns)",
    ]

    experiment_types = [
        Dict("name" => "punching", "speed" => "instant", "args" => ["col_idx", "c1_in?", "c2_in?", "h_in?", "fc_in?"]),
        Dict("name" => "pm_column", "speed" => "instant", "args" => ["col_idx", "section_size"]),
        Dict("name" => "beam", "speed" => "instant", "args" => ["beam_idx", "section_size"]),
        Dict("name" => "punching_reinforcement", "speed" => "instant", "args" => ["col_idx", "reinforcement_type?", "stud_diameter_in?", "bar_size?", "fyt_psi?"]),
        Dict("name" => "punching_column_downsize", "speed" => "instant", "args" => ["col_idx", "reinforcement_type?", "min_column_dim_in?", "stud_diameter_in?", "bar_size?", "fyt_psi?", "check_pm?"]),
        Dict("name" => "deflection", "speed" => "instant", "args" => ["slab_idx", "deflection_limit"]),
        Dict("name" => "catalog_screen", "speed" => "instant", "args" => ["col_idx", "candidates[]"]),
    ]

    agent_levers = Dict{String, Any}(
        "geometry" => "Grasshopper/Rhino only; assistant advises (predict_geometry_effect).",
        "api_parameters" => "validate_params → run_design; use get_lever_map(check=…) to map failures to API fields.",
        "micro_experiments" => "run_experiment: cached per-element what-if. RC column → pm_column numeric in or catalog_screen Float64[]; steel column → pm_column W-string; steel beam → beam W-string only.",
        "solver_outputs" => "Read-only (thicknesses, sections, rebar); recommend geometry or API changes instead.",
    )

    member_type_experiments = Dict{String, Any}(
        "rc_rect_column" => "pm_column numeric; catalog_screen Float64[]; punching*; never W-strings.",
        "rc_circular_column" => "pm_column numeric; punching*.",
        "steel_column" => "pm_column W-string; catalog_screen String[].",
        "steel_beam" => "beam W-string only.",
    )

    params_ssot_note =
        "One server-stored API JSON; validate_params (default merge) and run_design merge patches then overwrite on success; POST /design overwrites with request body; get_api_params_ssot reads it."

    insight_categories = ["observation", "discovery", "dead_end", "sensitivity", "geometry_note"]

    return Dict{String, Any}(
        "contract_version" => _LLM_CONTRACT_VERSION,
        "system" => "menegroth structural synthesizer",
        "description" => "Automated structural engineering design: gravity sizing for RC and steel buildings",
        "tools" => tools_compact,
        "n_tools" => length(tools_compact),
        "parameters" => params_list,
        "lever_map_checks" => sort(collect(keys(LEVER_SURFACE_MAP))),
        "scope_limits" => scope_limits,
        "experiments" => experiment_types,
        "agent_levers" => agent_levers,
        "member_type_experiments" => member_type_experiments,
        "params_ssot" => params_ssot_note,
        "insight_categories" => insight_categories,
        "trace_tiers" => [string(t) for t in StructuralSizer.TRACE_TIERS],
        "trace_layers" => [string(l) for l in StructuralSizer.TRACE_LAYERS],
        "workflow_sequence" => [
            "get_situation_card",
            "get_lever_map(check=…) before recommending fixes to a named check",
            "run_experiment (element) or validate_params→run_design (global API)",
            "compare_designs (previous vs latest, no args); record_insight",
        ],
    )
end
