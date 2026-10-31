"""
    api_applicability_schema() -> Dict

Return a compact, machine-readable subset of `api_params_schema_structured()`
containing only method/floor compatibility and applicability rules. Intended for
LLM assistants that need fast eligibility checks without loading the full schema.
"""
function api_applicability_schema()
    s = api_params_schema_structured()

    floor_type = s["floor_type"]
    method = s["floor_options"]["fields"]["method"]

    return Dict{String, Any}(
        "version" => "v1",
        "source" => "api_params_schema_structured",
        "rules" => Dict{String, Any}(
            "floor_type" => Dict{String, Any}(
                "default" => floor_type["default"],
                "allowed" => floor_type["allowed"],
                "compatibility_checks" => floor_type["compatibility_checks"],
            ),
            "analysis_method" => Dict{String, Any}(
                "default" => method["default"],
                "allowed" => method["allowed"],
                "applicability_checks" => method["applicability_checks"],
            ),
        ),
    )
end

"""
    api_diagnose_schema() -> Dict

Return a compact, versioned contract for the `GET /diagnose` payload.
This describes the stable top-level sections and key per-element fields so
assistants/clients can validate presence and parse semantics.
"""
function api_diagnose_schema()
    return Dict{String, Any}(
        "version" => "v1",
        "endpoint" => "GET /diagnose",
        "description" => "High-resolution, machine-readable causal diagnostics for structural sizing decisions.",
        "top_level" => Dict{String, Any}(
            "status" => "string",
            "unit_system" => "enum(imperial|metric)",
            "length_unit" => "string",
            "thickness_unit" => "string",
            "force_unit" => "string",
            "moment_unit" => "string",
            "pressure_unit" => "string",
            "design_context" => "object",
            "agent_summary" => "object",
            "columns" => "array<object>",
            "beams" => "array<object>",
            "slabs" => "array<object>",
            "foundations" => "array<object>",
            "architectural" => "object",
            "constraints" => "object",
        ),
        "design_context" => Dict{String, Any}(
            "required_keys" => [
                "floor_type", "column_type", "beam_type",
                "analysis_method", "deflection_limit", "unit_system", "loads",
            ],
            "loads_keys" => ["floor_SDL", "floor_LL", "roof_SDL", "roof_LL", "unit"],
            "optional_keys" => ["punching_strategy", "punching_strategy_description"],
        ),
        "agent_summary" => Dict{String, Any}(
            "required_keys" => [
                "all_pass", "critical_element", "critical_ratio",
                "total_ec_kgco2e", "governing_check_distribution", "per_type",
            ],
            "distribution_item" => Dict("check" => "string", "count" => "int"),
        ),
        "element_contracts" => Dict{String, Any}(
            "common_required" => [
                "id", "governing_check", "governing_ratio",
                "governing_mode", "ok", "checks", "levers",
                "limit_state_description",
            ],
            "columns_required" => [
                "section", "shape", "Pu", "Mu_x", "Mu_y",
                "axial_ratio", "interaction_ratio", "ec_kgco2e",
            ],
            "beams_required" => [
                "section", "Mu", "Vu", "ec_kgco2e",
            ],
            "slabs_required" => [
                "thickness", "l1", "l2", "M0", "qu",
                "deflection", "deflection_limit", "deflection_unit", "ec_kgco2e",
            ],
            "foundations_required" => [
                "length", "width", "depth", "reaction",
            ],
            "check_required" => [
                "name", "code_clause", "ratio", "headroom", "governing",
            ],
            "check_optional" => [
                "demand", "capacity", "demand_unit", "capacity_phiVc",
                "demand_Mu_x", "demand_Mu_y", "demand_Vu", "demand_vu",
            ],
        ),
        "architectural" => Dict{String, Any}(
            "required_keys" => ["system_narrative", "scale_references", "goal_recommendations"],
        ),
        "constraints" => Dict{String, Any}(
            "required_keys" => ["fixed_by_geometry", "lever_impacts"],
        ),
        "notes" => [
            "All numeric values are emitted in the selected display unit system.",
            "Some fields (e.g., ec_kgco2e) may be null when unavailable.",
            "Keys are ASCII-only for robust machine parsing.",
        ],
    )
end

