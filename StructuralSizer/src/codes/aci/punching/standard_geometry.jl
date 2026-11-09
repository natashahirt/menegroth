# =============================================================================
# Shared ACI 318-11 Punching & Shear Utilities (Unitful)
# =============================================================================
#
# Element-agnostic ACI punching/shear math used by BOTH slabs and foundations.
# Included via codes/aci/_aci_shared.jl BEFORE slabs/ and foundations/.
#
# Contents:
#   §11.11      Punching (two-way) shear geometry, capacity, demand
#   §13.5.3     Moment transfer fractions (γf, γv)
#   R11.11.7.2  Combined punching stress with unbalanced moment (Jc)
#   §13.5.3.2   Effective slab width for moment transfer
#   §11.2       One-way (beam) shear capacity/demand
#   —           High-level punching_check for biaxial moment transfer
#
# All functions are fully Unitful.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# §11.11.1.2 — Critical Section Geometry
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_geometry_interior(c1, c2, d; shape=:rectangular)

4-sided critical section at d/2 from column face (interior column).

Returns `(b1, b2, b0, cAB)`.

- `b1`, `b2`: Critical section dimensions (c1+d, c2+d)
- `b0`: Total perimeter
- `cAB`: Centroid distance from face (b1/2 for symmetric)

Reference: ACI 318-11 §11.11.1.2
"""
function punching_geometry_interior(c1::Length, c2::Length, d::Length;
                                     shape::Symbol = :rectangular)
    if shape == :circular
        D = c1
        b0 = π * (D + d)
        b_sq = b0 / 4   # equivalent square side
        return (b1 = b_sq, b2 = b_sq, b0 = b0, cAB = b_sq / 2)
    end
    b1 = c1 + d
    b2 = c2 + d
    b0 = 2b1 + 2b2
    return (b1 = b1, b2 = b2, b0 = b0, cAB = b1 / 2)
end

"""
    punching_geometry_edge(c1, c2, d)

3-sided critical section for edge column.

Returns `(b1, b2, b0, cAB)`.

Reference: ACI 318-11 §11.11.1.2, StructurePoint §5.2(a)
"""
function punching_geometry_edge(c1::Length, c2::Length, d::Length)
    b1 = c1 + d / 2
    b2 = c2 + d
    b0 = 2b1 + b2
    ustrip(b0) > 0 || throw(ArgumentError("Edge critical perimeter is zero (c1=$c1, c2=$c2, d=$d)"))
    cAB = b1^2 / (2b1 + b2)
    return (b1 = b1, b2 = b2, b0 = b0, cAB = cAB)
end

"""
    punching_geometry_corner(c1, c2, d)

2-sided critical section for corner column.

Returns `(b1, b2, b0, cAB_x, cAB_y)`.

`b1 = c1 + d/2`, `b2 = c2 + d/2` (two-sided section at d/2 from each
interior column face).  Centroid distances from the inner (slab-side)
face of each leg:

    cAB_x = b1² / [2(b1 + b2)]     (PCA Fig. 16-13 Case D, `c`)
    cAB_y = b2² / [2(b1 + b2)]

Reference: ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 209);
PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486).
"""
function punching_geometry_corner(c1::Length, c2::Length, d::Length)
    b1 = c1 + d / 2
    b2 = c2 + d / 2
    b0 = b1 + b2
    denom = 2 * (b1 + b2)
    ustrip(denom) > 0 || throw(ArgumentError("Corner critical perimeter is zero (c1=$c1, c2=$c2, d=$d)"))
    return (b1 = b1, b2 = b2, b0 = b0,
            cAB_x = b1^2 / denom, cAB_y = b2^2 / denom)
end

"""
    punching_geometry(c1, c2, d; position, shape)

Dispatch to the appropriate geometry function by column position.
"""
function punching_geometry(c1::Length, c2::Length, d::Length;
                           position::Symbol = :interior,
                           shape::Symbol = :rectangular)
    position == :interior && return punching_geometry_interior(c1, c2, d; shape = shape)
    position == :edge     && return punching_geometry_edge(c1, c2, d)
    return punching_geometry_corner(c1, c2, d)
end

"""
    eccentricity_to_critical_centroid(b_section, c_col, cAB) -> Length

Distance from the column centerline to the centroid of an edge or corner
critical section, positive toward the interior of the slab.

`cAB` is the distance from the inner face of the critical section back to
the centroid (PCA EB712 Fig. 16-13 `c`; corpus: pca-eb712, page 484, where
`c` and `c′` are the distances from the centroidal axis to the perimeter).
That face lies `d/2` outside the column face, and `b_section = c_col + d/2`
(ACI 318-11 §11.11.1.2). R11.11.7.2 takes `Vu` and `Mu` at the centroidal
axis c-c (corpus: aci-318-11, page 210), so

    e = (b_section − cAB) − c_col/2

Worked check, exterior column: `b1 = 18.88 in`, `cAB = 5.99 in`, `c1 = 16 in`
gives `e = 4.89 in`, and `M_unb = 46.65 − 21.70 × e/12 = 37.81 kip·ft`
(corpus: sp-de-two-way-flat-plate-aci318-14, page 42). That example is
ACI 318-14; the `d/2` section and the centroidal-axis moment are the same
statements in ACI 318-11 §11.11.1.2 and R11.11.7.2.
"""
function eccentricity_to_critical_centroid(b_section::Length, c_col::Length, cAB::Length)
    return (b_section - cAB) - c_col / 2
end

"""
    punching_perimeter(c1, c2, d; shape=:rectangular)

Critical perimeter b₀ for an interior column.

Reference: ACI 318-11 §11.11.1.2
"""
function punching_perimeter(c1::Length, c2::Length, d::Length;
                             shape::Symbol = :rectangular)
    shape == :circular && return π * (c1 + d)
    return 2 * (c1 + d) + 2 * (c2 + d)
end

# ─────────────────────────────────────────────────────────────────────────────
# §11.11.2.1 — Column Factors
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_αs(position) → Int

ACI 318-11 §11.11.2.1(b) location factor: 40 interior, 30 edge, 20 corner.
"""
function punching_αs(position::Symbol)
    position == :interior ? 40 :
    position == :edge     ? 30 : 20
end

"""
    punching_β(c1, c2; shape=:rectangular)

Column aspect ratio β = long side / short side (1.0 for circular).
"""
function punching_β(c1::Length, c2::Length; shape::Symbol = :rectangular)
    shape == :circular && return 1.0
    short = min(c1, c2)
    return ustrip(u"inch", max(c1, c2)) / ustrip(u"inch", max(short, 1.0u"inch"))
end

# ─────────────────────────────────────────────────────────────────────────────
# §13.5.3 / §11.11.7 — Moment Transfer Fractions
# ─────────────────────────────────────────────────────────────────────────────

"""
    gamma_f(b1, b2) → Float64

Fraction of unbalanced moment transferred by flexure.

    γf = 1 / (1 + (2/3)√(b1/b2))

`b1` = critical section dimension in the span direction of the moment.

Reference: ACI 318-11 Eq. (13-1)
"""
function gamma_f(b1::Length, b2::Length)
    return 1.0 / (1.0 + (2.0 / 3.0) * sqrt(b1 / b2))
end

"""
    gamma_v(b1, b2) → Float64

Fraction of unbalanced moment transferred by eccentric shear: γv = 1 − γf.

Reference: ACI 318-11 Eq. (11-37)
"""
function gamma_v(b1::Length, b2::Length)
    return 1.0 - gamma_f(b1, b2)
end

"""
    effective_slab_width(c_transverse, h; position=:interior)

§13.5.3.2 width of the band that transfers one unbalanced moment: 1.5h
outside each column face that has slab (corpus: aci-318-11, page 250;
R13.5.3, "1.5h on each side of the column").

`c_transverse` is the column face perpendicular to the bars in the band.

- `:interior`, and an edge column's moment about the axis parallel to the
  edge: slab on both sides, `c_transverse + 3h`. The StructurePoint exterior
  column is this case, `16 + 3×7 = 37` in
  (corpus: sp-de-two-way-flat-plate-aci318-14, page 18).
- `:edge` here is the other moment, the one spanning along the edge, and a
  corner moment: the free edge removes one side, `c_transverse + 1.5h`.

[`transfer_bands`](@ref) picks which of the two an edge column uses.
"""
function effective_slab_width(c_transverse::Length, h::Length; position::Symbol = :interior)
    position == :interior ? c_transverse + 3h : c_transverse + 1.5h
end

