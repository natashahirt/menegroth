# ─── Top-Level Dispatch ──────────────────────────────────────────────────────

"""
    list_experiments() -> Dict

Return metadata about available micro-experiment types.
"""
function list_experiments()::Dict{String, Any}
    Dict{String, Any}(
        "experiments" => [
            Dict{String, Any}(
                "name" => "punching",
                "description" => "Re-check punching shear with modified column size, slab thickness, or concrete strength. " *
                    "Respects column position (interior/edge/corner) and unbalanced moment. " *
                    "Adjusts Vu for critical-area change. Returns demand, capacity, stress decomposition.",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "c1_in" => "optional Float64 — new column c1 dimension (inches)",
                    "c2_in" => "optional Float64 — new column c2 dimension (inches)",
                    "h_in" => "optional Float64 — new slab thickness (inches)",
                    "fc_in" => "optional Float64 — new concrete compressive strength (psi, e.g. 5000)",
                ),
                "example" => "run_experiment(type=punching, args={col_idx=3, c1_in=20, c2_in=20})",
            ),
            Dict{String, Any}(
                "name" => "pm_column",
                "description" => "Test P-M interaction with a different section using the real checker. " *
                    "RC: scales rebar layout to column size. Steel: uses full AISC checker. " *
                    "Returns demands, original/modified ratios, and all individual check results.",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "section_size" => "Float64 (inches, for RC square column) or String (W-shape, e.g. \"W14X82\")",
                ),
                "example" => "run_experiment(type=pm_column, args={col_idx=5, section_size=24})",
            ),
            Dict{String, Any}(
                "name" => "beam",
                "description" => "Steel beams only: test cached Mu/Vu against a different AISC W-shape. " *
                    "Uses full AISC checker (flexure, shear, LTB, etc.). " *
                    "RC or other section types return beam_not_steel_w — use run_design for those.",
                "args" => Dict(
                    "beam_idx" => "required Int — beam index from diagnose",
                    "section_size" => "required String — W-shape designation (e.g. \"W16X40\")",
                ),
                "example" => "run_experiment(type=beam, args={beam_idx=1, section_size=\"W16X40\"})",
            ),
            Dict{String, Any}(
                "name" => "punching_reinforcement",
                "description" => "Design shear studs or closed stirrups for a column failing punching shear. " *
                    "Uses cached demands to run the full stud/stirrup design algorithm. " *
                    "Returns reinforcement layout and whether the column now passes.",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "reinforcement_type" => "optional String — \"studs\" (default) or \"stirrups\"",
                    "stud_diameter_in" => "optional Float64 — stud diameter in inches (default 0.5, studs only)",
                    "bar_size" => "optional Int — stirrup bar designation: 3, 4, or 5 (default 4, stirrups only)",
                    "fyt_psi" => "optional Float64 — reinforcement yield strength in psi (default 51000 studs / 60000 stirrups)",
                ),
                "example" => "run_experiment(type=punching_reinforcement, args={col_idx=3, reinforcement_type=\"studs\"})",
            ),
            Dict{String, Any}(
                "name" => "punching_column_downsize",
                "description" => "With Vu and Mub fixed to the cached design values, find the smallest uniform scale of the column footprint " *
                    "such that punching passes with shear studs or closed stirrups. " *
                    "Optionally cross-checks P-M at a square section (max side). " *
                    "Use this to see whether reinforce_first-style capacity could allow a smaller column than grow_columns, before a full run_design.",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "reinforcement_type" => "optional String — \"studs\" (default) or \"stirrups\"",
                    "min_column_dim_in" => "optional Float64 — minimum smaller plan dimension in inches (default 8)",
                    "stud_diameter_in" => "optional Float64 — stud diameter (studs only)",
                    "bar_size" => "optional Int — stirrup bar #3–5 (stirrups only)",
                    "fyt_psi" => "optional Float64 — reinforcement yield (psi)",
                    "check_pm" => "optional Bool — run pm_column heuristic at downsized size (default true)",
                ),
                "example" => "run_experiment(type=punching_column_downsize, args={col_idx=3, reinforcement_type=\"studs\"})",
            ),
            Dict{String, Any}(
                "name" => "deflection",
                "description" => "Test a slab under a different deflection limit (L/240, L/360, L/480). " *
                    "Does NOT re-compute actual deflection — only changes the allowable limit. " *
                    "Use run_design to test a thicker slab.",
                "args" => Dict(
                    "slab_idx" => "required Int — slab index from diagnose",
                    "deflection_limit" => "L_240 | L_360 | L_480 (default L_360)",
                ),
                "example" => "run_experiment(type=deflection, args={slab_idx=1, deflection_limit=L_480})",
            ),
            Dict{String, Any}(
                "name" => "catalog_screen",
                "description" => "Screen multiple candidate column sizes against stored demands. " *
                    "Sorts by ratio, identifies best and lightest feasible. " *
                    "RC: pass Float64[] (inches). Steel: pass String[] (W-shapes).",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "candidates" => "Float64[] for RC or String[] for steel — list of sizes to test",
                ),
                "example" => "run_experiment(type=catalog_screen, args={col_idx=5, candidates=[14,16,18,20,24]})",
            ),
        ],
        "note" => "Micro-experiments are INSTANT (~0.1s) — they use cached design data and real StructuralSizer checkers. " *
            "Use run_design only when you need to test a GLOBAL parameter change across all elements.",
    )
end

"""
    evaluate_experiment(design, experiment_type, args) -> Dict

Dispatch a micro-experiment by name.
"""
function evaluate_experiment(
    design::BuildingDesign,
    experiment_type::String,
    args::Dict{String, Any},
)::Dict{String, Any}
    if experiment_type == "punching"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "punching experiment requires col_idx")
        c1_in = _coerce_float(get(args, "c1_in", nothing))
        c2_in = _coerce_float(get(args, "c2_in", nothing))
        h_in = _coerce_float(get(args, "h_in", nothing))
        fc_in = _coerce_float(get(args, "fc_in", nothing))
        return experiment_punching(design, col_idx;
            c1_in = c1_in,
            c2_in = c2_in,
            h_in = h_in,
            fc_in = fc_in,
        )
    elseif experiment_type == "beam"
        beam_idx = _coerce_int(get(args, "beam_idx", nothing))
        isnothing(beam_idx) && return Dict("error" => "missing_beam_idx", "message" => "beam experiment requires beam_idx")
        return experiment_beam(design, beam_idx;
            section_size = get(args, "section_size", nothing),
        )
    elseif experiment_type == "punching_reinforcement"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "punching_reinforcement experiment requires col_idx")
        rt = string(get(args, "reinforcement_type", "studs"))
        sd_in = _coerce_float(get(args, "stud_diameter_in", nothing))
        bs = _coerce_int(get(args, "bar_size", nothing))
        fyt = _coerce_float(get(args, "fyt_psi", nothing))
        return experiment_punching_reinforcement(design, col_idx;
            reinforcement_type = rt,
            stud_diameter_in = sd_in,
            bar_size = bs,
            fyt_psi = fyt,
        )
    elseif experiment_type == "punching_column_downsize"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "punching_column_downsize experiment requires col_idx")
        rt = string(get(args, "reinforcement_type", "studs"))
        min_dim = _coerce_float(get(args, "min_column_dim_in", nothing))
        sd_in = _coerce_float(get(args, "stud_diameter_in", nothing))
        bs = _coerce_int(get(args, "bar_size", nothing))
        fyt = _coerce_float(get(args, "fyt_psi", nothing))
        check_pm_raw = get(args, "check_pm", true)
        check_pm = if check_pm_raw isa Bool
            check_pm_raw
        elseif check_pm_raw isa Integer
            check_pm_raw != 0
        elseif check_pm_raw isa AbstractString
            lowercase(strip(string(check_pm_raw))) in ("true", "1", "yes", "y")
        else
            true
        end
        return experiment_punching_column_downsize(design, col_idx;
            reinforcement_type = rt,
            min_column_dim_in = something(min_dim, 8.0),
            stud_diameter_in = sd_in,
            bar_size = bs,
            fyt_psi = fyt,
            check_pm = check_pm,
        )
    elseif experiment_type == "pm_column"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "pm_column experiment requires col_idx")
        return experiment_pm_column(design, col_idx;
            section_size = get(args, "section_size", nothing),
        )
    elseif experiment_type == "deflection"
        slab_idx = _coerce_int(get(args, "slab_idx", nothing))
        isnothing(slab_idx) && return Dict("error" => "missing_slab_idx", "message" => "deflection experiment requires slab_idx")
        return experiment_deflection(design, slab_idx;
            deflection_limit = string(get(args, "deflection_limit", "L_360")),
        )
    elseif experiment_type == "catalog_screen"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "catalog_screen experiment requires col_idx")
        candidates_raw = get(args, "candidates", Any[])
        # Accept both numeric (RC) and string (steel) candidates.
        candidates = Any[]
        for c in candidates_raw
            # A numeric string is an RC size in inches. A designation such as
            # "W14X82" is a steel section. Anything else is rejected here so
            # the screen does not have to discover it candidate by candidate.
            if c isa AbstractString
                s = String(strip(c))
                v = _coerce_float(s)
                if !isnothing(v)
                    push!(candidates, v)
                elseif occursin(r"^[A-Za-z]+\d", s)
                    push!(candidates, s)
                else
                    return Dict(
                        "error" => "invalid_candidates",
                        "message" => "All candidates must be numeric inches (RC) or W-shape strings (steel). Got invalid value: $(repr(c))",
                    )
                end
            else
                v = _coerce_float(c)
                if isnothing(v)
                    return Dict(
                        "error" => "invalid_candidates",
                        "message" => "All candidates must be numeric inches (RC) or W-shape strings (steel). Got invalid value: $(repr(c))",
                    )
                end
                push!(candidates, v)
            end
        end
        return experiment_catalog_screen(design, col_idx; candidates)
    else
        return Dict{String, Any}(
            "error" => "unknown_experiment",
            "message" => "Unknown experiment type: \"$experiment_type\". Use list_experiments to see available types.",
        )
    end
end

"""
    batch_evaluate(design, experiments) -> Dict

Run multiple micro-experiments in one call. `experiments` is an array of
`{type, args}` dicts.
"""
function batch_evaluate(
    design::BuildingDesign,
    experiments::Vector,
)::Dict{String, Any}
    results = Dict{String, Any}[]
    for (i, exp) in enumerate(experiments)
        exp_type_str = (exp isa AbstractDict) ? string(get(exp, "type", "")) : ""
        r = try
            !(exp isa AbstractDict) && error("experiment entry must be an object with type and args")
            exp_args = Dict{String, Any}(string(k) => v for (k, v) in get(exp, "args", Dict()))
            evaluate_experiment(design, exp_type_str, exp_args)
        catch e
            Dict{String, Any}(
                "error"   => "experiment_failed",
                "message" => sprint(showerror, e),
                "type"    => exp_type_str,
            )
        end
        r = Dict{String, Any}(r)
        r["experiment_index"] = i
        r["type"] = exp_type_str
        push!(results, r)
    end
    return Dict{String, Any}(
        "n_experiments" => length(results),
        "results" => results,
    )
end
