"""
Build goal-ranked recommendations for the three most common design goals.
Each entry is actionable: it names the parameter and estimates the impact.
"""
function _build_goal_recommendations(
    design::BuildingDesign,
    params::DesignParameters,
    du::DisplayUnits,
    col_dicts::Vector,
    beam_dicts::Vector,
    slab_dicts::Vector,
    fdn_dicts::Vector,
)
    recs = Dict{String, Any}[]

    # ── Goal: reduce_column_size ──────────────────────────────────────
    if !isempty(col_dicts)
        worst_col = col_dicts[argmax(something(get(d, "governing_ratio", 0.0), 0.0) for d in col_dicts)]
        gc = get(worst_col, "governing_check", "")
        if gc == "punching_shear_col"
            ps = _punching_strategy_code(params)
            if !isnothing(ps) && ps != "reinforce_first"
                # `axial_ratio`/`interaction_ratio` serialize to `nothing` for an unverified
                # column; `_serialized_ratio` maps that to a failing sentinel (≥ 1.0) so the
                # `max` never runs arithmetic on `nothing` and never reads unverified as safe.
                pm_ratio = max(
                    _serialized_ratio(worst_col, "axial_ratio"),
                    _serialized_ratio(worst_col, "interaction_ratio"),
                )
                push!(recs, Dict{String, Any}(
                    "goal"             => "reduce_column_size",
                    "primary_lever"    => "punching_strategy",
                    "suggested_value"  => "reinforce_first",
                    "current_ratio"    => get(worst_col, "governing_ratio", 0.0),
                    "estimated_new_ratio" => _round_val(pm_ratio),
                    "confidence"       => "estimated",
                    "rationale"        => "Punching governs the critical column. " *
                                         "reinforce_first adds shear studs instead of growing the column, " *
                                         "so columns are sized for P-M only. Requires a rerun for exact size.",
                ))
            end
        elseif gc in ("pm_interaction", "axial_compression", "column_shear")
            why = gc == "column_shear" ?
                "One-way shear governs. Ties are sized by ACI 318-19 §22.5; past the " *
                "section limit, a larger section or a higher f'c is the lever. A rerun is needed." :
                "P-M interaction governs. Higher concrete strength or a larger catalog " *
                "section is the direct lever. A rerun is needed for exact results."
            push!(recs, Dict{String, Any}(
                "goal"             => "reduce_column_size",
                "primary_lever"    => "fc_column",
                "suggested_value"  => "higher f'c or stronger catalog",
                "current_ratio"    => get(worst_col, "governing_ratio", 0.0),
                "estimated_new_ratio" => nothing,
                "confidence"       => "requires_rerun",
                "rationale"        => why,
            ))
        end
    end

    # ── Goal: reduce_slab_thickness ──────────────────────────────────
    if !isempty(slab_dicts)
        worst_slab = slab_dicts[argmax(something(get(d, "governing_ratio", 0.0), 0.0) for d in slab_dicts)]
        if get(worst_slab, "governing_check", "") == "deflection"
            d_curr = _deflection_limit_divisor(params)
            if d_curr > 240
                new_ratio = _round_val(something(get(worst_slab, "governing_ratio", 0.0), 0.0) * 240 / d_curr)
                push!(recs, Dict{String, Any}(
                    "goal"             => "reduce_slab_thickness",
                    "primary_lever"    => "deflection_limit",
                    "suggested_value"  => "L_240",
                    "current_ratio"    => get(worst_slab, "governing_ratio", 0.0),
                    "estimated_new_ratio" => new_ratio,
                    "confidence"       => "analytical",
                    "rationale"        => "Deflection governs the critical slab. Relaxing to L/240 from L/$(d_curr) " *
                                        "increases the allowable deflection by a factor of $(round(d_curr / 240; digits=2))×. " *
                                        "The ratio scales exactly: new_ratio = old × 240 / $d_curr = old × $(round(240 / d_curr; digits=3)). " *
                                        "Actual thickness reduction requires a rerun.",
                ))
            end
        end
    end

    # ── Goal: reduce_embodied_carbon ──────────────────────────────────
    # Slabs are the dominant EC contributor in typical flat-plate buildings
    # (≈ 60–75% of structural EC). Deflection limit directly governs slab thickness.
    if !isempty(slab_dicts)
        defl_governed = filter(d -> get(d, "governing_check", "") == "deflection", slab_dicts)
        d_curr = _deflection_limit_divisor(params)
        if !isempty(defl_governed) && d_curr > 240
            total_slab_ec = sum(get(d, "ec_kgco2e", 0.0) for d in slab_dicts)
            push!(recs, Dict{String, Any}(
                "goal"             => "reduce_embodied_carbon",
                "primary_lever"    => "deflection_limit",
                "suggested_value"  => "L_240",
                "note"             => "Slabs typically account for 60–75% of structural embodied carbon. " *
                                     "Relaxing the deflection limit (L/240 vs L/$d_curr) enables thinner slabs. " *
                                     "Current slab EC contribution: $(round(total_slab_ec; digits=0)) kgCO₂e. " *
                                     "A rerun is needed for the exact carbon reduction.",
                "confidence"       => "estimated",
                "rationale"        => "Slab volume is proportional to thickness; EC scales with volume. " *
                                     "For deflection-governed slabs, thickness tracks the limit directly.",
            ))
        end
    end

    return recs
end

