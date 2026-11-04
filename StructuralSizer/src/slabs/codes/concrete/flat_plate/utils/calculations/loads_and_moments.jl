# =============================================================================
# CIP Flat Plate Design per ACI 318-11
# =============================================================================
#
# Methodology: StructurePoint Design Examples (ACI 318-11)
# Equations: Broyles, Solnosky, Brown (2024) - Supplementary Document
#
# Reference: DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf
# Example: 18 ft × 14 ft panel, 16" columns, f'c=4000 psi (slab), fy=60 ksi
#
# =============================================================================
# NOT YET IMPLEMENTED (Future Work)
# =============================================================================
#
# 1. Shear Reinforcement (ACI 318-11 §11.11.5)
#    - Stud rails / headed shear studs for punching shear enhancement
#    - Stirrup cages around columns
#    - vn = vc + vs calculations where shear exceeds concrete capacity
#    Note: Currently punching shear failure requires column size or slab thickness increase
#
# 2. Pattern Loading (ACI 318-11 §13.7.6)  
#    - Only required when L/D > 0.75 (live load > 3/4 dead load)
#    - Checkerboard loading, adjacent spans loaded patterns
#    - Envelope of maximum/minimum moments at each location
#    Note: Current EFM uses full load on all spans (conservative for typical L/D < 0.75)
#
# =============================================================================
# UNIT CONVENTION
# =============================================================================
#
# All public functions use Unitful type signatures for type safety:
#   - Lengths:   Length   (accepts m, ft, inch, etc.)
#   - Areas:     Area     (accepts m², ft², inch², etc.)
#   - Pressures: Pressure (accepts Pa, psi, ksi, psf, etc.)
#   - Moments:   Moment   (accepts N·m, kip·ft, lb·in, etc.)
#
# Internal calculations convert to a consistent system (typically US customary
# for ACI compatibility) and return results with explicit units.
#
# Example:
#   h = min_thickness(FlatPlate(), 16.67u"ft")  # Returns Quantity in inches
#   fc = 4000u"psi"
#   Ec_val = Ec(fc, 150)  # Returns Quantity in psi (wc=150 pcf)
#
# =============================================================================

using Unitful
using Unitful: @u_str
using Asap: kip, ksi, ksf, psf, pcf
using Asap: Length, Area, Volume, SecondMomentOfArea, TorsionalConstant, Pressure, Force, Moment, Torque, LinearLoad


# =============================================================================
# Self-Weight Calculation
# =============================================================================


"""
    slab_self_weight(h, ρ) -> Pressure

Compute slab self-weight from thickness and mass density.

Mass density (ρ, kg/m³) must be multiplied by gravity to get weight density (γ, N/m³).
Then multiplying by thickness gives pressure (load per unit area).

# Arguments
- `h`: Slab thickness (Length)
- `ρ`: Concrete mass density (Density, e.g., kg/m³)

# Returns
- Self-weight as pressure (psf)

# Example
```julia
h = 7u"inch"
ρ = 2400u"kg/m^3"
sw = slab_self_weight(h, ρ)  # ≈ 87.5 psf
```
"""
slab_self_weight(h, ρ) = uconvert(psf, h * ρ * GRAVITY)


"""
    clear_span(l, c; shape=:rectangular)

Clear span from face-to-face of supports.

For circular columns, deducts the equivalent square dimension `c_eq = D√(π/4)`
so that the cross-sectional area is preserved.

# Arguments
- `l`: Center-to-center span
- `c`: Column dimension in span direction (diameter D for circular)
- `shape`: Column shape — `:rectangular` or `:circular`
"""
function clear_span(l::Length, c::Length; shape::Symbol=:rectangular)
    if shape == :circular
        return l - equivalent_square_column(c)
    else
        return l - c
    end
end

"""
    eq13_4_clear_span(l1, ln) -> Length

Clear span to use in Eq. (13-4): `max(ln, 0.65 l1)`.

ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253): "Value of ℓn used in
Eq. (13-4) shall not be less than 0.65ℓ1."  The floor applies to M₀ only;
minimum thickness, shear, and applicability checks use the face-to-face
`clear_span` unchanged.

# Arguments
- `l1`: Center-to-center span in the direction moments are being determined
- `ln`: Face-to-face clear span from `clear_span`
"""
eq13_4_clear_span(l1::Length, ln::Length) = max(ln, 0.65 * l1)

# =============================================================================
# Circular Column Utilities (ACI 318-11 R13.6.2.5)
# =============================================================================

"""
    equivalent_square_column(D) -> Length

Equivalent square column dimension for a circular column of diameter D.

    c_eq = D × √(π/4) ≈ 0.886 D

Preserves cross-sectional area: π D²/4 = c_eq².
Used for clear span, torsional constant, and EFM stiffness calculations.

# Reference
- ACI 318-11 R13.6.2.5
- PCA Notes on ACI 318-11: "For circular columns, use equivalent square"
"""
function equivalent_square_column(D::Length)
    return D * sqrt(π / 4)
end

"""
    circular_column_Ic(D) -> SecondMomentOfArea

Moment of inertia for a circular column section.

    Ic = π D⁴ / 64
"""
function circular_column_Ic(D::Length)
    return π * D^4 / 64
end

# =============================================================================
# Phase 3: Static Moment & Moment Distribution (ACI 318-11 §13.6)
# =============================================================================

"""
    total_static_moment(qu, l2, ln)

Total factored static moment per ACI 318-11 Eq. (13-4).

    M₀ = (qᵤ × l₂ × lₙ²) / 8

# Arguments
- `qu`: Factored uniform load (psf or kPa)
- `l2`: Panel width perpendicular to span direction
- `ln`: Clear span (face-to-face of columns)

# Reference
- ACI 318-11 §13.6.2.2 (Eq. 13-4)
- StructurePoint Example: qu=0.193 ksf, l2=14 ft, ln=16.67 ft → M₀ = 93.82 k-ft
"""
function total_static_moment(qu::Pressure, l2::Length, ln::Length)
    return qu * l2 * ln^2 / 8
end

"""
    interior_unbalanced_moment_eq_13_7(wDu, wLu, ℓn, wDu_other, ℓn_other)

Signed ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258)
for one live-load pattern:

    Mu = 0.07[(w_Du + 0.5 w_Lu) ℓn² − w_Du,other ℓn,other²]

`w_Du` and `w_Lu` are factored line loads `q · ℓ2` on the span that
carries full dead plus half live.  `w_Du_other` is factored dead only
on the other span (R13.6.9: live on that span does not enter).  The
bracket is negative when the dead-only side is heavier.  This function
does not take the absolute value and does not choose which span is
longer — `governing_interior_unbalanced_moment` envelopes both
assignments.
"""
function interior_unbalanced_moment_eq_13_7(
    wDu, wLu, ℓn::Length, wDu_other, ℓn_other::Length,
)
    # ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258).
    return 0.07 * ((wDu + 0.5 * wLu) * ℓn^2 - wDu_other * ℓn_other^2)
end

"""
    governing_interior_unbalanced_moment(qD_a, qL_a, ℓ2_a, ℓn_a,
                                         qD_b, qL_b, ℓ2_b, ℓn_b)

Transfer magnitude of Eq. (13-7).

Service pressures are turned into line loads `w = q · ℓ2` (ACI 318-11
§13.6.2.2, the `q ℓ2` term of Eq. (13-4); corpus: aci-318-11, page 253).
The magnitude is the larger of:

- §9.2.1 Eq. (9-1) `U = 1.4D` and Eq. (9-2) `U = 1.2D + 1.6L`
  (corpus: aci-318-11, page 123).  Eq. (9-2)'s `0.5(Lr or S or R)` is
  zero in this floor pattern, matching `factored_pressure`.
- ENGINEERING JUDGMENT: R13.6.9 (corpus: aci-318-11, page 258) describes
  only full dead plus half live on the *longer* span and dead only on
  the shorter.  The reverse assignment can govern when the shorter span
  carries a heavier dead load (22 ft at 60/100 psf against 20 ft at
  200/100 psf is about 130.4 kip·ft, not the 99.9 kip·ft of the
  commentary pattern under 1.4D).  Both assignments are evaluated and
  the larger magnitude is kept.

`M0` still uses the single `q_u` that maximises total factored pressure.

A negative service load, panel width or clear span is invalid input and
returns NaN, like a non-finite one: ACI 318-11 §13.6.1.5 (corpus:
aci-318-11, page 252) requires loads due to gravity only.  Zero is valid.
Callers holding a trace collector emit the `:failure` event
(`negative_service_load`, `_eq137_transfer_moment`).
"""
function governing_interior_unbalanced_moment(
    qD_a::Pressure, qL_a::Pressure, ℓ2_a::Length, ℓn_a::Length,
    qD_b::Pressure, qL_b::Pressure, ℓ2_b::Length, ℓn_b::Length,
)
    if any(x -> x < zero(x), (qD_a, qL_a, ℓ2_a, ℓn_a)) ||
       any(x -> x < zero(x), (qD_b, qL_b, ℓ2_b, ℓn_b))
        return NaN * kip * u"ft"
    end
    return _eq137_governing_line_loads(
        qD_a * ℓ2_a, qL_a * ℓ2_a, ℓn_a,
        qD_b * ℓ2_b, qL_b * ℓ2_b, ℓn_b,
    )
end

"""
Line-load form of `governing_interior_unbalanced_moment`.

`wD` / `wL` are service `Σ q_i · ℓ2,i` on each adjoining span.  Same
envelope as the pressure form: both §9.2.1 gravity combinations, both
choices of which span carries half live.  A non-finite input or pattern
`Mu` returns NaN (never a finite magnitude).  A negative line load or
clear span returns NaN too (§13.6.1.5, gravity loads only; corpus:
aci-318-11, page 252); zero is valid.
"""
function _eq137_governing_line_loads(wD_a, wL_a, ℓn_a::Length,
                                     wD_b, wL_b, ℓn_b::Length)
    if any(x -> x < zero(x), (wD_a, wL_a, ℓn_a, wD_b, wL_b, ℓn_b))
        return NaN * kip * u"ft"
    end
    # ENGINEERING JUDGMENT: see `governing_interior_unbalanced_moment`.
    # R13.6.9 names only the longer-span pattern; both assignments are
    # evaluated and the larger magnitude is returned.
    best = zero(1.0kip * u"ft")
    # ACI 318-11 §9.2.1 Eq. (9-2) then Eq. (9-1) (corpus: aci-318-11, page 123).
    for (Df, Lf) in (
        (strength_1_2D_1_6L.D, strength_1_2D_1_6L.L),
        (strength_1_4D.D, strength_1_4D.L),
    )
        for (wD, wL, ln, wDo, lno) in (
            (wD_a, wL_a, ℓn_a, wD_b, ℓn_b),
            (wD_b, wL_b, ℓn_b, wD_a, ℓn_a),
        )
            Mu = interior_unbalanced_moment_eq_13_7(
                Df * wD, Lf * wL, ln, Df * wDo, lno)
            # A NaN never wins `abs(Mu) > abs(best)`; return it so callers
            # reject the connection instead of seeing a finite 0.
            isfinite(Mu) || return NaN * kip * u"ft"
            if abs(Mu) > abs(best)
                best = Mu
            end
        end
    end
    return abs(best)
end

