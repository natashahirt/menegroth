# ─── Phase 2: Diagnosis ──────────────────────────────────────────────────────

"""
    agent_query_elements(design::BuildingDesign; kwargs...) -> Dict{String, Any}

Run `design_to_diagnose` and filter elements by the given criteria.
"""
function agent_query_elements(
    design::BuildingDesign;
    type::Union{String, Nothing}=nothing,
    min_ratio::Union{Float64, Nothing}=nothing,
    max_ratio::Union{Float64, Nothing}=nothing,
    governing_check::Union{String, Nothing}=nothing,
    ok::Union{Bool, Nothing}=nothing,
    story::Union{Int, Nothing}=nothing,
)::Dict{String, Any}
    diag = get_cached_diagnose(DESIGN_CACHE, design)

    function _matches(d::Dict)
        if !isnothing(min_ratio)
            r = something(get(d, "governing_ratio", 0.0), 0.0)
            r < min_ratio && return false
        end
        if !isnothing(max_ratio)
            r = something(get(d, "governing_ratio", 0.0), 0.0)
            r > max_ratio && return false
        end
        if !isnothing(governing_check)
            get(d, "governing_check", "") != governing_check && return false
        end
        if !isnothing(ok)
            get(d, "ok", true) != ok && return false
        end
        if !isnothing(story)
            elem_story = get(d, "story", nothing)
            !isnothing(elem_story) && elem_story != story && return false
        end
        return true
    end

    results = Dict{String, Any}()
    type_map = Dict(
        "column"     => "columns",
        "beam"       => "beams",
        "slab"       => "slabs",
        "foundation" => "foundations",
    )

    types_to_check = isnothing(type) ? keys(type_map) : [type]
    total = 0

    for t in types_to_check
        key = get(type_map, t, t * "s")
        elements = get(diag, key, [])
        matched = filter(_matches, elements)
        if !isempty(matched)
            results[key] = matched
            total += length(matched)
        end
    end

    results["total_matched"] = total
    results["unit_system"]   = get(diag, "unit_system", "imperial")
    return results
end

"""
    agent_explain_field(field_name::String) -> Dict{String, Any}

Look up a field in `api_params_schema_structured()` and return its metadata.
"""
function agent_explain_field(field_name::String)::Dict{String, Any}
    schema = api_params_schema_structured()
    fn_lower = lowercase(field_name)

    found_field = nothing
    found_details = nothing

    for (top_key, top_val) in schema
        if lowercase(string(top_key)) == fn_lower
            found_field = string(top_key)
            found_details = top_val
            break
        end
        if top_val isa Dict
            for (sub_key, sub_val) in top_val
                full_key = "$(top_key).$(sub_key)"
                if lowercase(string(sub_key)) == fn_lower || lowercase(full_key) == fn_lower
                    found_field = full_key
                    found_details = sub_val
                    break
                end
                if sub_val isa Dict
                    for (inner_key, inner_val) in sub_val
                        full_inner = "$(top_key).$(sub_key).$(inner_key)"
                        if lowercase(string(inner_key)) == fn_lower || lowercase(full_inner) == fn_lower
                            found_field = full_inner
                            found_details = inner_val
                            break
                        end
                    end
                end
                !isnothing(found_field) && break
            end
        end
        !isnothing(found_field) && break
    end

    if isnothing(found_field)
        return Dict{String, Any}(
            "error"   => "field_not_found",
            "message" => "Field \"$field_name\" not found in the parameter schema. " *
                         "Use get_applicability or check the /schema endpoint for valid field names.",
        )
    end

    result = Dict{String, Any}("field" => found_field, "details" => found_details)

    # Enrich with ontology rationale when available
    leaf = split(found_field, ".")[end]
    rationale = get_code_rationale(string(leaf))
    if !isnothing(rationale)
        result["rationale"] = rationale
    end

    # Surface related checks with provision summaries via LEVER_SURFACE_MAP + ontology
    related_checks = Dict{String, Any}[]
    for (check_name, lever_info) in LEVER_SURFACE_MAP
        params = get(lever_info, "parameters", String[])
        if string(leaf) in params
            entry = Dict{String, Any}("check" => check_name)
            provs = get_provisions_for_check(check_name)
            if !isempty(provs)
                p = provs[1]
                entry["provision"] = get(p, "provision", "")
                entry["failure_consequence"] = get(p, "failure_consequence", "")
                mech = get(p, "mechanism", "")
                entry["mechanism"] = length(mech) > 120 ? mech[1:117] * "..." : mech
            end
            push!(related_checks, entry)
        end
    end
    if !isempty(related_checks)
        result["related_checks"] = related_checks
    end

    return result
end

