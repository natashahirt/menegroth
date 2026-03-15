# =============================================================================
# Engineering Report
# =============================================================================
# Dense, numbers-focused report for structural design review.
# One function call: engineering_report(design) prints all tables.
#
# Tables:
#   1. Design header (name, materials, loads)
#   2. Slab panel schedule (geometry, loading, M₀)
#   3. Slab reinforcement schedule (per strip, per panel)
#   4. Punching shear schedule (per column, per panel)
#   5. Slab deflection checks
#   6. Column schedule
#   7. Foundation schedule
#   8. Material takeoff + embodied carbon
# =============================================================================

"""
    engineering_report(design::BuildingDesign; io::IO=stdout)

Print a dense engineering report summarizing the design.
All relevant inputs and outputs are stated; no hidden assumptions.
"""
function engineering_report(design::BuildingDesign; io::IO=stdout)
    struc = design.structure
    params = design.params
    du = params.display_units

    conc = resolve_concrete(params)
    reb  = resolve_rebar(params)

    _report_header(io, design; conc=conc, reb=reb)
    _report_slabs(io, design; conc=conc, reb=reb)
    _report_columns(io, design; conc=conc, reb=reb)
    _report_foundations(io, design)
    _report_takeoff(io, design)
    _report_status(io, design)
end

# ─────────────────────────────────────────────────────────────────────────────
# 1. Header
# ─────────────────────────────────────────────────────────────────────────────

"""Print the report header: timestamp, materials, unfactored loads, and building geometry."""
function _report_header(io::IO, design::BuildingDesign;
                        conc=resolve_concrete(design.params),
                        reb=resolve_rebar(design.params))
    params = design.params
    struc = design.structure
    du = params.display_units
    loads = params.loads

    println(io, section_break("ENGINEERING REPORT: $(params.name)"))
    println(io, "  Generated: $(Dates.format(design.created, "yyyy-mm-dd HH:MM"))")
    println(io, "  Compute time: $(round(design.compute_time_s; digits=2))s")
    println(io)
    fc_psi = round(ustrip(u"psi", conc.fc′); digits=0)
    fy_ksi = round(ustrip(ksi, reb.Fy); digits=0)
    γc_pcf = round(ustrip(pcf, conc.ρ); digits=1)

    println(io, "  MATERIALS")
    Printf.@printf(io, "    Concrete: f'c = %.0f psi, γc = %.1f pcf, Ec = %.0f ksi\n",
                   fc_psi, γc_pcf, round(ustrip(ksi, StructuralSizer.Ec(conc)); digits=0))
    Printf.@printf(io, "    Rebar:    fy  = %.0f ksi, Es = %.0f ksi\n",
                   fy_ksi, round(ustrip(ksi, reb.E); digits=0))
    println(io)

    # Loads
    println(io, "  UNFACTORED LOADS")
    Printf.@printf(io, "    Live load (floor):   %6.1f psf\n", ustrip(psf, loads.floor_LL))
    Printf.@printf(io, "    Live load (roof):    %6.1f psf\n", ustrip(psf, loads.roof_LL))
    Printf.@printf(io, "    Superimposed dead:   %6.1f psf\n", ustrip(psf, loads.floor_SDL))
    println(io)

    # Building geometry
    n_stories = length(struc.skeleton.stories)
    n_slabs = length(struc.slabs)
    n_cols  = length(struc.columns)
    n_fdns  = length(struc.foundations)

    println(io, "  BUILDING")
    Printf.@printf(io, "    Stories: %d,  Slabs: %d,  Columns: %d,  Foundations: %d\n",
                   n_stories, n_slabs, n_cols, n_fdns)

    # Floor system
    floor = params.floor
    if !isnothing(floor)
        println(io, "    Floor system: $(typeof(floor).name.name)")
    end
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. Slabs
# ─────────────────────────────────────────────────────────────────────────────

"""Print slab panel tables (geometry, loading, reinforcement, punching, deflection)."""
function _report_slabs(io::IO, design::BuildingDesign;
                       conc=resolve_concrete(design.params),
                       reb=resolve_rebar(design.params))
    struc = design.structure
    params = design.params
    du = params.display_units
    loads = params.loads

    isempty(struc.slabs) && return

    γc_pcf = ustrip(pcf, conc.ρ)

    println(io, section_break("SLAB PANELS"))
    println(io)

    for (s_idx, slab) in enumerate(struc.slabs)
        r = slab.result
        r isa StructuralSizer.FlatPlatePanelResult || continue

        _report_flat_plate_panel(io, design, s_idx, slab, r; conc=conc, reb=reb)
    end
end

"""Print a single flat-plate panel: spans, loading breakdown, M₀, reinforcement, punching, and deflection."""
function _report_flat_plate_panel(io::IO, design::BuildingDesign,
                                   s_idx::Int, slab, r;
                                   conc=resolve_concrete(design.params),
                                   reb=resolve_rebar(design.params))
    struc = design.structure
    params = design.params
    du = params.display_units
    loads = params.loads

    γc_pcf = ustrip(pcf, conc.ρ)
    fc_psi = round(ustrip(u"psi", conc.fc′); digits=0)

    h_in   = round(ustrip(u"inch", r.thickness); digits=1)
    l1_ft  = round(ustrip(u"ft", r.l1); digits=1)
    l2_ft  = round(ustrip(u"ft", r.l2); digits=1)
    ratio  = l2_ft > 0 ? round(l2_ft / l1_ft; digits=2) : 0.0

    # Effective depth (assume #5 bars, 0.75" cover as typical)
    bar_dia = 0.625  # #5
    d_in = round(h_in - 0.75 - bar_dia / 2; digits=2)

    # Loading breakdown
    w_sw_psf  = round(h_in / 12.0 * γc_pcf; digits=1)
    w_sdl_psf = round(ustrip(psf, loads.floor_SDL); digits=1)
    w_ll_psf  = round(ustrip(psf, loads.floor_LL); digits=1)
    qu_psf    = round(ustrip(psf, r.qu); digits=1)
    M0_kipft  = round(ustrip(kip * u"ft", r.M0); digits=1)

    # Slab area
    slab_area = sum(struc.cells[ci].area for ci in slab.cell_indices)

    # ── Panel geometry & loading table ──
    println(io, "  ┌─ Panel S-$(s_idx) ─────────────────────────────────────────────────")
    Printf.@printf(io, "  │  Spans: l₁ = %.1f ft, l₂ = %.1f ft  (l₂/l₁ = %.2f)\n", l1_ft, l2_ft, ratio)
    Printf.@printf(io, "  │  h = %.1f in, d = %.2f in  (cover = 0.75 in, #5 bars)\n", h_in, d_in)
    Printf.@printf(io, "  │  Area: %.0f ft²\n", ustrip(u"ft^2", slab_area))
    println(io, "  │")

    Printf.@printf(io, "  │  %-22s %8s\n", "Load Component", "psf")
    Printf.@printf(io, "  │  %-22s %8s\n", "──────────────────────", "────────")
    Printf.@printf(io, "  │  %-22s %8.1f   (h × γc = %.1f\" × %.1f pcf / 12)\n",
                   "Self-weight", w_sw_psf, h_in, γc_pcf)
    Printf.@printf(io, "  │  %-22s %8.1f\n", "Superimposed dead", w_sdl_psf)
    Printf.@printf(io, "  │  %-22s %8.1f\n", "Live load", w_ll_psf)
    Printf.@printf(io, "  │  %-22s %8s\n", "──────────────────────", "────────")
    Printf.@printf(io, "  │  %-22s %8.1f   (1.2D + 1.6L factored)\n", "qu (factored)", qu_psf)
    println(io, "  │")
    Printf.@printf(io, "  │  M₀ (total static moment) = %.1f kip·ft\n", M0_kipft)
    println(io, "  │")

    # ── Reinforcement schedule ──
    _report_slab_reinforcement(io, r, h_in, d_in)

    # ── Punching shear ──
    _report_slab_punching(io, struc, r, h_in, d_in, fc_psi)

    # ── Deflection ──
    _report_slab_deflection(io, r, l1_ft)

    println(io, "  └──────────────────────────────────────────────────────────────")
    println(io)
end

"""Print the reinforcement schedule table for column and middle strips."""
function _report_slab_reinforcement(io::IO, r, h_in, d_in)
    println(io, "  │  REINFORCEMENT  (h = $(h_in) in, d = $(d_in) in)")
    Printf.@printf(io, "  │  %-13s %-8s %8s %11s %11s %4s %5s %3s %12s %5s\n",
        "Strip", "Location", "Mu(k·ft)", "As_req(in²)", "As_min(in²)",
        "Bar", "s(in)", "n", "As_prov(in²)", "Ratio")
    Printf.@printf(io, "  │  %-13s %-8s %8s %11s %11s %4s %5s %3s %12s %5s\n",
        "─"^13, "─"^8, "─"^8, "─"^11, "─"^11, "─"^4, "─"^5, "─"^3, "─"^12, "─"^5)

    # Column strip
    for sr in r.column_strip_reinf
        _print_reinf_row(io, "Col. strip", sr)
    end
    # Middle strip
    for sr in r.middle_strip_reinf
        _print_reinf_row(io, "Mid. strip", sr)
    end
    println(io, "  │")
end

"""Print one row of the reinforcement schedule (Mu, As_req, bar size, spacing, As_provided)."""
function _print_reinf_row(io::IO, strip_name::String, sr)
    loc = string(sr.location)
    Mu_kipft = round(ustrip(kip * u"ft", sr.Mu); digits=1)
    As_req   = round(ustrip(u"inch^2", sr.As_reqd); digits=3)
    As_min   = round(ustrip(u"inch^2", sr.As_min); digits=3)
    As_prov  = round(ustrip(u"inch^2", sr.As_provided); digits=3)
    bar_str  = "#$(sr.bar_size)"
    s_in     = round(ustrip(u"inch", sr.spacing); digits=1)
    n_bars   = sr.n_bars
    ratio    = As_prov > 0 ? round(As_req / As_prov; digits=2) : 0.0

    Printf.@printf(io, "  │  %-13s %-8s %8.1f %11.3f %11.3f %4s %5.1f %3d %12.3f %5.2f\n",
        strip_name, loc, Mu_kipft, As_req, As_min, bar_str, s_in, n_bars, As_prov, ratio)
end

"""Print the punching shear schedule per column (b₀, vu, φvc, stud requirement)."""
function _report_slab_punching(io::IO, struc, r, h_in, d_in, fc_psi)
    pc = r.punching_check
    isempty(pc.details) && return

    println(io, "  │  PUNCHING SHEAR  (h = $(h_in) in, d = $(d_in) in, f'c = $(round(Int, fc_psi)) psi)")
    Printf.@printf(io, "  │  %-6s %10s %10s %10s %10s %10s %6s %6s\n",
        "Col", "Position", "b₀(in)", "vu(psi)", "φvc(psi)", "Ratio", "Studs", "OK?")
    Printf.@printf(io, "  │  %-6s %10s %10s %10s %10s %10s %6s %6s\n",
        "─"^6, "─"^10, "─"^10, "─"^10, "─"^10, "─"^10, "─"^6, "─"^6)

    for (col_idx, pr) in sort(collect(pc.details); by=first)
        b0_in = round(ustrip(u"inch", pr.b0); digits=1)
        vu_psi = round(ustrip(u"psi", pr.vu); digits=1)
        φvc_psi = round(ustrip(u"psi", pr.φvc); digits=1)
        ratio = round(pr.ratio; digits=2)
        has_studs = hasproperty(pr, :studs) && !isnothing(pr.studs) && pr.studs.required
        stud_str = has_studs ? "Yes" : "No"

        # Get column position from structure
        pos_str = "—"
        if col_idx ≤ length(struc.columns)
            try
                pos_str = string(struc.columns[col_idx].position)
            catch; end
        end

        Printf.@printf(io, "  │  C-%-3d %10s %10.1f %10.1f %10.1f %10.2f %6s %6s\n",
            col_idx, pos_str, b0_in, vu_psi, φvc_psi, ratio, stud_str, pass_fail(pr.ok))
    end

    Printf.@printf(io, "  │  Overall: max ratio = %.2f  %s\n", pc.max_ratio, pass_fail(pc.ok))
    println(io, "  │")
end

"""Print the slab deflection check table (Δ, limit, L/Δ, long-term total)."""
function _report_slab_deflection(io::IO, r, l1_ft)
    dc = r.deflection_check
    hasproperty(dc, :Δ_check) || return

    Δ_in   = round(ustrip(u"inch", dc.Δ_check); digits=3)
    Δ_lim  = round(ustrip(u"inch", dc.Δ_limit); digits=3)
    L_in   = l1_ft * 12.0
    L_over_Δ = Δ_in > 0 ? round(Int, L_in / Δ_in) : 99999

    println(io, "  │  DEFLECTION")
    Printf.@printf(io, "  │  %-20s %8s %8s %8s %12s %4s\n",
        "Check", "Δ(in)", "Limit", "L/Δ", "Criterion", "OK?")
    Printf.@printf(io, "  │  %-20s %8s %8s %8s %12s %4s\n",
        "─"^20, "─"^8, "─"^8, "─"^8, "─"^12, "─"^4)
    Printf.@printf(io, "  │  %-20s %8.3f %8.3f %8d %12s %4s\n",
        "Deflection check", Δ_in, Δ_lim, L_over_Δ, "L/360", pass_fail(dc.ok))

    if hasproperty(dc, :Δ_total) && !isnothing(dc.Δ_total)
        Δ_tot  = round(ustrip(u"inch", dc.Δ_total); digits=3)
        Δ_tlim = round(L_in / 240.0; digits=3)
        L_Δ_t  = Δ_tot > 0 ? round(Int, L_in / Δ_tot) : 99999
        Printf.@printf(io, "  │  %-20s %8.3f %8.3f %8d %12s %4s\n",
            "Long-term total", Δ_tot, Δ_tlim, L_Δ_t, "L/240", pass_fail(Δ_tot ≤ Δ_tlim))
    end
    println(io, "  │")
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. Columns
# ─────────────────────────────────────────────────────────────────────────────

"""Print the column schedule (section, loads, axial/P-M/punching ratios)."""
function _report_columns(io::IO, design::BuildingDesign;
                         conc=resolve_concrete(design.params),
                         reb=resolve_rebar(design.params))
    struc = design.structure
    params = design.params
    du = params.display_units

    isempty(design.columns) && return
    fc_psi = round(ustrip(u"psi", conc.fc′); digits=0)
    fy_ksi = round(ustrip(ksi, reb.Fy); digits=0)

    # Shape constraint summary (from column options if available)
    col_opts = _get_column_opts(params)
    shape_con = !isnothing(col_opts) ? col_opts.shape_constraint : :square
    max_ar    = !isnothing(col_opts) ? col_opts.max_aspect_ratio : 2.0
    inc_in    = !isnothing(col_opts) ? round(ustrip(u"inch", col_opts.size_increment); digits=1) : 0.5

    println(io, section_break("COLUMN SCHEDULE"))
    Printf.@printf(io, "  f'c = %.0f psi, fy = %.0f ksi\n", fc_psi, fy_ksi)
    Printf.@printf(io, "  Shape: %s, Max AR: %.1f, Increment: %.1f in\n", shape_con, max_ar, inc_in)
    println(io)

    # Detect whether any column is rectangular (c1 ≠ c2)
    has_rect = any(cr -> begin
        c1_in = ustrip(u"inch", cr.c1)
        c2_in = ustrip(u"inch", cr.c2)
        c1_in > 0.1 && c2_in > 0.1 && abs(c1_in - c2_in) > 0.1
    end, values(design.columns))

    # Header — wider table when rectangular columns present
    if has_rect
        Printf.@printf(io, "  %-5s %5s %-8s %7s %7s %5s %9s %9s %9s %8s %8s %8s %4s\n",
            "Col", "Story", "Position", "c1(in)", "c2(in)", "AR",
            "Pu(kip)", "Mu(k·ft)", "e(in)", "Axl.Rat", "P-M Rat", "Pun.Rat", "OK?")
        Printf.@printf(io, "  %-5s %5s %-8s %7s %7s %5s %9s %9s %9s %8s %8s %8s %4s\n",
            "─"^5, "─"^5, "─"^8, "─"^7, "─"^7, "─"^5,
            "─"^9, "─"^9, "─"^9, "─"^8, "─"^8, "─"^8, "─"^4)
    else
        Printf.@printf(io, "  %-5s %5s %-8s %-10s %9s %9s %9s %8s %8s %8s %4s\n",
            "Col", "Story", "Position", "Section",
            "Pu(kip)", "Mu(k·ft)", "e(in)", "Axl.Rat", "P-M Rat", "Pun.Rat", "OK?")
        Printf.@printf(io, "  %-5s %5s %-8s %-10s %9s %9s %9s %8s %8s %8s %4s\n",
            "─"^5, "─"^5, "─"^8, "─"^10,
            "─"^9, "─"^9, "─"^9, "─"^8, "─"^8, "─"^8, "─"^4)
    end

    for (col_idx, cr) in sort(collect(design.columns); by=first)
        Pu_kip  = round(ustrip(kip, cr.Pu); digits=1)
        Mu_kipft = round(ustrip(kip * u"ft", cr.Mu_x); digits=1)

        # Eccentricity e = M/P (inches)
        e_in = abs(Pu_kip) > 0.01 ? round(abs(Mu_kipft * 12.0 / Pu_kip); digits=1) : 0.0

        # Story and position from structure
        story = 0
        pos_str = "—"
        try
            col = struc.columns[col_idx]
            story = col.story
            pos_str = string(col.position)
        catch; end

        punch_str = "—"
        if !isnothing(cr.punching)
            punch_str = fv(cr.punching.ratio; d=2)
        end

        if has_rect
            c1_in = round(ustrip(u"inch", cr.c1); digits=1)
            c2_in = round(ustrip(u"inch", cr.c2); digits=1)
            ar = c2_in > 0.1 ? round(c1_in / c2_in; digits=2) : 1.0
            Printf.@printf(io, "  C-%-2d %5d %-8s %7.1f %7.1f %5.2f %9.1f %9.1f %9.1f %8s %8s %8s %4s\n",
                col_idx, story, pos_str, c1_in, c2_in, ar,
                Pu_kip, Mu_kipft, e_in,
                fv(cr.axial_ratio; d=3), fv(cr.interaction_ratio; d=3), punch_str, pass_fail(cr.ok))
        else
            Printf.@printf(io, "  C-%-2d %5d %-8s %-10s %9.1f %9.1f %9.1f %8s %8s %8s %4s\n",
                col_idx, story, pos_str, cr.section_size,
                Pu_kip, Mu_kipft, e_in,
                fv(cr.axial_ratio; d=3), fv(cr.interaction_ratio; d=3), punch_str, pass_fail(cr.ok))
        end
    end
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 4. Foundations
# ─────────────────────────────────────────────────────────────────────────────

"""Print the foundation schedule (reactions, dimensions, bearing/punching/flexure ratios)."""
function _report_foundations(io::IO, design::BuildingDesign)
    struc = design.structure
    params = design.params
    du = params.display_units

    isempty(design.foundations) && return

    # Try to get soil bearing capacity from params
    qa_str = "—"
    if !isnothing(params.foundation_options)
        soil = params.foundation_options.soil
        qa_ksf = round(ustrip(ksf, soil.qa); digits=1)
        qa_str = "$(qa_ksf) ksf"
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
        "Fdn", "Group", "Rxn(kip)", "B(ft)", "L(ft)", "D(in)",
        "q_act(ksf)", "BearRat", "PunRat", "FlxRat", "OK?")
    Printf.@printf(io, "  %-5s %5s %10s %7s %7s %6s %10s %8s %8s %8s %4s\n",
        "─"^5, "─"^5, "─"^10, "─"^7, "─"^7, "─"^6, "─"^10, "─"^8, "─"^8, "─"^8, "─"^4)

    for (fdn_idx, fr) in sorted_fdns
        Rxn_kip = round(ustrip(kip, fr.reaction); digits=1)
        B_ft    = round(ustrip(u"ft", fr.width); digits=1)
        L_ft    = round(ustrip(u"ft", fr.length); digits=1)
        D_in    = round(ustrip(u"inch", fr.depth); digits=1)

        # Actual bearing pressure = Reaction / (B × L)
        A_ft2 = B_ft * L_ft
        q_act = A_ft2 > 0 ? round(Rxn_kip / A_ft2; digits=2) : 0.0
        g_label = get(gid_map, fr.group_id, 0)

        Printf.@printf(io, "  F-%-2d %5d %10.1f %7.1f %7.1f %6.1f %10.2f %8s %8s %8s %4s\n",
            fdn_idx, g_label, Rxn_kip, B_ft, L_ft, D_in, q_act,
            fv(fr.bearing_ratio; d=2), fv(fr.punching_ratio; d=2),
            fv(fr.flexure_ratio; d=2), pass_fail(fr.ok))
    end
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 5. Material Takeoff
# ─────────────────────────────────────────────────────────────────────────────

"""Print the material takeoff (concrete volumes, floor area, embodied carbon)."""
function _report_takeoff(io::IO, design::BuildingDesign)
    struc = design.structure
    params = design.params
    du = params.display_units

    println(io, section_break("MATERIAL TAKEOFF"))
    println(io)

    total_slab_conc = 0.0u"m^3"
    total_slab_area = 0.0u"m^2"
    for (s_idx, slab) in enumerate(struc.slabs)
        r = slab.result
        isnothing(r) && continue
        slab_area = sum(struc.cells[ci].area for ci in slab.cell_indices)
        total_slab_area += slab_area
        if hasproperty(r, :volume_per_area)
            total_slab_conc += r.volume_per_area * slab_area
        elseif hasproperty(r, :thickness)
            total_slab_conc += StructuralSizer.total_depth(r) * slab_area
        end
    end

    total_fdn_conc = 0.0u"m^3"
    for fdn in struc.foundations
        r = fdn.result
        isnothing(r) && continue
        if hasproperty(r, :concrete_volume)
            total_fdn_conc += r.concrete_volume
        end
    end

    conc_slab_yd3 = round(ustrip(u"yd^3", total_slab_conc); digits=1)
    conc_fdn_yd3  = round(ustrip(u"yd^3", total_fdn_conc); digits=1)
    conc_total    = conc_slab_yd3 + conc_fdn_yd3
    area_ft2      = round(ustrip(u"ft^2", total_slab_area); digits=0)

    Printf.@printf(io, "  %-16s %12s %14s\n", "System", "Conc.Vol(yd³)", "Floor Area(ft²)")
    Printf.@printf(io, "  %-16s %12s %14s\n", "─"^16, "─"^12, "─"^14)
    Printf.@printf(io, "  %-16s %12.1f %14.0f\n", "Slabs", conc_slab_yd3, area_ft2)
    Printf.@printf(io, "  %-16s %12.1f %14s\n", "Foundations", conc_fdn_yd3, "—")
    Printf.@printf(io, "  %-16s %12s %14s\n", "─"^16, "─"^12, "─"^14)
    Printf.@printf(io, "  %-16s %12.1f\n", "TOTAL", conc_total)
    println(io)

    # Embodied carbon (if available)
    try
        ec = compute_building_ec(struc)
        Printf.@printf(io, "  Embodied Carbon:  %.0f kgCO₂e\n", ec.total_ec)
        Printf.@printf(io, "  EC Intensity:     %.1f kgCO₂e/m²\n", ec.ec_per_floor_area)
    catch; end
    println(io)
end

# ─────────────────────────────────────────────────────────────────────────────
# 6. Overall Status
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
