# ==============================================================================
# Construction Stage Checks — AISC 360-16 Section I3.1b
# ==============================================================================
# When temporary shores are not used, the steel section alone must support
# all loads applied prior to the concrete attaining 75% of fc'.

"""
    check_construction(section::ISymmSection, material, Mu_const, Vu_const;
                       Lb_const, Cb_const=1.0, ϕ_b=0.9, ϕ_v=1.0) -> NamedTuple

Construction-stage check per AISC I3.1b: steel section alone must resist
all loads applied before the concrete reaches 75% of fc'.

Uses Chapter F (flexure) and Chapter G (shear) for the bare steel section.
`Lb_const` is the unbraced length during construction — typically the full beam
span unless temporary bracing or deck attachment provides lateral support.

# Returns
- `flexure_ok`:  `ϕMn_steel ≥ Mu_const`
- `shear_ok`:    `ϕVn_steel ≥ Vu_const`
- `ϕMn_steel`:   Design flexural strength of steel section alone
- `ϕVn_steel`:   Design shear strength of steel section alone
"""
function check_construction(section::ISymmSection, material, Mu_const, Vu_const;
                             Lb_const, Cb_const=1.0, ϕ_b=0.9, ϕ_v=1.0)
    # Flexure — Chapter F with construction-stage unbraced length
    ϕMn_steel = get_ϕMn(section, material; Lb=Lb_const, Cb=Cb_const, axis=:strong, ϕ=ϕ_b)

    # Shear — Chapter G
    ϕVn_steel = get_ϕVn(section, material; axis=:strong, ϕ=ϕ_v)

    flexure_ok = ϕMn_steel >= Mu_const
    shear_ok   = ϕVn_steel >= Vu_const

    return (; flexure_ok, shear_ok, ϕMn_steel, ϕVn_steel)
end

# ==============================================================================
# Pre-cure demand — SEI/ASCE 37-02, flagged older than ASCE/SEI 37-14
# ==============================================================================
# AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 500): loads applied
# to an unshored beam before the concrete has cured are resisted by the steel
# section alone. The commentary points to ASCE/SEI 37-14, which is not in the
# corpus. The combinations below are SEI/ASCE 37-02 §2.2.3 Eqs. 2-2 and 2-3
# (corpus: sei-asce-37-02, PDF p. 16). 37-02 is an older edition than the one
# AISC 360-22 cites. Report that whenever these factors are used.
#
# Eq. 2-2: 1.4D + 1.4C_D + 1.2C_FML + 1.4C_VML
# Eq. 2-3: 1.2D + 1.2C_D + 1.2C_FML + 1.4C_VML + 1.6C_P + 1.6C_H + 0.5L
#
# Fresh concrete is C_VML because it can be piled higher than the finished
# thickness (Commentary C4.2, PDF p. 22). The steel beam and an installed deck
# are D. Table 2 (§4.8.1.1, PDF p. 29) is the vertical load from personnel,
# equipment, and material in transit. It does not include D, C_D, or C_FML.
# This check assigns that tabulated value to C_P. Placed concrete stays C_VML.

const _CONSTRUCTION_EDITION =
    "SEI/ASCE 37-02 (older than the ASCE/SEI 37-14 cited by AISC 360-22 Commentary I3.1b)"

# SEI/ASCE 37-02 Table 2, §4.8.1.1 (corpus: sei-asce-37-02, PDF p. 29).
const _CP_TABLE = (
    very_light = 20.0u"psf",
    light      = 25.0u"psf",
    medium     = 50.0u"psf",
    heavy      = 75.0u"psf",
)

"""Working-surface class for Table 2. `nothing` is a missing load and throws."""
function construction_personnel_pressure(cp_class)
    cp_class === nothing && throw(ArgumentError(
        "Composite construction needs a working-surface class for C_P " *
        "(SEI/ASCE 37-02 Table 2, §4.8.1.1, PDF p. 29). The default is :medium (50 psf)."))
    cp_class in keys(_CP_TABLE) || throw(ArgumentError(
        "Working-surface class $(cp_class) is not in SEI/ASCE 37-02 Table 2. " *
        "Use :very_light, :light, :medium, or :heavy."))
    return uconvert(u"Pa", _CP_TABLE[cp_class])
end

construction_edition() = _CONSTRUCTION_EDITION

"""Half-width that carries load: half the center-to-center spacing, or the slab edge."""
function _tributary_half(spacing, edge)
    edge === nothing && return spacing / 2
    return min(spacing / 2, edge)
end

"""
Nominal fresh-concrete pressure, C_VML.

The finished thickness is the nominal load. Eq. 2-2 and Eq. 2-3 already factor
it by 1.4 (SEI/ASCE 37-02 §2.2.3, PDF p. 16). No extra piled thickness is added.

For a deck, rib pitch is not stored. The rib is counted as solid over `hr`.
That overstates the concrete in the flutes.
"""
_concrete_pressure(slab::SolidSlabOnBeam) = uconvert(u"Pa", slab.t_slab * slab.wc * GRAVITY)
function _concrete_pressure(slab::DeckSlabOnBeam)
    # ENGINEERING JUDGMENT: DeckSlabOnBeam has no rib pitch, so the flute is
    # taken as solid concrete over hr. This overstates C_VML. Deck steel weight
    # is not in this pressure; pass it as w_D_extra.
    return uconvert(u"Pa", (slab.t_slab + slab.hr) * slab.wc * GRAVITY)
end

function construction_stage(slab::AbstractSlabOnBeam;
                            cp_class::Union{Symbol, Nothing} = :medium,
                            b_trib = nothing,
                            p_L = 0.0u"Pa",
                            w_D_extra = 0.0u"N/m",
                            w_Cd = 0.0u"N/m",
                            w_Cfml = 0.0u"N/m",
                            p_concrete = nothing)
    b = b_trib === nothing ? tributary_width(slab) : uconvert(u"m", b_trib)
    pc = p_concrete === nothing ? _concrete_pressure(slab) : uconvert(u"Pa", p_concrete)
    return ConstructionStage(cp_class, construction_personnel_pressure(cp_class),
                             pc, b,
                             uconvert(u"Pa", p_L),
                             uconvert(u"N/m", w_D_extra),
                             uconvert(u"N/m", w_Cd),
                             uconvert(u"N/m", w_Cfml),
                             nothing, nothing, nothing)
end

construction_with_width(stage::ConstructionStage, b_trib) =
    ConstructionStage(stage.cp_class, stage.p_Cp, stage.p_concrete,
                      uconvert(u"m", b_trib), stage.p_L,
                      stage.w_D_extra, stage.w_Cd, stage.w_Cfml,
                      stage.M_ref, stage.V_ref, stage.w_ref,
                      stage.M_line, stage.V_line, stage.p_ref)

"""
Attach an analysis dead-load shape to a construction stage.

`M_ref` and `V_ref` are the extrema of absolute moment and shear from a
uniform dead load `w_ref` on this beam. The pre-cure check scales them by
the SEI/ASCE 37-02 line load. A non-positive `w_ref` throws.
"""
function construction_with_shape(stage::ConstructionStage, M_ref, V_ref, w_ref)
    w = uconvert(u"N/m", w_ref)
    ustrip(w) > 0 || throw(ArgumentError(
        "A pre-cure moment shape needs a positive analysis line load."))
    ConstructionStage(stage.cp_class, stage.p_Cp, stage.p_concrete, stage.b_trib,
                      stage.p_L, stage.w_D_extra, stage.w_Cd, stage.w_Cfml,
                      abs(uconvert(u"N*m", M_ref)),
                      abs(uconvert(u"N", V_ref)),
                      w, nothing, nothing, nothing)
end

"""
Attach a varying-width dead-load shape to a construction stage.

`M_area` and `V_area` are the extrema from one tributary pressure `p_ref` on
the bare-steel model, widths varying along the beam. `M_line` and `V_line`
are the extrema from a uniform 1 N/m on that same model. Area load scales
with pressure. The steel weight, a line load, scales `M_line`.
"""
function construction_with_split(stage::ConstructionStage, M_area, V_area, p_ref,
                                 M_line, V_line)
    p = uconvert(u"Pa", p_ref)
    ustrip(p) > 0 || throw(ArgumentError(
        "A pre-cure tributary shape needs a positive analysis pressure."))
    return ConstructionStage(stage.cp_class, stage.p_Cp, stage.p_concrete, stage.b_trib,
                             stage.p_L, stage.w_D_extra, stage.w_Cd, stage.w_Cfml,
                             abs(uconvert(u"N*m", M_area)),
                             abs(uconvert(u"N", V_area)),
                             nothing,
                             abs(uconvert(u"N*m", M_line)),
                             abs(uconvert(u"N", V_line)),
                             p)
end

"""
Factored uniform line load and the simple-span moment and shear it produces.

The steel beam's weight is D. C_H is not a vertical load on this beam; a
horizontal construction load is not added here.

STATICS, not a code formula. With no analysis shape, a uniform line load on
a simple span gives `M = w L^2 / 8` and `V = w L / 2`.

ENGINEERING JUDGMENT: when the stage carries `M_ref`, `V_ref`, and `w_ref`
from a uniform analysis dead load, both are scaled by `w / w_ref`. A pinned
beam recovers `w L^2 / 8`. A moment connection supplies its own end moment
and end shear. The scale is valid only when the construction load has the
same layout as that dead load. Personnel placed in a different pattern is
not represented.

ENGINEERING JUDGMENT: when the stage carries `p_ref`, the tributary width
varies and the dead load is one pressure on that width. The area-load part
of each equation scales `M_ref` by its pressure over `p_ref`. The steel
weight and the line-load construction terms scale `M_line`, the moment of a
uniform 1 N/m on the same model. Without a shape, the simple span remains:
`w L^2 / 8` is the largest uniform-load moment among simple, propped, and
fixed ends, and `w L / 2` is below the 5wL/8 fixed-end shear of a propped
cantilever.

ENGINEERING JUDGMENT: `p_L` defaults to zero. Eq. 2-3's `0.5L` is the
arbitrary-point-in-time live load present during construction (SEI/ASCE 37-02
§2.2.3). The finished floor's occupancy live load is not put on the wet slab
unless the caller passes `p_L`.
"""
function construction_span_demand(section, material, stage::ConstructionStage, L)
    L_m = uconvert(u"m", L)
    w_steel = uconvert(u"N/m", section.A * material.ρ * GRAVITY)
    w_D = w_steel + stage.w_D_extra
    w_Cvml = uconvert(u"N/m", stage.p_concrete * stage.b_trib)
    w_Cp = uconvert(u"N/m", stage.p_Cp * stage.b_trib)
    w_L = uconvert(u"N/m", stage.p_L * stage.b_trib)
    # SEI/ASCE 37-02 §2.2.3 Eqs. 2-2 and 2-3 (corpus: sei-asce-37-02, PDF p. 16).
    # C_H is omitted: it is horizontal (§2.1) and this beam check is vertical.
    w_22 = 1.4 * w_D + 1.4 * stage.w_Cd + 1.2 * stage.w_Cfml + 1.4 * w_Cvml
    w_23 = 1.2 * w_D + 1.2 * stage.w_Cd + 1.2 * stage.w_Cfml + 1.4 * w_Cvml +
           1.6 * w_Cp + 0.5 * w_L
    w = max(w_22, w_23)
    equation = w_23 >= w_22 ? "2-3" : "2-2"
    line_refs = (stage.M_line, stage.V_line, stage.p_ref)
    if stage.p_ref !== nothing && any(isnothing, line_refs)
        throw(ArgumentError(
            "A varying-width pre-cure shape needs the area-load moment and shear, " *
            "the unit line-load moment and shear, and the analysis pressure."))
    end
    refs = (stage.M_ref, stage.V_ref, stage.w_ref)
    if stage.p_ref === nothing && any(!isnothing, refs) && any(isnothing, refs)
        throw(ArgumentError(
            "Pre-cure moment shape needs the analysis moment, shear, and line load together."))
    end
    if stage.p_ref !== nothing
        # Area load follows the tributary width. Line load does not.
        # SEI/ASCE 37-02 §2.2.3: C_VML, C_P, and 0.5L are pressures; D, C_D,
        # and C_FML are line loads. The governing equation may differ for
        # moment and for shear; `equation` names the moment's.
        p22 = 1.4 * stage.p_concrete
        p23 = 1.4 * stage.p_concrete + 1.6 * stage.p_Cp + 0.5 * stage.p_L
        w22 = 1.4 * w_D + 1.4 * stage.w_Cd + 1.2 * stage.w_Cfml
        w23 = 1.2 * w_D + 1.2 * stage.w_Cd + 1.2 * stage.w_Cfml
        w1 = 1.0u"N/m"
        Mu22 = stage.M_ref * (p22 / stage.p_ref) + stage.M_line * (w22 / w1)
        Mu23 = stage.M_ref * (p23 / stage.p_ref) + stage.M_line * (w23 / w1)
        Vu22 = stage.V_ref * (p22 / stage.p_ref) + stage.V_line * (w22 / w1)
        Vu23 = stage.V_ref * (p23 / stage.p_ref) + stage.V_line * (w23 / w1)
        Mu = max(Mu22, Mu23)
        Vu = max(Vu22, Vu23)
        equation = Mu23 >= Mu22 ? "2-3" : "2-2"
        moment_model = :analysis_tributary
    elseif stage.M_ref === nothing
        Mu = w * L_m^2 / 8
        Vu = w * L_m / 2
        moment_model = :simple_span
    else
        # ENGINEERING JUDGMENT: same layout as the uniform analysis dead load.
        Mu = uconvert(u"N*m", stage.M_ref) * (w / stage.w_ref)
        Vu = uconvert(u"N", stage.V_ref) * (w / stage.w_ref)
        moment_model = :analysis_dead_load
    end
    # Cd = 1. The shape stores extrema, not the station of an inflection, so
    # the double-curvature Cd = 2 of Eq. A-6-5 is not applied here.
    # AISC 360-22 Appendix 6.3.1a Eq. A-6-5 (corpus: aisc-360-22, PDF p. 342).
    Vbr = beam_panel_brace_shear(section, Mu)
    return (; w = w, Mu = Mu, Vu = Vu, equation = equation,
            cp_class = stage.cp_class, p_Cp = stage.p_Cp,
            edition = construction_edition(), Vbr = Vbr,
            moment_model = moment_model)
end

"""
    beam_panel_brace_shear(section, Mr; Cd=1.0) -> Force

Required shear strength of a panel brace for a flexural member.

AISC 360-22 Appendix 6.3.1a Eq. A-6-5 (corpus: aisc-360-22, PDF p. 342):

    Vbr = 0.01 · Mr · Cd / ho

`Cd` is 1.0, or 2.0 for the brace closest to the inflection point in double
curvature. `ho` is the distance between flange centroids.

Eq. A-6-6a, the required stiffness, is not evaluated. Appendix 6 defines `Lbr`
as the unbraced length within a panel and does not say what that length is for
deck that braces the flange continuously.
"""
function beam_panel_brace_shear(section::ISymmSection, Mr; Cd::Real=1.0)
    ho = uconvert(u"m", section.ho)
    ustrip(ho) > 0 || throw(ArgumentError(
        "Panel brace shear needs a positive distance between flange centroids."))
    Cd > 0 || throw(ArgumentError("Cd must be positive, got $Cd."))
    return uconvert(u"N", 0.01 * uconvert(u"N*m", Mr) * Cd / ho)
end
