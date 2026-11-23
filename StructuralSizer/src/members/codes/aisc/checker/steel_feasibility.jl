"""
    is_feasible(checker::AISCChecker, cache, j, section, material, demand, geometry;
                story=nothing) -> Bool

Check if an I-section satisfies AISC 360 requirements for the given demand.
Uses cached capacities where available.

Second-order required strengths follow AISC 360-16 Appendix 8 through the
shared [`design_column_moments`](@ref) / `_aisc_amplified_forces` core:
`Mr = B1·Mnt + B2·Mlt` (Eq. A-8-1) and `Pr = Pnt + B2·Plt` (Eq. A-8-2). The
`demand.lt` lateral-translation split supplies `Mlt`/`Plt`; the optional `story`
(a `StoryStability`) supplies the story P-Δ amplifier `B2` (Eq. A-8-6). When
`story === nothing` and `demand.lt === nothing` — the gravity-column case — `B2`
collapses to 1 and only `B1` (member P-δ) is applied, byte-identical to the
legacy path.
"""
function is_feasible(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,  # Section index in catalog
    section::AbstractSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry;
    story = nothing,  # Union{Nothing,StoryStability}; untyped (StoryStability
                      # is defined in shared/, included after aisc/).
)::Bool
    # --- Composite branch: delegate to composite overload ---
    # Only a real CompositeContext has slab/anchor data for Chapter I.
    # `true` is the SteelBeamOptions.composite sentinel (no slab data);
    # hogging Chapter F is applied below from Mux_neg, not from this flag.
    if section isa ISymmSection
        if demand.composite isa PerStationComposite
            return is_feasible(checker, cache, j, section, material, demand, geometry,
                               demand.composite)
        elseif demand.composite isa CompositeContext
            return is_feasible(checker, cache, j, section, material, demand, geometry,
                               demand.composite)
        end
    end

    # Extract demand values (SI: N, N·m)
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
    
    # AISC 360-16 Appendix 8 B2 (P-Δ) is applied through the shared
    # `_aisc_amplified_forces` core when a `story` (StoryStability) is supplied.
    # `SteelMemberGeometry.braced` defaults to `true` (no sidesway). A sway frame
    # (`braced=false`) that supplies no `story` gets only B1 (P-δ): warn, since
    # that is unconservative for sidesway members.
    if !geometry.braced && story === nothing
        @warn "Sway frame (braced=false) with no StoryStability supplied: B2 (P-Δ) " *
              "amplification not applied, only B1 (P-δ). Pass `story=` for sway members." maxlog=1
    end
    
    # --- Depth Check ---
    cache.depths[j] <= checker.max_depth || return false
    
    # --- Shear Checks ---
    cache.ϕVn_strong[j] >= Vus || return false
    cache.ϕVn_weak[j] >= Vuw || return false
    
    # --- Strong-Axis Flexure (with LTB) ---
    ϕMnx = _get_ϕMnx_cached!(cache, j, Lb_m, geometry.Cb, section, material, checker.ϕ_b)
    
    # --- Compression Capacity ---
    Lc_x = geometry.Kx * L_m
    Lc_y = geometry.Ky * L_m
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)
    
    # --- B1/B2 Moment Amplification (AISC Appendix 8) via shared core ---
    # AISC 360-16 Appendix 8 Eqs. A-8-1/A-8-2/A-8-3 — corpus: aisc-360-16, pp. 305–306.
    # `_aisc_amplified_forces` is the single implementation shared with the
    # `design_column_moments(::MemberDemand, …)` trait, so RC and steel columns
    # amplify through one path. The lateral-translation split (`demand.lt`) and
    # `story` supply Mlt/Plt and B2; absent both, B2 = 1 and only B1 is applied
    # (byte-identical to the legacy gravity-column path).
    Mux_neg = to_newton_meters(demand.Mux_neg)
    Mux_amp = Mux
    Muy_amp = Muy
    Mux_neg_amp = Mux_neg
    Pr_c = Pu_c  # second-order required compression (Eq. A-8-2); = Pu_c with no sway

    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix = cache.Ix[j]
        Iy = to_meters_fourth(StructuralSizer.Iy(section))

        Lc1_x = geometry.Kx * L_m
        Lc1_y = geometry.Ky * L_m

        (Lc1_x > 0 && Lc1_y > 0) || return false  # zero unbraced length → skip P-δ

        # Eq. A-8-5: no-translation elastic buckling strength, each axis (SI N).
        Pe1_x = π^2 * E * Ix / Lc1_x^2
        Pe1_y = π^2 * E * Iy / Lc1_y^2

        # Lateral-translation envelopes in SI (0 for a pure gravity column).
        lt = demand.lt
        Plt = lt === nothing ? 0.0 : to_newtons(lt.Plt)
        Mltx_env = lt === nothing ? 0.0 :
            max(abs(to_newton_meters(lt.M1ltx)), abs(to_newton_meters(lt.M2ltx)))
        Mlty_env = lt === nothing ? 0.0 :
            max(abs(to_newton_meters(lt.M1lty)), abs(to_newton_meters(lt.M2lty)))

        design = _aisc_amplified_forces(Pu_c, Mux, Muy, M1x, M2x, M1y, M2y,
                                        demand.transverse_load, Plt, Mltx_env, Mlty_env,
                                        story, Pe1_x, Pe1_y; α=1.0)

        (isfinite(design.B1x) && isfinite(design.B1y)) || return false

        Mux_amp = design.Mrx                     # Eq. A-8-1: B1x·Mux + B2·Mltx
        Muy_amp = design.Mry                     # Eq. A-8-1: B1y·Muy + B2·Mlty
        # Hogging shares the same lateral-translation envelope (reverse curvature).
        Mux_neg_amp = amplify_moments(Mux_neg, Mltx_env, design.B1x, design.B2)
        Pr_c = design.Pr                         # Eq. A-8-2: Pnt + B2·Plt
    end
    
    # --- Hogging Chapter F (bottom-flange LTB: Lb=L, Cb=1.0) ---
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
    # Mux_neg is always set (defaults to Mux). Do not gate on composite:
    # a CompositeContext takes the 8-arg path above; bare steel and the
    # `composite=true` sentinel both use Chapter F steel-alone here.
    # When a CompositeContext is present, §I3.2b (page 151) also refers
    # hogging to Chapter F; adequately braced = Lb ≤ Lp (Eq. F2-5, page 104).
    # ENGINEERING JUDGMENT: Cb_neg=1.0 — SteelMemberGeometry has only sagging Cb.
    ϕMn_neg = ϕMnx
    if section isa ISymmSection
        hog = _hogging_ltb_inputs(section, material, geometry)
        ϕMn_neg = _get_ϕMnx_cached!(cache, j, hog.Lb_neg_m, hog.Cb_neg,
                                    section, material, checker.ϕ_b)
        ϕMn_neg >= Mux_neg || return false
    end

    # --- H1 interaction: compression and tension, each with sagging and hogging ---
    # Hogging Mcx is Chapter F at Lb=L, Cb=1.0; do not credit deck-braced ϕMnx.
    # Compression uses the second-order Pr (Eq. A-8-2) and Mr = B1·Mnt + B2·Mlt
    # (Eq. A-8-1). Tension Mr/Pr are first-order (§H1.2, page 134); hogging
    # tension uses ϕMn_neg, not sagging ϕMnx.
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133.
    urs = _h1_pm_utilizations(Pr_c, Pu_t, Mux, Mux_neg, Muy,
                              ϕPnc, cache.ϕPn_tension[j], ϕMnx, ϕMn_neg,
                              cache.ϕMn_weak[j]; Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                              Mux_neg_amp=Mux_neg_amp)
    urs.ur_c <= 1.0 || return false
    urs.ur_t <= 1.0 || return false
    urs.ur_t_neg <= 1.0 || return false
    if section isa ISymmSection
        urs.ur_c_neg <= 1.0 || return false
    end
    
    # --- LL Deflection Check (e.g. L/360) ---
    if !isnothing(checker.deflection_limit) && I_ref > 0 && δ_max_LL > 0
        δ_scaled = δ_max_LL * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / L_m
        δ_ratio <= checker.deflection_limit || return false
    end
    
    # --- Total Deflection Check (e.g. L/240) ---
    if !isnothing(checker.total_deflection_limit) && I_ref > 0 && δ_max_total > 0
        δ_scaled = δ_max_total * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / L_m
        δ_ratio <= checker.total_deflection_limit || return false
    end

    # --- Story-shell LL deflection, each span on its own length ---
    _steel_shell_ratio(checker, demand.member_idx, section, cache.Ix[j]) <= 1 || return false

    return true
end

"""
    get_objective_coeff(checker::AISCChecker, cache, j) -> Float64

Get the precomputed objective coefficient for section j.
"""
function get_objective_coeff(checker::AISCChecker, cache::AISCCapacityCache, j::Int)::Float64
    cache.obj_coeffs[j]
end

"""
    get_feasibility_error_msg(checker::AISCChecker, demand, geometry) -> String

Generate descriptive error message for infeasible groups.
"""
function get_feasibility_error_msg(
    checker::AISCChecker,
    demand::MemberDemand,
    geometry::SteelMemberGeometry
)
    Pu_c = to_newtons(demand.Pu_c)
    Pu_t = to_newtons(demand.Pu_t)
    Mux = to_newton_meters(demand.Mux)
    Muy = to_newton_meters(demand.Muy)
    Vus = to_newtons(demand.Vu_strong)
    Vuw = to_newtons(demand.Vu_weak)
    
    "No feasible sections: Pu_c=$(Pu_c) N, Pu_t=$(Pu_t) N, " *
    "Mux=$(Mux) N·m, Muy=$(Muy) N·m, " *
    "Vus=$(Vus) N, Vuw=$(Vuw) N, " *
    "L=$(geometry.L), Lb=$(geometry.Lb)"
end

# ==============================================================================
# Hogging Chapter F inputs (bare steel + I3.2b steel-alone)
# ==============================================================================

"""
Hogging Chapter F LTB inputs (AISC 360-16 §F2.2, corpus: aisc-360-16, page 103).

Used for bare-steel 6-arg checks and for §I3.2b steel-alone strength
(corpus: aisc-360-16, page 151). Chapter F LTB is governed by the
compression flange. In hogging that flange is the bottom flange.
`geometry.Lb` is the top-flange (deck) brace spacing;
`SteelMemberGeometry` has no dedicated bottom-flange `Lb`, so `Lb_neg` is the
span `L`.

# ENGINEERING JUDGMENT
Hogging uses `Cb_neg = 1.0` unless a dedicated bottom-flange `Cb` already
exists. Do not invent a new geometry field — sagging `geometry.Cb` is not
the bottom-flange moment-gradient factor. The length of the negative-moment
region is not an unbraced length: an inflection point does not brace the
bottom flange, and shortening `Lb` to that region would raise φMn without a brace.

Adequately braced per §I3.2b(a) is `Lb ≤ Lp` (AISC 360-16 §F2.2 Eq. F2-5,
corpus: aisc-360-16, page 104), not Cb-inflated `Mn` reaching `Mp`.
"""
function _hogging_ltb_inputs(section::ISymmSection, material, geometry::SteelMemberGeometry;
                             Cb_neg::Real=1.0, L_twist=nothing)
    # A caller-supplied twist-restraint spacing replaces the span; it never
    # lengthens the unbraced length past the member.
    Lb_neg_m = L_twist === nothing ? to_meters(geometry.L) :
        min(ustrip(u"m", uconvert(u"m", L_twist)), to_meters(geometry.L))
    # Cb_neg defaults to 1. A moment field in reverse curvature passes
    # Commentary Eq. C-F1-5 (corpus: aisc-360-22, PDF pp. 442–443).
    # AISC 360-16 §F2.2, Eq. F2-5 — corpus: aisc-360-16, page 104
    Lp_m = ustrip(u"m", get_Lp_Lr(section, material).Lp)
    # AISC 360-16 §I3.2b(a) — corpus: aisc-360-16, page 151
    adequately_braced = Lb_neg_m <= Lp_m
    return (Lb_neg_m=Lb_neg_m, Cb_neg=Cb_neg, adequately_braced=adequately_braced)
end

"""
    _hogging_is_stricter(geometry::SteelMemberGeometry) -> Bool

`true` when hogging Chapter F is stricter than the sagging geometry:
deck-braced `Lb < L` or sagging `Cb > 1`.

Lengths compare in the geometry's own unit (stored metres) with the
existing `1e-9` float guard. Both inequalities are strict.

AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
# ENGINEERING JUDGMENT
`SteelMemberGeometry` has only sagging `Cb`. Hogging uses `Cb = 1.0`
when this is true (see [`_hogging_chapter_f_geometry`](@ref)).
"""
function _hogging_is_stricter(geometry::SteelMemberGeometry)
    tol = 1e-9 * oneunit(geometry.Lb)
    return geometry.Lb + tol < geometry.L || geometry.Cb > 1.0 + 1e-9
end

"""Hogging Chapter F geometry: `Lb=L`, `Cb=1.0`.

AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
# ENGINEERING JUDGMENT
`SteelMemberGeometry` has only sagging `Cb`. Hogging uses `Cb=1.0`.
"""
function _hogging_chapter_f_geometry(g::SteelMemberGeometry)
    SteelMemberGeometry(g.L; Lb=g.L, Cb=1.0, Kx=g.Kx, Ky=g.Ky, braced=g.braced)
end

"""I3.2b hogging design strength. Same gates as [`available_negative_flexure`](@ref).

AISC 360-22 §I3.2b(a–c) — corpus: aisc-360-22, PDF p. 170.
Chapter F φMn is the existing 360-16 implementation; see that function.
"""
function _composite_ϕMn_neg(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material,
    geometry::SteelMemberGeometry,
    ctx::CompositeContext;
    Cb_neg=nothing,
)
    hog = _hogging_ltb_inputs(section, material, geometry;
                              Cb_neg = something(Cb_neg, 1.0),
                              L_twist = ctx.L_twist)
    # Touch the cache so a later sagging lookup at this Lb is warm. The value
    # used below is `available_negative_flexure`, which calls `get_ϕMn` with
    # the same Lb and Cb.
    _get_ϕMnx_cached!(cache, j, hog.Lb_neg_m, hog.Cb_neg,
                      section, material, checker.ϕ_b)
    ϕMn = available_negative_flexure(section, material;
                                     Lb = hog.Lb_neg_m * u"m",
                                     Asr = ctx.Asr, Fysr = ctx.Fysr,
                                     neg_moment = ctx.neg_moment,
                                     ΣQn = ctx.ΣQn_neg,
                                     ϕ = checker.ϕ_b, Cb = hog.Cb_neg)
    return ustrip(u"N*m", ϕMn)
end

"""
AISC 360-16 §H1.1 compression, tension, and hogging P–M utilizations
(Eqs. H1-1a / H1-1b — corpus: aisc-360-16, page 133).

Required flexural strengths `Mr` for compression+flexure are second-order
moments: App. 8 B1 (P-δ) amplifies both the sagging and hogging faces
before H1 (AISC 360-16 Appendix 8 Eq. A-8-1 / A-8-3 — corpus: aisc-360-16,
pages 305–306; §C2.1 requires second-order required strengths — page 79).

`ϕMnx_sag` is sagging Mcx (Chapter F, or max(I3.2a composite, Chapter F) on
the CompositeContext path). `ϕMn_neg` is hogging Mcx (Chapter F at Lb=L,
Cb=1.0, or I3.2b). Axial Pc is Chapter E φPn — I2 is for encased/filled
columns, not slab-on-beam composite beams.

`Mux_amp` / `Mux_neg_amp` / `Muy_amp` are B1-amplified required moments
(default = first-order when B1 = 1). Tension+flexure uses first-order Mr
(App. 8 B1 applies to members subject to compression).

§H1.2 (page 134) limits flexure + tension by the same Eqs. H1-1a/H1-1b,
with Pc = φt·Pn from Section D2 and Mc from Chapter F. `ur_t` pairs tension
with the sagging face; `ur_t_neg` pairs it with the hogging face (`ϕMn_neg`).

Returns `(ur_c, ur_t, ur_c_neg, ur_t_neg)`. Adequate iff each ≤ 1.0.
"""
function _h1_pm_utilizations(
    Pu_c, Pu_t, Mux_sag, Mux_neg, Muy,
    ϕPnc, ϕPnt, ϕMnx_sag, ϕMn_neg, ϕMny;
    Mux_amp = Mux_sag,
    Muy_amp = Muy,
    Mux_neg_amp = Mux_neg,
)
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133
    # §H1.2 — same equations for flexure + tension, Pc = φt Pn (D2) — page 134
    # Compression Mr from App. 8 B1 — pages 305–306 (Eqs. A-8-1, A-8-3).
    # Tension Mr is first-order on each flexural face.
    ur_c = check_PMxMy_interaction(Pu_c, Mux_amp, Muy_amp, ϕPnc, ϕMnx_sag, ϕMny)
    ur_t = check_PMxMy_interaction(Pu_t, Mux_sag, Muy, ϕPnt, ϕMnx_sag, ϕMny)
    ur_c_neg = check_PMxMy_interaction(Pu_c, Mux_neg_amp, Muy_amp, ϕPnc, ϕMn_neg, ϕMny)
    ur_t_neg = check_PMxMy_interaction(Pu_t, Mux_neg, Muy, ϕPnt, ϕMn_neg, ϕMny)
    return (ur_c = ur_c, ur_t = ur_t, ur_c_neg = ur_c_neg, ur_t_neg = ur_t_neg)
end

