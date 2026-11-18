# ─── Geometric recommendation detection ──────────────────────────────────────

# Known top-level keys of APIParams (keeps the LLM honest about what run_design can do).
const _API_PARAM_KEYS = Set([
    "floor_type", "floor_options", "column_type", "column_catalog",
    "column_sizing_strategy", "beam_type", "beam_catalog", "beam_sizing_strategy",
    "floor_ll", "roof_ll", "grade_ll", "floor_sdl", "roof_sdl", "wall_sdl",
    "concrete", "rebar", "steel", "deflection_limit", "punching_strategy",
    "vault_lambda", "max_iterations", "skip_visualization", "mip_time_limit_sec",
    "fea_target_edge_m", "steel_w_bounds", "steel_hss_bounds", "rc_rect_bounds",
    "rc_circular_bounds", "pixelframe_fc_preset", "pixelframe_fc_min_ksi",
    "pixelframe_fc_max_ksi", "pixelframe_fc_resolution_ksi", "fire_rating",
    "optimize_for", "size_foundations", "foundation_soil", "foundation_concrete",
    "foundation_strategy", "mat_coverage_threshold", "unit_system",
    "visualization_detail", "visualization_target_edge_m",
    "uniform_column_sizing",
    "composite", "composite_slab_type", "composite_t_slab_in",
    "composite_anchor_d_in", "composite_anchor_length_in", "composite_anchor_Fu_ksi",
    "composite_shored", "composite_cp_class",
    "composite_deck_hr_in", "composite_deck_wr_in", "composite_deck_orientation",
])

# Keys that belong inside nested APIParams sub-structs when provided at the top level.
const _FLOOR_OPTION_KEYS = Set(["method", "deflection_limit", "punching_strategy", "target_edge_m", "fea_target_edge_m", "vault_lambda"])
const _LOADS_KEYS        = Set(["floor_ll", "roof_ll", "grade_ll", "floor_sdl", "roof_sdl", "wall_sdl"])

"""
    _normalize_flat_patch(patch) -> Dict{String, Any}

Promote flat top-level keys into their proper nested APIParams structure so
`JSON3.read(..., APIParams)` sees them.  For example, a patch
`{"punching_strategy": "reinforce_first"}` becomes
`{"floor_options": {"punching_strategy": "reinforce_first"}}`.
Keys already nested (e.g. `floor_options` dict) are left untouched.
"""
function _normalize_flat_patch(patch::Dict{String, Any})::Dict{String, Any}
    out = Dict{String, Any}()
    floor_opts = Dict{String, Any}()
    loads_dict = Dict{String, Any}()

    for (k, v) in patch
        ks = lowercase(k)
        if ks in _FLOOR_OPTION_KEYS
            floor_opts[ks] = v
        elseif ks in _LOADS_KEYS
            loads_dict[ks] = v
        else
            out[k] = v
        end
    end

    if !isempty(floor_opts)
        existing = get(out, "floor_options", nothing)
        if existing isa AbstractDict
            merge!(existing, floor_opts)
        else
            out["floor_options"] = floor_opts
        end
    end
    if !isempty(loads_dict)
        existing = get(out, "loads", nothing)
        if existing isa AbstractDict
            merge!(existing, loads_dict)
        else
            out["loads"] = loads_dict
        end
    end
    return out
end

"""
    _deep_merge(base, patch) -> Dict{String, Any}

Recursively merge `patch` into `base`.  When both sides have a dict for the same
key, merge recursively; otherwise `patch` wins.  Neither input is mutated.
"""
function _deep_merge(base::Dict{String, Any}, patch::Dict{String, Any})::Dict{String, Any}
    out = copy(base)
    for (k, v) in patch
        existing = get(out, k, nothing)
        if existing isa AbstractDict && v isa AbstractDict
            out[k] = _deep_merge(Dict{String, Any}(string(ek) => ev for (ek, ev) in existing),
                                 Dict{String, Any}(string(pk) => pv for (pk, pv) in v))
        else
            out[k] = v
        end
    end
    return out
end

"""Default wire-format API params (all `APIParams` defaults) as a plain Dict."""
function _default_api_params_wire_dict()::Dict{String, Any}
    JSON3.read(JSON3.write(APIParams()), Dict{String, Any})
end

"""
    _chat_api_params_base() -> Dict{String, Any}

Single source of truth for chat-side parameter patching: the last successful design's
`api_params` JSON, or default `APIParams()` when empty. There is no parallel \"original\"
snapshot — this object is replaced in full after each successful `POST /design` or chat `run_design`.
"""
function _chat_api_params_base()::Dict{String, Any}
    snap = with_cache_read(c -> copy(c.last_api_params_json), DESIGN_CACHE)
    isempty(snap) ? _default_api_params_wire_dict() : snap
end

"""Deep-merge `patch_norm` (already `_normalize_flat_patch` when needed) into the server SSOT."""
function _chat_merge_api_params_patch(patch_norm::Dict{String, Any})::Dict{String, Any}
    _deep_merge(_chat_api_params_base(), patch_norm)
end

# Keyword fragments that suggest a geometric (Grasshopper-side) change.
const _GEOMETRIC_PATTERNS = [
    "spacing", "span", "bay_width", "bay_depth", "story_height", "floor_height",
    "num_stories", "num_bays", "num_columns", "column_layout", "column_position",
    "grid_size", "grid_spacing", "plan_width", "plan_depth", "footprint",
    "bay_size", "cantilever", "setback", "opening",
]

"""
    _classify_patch(patch) -> (api_keys, geometric_hints, other_unknown)

Split a param patch dict into three sets:
- `api_keys`       : keys recognised as valid APIParams fields.
- `geometric_hints`: keys not in APIParams but matching geometric-change patterns.
- `other_unknown`  : remaining unrecognised keys (e.g. typos).
"""
function _classify_patch(patch::Dict)
    api_keys       = String[]
    geo_hints      = String[]
    other_unknown  = String[]
    for k in keys(patch)
        ks = lowercase(string(k))
        if ks in _API_PARAM_KEYS
            push!(api_keys, string(k))
        elseif any(p -> occursin(p, ks), _GEOMETRIC_PATTERNS)
            push!(geo_hints, string(k))
        else
            push!(other_unknown, string(k))
        end
    end
    return api_keys, geo_hints, other_unknown
end

"""
    _validate_params_patch(patch) -> Dict{String, Any}

Validate a params patch against the full schema: enum membership, numeric
ranges, unknown keys, and floor/column/beam compatibility rules.
Returns `{ok, violations, warnings}`.
"""
function _validate_params_patch(patch::Dict{String, Any})::Dict{String, Any}
    violations = Dict{String, Any}[]
    warnings   = String[]
    schema     = api_params_schema_structured()

    # 1. Check for unknown keys.
    api_keys, geo_hints, unknowns = _classify_patch(patch)
    for k in unknowns
        push!(warnings, "Unknown parameter \"$k\". Not a recognized API field.")
    end
    for k in geo_hints
        push!(warnings, "\"$k\" looks like a geometric parameter — geometry is set in Grasshopper, not via the API.")
    end

    # 2. Enum and range checks — walk top-level and nested fields.
    _check_schema_constraints!(violations, patch, schema, "")

    # 3. Compatibility rules (floor ↔ column ↔ beam).
    floor_type  = get(patch, "floor_type", nothing)
    column_type = get(patch, "column_type", nothing)
    beam_type   = get(patch, "beam_type", nothing)
    if !isnothing(floor_type)
        floor_schema = get(schema, "floor_type", nothing)
        if !isnothing(floor_schema)
            compat = get(floor_schema, "compatibility_checks", nothing)
            if !isnothing(compat)
                for rule in get(compat, "rules", Any[])
                    when_clause = get(rule, "when", Dict())
                    rejects     = get(rule, "rejects", Dict())
                    when_floor  = get(when_clause, "floor_type", nothing)
                    active = if !isnothing(when_floor)
                        when_floor isa Vector ? floor_type in when_floor : floor_type == when_floor
                    else
                        false
                    end
                    active || continue
                    rule_id = get(rule, "id", "compatibility")
                    sev     = get(rule, "severity", "error")
                    reject_cols  = get(rejects, "column_type", String[])
                    reject_beams = get(rejects, "beam_type",   String[])
                    if !isnothing(column_type) && column_type in reject_cols
                        push!(violations, Dict{String, Any}(
                            "field" => "column_type", "value" => column_type,
                            "constraint" => "compatibility",
                            "message" => "$rule_id: column_type \"$column_type\" incompatible with floor_type \"$floor_type\"",
                            "severity" => sev,
                        ))
                    end
                    if !isnothing(beam_type) && beam_type in reject_beams
                        push!(violations, Dict{String, Any}(
                            "field" => "beam_type", "value" => beam_type,
                            "constraint" => "compatibility",
                            "message" => "$rule_id: beam_type \"$beam_type\" incompatible with floor_type \"$floor_type\"",
                            "severity" => sev,
                        ))
                    end
                end
            end
        end
    end

    # 4. uniform_column_sizing + pixelframe compatibility
    # Only check when both fields are present in the patch; if column_type is not
    # in the patch we can't know the current type — full API validation catches it.
    ucs = get(patch, "uniform_column_sizing", nothing)
    if !isnothing(ucs) && lowercase(string(ucs)) != "off" && !isnothing(column_type)
        if column_type == "pixelframe"
            push!(violations, Dict{String, Any}(
                "field" => "uniform_column_sizing", "value" => ucs,
                "constraint" => "compatibility",
                "message" => "uniform_column_sizing \"$ucs\" is not supported with pixelframe columns.",
            ))
        end
    end

    # Field guidance: for each patched API key, show related checks from lever map
    field_guidance = Dict{String, Any}()
    for k in api_keys
        affected_checks = String[]
        for (check_name, lever_info) in LEVER_SURFACE_MAP
            params_list = get(lever_info, "parameters", String[])
            if k in params_list
                push!(affected_checks, check_name)
            end
        end
        if !isempty(affected_checks)
            field_guidance[k] = Dict{String, Any}(
                "affects_checks" => affected_checks,
                "impact" => get(get(schema, k, Dict()), "impact", nothing),
            )
        end
    end

    result = Dict{String, Any}(
        "ok" => isempty(violations),
        "violations" => violations,
        "warnings" => warnings,
    )
    !isempty(field_guidance) && (result["field_guidance"] = field_guidance)
    return result
end

function _check_schema_constraints!(violations, patch, schema, prefix)
    for (key, val) in patch
        full_key = isempty(prefix) ? key : "$(prefix).$(key)"
        spec = get(schema, key, nothing)
        isnothing(spec) && continue
        !isa(spec, Dict) && continue

        ptype = get(spec, "type", "")

        if ptype == "object"
            sub_fields = get(spec, "fields", nothing)
            if !isnothing(sub_fields) && val isa Dict
                _check_schema_constraints!(violations, Dict{String, Any}(string(k) => v for (k, v) in val), sub_fields, full_key)
            end
        elseif ptype == "enum"
            allowed = get(spec, "allowed", nothing)
            if !isnothing(allowed) && !(string(val) in [string(a) for a in allowed])
                push!(violations, Dict{String, Any}(
                    "field" => full_key, "value" => val,
                    "constraint" => "enum",
                    "allowed" => allowed,
                    "message" => "\"$full_key\" = \"$val\" not in allowed values: $(join(allowed, ", "))",
                ))
            end
        elseif ptype == "number" || ptype == "float" || ptype == "integer"
            rng = get(spec, "range", nothing)
            if !isnothing(rng) && length(rng) >= 2 && val isa Real
                lo, hi = rng[1], rng[2]
                if val < lo || val > hi
                    push!(violations, Dict{String, Any}(
                        "field" => full_key, "value" => val,
                        "constraint" => "range",
                        "range" => rng,
                        "message" => "\"$full_key\" = $val out of range [$lo, $hi]",
                    ))
                end
            end
        elseif ptype == "bool" || ptype == "boolean"
            if !(val isa Bool)
                push!(violations, Dict{String, Any}(
                    "field" => full_key, "value" => val,
                    "constraint" => "type",
                    "message" => "\"$full_key\" must be a boolean, got $(typeof(val))",
                ))
            end
        end
    end
end

"""
    _extract_params_patch(text) -> Union{Dict{String,Any}, Nothing}

Extract a JSON code block from the assistant text that looks like a parameter
patch (contains at least one known API param key or a `_history_label`).
Returns the parsed dict with validation info, or `nothing` if no patch found.
"""
function _extract_params_patch(text::String)::Union{Dict{String, Any}, Nothing}
    isempty(text) && return nothing
    m = match(r"```json\s*\n([\s\S]*?)\n\s*```"i, text)
    isnothing(m) && return nothing
    json_str = strip(m.captures[1])
    isempty(json_str) && return nothing

    local parsed
    try
        parsed = Dict{String, Any}(string(k) => v for (k, v) in JSON3.read(json_str))
    catch
        return nothing
    end
    isempty(parsed) && return nothing

    api_keys, geo_hints, _ = _classify_patch(parsed)
    (isempty(api_keys) && !haskey(parsed, "_history_label")) && return nothing

    history_label = pop!(parsed, "_history_label", nothing)
    clean_patch = Dict{String, Any}(k => v for (k, v) in parsed if lowercase(k) in _API_PARAM_KEYS)
    isempty(clean_patch) && return nothing
    clean_patch = _normalize_flat_patch(clean_patch)

    validation = _validate_params_patch(clean_patch)
    result = Dict{String, Any}(
        "patch"      => clean_patch,
        "valid"      => get(validation, "ok", false),
        "violations" => get(validation, "violations", []),
        "warnings"   => get(validation, "warnings", []),
    )
    if !isempty(geo_hints)
        result["geometric_hints"] = geo_hints
    end
    if !isnothing(history_label)
        result["history_label"] = string(history_label)
    end
    return result
end

"""
    _build_turn_summary(; suggestions, clarification_data, tool_actions, params_patch) -> Dict

Canonical turn-summary event.  Guarantees `suggested_next_questions` is always
present (empty array when absent) and `clarification_prompt` is either a valid
dict or `nothing`.  `tool_actions` is an optional array of tool-action records.
When `params_patch` is present, includes validated parameter changes for the
client's "Apply & Run" button.
"""
function _build_turn_summary(;
    suggestions::Vector{String}         = String[],
    clarification_data                  = nothing,
    tool_actions::Vector{Dict{String,Any}} = Dict{String,Any}[],
    params_patch::Union{Dict{String,Any}, Nothing} = nothing,
)::Dict{String, Any}
    summary = Dict{String, Any}(
        "type"                     => "agent_turn_summary",
        "suggested_next_questions" => suggestions,
        "clarification_prompt"     => _normalize_clarification(clarification_data),
    )
    if !isempty(tool_actions)
        summary["tool_actions"] = tool_actions
    end
    if !isnothing(params_patch)
        summary["params_patch"] = params_patch
    end
    return summary
end

