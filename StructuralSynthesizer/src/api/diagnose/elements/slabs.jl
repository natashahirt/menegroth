"""
Build a Dict representing one slab panel's full diagnostic data.
"""
function _diagnose_slab(
    idx::Int,
    sr::SlabDesignResult,
    slab_obj::Slab,
    struc::BuildingStructure,
    du::DisplayUnits,
)
    punit = _pressure_unit_str(du)
    munit = _moment_unit_str(du)

    governing = _slab_governing_check(sr)
    base_ratio = max(sr.deflection_ratio, sr.punching_max_ratio)
    reinf_or_conv_fail = governing in (
        "reinforcement_design",
        "reinforcement_design_secondary",
        "transfer_reinforcement",
        "non_convergence",
    )
    max_ratio = reinf_or_conv_fail ? max(base_ratio, 1.0) : base_ratio

    h_disp = _to_display(du, :thickness, sr.thickness)
    defl_disp       = _to_display(du, :deflection, sr.deflection_in * u"inch")
    defl_limit_disp = _to_display(du, :deflection, sr.deflection_limit_in * u"inch")
    punch_stress_disp = _to_display(du, :stress, sr.punching_vu_max_psi * u"psi")
    (l1_disp, l2_disp) = _slab_spans_display(slab_obj, du)

    m0_disp = if !isnothing(sr.M0)
        _to_display(du, :moment, sr.M0)
    else
        0.0
    end
    qu_disp = if !isnothing(sr.qu)
        _to_display(du, :pressure, sr.qu)
    else
        0.0
    end

    gov_defl = governing == "deflection"
    gov_punch = governing == "punching_shear_slab"

    # AUDIT (P0-B): slabs are reinforced-concrete two-way members sized entirely
    # by the ACI two-way pipeline, so both checks are computed under ACI 318-19 —
    # deflection (§24.2) and two-way punching (§22.6). The emitted clauses are the
    # same code family (concrete) as the ratios; no material branch is needed.
    checks = Dict{String, Any}[
        Dict{String, Any}(
            "name"          => "deflection",
            "code_clause"   => "ACI 318-19 §24.2",
            "demand"        => _round_val(defl_disp),
            "capacity"      => _round_val(defl_limit_disp),
            "deflection_unit" => _thickness_unit_string(du),
            "ratio"         => _round_val(sr.deflection_ratio),
            "headroom"      => _round_val(1.0 - sr.deflection_ratio),
            "governing"     => gov_defl,
        ),
        Dict{String, Any}(
            "name"          => "punching_shear_slab",
            "code_clause"   => "ACI 318-19 §22.6",
            "demand_vu"     => _round_val(punch_stress_disp),
            "demand_unit"   => _is_imperial(du) ? "ksi" : "MPa",
            "ratio"         => _round_val(sr.punching_max_ratio),
            "headroom"      => _round_val(1.0 - sr.punching_max_ratio),
            "governing"     => gov_punch,
            "has_studs"     => sr.has_studs,
        ),
    ]

    # Attach live corpus citations (explanation-layer only; ratios untouched).
    _ground_checks!(checks)

    # Reinforcement summary — expose bar sizes, spacings, and provided/required ratios
    rebar_summary = _slab_rebar_summary(sr, du)

    d = Dict{String, Any}(
        "id"             => idx,
        "floor_type"     => string(slab_obj.floor_type),
        "position"       => string(slab_obj.position),
        "thickness"      => _round_val(h_disp),
        "thickness_unit" => _thickness_unit_string(du),
        "l1"             => _round_val(l1_disp),
        "l2"             => _round_val(l2_disp),
        "span_unit"      => _length_unit_string(du),
        "M0"             => _round_val(m0_disp),
        "moment_unit"    => munit,
        "qu"             => _round_val(qu_disp),
        "pressure_unit"  => punit,
        "deflection"     => _round_val(defl_disp),
        "deflection_limit" => _round_val(defl_limit_disp),
        "deflection_unit" => _thickness_unit_string(du),
        "failure_reason"  => _normalize_failure_reason(sr.failure_reason),
        "governing_check" => governing,
        "governing_ratio" => _round_val(max_ratio),
        "governing_mode"  => _governing_mode(max_ratio),
        "ok"             => _slab_design_ok(sr),
        "checks"         => checks,
        "levers"         => get(LEVER_MAP, governing, String[]),
        "limit_state_description" => get(LIMIT_STATE_DESCRIPTIONS, governing, ""),
        "ec_kgco2e"      => _round_or_nothing(_slab_ec_kgco2e(struc, idx); digits=1),
    )
    !isempty(rebar_summary) && (d["reinforcement"] = rebar_summary)
    return d
end

"""
Summarize slab strip reinforcement: bar size, spacing, provided/required ratio.
Returns a Dict with column_strip and middle_strip sub-dicts keyed by location.
"""
function _slab_rebar_summary(sr::SlabDesignResult, du::DisplayUnits)::Dict{String, Any}
    out = Dict{String, Any}()
    for (strip_name, strip_data) in [("column_strip", sr.column_strip), ("middle_strip", sr.middle_strip)]
        isempty(strip_data) && continue
        strip_out = Dict{String, Any}()
        for (loc, rd) in strip_data
            as_req = ustrip(u"mm^2", rd.As_required)
            as_prov = ustrip(u"mm^2", rd.As_provided)
            prov_req = as_req > 0 ? round(as_prov / as_req; digits=2) : nothing
            spacing_disp = _to_display(du, :thickness, rd.spacing)
            strip_out[string(loc)] = Dict{String, Any}(
                "bar_size"       => rd.bar_size,
                "spacing"        => _round_val(spacing_disp),
                "spacing_unit"   => _thickness_unit_string(du),
                "n_bars"         => rd.n_bars,
                "As_provided_over_required" => _round_val(prov_req),
            )
        end
        out[strip_name] = strip_out
    end
    return out
end

function _diagnose_slabs(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    isempty(design.slabs) && return Dict{String, Any}[]
    [_diagnose_slab(idx, design.slabs[idx], struc.slabs[idx], struc, du)
     for idx in _sorted_indices(design.slabs)]
end

