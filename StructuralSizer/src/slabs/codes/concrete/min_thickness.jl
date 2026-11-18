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
# ACI 318-11 §9.5.3.3        → two-way slabs with beams (αfm, Eq. 9-12/9-13)
# ACI 318-11 Table 9.5(a)    → one-way slabs
# ACI 318-11 §9.8            → waffle (two-way joist)
# PTI DC20.9                 → PT banded slabs
# =============================================================================

# -----------------------------------------------------------------------------
# Flat Plate (no drop panels) — ACI Table 9.5(c) Row 1
# -----------------------------------------------------------------------------

"""
    min_thickness(::FlatPlate, ln; discontinuous_edge=false, fy=60 ksi)

Minimum flat-plate thickness per ACI 318-11 Table 9.5(c), without drop
panels (corpus: aci-318-11, page 134). Divisors at fy = 40 / 60 / 75 ksi,
interpolated linearly between (footnote †):

| Panel location | Divisor |
|:-------------- |:------- |
| Interior, and exterior with edge beams | 36 / 33 / 31 |
| Exterior without edge beams | 33 / 30 / 28 |

`discontinuous_edge=true` selects the exterior-without-edge-beams column.
A wall along the slab edge is that case. Footnote § allows the thinner
with-edge-beams column only for a beam with αf ≥ 0.8. The table does not
name a wall, so a wall is not taken as that beam.

Absolute minimum: 5 in (§9.5.3.2(a)).
"""
function min_thickness(::FlatPlate, ln::Length; discontinuous_edge::Bool=false,
                       fy::Pressure=60000u"psi")
    return max(_table_9_5c(ln, fy; exterior = discontinuous_edge, drops = false), 5.0u"inch")
end

# -----------------------------------------------------------------------------
# Flat Slab (with drop panels) — ACI Table 9.5(c) Row 2
# -----------------------------------------------------------------------------

"""
    min_thickness(::FlatSlab, ln; discontinuous_edge=false, fy=60 ksi)

Minimum flat-slab thickness per ACI 318-11 Table 9.5(c), with drop panels
as defined in §13.2.5 (corpus: aci-318-11, page 134). Divisors at
fy = 40 / 60 / 75 ksi, interpolated linearly between (footnote †):

| Panel location | Divisor |
|:-------------- |:------- |
| Interior, and exterior with edge beams | 40 / 36 / 34 |
| Exterior without edge beams | 36 / 33 / 31 |

Absolute minimum: 4 in (§9.5.3.2(b)).
"""
function min_thickness(::FlatSlab, ln::Length; discontinuous_edge::Bool=false,
                       fy::Pressure=60000u"psi")
    return max(_table_9_5c(ln, fy; exterior = discontinuous_edge, drops = true), 4.0u"inch")
end

# -----------------------------------------------------------------------------
# Two-Way with Beams — ACI 318-11 §9.5.3.3, Eq. (9-13)
# -----------------------------------------------------------------------------

"""
    alpha_f(Ecb, Ib, Ecs, slab_width, h) -> Float64

Beam-to-slab flexural stiffness ratio, ACI 318-11 Eq. (13-3) (corpus:
aci-318-11, page 253):

    αf = Ecb·Ib / (Ecs·Is)

`Is` is the gross slab moment of inertia, `slab_width·h³/12`, where
`slab_width` is bounded laterally by the centerlines of the adjacent panels
on each side of the beam (notation for αf, page 29). `Ib` is the gross beam
section about its centroid. For monolithic or fully composite construction
it includes slab on each side equal to the beam projection above or below
the slab, not more than four slab thicknesses (§13.2.4, page 244).
"""
function alpha_f(Ecb::Pressure, Ib, Ecs::Pressure, slab_width::Length, h::Length)
    Is = slab_width * h^3 / 12
    return Float64(uconvert(NoUnits, Ecb * Ib / (Ecs * Is)))
end

"""
    alpha_fm(alphas) -> Float64

Average αf for all beams on the edges of a panel (notation for αfm,
ACI 318-11, corpus: aci-318-11, page 29).
"""
function alpha_fm(alphas)
    isempty(alphas) && throw(ArgumentError("αfm needs at least one beam"))
    return sum(alphas) / length(alphas)
end

# ACI 318-11 Table 9.5(c) (corpus: aci-318-11, page 134). Divisors of ln by
# fy: exterior without edge beams, and interior (the exterior-with-edge-beams
# column equals interior), without and with drop panels.
const _TABLE_9_5C_FY_PSI = (40_000.0, 60_000.0, 75_000.0)
const _TABLE_9_5C_EXTERIOR = (33.0, 30.0, 28.0)
const _TABLE_9_5C_INTERIOR = (36.0, 33.0, 31.0)
const _TABLE_9_5C_DROP_EXTERIOR = (36.0, 33.0, 31.0)
const _TABLE_9_5C_DROP_INTERIOR = (40.0, 36.0, 34.0)

"""
    _table_9_5c(ln, fy; exterior, drops=false) -> Length

ACI 318-11 Table 9.5(c) (corpus: aci-318-11, page 134). For fy between
tabulated values the thickness is interpolated linearly (footnote †). fy
outside 40–75 ksi throws: the table does not cover it.
"""
function _table_9_5c(ln::Length, fy::Pressure; exterior::Bool, drops::Bool = false)
    fy_psi = ustrip(u"psi", fy)
    xs = _TABLE_9_5C_FY_PSI
    divs = drops ? (exterior ? _TABLE_9_5C_DROP_EXTERIOR : _TABLE_9_5C_DROP_INTERIOR) :
                   (exterior ? _TABLE_9_5C_EXTERIOR : _TABLE_9_5C_INTERIOR)
    (xs[1] <= fy_psi <= xs[end]) || throw(ArgumentError(
        "ACI 318-11 Table 9.5(c) covers fy from 40 to 75 ksi; got $(fy_psi) psi"))
    i = fy_psi <= xs[2] ? 1 : 2
    t = (fy_psi - xs[i]) / (xs[i + 1] - xs[i])
    h_lo = ln / divs[i]
    h_hi = ln / divs[i + 1]
    return h_lo + t * (h_hi - h_lo)
end

"""
    min_thickness(::TwoWay, ln; fy, beta, alpha_fm, discontinuous_edge,
                  edge_beam_alpha_f, wall_supported, missing_edge_beam) -> Length

Minimum thickness of a two-way slab with beams between supports on all
sides, ACI 318-11 §9.5.3.3 (corpus: aci-318-11, pages 134–135).

- `ln`: clear span in the long direction, face-to-face of beams.
- `beta`: long-to-short clear span ratio.
- `alpha_fm`: average αf of the edge beams ([`alpha_fm`](@ref)), or
  `nothing` when the beams are not known yet.
- `discontinuous_edge`: the panel has a discontinuous edge.
- `edge_beam_alpha_f`: smallest αf of the beams on discontinuous edges, or
  `nothing` when unknown.
- `wall_supported`: every edge of the panel is a wall. Selects §9.5.3.3(c)
  without a computed αfm. A wall is stiffer than αfm = 2, and §9.5.3.3(d)
  is not applied because every edge is supported.
- `missing_edge_beam`: a building-edge beam is absent. §9.5.3.3(d)'s 10%
  increase is applied to Eq. (9-12) or (9-13) even when `edge_beam_alpha_f`
  would otherwise satisfy αf ≥ 0.8. With `alpha_fm = nothing` the unknown-beam
  bound already includes that 10%.

# Cases
- (a) αfm ≤ 0.2: §9.5.3.2 applies, Table 9.5(c) without drop panels, not
  less than 5 in.
- (b) 0.2 < αfm ≤ 2.0: Eq. (9-12), `ln(0.8 + fy/200000)/(36 + 5β(αfm − 0.2))`,
  not less than 5 in.
- (c) αfm > 2.0: Eq. (9-13), `ln(0.8 + fy/200000)/(36 + 9β)`, not less
  than 3.5 in.
- (d) At a discontinuous edge, an edge beam with αf ≥ 0.80, or the thickness
  from Eq. (9-12) or (9-13) increased by at least 10 percent.

# Unknown beams
ENGINEERING JUDGMENT: with `alpha_fm = nothing` the result is the largest
thickness any of (a)–(d) can require: the exterior-without-edge-beams column
of Table 9.5(c), or Eq. (9-12) at αfm = 0.2 increased by 10 percent, and not
less than 5 in. Eq. (9-12) decreases as αfm grows, and (c) is thinner still,
so no stiffer beam can require more. This is not a code case. It stands in
until the beams are sized.
"""
function min_thickness(::TwoWay, ln::Length;
                       fy::Pressure = 60000u"psi",
                       beta::Real = 1.0,
                       alpha_fm::Union{Nothing, Real} = nothing,
                       discontinuous_edge::Bool = true,
                       edge_beam_alpha_f::Union{Nothing, Real} = nothing,
                       wall_supported::Bool = false,
                       missing_edge_beam::Bool = false)
    ln > zero(ln) || throw(ArgumentError("ln must be positive"))
    beta >= 1.0 || throw(ArgumentError("β is long over short and cannot be below 1; got $beta"))
    wall_supported && missing_edge_beam && throw(ArgumentError(
        "a panel bounded by walls on every side has no missing edge beam"))
    # ACI 318-11 §9.5.3.3(b)/(c), page 134: common numerator.
    numer = ln * (0.8 + fy / 200_000u"psi")

    if wall_supported
        # Classification, not a computed αfm. ACI 318-11 §9.5.3.3(c), page 134.
        # §9.5.3.3(d) is not added: each edge is a wall.
        return max(numer / (36 + 9 * beta), 3.5u"inch")
    end

    if alpha_fm === nothing
        # ENGINEERING JUDGMENT: bound over (a)–(d); see docstring.
        h_table = _table_9_5c(ln, fy; exterior = true)
        h_eq = 1.1 * numer / 36
        return max(h_table, h_eq, 5.0u"inch")
    end

    alpha_fm >= 0 || throw(ArgumentError("αfm cannot be negative; got $alpha_fm"))
    if alpha_fm <= 0.2
        # ACI 318-11 §9.5.3.3(a) → §9.5.3.2 and Table 9.5(c), page 134.
        # The edge-beam column needs edge αf ≥ 0.8 (footnote §).
        edge_ok = edge_beam_alpha_f !== nothing && edge_beam_alpha_f >= 0.8
        exterior = discontinuous_edge && !edge_ok
        return max(_table_9_5c(ln, fy; exterior = exterior), 5.0u"inch")
    end

    h_eq, h_abs = if alpha_fm <= 2.0
        # ACI 318-11 §9.5.3.3(b), Eq. (9-12), page 134.
        numer / (36 + 5 * beta * (alpha_fm - 0.2)), 5.0u"inch"
    else
        # ACI 318-11 §9.5.3.3(c), Eq. (9-13), page 134.
        numer / (36 + 9 * beta), 3.5u"inch"
    end
    # ACI 318-11 §9.5.3.3(d), pages 134–135. A missing building-edge beam
    # fails the αf ≥ 0.8 alternative, so the 10% applies even if a caller
    # passed a stiff edge-beam αf for some other edge.
    edge_ok = edge_beam_alpha_f !== nothing && edge_beam_alpha_f >= 0.8
    if missing_edge_beam || (discontinuous_edge && !edge_ok)
        h_eq *= 1.1
    end
    return max(h_eq, h_abs)
end

# -----------------------------------------------------------------------------
# One-Way — ACI 318-11 Table 9.5(a)
# -----------------------------------------------------------------------------

"""
    min_thickness(::OneWay, ln; fy=60000psi, support=BOTH_ENDS_CONT)

Minimum one-way slab thickness per ACI 318-19 Table 7.3.1.1 (corpus:
aci-318-19, page 92). ACI 318-11 Table 9.5(a) (page 131) has the same
divisors. The fy multiplier is §7.3.1.1.1.

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
    divisor = if support == SIMPLE;               20
              elseif support == ONE_END_CONT;      24
              elseif support == BOTH_ENDS_CONT;    28
              elseif support == CANTILEVER;        10
              else
                  throw(ArgumentError("unknown one-way support condition $support"))
              end
    return max(ln * fy_factor / divisor, 4.0u"inch")
end

"""
    one_way_support_condition(end_a, end_b) -> SupportCondition

Table 9.5(a) condition of a span from its two ends. Each end is `:free`,
`:supported` (a beam or wall the slab stops at), or `:continuous` (a support
the slab runs past). A span with a free end is a cantilever. A span between
two supports is simple, one-end continuous, or both-ends continuous.

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

Practical total depth for a waffle slab: span/22, and at least 8 in.

This is a rule of thumb for standard pan forms. It is not an ACI 318-11
thickness limit. Joist geometry and the shear increase are ACI 318-11 §8.13
(`check_joist_construction`).
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

