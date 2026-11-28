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
    "axial_compression_unverified" => ["column_catalog"],
    "pm_interaction"      => ["column_catalog", "fc_column"],
    "punching_shear_col"  => ["punching_strategy", "column_catalog"],
    "column_shear"        => ["column_catalog", "fc_column"],
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
    "one_way_shear_fdn"   => ["bearing_capacity"],
    "flexure_fdn"         => ["bearing_capacity"],
)

"""
Plain-English descriptions of each limit state for non-technical users.
Code clause annotations cite ACI 318-19 and AISC 360-16 (the steel edition
actually implemented by `StructuralSizer.AISCChecker`).
"""
const LIMIT_STATE_DESCRIPTIONS = Dict{String, String}(
    "axial_compression" =>
        "The column is carrying load near its maximum axial capacity. " *
        "ACI 318-19 §22.4.2: Pn = 0.85·f'c·(Ag – As) + fy·As. " *
        "A larger section or higher-strength concrete raises this ceiling.",

    "axial_compression_unverified" =>
        "The column's axial-compression capacity could NOT be verified. For a steel column " *
        "the AISC 360-16 §E3/§E4 flexural/torsional-buckling strength was unavailable for this " *
        "section (e.g. an unsupported/built-up shape or a section with no material assigned), so " *
        "the axial and P-M interaction ratios are reported as null rather than substituting the " *
        "unconservative gross-yield bound. This column is treated as FAILING until a section with " *
        "an evaluable buckling capacity is chosen; it is not a passing result.",

    "pm_interaction" =>
        "The column is under simultaneous axial compression and bending — " *
        "moment from unequal spans or slab rotations. ACI 318-19 §22.4. " *
        "The P-M interaction surface shrinks under combined loading; " *
        "a larger section or higher concrete grade expands it.",

    "column_shear" =>
        "Factored shear compared with φVn from ACI 318-19 §22.5 (§10.5.3.1). " *
        "Ties are tightened until the demand fits or the section reaches " *
        "Eq. (22.5.1.2). Past that limit, a larger section or a higher f'c " *
        "is the remaining lever.",

    "punching_shear_col" =>
        "The slab is on the verge of punching through around the column, " *
        "like a cookie-cutter through dough. ACI 318-19 §22.6. " *
        "The critical shear perimeter (bo = 4·(c + d)) at distance d/2 from " *
        "the column face is too small for the transmitted force. " *
        "Bigger columns, shear studs, or drop panels fix this.",

    "flexure" =>
        "The beam cannot resist the bending moment at this demand level. " *
        "AISC 360-16 Chapter F (steel) or ACI 318-19 §9.5 (RC). " *
        "A deeper or heavier section is needed.",

    "shear" =>
        "The beam is failing to transfer transverse (vertical) load. " *
        "AISC 360-16 Chapter G (steel) or ACI 318-19 §22.5 (RC). " *
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

    "one_way_shear_fdn" =>
        "The footing is failing in beam-like shear across its width. ACI 318-19 §22.5. " *
        "Increasing the footing depth (d) resolves this.",

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

"""
    _serialized_ratio(d, key; missing_default=0.0, unverified=1.0) -> Float64

Read a demand/capacity ratio from an already-serialized element `Dict` for arithmetic or
comparison, mapping an UNVERIFIED value to an ATTENTION/failing sentinel instead of `0.0`.

`_round_val` serializes a non-finite ratio (`NaN`/`Inf`) as `nothing` (JSON `null`), and a
steel column whose §E3/§E4 buckling capacity was unavailable carries `NaN` axial/interaction
ratios (see `_populate_column_results!`). A present-but-`nothing` value therefore means
"unverified", NOT "zero utilization". Plain `get(d, key, 0.0)` is unsafe on two counts:
(1) the `0.0` default applies only to a MISSING key, so a present `nothing` slips through and
then throws under `max`/comparison (`max(nothing, …)` is a `MethodError`); and (2) treating an
unverified column as ratio `0.0` reads as maximum headroom (safe) in any "worst element" /
lever selection — the opposite of the truth. This maps `nothing`/non-finite to `unverified`
(default `1.0`, a failing ratio consistent with the summary path) and a genuinely MISSING key to
`missing_default`.
"""
function _serialized_ratio(d, key; missing_default::Float64 = 0.0, unverified::Float64 = 1.0)::Float64
    haskey(d, key) || return missing_default
    v = d[key]
    (v === nothing || (v isa Real && !isfinite(v))) && return unverified
    return Float64(v)
end

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
        return ustrip(u"kgCO2e", element_ec(volumes(col)))
    catch e
        @warn "Column EC unavailable" column_id=idx exception=(e, catch_backtrace())
        return nothing
    end
end

"""
Compute embodied carbon (kgCO₂e) for beam at `idx`. Returns `nothing` on failure.
"""
function _beam_ec_kgco2e(struc::BuildingStructure, idx::Int)
    try
        bm = struc.beams[idx]
        return ustrip(u"kgCO2e", element_ec(volumes(bm)))
    catch e
        @warn "Beam EC unavailable" beam_id=idx exception=(e, catch_backtrace())
        return nothing
    end
end

"""
Compute embodied carbon (kgCO₂e) for slab at `idx`. Returns `nothing` on failure.
"""
function _slab_ec_kgco2e(struc::BuildingStructure, idx::Int)
    try
        sl = struc.slabs[idx]
        return ustrip(u"kgCO2e", element_ec(sl.volumes))
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
            "joint_search"   => "Slab thickness, column sizes, and shear studs are chosen together by embodied carbon.",
        )[punching_strat]
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

    # EC total — strip the typed `kgCO₂e` field at the JSON boundary so
    # the downstream Dict / Printf consumers stay numeric.
    ec_total_kg = ustrip(u"kgCO2e", s.embodied_carbon)
    total_ec    = _round_val(ec_total_kg; digits=0)

    # Floor area & EC intensity
    struc = design.structure
    floor_area_m2 = sum(ustrip(u"m^2", c.area) for c in struc.cells; init=0.0)
    is_imp = du.units[:length] == u"ft"
    floor_area_disp = is_imp ? floor_area_m2 * 10.7639 : floor_area_m2
    area_unit = is_imp ? "ft2" : "m2"
    ec_intensity_m2 = floor_area_m2 > 0 ? ec_total_kg / floor_area_m2 : 0.0
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

