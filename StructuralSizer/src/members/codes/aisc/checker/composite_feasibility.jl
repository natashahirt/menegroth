


"""
    is_feasible(checker, cache, j, section::ISymmSection, material, demand, geometry,
                ctx::CompositeContext) -> Bool

Composite-aware feasibility check. When `CompositeContext` is provided:

1. **Construction stage** (I3.1b): bare steel under the SEI/ASCE 37-02 pre-cure load at `Lb_const` (skipped if shored). Not the final envelope.
2. **Composite ϕMn** (I3.2a / I8.2c): plastic stress distribution at the stud
   strength that fits on the shear span. Full composite is not assumed.
3. **Deflection** (Commentary I3.2): live load uses `I_LB`. A member whose
   moment field has a negative region uses Eq. C-I3-5, `0.6 I_LB + 0.4 I_s`,
   passed in as `service_continuous`. Unshored dead load stays on `Ix`.
4. **Shear and weak-axis** checks remain the same as bare steel.
5. **H1 interaction**: compression uses the larger of composite ϕMn and
   bare-steel ϕMn for sagging; hogging uses I3.2b ϕMn_neg with Pu via H1.
   Do not skip Pu because a CompositeContext is present.
"""
function is_feasible(
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
)::Bool
    Mux = to_newton_meters(demand.Mux)
    # Envelope stays on construction (§I3.1b). `strength_Mux_pos` is the
    # sagging moment at the governing station when the caller has a
    # per-station width; omitting it keeps the envelope (scalar path).
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

    # --- Depth Check ---
    cache.depths[j] <= checker.max_depth || return false

    # --- Shear Checks (steel section alone — AISC G) ---
    cache.ϕVn_strong[j] >= Vus || return false
    cache.ϕVn_weak[j] >= Vuw || return false

    # --- Construction Stage (I3.1b) — unshored; pre-cure loads on bare steel ---
    # AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 500): loads
    # applied before the concrete has cured are resisted by the steel section
    # alone. The demand is SEI/ASCE 37-02 Eqs. 2-2 and 2-3 on this member's
    # span, not the final factored envelope. 37-02 is older than the 37-14
    # that commentary cites; construction_edition() carries that flag.
    # Chapter F here is still the 360-16 implementation.
    if !ctx.shored
        pre = construction_span_demand(section, material, ctx.construction, ctx.L_beam)
        Lb_const_m = ustrip(u"m", ctx.Lb_const)
        ϕMn_const = _get_ϕMnx_cached!(cache, j, Lb_const_m, 1.0, section, material, checker.ϕ_b)
        ϕMn_const >= ustrip(u"N*m", pre.Mu) || return false
        cache.ϕVn_strong[j] >= ustrip(u"N", pre.Vu) || return false
    end

    # --- Negative flexural strength (I3.2b) does not use the positive studs ---
    ϕMn_neg = _composite_ϕMn_neg(checker, cache, j, section, material, geometry, ctx;
                                 Cb_neg = Cb_neg)
    ϕMn_neg >= Mux_neg || return false

    # Chapter F sagging strength, axial capacity, and Appendix 8 amplification.
    # The stud search has to see the amplified moment, so these come first.
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133.
    # AISC 360-16 Appendix 8 Eq. A-8-3, α=1.0 for LRFD — corpus: aisc-360-16, page 306.
    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                     section, material, checker.ϕ_b)
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
    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix = cache.Ix[j]
        Iy = to_meters_fourth(StructuralSizer.Iy(section))
        Lc1_x = geometry.Kx * L_m
        Lc1_y = geometry.Ky * L_m
        (Lc1_x > 0 && Lc1_y > 0) || return false
        Pe1_x = π^2 * E * Ix / Lc1_x^2
        Pe1_y = π^2 * E * Iy / Lc1_y^2
        Cm_x = compute_Cm(M1x, M2x; transverse_loading=demand.transverse_load)
        Cm_y = compute_Cm(M1y, M2y; transverse_loading=demand.transverse_load)
        B1_x = compute_B1(Pu_c, Pe1_x, Cm_x; α=1.0)
        B1_y = compute_B1(Pu_c, Pe1_y, Cm_y; α=1.0)
        if isinf(B1_x) || isinf(B1_y)
            return false
        end
        Mux_amp = B1_x * Mux_pos
        Muy_amp = B1_y * Muy
        Mux_neg_amp = B1_x * Mux_neg
    end

    # Studs between the maximum moment and each adjacent zero (§I8.2c).
    # Without a moment diagram both sides are half the beam span.
    b_eff = get_b_eff(ctx.slab, ctx.L_beam)
    δ_max_LL = to_meters(demand.δ_max_LL)
    δ_max_total = to_meters(demand.δ_max_total)
    I_ref = to_meters_fourth(demand.I_ref)
    # A model that already carries per-element composite inertia has produced
    # this deflection. Asking the studs for a larger I_LB, then scaling the
    # deflection by Ix / I_service, would count that stiffness twice.
    I_need = variable_inertia ? nothing :
        _I_required_for_composite(checker, ctx.shored, L_m, I_ref, δ_max_LL, δ_max_total)
    I_neg = composite_negative_inertia(section, ctx)
    if service_continuous && I_need !== nothing
        # Eq. C-I3-5 is checked on 0.6 I_LB + 0.4 I_neg. Ask the stud layout for
        # the I_LB that produces the required service inertia.
        I_need = positive_inertia_for_service(I_need, I_neg; continuous=true)
    end
    function h1_ok(lay)
        ϕMnx = max(ustrip(u"N*m", lay.ϕMn), ϕMnx_steel)
        urs = _h1_pm_utilizations(Pu_c, Pu_t, Mux_pos, Mux_neg, Muy,
                                  ϕPnc, ϕPn_t, ϕMnx, ϕMn_neg, ϕMny;
                                  Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                                  Mux_neg_amp=Mux_neg_amp)
        return urs.ur_c <= 1.0 && urs.ur_t <= 1.0 &&
               urs.ur_t_neg <= 1.0 && urs.ur_c_neg <= 1.0
    end
    # The search target is the amplified sagging moment. H1 can still ask for
    # more capacity when axial force is present; `h1_ok` raises the stud count.
    layout = design_shear_anchors(section, material, ctx.slab, ctx.anchor, b_eff,
                                  ctx.L_beam, Mux_amp * u"N*m";
                                  ϕMn_steel = ϕMnx_steel * u"N*m",
                                  shear_spans = shear_spans,
                                  slip_checked = ctx.slip_checked,
                                  I_need = I_need,
                                  extra_ok = h1_ok,
                                  ϕ = checker.ϕ_b)
    layout.ok || return false
    ϕMnx = max(ustrip(u"N*m", layout.ϕMn), ϕMnx_steel)

    # --- Deflection Checks (Commentary I3.2) ---
    # Live load, and shored total load, use I_LB. A continuous member uses
    # Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502): 0.6 I_LB + 0.4 I_neg.
    I_service = composite_service_inertia(layout.I_LB, I_neg;
                                          continuous=service_continuous)
    I_svc_m4 = ustrip(u"m^4", uconvert(u"m^4", I_service))
    I_steel_m4 = cache.Ix[j]

    # LL deflection check (e.g. L/360). `variable_inertia` uses the solved δ.
    if !isnothing(checker.deflection_limit) && δ_max_LL > 0 && (variable_inertia || I_ref > 0)
        δ_scaled = variable_inertia ? δ_max_LL : δ_max_LL * I_ref / I_svc_m4
        δ_ratio = δ_scaled / L_m
        δ_ratio <= checker.deflection_limit || return false
    end

    # Total deflection check (e.g. L/240). Unshored dead load stays on Ix
    # unless the analysis already split the two stages.
    if !isnothing(checker.total_deflection_limit) && δ_max_total > 0 &&
            (variable_inertia || I_ref > 0)
        δ_scaled = if variable_inertia
            δ_max_total
        else
            I_total_eff = ctx.shored ? I_svc_m4 : I_steel_m4
            δ_max_total * I_ref / I_total_eff
        end
        δ_ratio = δ_scaled / L_m
        δ_ratio <= checker.total_deflection_limit || return false
    end

    # Story-shell LL deflection, each span on its own length. The candidate's
    # inertia is the same service inertia the shell's solved section recorded.
    # ENGINEERING JUDGMENT: a group's spans are all checked against this
    # beam's service inertia, so the beam with the smallest one governs.
    _steel_shell_ratio(checker, demand.member_idx, section, I_svc_m4) <= 1 || return false

    return true
end

"""
Per-station composite feasibility.

Each beam in the group is checked at the sagging station that maximizes
`M⁺(s) / ϕMn(b_eff(s))` for this section (AISC 360-16 §I3.1a / §I3.2a,
corpus: aisc-360-16, PDF pp. 150–151). The scalar composite check then runs
at that station's width and moment. Construction (§I3.1b) uses this member's
pre-cure load. Hogging (§I3.2b) keeps the demand envelope.

A moment field with more than one sagging region (a continuous beam) designs
the anchors of each region from that region's own maximum moment and the
zeros on either side (AISC 360-22 §I8.2c and Commentary Eq. C-I3-1, corpus:
aisc-360-22, PDF pp. 183 and 502). The service inertia uses the region of
greatest positive moment. One region keeps the single-station path.
Every region of `psc.strength_fields` is then checked for strength and
anchors only.
"""
function is_feasible(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    psc::PerStationComposite,
)::Bool
    isempty(psc.fields) &&
        return is_feasible(checker, cache, j, section, material, demand, geometry, psc.ctx)

    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                   section, material, checker.ϕ_b)
    for field in psc.fields
        # Each member's own span (§I3.1a L/8) and its own slab. The context
        # span may be a group total; that total is not this beam's L.
        slab_i = _station_slab(psc.ctx, field)
        L_i = _station_span(psc.ctx, field)
        regions = positive_moment_regions(field.demand_of_s;
                                          breakpoints = field.breakpoints)
        if length(regions) <= 1
            _one_sagging_region(checker, cache, j, section, material, demand,
                                geometry, psc, field, slab_i, L_i, ϕMnx_steel) ||
                return false
        else
            primary = argmax(r -> r.M_peak, regions)
            _region_service(checker, cache, j, section, material, demand, geometry,
                            psc, field, slab_i, L_i, ϕMnx_steel, primary) || return false
            for region in regions
                region.s_peak == primary.s_peak && continue
                _region_strength(section, material, slab_i, psc.ctx, field, L_i,
                                 ϕMnx_steel, checker.ϕ_b, region,
                                 demand, geometry, checker, cache, j) || return false
            end
        end
    end
    for field in psc.strength_fields
        slab_i = _station_slab(psc.ctx, field)
        L_i = _station_span(psc.ctx, field)
        for region in positive_moment_regions(field.demand_of_s;
                                              breakpoints = field.breakpoints)
            _region_strength(section, material, slab_i, psc.ctx, field, L_i,
                             ϕMnx_steel, checker.ϕ_b, region,
                             demand, geometry, checker, cache, j) || return false
        end
    end
    return true
end

"""The single sagging region: one governing station, one pair of shear spans."""
function _one_sagging_region(checker, cache, j, section, material, demand, geometry,
                             psc, field, slab_i, L_i, ϕMnx_steel)
    g = governing_sagging_station(section, material, slab_i, L_i,
                                  field.demand_of_s, ϕMnx_steel;
                                  left = field.left, right = field.right,
                                  extra_breakpoints = field.breakpoints,
                                  supports = field.supports,
                                  ϕ = checker.ϕ_b)
    g.dcr <= 1.0 || return false
    return _service_at_station(checker, cache, j, section, material, demand, geometry,
                               psc, field, slab_i, L_i, g,
                               adjacent_shear_spans(field.demand_of_s, g.s_star, L_i),
                               g.M_pos)
end

"""Service check on the region of greatest positive moment, studs on its own zeros."""
function _region_service(checker, cache, j, section, material, demand, geometry,
                         psc, field, slab_i, L_i, ϕMnx_steel, region)
    g = _region_governing(section, material, slab_i, L_i, field, ϕMnx_steel,
                          checker.ϕ_b, region)
    g.dcr <= 1.0 || return false
    return _service_at_station(checker, cache, j, section, material, demand, geometry,
                               psc, field, slab_i, L_i, g,
                               region_shear_spans(region, L_i),
                               max(g.M_pos, region.M_peak))
end

function _service_at_station(checker, cache, j, section, material, demand, geometry,
                             psc, field, slab_i, L_i, g, spans, M_pos)
    st = CompositeSaggingStation(g.b_eff, g.M_pos * u"N*m",
                                 g.spacing_left, g.spacing_right)
    ctx_i = construction_context(psc.ctx, field, st, L_i, slab_i)
    return is_feasible(checker, cache, j, section, material, demand, geometry, ctx_i;
                       strength_Mux_pos = M_pos, shear_spans = spans,
                       service_continuous = moment_field_has_negative(field.demand_of_s),
                       variable_inertia = psc.variable_inertia,
                       Cb_neg = cb_neg_from_moment_field(field.demand_of_s;
                                                         L = L_i, L_twist = psc.ctx.L_twist))
end

"""Strength only: this region's anchors, not the service inertia of another bay.

Sagging-face H1 uses this region's own φMn. The hogging face stays on the
member envelope, which the primary region already checks. A secondary region
is not failed because the hogging face is inadequate.
"""
function _region_strength(section, material, slab, ctx, field, L, ϕMn_steel, ϕ, region,
                          demand, geometry, checker, cache, j)
    g = _region_governing(section, material, slab, L, field, ϕMn_steel, ϕ, region)
    g.dcr <= 1.0 || return false
    spans = region_shear_spans(region, L)
    lay_gov = nothing
    M_gov = 0.0
    for (s, M) in ((region.s_peak, region.M_peak), (g.s_star, g.M_pos))
        M <= 0 && continue
        b = b_eff_at_station(slab, L, s; left = field.left, right = field.right,
                             supports = field.supports)
        lay = design_shear_anchors(section, material, slab, ctx.anchor, b, L,
                                   M * u"N*m";
                                   ϕMn_steel = ϕMn_steel * u"N*m",
                                   shear_spans = spans,
                                   slip_checked = ctx.slip_checked,
                                   ϕ = ϕ)
        lay.ok || return false
        if M >= M_gov
            M_gov = M
            lay_gov = lay
        end
    end
    lay_gov === nothing && return true
    return _secondary_sagging_h1(section, material, demand, geometry, checker, cache, j,
                                 lay_gov, ϕMn_steel, M_gov)
end

"""H1 on the sagging face of a secondary positive-moment region.

AISC 360-16 §H1.1 (corpus: aisc-360-16, page 133). `Mux_neg` is left at zero
so this region is not judged on the hogging face. With no axial force, H1
reduces to flexure, which the anchor search already enforced.
"""
function _secondary_sagging_h1(section, material, demand, geometry, checker, cache, j,
                               lay, ϕMn_steel, M_sag)
    Pu_c = to_newtons(demand.Pu_c)
    Pu_t = to_newtons(demand.Pu_t)
    (Pu_c <= 0.0 && Pu_t <= 0.0) && return true
    ϕMnx = max(ustrip(u"N*m", lay.ϕMn), ϕMn_steel)
    Muy = to_newton_meters(demand.Muy)
    L_m = to_meters(geometry.L)
    Lc_x = geometry.Kx * L_m
    Lc_y = geometry.Ky * L_m
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)
    ϕMny = cache.ϕMn_weak[j]
    ϕPn_t = cache.ϕPn_tension[j]
    Mux_amp = M_sag
    Muy_amp = Muy
    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix = cache.Ix[j]
        Iy = to_meters_fourth(StructuralSizer.Iy(section))
        (Lc_x > 0 && Lc_y > 0) || return false
        Pe1_x = π^2 * E * Ix / Lc_x^2
        Pe1_y = π^2 * E * Iy / Lc_y^2
        M1x = to_newton_meters(demand.M1x)
        M2x = to_newton_meters(demand.M2x)
        M1y = to_newton_meters(demand.M1y)
        M2y = to_newton_meters(demand.M2y)
        Cm_x = compute_Cm(M1x, M2x; transverse_loading=demand.transverse_load)
        Cm_y = compute_Cm(M1y, M2y; transverse_loading=demand.transverse_load)
        B1_x = compute_B1(Pu_c, Pe1_x, Cm_x; α=1.0)
        B1_y = compute_B1(Pu_c, Pe1_y, Cm_y; α=1.0)
        (isinf(B1_x) || isinf(B1_y)) && return false
        Mux_amp = B1_x * M_sag
        Muy_amp = B1_y * Muy
    end
    urs = _h1_pm_utilizations(Pu_c, Pu_t, M_sag, 0.0, Muy,
                              ϕPnc, ϕPn_t, ϕMnx, ϕMnx, ϕMny;
                              Mux_amp=Mux_amp, Muy_amp=Muy_amp, Mux_neg_amp=0.0)
    return urs.ur_c <= 1.0 && urs.ur_t <= 1.0
end

function _region_governing(section, material, slab, L, field, ϕMn_steel, ϕ, region)
    lo, hi = region.s_left, region.s_right
    masked = s -> (lo - 1e-9 <= float(s) <= hi + 1e-9) ?
        field.demand_of_s(float(s)) : 0 * field.demand_of_s(float(s))
    return governing_sagging_station(section, material, slab, L, masked, ϕMn_steel;
                                     left = field.left, right = field.right,
                                     extra_breakpoints = vcat(field.breakpoints,
                                                              [region.s_left, region.s_right]),
                                     supports = field.supports,
                                     ϕ = ϕ)
end

# ==============================================================================
# Composite Objective: Add Stud Cost
# ==============================================================================

"""
    composite_stud_contribution(ctx, section, material, objective; Mu, Lb=ctx.L_beam,
                                Cb=1.0, shear_spans=nothing, I_need=nothing,
                                extra_ok=nothing, ϕ=0.9) -> Unitful.Quantity

Stud contribution of the layout [`design_shear_anchors`](@ref) selects for `Mu`.
The count is the studs on each side of the maximum moment, not the studs that
would develop `Cf`. Returns `kg` for [`MinWeight`](@ref), `kgCO2e` for
[`MinCarbon`](@ref), and `0 m^3` for [`MinVolume`](@ref).

Throws when no layout meets `Mu`. A moment the steel section carries alone
contributes nothing, because no studs are placed.
"""
function composite_stud_contribution(
    ctx::CompositeContext,
    section::ISymmSection,
    material::StructuralSteel,
    objective::AbstractObjective;
    Mu,
    Lb=ctx.L_beam,
    Cb::Real=1.0,
    shear_spans=nothing,
    I_need=nothing,
    extra_ok=nothing,
    ϕ::Real=0.9,
)
    b_eff = get_b_eff(ctx.slab, ctx.L_beam)
    ϕMn_steel = get_ϕMn(section, material; Lb=Lb, Cb=Cb, axis=:strong)
    layout = design_shear_anchors(section, material, ctx.slab, ctx.anchor, b_eff,
                                  ctx.L_beam, Mu;
                                  ϕMn_steel=ϕMn_steel,
                                  shear_spans=shear_spans,
                                  slip_checked=ctx.slip_checked,
                                  I_need=I_need,
                                  extra_ok=extra_ok,
                                  ϕ=ϕ)
    layout.ok || throw(ArgumentError(
        "No shear-anchor layout meets this moment ($(layout.reason))."))
    # One `n_half` is the studs on one side. The search uses that count on
    # every shear span. With no diagram, both sides are half the span.
    n_sides = shear_spans === nothing ? 2 : length(shear_spans)
    n_total = layout.n_half * n_sides
    m_one = stud_mass(ctx.anchor)

    if objective isa MinWeight
        return m_one * n_total
    elseif objective isa MinCarbon
        return m_one * n_total * ctx.anchor.ecc
    elseif objective isa MinVolume
        return 0.0u"m^3"
    else
        return 0.0
    end
end

