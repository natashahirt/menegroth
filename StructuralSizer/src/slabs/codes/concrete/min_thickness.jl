# =============================================================================
# ACI 318 Minimum Slab Thickness (Deflection Control)
# =============================================================================
#
# Tabulated minimum-thickness rules that bypass explicit deflection calculation.
# Each method dispatches on the floor-system type so callers can write
#
#     h = min_thickness(FlatPlate(), ln; discontinuous_edge=true)
#
# without pulling in the full sizing pipeline.
#
# References
# ----------
# ACI 318-11 Table 9.5(c)   → flat plate, flat slab
# ACI 318-19 Table 8.3.1.1  → flat plate, flat slab (renumbered)
# ACI 318-19 Table 8.3.1.2  → two-way slabs with beams
# ACI 318-19 Table 7.3.1.1  → one-way slabs
# ACI 318-11 §9.8           → waffle (two-way joist)
# PTI DC20.9                → PT banded slabs
# =============================================================================

# -----------------------------------------------------------------------------
# Flat Plate (no drop panels) — ACI Table 9.5(c) Row 1
# -----------------------------------------------------------------------------

"""
    min_thickness(::FlatPlate, ln; discontinuous_edge=false)

Minimum flat-plate thickness per ACI 318-11 Table 9.5(c) Row 1.

| Panel location | Divisor |
|:-------------- |:------- |
| Interior       | 33      |
| Exterior       | 30      |

Absolute minimum: 5 in (ACI §9.5.3.2).
"""
function min_thickness(::FlatPlate, ln::Length; discontinuous_edge::Bool=false)
    divisor = discontinuous_edge ? 30 : 33
    return max(ln / divisor, 5.0u"inch")
end

# -----------------------------------------------------------------------------
# Flat Slab (with drop panels) — ACI Table 9.5(c) Row 2
# -----------------------------------------------------------------------------

"""
    min_thickness(::FlatSlab, ln; discontinuous_edge=false)

Minimum flat-slab thickness per ACI 318-11 Table 9.5(c) Row 2.
Drop panels conforming to §8.2.4 allow thinner slabs:

| Panel location | Divisor |
|:-------------- |:------- |
| Interior       | 36      |
| Exterior       | 33      |

Absolute minimum: 4 in (ACI §9.5.3.2).
"""
function min_thickness(::FlatSlab, ln::Length; discontinuous_edge::Bool=false)
    divisor = discontinuous_edge ? 33 : 36
    return max(ln / divisor, 4.0u"inch")
end

# -----------------------------------------------------------------------------
# Two-Way with Beams — ACI Table 8.3.1.2
# -----------------------------------------------------------------------------

"""
    min_thickness(::TwoWay, ln; fy=60000psi)

Minimum two-way slab thickness with beams on all sides.

    h = ln × (0.8 + fy / 200 000 psi) / 36

Absolute minimum: 3.5 in.

Ref: ACI 318-19 Table 8.3.1.2 (αfm > 2.0 row, simplified).
"""
function min_thickness(::TwoWay, ln::Length; fy::Pressure=60000u"psi")
    h = ln * (0.8 + fy / (200_000u"psi")) / 36
    return max(h, 3.5u"inch")
end

# -----------------------------------------------------------------------------
# One-Way — ACI Table 7.3.1.1
# -----------------------------------------------------------------------------

"""
    min_thickness(::OneWay, ln; fy=60000psi, support=BOTH_ENDS_CONT)

Minimum one-way slab thickness per ACI 318-19 Table 7.3.1.1.

    h = ln × (0.4 + fy / 100 000 psi) / divisor

| Support condition | Divisor |
|:----------------- |:------- |
| Simply supported  | 20      |
| One end continuous | 24      |
| Both ends continuous | 28   |
| Cantilever        | 10      |

Absolute minimum: 4 in.
"""
function min_thickness(::OneWay, ln::Length;
                       fy::Pressure=60000u"psi",
                       support::SupportCondition=BOTH_ENDS_CONT)
    fy_factor = 0.4 + fy / (100_000u"psi")
    divisor = if support == SIMPLE;          20
              elseif support == ONE_END_CONT;     24
              elseif support == BOTH_ENDS_CONT;   28
              elseif support == CANTILEVER;        10
              else                                 24 end
    return max(ln * fy_factor / divisor, 4.0u"inch")
end

# -----------------------------------------------------------------------------
# Waffle (Two-Way Joist) — ACI §9.8
# -----------------------------------------------------------------------------

"""
    min_thickness(::Waffle, ln)

Minimum waffle-slab total depth.
Rule of thumb: span/20 to span/24 (uses span/22 as default).

Absolute minimum: 8 in (practical for standard pan forms).

Ref: ACI 318-11 §9.8 (two-way joist construction).
"""
function min_thickness(::Waffle, ln::Length)
    return max(ln / 22, 8.0u"inch")
end

# -----------------------------------------------------------------------------
# PT Banded — PTI DC20.9
# -----------------------------------------------------------------------------

"""
    min_thickness(::PTBanded, ln; has_drops=false)

Minimum post-tensioned banded-slab thickness per PTI guidelines.

| Configuration  | Divisor |
|:-------------- |:------- |
| Without drops  | 45      |
| With drops     | 50      |

Absolute minimum: 5 in.
"""
function min_thickness(::PTBanded, ln::Length; has_drops::Bool=false)
    divisor = has_drops ? 50.0 : 45.0
    return max(ln / divisor, 5.0u"inch")
end

