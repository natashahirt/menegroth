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

"""
    beam_slab_alpha_f(Ecb, Ib, Ecs, Is) -> Float64

αf = Ecb Ib / Ecs Is. ACI 318-11 Eq. (13-3) (corpus: aci-318-11, PDF page 253).

`Ib` is the gross moment of inertia of the beam stem. The sentence that
puts a slab flange into the beam section did not survive the text layer,
so the slab is not added to `Ib`. `Is` is the gross inertia of the slab
width bounded by the centerlines of the adjacent panels (notation, page 29):
`ls · h³ / 12`.
"""
function beam_slab_alpha_f(Ecb, Ib, Ecs, Is)
    Is_m4 = ustrip(u"m^4", Is)
    Is_m4 > 0 || throw(ArgumentError(
        "Is must be positive. ACI 318-11 Eq. (13-3) (corpus: aci-318-11, PDF page 253)."))
    Ecs_Pa = ustrip(u"Pa", Ecs)
    Ecs_Pa > 0 || throw(ArgumentError("Ecs must be positive (Eq. 13-3)."))
    return ustrip(u"Pa", Ecb) * ustrip(u"m^4", Ib) / (Ecs_Pa * Is_m4)
end

"""Gross inertia of a slab strip, `ls · h³ / 12`."""
slab_strip_inertia(ls::Length, h::Length) = ls * h^3 / 12

"""Average αf on the edges of one panel. ACI 318-11 notation, page 29."""
function panel_alpha_fm(alphas::AbstractVector{<:Real})
    isempty(alphas) && throw(ArgumentError(
        "αfm is the average αf of the beams on the edges of a panel."))
    any(a -> a < 0, alphas) && throw(ArgumentError("αf cannot be negative."))
    return sum(alphas) / length(alphas)
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

"""
    one_way_support_condition(end_a, end_b) -> SupportCondition

Table 9.5(a) condition of a span from its two ends. Each end is `:free`,
`:supported` (a beam or wall the slab stops at), or `:continuous` (a support
the slab runs past). A span with one free end is a cantilever. A span
between two supports is simple, one-end continuous, or both-ends continuous.

ACI 318-11 §9.5.2.1 and Table 9.5(a) (corpus: aci-318-11, page 131).
"""
function one_way_support_condition(end_a::Symbol, end_b::Symbol)
    known = (:free, :supported, :continuous)
    (end_a in known && end_b in known) || throw(ArgumentError(
        "a one-way span end is :free, :supported, or :continuous; got $end_a and $end_b"))
    ends = (end_a, end_b)
    count(==( :free), ends) == 2 && throw(ArgumentError(
        "a one-way span has no beam or wall at either end"))
    count(==( :free), ends) == 1 && return CANTILEVER
    n = count(==( :continuous), ends)
    n >= 2 && return BOTH_ENDS_CONT
    n == 1 && return ONE_END_CONT
    return SIMPLE
end

"""The condition that requires the thicker slab. ACI 318-11 Table 9.5(a) (corpus: aci-318-11, page 131): cantilever ℓ/10, simple ℓ/20, one end ℓ/24, both ends ℓ/28."""
function thicker_support(a::SupportCondition, b::SupportCondition)
    rank(s) = s == CANTILEVER ? 10 : s == SIMPLE ? 20 : s == ONE_END_CONT ? 24 : 28
    return rank(a) <= rank(b) ? a : b
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

