"""
Build a Dict representing one foundation's full diagnostic data.
"""
function _diagnose_foundation(
    idx::Int,
    fr::FoundationDesignResult,
    du::DisplayUnits,
)
    funit = _force_unit_str(du)
    lunit = _length_unit_string(du)
    thick_unit = _thickness_unit_string(du)

    governing = _fdn_governing_check(fr)
    max_ratio = max(fr.governing_ratio, maximum(last, foundation_check_ratios(fr)))
    if !fr.ok && max_ratio < 1.0
        max_ratio = 1.0
    end

    L_disp     = _to_display_length(du, fr.length)
    W_disp     = _to_display_length(du, fr.width)
    D_disp     = _to_display(du, :thickness, fr.depth)
    react_disp = _to_display(du, :force, fr.reaction)

    # AUDIT (P0-B): spread footings are reinforced concrete. Soil bearing is a
    # geotechnical/allowable-stress check governed by IBC 2021 Table 1806.2 (NOT a
    # concrete member strength — and IBC is absent from the corpus, so it grounds
    # UNRESOLVED rather than mis-cited). The two structural footing checks are
    # concrete: two-way punching (ACI 318-19 §22.6.5) and flexure (§15.4). Every
    # emitted clause is the same code family that produced its ratio.
    checks = Dict{String, Any}[
        Dict{String, Any}(
            "name"        => "bearing",
            "code_clause" => "IBC 2021 Table 1806.2",
            "demand"      => _round_val(react_disp),
            "demand_unit" => funit,
            "ratio"       => _round_val(fr.bearing_ratio),
            "headroom"    => _round_val(1.0 - fr.bearing_ratio),
            "governing"   => governing == "bearing",
        ),
        Dict{String, Any}(
            "name"        => "punching_shear_fdn",
            "code_clause" => "ACI 318-19 §22.6.5",
            "ratio"       => _round_val(fr.punching_ratio),
            "headroom"    => _round_val(1.0 - fr.punching_ratio),
            "governing"   => governing == "punching_shear_fdn",
        ),
        Dict{String, Any}(
            "name"        => "one_way_shear_fdn",
            "code_clause" => "ACI 318-19 §22.5",
            "ratio"       => _round_val(fr.one_way_shear_ratio),
            "headroom"    => _round_val(1.0 - fr.one_way_shear_ratio),
            "governing"   => governing == "one_way_shear_fdn",
        ),
        Dict{String, Any}(
            "name"        => "flexure_fdn",
            "code_clause" => "ACI 318-19 §15.4",
            "ratio"       => _round_val(fr.flexure_ratio),
            "headroom"    => _round_val(1.0 - fr.flexure_ratio),
            "governing"   => governing == "flexure_fdn",
        ),
    ]

    # Attach live corpus citations (explanation-layer only; ratios untouched).
    _ground_checks!(checks)

    return Dict{String, Any}(
        "id"             => idx,
        "length"         => _round_val(L_disp),
        "width"          => _round_val(W_disp),
        "depth"          => _round_val(D_disp),
        "length_unit"    => lunit,
        "depth_unit"     => thick_unit,
        "reaction"       => _round_val(react_disp),
        "force_unit"     => funit,
        "group_id"       => fr.group_id,
        "governing_check" => governing,
        "governing_ratio" => _round_val(max_ratio),
        "governing_mode"  => _governing_mode(max_ratio),
        "ok"             => fr.ok,
        "checks"         => checks,
        "levers"         => get(LEVER_MAP, governing, String[]),
        "limit_state_description" => get(LIMIT_STATE_DESCRIPTIONS, governing, ""),
    )
end

function _diagnose_foundations(design::BuildingDesign, du::DisplayUnits)
    isempty(design.foundations) && return Dict{String, Any}[]
    [_diagnose_foundation(idx, design.foundations[idx], du)
     for idx in _sorted_indices(design.foundations)]
end

