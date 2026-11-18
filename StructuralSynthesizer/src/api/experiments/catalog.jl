# ─── Catalog Feasibility Screening ───────────────────────────────────────────

"""
    experiment_catalog_screen(design, col_idx; candidates) -> Dict

Screen a list of candidate sections against the stored demands for a column.
Returns a feasibility assessment for each candidate using the real checkers.

For RC columns, `candidates` is a vector of section dimensions (inches).
For steel columns, `candidates` is a vector of W-shape designation strings.
"""
function experiment_catalog_screen(
    design::BuildingDesign,
    col_idx::Int;
    candidates::Union{Vector{Float64}, Vector} = Float64[],
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

    # Comparison-safe baseline; keep the displayed original ratio null when unverified
    # (a raw `round(NaN)` would otherwise leak an invalid `NaN` JSON token). See
    # `_column_orig_ratio`. Per-candidate `improved` flags come from `experiment_pm_column`,
    # which applies the same guard.
    orig_ratio, orig_unverified = _column_orig_ratio(col)
    is_rc = col.shape in (:rectangular, :circular, :rc_rect, :rc_circular)

    results = Dict{String, Any}[]
    for cand in candidates
        r = experiment_pm_column(design, col_idx; section_size=cand)
        if haskey(r, "error")
            push!(results, Dict{String, Any}("section" => string(cand), "error" => r["error"]))
        else
            mod = r["modified"]
            entry = Dict{String, Any}(
                "section" => mod["section"],
                "interaction_ratio" => mod["interaction_ratio"],
                "governing_check" => get(mod, "governing_check", ""),
                "ok" => mod["ok"],
                "improved" => get(r, "improved", false),
            )
            if haskey(mod, "weight_plf") && !isnothing(mod["weight_plf"])
                entry["weight_plf"] = mod["weight_plf"]
            end
            if haskey(mod, "rebar")
                entry["rebar"] = mod["rebar"]
            end
            push!(results, entry)
        end
    end

    # An UNVERIFIABLE candidate (its own AISC 360-16 §E3/§E4 buckling capacity unavailable —
    # `experiment_pm_column` sets `new_ratio = expl.governing_ratio = NaN`, which
    # `_json_safe(round(NaN)) → nothing`) carries `interaction_ratio == nothing`; an ERRORED
    # candidate has no `interaction_ratio` key at all. This is exactly reachable when screening
    # replacement sections for an unverified steel column whose alternates also cannot be
    # verified. A bare `get(r, "interaction_ratio", Inf)` returns that `nothing`, and
    # `sort!` would then call `isless(::Nothing, ::Float64)` → `MethodError`, crashing the
    # catalog screen. Coerce any non-`Real` ratio to `Inf` so unverifiable/errored candidates
    # sort to the BOTTOM (worst) and are never ranked "best feasible".
    _cand_sort_key(r) = (v = get(r, "interaction_ratio", Inf); v isa Real ? Float64(v) : Inf)
    sort!(results; by=_cand_sort_key)

    feasible = filter(r -> get(r, "ok", false), results)

    # For steel, identify lightest feasible by weight
    lightest_feasible = nothing
    if !isempty(feasible) && !is_rc
        with_weight = filter(r -> haskey(r, "weight_plf"), feasible)
        if !isempty(with_weight)
            lightest_feasible = sort(with_weight; by=r -> r["weight_plf"])[1]["section"]
        end
    end

    Pu_kip_val = round(ustrip(u"kip", col.Pu); digits=1)
    Mux_kipft_val = round(ustrip(u"kip*ft", col.Mu_x); digits=1)
    Muy_kipft_val = round(ustrip(u"kip*ft", col.Mu_y); digits=1)
    cand_strs = [string(c) for c in candidates]

    setup = _experimental_setup(;
        changed = ["section — screening $(length(candidates)) candidates: $(join(cand_strs[1:min(end, 5)], ", "))$(length(cand_strs) > 5 ? "…" : "")"],
        held_constant = ["Pu = $(Pu_kip_val) kip", "Mux = $(Mux_kipft_val) kip·ft",
                         "Muy = $(Muy_kipft_val) kip·ft", "height, K-factors, material properties"],
        source = "Cached design — column $col_idx",
    )

    _best_sec = isempty(feasible) ? "none" : first(feasible)["section"]
    _best_rat = isempty(feasible) ? "" : " (ratio=$(first(feasible)["interaction_ratio"]))"

    return Dict{String, Any}(
        "experiment" => "catalog_screen",
        "result_summary" => "$(length(feasible))/$(length(results)) candidates pass. " *
            "Best feasible: $(_best_sec)$(_best_rat). " *
            (isnothing(lightest_feasible) ? "" : "Lightest feasible: $(lightest_feasible)."),
        "experimental_setup" => setup,
        "column_idx" => col_idx,
        "column_type" => is_rc ? "RC" : "steel",
        "demands" => Dict{String, Any}(
            "Pu_kip" => Pu_kip_val,
            "Mux_kipft" => Mux_kipft_val,
            "Muy_kipft" => Muy_kipft_val,
        ),
        "original" => Dict{String, Any}(
            "section" => col.section_size,
            "ratio" => orig_unverified ? nothing : round(orig_ratio; digits=3),
            "unverified" => orig_unverified,
            "ok" => col.ok,
            "governing_check" => column_diagnostic_governing_check(col),
        ),
        "n_candidates" => length(results),
        "n_feasible" => length(feasible),
        "candidates" => results,
        "best_feasible" => isempty(feasible) ? nothing : first(feasible)["section"],
        "lightest_feasible" => lightest_feasible,
        "note" => isempty(feasible) ?
            "No candidate section passes all checks. Consider larger sections or reviewing demands." :
            "$(length(feasible))/$(length(results)) candidates pass. Best ratio: $(first(feasible)["interaction_ratio"]).",
    )
end

