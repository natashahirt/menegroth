# ==============================================================================
# Feasibility Explanation (Solver Trace)
# ==============================================================================

"""
    explain_feasibility(checker::AISCChecker, cache, j, section, material, demand, geometry;
                        story=nothing)

Evaluate ALL AISC 360-16 checks without short-circuiting and return per-check
demand/capacity ratios. Mirrors the logic of `is_feasible` exactly but collects
every intermediate result.

The optional `story` (a `StoryStability`) feeds the AISC 360-16 Appendix 8
story amplifier `B2` (Eq. A-8-6) through the same `_aisc_amplified_forces`
core `is_feasible` uses, so the reported governing ratio matches the
second-order feasibility verdict. With `story === nothing` (and no
`demand.lt`) only `B1` is applied, byte-identical to the legacy trace.

Used post-solve by the trace system to explain section selection and rejection.
"""
function explain_feasibility(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::AbstractSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry;
    story = nothing,  # Union{Nothing,StoryStability}; untyped (defined in shared/).
)::FeasibilityExplanation
    if section isa ISymmSection
        if demand.composite isa PerStationComposite
            return explain_feasibility(checker, cache, j, section, material, demand, geometry,
                                       demand.composite)
        elseif demand.composite isa CompositeContext
            return explain_feasibility(checker, cache, j, section, material, demand, geometry,
                                       demand.composite)
        end
    end

    checks = CheckResult[]

    # --- Extract demands (SI) ---
    Pu_c = to_newtons(demand.Pu_c)
    Pu_t = to_newtons(demand.Pu_t)
    Mux = to_newton_meters(demand.Mux)
    Muy = to_newton_meters(demand.Muy)
    M1x = to_newton_meters(demand.M1x)
    M2x = to_newton_meters(demand.M2x)
    M1y = to_newton_meters(demand.M1y)
    M2y = to_newton_meters(demand.M2y)
    Vus = to_newtons(demand.Vu_strong)
    Vuw = to_newtons(demand.Vu_weak)
    δ_max_LL = to_meters(demand.δ_max_LL)
    δ_max_total = to_meters(demand.δ_max_total)
    I_ref = to_meters_fourth(demand.I_ref)
    L_m = to_meters(geometry.L)
    Lb_m = to_meters(geometry.Lb)

    # --- Depth Check ---
    d_section = cache.depths[j]
    d_limit = checker.max_depth
    d_ratio = d_limit > 0 ? d_section / d_limit : 0.0
    push!(checks, CheckResult("depth", d_section <= d_limit,
          d_ratio, d_section, d_limit, ""))

    # --- Shear: Strong Axis — AISC 360-16 G2 ---
    ϕVn_s = cache.ϕVn_strong[j]
    s_ratio_s = ϕVn_s > 0 ? Vus / ϕVn_s : (Vus > 0 ? Inf : 0.0)
    push!(checks, CheckResult("shear_strong", ϕVn_s >= Vus,
          s_ratio_s, Vus, ϕVn_s, "AISC 360-16 G2"))

    # --- Shear: Weak Axis ---
    ϕVn_w = cache.ϕVn_weak[j]
    s_ratio_w = ϕVn_w > 0 ? Vuw / ϕVn_w : (Vuw > 0 ? Inf : 0.0)
    push!(checks, CheckResult("shear_weak", ϕVn_w >= Vuw,
          s_ratio_w, Vuw, ϕVn_w, "AISC 360-16 G2"))

    # --- Flexural + Compression Capacities (needed for interaction) ---
    ϕMnx = _get_ϕMnx_cached!(cache, j, Lb_m, geometry.Cb, section, material, checker.ϕ_b)
    ϕMny = cache.ϕMn_weak[j]

    Lc_x = geometry.Kx * L_m
    Lc_y = geometry.Ky * L_m
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)

    # --- B1/B2 Moment Amplification — AISC Appendix 8 (shared core) ---
    # AISC 360-16 Appendix 8 Eqs. A-8-1/A-8-2/A-8-3 — corpus: aisc-360-16, pages 305–306.
    # Mirrors `is_feasible`: `Mr = B1·Mnt + B2·Mlt` (Eq. A-8-1), `Pr = Pnt + B2·Plt`
    # (Eq. A-8-2) via `_aisc_amplified_forces`. `demand.lt` supplies Mlt/Plt and
    # `story` supplies B2; absent both, B2 = 1 and only B1 is applied.
    Mux_neg = to_newton_meters(demand.Mux_neg)
    Mux_amp = Mux
    Muy_amp = Muy
    Mux_neg_amp = Mux_neg
    Pr_c = Pu_c  # second-order required compression (Eq. A-8-2); = Pu_c with no sway
    b1_feasible = true

    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix_j = cache.Ix[j]
        Iy_j = to_meters_fourth(StructuralSizer.Iy(section))
        Lc1_x = geometry.Kx * L_m
        Lc1_y = geometry.Ky * L_m

        if Lc1_x > 0 && Lc1_y > 0
            Pe1_x = π^2 * E * Ix_j / Lc1_x^2
            Pe1_y = π^2 * E * Iy_j / Lc1_y^2

            lt = demand.lt
            Plt = lt === nothing ? 0.0 : to_newtons(lt.Plt)
            Mltx_env = lt === nothing ? 0.0 :
                max(abs(to_newton_meters(lt.M1ltx)), abs(to_newton_meters(lt.M2ltx)))
            Mlty_env = lt === nothing ? 0.0 :
                max(abs(to_newton_meters(lt.M1lty)), abs(to_newton_meters(lt.M2lty)))

            design = _aisc_amplified_forces(Pu_c, Mux, Muy, M1x, M2x, M1y, M2y,
                                            demand.transverse_load, Plt, Mltx_env, Mlty_env,
                                            story, Pe1_x, Pe1_y; α=1.0)
            b1_feasible = isfinite(design.B1x) && isfinite(design.B1y)
            if b1_feasible
                Mux_amp = design.Mrx              # Eq. A-8-1: B1x·Mux + B2·Mltx
                Muy_amp = design.Mry              # Eq. A-8-1: B1y·Muy + B2·Mlty
                Mux_neg_amp = amplify_moments(Mux_neg, Mltx_env, design.B1x, design.B2)
                Pr_c = design.Pr                  # Eq. A-8-2: Pnt + B2·Plt
            end
        else
            b1_feasible = false
        end
    end

    # Report the B1/B2 amplification as a check (Pu/Pe ratio indicates stability).
    if Pu_c > 0.0 && Lc_x > 0
        Pe1_approx = ϕPnc > 0 ? Pu_c / ϕPnc : Inf
        push!(checks, CheckResult("b1_amplification", b1_feasible,
              b1_feasible ? Pe1_approx : Inf, Pu_c, ϕPnc, "AISC 360-16 App. 8"))
    end

    # --- Hogging Chapter F (bottom-flange LTB: Lb=L, Cb=1.0) ---
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
    # Always reported for I-sections so explain does not tell only the
    # unsigned H1 story. Clause is §I3.2b when the hogging-only sentinel
    # is set; otherwise Chapter F (bare steel) / H1 when Pu > 0.
    # ENGINEERING JUDGMENT: Cb_neg=1.0 — SteelMemberGeometry has only sagging Cb.
    hog_stricter = false
    ϕMn_neg = ϕMnx
    if section isa ISymmSection
        hog = _hogging_ltb_inputs(section, material, geometry)
        ϕMn_neg = _get_ϕMnx_cached!(cache, j, hog.Lb_neg_m, hog.Cb_neg,
                                    section, material, checker.ϕ_b)
        hog_stricter = _hogging_is_stricter(geometry)
    end

    # --- H1 interaction: sagging, tension, hogging ---
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133.
    # Hogging Mr = B1·Mux_neg (App. 8) — corpus: aisc-360-16, pages 305–306.
    ϕPn_t = cache.ϕPn_tension[j]
    # Compression uses the second-order Pr (Eq. A-8-2); mirrors `is_feasible`.
    urs = _h1_pm_utilizations(Pr_c, Pu_t, Mux, Mux_neg, Muy,
                              ϕPnc, ϕPn_t, ϕMnx, ϕMn_neg, ϕMny;
                              Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                              Mux_neg_amp=Mux_neg_amp)
    ur_c = b1_feasible ? urs.ur_c : Inf
    push!(checks, CheckResult("pm_interaction_compression", ur_c <= 1.0,
          ur_c, max(Pr_c, Mux_amp, Muy_amp), 1.0, "AISC 360-16 H1"))
    push!(checks, CheckResult("pm_interaction_tension", urs.ur_t <= 1.0,
          urs.ur_t, max(Pu_t, Mux, Muy), 1.0, "AISC 360-16 H1"))
    # §H1.2 (page 134): tension with the hogging face. First-order Mr, Mcx = ϕMn_neg.
    push!(checks, CheckResult("pm_interaction_tension_hogging", urs.ur_t_neg <= 1.0,
          urs.ur_t_neg, max(Pu_t, Mux_neg, Muy), 1.0, "AISC 360-16 H1.2"))
    if section isa ISymmSection
        flex_ratio = ϕMn_neg > 0 ? Mux_neg / ϕMn_neg : (Mux_neg > 0 ? Inf : 0.0)
        neg_ratio = max(flex_ratio, urs.ur_c_neg)
        neg_ok = ϕMn_neg >= Mux_neg && urs.ur_c_neg <= 1.0
        clause = if demand.composite === true
            "AISC 360-16 I3.2b"
        elseif Pu_c > 0
            "AISC 360-16 H1"
        else
            "AISC 360-16 F2"
        end
        push!(checks, CheckResult("flexure_neg", neg_ok,
              neg_ratio, Mux_neg, ϕMn_neg, clause))
    end

    # --- LL Deflection Check ---
    if !isnothing(checker.deflection_limit) && I_ref > 0 && δ_max_LL > 0
        δ_scaled = δ_max_LL * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / L_m
        limit_val = checker.deflection_limit
        push!(checks, CheckResult("deflection_ll", δ_ratio <= limit_val,
              δ_ratio / limit_val, δ_ratio, limit_val, "AISC 360-16 L"))
    end

    # --- Total Deflection Check ---
    if !isnothing(checker.total_deflection_limit) && I_ref > 0 && δ_max_total > 0
        δ_scaled = δ_max_total * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / L_m
        limit_val = checker.total_deflection_limit
        push!(checks, CheckResult("deflection_total", δ_ratio <= limit_val,
              δ_ratio / limit_val, δ_ratio, limit_val, "AISC 360-16 L"))
    end
    _push_steel_shell_check!(checks, checker, demand.member_idx, section, cache.Ix[j],
                             "AISC 360-16 L")

    # --- Aggregate ---
    # Exclude informational checks (b1_amplification is a stability indicator,
    # not a demand/capacity utilization ratio) from governing determination.
    # When hogging Chapter F is stricter, unsigned H1 used sagging ϕMnx —
    # do not advertise it as the flexure story (flexure_neg / hogging H1 is).
    capacity_checks = filter(c -> c.name != "b1_amplification", checks)
    if hog_stricter && Mux_neg > 0
        capacity_checks = filter(c -> c.name != "pm_interaction_compression" &&
                                      c.name != "pm_interaction_tension",
                                 capacity_checks)
    end
    all_pass = all(c -> c.passed, checks)
    if isempty(capacity_checks)
        gov = CheckResult("none", true, 0.0, 0.0, 0.0, "")
    else
        gov_idx = argmax([c.ratio for c in capacity_checks])
        gov = capacity_checks[gov_idx]
    end

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end

"""
    explain_feasibility(checker, cache, j, section, material, demand, geometry, ctx)

Composite-aware diagnostic sibling of the `CompositeContext` `is_feasible`
overload. Evaluates construction both-face (I3.1b), hogging (I3.2b), and
H1 interaction so `explain.passed` matches `is_feasible`.
"""
function explain_feasibility(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    ctx::CompositeContext;
    strength_Mux_pos::Union{Nothing, Float64} = nothing,
    shear_spans=nothing,
    Cb_neg=nothing,
    service_continuous::Bool=false,
    variable_inertia::Bool=false,
)::FeasibilityExplanation
    checks = CheckResult[]

    Mux = to_newton_meters(demand.Mux)
    Mux_pos_env = to_newton_meters(demand.Mux_pos)
    Mux_pos = strength_Mux_pos === nothing ? Mux_pos_env : strength_Mux_pos
    Mux_neg = to_newton_meters(demand.Mux_neg)
    Pu_c = to_newtons(demand.Pu_c)
    Pu_t = to_newtons(demand.Pu_t)
    Muy = to_newton_meters(demand.Muy)
    M1x = to_newton_meters(demand.M1x)
    M2x = to_newton_meters(demand.M2x)
    M1y = to_newton_meters(demand.M1y)
    M2y = to_newton_meters(demand.M2y)
    Vus = to_newtons(demand.Vu_strong)
    Vuw = to_newtons(demand.Vu_weak)
    L_m = to_meters(geometry.L)
    δ_max_LL = to_meters(demand.δ_max_LL)
    δ_max_total = to_meters(demand.δ_max_total)
    I_ref = to_meters_fourth(demand.I_ref)

    # --- Depth ---
    d_section = cache.depths[j]
    d_limit = checker.max_depth
    d_ratio = d_limit > 0 ? d_section / d_limit : 0.0
    push!(checks, CheckResult("depth", d_section <= d_limit,
          d_ratio, d_section, d_limit, ""))

    # --- Shear (steel section alone — AISC G) ---
    ϕVn_s = cache.ϕVn_strong[j]
    s_ratio_s = ϕVn_s > 0 ? Vus / ϕVn_s : (Vus > 0 ? Inf : 0.0)
    push!(checks, CheckResult("shear_strong", ϕVn_s >= Vus,
          s_ratio_s, Vus, ϕVn_s, "AISC 360-16 G2"))

    ϕVn_w = cache.ϕVn_weak[j]
    s_ratio_w = ϕVn_w > 0 ? Vuw / ϕVn_w : (Vuw > 0 ? Inf : 0.0)
    push!(checks, CheckResult("shear_weak", ϕVn_w >= Vuw,
          s_ratio_w, Vuw, ϕVn_w, "AISC 360-16 G2"))

    # --- Construction Stage (I3.1b) — pre-cure load, not the final envelope ---
    # AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 500).
    # Demand: SEI/ASCE 37-02 §2.2.3 Eqs. 2-2 and 2-3 (corpus: sei-asce-37-02,
    # PDF p. 16), an older edition than ASCE/SEI 37-14. Chapter F is 360-16.
    if !ctx.shored
        pre = construction_span_demand(section, material, ctx.construction, ctx.L_beam)
        Lb_const_m = ustrip(u"m", ctx.Lb_const)
        ϕMn_const = _get_ϕMnx_cached!(cache, j, Lb_const_m, 1.0, section, material, checker.ϕ_b)
        Mu_const = ustrip(u"N*m", pre.Mu)
        Vu_const = ustrip(u"N", pre.Vu)
        c_ratio = ϕMn_const > 0 ? Mu_const / ϕMn_const : (Mu_const > 0 ? Inf : 0.0)
        clause = "AISC 360-22 I3.1b; $(pre.edition); Eq. $(pre.equation); C_P $(pre.cp_class)" *
                 deck_brace_note(ctx.deck_attachment, pre.Vbr)
        push!(checks, CheckResult("construction_flexure", ϕMn_const >= Mu_const,
              c_ratio, Mu_const, ϕMn_const, clause))
        ϕVn_c = cache.ϕVn_strong[j]
        v_ratio = ϕVn_c > 0 ? Vu_const / ϕVn_c : (Vu_const > 0 ? Inf : 0.0)
        push!(checks, CheckResult("construction_shear", ϕVn_c >= Vu_const,
              v_ratio, Vu_const, ϕVn_c, clause))
    end

    # Positive studs are chosen after amplification, so Chapter F is all that
    # is known here. `flexure_pos` is recorded with the layout below.
    b_eff = get_b_eff(ctx.slab, ctx.L_beam)
    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                     section, material, checker.ϕ_b)
    ϕMnx = ϕMnx_steel

    # --- Negative flexural strength (I3.2b) + hogging H1 ---
    # AISC 360-16 §I3.2b — corpus: aisc-360-16, page 151
    # AISC 360-16 §F2.2 Eq. F2-5 — corpus: aisc-360-16, page 104
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133
    ϕMn_neg = _composite_ϕMn_neg(checker, cache, j, section, material, geometry, ctx;
                                 Cb_neg = Cb_neg)
    hog_stricter = _hogging_is_stricter(geometry)

    Lc_x = geometry.Kx * L_m
    Lc_y = geometry.Ky * L_m
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)
    ϕMny = cache.ϕMn_weak[j]
    ϕPn_t = cache.ϕPn_tension[j]

    Mux_amp = Mux_pos
    Muy_amp = Muy
    Mux_neg_amp = Mux_neg
    b1_feasible = true
    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix_j = cache.Ix[j]
        Iy_j = to_meters_fourth(StructuralSizer.Iy(section))
        Lc1_x = geometry.Kx * L_m
        Lc1_y = geometry.Ky * L_m
        if Lc1_x > 0 && Lc1_y > 0
            Pe1_x = π^2 * E * Ix_j / Lc1_x^2
            Pe1_y = π^2 * E * Iy_j / Lc1_y^2
            Cm_x = compute_Cm(M1x, M2x; transverse_loading=demand.transverse_load)
            Cm_y = compute_Cm(M1y, M2y; transverse_loading=demand.transverse_load)
            B1_x = compute_B1(Pu_c, Pe1_x, Cm_x; α=1.0)
            B1_y = compute_B1(Pu_c, Pe1_y, Cm_y; α=1.0)
            b1_feasible = !isinf(B1_x) && !isinf(B1_y)
            if b1_feasible
                Mux_amp = B1_x * Mux_pos
                Muy_amp = B1_y * Muy
                Mux_neg_amp = B1_x * Mux_neg
            end
        else
            b1_feasible = false
        end
    end

    if Pu_c > 0.0 && Lc_x > 0
        Pe1_approx = ϕPnc > 0 ? Pu_c / ϕPnc : Inf
        push!(checks, CheckResult("b1_amplification", b1_feasible,
              b1_feasible ? Pe1_approx : Inf, Pu_c, ϕPnc, "AISC 360-16 App. 8"))
    end

    I_need = variable_inertia ? nothing :
        _I_required_for_composite(checker, ctx.shored, L_m, I_ref, δ_max_LL, δ_max_total)
    I_neg = composite_negative_inertia(section, ctx)
    if service_continuous && I_need !== nothing
        I_need = positive_inertia_for_service(I_need, I_neg; continuous=true)
    end
    function h1_ok(lay)
        mcx = max(ustrip(u"N*m", lay.ϕMn), ϕMnx_steel)
        trial = _h1_pm_utilizations(Pu_c, Pu_t, Mux_pos, Mux_neg, Muy,
                                    ϕPnc, ϕPn_t, mcx, ϕMn_neg, ϕMny;
                                    Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                                    Mux_neg_amp=Mux_neg_amp)
        b1_feasible || return false
        return trial.ur_c <= 1.0 && trial.ur_t <= 1.0 &&
               trial.ur_t_neg <= 1.0 && trial.ur_c_neg <= 1.0
    end
    layout = design_shear_anchors(section, material, ctx.slab, ctx.anchor, b_eff,
                                  ctx.L_beam, Mux_amp * u"N*m";
                                  ϕMn_steel = ϕMnx_steel * u"N*m",
                                  shear_spans = shear_spans,
                                  slip_checked = ctx.slip_checked,
                                  I_need = I_need,
                                  extra_ok = h1_ok,
                                  ϕ = checker.ϕ_b)
    ϕMnx = max(ustrip(u"N*m", layout.ϕMn), ϕMnx_steel)
    pos_ratio = ϕMnx > 0 ? Mux_pos / ϕMnx : (Mux_pos > 0 ? Inf : 0.0)
    push!(checks, CheckResult("flexure_pos", ϕMnx >= Mux_pos,
          pos_ratio, Mux_pos, ϕMnx, "AISC 360-22 I3.2a"))
    stud_clause = "AISC 360-22 I8.2c; I8.2d; $(layout.n_half) studs/side; $(layout.reason)"
    isempty(ctx.anchor.source) || (stud_clause *= "; " * ctx.anchor.source)
    deck = deck_limit_failures(ctx.slab, ctx.anchor)
    for msg in vcat(deck.failures, deck.unchecked)
        stud_clause *= "; " * msg
    end
    rib_note = deck_rib_note(ctx.slab)
    isempty(rib_note) || (stud_clause *= "; " * rib_note)
    push!(checks, CheckResult("shear_anchors", layout.ok,
          layout.ok ? pos_ratio : Inf, Float64(layout.n_half),
          Float64(layout.n_rows_max * ctx.anchor.n_per_row), stud_clause))

    urs = _h1_pm_utilizations(Pu_c, Pu_t, Mux_pos, Mux_neg, Muy,
                              ϕPnc, ϕPn_t, ϕMnx, ϕMn_neg, ϕMny;
                              Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                              Mux_neg_amp=Mux_neg_amp)
    ur_c = b1_feasible ? urs.ur_c : Inf
    push!(checks, CheckResult("pm_interaction_compression", ur_c <= 1.0,
          ur_c, max(Pu_c, Mux_amp, Muy_amp), 1.0, "AISC 360-16 H1"))
    push!(checks, CheckResult("pm_interaction_tension", urs.ur_t <= 1.0,
          urs.ur_t, max(Pu_t, Mux_pos, Muy), 1.0, "AISC 360-16 H1"))
    # §H1.2 (page 134): tension with the hogging face. First-order Mr, Mcx = ϕMn_neg.
    push!(checks, CheckResult("pm_interaction_tension_hogging", urs.ur_t_neg <= 1.0,
          urs.ur_t_neg, max(Pu_t, Mux_neg, Muy), 1.0, "AISC 360-16 H1.2"))

    flex_ratio = ϕMn_neg > 0 ? Mux_neg / ϕMn_neg : (Mux_neg > 0 ? Inf : 0.0)
    neg_ratio = max(flex_ratio, urs.ur_c_neg)
    neg_ok = ϕMn_neg >= Mux_neg && urs.ur_c_neg <= 1.0
    clause = Pu_c > 0 ? "AISC 360-16 H1" : "AISC 360-16 I3.2b"
    push!(checks, CheckResult("flexure_neg", neg_ok,
          neg_ratio, Mux_neg, ϕMn_neg, clause))

    # --- Deflection (Commentary I3.2, Eq. C-I3-5 when the span changes sign) ---
    I_service = composite_service_inertia(layout.I_LB, I_neg;
                                          continuous=service_continuous)
    I_svc_m4 = ustrip(u"m^4", uconvert(u"m^4", I_service))
    I_steel_m4 = cache.Ix[j]
    defl_clause = variable_inertia ? "per-element composite inertia" :
        (service_continuous ? "AISC 360-22 Comm. C-I3-5" : "AISC 360-22 Comm. I3.2")

    if !isnothing(checker.deflection_limit) && δ_max_LL > 0 && (variable_inertia || I_ref > 0)
        δ_scaled = variable_inertia ? δ_max_LL : δ_max_LL * I_ref / I_svc_m4
        δ_ratio = δ_scaled / L_m
        limit_val = checker.deflection_limit
        push!(checks, CheckResult("deflection_ll", δ_ratio <= limit_val,
              δ_ratio / limit_val, δ_ratio, limit_val, defl_clause))
    end

    if !isnothing(checker.total_deflection_limit) && δ_max_total > 0 &&
            (variable_inertia || I_ref > 0)
        δ_scaled = if variable_inertia
            δ_max_total
        else
            I_total_eff = ctx.shored ? I_svc_m4 : I_steel_m4
            δ_max_total * I_ref / I_total_eff
        end
        δ_ratio = δ_scaled / L_m
        limit_val = checker.total_deflection_limit
        push!(checks, CheckResult("deflection_total", δ_ratio <= limit_val,
              δ_ratio / limit_val, δ_ratio, limit_val, defl_clause))
    end
    _push_steel_shell_check!(checks, checker, demand.member_idx, section, I_svc_m4,
                             "AISC 360-22 Comm. I3.2")

    capacity_checks = filter(c -> c.name != "b1_amplification", checks)
    if hog_stricter && Mux_neg > 0
        capacity_checks = filter(c -> c.name != "pm_interaction_compression" &&
                                      c.name != "pm_interaction_tension",
                                 capacity_checks)
    end
    all_pass = all(c -> c.passed, checks)
    if isempty(capacity_checks)
        gov = CheckResult("none", true, 0.0, 0.0, 0.0, "")
    else
        gov_idx = argmax([c.ratio for c in capacity_checks])
        gov = capacity_checks[gov_idx]
    end

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end

"""Explain the beam in the group whose governing sagging station is the strictest."""
function explain_feasibility(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    psc::PerStationComposite,
)::FeasibilityExplanation
    isempty(psc.fields) &&
        return explain_feasibility(checker, cache, j, section, material, demand, geometry, psc.ctx)

    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                   section, material, checker.ϕ_b)
    # Secondary regions are strength only. Their inertia is not the member's
    # service inertia, so a deflection limit must not govern their report.
    strength_only = AISCChecker(; ϕ_b = checker.ϕ_b, ϕ_c = checker.ϕ_c,
                                ϕ_v = checker.ϕ_v, ϕ_t = checker.ϕ_t,
                                max_depth = checker.max_depth,
                                prefer_penalty = checker.prefer_penalty)
    best = nothing
    for field in psc.fields
        slab_i = _station_slab(psc.ctx, field)
        L_i = _station_span(psc.ctx, field)
        regions = positive_moment_regions(field.demand_of_s;
                                          breakpoints = field.breakpoints)
        if length(regions) <= 1
            g = governing_sagging_station(section, material, slab_i, L_i,
                                          field.demand_of_s, ϕMnx_steel;
                                          left = field.left, right = field.right,
                                          extra_breakpoints = field.breakpoints,
                                          supports = field.supports,
                                          ϕ = checker.ϕ_b)
            best = _worse_explanation(best, _explain_station(
                checker, cache, j, section, material, demand, geometry, psc,
                field, slab_i, L_i, g,
                adjacent_shear_spans(field.demand_of_s, g.s_star, L_i), g.M_pos))
        else
            primary = argmax(r -> r.M_peak, regions)
            g = _region_governing(section, material, slab_i, L_i, field, ϕMnx_steel,
                                  checker.ϕ_b, primary)
            best = _worse_explanation(best, _explain_station(
                checker, cache, j, section, material, demand, geometry, psc,
                field, slab_i, L_i, g, region_shear_spans(primary, L_i),
                max(g.M_pos, primary.M_peak)))
            for region in regions
                region.s_peak == primary.s_peak && continue
                gr = _region_governing(section, material, slab_i, L_i, field,
                                       ϕMnx_steel, checker.ϕ_b, region)
                best = _worse_explanation(best, _explain_station(
                    strength_only, cache, j, section, material, demand, geometry, psc,
                    field, slab_i, L_i, gr, region_shear_spans(region, L_i),
                    max(gr.M_pos, region.M_peak)))
            end
        end
    end
    for field in psc.strength_fields
        slab_i = _station_slab(psc.ctx, field)
        L_i = _station_span(psc.ctx, field)
        for region in positive_moment_regions(field.demand_of_s;
                                              breakpoints = field.breakpoints)
            gr = _region_governing(section, material, slab_i, L_i, field,
                                   ϕMnx_steel, checker.ϕ_b, region)
            best = _worse_explanation(best, _explain_station(
                strength_only, cache, j, section, material, demand, geometry, psc,
                field, slab_i, L_i, gr, region_shear_spans(region, L_i),
                max(gr.M_pos, region.M_peak)))
        end
    end
    return best
end

function _explain_station(checker, cache, j, section, material, demand, geometry,
                          psc, field, slab_i, L_i, g, spans, M_pos)
    st = CompositeSaggingStation(g.b_eff, g.M_pos * u"N*m",
                                 g.spacing_left, g.spacing_right)
    ctx_i = construction_context(psc.ctx, field, st, L_i, slab_i)
    return explain_feasibility(checker, cache, j, section, material, demand, geometry, ctx_i;
                               strength_Mux_pos = M_pos, shear_spans = spans,
                               service_continuous = moment_field_has_negative(field.demand_of_s),
                               variable_inertia = psc.variable_inertia,
                               Cb_neg = cb_neg_from_moment_field(field.demand_of_s;
                                                                 L = L_i, L_twist = psc.ctx.L_twist))
end

function _worse_explanation(best, ex)
    if best === nothing || (!ex.passed && best.passed) ||
            (ex.passed == best.passed && ex.governing_ratio > best.governing_ratio)
        return ex
    end
    return best
end

"""Section name for an infeasibility message, or the type when it has none."""
function _catalog_section_name(section)
    name = hasproperty(section, :name) ? getfield(section, :name) : nothing
    return name === nothing ? string(typeof(section)) : string(name)
end

_ratio_text(r::Real) = isinf(r) ? "Inf" : string(round(r; digits = 2))

"""`name` ratio, the L/n limit for a deflection check, and the clause."""
function _check_phrase(check::CheckResult)
    clause = isempty(check.code_clause) ? "" : " ($(check.code_clause))"
    limit = ""
    if startswith(check.name, "deflection") && check.capacity > 0
        n = round(Int, 1 / check.capacity)
        if n > 0 && abs(1 / check.capacity - n) < 1e-2
            limit = ", limit L/$n"
        end
    end
    return "$(check.name) ratio $(_ratio_text(check.ratio))$limit$clause"
end

"""
    diagnose_infeasibility(checker::AISCChecker, cache, catalog, material, demand, geometry) -> String

Name the checks that reject this demand.

A check that fails on every section is named first. The section with the
lowest governing ratio is the closest, and its failing checks are listed
with that ratio. This runs only after the catalog search has already failed.
"""
function diagnose_infeasibility(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    catalog::AbstractVector,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
)::String
    isempty(catalog) && return "The catalog is empty."
    n = length(catalog)
    n_pass = 0
    common = nothing
    closest = nothing
    for j in 1:n
        section = catalog[j]
        expl = explain_feasibility(checker, cache, j, section, material, demand, geometry)
        expl.passed && (n_pass += 1; continue)
        failing = filter(c -> !c.passed, expl.checks)
        names = Set(c.name for c in failing)
        common = common === nothing ? names : intersect(common, names)
        if closest === nothing || expl.governing_ratio < closest.ratio
            closest = (ratio = expl.governing_ratio, section = section, checks = failing)
        end
    end
    n_pass == n && return "Every section passes these checks."
    closest === nothing && return "No section could be checked."
    label = _catalog_section_name(closest.section)
    listed = isempty(closest.checks) ? "no named check" :
        join((_check_phrase(c) for c in closest.checks), "; ")
    shared = common === nothing ? String[] : sort!(collect(common))
    if n_pass > 0
        head = "$n_pass of $n sections pass these checks."
    elseif !isempty(shared)
        head = "Every section fails $(join(shared, ", "))."
    else
        head = "No check fails every section."
    end
    return "$head Closest is $label: $listed."
end
