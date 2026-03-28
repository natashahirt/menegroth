# Dump JSON artifacts for paper "input contract" figure (same payloads as GET /schema/* and chat tools).
#
# Run from repo root:
#   SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false julia --project=StructuralSynthesizer scripts/runners/dump_paper_contract_json.jl
#
# Output: paper_contract_snippets/*.json

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using JSON3
using StructuralSynthesizer
using Unitful

const OUT = joinpath(@__DIR__, "..", "..", "paper_contract_snippets")

function validate_params_like_chat(param_patch::Dict{String, Any})
    schema_rules = get(get(api_applicability_schema(), "rules", Dict()), "floor_type", Dict())
    compat = get(schema_rules, "compatibility_checks", Dict())
    rules  = get(compat, "rules", Any[])
    floor_type   = get(param_patch, "floor_type", nothing)
    column_type  = get(param_patch, "column_type", nothing)
    beam_type    = get(param_patch, "beam_type", nothing)
    violations = String[]
    for rule in rules
        when_clause = get(rule, "when", Dict())
        rejects     = get(rule, "rejects", Dict())
        when_floor = get(when_clause, "floor_type", nothing)
        active = false
        if !isnothing(when_floor) && !isnothing(floor_type)
            active = when_floor isa Vector ? floor_type in when_floor : floor_type == when_floor
        end
        active || continue
        reject_cols  = get(rejects, "column_type", String[])
        reject_beams = get(rejects, "beam_type",   String[])
        rule_id      = get(rule, "id", "rule")
        if !isnothing(column_type) && column_type in reject_cols
            push!(violations, "$rule_id: column_type \"$column_type\" is incompatible with floor_type \"$floor_type\"")
        end
        if !isnothing(beam_type) && beam_type in reject_beams
            push!(violations, "$rule_id: beam_type \"$beam_type\" is incompatible with floor_type \"$floor_type\"")
        end
    end
    return Dict{String, Any}("ok" => isempty(violations), "violations" => violations)
end

function write_json(path, obj)
    open(path, "w") do io
        JSON3.pretty(io, obj)
    end
    println("wrote ", path)
end

mkpath(OUT)

# ── Contract surface (same as GET /schema/llm_contract) ───────────────────────
full_contract = StructuralSynthesizer.api_llm_contract()
write_json(joinpath(OUT, "llm_contract_full.json"), full_contract)

tools = full_contract["tools"]
trunc_contract = Dict{String, Any}(
    "contract_version" => full_contract["contract_version"],
    "system" => full_contract["system"],
    "description" => full_contract["description"],
    "n_tools" => full_contract["n_tools"],
    "scope_limits" => full_contract["scope_limits"],
    "trace_tiers" => full_contract["trace_tiers"],
    "trace_layers" => full_contract["trace_layers"],
    "workflow_sequence" => full_contract["workflow_sequence"],
    "tools_sample" => tools[1:min(2, length(tools))],
    "parameters_sample" => full_contract["parameters"][1:min(4, length(full_contract["parameters"]))],
    "experiments" => full_contract["experiments"],
)
write_json(joinpath(OUT, "llm_contract_truncated_for_figure.json"), trunc_contract)

# ── Applicability (same as GET /schema/applicability) ─────────────────────────
app = api_applicability_schema()
write_json(joinpath(OUT, "applicability_full.json"), app)

rules = get(get(get(app, "rules", Dict()), "floor_type", Dict()), "compatibility_checks", Dict())["rules"]
trunc_app = Dict{String, Any}(
    "version" => app["version"],
    "source" => app["source"],
    "compatibility_rules_excerpt" => rules[1:min(2, length(rules))],
)
write_json(joinpath(OUT, "applicability_truncated_for_figure.json"), trunc_app)

# ── Positive: explain_field (same as tool explain_field) ──────────────────────
explain = StructuralSynthesizer.agent_explain_field("deflection_limit")
write_json(joinpath(OUT, "explain_field_deflection_limit.json"), explain)

# ── Positive: get_current_params after a tiny design ──────────────────────────
skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
struc = BuildingStructure(skel)
design = design_building(
    struc,
    DesignParameters(
        name = "paper_contract_dump",
        floor = FlatPlateOptions(method = DDM()),
        max_iterations = 2,
    ),
)
params_snapshot = StructuralSynthesizer.agent_current_params(design)
write_json(joinpath(OUT, "get_current_params_after_design.json"), params_snapshot)

# ── Negative: validate_params violation ────────────────────────────────────────
bad_patch = Dict{String, Any}("floor_type" => "flat_plate", "column_type" => "steel_w")
write_json(joinpath(OUT, "validate_params_flat_plate_steel_column.json"), validate_params_like_chat(bad_patch))

# ── Negative: geometric_change_required (verbatim shape from chat.jl run_design) ─
write_json(
    joinpath(OUT, "geometric_change_required_example.json"),
    Dict(
        "error" => "geometric_change_required",
        "geometric_fields" => ["bay_width", "story_height"],
        "message" =>
            "This recommendation requires changing the building geometry in Grasshopper. " *
            "The following are geometry properties, not API parameters: bay_width, story_height. " *
            "Adjust the Rhino model or the GeometryInput component, then re-run the design from Grasshopper.",
        "note" =>
            "run_design only applies changes to API parameters (floor type, material, loads, sizing strategy, etc.). " *
            "Geometric changes — column positions, bay dimensions, story heights, setbacks — must be made in Grasshopper.",
    ),
)

println("\nDone. See directory: ", OUT)
