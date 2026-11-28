# ==============================================================================
# Composite Deflection — Transformed Moment of Inertia & I_LB
# ==============================================================================
# References:
#   - AISC 360-22 Commentary §I3, Eqs. C-I3-1 and C-I3-2 (corpus: aisc-360-22,
#     PDF pp. 501–502). I_LB is the lower-bound inertia at every degree of
#     composite action, including full composite action.
#   - Eq. C-I3-9 (PDF p. 505) for the compression-block depth `a`, and
#     Eqs. C-I3-6 through C-I3-8 (PDF p. 505) for the compression force that
#     `d_1` locates. The force is the smallest of Fy·As, 0.85·f′c·Ac, and ΣQn.
#   - `get_I_transformed` is the uncracked transformed inertia I_tr used by
#     Commentary Eq. C-I3-3. It is not I_LB.

# ==============================================================================
# Transformed Moment of Inertia (Full Composite)
# ==============================================================================

"""
    get_I_transformed(section::ISymmSection, slab::AbstractSlabOnBeam, b_eff) -> SecondMomentOfArea

Full-composite transformed moment of inertia using the modular ratio n = Es/Ec.

Transforms the concrete slab into an equivalent steel area `(b_eff / n) × t_slab`,
then computes the composite I about the centroidal axis of the transformed section.

For `DeckSlabOnBeam`, only the concrete above the deck ribs is transformed. The
concrete centroid is at `d + hr + t_slab/2` from the bottom of the steel section
(the rib height creates a gap between the steel top flange and the concrete).
"""
function get_I_transformed(section::ISymmSection, slab::AbstractSlabOnBeam, b_eff)
    n  = slab.n
    As = section.A
    Is = section.Ix
    d  = section.d
    ts = slab.t_slab

    b_tr  = b_eff / n
    Ac_tr = b_tr * ts
    Ic_tr = b_tr * ts^3 / 12

    ȳ_steel = d / 2
    ȳ_conc  = d + _gap_above_steel(slab) + ts / 2

    A_total = As + Ac_tr
    ȳ_comp = (As * ȳ_steel + Ac_tr * ȳ_conc) / A_total

    I_comp = Is + As * (ȳ_comp - ȳ_steel)^2 +
             Ic_tr + Ac_tr * (ȳ_conc - ȳ_comp)^2

    return I_comp
end

## _gap_above_steel is defined in types.jl (shared by flexure.jl and deflection.jl)

# ==============================================================================
# Lower-Bound Moment of Inertia (Partial Composite)
# ==============================================================================

"""
    get_I_LB(section::ISymmSection, material, slab::AbstractSlabOnBeam,
             b_eff, ΣQn) -> SecondMomentOfArea

Lower-bound moment of inertia `I_LB` from AISC 360-22 Commentary Eqs. C-I3-1
and C-I3-2 (corpus: aisc-360-22, PDF pp. 501–502):

    I_LB  = I_s + A_s (Y_ENA − d_3)² + (ΣQ_n / F_y) (2d_3 + d_1 − Y_ENA)²
    Y_ENA = [A_s d_3 + (ΣQ_n / F_y) (2d_3 + d_1)] / [A_s + ΣQ_n / F_y]

`d_3` is the distance from the top of the steel to the resultant of full-section
tension yield. On an `ISymmSection` that resultant is the centroid, so
`d_3 = d/2`. `d_1` is the distance from the top of the steel up to the concrete
compression force. The block depth is Eq. C-I3-9, `a = C / (0.85 f′c b)`, so
the block centroid gives `d_1 = gap + t_slab − a/2`.

The compression force `C` is the smallest of `F_y A_s`, `0.85 f′c A_c`, and
`ΣQ_n` (Eqs. C-I3-6, C-I3-7, C-I3-8, PDF p. 505). `ΣQ_n` above that smallest
value is not a larger concrete force. `C = 0` returns the steel `I_s`, which is
Eq. C-I3-1 with `ΣQ_n = 0`.

This is not the uncracked transformed inertia. `I_tr` from
[`get_I_transformed`](@ref) is the upper end of Eq. C-I3-3 and is larger.
"""
function get_I_LB(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                  b_eff, ΣQn)
    # C = min(Fy As, 0.85 f′c Ac, ΣQn). Eqs. C-I3-6, C-I3-7, C-I3-8.
    Cf_max = _Cf_max(section, material, slab, b_eff)
    Cf = min(uconvert(u"N", ΣQn), uconvert(u"N", Cf_max))

    if ustrip(u"N", Cf) ≤ 0.0
        return section.Ix
    end

    Is  = section.Ix
    As  = section.A
    Fy  = material.Fy
    d   = section.d
    ts  = slab.t_slab
    gap = _gap_above_steel(slab)

    # Eq. C-I3-9. d_1 is the block centroid above the top of steel.
    a = Cf / (0.85 * slab.fc′ * b_eff)
    d_1 = gap + ts - a / 2
    d_3 = d / 2
    Ae = Cf / Fy

    # Eq. C-I3-2, measured from the bottom of the steel: the steel resultant
    # sits at d_3 and the concrete resultant at 2d_3 + d_1.
    Y_ENA = (As * d_3 + Ae * (2 * d_3 + d_1)) / (As + Ae)

    # Eq. C-I3-1.
    return Is + As * (Y_ENA - d_3)^2 + Ae * (2 * d_3 + d_1 - Y_ENA)^2
end

"""
    get_I_cracked_negative(section::ISymmSection, Asr; d_rebar=0.0u"m") -> SecondMomentOfArea

Cracked negative-moment inertia of the steel section plus the developed
longitudinal slab reinforcement `Asr`, about their combined centroid:

    ȳ    = [A_s (d/2) + A_sr (d + d_rebar)] / (A_s + A_sr)
    I_cr = I_s + A_s (ȳ − d/2)² + A_sr (d + d_rebar − ȳ)²

`d_rebar` is the height of the bar centroid above the top of the steel, the
convention of [`get_Mn_negative`](@ref). The default 0 places the bars at the
top of the steel, which gives the smallest `I_cr`. `Asr = 0` returns `I_s`.

# ENGINEERING JUDGMENT
AISC 360-22 Commentary Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502) names
`I_neg` as the effective inertia for negative moment and gives no equation.
This is the cracked transformed section: concrete in tension carries nothing,
and the bars have the steel modulus, so they enter at their own area. Only the
developed bars over the support count; temperature and shrinkage steel does
not. The bar's own inertia about its centroid is omitted.
"""
function get_I_cracked_negative(section::ISymmSection, Asr; d_rebar=0.0u"m")
    Is  = section.Ix
    As  = section.A
    d   = section.d
    Asr = uconvert(unit(As), Asr)
    ustrip(Asr) > 0 || return Is
    y_s = d / 2
    y_r = d + uconvert(unit(d), d_rebar)
    ȳ = (As * y_s + Asr * y_r) / (As + Asr)
    return Is + As * (ȳ - y_s)^2 + Asr * (y_r - ȳ)^2
end

"""
    composite_negative_inertia(section, ctx::CompositeContext; d_rebar=nothing)

`I_neg` for Eq. C-I3-5 from the context: [`get_I_cracked_negative`](@ref) when
`ctx.neg_moment` is set and `ctx.Asr > 0` (anchors in the negative region and
developed bars, §I3.2b), otherwise the steel `I_s`.

`d_rebar` defaults to `ctx.d_rebar`. Passing it overrides that height for this call.
"""
function composite_negative_inertia(section::ISymmSection, ctx::CompositeContext;
                                    d_rebar=nothing)
    ctx.neg_moment || return section.Ix
    d = d_rebar === nothing ? ctx.d_rebar : d_rebar
    return get_I_cracked_negative(section, ctx.Asr; d_rebar=d)
end

"""
    composite_service_inertia(I_pos, I_neg; continuous=false, for_drift=false)

Member stiffness for an elastic analysis of a composite beam.

AISC 360-22 Commentary Eq. C-I3-5 (corpus: aisc-360-22, PDF p. 502):

    I = a I_pos + b I_neg

`I_pos` is the positive-moment inertia. Callers pass `I_LB` from Eq. C-I3-1.
A beam with no negative-moment region keeps `I_pos`. A continuous beam under
gravity uses `a = 0.6` and `b = 0.4`. Drift of a composite moment frame uses
`a = b = 0.5`.

`I_neg` comes from [`composite_negative_inertia`](@ref): the cracked section
with developed bars when the context declares them, otherwise `I_s`.
"""
function composite_service_inertia(I_pos, I_neg; continuous::Bool=false, for_drift::Bool=false)
    continuous || return I_pos
    a, b = for_drift ? (0.5, 0.5) : (0.6, 0.4)
    return a * I_pos + b * I_neg
end

"""
    positive_inertia_for_service(I_service, I_neg; continuous=false, for_drift=false)

Positive-moment inertia that makes Eq. C-I3-5 equal `I_service`.

The stud layout is chosen on `I_LB`. A continuous beam is checked on the
weighted inertia, so the layout has to reach the `I_pos` that produces the
required service inertia. A beam that is not continuous returns `I_service`.
"""
function positive_inertia_for_service(I_service, I_neg; continuous::Bool=false, for_drift::Bool=false)
    continuous || return I_service
    a, b = for_drift ? (0.5, 0.5) : (0.6, 0.4)
    return max((I_service - b * I_neg) / a, zero(I_service))
end

# ==============================================================================
# Composite Deflection Check
# ==============================================================================

"""
    check_composite_deflection(section::ISymmSection, material,
                                slab::AbstractSlabOnBeam, b_eff, ΣQn,
                                L, w_DL, w_LL;
                                shored::Bool=false,
                                δ_limit_ratio=1/360,
                                δ_total_limit_ratio=1/240,
                                δ_const_limit=nothing) -> NamedTuple

Check deflections for a composite beam under uniform load.

# Shored vs Unshored (AISC I3.1b / Commentary):
- **Unshored**: Dead load deflection uses steel-alone Ix (wet concrete applied before composite).
  Live load deflection uses I_LB, or Eq. C-I3-5 when `continuous` is set.
- **Shored**: All load deflection uses that same service inertia.

# Arguments
- `w_DL`: Distributed dead load (weight per length)
- `w_LL`: Distributed live load (weight per length)
- `δ_limit_ratio`: Maximum LL deflection ratio (default L/360)
- `δ_total_limit_ratio`: Maximum DL+LL deflection ratio (default L/240). `nothing` to skip.
- `δ_const_limit`: Optional absolute limit for construction deflection (e.g., 2.5 in.)
- `I_neg`: Negative-moment inertia for Eq. C-I3-5 when `continuous`; default `I_s`.
  Pass [`get_I_cracked_negative`](@ref) for developed slab bars.

# Returns
- `δ_DL`, `δ_LL`, `δ_total`: Computed deflections
- `ok_LL`: Live load deflection check passes
- `ok_total`: Total (DL+LL) deflection check passes
- `ok_const`: Construction deflection check passes (only if `δ_const_limit` is set)
"""
function check_composite_deflection(section::ISymmSection, material,
                                     slab::AbstractSlabOnBeam, b_eff, ΣQn,
                                     L, w_DL, w_LL;
                                     shored::Bool=false,
                                     δ_limit_ratio=1/360,
                                     δ_total_limit_ratio=1/240,
                                     δ_const_limit=nothing,
                                     continuous::Bool=false,
                                     for_drift::Bool=false,
                                     I_neg=section.Ix)
    Es = material.E
    I_steel = section.Ix
    I_LB = get_I_LB(section, material, slab, b_eff, ΣQn)
    # Eq. C-I3-5. A beam with no negative region keeps I_LB.
    I_service = composite_service_inertia(I_LB, I_neg;
                                          continuous=continuous, for_drift=for_drift)

    coeff = 5 * L^4 / (384 * Es)

    if shored
        δ_DL = coeff * w_DL / I_service
        δ_LL = coeff * w_LL / I_service
    else
        δ_DL = coeff * w_DL / I_steel
        δ_LL = coeff * w_LL / I_service
    end

    δ_total = δ_DL + δ_LL
    δ_LL_limit = L * δ_limit_ratio

    ok_LL = δ_LL <= δ_LL_limit

    # Total deflection check (DL+LL)
    ok_total = true
    δ_total_limit = if !isnothing(δ_total_limit_ratio)
        L * δ_total_limit_ratio
    else
        nothing
    end
    if !isnothing(δ_total_limit)
        ok_total = δ_total <= δ_total_limit
    end

    # Construction deflection (unshored only)
    ok_const = true
    δ_const = δ_DL
    if !shored && δ_const_limit !== nothing
        ok_const = δ_const <= δ_const_limit
    end

    return (; δ_DL=uconvert(u"mm", δ_DL),
              δ_LL=uconvert(u"mm", δ_LL),
              δ_total=uconvert(u"mm", δ_total),
              δ_LL_limit=uconvert(u"mm", δ_LL_limit),
              δ_total_limit=isnothing(δ_total_limit) ? nothing : uconvert(u"mm", δ_total_limit),
              ok_LL, ok_total, ok_const, I_LB, I_service)
end
