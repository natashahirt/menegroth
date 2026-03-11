# ==============================================================================
# Composite Deflection — Transformed Moment of Inertia & I_LB
# ==============================================================================
# AISC 360-16 Commentary on Section I3.2 and AISC Manual Table 3-20 approach.

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

Lower-bound moment of inertia for partially composite beams per AISC Manual
Eq. C-I3-1 (Commentary on Section I3.2).

Uses the stress-block centroid (Y2 method) consistent with AISC Manual
Tables 3-19/3-20:

    a  = Cf / (0.85 fc′ b_eff)
    Y2 = (gap + ts) − a/2          (top of steel to concrete resultant)
    Aₑ = Cf / Fy                   (effective area, transformed to steel)
    YENA from bottom of steel via parallel axis theorem
    I_LB = Is + As×(YENA − d/2)² + Aₑ×(d + Y2 − YENA)²

For full composite (`ΣQn ≥ Cf_max`), delegates to `get_I_transformed`.
For zero composite, returns `section.Ix`.
"""
function get_I_LB(section::ISymmSection, material, slab::AbstractSlabOnBeam,
                  b_eff, ΣQn)
    Cf_max = _Cf_max(section, material, slab, b_eff)
    Cf = min(uconvert(u"N", ΣQn), uconvert(u"N", Cf_max))

    if ustrip(u"N", Cf) ≤ 0.0
        return section.Ix
    end

    if Cf >= uconvert(u"N", Cf_max)
        return get_I_transformed(section, slab, b_eff)
    end

    Is  = section.Ix
    As  = section.A
    Fy  = material.Fy
    d   = section.d
    ts  = slab.t_slab
    gap = _gap_above_steel(slab)

    # Stress block depth: a = Cf / (0.85 fc′ b_eff)
    a = Cf / (0.85 * slab.fc′ * b_eff)

    Ae = Cf / Fy

    # Y2 = distance from top of steel to concrete resultant (AISC notation)
    Y2 = gap + ts - a / 2

    # Centroids from bottom of steel section
    ȳ_steel = d / 2
    ȳ_conc  = d + Y2

    A_total = As + Ae
    ȳ_ENA = (As * ȳ_steel + Ae * ȳ_conc) / A_total

    I_LB = Is + As * (ȳ_ENA - ȳ_steel)^2 + Ae * (ȳ_conc - ȳ_ENA)^2

    return I_LB
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
                                δ_const_limit=nothing) -> NamedTuple

Check deflections for a composite beam under uniform load.

# Shored vs Unshored (AISC I3.1b / Commentary):
- **Unshored**: Dead load deflection uses steel-alone Ix (wet concrete applied before composite).
  Live load deflection uses I_LB (composite section).
- **Shored**: All load deflection uses I_LB (entire load applied after composite).

# Arguments
- `w_DL`: Distributed dead load (weight per length)
- `w_LL`: Distributed live load (weight per length)
- `δ_limit_ratio`: Maximum LL deflection ratio (default L/360)
- `δ_const_limit`: Optional absolute limit for construction deflection (e.g., 2.5 in.)

# Returns
- `δ_DL`, `δ_LL`, `δ_total`: Computed deflections
- `ok_LL`: Live load deflection check passes
- `ok_const`: Construction deflection check passes (only if `δ_const_limit` is set)
"""
function check_composite_deflection(section::ISymmSection, material,
                                     slab::AbstractSlabOnBeam, b_eff, ΣQn,
                                     L, w_DL, w_LL;
                                     shored::Bool=false,
                                     δ_limit_ratio=1/360,
                                     δ_const_limit=nothing)
    Es = material.E
    I_steel = section.Ix
    I_LB = get_I_LB(section, material, slab, b_eff, ΣQn)

    # 5wL⁴ / (384 E I)
    coeff = 5 * L^4 / (384 * Es)

    if shored
        # All loads on composite section
        δ_DL = coeff * w_DL / I_LB
        δ_LL = coeff * w_LL / I_LB
    else
        # DL on steel alone, LL on composite
        δ_DL = coeff * w_DL / I_steel
        δ_LL = coeff * w_LL / I_LB
    end

    δ_total = δ_DL + δ_LL
    δ_LL_limit = L * δ_limit_ratio

    ok_LL = δ_LL <= δ_LL_limit

    # Construction deflection (unshored only)
    ok_const = true
    δ_const = δ_DL  # construction DL ≈ total DL for unshored
    if !shored && δ_const_limit !== nothing
        ok_const = δ_const <= δ_const_limit
    end

    return (; δ_DL=uconvert(u"mm", δ_DL),
              δ_LL=uconvert(u"mm", δ_LL),
              δ_total=uconvert(u"mm", δ_total),
              δ_LL_limit=uconvert(u"mm", δ_LL_limit),
              ok_LL, ok_const, I_LB)
end
