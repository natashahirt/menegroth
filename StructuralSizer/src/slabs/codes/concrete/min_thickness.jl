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
# ACI 318-11 Table 9.5(c)    → flat plate, flat slab
# ACI 318-11 §9.5.3.3        → two-way slabs with beams (αfm)
# ACI 318-11 Table 9.5(a)    → one-way slabs
# ACI 318-11 §9.8            → waffle (two-way joist)
# PTI DC20.9                 → PT banded slabs
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
# Two-Way with Beams — ACI 318-11 §9.5.3.3, Eq. (9-13)
# -----------------------------------------------------------------------------

"""
Divisor of `ln` from ACI 318-11 Table 9.5(c), exterior panel, no drop, no edge beam.

The row is the thickest in the table. `fy` is interpolated between 40, 60,
and 75 ksi. ACI 318-11 §9.5.3.2 (corpus: aci-318-11, PDF page 134).
"""
function _table_9_5c_exterior_divisor(fy::Pressure)
    fy_ksi = ustrip(u"ksi", fy)
    (40.0 <= fy_ksi <= 75.0) || throw(ArgumentError(
        "Table 9.5(c) interpolates fy between 40 and 75 ksi, got $(fy). " *
        "ACI 318-11 §9.5.3.2 (corpus: aci-318-11, PDF page 134)."))
    if fy_ksi <= 60.0
        t = (fy_ksi - 40.0) / 20.0
        return 33.0 + (30.0 - 33.0) * t
    end
    t = (fy_ksi - 60.0) / 15.0
    return 30.0 + (28.0 - 30.0) * t
end

"""
    min_thickness(::TwoWay, ln; fy=60000psi, αfm=nothing, β=nothing,
                  discontinuous_edge=false)

Minimum thickness of a slab with beams on all sides.

`αfm` is the average beam-to-slab stiffness ratio. Until it is known, the
slab is treated as αfm ≤ 0.2 and uses Table 9.5(c) through §9.5.3.3(a).
The exterior panel without an edge beam is the thickest column of that table.

When `αfm` is given, `β` is the long clear span divided by the short clear
span and must be at least 1.

- αfm ≤ 0.2: Table 9.5(c), and not less than 5 in. §9.5.3.3(a), §9.5.3.2.
  The table applies when the long-to-short ratio is not greater than 2.
  A larger ratio is classified one-way before this function runs.
- 0.2 < αfm ≤ 2.0: Eq. (9-12), and not less than 5 in. §9.5.3.3(b).
- αfm > 2.0: Eq. (9-13), and not less than 3.5 in. §9.5.3.3(c).

`discontinuous_edge` increases the Eq. (9-12) or Eq. (9-13) value by
10 percent, and the inch floor still applies. §9.5.3.3(d).

ACI 318-11 §9.5.3.3 (corpus: aci-318-11, PDF pages 134–135).
"""
function min_thickness(::TwoWay, ln::Length;
                       fy::Pressure=60000u"psi",
                       αfm::Union{Nothing, Real}=nothing,
                       β::Union{Nothing, Real}=nothing,
                       discontinuous_edge::Bool=false)
    if αfm === nothing || αfm <= 0.2
        αfm !== nothing && αfm < 0 && throw(ArgumentError(
            "αfm is $(αfm). The stiffness ratio cannot be negative. " *
            "ACI 318-11 §9.5.3.3 (corpus: aci-318-11, PDF page 134)."))
        if β !== nothing && β > 2
            throw(ArgumentError(
                "Table 9.5(c) applies when the long-to-short span ratio is " *
                "not greater than 2 (got β = $(β)). ACI 318-11 §9.5.3.2 " *
                "(corpus: aci-318-11, PDF page 134)."))
        end
        divisor = _table_9_5c_exterior_divisor(fy)
        return max(ln / divisor, 5.0u"inch")
    end
    β === nothing && throw(ArgumentError(
        "two-way thickness with αfm = $(αfm) needs β, the long clear span " *
        "divided by the short clear span. ACI 318-11 §9.5.3.3 " *
        "(corpus: aci-318-11, PDF page 135)."))
    β >= 1 || throw(ArgumentError(
        "β is $(β). It is the long clear span divided by the short clear span, " *
        "so it is at least 1. ACI 318-11 §9.5.3.3 (corpus: aci-318-11, PDF page 135)."))
    # ACI 318-11 Eq. (9-12) and Eq. (9-13), PDF page 134.
    # h = ln · (0.8 + fy / 200,000) / denominator.
    factor = 0.8 + ustrip(u"psi", fy) / 200_000
    if αfm <= 2.0
        h = ln * factor / (36 + 5 * β * (Float64(αfm) - 0.2))
        floor_h = 5.0u"inch"
    else
        h = ln * factor / (36 + 9 * β)
        floor_h = 3.5u"inch"
    end
    # §9.5.3.3(d), PDF page 135. Ten percent applies to the equation
    # value. The inch floor is a separate lower bound.
    discontinuous_edge && (h *= 1.10)
    return max(h, floor_h)
end

# -----------------------------------------------------------------------------
# One-Way — ACI 318-11 Table 9.5(a)
# -----------------------------------------------------------------------------

"""
    min_thickness(::OneWay, ln; fy=60000psi, support=BOTH_ENDS_CONT)

Minimum one-way slab thickness per ACI 318-11 Table 9.5(a).

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

