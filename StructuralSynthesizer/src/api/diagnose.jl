# =============================================================================
# Diagnose — high-resolution, machine-readable diagnostic endpoint
#
# GET /diagnose returns a layered JSON report that exposes the causal logic
# behind every sizing decision, designed for LLM agent consumption.
#
# Architecture: three layers in one response
#   1. Engineering layer — per-element checks with demand/capacity pairs,
#      governing_check, code clause, headroom, and lever parameters.
#   2. Architectural layer — goal-ranked recommendations and system narrative.
#   3. Constraint layer — fixed-by-geometry vs. mutable parameters, and
#      analytical lever-impact estimates for available alternatives.
# =============================================================================

# ─── Static Lookups ──────────────────────────────────────────────────────────

"""
Map each governing limit-state check to the API parameters that most directly
address it. Used by `_diagnose_column`, etc. to populate per-element `levers`.
"""
const LEVER_MAP = Dict{String, Vector{String}}(
    "axial_compression"   => ["column_catalog", "fc_column"],
    "pm_interaction"      => ["column_catalog", "fc_column"],
    "punching_shear_col"  => ["punching_strategy", "column_catalog"],
    "flexure"             => ["beam_catalog", "fc_beam"],
    "shear"               => ["beam_catalog"],
    "deflection"          => ["deflection_limit", "fc_slab"],
    "punching_shear_slab" => ["column_catalog", "punching_strategy"],
    "reinforcement_design" => ["fc_slab", "deflection_limit"],
    "reinforcement_design_secondary" => ["fc_slab", "deflection_limit"],
    "transfer_reinforcement" => ["fc_slab", "column_catalog"],
    "non_convergence"     => ["max_iterations", "fc_slab"],
    "bearing"             => ["bearing_capacity"],
    "punching_shear_fdn"  => ["bearing_capacity"],
    "flexure_fdn"         => ["bearing_capacity"],
)

"""
Plain-English descriptions of each limit state for non-technical users.
Code clause annotations cite ACI 318-19 and AISC 360-22.
"""
const LIMIT_STATE_DESCRIPTIONS = Dict{String, String}(
    "axial_compression" =>
        "The column is carrying load near its maximum axial capacity. " *
        "ACI 318-19 §22.4.2: Pn = 0.85·f'c·(Ag – As) + fy·As. " *
        "A larger section or higher-strength concrete raises this ceiling.",

    "pm_interaction" =>
        "The column is under simultaneous axial compression and bending — " *
        "moment from unequal spans or slab rotations. ACI 318-19 §22.4. " *
        "The P-M interaction surface shrinks under combined loading; " *
        "a larger section or higher concrete grade expands it.",

    "punching_shear_col" =>
        "The slab is on the verge of punching through around the column, " *
        "like a cookie-cutter through dough. ACI 318-19 §22.6. " *
        "The critical shear perimeter (bo = 4·(c + d)) at distance d/2 from " *
        "the column face is too small for the transmitted force. " *
        "Bigger columns, shear studs, or drop panels fix this.",

    "flexure" =>
        "The beam cannot resist the bending moment at this demand level. " *
        "AISC 360-22 Chapter F (steel) or ACI 318-19 §9.5 (RC). " *
        "A deeper or heavier section is needed.",

    "shear" =>
        "The beam is failing to transfer transverse (vertical) load. " *
        "AISC 360-22 Chapter G (steel) or ACI 318-19 §22.5 (RC). " *
        "Typically paired with high flexure in heavily loaded spans.",

    "deflection" =>
        "The slab deflects more than the code allows relative to its span. " *
        "ACI 318-19 §24.2: L/360 for floors with attached partitions (default), " *
        "L/240 for floors without damage-sensitive attachments, L/480 for sensitive finishes. " *
        "Thickness, concrete grade, and the chosen deflection limit all affect this. " *
        "L/240 allows 50% more deflection than L/360; L/480 allows 25% less (ratio increases by 33%).",

    "punching_shear_slab" =>
        "This is the slab-level punching check at a column location. " *
        "ACI 318-19 §22.6. A larger column increases the critical perimeter, " *
        "directly reducing the punching stress demand.",

    "reinforcement_design" =>
        "The slab thickness and effective depth are insufficient to provide the required " *
        "flexural reinforcement in a column strip or middle strip (Whitney block / strain compatibility). " *
        "ACI 318-19 Ch. 8–9. Increase slab thickness or concrete strength, or reduce span / load.",

    "reinforcement_design_secondary" =>
        "Same as primary-direction flexural adequacy but in the orthogonal strip direction. " *
        "ACI 318-19 Ch. 8–9. Often resolved by increasing thickness or fc′.",

    "transfer_reinforcement" =>
        "Moment transfer reinforcement at a column (ACI 318-19 §8.4.2.3) cannot fit within " *
        "the available depth — the section is inadequate for unbalanced moment. " *
        "Thicker slab, larger column, or revised geometry at that connection.",

    "non_convergence" =>
        "The slab design loop did not reach a consistent solution (iterations exhausted or " *
        "intermediate failure). Try max_iterations, fc_slab, or relieving span/load in Grasshopper.",

    "bearing" =>
        "The footing is pressing on the soil harder than the allowable bearing capacity. " *
        "IBC 2021 Table 1806.2. A larger footing spreads the column reaction " *
        "over more area, reducing the contact pressure.",

    "punching_shear_fdn" =>
        "The column is punching through the footing. ACI 318-19 §22.6.5. " *
        "Increasing the footing depth (d) or plan size resolves this.",

    "flexure_fdn" =>
        "The footing is bending excessively under the column reaction. " *
        "ACI 318-19 §15.4. A thicker or wider footing increases the moment capacity.",
)

const _FLOOR_NAMES = Dict{String, String}(
    "flat_plate" => "flat-plate slab (no beams or drop panels)",
    "flat_slab"  => "flat slab with drop panels",
    "one_way"    => "one-way slab-and-beam system",
    "vault"      => "vault shell",
)

const _COLUMN_NAMES = Dict{String, String}(
    "rc_rect"     => "rectangular reinforced-concrete column",
    "rc_circular" => "circular reinforced-concrete column",
    "steel_w"     => "wide-flange (W-shape) steel column",
    "steel_hss"   => "hollow structural section (HSS) steel column",
    "pixelframe"  => "PixelFrame composite column",
)

const _BEAM_NAMES = Dict{String, String}(
    "rc_rect"   => "rectangular RC beam",
    "rc_tbeam"  => "T-beam (integral with slab)",
    "steel_w"   => "wide-flange (W-shape) steel beam",
    "steel_hss" => "hollow structural section (HSS) beam",
    "pixelframe" => "PixelFrame composite beam",
)

# ─── Helpers ─────────────────────────────────────────────────────────────────

"""True when `du` is configured for imperial (English) units."""
_is_imperial(du::DisplayUnits) = du.units[:length] == u"ft"

"""Unit label strings for diagnostic JSON fields."""
_force_unit_str(du)    = _is_imperial(du) ? "kip" : "kN"
_moment_unit_str(du)   = _is_imperial(du) ? "kip-ft" : "kN-m"
_pressure_unit_str(du) = _is_imperial(du) ? "psf" : "kPa"
_area_unit_str(du)     = _is_imperial(du) ? "ft2" : "m2"

"""Round numeric value, preserving `nothing` as `nothing`."""
_round_or_nothing(x; digits=3) = isnothing(x) ? nothing : _round_val(x; digits=digits)

# ─── Governing check helpers ──────────────────────────────────────────────────

"""Return the governing limit-state check for a `SlabDesignResult` (see `slab_diagnostic_governing_check`)."""
function _slab_governing_check(sr::SlabDesignResult)
    slab_diagnostic_governing_check(sr)
end

"""Governing limit-state for columns (see `column_diagnostic_governing_check`)."""
function _column_governing_check(cr::ColumnDesignResult)
    column_diagnostic_governing_check(cr)
end

"""Governing limit-state for beams (see `beam_diagnostic_governing_check`)."""
function _beam_governing_check(br::BeamDesignResult)
    beam_diagnostic_governing_check(br)
end

"""Governing limit-state for foundations (see `foundation_diagnostic_governing_check`)."""
function _fdn_governing_check(fr::FoundationDesignResult)
    foundation_diagnostic_governing_check(fr)
end

"""
Classify the governing mode for an element based on its best available headroom.
`headroom > 0.40` suggests the element is at a minimum catalog or code size
rather than at a structural limit — i.e., making it smaller is not possible
without violating minimum requirements.
"""
_governing_mode(max_ratio::Float64) =
    (1.0 - max_ratio) > 0.40 ? "minimum_governed" : "structural_demand"

# ─── Analysis method / floor option codes ────────────────────────────────────

"""
Extract the floor analysis method string from `DesignParameters`.
Returns "DDM", "EFM", "FEA", or "unknown".
"""
function _analysis_method_code(params::DesignParameters)
    f = params.floor
    isnothing(f) && return "unknown"
    (f isa StructuralSizer.FlatPlateOptions || f isa StructuralSizer.FlatSlabOptions) || return "n/a"
    m = f.method
    m isa StructuralSizer.DDM && return "DDM"
    m isa StructuralSizer.EFM && return "EFM"
    m isa StructuralSizer.FEA && return "FEA"
    return "unknown"
end

"""
Extract the deflection-limit symbol as an API string, e.g. "L_360".
The `FlatPlateOptions.deflection_limit` field is a `Symbol` like `:L_360`.
Returns 360 as the numeric divisor.
"""
function _deflection_limit_divisor(params::DesignParameters)
    f = params.floor
    isnothing(f) && return 360
    (f isa StructuralSizer.FlatPlateOptions || f isa StructuralSizer.FlatSlabOptions) || return 360
    dl = f.deflection_limit   # Symbol e.g. :L_360
    try
        return parse(Int, split(string(dl), "_")[end])
    catch
        return 360
    end
end

"""
Extract the punching_strategy Symbol from floor options as a String.
Returns `nothing` when not applicable (non-flat floor systems).
"""
function _punching_strategy_code(params::DesignParameters)
    f = params.floor
    isnothing(f) && return nothing
    (f isa StructuralSizer.FlatPlateOptions || f isa StructuralSizer.FlatSlabOptions) || return nothing
    return string(f.punching_strategy)  # "grow_columns", "reinforce_first", "reinforce_last"
end

# ─── Per-element embodied carbon (kgCO₂e) ────────────────────────────────────

"""
Compute embodied carbon (kgCO₂e) for column at `idx`. Returns 0.0 on failure.
"""
function _col_ec_kgco2e(struc::BuildingStructure, idx::Int)
    try
        col = struc.columns[idx]
        return element_ec(volumes(col))
    catch e
        @warn "Column EC unavailable" column_id=idx exception=(e, catch_backtrace())
        return nothing
    end
end

"""
Compute embodied carbon (kgCO₂e) for beam at `idx`. Returns 0.0 on failure.
"""
function _beam_ec_kgco2e(struc::BuildingStructure, idx::Int)
    try
        bm = struc.beams[idx]
        return element_ec(volumes(bm))
    catch e
        @warn "Beam EC unavailable" beam_id=idx exception=(e, catch_backtrace())
        return nothing
    end
end

"""
Compute embodied carbon (kgCO₂e) for slab at `idx`. Returns 0.0 on failure.
"""
function _slab_ec_kgco2e(struc::BuildingStructure, idx::Int)
    try
        sl = struc.slabs[idx]
        return element_ec(sl.volumes)
    catch e
        @warn "Slab EC unavailable" slab_id=idx exception=(e, catch_backtrace())
        return nothing
    end
end

"""
Compute embodied carbon (kgCO₂e) for foundation at `idx`. Returns 0.0 on failure.
"""
function _fdn_ec_kgco2e(struc::BuildingStructure, idx::Int)
    try
        fdn = struc.foundations[idx]
        return element_ec(fdn.volumes)
    catch e
        @warn "Foundation EC unavailable" foundation_id=idx exception=(e, catch_backtrace())
        return nothing
    end
end

# ─── Slab span extraction ─────────────────────────────────────────────────────

"""
Return (l1_disp, l2_disp) span values in display units from a `Slab` result.
Falls back to (0.0, 0.0) for non-flat-plate result types that lack l1/l2.
"""
function _slab_spans_display(slab_obj, du::DisplayUnits)
    r = slab_obj.result
    try
        l1 = _to_display(du, :length, r.l1)
        l2 = _to_display(du, :length, r.l2)
        return (l1, l2)
    catch
        return (0.0, 0.0)
    end
end

# ─── Per-element serializers ──────────────────────────────────────────────────

"""
Build a Dict representing one column's full diagnostic data.
"""
function _diagnose_column(
    idx::Int,
    cr::ColumnDesignResult,
    col_obj::Column,
    struc::BuildingStructure,
    du::DisplayUnits,
)
    funit = _force_unit_str(du)
    munit = _moment_unit_str(du)
    thick_unit = _thickness_unit_string(du)

    governing = _column_governing_check(cr)
    punch_ratio = isnothing(cr.punching) ? 0.0 : cr.punching.ratio
    max_ratio   = max(cr.axial_ratio, cr.interaction_ratio, punch_ratio)
    if !cr.ok && max_ratio < 1.0
        max_ratio = 1.0
    end

    # Section dimensions in display (thickness) units
    c1_disp = _to_display(du, :thickness, cr.c1)
    c2_disp = _to_display(du, :thickness, cr.c2)

    # Demand values in display force/moment units
    pu_disp  = _to_display(du, :force, cr.Pu)
    mux_disp = _to_display(du, :moment, cr.Mu_x)
    muy_disp = _to_display(du, :moment, cr.Mu_y)

    # Column height
    h_disp = _to_display(du, :length, cr.height)

    # Tributary area: prefer punching result (exact), fall back to structure accessor
    trib_area_m2 = if !isnothing(cr.punching)
        ustrip(u"m^2", cr.punching.tributary_area)
    else
        try column_tributary_area(struc, col_obj) catch; 0.0 end
    end
    trib_area_disp = _to_display(du, :area, trib_area_m2 * u"m^2")

    checks = Dict{String, Any}[
        Dict{String, Any}(
            "name"         => "axial_compression",
            "code_clause"  => "ACI 318-19 §22.4.2",
            "demand"       => _round_val(pu_disp),
            "demand_unit"  => funit,
            "ratio"        => _round_val(cr.axial_ratio),
            "headroom"     => _round_val(1.0 - cr.axial_ratio),
            "governing"    => governing == "axial_compression",
        ),
        Dict{String, Any}(
            "name"         => "pm_interaction",
            "code_clause"  => "ACI 318-19 §22.4",
            "demand_Mu_x"  => _round_val(mux_disp),
            "demand_Mu_y"  => _round_val(muy_disp),
            "demand_unit"  => munit,
            "ratio"        => _round_val(cr.interaction_ratio),
            "headroom"     => _round_val(1.0 - cr.interaction_ratio),
            "governing"    => governing == "pm_interaction",
        ),
    ]

    # Add punching check only if the column supports a slab with punching data
    if !isnothing(cr.punching)
        p = cr.punching
        vu_disp  = _to_display(du, :force, p.Vu)
        phvc_disp = _to_display(du, :force, p.φVc)
        push!(checks, Dict{String, Any}(
            "name"          => "punching_shear_col",
            "code_clause"   => "ACI 318-19 §22.6",
            "demand_Vu"     => _round_val(vu_disp),
            "capacity_phiVc" => _round_val(phvc_disp),
            "demand_unit"   => funit,
            "ratio"         => _round_val(p.ratio),
            "headroom"      => _round_val(1.0 - p.ratio),
            "governing"     => governing == "punching_shear_col",
        ))
    end

    return Dict{String, Any}(
        "id"             => idx,
        "story"          => col_obj.story,
        "position"       => string(col_obj.position),
        "section"        => cr.section_size,
        "shape"          => string(cr.shape),
        "c1"             => _round_val(c1_disp),
        "c2"             => _round_val(c2_disp),
        "section_unit"   => thick_unit,
        "height"         => _round_val(h_disp),
        "height_unit"    => _length_unit_string(du),
        "rho_g"          => _round_val(cr.rho_g; digits=4),
        "tributary_area" => _round_val(trib_area_disp),
        "area_unit"      => _area_unit_str(du),
        "Pu"             => _round_val(pu_disp),
        "Mu_x"           => _round_val(mux_disp),
        "Mu_y"           => _round_val(muy_disp),
        "axial_ratio"    => _round_val(cr.axial_ratio),
        "interaction_ratio" => _round_val(cr.interaction_ratio),
        "force_unit"     => funit,
        "moment_unit"    => munit,
        "governing_check" => governing,
        "governing_ratio" => _round_val(max_ratio),
        "governing_mode"  => _governing_mode(max_ratio),
        "ok"             => cr.ok,
        "checks"         => checks,
        "levers"         => get(LEVER_MAP, governing, String[]),
        "limit_state_description" => get(LIMIT_STATE_DESCRIPTIONS, governing, ""),
        "ec_kgco2e"      => _round_or_nothing(_col_ec_kgco2e(struc, idx); digits=1),
    )
end

"""
Build a Dict representing one beam's full diagnostic data.
"""
function _diagnose_beam(
    idx::Int,
    br::BeamDesignResult,
    bm_obj::Beam,
    struc::BuildingStructure,
    du::DisplayUnits,
)
    funit = _force_unit_str(du)
    munit = _moment_unit_str(du)

    governing = _beam_governing_check(br)
    max_ratio = max(br.flexure_ratio, br.shear_ratio)
    if !br.ok && max_ratio < 1.0
        max_ratio = 1.0
    end

    mu_disp = _to_display(du, :moment, br.Mu)
    vu_disp = _to_display(du, :force,  br.Vu)
    L_disp  = _to_display(du, :length, br.member_length)

    # Tributary width (one-way slab load width)
    trib_w_disp = if !isnothing(bm_obj.tributary_width)
        _to_display(du, :length, bm_obj.tributary_width)
    else
        0.0
    end

    checks = Dict{String, Any}[
        Dict{String, Any}(
            "name"        => "flexure",
            "code_clause" => "AISC 360-22 Chapter F / ACI 318-19 §9.5",
            "demand"      => _round_val(mu_disp),
            "demand_unit" => munit,
            "ratio"       => _round_val(br.flexure_ratio),
            "headroom"    => _round_val(1.0 - br.flexure_ratio),
            "governing"   => governing == "flexure",
        ),
        Dict{String, Any}(
            "name"        => "shear",
            "code_clause" => "AISC 360-22 Chapter G / ACI 318-19 §22.5",
            "demand"      => _round_val(vu_disp),
            "demand_unit" => funit,
            "ratio"       => _round_val(br.shear_ratio),
            "headroom"    => _round_val(1.0 - br.shear_ratio),
            "governing"   => governing == "shear",
        ),
    ]

    return Dict{String, Any}(
        "id"              => idx,
        "role"            => string(bm_obj.role),
        "section"         => br.section_size,
        "member_length"   => _round_val(L_disp),
        "length_unit"     => _length_unit_string(du),
        "tributary_width" => _round_val(trib_w_disp),
        "Mu"              => _round_val(mu_disp),
        "Vu"              => _round_val(vu_disp),
        "force_unit"      => funit,
        "moment_unit"     => munit,
        "governing_check"  => governing,
        "governing_ratio"  => _round_val(max_ratio),
        "governing_mode"   => _governing_mode(max_ratio),
        "ok"              => br.ok,
        "checks"          => checks,
        "levers"          => get(LEVER_MAP, governing, String[]),
        "limit_state_description" => get(LIMIT_STATE_DESCRIPTIONS, governing, ""),
        "ec_kgco2e"       => _round_or_nothing(_beam_ec_kgco2e(struc, idx); digits=1),
    )
end

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
        "ok"             => sr.converged && sr.deflection_ok && sr.punching_ok,
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
    max_ratio = max(fr.bearing_ratio, fr.punching_ratio, fr.flexure_ratio)
    if !fr.ok && max_ratio < 1.0
        max_ratio = 1.0
    end

    L_disp     = _to_display_length(du, fr.length)
    W_disp     = _to_display_length(du, fr.width)
    D_disp     = _to_display(du, :thickness, fr.depth)
    react_disp = _to_display(du, :force, fr.reaction)

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
            "name"        => "flexure_fdn",
            "code_clause" => "ACI 318-19 §15.4",
            "ratio"       => _round_val(fr.flexure_ratio),
            "headroom"    => _round_val(1.0 - fr.flexure_ratio),
            "governing"   => governing == "flexure_fdn",
        ),
    ]

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

# ─── Collection serializers ───────────────────────────────────────────────────

function _diagnose_columns(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    isempty(design.columns) && return Dict{String, Any}[]
    [_diagnose_column(idx, design.columns[idx], struc.columns[idx], struc, du)
     for idx in _sorted_indices(design.columns)]
end

function _diagnose_beams(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    isempty(design.beams) && return Dict{String, Any}[]
    [_diagnose_beam(idx, design.beams[idx], struc.beams[idx], struc, du)
     for idx in _sorted_indices(design.beams)]
end

function _diagnose_slabs(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    isempty(design.slabs) && return Dict{String, Any}[]
    [_diagnose_slab(idx, design.slabs[idx], struc.slabs[idx], struc, du)
     for idx in _sorted_indices(design.slabs)]
end

function _diagnose_foundations(design::BuildingDesign, du::DisplayUnits)
    isempty(design.foundations) && return Dict{String, Any}[]
    [_diagnose_foundation(idx, design.foundations[idx], du)
     for idx in _sorted_indices(design.foundations)]
end

# ─── Design context ───────────────────────────────────────────────────────────

"""
Build a Dict that describes the design configuration (parameters, methods,
limits) in machine-readable form. This is the input-side context layer.
"""
function _diagnose_design_context(params::DesignParameters, du::DisplayUnits;
                                  design::Union{BuildingDesign, Nothing} = nothing)
    punit = _pressure_unit_str(du)
    lunit = _length_unit_string(du)

    # Loads
    floor_SDL = try _to_display(du, :pressure, params.loads.floor_SDL) catch; 0.0 end
    floor_LL  = try _to_display(du, :pressure, params.loads.floor_LL)  catch; 0.0 end
    roof_SDL  = try _to_display(du, :pressure, params.loads.roof_SDL)  catch; floor_SDL end
    roof_LL   = try _to_display(du, :pressure, params.loads.roof_LL)   catch; floor_LL  end

    # Floor options
    floor_type = _floor_type_code(params)
    col_type   = _column_type_code(params)
    beam_type  = _beam_type_code(params)
    # `params.columns` / `params.beams` are often unset when using prepare! defaults;
    # infer from sized results on `BuildingDesign` (still valid after `restore!`).
    if col_type == "unknown" && !isnothing(design)
        inferred = _column_type_code_from_design(design)
        inferred != "unknown" && (col_type = inferred)
    end
    if beam_type == "unknown" && !isnothing(design)
        beam_type = _beam_type_code_from_design(design, params)
    end
    analysis_method  = _analysis_method_code(params)
    defl_divisor     = _deflection_limit_divisor(params)
    punching_strat   = _punching_strategy_code(params)

    ctx = Dict{String, Any}(
        "floor_type"        => floor_type,
        "column_type"       => col_type,
        "beam_type"         => beam_type,
        "analysis_method"   => analysis_method,
        "deflection_limit"  => "L_$defl_divisor",
        "deflection_limit_description" =>
            "Slab deflection ≤ l / $defl_divisor where l is the governing span. " *
            "L/360 is the ACI 318-19 §24.2 default for live-load deflection of " *
            "members supporting non-structural elements not likely to be damaged.",
        "unit_system"       => _is_imperial(du) ? "imperial" : "metric",
        "loads" => Dict{String, Any}(
            "floor_SDL" => _round_val(floor_SDL),
            "floor_LL"  => _round_val(floor_LL),
            "roof_SDL"  => _round_val(roof_SDL),
            "roof_LL"   => _round_val(roof_LL),
            "unit"      => punit,
            "note"      => "SDL = superimposed dead load (finishes, partitions, MEP). " *
                           "LL = live load. Factored using ASCE 7 load combination 1.2D+1.6L.",
        ),
    )
    if !isnothing(punching_strat)
        ctx["punching_strategy"] = punching_strat
        ctx["punching_strategy_description"] = Dict{String, String}(
            "grow_columns"   => "Columns are sized up to satisfy punching directly. No shear reinforcement.",
            "reinforce_first" => "Shear studs are added first; columns are sized for P-M interaction only.",
            "reinforce_last" => "Columns grow until punching headroom falls below a threshold, then studs are added.",
        )[get(Dict("grow_columns"=>"grow_columns","reinforce_first"=>"reinforce_first","reinforce_last"=>"reinforce_last"), punching_strat, punching_strat)]
    end
    return ctx
end

# ─── Agent summary ────────────────────────────────────────────────────────────

"""
Build a concise agent summary: overall status, per-type statistics,
governing-check distribution, and worst elements.
"""
function _diagnose_agent_summary(
    design::BuildingDesign,
    du::DisplayUnits,
    col_dicts::Vector,
    beam_dicts::Vector,
    slab_dicts::Vector,
    fdn_dicts::Vector,
)
    s = design.summary

    # Per-type pass/fail counts and worst ratios
    function _stats(dicts, type_label)
        isempty(dicts) && return nothing
        ratios   = [something(get(d, "governing_ratio", 0.0), 0.0) for d in dicts]
        failing  = count(d -> !get(d, "ok", true), dicts)
        worst_id = argmax(ratios)
        Dict{String, Any}(
            "type"         => type_label,
            "count"        => length(dicts),
            "passing"      => length(dicts) - failing,
            "failing"      => failing,
            "worst_id"     => dicts[worst_id]["id"],
            "worst_ratio"  => _round_val(ratios[worst_id]),
            "worst_check"  => get(dicts[worst_id], "governing_check", ""),
            "worst_mode"   => get(dicts[worst_id], "governing_mode",  ""),
        )
    end

    # Governing check distribution across all elements
    all_checks = String[]
    for dicts in (col_dicts, beam_dicts, slab_dicts, fdn_dicts)
        for d in dicts
            gc = get(d, "governing_check", "")
            isempty(gc) || push!(all_checks, gc)
        end
    end
    check_counts = Dict{String, Int}()
    for c in all_checks
        check_counts[c] = get(check_counts, c, 0) + 1
    end
    check_dist = sort(collect(check_counts); by=x -> -x[2])

    # EC total
    total_ec = _round_val(s.embodied_carbon; digits=0)

    # Floor area & EC intensity
    struc = design.structure
    floor_area_m2 = sum(ustrip(u"m^2", c.area) for c in struc.cells; init=0.0)
    is_imp = du.units[:length] == u"ft"
    floor_area_disp = is_imp ? floor_area_m2 * 10.7639 : floor_area_m2
    area_unit = is_imp ? "ft2" : "m2"
    ec_intensity_m2 = floor_area_m2 > 0 ? s.embodied_carbon / floor_area_m2 : 0.0
    ec_intensity_disp = is_imp ? ec_intensity_m2 / 10.7639 : ec_intensity_m2
    intensity_unit = is_imp ? "kgCO2e/ft2" : "kgCO2e/m2"

    stats_vec = filter(!isnothing, [
        _stats(col_dicts,  "columns"),
        _stats(beam_dicts, "beams"),
        _stats(slab_dicts, "slabs"),
        _stats(fdn_dicts,  "foundations"),
    ])

    return Dict{String, Any}(
        "all_pass"           => s.all_checks_pass,
        "critical_element"   => s.critical_element,
        "critical_ratio"     => _round_val(s.critical_ratio),
        "total_ec_kgco2e"    => total_ec,
        "floor_area"         => Dict("value" => _round_val(floor_area_disp; digits=0), "unit" => area_unit,
                                     "value_m2" => _round_val(floor_area_m2; digits=0)),
        "ec_intensity"       => Dict("value" => _round_val(ec_intensity_disp; digits=1), "unit" => intensity_unit,
                                     "value_m2" => _round_val(ec_intensity_m2; digits=1), "unit_m2" => "kgCO2e/m2"),
        "governing_check_distribution" => [
            Dict("check" => c, "count" => n) for (c, n) in check_dist
        ],
        "per_type" => stats_vec,
    )
end

# ─── Architectural layer ──────────────────────────────────────────────────────

"""
Build the architectural layer: system narrative and goal-ranked recommendations.
"""
function _diagnose_architectural(
    design::BuildingDesign,
    params::DesignParameters,
    du::DisplayUnits,
    col_dicts::Vector,
    beam_dicts::Vector,
    slab_dicts::Vector,
    fdn_dicts::Vector,
)
    n_stories = length(design.structure.skeleton.stories)
    n_cols    = length(col_dicts)
    n_slabs   = length(slab_dicts)
    n_beams   = length(beam_dicts)
    n_fdns    = length(fdn_dicts)

    floor_name = get(_FLOOR_NAMES, _floor_type_code(params), _floor_type_code(params))
    col_code   = _column_type_code(params)
    if col_code == "unknown"
        inferred = _column_type_code_from_design(design)
        inferred != "unknown" && (col_code = inferred)
    end
    col_name  = get(_COLUMN_NAMES, col_code, col_code)
    beam_code = _beam_type_code(params)
    if beam_code == "unknown"
        beam_code = _beam_type_code_from_design(design, params)
    end
    beam_name = get(_BEAM_NAMES, beam_code, beam_code)

    beam_clause = n_beams > 0 ? " with $n_beams $beam_name members" : ""
    narrative = "This is a $n_stories-story structure with a $floor_name and $n_cols $col_name" *
                " column$(n_cols == 1 ? "" : "s")$beam_clause. " *
                "There $(n_slabs == 1 ? "is" : "are") $n_slabs slab panel$(n_slabs == 1 ? "" : "s")" *
                " and $n_fdns foundation$(n_fdns == 1 ? "" : "s")."

    # Goal-ranked recommendations
    goal_recs = _build_goal_recommendations(design, params, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)

    return Dict{String, Any}(
        "system_narrative"  => narrative,
        "goal_recommendations" => goal_recs,
    )
end

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
                pm_ratio = max(
                    get(worst_col, "axial_ratio",       0.0),
                    get(worst_col, "interaction_ratio", 0.0),
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
        elseif gc in ("pm_interaction", "axial_compression")
            push!(recs, Dict{String, Any}(
                "goal"             => "reduce_column_size",
                "primary_lever"    => "fc_column",
                "suggested_value"  => "higher f'c or stronger catalog",
                "current_ratio"    => get(worst_col, "governing_ratio", 0.0),
                "estimated_new_ratio" => nothing,
                "confidence"       => "requires_rerun",
                "rationale"        => "P-M interaction governs. Higher concrete strength or a larger catalog " *
                                     "section is the direct lever. A rerun is needed for exact results.",
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
            pm_ratios = [
                max(get(d, "axial_ratio", 0.0), get(d, "interaction_ratio", 0.0))
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

# ─── Footing Proximity ─────────────────────────────────────────────────────────

"""
    _check_footing_proximity!(warnings, design, fdn_dicts, is_imp, fdn_t)

Compute actual edge-to-edge clearances between spread footings using their designed
plan dimensions and column positions. Emits a warning for each pair of footings
whose edges are closer than 12 in (or overlap), and a warning for footings whose
plan area exceeds the threshold.
"""
function _check_footing_proximity!(
    warnings::Vector{Dict{String, Any}},
    design::BuildingDesign,
    fdn_dicts::Vector,
    is_imp::Bool,
    fdn_t::Dict{String, Any},
)
    struc = design.structure
    (isnothing(struc) || isempty(struc.foundations)) && return

    skel = struc.skeleton
    nf = length(struc.foundations)
    nf < 2 && return

    # Build a vector of (fdn_idx, centroid_x_m, centroid_y_m, half_L_m, half_W_m)
    # for single-support (spread) footings only.
    fdata = NamedTuple{(:fi, :x, :y, :hL, :hW),
                       NTuple{5, Float64}}[]

    for (fi, fnd) in enumerate(struc.foundations)
        length(fnd.support_indices) != 1 && continue
        si = fnd.support_indices[1]
        (si < 1 || si > length(struc.supports)) && continue
        sup = struc.supports[si]
        v = skel.vertices[sup.vertex_idx]
        c = Meshes.coords(v)
        cx = ustrip(u"m", c.x)
        cy = ustrip(u"m", c.y)

        # Get designed plan dimensions from FoundationDesignResult
        !haskey(design.foundations, fi) && continue
        fr = design.foundations[fi]
        L_m = ustrip(u"m", fr.length)
        W_m = ustrip(u"m", fr.width)
        (L_m <= 0 || W_m <= 0) && continue

        push!(fdata, (fi=fi, x=cx, y=cy, hL=L_m/2, hW=W_m/2))
    end

    length(fdata) < 2 && return

    min_clearance_m = 0.3048   # 12 inches

    for i in eachindex(fdata)
        for j in (i+1):length(fdata)
            a = fdata[i]
            b = fdata[j]

            # Axis-aligned edge-to-edge gap between rectangles centered on columns.
            # gap_x, gap_y are edge separations along each axis (negative = overlap).
            gap_x = abs(a.x - b.x) - a.hL - b.hL
            gap_y = abs(a.y - b.y) - a.hW - b.hW

            # If both gaps are negative, footings fully overlap in plan.
            # If one is negative, footings overlap on that axis; clearance = the other.
            # If both positive, closest corner distance = hypot(gap_x, gap_y).
            gap = if gap_x < 0 && gap_y < 0
                max(gap_x, gap_y)   # both overlap; report the smaller intrusion
            elseif gap_x < 0
                gap_y               # overlap in x, clearance determined by y
            elseif gap_y < 0
                gap_x               # overlap in y, clearance determined by x
            else
                hypot(gap_x, gap_y) # diagonal separation
            end

            if gap < min_clearance_m
                gap_in = gap * 39.3701
                gap_disp = is_imp ? round(gap_in; digits=1) : round(gap * 1000; digits=0)
                gap_unit = is_imp ? "in" : "mm"

                if gap <= 0
                    severity = "critical"
                    interp = "Footings $(a.fi) and $(b.fi) overlap by $(abs(round(gap_in; digits=1))) in — " *
                        "consider combining into a combined/strip footing or adding columns."
                else
                    severity = "warning"
                    interp = "Footings $(a.fi) and $(b.fi) have only $(gap_disp) $(gap_unit) " *
                        "edge clearance — construction may be impractical. " *
                        "Consider combining into a strip footing or adding columns."
                end

                push!(warnings, Dict{String, Any}(
                    "element_type" => "foundation",
                    "element_id" => "$(a.fi)-$(b.fi)",
                    "check" => "footing_proximity",
                    "severity" => severity,
                    "value" => _round_val(gap_disp),
                    "threshold" => is_imp ? 12.0 : 305.0,
                    "unit" => gap_unit,
                    "interpretation" => interp,
                    "parameter_headroom" => gap <= 0 ? "none" : "limited",
                ))
            end
        end
    end

    # Also check individual footing plan area
    for fd in fdn_dicts
        fl = get(fd, "length", 0.0)
        fw = get(fd, "width", 0.0)
        fl_ft = is_imp ? fl : fl * 3.28084
        fw_ft = is_imp ? fw : fw * 3.28084
        area_ft2 = fl_ft * fw_ft

        if area_ft2 > fdn_t["plan_area_max_ft2"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "foundation", "element_id" => get(fd, "id", "?"),
                "check" => "oversized_footing", "severity" => "warning",
                "value" => _round_val(area_ft2), "threshold" => fdn_t["plan_area_max_ft2"], "unit" => "ft²",
                "interpretation" => "Footing plan area $(round(area_ft2; digits=0)) ft² is very large. " *
                    "Consider adding columns or switching to strip/mat foundation.",
                "parameter_headroom" => "limited",
            ))
        end
    end
end

# ─── Element Reasonableness Checks ────────────────────────────────────────────

"""
    _element_reasonableness_checks(design, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)

Compare sized element dimensions against industry-norm thresholds from
`ELEMENT_REASONABLENESS_THRESHOLDS`. Returns a `Vector{Dict{String,Any}}`
of warnings sorted by severity (critical first).
"""
function _element_reasonableness_checks(
    design::BuildingDesign,
    du::DisplayUnits,
    col_dicts::Vector,
    beam_dicts::Vector,
    slab_dicts::Vector,
    fdn_dicts::Vector,
)::Vector{Dict{String, Any}}
    warnings = Dict{String, Any}[]
    is_imp = _is_imperial(du)
    t = ELEMENT_REASONABLENESS_THRESHOLDS

    slab_t = t["slab"]
    col_t  = t["column"]
    beam_t = t["beam"]
    fdn_t  = t["foundation"]

    # ── Slab checks ──────────────────────────────────────────────────────
    for sd in slab_dicts
        h_disp = get(sd, "thickness", 0.0)
        h_in   = is_imp ? h_disp : h_disp / 25.4

        if h_in > slab_t["thickness_extreme_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "slab", "element_id" => get(sd, "id", "?"),
                "check" => "extreme_thickness", "severity" => "critical",
                "value" => _round_val(h_in), "threshold" => slab_t["thickness_extreme_in"], "unit" => "in",
                "interpretation" => "Slab thickness $(round(h_in; digits=1)) in is extreme " *
                    "(> $(slab_t["thickness_extreme_in"]) in). This almost certainly indicates " *
                    "spans are too long for any slab system. Reduce column spacing in Grasshopper.",
                "parameter_headroom" => "none",
            ))
        elseif h_in > slab_t["thickness_max_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "slab", "element_id" => get(sd, "id", "?"),
                "check" => "excessive_thickness", "severity" => "warning",
                "value" => _round_val(h_in), "threshold" => slab_t["thickness_max_in"], "unit" => "in",
                "interpretation" => "Slab thickness $(round(h_in; digits=1)) in exceeds typical " *
                    "flat plate limit (~$(slab_t["thickness_max_in"]) in). Consider reducing spans " *
                    "or switching to a beam-and-slab system.",
                "parameter_headroom" => "limited",
            ))
        end

        defl_ratio = get(sd, "deflection_ratio", 0.0)
        if defl_ratio > slab_t["deflection_ratio_marginal"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "slab", "element_id" => get(sd, "id", "?"),
                "check" => "deflection_marginal", "severity" => "warning",
                "value" => _round_val(defl_ratio), "threshold" => slab_t["deflection_ratio_marginal"], "unit" => "ratio",
                "interpretation" => "Deflection ratio $(round(defl_ratio; digits=2)) is near " *
                    "the limit — almost no margin. Deeper slab would add self-weight, " *
                    "creating diminishing returns.",
                "parameter_headroom" => "limited",
            ))
        end
    end

    # Self-weight dominance: check from the design result objects directly
    # design.slabs is Dict{Int,SlabDesignResult}; enumerate(dict) yields (n, Pair{K,V}), not results.
    for (slab_idx, sr) in design.slabs
        qu_val  = sr.qu
        sw_val  = sr.self_weight
        (isnothing(qu_val) || isnothing(sw_val)) && continue
        qu_raw = Float64(ustrip(u"kPa", qu_val))
        sw_raw = Float64(ustrip(u"kPa", sw_val))
        qu_raw <= 0 && continue
        sw_frac = sw_raw / qu_raw
        if sw_frac > slab_t["self_weight_dominance"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "slab", "element_id" => "slab_$slab_idx",
                "check" => "self_weight_dominance", "severity" => "critical",
                "value" => _round_val(sw_frac; digits=2), "threshold" => slab_t["self_weight_dominance"], "unit" => "fraction",
                "interpretation" => "Slab self-weight is $(round(sw_frac * 100; digits=0))% of " *
                    "factored load — the slab is mostly carrying itself. " *
                    "This is a classic sign of spans being too long for the floor system.",
                "parameter_headroom" => "none",
            ))
        end
    end

    # ── Column checks ────────────────────────────────────────────────────
    for cd in col_dicts
        c1_disp = get(cd, "c1", 0.0)
        c2_disp = get(cd, "c2", 0.0)
        c_max_disp = max(c1_disp, c2_disp)
        c_min_disp = min(c1_disp, c2_disp)
        c_max_in = is_imp ? c_max_disp : c_max_disp / 25.4
        c_min_in = is_imp ? c_min_disp : c_min_disp / 25.4

        if c_max_in > col_t["max_dimension_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "column", "element_id" => get(cd, "id", "?"),
                "check" => "oversized_column", "severity" => "warning",
                "value" => _round_val(c_max_in), "threshold" => col_t["max_dimension_in"], "unit" => "in",
                "interpretation" => "Column dimension $(round(c_max_in; digits=1)) in exceeds " *
                    "$(col_t["max_dimension_in"]) in — unusual for buildings under ~20 stories. " *
                    "Consider adding columns to redistribute load.",
                "parameter_headroom" => "limited",
            ))
        end

        if c_min_in > 0 && c_min_in < col_t["min_dimension_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "column", "element_id" => get(cd, "id", "?"),
                "check" => "undersized_column", "severity" => "warning",
                "value" => _round_val(c_min_in), "threshold" => col_t["min_dimension_in"], "unit" => "in",
                "interpretation" => "Column dimension $(round(c_min_in; digits=1)) in is below " *
                    "practical minimum (~$(col_t["min_dimension_in"]) in).",
                "parameter_headroom" => "available",
            ))
        end

        rho_g = get(cd, "rho_g", 0.0)
        if rho_g > col_t["rho_g_high"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "column", "element_id" => get(cd, "id", "?"),
                "check" => "congested_reinforcement", "severity" => "warning",
                "value" => _round_val(rho_g; digits=4), "threshold" => col_t["rho_g_high"], "unit" => "ratio",
                "interpretation" => "Reinforcement ratio $(round(rho_g; digits=3)) exceeds " *
                    "$(col_t["rho_g_high"]) — congested rebar makes construction difficult. " *
                    "ACI max is 0.08. Consider larger column section or higher f'c.",
                "parameter_headroom" => "limited",
            ))
        end
    end

    # ── Beam checks ──────────────────────────────────────────────────────
    for bd in beam_dicts
        section = get(bd, "section", "")
        member_len = get(bd, "member_length", 0.0)  # ft (imp) or m (metric)
        len_in = is_imp ? member_len * 12.0 : member_len * 39.3701  # → inches

        # Extract depth from W-shape section name (e.g. "W24x94" → 24 in)
        m = match(r"W(\d+)", section)
        if !isnothing(m)
            depth_in = parse(Float64, m.captures[1])

            if depth_in > beam_t["depth_max_in"]
                push!(warnings, Dict{String, Any}(
                    "element_type" => "beam", "element_id" => get(bd, "id", "?"),
                    "check" => "very_deep_beam", "severity" => "warning",
                    "value" => depth_in, "threshold" => beam_t["depth_max_in"], "unit" => "in",
                    "interpretation" => "Beam depth $(round(depth_in; digits=0)) in is very deep — " *
                        "may conflict with MEP routing and ceiling clearance.",
                    "parameter_headroom" => "limited",
                ))
            end

            if len_in > 0 && depth_in > 0
                l_d = len_in / depth_in
                if l_d < beam_t["span_to_depth_min"]
                    push!(warnings, Dict{String, Any}(
                        "element_type" => "beam", "element_id" => get(bd, "id", "?"),
                        "check" => "low_span_depth_ratio", "severity" => "warning",
                        "value" => _round_val(l_d), "threshold" => beam_t["span_to_depth_min"], "unit" => "L/d",
                        "interpretation" => "Span-to-depth ratio $(round(l_d; digits=1)) is unusually low — " *
                            "beam is very deep relative to its span, suggesting heavy loads or geometry issues.",
                        "parameter_headroom" => "limited",
                    ))
                end
            end
        end

        # Weight per foot for steel beams (from section name, e.g. "W24x94" → 94 plf)
        mw = match(r"W\d+x(\d+)", section)
        if !isnothing(mw)
            wt_plf = parse(Float64, mw.captures[1])
            if wt_plf > beam_t["weight_per_ft_extreme"]
                push!(warnings, Dict{String, Any}(
                    "element_type" => "beam", "element_id" => get(bd, "id", "?"),
                    "check" => "heavy_beam", "severity" => "warning",
                    "value" => wt_plf, "threshold" => beam_t["weight_per_ft_extreme"], "unit" => "plf",
                    "interpretation" => "Beam weight $(round(wt_plf; digits=0)) plf is very heavy — " *
                        "suggests high demands. Consider reducing span or adding intermediate supports.",
                    "parameter_headroom" => "limited",
                ))
            end
        end
    end

    # ── Foundation checks ────────────────────────────────────────────────
    for fd in fdn_dicts
        fdepth = get(fd, "depth", 0.0)
        d_in = is_imp ? fdepth : fdepth / 25.4         # depth is in in (imp) or mm (metric)

        if d_in > fdn_t["depth_max_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "foundation", "element_id" => get(fd, "id", "?"),
                "check" => "deep_footing", "severity" => "warning",
                "value" => _round_val(d_in), "threshold" => fdn_t["depth_max_in"], "unit" => "in",
                "interpretation" => "Footing depth $(round(d_in; digits=1)) in is very thick — " *
                    "high punching or flexure demands from large column reactions.",
                "parameter_headroom" => "limited",
            ))
        end
    end

    # ── Foundation proximity (actual edge-to-edge clearance) ──────────
    _check_footing_proximity!(warnings, design, fdn_dicts, is_imp, fdn_t)

    # Sort: critical first, then by element type
    sort!(warnings; by=w -> (get(w, "severity", "") == "critical" ? 0 : 1, get(w, "element_type", "")))
    return warnings
end

# ─── Top-level ────────────────────────────────────────────────────────────────

"""
    design_to_diagnose(design::BuildingDesign; report_units=nothing) -> Dict{String, Any}

Serialize a `BuildingDesign` into the high-resolution diagnostic JSON format.

Returns a three-layer Dict:
- `columns`, `beams`, `slabs`, `foundations`: per-element engineering data
  (checks, demands, capacities, governing check, levers, EC).
- `agent_summary`: overall pass/fail status, check distribution, worst elements.
- `architectural`: system narrative, goal recommendations.
- `constraints`: geometry-fixed values and analytical lever impact estimates.
- `size_warnings`: element reasonableness checks (abnormal sizes, parameter headroom).
- `design_context`: input parameters (loads, methods, limits) in machine-readable form.

All numeric values are in the display unit system specified by `report_units`
(`:imperial` or `:metric`) or `design.params.display_units` if not specified.
"""
function design_to_diagnose(design::BuildingDesign; report_units=nothing)
    params = design.params
    du = report_units === nothing ? params.display_units : DisplayUnits(report_units)
    struc = design.structure

    col_dicts  = _diagnose_columns(design, struc, du)
    beam_dicts = _diagnose_beams(design, struc, du)
    slab_dicts = _diagnose_slabs(design, struc, du)
    fdn_dicts  = _diagnose_foundations(design, du)

    design_context = _diagnose_design_context(params, du; design=design)
    agent_summary  = _diagnose_agent_summary(design, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)
    architectural  = _diagnose_architectural(design, params, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)
    constraints    = _diagnose_constraints(design, struc, params, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)
    size_warnings  = _element_reasonableness_checks(design, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)

    return Dict{String, Any}(
        "status"         => "ok",
        "unit_system"    => _is_imperial(du) ? "imperial" : "metric",
        "length_unit"    => _length_unit_string(du),
        "thickness_unit" => _thickness_unit_string(du),
        "force_unit"     => _force_unit_str(du),
        "moment_unit"    => _moment_unit_str(du),
        "pressure_unit"  => _pressure_unit_str(du),
        "design_context" => design_context,
        "agent_summary"  => agent_summary,
        "columns"        => col_dicts,
        "beams"          => beam_dicts,
        "slabs"          => slab_dicts,
        "foundations"    => fdn_dicts,
        "architectural"  => architectural,
        "constraints"    => constraints,
        "size_warnings"  => size_warnings,
    )
end
