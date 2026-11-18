# ─── Constraint layer ─────────────────────────────────────────────────────────

"""
Build the constraint layer: categorize design variables into fixed-by-geometry
(spans, heights), mutable API parameters, and analytical lever impact estimates.
"""
function _diagnose_constraints(
    design::BuildingDesign,
    struc::BuildingStructure,
    params::DesignParameters,
    du::DisplayUnits,
    col_dicts::Vector,
    beam_dicts::Vector,
    slab_dicts::Vector,
    fdn_dicts::Vector,
)
    lunit = _length_unit_string(du)
    thick_unit = _thickness_unit_string(du)

    # ── Fixed by geometry ─────────────────────────────────────────────
    # Collect unique span ranges from slab panels
    l1_vals = filter(>(0.0), [get(d, "l1", 0.0) for d in slab_dicts])
    l2_vals = filter(>(0.0), [get(d, "l2", 0.0) for d in slab_dicts])
    col_heights = filter(>(0.0), [get(d, "height", 0.0) for d in col_dicts])

    fixed_by_geometry = Dict{String, Any}(
        "note"   => "These values are set by the input geometry and cannot be changed " *
                    "without modifying the building layout.",
        "spans_l1" => isempty(l1_vals) ? nothing : Dict(
            "min" => _round_val(minimum(l1_vals)), "max" => _round_val(maximum(l1_vals)),
            "unit" => lunit,
        ),
        "spans_l2" => isempty(l2_vals) ? nothing : Dict(
            "min" => _round_val(minimum(l2_vals)), "max" => _round_val(maximum(l2_vals)),
            "unit" => lunit,
        ),
        "story_heights" => isempty(col_heights) ? nothing : Dict(
            "min" => _round_val(minimum(col_heights)), "max" => _round_val(maximum(col_heights)),
            "unit" => lunit,
        ),
    )

    # ── Analytical lever impact estimates ─────────────────────────────
    lever_impacts = _diagnose_lever_impacts(design, params, du, col_dicts, slab_dicts)

    return Dict{String, Any}(
        "fixed_by_geometry" => fixed_by_geometry,
        "lever_impacts"     => lever_impacts,
    )
end

"""
Compute analytical and estimated lever impact estimates for available
parameter alternatives. Only parameters where a closed-form estimate
is possible without a rerun are included.
"""
function _diagnose_lever_impacts(
    design::BuildingDesign,
    params::DesignParameters,
    du::DisplayUnits,
    col_dicts::Vector,
    slab_dicts::Vector,
)
    impacts = Dict{String, Any}[]

    # ── Deflection limit alternatives (analytical) ────────────────────
    # New ratio = old_ratio × (new_divisor / current_divisor).
    # Exact because: ratio = Δ_actual / (l / d), and Δ_actual does not change.
    if !isempty(slab_dicts)
        d_curr = _deflection_limit_divisor(params)
        defl_ratios = [
            maximum(
                get(chk, "ratio", 0.0)
                for chk in get(d, "checks", []) if get(chk, "name", "") == "deflection";
                init=0.0,
            )
            for d in slab_dicts
        ]
        worst_defl = isempty(defl_ratios) ? 0.0 : maximum(defl_ratios)

        for d_alt in (240, 360, 480)
            d_alt == d_curr && continue
            new_worst = worst_defl * d_alt / d_curr
            push!(impacts, Dict{String, Any}(
                "parameter"         => "deflection_limit",
                "current_value"     => "L_$d_curr",
                "alternative_value" => "L_$d_alt",
                "direction"         => d_alt < d_curr ? "relaxed" : "tighter",
                "worst_slab_deflection_ratio_current" => _round_val(worst_defl),
                "worst_slab_deflection_ratio_estimated" => _round_val(new_worst),
                "delta"             => _round_val(new_worst - worst_defl),
                "confidence"        => "analytical",
                "basis"             => "ratio = Δ/(L/d) = Δ·d/L, so ratio ∝ divisor: " *
                                       "new_ratio = old_ratio × ($d_alt / $d_curr). " *
                                       "The actual slab deflection Δ is unchanged; only the allowable changes. " *
                                       "Thickness changes require a rerun.",
                "affected_element_type" => "slabs",
                "n_affected"        => length(slab_dicts),
            ))
        end
    end

    # ── Punching strategy: grow_columns → reinforce_first (estimated) ──
    # If punching governs some columns, reinforce_first decouples punching
    # from column size by adding shear studs. The column is then sized for
    # P-M interaction only. Estimated new ratio = max(axial, interaction).
    ps = _punching_strategy_code(params)
    if !isnothing(ps) && ps != "reinforce_first" && !isempty(col_dicts)
        punching_cols = filter(d -> get(d, "governing_check", "") == "punching_shear_col", col_dicts)
        if !isempty(punching_cols)
            # Use `_serialized_ratio` so a column whose axial/interaction ratio serialized to
            # `nothing` (unverified §E3/§E4 buckling capacity) contributes a failing sentinel
            # (≥ 1.0) rather than throwing under `max` or being read as zero utilization.
            pm_ratios = [
                max(_serialized_ratio(d, "axial_ratio"), _serialized_ratio(d, "interaction_ratio"))
                for d in punching_cols
            ]
            push!(impacts, Dict{String, Any}(
                "parameter"         => "punching_strategy",
                "current_value"     => ps,
                "alternative_value" => "reinforce_first",
                "direction"         => "relaxed_column_size",
                "n_punching_governed_columns" => length(punching_cols),
                "worst_punching_ratio_current" =>
                    _round_val(maximum(something(get(d, "governing_ratio", 0.0), 0.0) for d in punching_cols)),
                "estimated_new_governing_ratio" => _round_val(maximum(pm_ratios)),
                "confidence"        => "estimated",
                "basis"             => "Under reinforce_first, shear studs handle the punching demand; " *
                                       "columns are then sized for P-M interaction only. " *
                                       "Estimated new ratio = max(axial_ratio, interaction_ratio) for each " *
                                       "punching-governed column. Actual catalog selection requires a rerun.",
                "affected_element_type" => "columns",
            ))
        end
    end

    return impacts
end

