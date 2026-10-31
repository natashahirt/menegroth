# Must match `_serialize_slabs` / `agent_situation_card` slab failure predicate.
_slab_design_ok(sr::SlabDesignResult) = sr.converged && sr.deflection_ok && sr.punching_ok

function _slab_governing_ratio_label(idx::Int, sr::SlabDesignResult)
    rd = sr.deflection_ratio
    rp = sr.punching_max_ratio
    if rd >= rp
        return rd, "Slab $idx (deflection)"
    else
        return rp, "Slab $idx (punching)"
    end
end

"""Compute summary metrics: critical element search + material quantity aggregation."""
function _compute_design_summary!(design::BuildingDesign, struc::BuildingStructure, params::DesignParameters)
    summary = design.summary

    # ── Critical element search ──────────────────────────────────────────
    # `glob_*` = highest ratio anywhere (utilization narrative).
    # `fail_*` = worst among elements that fail API-style `ok` (matches chat / GET /result).
    glob_ratio = 0.0
    glob_elem = ""
    fail_ratio = 0.0
    fail_elem = ""
    all_ok = true

    for (idx, slab_result) in design.slabs
        r_glob, lab_glob = _slab_governing_ratio_label(idx, slab_result)
        if r_glob > glob_ratio
            glob_ratio = r_glob
            glob_elem = lab_glob
        end
        if !_slab_design_ok(slab_result)
            all_ok = false
            g = slab_diagnostic_governing_check(slab_result)
            rd = slab_result.deflection_ratio
            rp = slab_result.punching_max_ratio
            r_fail = max(rd, rp)
            if g in ("reinforcement_design", "reinforcement_design_secondary", "transfer_reinforcement", "non_convergence")
                r_fail = max(r_fail, 1.0)
            end
            lab_fail = "Slab $idx ($g)"
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab_fail
            end
        end
    end

    for (idx, col_result) in design.columns
        r_ax = col_result.axial_ratio
        r_int = col_result.interaction_ratio
        r_punch = (!isnothing(col_result.punching) ? col_result.punching.ratio : 0.0)
        # An UNVERIFIED axial/interaction ratio (NaN sentinel — the §E3/§E4 buckling
        # capacity was unavailable; see `_populate_column_results!`) must NOT be
        # treated as a low/passing ratio. Exclude NaN terms from the numeric
        # aggregate (so they can never poison `glob_ratio`/`fail_ratio` with NaN)
        # and force the column to register as a definite failure below.
        axial_unverified = isnan(r_ax) || isnan(r_int)
        finite_ratios = filter(!isnan, (r_ax, r_int, r_punch))
        r_glob = isempty(finite_ratios) ? 0.0 : maximum(finite_ratios)
        g_glob = if axial_unverified
            "axial_compression_unverified"
        elseif r_ax >= r_int && r_ax >= r_punch
            "axial_compression"
        elseif r_int >= r_punch
            "pm_interaction"
        else
            "punching_shear_col"
        end
        lab_glob = "Column $idx ($g_glob)"
        if r_glob > glob_ratio
            glob_ratio = r_glob
            glob_elem = lab_glob
        end
        if !col_result.ok
            all_ok = false
            # Failed (or unverified) column reports a ratio ≥ 1.0, never NaN.
            r_fail = max(r_glob, 1.0)
            gcheck = axial_unverified ? "axial_compression_unverified" :
                     column_diagnostic_governing_check(col_result)
            lab_fail = "Column $idx ($gcheck)"
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab_fail
            end
        end
    end

    for (idx, beam_result) in design.beams
        r_glob = max(beam_result.flexure_ratio, beam_result.shear_ratio)
        g_glob = beam_result.flexure_ratio >= beam_result.shear_ratio ? "flexure" : "shear"
        lab_glob = "Beam $idx ($g_glob)"
        if r_glob > glob_ratio
            glob_ratio = r_glob
            glob_elem = lab_glob
        end
        if !beam_result.ok
            all_ok = false
            r_fail = r_glob < 1.0 ? 1.0 : r_glob
            lab_fail = "Beam $idx ($(beam_diagnostic_governing_check(beam_result)))"
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab_fail
            end
        end
    end

    for (idx, fdn_result) in design.foundations
        fdn_ratios = (
            fdn_result.bearing_ratio  => "bearing",
            fdn_result.punching_ratio => "punching",
            fdn_result.flexure_ratio  => "flexure",
        )
        for (r, check_name) in fdn_ratios
            if r > glob_ratio
                glob_ratio = r
                glob_elem = "Foundation $idx ($check_name)"
            end
        end
        if !fdn_result.ok
            all_ok = false
            r_fail = max(fdn_result.bearing_ratio, fdn_result.punching_ratio, fdn_result.flexure_ratio)
            if r_fail < 1.0
                r_fail = 1.0
            end
            lab_fail = "Foundation $idx ($(foundation_diagnostic_governing_check(fdn_result)))"
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab_fail
            end
        end
    end

    for (idx, records) in design.walls
        for rec in records
            r = isfinite(rec.ratio) ? rec.ratio : 0.0
            lab = "Wall $idx ($(rec.check)) story $(rec.story) $(rec.case)"
            if r > glob_ratio
                glob_ratio = r
                glob_elem = lab
            end
            if !rec.passed
                all_ok = false
                r_fail = r < 1.0 ? 1.0 : r
                if r_fail > fail_ratio || isempty(fail_elem)
                    fail_ratio = max(fail_ratio, r_fail)
                    fail_elem = lab
                end
            end
        end
    end

    for drift in design.seismic_story_drift
        drift isa SeismicStoryDriftCheck || continue
        r = drift.allowable_m > 0 ? drift.drift_m / drift.allowable_m :
            (drift.passes ? 0.0 : 1.0)
        lab = "Seismic story drift story $(drift.story) $(drift.direction)"
        if isfinite(r) && r > glob_ratio
            glob_ratio = r
            glob_elem = lab
        end
        if !drift.passes
            all_ok = false
            r_fail = !isfinite(r) || r < 1.0 ? 1.0 : r
            if r_fail > fail_ratio || isempty(fail_elem)
                fail_ratio = max(fail_ratio, r_fail)
                fail_elem = lab
            end
        end
    end

    if !all_ok && (!isempty(fail_elem) || fail_ratio > 0)
        summary.critical_ratio = fail_ratio > 0 ? fail_ratio : glob_ratio
        summary.critical_element = !isempty(fail_elem) ? fail_elem : glob_elem
    else
        summary.critical_ratio = glob_ratio
        summary.critical_element = glob_elem
    end
    summary.all_checks_pass = all_ok

    # ── Material quantity aggregation ────────────────────────────────────
    # Same volumes as the element takeoff. Mass is volume × that material's
    # density. An unsplit reinforced-concrete lump is concrete only: rebar is
    # not inferred. Drop panels, shear caps, capitals, and studs are already
    # on the slab volumes.
    total_conc_vol = 0.0u"m^3"
    total_steel_wt = 0.0u"kg"
    total_rebar_wt = 0.0u"kg"
    total_timber_vol = 0.0u"m^3"
    addq! = function (part)
        total_conc_vol += part.concrete
        total_rebar_wt += part.rebar
        total_steel_wt += part.steel
        total_timber_vol += part.timber
    end

    for slab in struc.slabs
        addq!(_quantity_increments(slab.volumes))
    end
    ρ_col_rebar = resolve_column_rebar(params.materials).ρ
    for (idx, column) in enumerate(struc.columns)
        vols = volumes(column)
        if !isempty(vols)
            addq!(_quantity_increments(vols))
        else
            col_result = get(design.columns, idx, nothing)
            if !isnothing(col_result) && col_result.Ag > 0.0u"m^2" && col_result.height > 0.0u"m"
                total_conc_vol += (col_result.Ag - col_result.As_total) * col_result.height
                total_rebar_wt += uconvert(u"kg", col_result.As_total * col_result.height * ρ_col_rebar)
            end
        end
    end
    for beam in struc.beams
        addq!(_quantity_increments(volumes(beam)))
    end
    for (beam_idx, beam_result) in design.beams
        beam_idx isa Integer && beam_idx in eachindex(struc.beams) &&
            !isempty(volumes(struc.beams[beam_idx])) && continue
        total_steel_wt += beam_result.weight
    end
    for strut in struc.struts
        addq!(_quantity_increments(volumes(strut)))
    end
    for foundation in struc.foundations
        addq!(_quantity_increments(foundation.volumes))
    end
    ρ_fdn_rebar = something(params.materials.rebar, StructuralSizer.Rebar_60).ρ
    for (f_idx, fdn_result) in design.foundations
        f_idx isa Integer && f_idx in eachindex(struc.foundations) &&
            !isempty(struc.foundations[f_idx].volumes) && continue
        total_conc_vol += fdn_result.concrete_volume
        total_rebar_wt += uconvert(u"kg", fdn_result.steel_volume * ρ_fdn_rebar)
    end

    summary.concrete_volume = total_conc_vol
    summary.steel_weight = total_steel_wt
    summary.rebar_weight = total_rebar_wt
    summary.timber_volume = total_timber_vol

    # ── Embodied carbon (totals + breakdown frozen here — same numbers as API / reports) ──
    # `BuildingECResult` now carries typed `kgCO₂e` quantities (Asap `𝐗` dimension);
    # `DesignSummary` keeps bare Float64 fields for JSON / API compatibility, so
    # we strip at this boundary. T2.3 will type the summary fields themselves
    # and move stripping to the API serializer.
    try
        ec = compute_building_ec(struc, params)
        # `DesignSummary.embodied_carbon_*` are typed `kgCO₂e` quantities
        # since T2.3; assign the typed quantities directly and let the
        # serialize / narrate / agent_tools paths strip at the API edge.
        summary.embodied_carbon             = ec.total_ec
        summary.embodied_carbon_slabs       = ec.slab_ec
        summary.embodied_carbon_columns     =
            sum(r.ec for r in ec.members if r.element_type == :column; init=0.0u"kgCO2e")
        summary.embodied_carbon_beams       =
            sum(r.ec for r in ec.members if r.element_type == :beam;   init=0.0u"kgCO2e")
        summary.embodied_carbon_struts      =
            sum(r.ec for r in ec.members if r.element_type == :strut;  init=0.0u"kgCO2e")
        summary.embodied_carbon_foundations = ec.foundation_ec
        summary.embodied_carbon_fireproofing= ec.fireproofing_ec
        parts = material_ec_total(struc)
        summary.embodied_carbon_concrete         = parts.concrete
        summary.embodied_carbon_rebar            = parts.rebar
        summary.embodied_carbon_structural_steel = parts.structural_steel
        summary.embodied_carbon_timber           = parts.timber
        summary.embodied_carbon_other            = parts.other
        by_element = takeoff_by_element(struc)
        summary.takeoff_slabs       = by_element.slabs
        summary.takeoff_columns     = by_element.columns
        summary.takeoff_beams       = by_element.beams
        summary.takeoff_struts      = by_element.struts
        summary.takeoff_foundations = by_element.foundations
    catch e
        @warn "Embodied carbon computation failed — defaulting to 0.0" exception=(e, catch_backtrace())
        summary.embodied_carbon              = 0.0u"kgCO2e"
        summary.embodied_carbon_slabs        = 0.0u"kgCO2e"
        summary.embodied_carbon_columns      = 0.0u"kgCO2e"
        summary.embodied_carbon_beams        = 0.0u"kgCO2e"
        summary.embodied_carbon_struts       = 0.0u"kgCO2e"
        summary.embodied_carbon_foundations  = 0.0u"kgCO2e"
        summary.embodied_carbon_fireproofing = 0.0u"kgCO2e"
        summary.embodied_carbon_concrete         = 0.0u"kgCO2e"
        summary.embodied_carbon_rebar            = 0.0u"kgCO2e"
        summary.embodied_carbon_structural_steel = 0.0u"kgCO2e"
        summary.embodied_carbon_timber           = 0.0u"kgCO2e"
        summary.embodied_carbon_other            = 0.0u"kgCO2e"
        summary.takeoff_slabs       = MaterialTakeoff()
        summary.takeoff_columns     = MaterialTakeoff()
        summary.takeoff_beams       = MaterialTakeoff()
        summary.takeoff_struts      = MaterialTakeoff()
        summary.takeoff_foundations = MaterialTakeoff()
    end
end

"""
    _set_rc_column_volumes!(col, concrete, rebar)

Write concrete and rebar volumes for one RC column via [`member_material_volumes`](@ref).

`L` is [`member_length`](@ref). Concrete is `(Ag − As) · L` and rebar is `As · L`,
so each material keeps its own density and carbon coefficient.
"""
function _set_rc_column_volumes!(col, concrete::StructuralSizer.Concrete, rebar::StructuralSizer.RebarSteel)
    sec = section(col)
    isnothing(sec) && return col
    set_volumes!(col, member_material_volumes(sec, member_length(col), concrete; rebar=rebar))
    return col
end

