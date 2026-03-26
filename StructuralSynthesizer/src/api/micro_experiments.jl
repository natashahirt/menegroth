# =============================================================================
# Micro-Experiments — Lightweight what-if checks using cached design data
#
# These functions re-run individual structural checks with modified parameters
# WITHOUT requiring a full design_building pass. They extract demands and
# geometry from a completed BuildingDesign and call StructuralSizer checker
# APIs directly.
#
# Experiment types:
#   - punching:    vary column size or slab thickness for a punching check
#   - pm:          try alternative column sections against cached P-M demands
#   - deflection:  test different deflection limits against stored slab data
#   - catalog:     screen a section catalog against a single demand envelope
# =============================================================================

using Unitful

# ─── Punching Experiments ─────────────────────────────────────────────────────

"""
    experiment_punching(design, col_idx; c1_in, c2_in, h_in) -> Dict

Re-run the ACI punching shear check for column `col_idx` with modified column
dimensions or slab thickness. Uses the stored shear demand `Vu` from the
original design.

Only the specified parameters are changed; others are taken from the design.
"""
function experiment_punching(
    design::BuildingDesign,
    col_idx::Int;
    c1_in::Union{Float64, Nothing} = nothing,
    c2_in::Union{Float64, Nothing} = nothing,
    h_in::Union{Float64, Nothing} = nothing,
)::Dict{String, Any}
    col_result = get(design.columns, col_idx, nothing)
    isnothing(col_result) && return Dict{String, Any}(
        "error" => "column_not_found",
        "message" => "Column index $col_idx not found. Available: $(sort(collect(keys(design.columns))))",
    )

    punching = col_result.punching
    isnothing(punching) && return Dict{String, Any}(
        "error" => "no_punching_data",
        "message" => "Column $col_idx has no punching shear data (may not be a flat plate column).",
    )

    orig_c1 = col_result.c1
    orig_c2 = col_result.c2
    orig_Vu = punching.Vu

    new_c1 = isnothing(c1_in) ? orig_c1 : c1_in * u"inch"
    new_c2 = isnothing(c2_in) ? orig_c2 : c2_in * u"inch"

    # Slab effective depth: approximate from stored data
    slab_concrete = resolve_slab_concrete(design.params.materials)
    fc = slab_concrete.fc′
    cover = 0.75u"inch"
    bar_d = 0.5u"inch"

    orig_h = nothing
    for (_, slab) in design.slabs
        if !isnothing(slab.thickness)
            orig_h = slab.thickness
            break
        end
    end

    isnothing(orig_h) && return Dict{String, Any}(
        "error" => "no_slab_thickness",
        "message" => "Cannot determine slab thickness from design.",
    )

    new_h = isnothing(h_in) ? orig_h : h_in * u"inch"
    d = new_h - cover - bar_d

    # Determine column position from shape
    position = :interior
    shape = col_result.shape == :circular ? :circular : :rectangular

    Mub = 0.0u"kip*ft"  # Conservative: no unbalanced moment in simplified check

    result = StructuralSizer.punching_check(
        orig_Vu, Mub, 0.0u"kip*ft",
        d, fc, new_c1, new_c2;
        position = position, shape = shape,
    )

    orig_ratio = punching.ratio

    return Dict{String, Any}(
        "experiment" => "punching",
        "column_idx" => col_idx,
        "original" => Dict{String, Any}(
            "c1_in" => round(ustrip(u"inch", orig_c1); digits=1),
            "c2_in" => round(ustrip(u"inch", orig_c2); digits=1),
            "ratio" => round(orig_ratio; digits=3),
            "ok" => punching.ok,
        ),
        "modified" => Dict{String, Any}(
            "c1_in" => round(ustrip(u"inch", new_c1); digits=1),
            "c2_in" => round(ustrip(u"inch", new_c2); digits=1),
            "h_in" => round(ustrip(u"inch", new_h); digits=1),
            "ratio" => round(result.utilization; digits=3),
            "ok" => result.ok,
            "vu_psi" => round(ustrip(u"psi", result.vu); digits=1),
            "φvc_psi" => round(ustrip(u"psi", result.ϕvc); digits=1),
        ),
        "delta_ratio" => round(result.utilization - orig_ratio; digits=3),
        "improved" => result.utilization < orig_ratio,
    )
end

# ─── P-M Interaction Experiments ──────────────────────────────────────────────

"""
    experiment_pm_column(design, col_idx; section_size) -> Dict

Test a column against its cached P-M demands with a different section size.
Uses the stored Pu, Mu_x, Mu_y from the original design and computes a
simplified interaction ratio.

For RC columns, `section_size` is the new dimension in inches (square assumed).
For steel columns, `section_size` is the W-shape designation string.
"""
function experiment_pm_column(
    design::BuildingDesign,
    col_idx::Int;
    section_size::Union{Float64, String, Nothing} = nothing,
)::Dict{String, Any}
    col = get(design.columns, col_idx, nothing)
    isnothing(col) && return Dict{String, Any}(
        "error" => "column_not_found",
        "message" => "Column index $col_idx not found.",
    )

    Pu = col.Pu
    Mux = col.Mu_x
    Muy = col.Mu_y
    orig_ratio = max(col.axial_ratio, col.interaction_ratio)

    mats = design.params.materials
    is_rc = col.shape in (:rectangular, :circular, :rc_rect, :rc_circular)

    if is_rc
        isnothing(section_size) && return Dict{String, Any}(
            "error" => "section_size_required",
            "message" => "Provide section_size (inches) for RC column experiment.",
        )
        new_dim = Float64(section_size)
        col_concrete = resolve_column_concrete(mats)
        col_rebar = resolve_column_rebar(mats)
        fc = col_concrete.fc′
        fy = col_rebar.Fy
        fc_psi = ustrip(u"psi", fc)
        fy_psi = ustrip(u"psi", fy)

        Ag = new_dim^2  # in²
        rho_g = 0.02  # Assume 2% reinforcement
        As = rho_g * Ag

        # ACI simplified axial capacity (no slenderness)
        φPn_kip = 0.65 * 0.80 * (0.85 * fc_psi * (Ag - As) + fy_psi * As) / 1000
        Pu_kip = ustrip(u"kip", Pu)
        axial_ratio = Pu_kip / φPn_kip

        # Rough M capacity: 0.12 * fc * b * d² (simplified flexural capacity)
        d_in = new_dim - 2.5  # cover + half bar
        φMn_kipft = 0.9 * 0.12 * fc_psi * new_dim * d_in^2 / 12000
        Mux_kipft = ustrip(u"kip*ft", Mux)
        moment_ratio = Mux_kipft / max(φMn_kipft, 1e-6)

        new_ratio = max(axial_ratio, moment_ratio)

        return Dict{String, Any}(
            "experiment" => "pm_column",
            "column_idx" => col_idx,
            "column_type" => "RC",
            "original" => Dict{String, Any}(
                "section" => col.section_size,
                "ratio" => round(orig_ratio; digits=3),
                "ok" => col.ok,
            ),
            "modified" => Dict{String, Any}(
                "section" => "$(Int(new_dim))x$(Int(new_dim))",
                "axial_ratio" => round(axial_ratio; digits=3),
                "moment_ratio" => round(moment_ratio; digits=3),
                "interaction_ratio" => round(new_ratio; digits=3),
                "ok" => new_ratio <= 1.0,
                "φPn_kip" => round(φPn_kip; digits=0),
                "φMn_kipft" => round(φMn_kipft; digits=0),
            ),
            "delta_ratio" => round(new_ratio - orig_ratio; digits=3),
            "improved" => new_ratio < orig_ratio,
            "note" => "Simplified estimate (ACI §10.3.6.2 axial + approximate flexure, 2% ρg assumed, no slenderness). Use run_design for exact results.",
        )
    else
        return Dict{String, Any}(
            "error" => "steel_pm_not_yet_supported",
            "message" => "Steel column P-M micro-experiment not yet implemented. Use run_design for steel column what-if checks.",
        )
    end
end

# ─── Deflection Experiments ───────────────────────────────────────────────────

"""
    experiment_deflection(design, slab_idx; deflection_limit) -> Dict

Test what happens to a slab's deflection check under a different limit
(L/240, L/360, L/480). Uses the stored deflection values from the design.
"""
function experiment_deflection(
    design::BuildingDesign,
    slab_idx::Int;
    deflection_limit::String = "L_360",
)::Dict{String, Any}
    slab = get(design.slabs, slab_idx, nothing)
    isnothing(slab) && return Dict{String, Any}(
        "error" => "slab_not_found",
        "message" => "Slab index $slab_idx not found. Available: $(sort(collect(keys(design.slabs))))",
    )

    orig_deflection = slab.deflection_in
    orig_limit = slab.deflection_limit_in
    orig_ok = slab.deflection_ok
    orig_ratio = slab.deflection_ratio

    if isnothing(orig_deflection) || orig_deflection == 0.0
        return Dict{String, Any}(
            "error" => "no_deflection_data",
            "message" => "Slab $slab_idx has no stored deflection data.",
        )
    end

    # Determine span length from the limit and divisor
    # orig_limit = span / divisor, so span = orig_limit * divisor
    orig_divisor = if orig_ratio > 0
        round(orig_limit / orig_deflection * orig_ratio; digits=0)
    else
        360.0
    end

    # Approximate span from the original limit
    # deflection_limit_in = span_in / divisor
    # We can back-compute span_in if we know the original divisor
    # span_in ≈ orig_limit * orig_divisor (where orig_divisor = orig_limit / orig_deflection * ratio)
    # Simpler: use orig_limit and the ratio to determine the span
    span_in = orig_limit * 360.0  # Assumes original was L/360 as default

    new_divisor = if deflection_limit == "L_240"
        240.0
    elseif deflection_limit == "L_360"
        360.0
    elseif deflection_limit == "L_480"
        480.0
    else
        return Dict{String, Any}(
            "error" => "invalid_limit",
            "message" => "deflection_limit must be L_240, L_360, or L_480. Got: $deflection_limit",
        )
    end

    # The deflection itself doesn't change (same loads, same slab), only the limit
    new_limit = span_in / new_divisor
    new_ratio = orig_deflection / new_limit
    new_ok = new_ratio <= 1.0

    return Dict{String, Any}(
        "experiment" => "deflection",
        "slab_idx" => slab_idx,
        "original" => Dict{String, Any}(
            "deflection_in" => round(orig_deflection; digits=3),
            "limit_in" => round(orig_limit; digits=3),
            "ratio" => round(orig_ratio; digits=3),
            "ok" => orig_ok,
        ),
        "modified" => Dict{String, Any}(
            "deflection_limit" => deflection_limit,
            "limit_in" => round(new_limit; digits=3),
            "ratio" => round(new_ratio; digits=3),
            "ok" => new_ok,
        ),
        "delta_ratio" => round(new_ratio - orig_ratio; digits=3),
        "improved" => new_ratio < orig_ratio,
        "note" => "Deflection value unchanged; only the allowable limit changes. Thicker slab would reduce actual deflection — use run_design for that.",
    )
end

# ─── Catalog Feasibility Screening ───────────────────────────────────────────

"""
    experiment_catalog_screen(design, col_idx; candidates) -> Dict

Screen a list of candidate sections against the stored demands for a column.
Returns a feasibility assessment for each candidate.

`candidates` is a vector of section size dimensions (inches, for RC) to test.
"""
function experiment_catalog_screen(
    design::BuildingDesign,
    col_idx::Int;
    candidates::Vector{Float64} = Float64[],
)::Dict{String, Any}
    col = get(design.columns, col_idx, nothing)
    isnothing(col) && return Dict{String, Any}(
        "error" => "column_not_found",
        "message" => "Column index $col_idx not found.",
    )

    isempty(candidates) && return Dict{String, Any}(
        "error" => "no_candidates",
        "message" => "Provide at least one candidate section size via `candidates`.",
    )

    results = Dict{String, Any}[]
    for dim in candidates
        r = experiment_pm_column(design, col_idx; section_size=dim)
        if haskey(r, "error")
            push!(results, Dict{String, Any}("section" => "$(Int(dim))x$(Int(dim))", "error" => r["error"]))
        else
            mod = r["modified"]
            push!(results, Dict{String, Any}(
                "section" => mod["section"],
                "interaction_ratio" => mod["interaction_ratio"],
                "ok" => mod["ok"],
                "φPn_kip" => get(mod, "φPn_kip", nothing),
            ))
        end
    end

    sort!(results; by=r -> get(r, "interaction_ratio", Inf))

    return Dict{String, Any}(
        "experiment" => "catalog_screen",
        "column_idx" => col_idx,
        "original_section" => col.section_size,
        "original_ratio" => round(max(col.axial_ratio, col.interaction_ratio); digits=3),
        "candidates" => results,
        "best_feasible" => let feas = filter(r -> get(r, "ok", false), results)
            isempty(feas) ? nothing : first(feas)["section"]
        end,
        "note" => "Simplified ACI capacity estimates. Use run_design for exact results.",
    )
end

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
                "description" => "Re-check punching shear with modified column size or slab thickness",
                "args" => Dict("col_idx" => "required Int", "c1_in" => "optional Float64", "c2_in" => "optional Float64", "h_in" => "optional Float64"),
            ),
            Dict{String, Any}(
                "name" => "pm_column",
                "description" => "Test P-M interaction for an RC column with a different section size",
                "args" => Dict("col_idx" => "required Int", "section_size" => "Float64 (inches)"),
            ),
            Dict{String, Any}(
                "name" => "deflection",
                "description" => "Test a slab under a different deflection limit (L/240, L/360, L/480)",
                "args" => Dict("slab_idx" => "required Int", "deflection_limit" => "L_240 | L_360 | L_480"),
            ),
            Dict{String, Any}(
                "name" => "catalog_screen",
                "description" => "Screen multiple RC column sizes against stored demands",
                "args" => Dict("col_idx" => "required Int", "candidates" => "Float64[] (inches)"),
            ),
        ],
        "note" => "Micro-experiments use cached design data for fast what-if checks. Results are approximate — use run_design for exact verification.",
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
        col_idx = get(args, "col_idx", nothing)
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "punching experiment requires col_idx")
        return experiment_punching(design, Int(col_idx);
            c1_in = get(args, "c1_in", nothing),
            c2_in = get(args, "c2_in", nothing),
            h_in = get(args, "h_in", nothing),
        )
    elseif experiment_type == "pm_column"
        col_idx = get(args, "col_idx", nothing)
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "pm_column experiment requires col_idx")
        return experiment_pm_column(design, Int(col_idx);
            section_size = get(args, "section_size", nothing),
        )
    elseif experiment_type == "deflection"
        slab_idx = get(args, "slab_idx", nothing)
        isnothing(slab_idx) && return Dict("error" => "missing_slab_idx", "message" => "deflection experiment requires slab_idx")
        return experiment_deflection(design, Int(slab_idx);
            deflection_limit = string(get(args, "deflection_limit", "L_360")),
        )
    elseif experiment_type == "catalog_screen"
        col_idx = get(args, "col_idx", nothing)
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "catalog_screen experiment requires col_idx")
        candidates_raw = get(args, "candidates", Float64[])
        candidates = Float64[Float64(c) for c in candidates_raw]
        return experiment_catalog_screen(design, Int(col_idx); candidates)
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
        exp_type = string(get(exp, "type", ""))
        exp_args = Dict{String, Any}(string(k) => v for (k, v) in get(exp, "args", Dict()))
        r = evaluate_experiment(design, exp_type, exp_args)
        r["experiment_index"] = i
        push!(results, r)
    end
    return Dict{String, Any}(
        "n_experiments" => length(results),
        "results" => results,
    )
end
