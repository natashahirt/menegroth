# =============================================================================
# Engineering Report
# =============================================================================
# Dense, numbers-focused report for structural design review.
# One function call: engineering_report(design) prints all tables.
#
# Units: Defaults to design.params.display_units (from DesignParams). Override
# with report_units=:imperial or report_units=:metric. Uses Unitful for conversions.
#
# Tables:
#   1. Design header (name, materials, loads)
#   2. Slab panel schedule — adapts to floor type
#   3. Beam schedule
#   4. Column schedule
#   5. Foundation schedule
#   6. Material takeoff + embodied carbon
# =============================================================================

"""Convert a Unitful value to display units and return Float64. Uses du.units[cat]."""
_to_report(du::DisplayUnits, cat::Symbol, val; digits=2) =
    round(ustrip(du.units[cat], uconvert(du.units[cat], val)); digits=digits)

"""Convert force-per-length (e.g. thrust kN/m) to display units."""
function _to_report_thrust(du::DisplayUnits, val; digits=2)
    target = du.units[:length] == u"ft" ? (kip / u"ft") : (u"kN/m")
    round(ustrip(target, uconvert(target, val)); digits=digits)
end

"""Unit label string for report column headers (e.g. \"psf\", \"kPa\")."""
const _IMPERIAL_LABELS = Dict(
    :length => "ft", :thickness => "in", :area => "ft²", :volume => "ft³",
    :force => "kip", :moment => "kip·ft", :pressure => "psf", :stress => "ksi",
    :mass => "lb", :deflection => "in", :spacing => "in", :rebar_area => "in²",
    :thrust => "kip/ft",
)
const _METRIC_LABELS = Dict(
    :length => "m", :thickness => "mm", :area => "m²", :volume => "m³",
    :force => "kN", :moment => "kN·m", :pressure => "kPa", :stress => "MPa",
    :mass => "kg", :deflection => "mm", :spacing => "mm", :rebar_area => "mm²",
    :thrust => "kN/m",
)
_ul(du::DisplayUnits, cat::Symbol) =
    du.units[:length] == u"ft" ? get(_IMPERIAL_LABELS, cat, "") : get(_METRIC_LABELS, cat, "")

"""
    engineering_report(design::BuildingDesign; io::IO=stdout, report_units=nothing)

Print a dense engineering report summarizing the design.
All relevant inputs and outputs are stated; no hidden assumptions.
Adapts automatically to the slab, beam, and column types in the design.

# Arguments
- `report_units`: When `nothing` (default), uses `design.params.display_units` (from DesignParams).
  Override with `:imperial` or `:metric` to force a specific unit system.
"""
function engineering_report(design::BuildingDesign; io::IO=stdout, report_units=nothing)
    params = design.params
    du = report_units === nothing ? params.display_units : DisplayUnits(report_units)

    conc = resolve_concrete(params)
    reb  = resolve_rebar(params)

    _report_header(io, design; conc=conc, reb=reb, du=du)
    _report_slabs(io, design; conc=conc, reb=reb, du=du)
    _report_beams(io, design; du=du)
    _report_columns(io, design; conc=conc, reb=reb, du=du)
    _report_foundations(io, design; du=du)
    _report_takeoff(io, design; du=du)
    _report_status(io, design)
end

# ─────────────────────────────────────────────────────────────────────────────
# 1. Header
# ─────────────────────────────────────────────────────────────────────────────

"""Print the report header: timestamp, materials, unfactored loads, and building geometry."""
function _report_header(io::IO, design::BuildingDesign;
                        conc=resolve_concrete(design.params),
                        reb=resolve_rebar(design.params),
                        du::DisplayUnits=design.params.display_units)
    params = design.params
    struc = design.structure
    loads = params.loads

    println(io, section_break("ENGINEERING REPORT: $(params.name)"))
    println(io, "  Generated: $(Dates.format(design.created, "yyyy-mm-dd HH:MM"))")
    println(io, "  Compute time: $(round(design.compute_time_s; digits=2))s")
    println(io)

    # Materials — use stress + density in display units
    fc_val = _to_report(du, :stress, conc.fc′; digits=0)
    fy_val = _to_report(du, :stress, reb.Fy; digits=0)
    Ec_val = _to_report(du, :stress, StructuralSizer.Ec(conc); digits=0)
    Es_val = _to_report(du, :stress, reb.E; digits=0)
    γc_val = du.units[:length] == u"ft" ?
        round(ustrip(pcf, uconvert(pcf, conc.ρ)); digits=1) :
        round(ustrip(u"kg/m^3", uconvert(u"kg/m^3", conc.ρ)); digits=1)
    γc_unit = du.units[:length] == u"ft" ? "pcf" : "kg/m³"
    stress_unit = _ul(du, :stress)

    println(io, "  MATERIALS")
    Printf.@printf(io, "    Concrete: f'c = %.0f %s, γc = %.1f %s, Ec = %.0f %s\n",
                   fc_val, stress_unit, γc_val, γc_unit, Ec_val, stress_unit)
    Printf.@printf(io, "    Rebar:    fy  = %.0f %s, Es = %.0f %s\n",
                   fy_val, stress_unit, Es_val, stress_unit)

    steel_mat = _resolve_steel_material(params)
    if !isnothing(steel_mat)
        Fy_val = _to_report(du, :stress, steel_mat.Fy; digits=0)
        E_val  = _to_report(du, :stress, steel_mat.E; digits=0)
        Printf.@printf(io, "    Steel:    Fy  = %.0f %s, Es = %.0f %s\n", Fy_val, stress_unit, E_val, stress_unit)
    end
    println(io)

    # Loads
    press_unit = _ul(du, :pressure)
    println(io, "  UNFACTORED LOADS")
    Printf.@printf(io, "    Live load (floor):   %6.1f %s\n", _to_report(du, :pressure, loads.floor_LL; digits=1), press_unit)
    Printf.@printf(io, "    Live load (roof):    %6.1f %s\n", _to_report(du, :pressure, loads.roof_LL; digits=1), press_unit)
    Printf.@printf(io, "    Superimposed dead:   %6.1f %s\n", _to_report(du, :pressure, loads.floor_SDL; digits=1), press_unit)
    println(io)

    # Building geometry
    n_stories = length(struc.skeleton.stories)
    n_slabs = length(struc.slabs)
    n_cols  = length(struc.columns)
    n_beams = length(struc.beams)
    n_fdns  = length(struc.foundations)

    println(io, "  BUILDING")
    Printf.@printf(io, "    Stories: %d,  Slabs: %d,  Columns: %d,  Beams: %d,  Foundations: %d\n",
                   n_stories, n_slabs, n_cols, n_beams, n_fdns)

    # Floor system
    floor = params.floor
    if !isnothing(floor)
        println(io, "    Floor system: $(typeof(floor).name.name)")
    end

    # Member types
    col_type = _column_type_label(params)
    beam_type = _beam_type_label(params)
    if !isempty(col_type) || !isempty(beam_type)
        parts = String[]
        !isempty(col_type) && push!(parts, "Columns: $col_type")
        !isempty(beam_type) && push!(parts, "Beams: $beam_type")
        println(io, "    ", join(parts, ",  "))
    end
    println(io)
end

"""Return the steel material from beam or column options, or nothing."""
function _resolve_steel_material(params::DesignParameters)
    beams = params.beams
    if beams isa SteelBeamOptions
        return beams.material
    end
    cols = params.columns
    if cols isa SteelColumnOptions
        return cols.material
    end
    return nothing
end

"""Human-readable column type label from design parameters."""
function _column_type_label(params::DesignParameters)
    opts = params.columns
    isnothing(opts) && return ""
    opts isa ConcreteColumnOptions && return opts.section_shape == :circular ? "RC Circular" : "RC Rectangular"
    opts isa SteelColumnOptions && return opts.section_type == :hss ? "Steel HSS" : "Steel W-shape"
    return string(typeof(opts).name.name)
end

"""Human-readable beam type label from design parameters."""
function _beam_type_label(params::DesignParameters)
    opts = params.beams
    isnothing(opts) && return ""
    opts isa SteelBeamOptions && return opts.section_type == :hss ? "Steel HSS" : "Steel W-shape"
    opts isa ConcreteBeamOptions && return opts.include_flange ? "RC T-beam" : "RC Rectangular"
    opts isa PixelFrameBeamOptions && return "PixelFrame"
    return string(typeof(opts).name.name)
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. Slabs
# ─────────────────────────────────────────────────────────────────────────────

"""Print slab panel tables, dispatching on floor result type."""
function _report_slabs(io::IO, design::BuildingDesign;
                       conc=resolve_concrete(design.params),
                       reb=resolve_rebar(design.params),
                       du::DisplayUnits=design.params.display_units)
    struc = design.structure

    isempty(struc.slabs) && return

    println(io, section_break("SLAB PANELS"))
    println(io)

    for (s_idx, slab) in enumerate(struc.slabs)
        sr = get(design.slabs, s_idx, nothing)
        isnothing(sr) && continue
        r_raw = sr.sizer_result
        r = r_raw isa Pair ? r_raw.second : r_raw
        isnothing(r) && continue
        _report_slab_panel(io, design, s_idx, slab, r; conc=conc, reb=reb, du=du)
    end
end

# Multiple dispatch routes the right report section for each floor type.
_report_slab_panel(io::IO, design::BuildingDesign, s_idx::Int, slab, r::StructuralSizer.FlatPlatePanelResult; kw...) =
    _report_flat_plate_panel(io, design, s_idx, slab, r; kw...)
_report_slab_panel(io::IO, design::BuildingDesign, s_idx::Int, slab, r::StructuralSizer.VaultResult; kw...) =
    _report_vault_panel(io, design, s_idx, slab, r; kw...)
_report_slab_panel(io::IO, design::BuildingDesign, s_idx::Int, slab, r; kw...) =
    _report_generic_slab(io, design, s_idx, slab, r; kw...)

"""Print a single flat-plate panel: spans, loading breakdown, M₀, reinforcement, punching, and deflection."""
function _report_flat_plate_panel(io::IO, design::BuildingDesign,
                                   s_idx::Int, slab, r;
                                   conc=resolve_concrete(design.params),
                                   reb=resolve_rebar(design.params),
                                   du::DisplayUnits=design.params.display_units)
    struc = design.structure
    loads = design.params.loads

    h = _to_report(du, :thickness, r.thickness; digits=1)
    l1 = _to_report(du, :length, r.l1; digits=1)
    l2 = _to_report(du, :length, r.l2; digits=1)
    ratio = l2 > 0 ? round(l2 / l1; digits=2) : 0.0

    # Effective depth (assume #5 bars, typical cover)
    is_imp = du.units[:length] == u"ft"
    cover_disp = is_imp ? 0.75 : 19.0
    bar_radius_disp = is_imp ? 0.3125 : 8.0
    d = round(h - cover_disp - bar_radius_disp; digits=2)

    # Self-weight from sizer result (includes drop panel contribution for flat slabs)
    w_sw = hasproperty(r, :self_weight) ?
           _to_report(du, :pressure, r.self_weight; digits=1) :
           _to_report(du, :pressure, conc.ρ * 9.80665u"m/s^2" * r.thickness; digits=1)
    w_sdl = _to_report(du, :pressure, loads.floor_SDL; digits=1)
    w_ll  = _to_report(du, :pressure, loads.floor_LL; digits=1)
    qu    = _to_report(du, :pressure, r.qu; digits=1)
    M0    = _to_report(du, :moment, r.M0; digits=1)

    slab_area = sum(struc.cells[ci].area for ci in slab.cell_indices)
    area_val = _to_report(du, :area, slab_area; digits=0)
    len_u = _ul(du, :length)
    thick_u = _ul(du, :thickness)
    area_u = _ul(du, :area)
    press_u = _ul(du, :pressure)
    mom_u = _ul(du, :moment)

    println(io, "  ┌─ Panel S-$(s_idx) ─────────────────────────────────────────────────")
    Printf.@printf(io, "  │  Spans: l₁ = %.1f %s, l₂ = %.1f %s  (l₂/l₁ = %.2f)\n", l1, len_u, l2, len_u, ratio)
    Printf.@printf(io, "  │  h = %.1f %s, d = %.2f %s\n", h, thick_u, d, thick_u)
    Printf.@printf(io, "  │  Area: %.0f %s\n", area_val, area_u)
    println(io, "  │")

    Printf.@printf(io, "  │  %-22s %8s\n", "Load Component", press_u)
    Printf.@printf(io, "  │  %-22s %8s\n", "──────────────────────", "────────")
    Printf.@printf(io, "  │  %-22s %8.1f\n", "Self-weight", w_sw)
    Printf.@printf(io, "  │  %-22s %8.1f\n", "Superimposed dead", w_sdl)
    Printf.@printf(io, "  │  %-22s %8.1f\n", "Live load", w_ll)
    Printf.@printf(io, "  │  %-22s %8s\n", "──────────────────────", "────────")
    Printf.@printf(io, "  │  %-22s %8.1f   (1.2D + 1.6L factored)\n", "qu (factored)", qu)
    println(io, "  │")
    Printf.@printf(io, "  │  M₀ (total static moment) = %.1f %s\n", M0, mom_u)
    println(io, "  │")

    _report_slab_reinforcement(io, r, h, d; du=du)
    _report_slab_punching(io, struc, r, h, d; conc=conc, du=du)
    _report_slab_deflection(io, r, l1; du=du)

    sr = get(design.slabs, s_idx, nothing)
    dp = isnothing(sr) ? nothing : sr.drop_panel
    if !isnothing(dp)
        h_drop = _to_report(du, :thickness, dp.h_drop; digits=1)
        a1 = _to_report(du, :length, 2 * dp.a_drop_1; digits=1)
        a2 = _to_report(du, :length, 2 * dp.a_drop_2; digits=1)
        println(io, "  │  DROP PANEL")
        Printf.@printf(io, "  │  Extra depth: %.1f %s,  Plan: %.1f × %.1f %s\n",
                       h_drop, thick_u, a1, a2, len_u)
        println(io, "  │")
    end

    println(io, "  └──────────────────────────────────────────────────────────────")
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 2b. Vault panels
# ─────────────────────────────────────────────────────────────────────────────

"""Print a vault panel: geometry, thrust, stress/deflection/convergence checks."""
function _report_vault_panel(io::IO, design::BuildingDesign,
                              s_idx::Int, slab, r::StructuralSizer.VaultResult;
                              conc=resolve_concrete(design.params),
                              reb=resolve_rebar(design.params),
                              du::DisplayUnits=design.params.display_units)
    struc = design.structure

    h = _to_report(du, :thickness, r.thickness; digits=1)
    rise = _to_report(du, :length, r.rise; digits=2)
    arc = _to_report(du, :length, r.arc_length; digits=1)
    span = hasproperty(slab, :spans) && !isnothing(slab.spans) ?
           _to_report(du, :length, slab.spans.isotropic * u"m"; digits=1) : 0.0
    λ = rise > 0 ? round(span / rise; digits=1) : 0.0

    slab_area = sum(struc.cells[ci].area for ci in slab.cell_indices)
    area_val = _to_report(du, :area, slab_area; digits=0)
    len_u = _ul(du, :length)
    thick_u = _ul(du, :thickness)
    area_u = _ul(du, :area)
    thrust_u = _ul(du, :thrust)
    stress_u = _ul(du, :stress)
    defl_u = _ul(du, :deflection)

    println(io, "  ┌─ Vault V-$(s_idx) ─────────────────────────────────────────────────")
    Printf.@printf(io, "  │  Span: %.1f %s,  Rise: %.2f %s  (λ = span/rise = %.1f)\n", span, len_u, rise, len_u, λ)
    Printf.@printf(io, "  │  Shell thickness: %.1f %s,  Arc length: %.1f %s\n", h, thick_u, arc, len_u)
    Printf.@printf(io, "  │  Plan area: %.0f %s\n", area_val, area_u)
    println(io, "  │")

    H_dead = _to_report_thrust(du, r.thrust_dead; digits=2)
    H_live = _to_report_thrust(du, r.thrust_live; digits=2)
    H_total = _to_report_thrust(du, StructuralSizer.total_thrust(r); digits=2)
    println(io, "  │  THRUST (horizontal, per unit width)")
    Printf.@printf(io, "  │    Dead: %.2f %s,  Live: %.2f %s,  Total: %.2f %s\n",
                   H_dead, thrust_u, H_live, thrust_u, H_total, thrust_u)
    println(io, "  │")

    sc = r.stress_check
    # stress_check stores σ and σ_allow in MPa (raw Float64)
    σ_val = _to_report(du, :stress, sc.σ * u"MPa"; digits=2)
    σ_allow_val = _to_report(du, :stress, sc.σ_allow * u"MPa"; digits=2)
    stress_label = _ul(du, :stress)
    println(io, "  │  STRESS CHECK")
    Printf.@printf(io, "  │    σ_max = %.2f %s,  σ_allow = %.2f %s,  Ratio = %.2f  %s\n",
                   σ_val, stress_label, σ_allow_val, stress_label, sc.ratio, pass_fail(sc.ok))
    Printf.@printf(io, "  │    Governing case: %s\n", string(r.governing_case))
    println(io, "  │")

    dc = r.deflection_check
    δ_val = _to_report(du, :deflection, dc.δ * u"m"; digits=3)
    lim_val = _to_report(du, :deflection, dc.limit * u"m"; digits=3)
    println(io, "  │  DEFLECTION CHECK")
    Printf.@printf(io, "  │    δ = %.3f %s,  Limit = %.3f %s,  Ratio = %.2f  %s\n",
                   δ_val, defl_u, lim_val, defl_u, dc.ratio, pass_fail(dc.ok))
    println(io, "  │")

    cc = r.convergence_check
    println(io, "  │  CONVERGENCE")
    Printf.@printf(io, "  │    Converged: %s,  Iterations: %d\n",
                   pass_fail(cc.converged), cc.iterations)
    println(io, "  │")

    println(io, "  └──────────────────────────────────────────────────────────────")
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 2c. Generic / one-way slabs
# ─────────────────────────────────────────────────────────────────────────────

"""Print a generic slab panel (one-way or other CIP): thickness, self-weight, basic checks."""
function _report_generic_slab(io::IO, design::BuildingDesign,
                               s_idx::Int, slab, r;
                               conc=resolve_concrete(design.params),
                               reb=resolve_rebar(design.params),
                               du::DisplayUnits=design.params.display_units)
    struc = design.structure
    slab_area = sum(struc.cells[ci].area for ci in slab.cell_indices)

    floor_type = string(slab.floor_type)
    h = hasproperty(r, :thickness) ? _to_report(du, :thickness, r.thickness; digits=1) : 0.0
    area_val = _to_report(du, :area, slab_area; digits=0)
    thick_u = _ul(du, :thickness)
    area_u = _ul(du, :area)
    press_u = _ul(du, :pressure)

    println(io, "  ┌─ Slab S-$(s_idx) ($(floor_type)) ──────────────────────────────────")
    Printf.@printf(io, "  │  Thickness: %.1f %s\n", h, thick_u)
    Printf.@printf(io, "  │  Plan area: %.0f %s\n", area_val, area_u)

    if hasproperty(r, :self_weight)
        sw = _to_report(du, :pressure, r.self_weight; digits=1)
        Printf.@printf(io, "  │  Self-weight: %.1f %s\n", sw, press_u)
    end
    println(io, "  │")

    # Check SlabDesignResult for summary ratios
    slab_dr = get(design.slabs, s_idx, nothing)
    if !isnothing(slab_dr)
        if slab_dr.deflection_ratio > 0
            Printf.@printf(io, "  │  Deflection ratio: %.2f  %s\n",
                           slab_dr.deflection_ratio, pass_fail(slab_dr.deflection_ok))
        end
        if slab_dr.punching_max_ratio > 0
            Printf.@printf(io, "  │  Punching ratio:   %.2f  %s\n",
                           slab_dr.punching_max_ratio, pass_fail(slab_dr.punching_ok))
        end
        println(io, "  │")
    end

    println(io, "  └──────────────────────────────────────────────────────────────")
    println(io)
end

"""Print the reinforcement schedule table for column and middle strips."""
function _report_slab_reinforcement(io::IO, r, h, d; du::DisplayUnits=imperial)
    thick_u = _ul(du, :thickness)
    mom_u = _ul(du, :moment)
    area_u = _ul(du, :rebar_area)
    spac_u = _ul(du, :spacing)
    println(io, "  │  REINFORCEMENT  (h = $(h) $thick_u, d = $(d) $thick_u)")
    Printf.@printf(io, "  │  %-13s %-8s %8s %11s %11s %4s %5s %3s %12s %5s\n",
        "Strip", "Location", "Mu($mom_u)", "As_req($area_u)", "As_min($area_u)",
        "Bar", "s($spac_u)", "n", "As_prov($area_u)", "Ratio")
    Printf.@printf(io, "  │  %-13s %-8s %8s %11s %11s %4s %5s %3s %12s %5s\n",
        "─"^13, "─"^8, "─"^8, "─"^11, "─"^11, "─"^4, "─"^5, "─"^3, "─"^12, "─"^5)

    for sr in r.column_strip_reinf
        _print_reinf_row(io, "Col. strip", sr; du=du)
    end
    for sr in r.middle_strip_reinf
        _print_reinf_row(io, "Mid. strip", sr; du=du)
    end
    println(io, "  │")
end

"""Print one row of the reinforcement schedule (Mu, As_req, bar size, spacing, As_provided)."""
function _print_reinf_row(io::IO, strip_name::String, sr; du::DisplayUnits=imperial)
    loc = string(sr.location)
    Mu_val = _to_report(du, :moment, sr.Mu; digits=1)
    As_req = _to_report(du, :rebar_area, sr.As_reqd; digits=3)
    As_min = _to_report(du, :rebar_area, sr.As_min; digits=3)
    As_prov = _to_report(du, :rebar_area, sr.As_provided; digits=3)
    bar_str = "#$(sr.bar_size)"
    s_val = _to_report(du, :spacing, sr.spacing; digits=1)
    n_bars = sr.n_bars
    ratio = As_prov > 0 ? round(As_req / As_prov; digits=2) : 0.0

    Printf.@printf(io, "  │  %-13s %-8s %8.1f %11.3f %11.3f %4s %5.1f %3d %12.3f %5.2f\n",
        strip_name, loc, Mu_val, As_req, As_min, bar_str, s_val, n_bars, As_prov, ratio)
end

"""Print the punching shear schedule per column (b₀, vu, φvc, stud requirement)."""
function _report_slab_punching(io::IO, struc, r, h, d; conc, du::DisplayUnits=imperial)
    pc = r.punching_check
    isempty(pc.details) && return

    is_imp = du.units[:stress] == ksi
    fc_val = is_imp ? round(Int, ustrip(u"psi", conc.fc′)) : round(_to_report(du, :stress, conc.fc′); digits=1)
    stress_u = is_imp ? "psi" : "MPa"
    thick_u = _ul(du, :thickness)

    println(io, "  │  PUNCHING SHEAR  (h = $(h) $thick_u, d = $(d) $thick_u, f'c = $fc_val $stress_u)")
    Printf.@printf(io, "  │  %-6s %10s %10s %10s %10s %10s %6s %6s\n",
        "Col", "Position", "b₀($thick_u)", "vu($stress_u)", "φvc($stress_u)", "Ratio", "Studs", "OK?")
    Printf.@printf(io, "  │  %-6s %10s %10s %10s %10s %10s %6s %6s\n",
        "─"^6, "─"^10, "─"^10, "─"^10, "─"^10, "─"^10, "─"^6, "─"^6)

    for (col_idx, pr) in sort(collect(pc.details); by=first)
        b0_val = _to_report(du, :thickness, pr.b0; digits=1)
        vu_val = du.units[:stress] == ksi ? round(ustrip(u"psi", pr.vu); digits=1) : round(ustrip(u"MPa", pr.vu); digits=1)
        φvc_val = du.units[:stress] == ksi ? round(ustrip(u"psi", pr.φvc); digits=1) : round(ustrip(u"MPa", pr.φvc); digits=1)
        ratio = round(pr.ratio; digits=2)
        has_studs = hasproperty(pr, :studs) && !isnothing(pr.studs) && pr.studs.required
        stud_str = has_studs ? "Yes" : "No"

        pos_str = "—"
        if col_idx >= 1 && col_idx <= length(struc.columns)
            c = struc.columns[col_idx]
            hasproperty(c, :position) && (pos_str = string(c.position))
        end

        Printf.@printf(io, "  │  C-%-3d %10s %10.1f %10.1f %10.1f %10.2f %6s %6s\n",
            col_idx, pos_str, b0_val, vu_val, φvc_val, ratio, stud_str, pass_fail(pr.ok))
    end

    Printf.@printf(io, "  │  Overall: max ratio = %.2f  %s\n", pc.max_ratio, pass_fail(pc.ok))
    println(io, "  │")
end

"""Print the slab deflection check table (Δ, limit, L/Δ, long-term total)."""
function _report_slab_deflection(io::IO, r, l1; du::DisplayUnits=imperial)
    dc = r.deflection_check
    hasproperty(dc, :Δ_check) || return

    Δ_val = _to_report(du, :deflection, dc.Δ_check; digits=3)
    Δ_lim = _to_report(du, :deflection, dc.Δ_limit; digits=3)
    defl_u = _ul(du, :deflection)
    # L in same length unit as l1 for L/Δ ratio
    L_disp = l1 * (du.units[:length] == u"ft" ? 12.0 : 1000.0)  # ft→in or m→mm
    L_over_Δ = Δ_val > 0 ? round(Int, L_disp / Δ_val) : 99999

    println(io, "  │  DEFLECTION")
    Printf.@printf(io, "  │  %-20s %8s %8s %8s %12s %4s\n",
        "Check", "Δ($defl_u)", "Limit", "L/Δ", "Criterion", "OK?")
    Printf.@printf(io, "  │  %-20s %8s %8s %8s %12s %4s\n",
        "─"^20, "─"^8, "─"^8, "─"^8, "─"^12, "─"^4)
    Printf.@printf(io, "  │  %-20s %8.3f %8.3f %8d %12s %4s\n",
        "Deflection check", Δ_val, Δ_lim, L_over_Δ, "L/360", pass_fail(dc.ok))

    if hasproperty(dc, :Δ_total) && !isnothing(dc.Δ_total)
        Δ_tot = _to_report(du, :deflection, dc.Δ_total; digits=3)
        Δ_tlim = round(L_disp / 240.0; digits=3)
        L_Δ_t = Δ_tot > 0 ? round(Int, L_disp / Δ_tot) : 99999
        Printf.@printf(io, "  │  %-20s %8.3f %8.3f %8d %12s %4s\n",
            "Long-term total", Δ_tot, Δ_tlim, L_Δ_t, "L/240", pass_fail(Δ_tot ≤ Δ_tlim))
    end
    println(io, "  │")
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. Beams
# ─────────────────────────────────────────────────────────────────────────────

"""Return true if the structure uses a beamless floor system (flat plate / flat slab).
Matches the logic used for visualization (`is_beamless_system` in serialize)."""
function _is_beamless_system(struc)
    isempty(struc.slabs) && return false
    return all(slab -> slab.floor_type in (:flat_plate, :flat_slab), struc.slabs)
end

"""Print the beam schedule (section, demands, flexure/shear ratios). Adapts header to beam type.
For beamless systems (flat plate, flat slab), prints the section heading with 'Not applicable.'."""
function _report_beams(io::IO, design::BuildingDesign; du::DisplayUnits=design.params.display_units)
    params = design.params
    struc = design.structure

    beam_label = _beam_type_label(params)
    section_title = "BEAM SCHEDULE" * (isempty(beam_label) ? "" : " ($beam_label)")
    println(io, section_break(section_title))
    println(io)

    if _is_beamless_system(struc) || isempty(design.beams)
        println(io, "  Not applicable.")
        println(io)
        return
    end

    mom_u = _ul(du, :moment)
    force_u = _ul(du, :force)
    len_u = _ul(du, :length)

    Printf.@printf(io, "  %-5s %-12s %9s %9s %9s %8s %8s %4s\n",
        "Beam", "Section", "Mu($mom_u)", "Vu($force_u)", "L($len_u)", "FlxRat", "ShrRat", "OK?")
    Printf.@printf(io, "  %-5s %-12s %9s %9s %9s %8s %8s %4s\n",
        "─"^5, "─"^12, "─"^9, "─"^9, "─"^9, "─"^8, "─"^8, "─"^4)

    for (beam_idx, br) in sort(collect(design.beams); by=first)
        Mu_val = _to_report(du, :moment, br.Mu; digits=1)
        Vu_val = _to_report(du, :force, br.Vu; digits=1)
        L_val  = _to_report(du, :length, br.member_length; digits=1)

        Printf.@printf(io, "  B-%-2d %-12s %9.1f %9.1f %9.1f %8s %8s %4s\n",
            beam_idx, br.section_size,
            Mu_val, Vu_val, L_val,
            fv(br.flexure_ratio; d=3), fv(br.shear_ratio; d=3), pass_fail(br.ok))
    end
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. Columns
# ─────────────────────────────────────────────────────────────────────────────

"""Print the column schedule (section, loads, axial/P-M/punching ratios). Adapts to steel vs RC."""
function _report_columns(io::IO, design::BuildingDesign;
                         conc=resolve_concrete(design.params),
                         reb=resolve_rebar(design.params),
                         du::DisplayUnits=design.params.display_units)
    struc = design.structure
    params = design.params

    isempty(design.columns) && return

    force_u = _ul(du, :force)
    mom_u = _ul(du, :moment)
    thick_u = _ul(du, :thickness)

    is_steel_col = params.columns isa SteelColumnOptions
    col_label = _column_type_label(params)
    println(io, section_break("COLUMN SCHEDULE" * (isempty(col_label) ? "" : " ($col_label)")))

    if is_steel_col
        steel = params.columns.material
        Fy_val = _to_report(du, :stress, steel.Fy; digits=0)
        Printf.@printf(io, "  Fy = %.0f %s\n", Fy_val, _ul(du, :stress))
    else
        fc_val = _to_report(du, :stress, conc.fc′; digits=0)
        fy_val = _to_report(du, :stress, reb.Fy; digits=0)
        Printf.@printf(io, "  f'c = %.0f %s, fy = %.0f %s\n", fc_val, _ul(du, :stress), fy_val, _ul(du, :stress))

        col_opts = _get_column_opts(params)
        if !isnothing(col_opts)
            shape_con = col_opts.shape_constraint
            max_ar    = col_opts.max_aspect_ratio
            inc_val   = _to_report(du, :thickness, col_opts.size_increment; digits=1)
            Printf.@printf(io, "  Shape: %s, Max AR: %.1f, Increment: %.1f %s\n", shape_con, max_ar, inc_val, thick_u)
        end
    end
    println(io)

    # Detect whether any column is rectangular (c1 ≠ c2) — RC columns only
    has_rect = !is_steel_col && any(cr -> begin
        c1_val = ustrip(du.units[:thickness], cr.c1)
        c2_val = ustrip(du.units[:thickness], cr.c2)
        denom = max(c1_val, c2_val, 1e-6)
        c1_val > 0.1 && c2_val > 0.1 && abs(c1_val - c2_val) / denom > 0.01
    end, values(design.columns))

    defl_u = _ul(du, :deflection)

    # Header — adapts to column type
    if has_rect
        Printf.@printf(io, "  %-5s %5s %-8s %7s %7s %5s %9s %9s %9s %8s %8s %8s %4s\n",
            "Col", "Story", "Position", "c1($thick_u)", "c2($thick_u)", "AR",
            "Pu($force_u)", "Mu($mom_u)", "e($defl_u)", "Axl.Rat", "P-M Rat", "Pun.Rat", "OK?")
        Printf.@printf(io, "  %-5s %5s %-8s %7s %7s %5s %9s %9s %9s %8s %8s %8s %4s\n",
            "─"^5, "─"^5, "─"^8, "─"^7, "─"^7, "─"^5,
            "─"^9, "─"^9, "─"^9, "─"^8, "─"^8, "─"^8, "─"^4)
    else
        Printf.@printf(io, "  %-5s %5s %-8s %-12s %9s %9s %9s %8s %8s %8s %4s\n",
            "Col", "Story", "Position", "Section",
            "Pu($force_u)", "Mu($mom_u)", "e($defl_u)", "Axl.Rat", "P-M Rat", "Pun.Rat", "OK?")
        Printf.@printf(io, "  %-5s %5s %-8s %-12s %9s %9s %9s %8s %8s %8s %4s\n",
            "─"^5, "─"^5, "─"^8, "─"^12,
            "─"^9, "─"^9, "─"^9, "─"^8, "─"^8, "─"^8, "─"^4)
    end

    for (col_idx, cr) in sort(collect(design.columns); by=first)
        Pu_val  = _to_report(du, :force, cr.Pu; digits=1)
        Mu_val  = _to_report(du, :moment, cr.Mu_x; digits=1)

        Pu_strip = ustrip(du.units[:force], cr.Pu)
        e_val = abs(Pu_strip) > 1e-6 ? _to_report(du, :deflection, abs(cr.Mu_x / cr.Pu); digits=1) : 0.0

        story = 0
        pos_str = "—"
        if col_idx >= 1 && col_idx <= length(struc.columns)
            col = struc.columns[col_idx]
            story = hasproperty(col, :story) ? col.story : 0
            pos_str = hasproperty(col, :position) ? string(col.position) : "—"
        end

        punch_str = "—"
        if !isnothing(cr.punching)
            punch_str = fv(cr.punching.ratio; d=2)
        end

        if has_rect
            c1_val = _to_report(du, :thickness, cr.c1; digits=1)
            c2_val = _to_report(du, :thickness, cr.c2; digits=1)
            mn, mx = minmax(c1_val, c2_val)
            ar = mn > 0.1 ? round(mx / mn; digits=2) : 1.0
            Printf.@printf(io, "  C-%-2d %5d %-8s %7.1f %7.1f %5.2f %9.1f %9.1f %9.1f %8s %8s %8s %4s\n",
                col_idx, story, pos_str, c1_val, c2_val, ar,
                Pu_val, Mu_val, e_val,
                fv(cr.axial_ratio; d=3), fv(cr.interaction_ratio; d=3), punch_str, pass_fail(cr.ok))
        else
            Printf.@printf(io, "  C-%-2d %5d %-8s %-12s %9.1f %9.1f %9.1f %8s %8s %8s %4s\n",
                col_idx, story, pos_str, cr.section_size,
                Pu_val, Mu_val, e_val,
                fv(cr.axial_ratio; d=3), fv(cr.interaction_ratio; d=3), punch_str, pass_fail(cr.ok))
        end
    end
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 5. Foundations
# ─────────────────────────────────────────────────────────────────────────────

"""Print the foundation schedule (reactions, dimensions, bearing/punching/flexure ratios)."""
function _report_foundations(io::IO, design::BuildingDesign; du::DisplayUnits=design.params.display_units)
    struc = design.structure
    params = design.params

    isempty(design.foundations) && return

    force_u = _ul(du, :force)
    len_u = _ul(du, :length)
    thick_u = _ul(du, :thickness)
    press_u = _ul(du, :pressure)

    # Try to get soil bearing capacity from params
    qa_str = "—"
    if !isnothing(params.foundation_options)
        soil = params.foundation_options.soil
        qa_val = _to_report(du, :pressure, soil.qa; digits=1)
        qa_str = "$(qa_val) $press_u"
    end

    println(io, section_break("FOUNDATION SCHEDULE"))
    println(io, "  Allowable bearing: $(qa_str)")
    println(io)

    # Build compact group labels from raw group IDs
    sorted_fdns = sort(collect(design.foundations); by=first)
    raw_gids = unique(fr.group_id for (_, fr) in sorted_fdns)
    gid_map = Dict(gid => i for (i, gid) in enumerate(raw_gids))

    # Header
    Printf.@printf(io, "  %-5s %5s %10s %7s %7s %6s %10s %8s %8s %8s %4s\n",
        "Fdn", "Group", "Rxn($force_u)", "B($len_u)", "L($len_u)", "D($thick_u)",
        "q_act($press_u)", "BearRat", "PunRat", "FlxRat", "OK?")
    Printf.@printf(io, "  %-5s %5s %10s %7s %7s %6s %10s %8s %8s %8s %4s\n",
        "─"^5, "─"^5, "─"^10, "─"^7, "─"^7, "─"^6, "─"^10, "─"^8, "─"^8, "─"^8, "─"^4)

    for (fdn_idx, fr) in sorted_fdns
        Rxn_val = _to_report(du, :force, fr.reaction; digits=1)
        B_val   = _to_report(du, :length, fr.width; digits=1)
        L_val   = _to_report(du, :length, fr.length; digits=1)
        D_val   = _to_report(du, :thickness, fr.depth; digits=1)

        # Actual bearing pressure = Reaction / (B × L)
        area = fr.width * fr.length
        q_act_val = ustrip(area) > 1e-12 ? _to_report(du, :pressure, fr.reaction / area; digits=2) : 0.0
        g_label = get(gid_map, fr.group_id, 0)

        Printf.@printf(io, "  F-%-2d %5d %10.1f %7.1f %7.1f %6.1f %10.2f %8s %8s %8s %4s\n",
            fdn_idx, g_label, Rxn_val, B_val, L_val, D_val, q_act_val,
            fv(fr.bearing_ratio; d=2), fv(fr.punching_ratio; d=2),
            fv(fr.flexure_ratio; d=2), pass_fail(fr.ok))
    end
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 6. Material Takeoff
# ─────────────────────────────────────────────────────────────────────────────

"""Print the material takeoff (concrete volumes, floor area, embodied carbon)."""
function _report_takeoff(io::IO, design::BuildingDesign; du::DisplayUnits=design.params.display_units)
    struc = design.structure

    vol_u = _ul(du, :volume)
    area_u = _ul(du, :area)

    println(io, section_break("MATERIAL TAKEOFF"))
    println(io)

    total_slab_conc = 0.0u"m^3"
    total_drop_conc = 0.0u"m^3"
    total_slab_area = 0.0u"m^2"
    for (s_idx, slab) in enumerate(struc.slabs)
        sr = get(design.slabs, s_idx, nothing)
        isnothing(sr) && continue
        r_raw = sr.sizer_result
        r = r_raw isa Pair ? r_raw.second : r_raw
        isnothing(r) && continue
        slab_area = sum(struc.cells[ci].area for ci in slab.cell_indices)
        total_slab_area += slab_area
        if hasproperty(r, :volume_per_area)
            total_slab_conc += r.volume_per_area * slab_area
        elseif hasproperty(r, :thickness)
            total_slab_conc += StructuralSizer.total_depth(r) * slab_area
        end
        # Drop panel concrete — per column, trimmed to slab boundary
        if !isnothing(slab.drop_panel)
            dp = slab.drop_panel
            slab_cells = Set(slab.cell_indices)
            bbox = _slab_bbox_m(struc, slab)
            for (col_idx, col) in enumerate(struc.columns)
                isempty(intersect(col.tributary_cell_indices, slab_cells)) && continue
                v_idx = col.vertex_idx
                (v_idx < 1 || v_idx > length(struc.skeleton.vertices)) && continue
                c = Meshes.coords(struc.skeleton.vertices[v_idx])
                cx = ustrip(u"m", c.x)
                cy = ustrip(u"m", c.y)
                a1_eff, a2_eff = _trimmed_drop_extents_m(dp, cx, cy, bbox)
                total_drop_conc += uconvert(u"m^3", StructuralSizer.drop_panel_concrete_volume(dp, a1_eff, a2_eff))
            end
        end
    end

    total_fdn_conc = 0.0u"m^3"
    for (_, fr) in design.foundations
        total_fdn_conc += fr.concrete_volume
    end

    conc_slab = _to_report(du, :volume, total_slab_conc; digits=1)
    conc_drop = _to_report(du, :volume, total_drop_conc; digits=1)
    conc_fdn  = _to_report(du, :volume, total_fdn_conc; digits=1)
    conc_total = _to_report(du, :volume, total_slab_conc + total_drop_conc + total_fdn_conc; digits=1)
    area_val   = _to_report(du, :area, total_slab_area; digits=0)

    Printf.@printf(io, "  %-16s %12s %14s\n", "System", "Conc.Vol($vol_u)", "Floor Area($area_u)")
    Printf.@printf(io, "  %-16s %12s %14s\n", "─"^16, "─"^12, "─"^14)
    Printf.@printf(io, "  %-16s %12.1f %14.0f\n", "Slabs", conc_slab, area_val)
    if total_drop_conc > 0.0u"m^3"
        Printf.@printf(io, "  %-16s %12.1f %14s\n", "Drop Panels", conc_drop, "—")
    end
    Printf.@printf(io, "  %-16s %12.1f %14s\n", "Foundations", conc_fdn, "—")
    Printf.@printf(io, "  %-16s %12s %14s\n", "─"^16, "─"^12, "─"^14)
    Printf.@printf(io, "  %-16s %12.1f\n", "TOTAL", conc_total)
    println(io)

    # Embodied carbon — use `design.summary` (same TOTAL as API; breakdown stored at capture with `compute_building_ec`)
    s = design.summary
    ec_total = s.embodied_carbon
    if ec_total > 0.0
        sub_sum = s.embodied_carbon_slabs + s.embodied_carbon_columns + s.embodied_carbon_beams +
                  s.embodied_carbon_struts + s.embodied_carbon_foundations + s.embodied_carbon_fireproofing
        # Designs captured before per-system fields existed: all breakdown zeros but total set.
        if sub_sum <= 1e-9
            Printf.@printf(io, "  Embodied carbon:  %.0f kgCO₂e (per-system breakdown unavailable for this design)\n", ec_total)
        else
            println(io, "  Embodied carbon (kgCO₂e)")
            Printf.@printf(io, "  %-20s %12.0f\n", "Slabs", s.embodied_carbon_slabs)
            Printf.@printf(io, "  %-20s %12.0f\n", "Columns", s.embodied_carbon_columns)
            Printf.@printf(io, "  %-20s %12.0f\n", "Beams", s.embodied_carbon_beams)
            if s.embodied_carbon_struts > 0.0
                Printf.@printf(io, "  %-20s %12.0f\n", "Struts", s.embodied_carbon_struts)
            end
            Printf.@printf(io, "  %-20s %12.0f\n", "Foundations", s.embodied_carbon_foundations)
            if s.embodied_carbon_fireproofing > 0.0
                Printf.@printf(io, "  %-20s %12.0f\n", "Fireproofing", s.embodied_carbon_fireproofing)
            end
            Printf.@printf(io, "  %-20s %12s\n", "─"^18, "─"^12)
            Printf.@printf(io, "  %-20s %12.0f\n", "TOTAL", ec_total)
        end
        area_m2 = ustrip(u"m^2", total_slab_area)
        if area_m2 > 0
            Printf.@printf(io, "  EC intensity (floor): %.1f kgCO₂e/m²\n", ec_total / area_m2)
        end
    end
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 7. Overall Status
# ─────────────────────────────────────────────────────────────────────────────

"""Print the overall pass/fail status and critical element."""
function _report_status(io::IO, design::BuildingDesign)
    s = design.summary

    println(io, section_break("STATUS"))
    println(io, "  All checks pass: $(pass_fail(s.all_checks_pass))")
    if !isempty(s.critical_element)
        Printf.@printf(io, "  Critical element: %s  (ratio = %.3f)\n",
                       s.critical_element, s.critical_ratio)
    end
    println(io, "═"^90)
end
