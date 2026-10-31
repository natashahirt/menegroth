# -----------------------------------------------------------------------------
# Per-station composite design check (strength + continuity + FEM deflection)
# -----------------------------------------------------------------------------

"""
    check_composite_beam(struc, beam, section, material, ctx; ΣQn,
        Asr=ctx.Asr, Fysr=ctx.Fysr, d_rebar=0.0u"m", ϕ=0.9,
        w_DL=nothing, w_LL=nothing, δ_LL=nothing) -> NamedTuple

Per-station composite flexural check for `beam` per AISC 360-16 §I3.1a / §I3.2a /
§I3.2b, combining:
  • the per-side §I3.1a effective width `b_eff(s)` from [`beam_side_profiles`];
  • the exact FEM demand field `M(s)` from [`beam_signed_moment_field`];
  • the grid-independent governing-station search (`governing_composite_station`).

`ΣQn` is the available shear transfer at the governing section (v1: one scalar
value with a continuity-ready interface — full per-station stud/shear-flow
accumulation is DEFERRED). Returns the governing record (`s_star`, `dcr_max`,
`b_eff`, `ϕMn`, `Mn`, `sense`, `M`) plus `I_LB`, `I_neg`, and `I_service`.

`I_LB` is the positive-moment lower-bound inertia at the peak sagging station.
`I_service` is the constant stiffness used to scale the steel-model deflection
([`composite_deflection_scale`](@ref)).
"""
function check_composite_beam(struc::BuildingStructure, beam::Beam, section, material,
                              ctx::CompositeContext; ΣQn,
                              Asr = ctx.Asr, Fysr = ctx.Fysr,
                              d_rebar = 0.0u"m", ϕ = 0.9)
    left, right = beam_side_profiles(struc, beam)
    M_of_s, demand_bps = beam_signed_moment_field(struc, beam)
    supports = beam_interior_supports(struc, beam)

    g = governing_composite_station(section, material, ctx.slab, ctx.L_beam,
                                    M_of_s, ΣQn; left = left, right = right,
                                    Asr = Asr, Fysr = Fysr, d_rebar = d_rebar, ϕ = ϕ,
                                    neg_moment = ctx.neg_moment,
                                    extra_breakpoints = demand_bps,
                                    supports = supports)

    # I_pos at the peak sagging station. A hogging governing station is not
    # the positive-moment section Eq. C-I3-5 names. A very large steel φMn
    # makes the sagging search follow M⁺, because φMn is then constant.
    sag = governing_sagging_station(section, material, ctx.slab, ctx.L_beam,
                                    M_of_s, 1.0e30;
                                    left = left, right = right,
                                    extra_breakpoints = demand_bps,
                                    supports = supports)
    I_pos = sag.M_pos > 0 ?
        get_I_LB(section, material, ctx.slab, sag.b_eff, ΣQn) : section.Ix
    # AISC 360-22 Commentary Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502):
    # I = 0.6 I_pos + 0.4 I_neg for a continuous beam under gravity.
    # A beam with no negative moment keeps I_pos. I_neg is the cracked steel +
    # developed-bar section when the negative region is composite, else Ix
    # (ENGINEERING JUDGMENT, see get_I_cracked_negative).
    continuous = StructuralSizer.moment_field_has_negative(M_of_s)
    I_neg = ctx.neg_moment ?
        get_I_cracked_negative(section, Asr; d_rebar = d_rebar) : section.Ix
    I_service = composite_service_inertia(I_pos, I_neg; continuous = continuous)
    return (; g..., I_LB = I_pos, I_neg = I_neg, I_service = I_service,
              left = left, right = right)
end

"""
    composite_deflection_scale(section, I_service) -> Float64

Multiplier that converts a bare-steel FEM deflection into the deflection of
the commentary's constant composite stiffness:
`δ_composite = δ_steel · (Ix / I_service)`.

`I_service` is `I_LB` when the moment does not change sign. For a continuous
beam it is AISC 360-22 Commentary Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502),
`0.6 I_pos + 0.4 I_neg`, from [`check_composite_beam`](@ref). The analysis
model carries the steel section, so one ratio applies that inertia to the
whole member. The commentary specifies this constant stiffness for the
elastic analysis.
"""
composite_deflection_scale(section, I_service) = ustrip(section.Ix / I_service)

