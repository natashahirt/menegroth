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
    effective_slab_width(c2, h; position=:interior)

Effective slab width for moment transfer by flexure.

- Interior: bb = c2 + 3h (1.5h each side)
- Edge/corner: bb = c2 + 1.5h (slab side only)

Reference: ACI 318-11 §13.5.3.2
"""
function effective_slab_width(c2::Length, h::Length; position::Symbol = :interior)
    position == :interior ? c2 + 3h : c2 + 1.5h
end

# ─────────────────────────────────────────────────────────────────────────────
# R11.11.7.2 — Polar Moment Jc of Critical Section
# ─────────────────────────────────────────────────────────────────────────────

"""
    polar_moment_Jc_interior(b1, b2, d)

Jc for interior column (4-sided, symmetric critical section).

    Jc = d b1³/6 + b1 d³/6 + d b2 (b1/2)² × 2

Reference: ACI 318-11 R11.11.7.2, StructurePoint p.44
"""
function polar_moment_Jc_interior(b1::Length, b2::Length, d::Length)
    cAB = b1 / 2
    return 2 * (b1 * d^3 / 12 + d * b1^3 / 12) + 2 * b2 * d * cAB^2
end

"""
    polar_moment_Jc_edge(b1, b2, d, cAB)

Jc for edge column (3-sided, asymmetric critical section).

    Jc = 2[b1 d³/12 + d b1³/12 + b1 d (b1/2−cAB)²] + b2 d cAB²

Two b1 sides (perpendicular to slab edge) get full in-plane + out-of-plane +
parallel-axis contributions.  The closing b2 side (parallel to the moment
transfer axis) contributes only its parallel-axis term (b2·d·cAB²); its
out-of-plane bending (b2·d³/12) is conventionally omitted per PCA practice.

Reference: ACI 318-11 R11.11.7.2, PCA Notes on ACI 318, StructurePoint p.42–43
"""
function polar_moment_Jc_edge(b1::Length, b2::Length, d::Length, cAB::Length)
    return 2 * (b1 * d^3 / 12 + d * b1^3 / 12 +
                b1 * d * (b1 / 2 - cAB)^2) +
           b2 * d * cAB^2
end

"""
    polar_modulus_Jc_over_c_corner(b1, b2, d)

Section modulus J/c of a two-sided (corner) critical section about the
axis associated with `b1`, per PCA Notes on ACI 318 Fig. 16-13 Case D:

    J/c = [b1² d (b1 + 4 b2) + d³ (b1 + b2)] / (6 b1)

`b1 = c1 + d/2` is the critical-section dimension in the direction of the
moment; `b2 = c2 + d/2` is the perpendicular leg.

ACI 318-11 R11.11.7.2 (page 211) gives Jc for an interior column and
states "Similar equations may be developed for Ac and Jc for columns
located at the edge or corner of a slab."  The closed-form corner
expression is taken from PCA EB712 Fig. 16-13 Case D (page 486), which
is the corpus source that writes the two-sided formula explicitly.

Reference: PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486);
ACI 318-11 R11.11.7.2 (corpus: aci-318-11, page 211).
"""
function polar_modulus_Jc_over_c_corner(b1::Length, b2::Length, d::Length)
    return (b1^2 * d * (b1 + 4 * b2) + d^3 * (b1 + b2)) / (6 * b1)
end

"""
    polar_moment_Jc_corner(b1, b2, d, cAB)

Jc for a corner column (2-sided critical section).

    Jc = (J/c) · cAB

with J/c from `polar_modulus_Jc_over_c_corner` and
`cAB = b1² / [2(b1 + b2)]` (PCA Case D `c`).

Equivalent expanded form (matches the tabulated J/c × c; omits the
closing-leg out-of-plane `b2 d³/12` term, same PCA convention as
`polar_moment_Jc_edge`):

    Jc = b1 d³/12 + d b1³/12 + b1 d (b1/2 − cAB)² + b2 d cAB²

Reference: PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486);
ACI 318-11 R11.11.7.2 (corpus: aci-318-11, page 211).
"""
function polar_moment_Jc_corner(b1::Length, b2::Length, d::Length, cAB::Length)
    return polar_modulus_Jc_over_c_corner(b1, b2, d) * cAB
end

# ─────────────────────────────────────────────────────────────────────────────
# ACI 421.1R-99 Appendix B — Properties of critical sections of GENERAL shape
# ─────────────────────────────────────────────────────────────────────────────
#
# The closed-form rectangular Jc expressions above apply only to right-angle
# interior/edge/corner columns. For non-orthogonal (e.g. 60°) and re-entrant
# (L-shape inside) corners, ACI 421.1R-99 Appendix B (corpus: aci-421-1r-99,
# p. 421.1R-11..13) gives the properties of a critical section whose perimeter
# is a chain of straight segments, by summation:
#
#   Ac = d · Σ l                                            (B-1)
#   Ix = Σ (d·l/3)(y_i² + y_i·y_j + y_j²)                   (B-2)
#   Iy = Σ (d·l/3)(x_i² + x_i·x_j + x_j²)                   (B-3)
#
# where (x_i,y_i),(x_j,y_j) are a segment's endpoints in CENTROIDAL coordinates
# and l is its length. The polar-moment analogs are approximated by the in-plane
# second moments: Jx ≈ Ix, Jy ≈ Iy (App. B, stated explicitly). This drops the
# out-of-plane self term that the exact rectangular Eq. (3.4) keeps (e.g. the
# b1·d³/6 of an interior column), so the general method is slightly CONSERVATIVE
# (smaller J → higher stress) relative to `polar_moment_Jc_interior/edge/corner`
# — the behavior the code sanctions for "sections of general shape".
#
# TRUE PRINCIPAL AXES: Eq. (3.2) assumes `x,y` are the section's principal axes
# (no product-of-inertia coupling). Rather than require a symmetric section, we
# also sum the product of inertia Ixy and rotate to the frame where Ixy→0, then
# apply Eq. (3.2) there. This keeps the method exact (within `J≈I`) for
# asymmetric sections (e.g. an L-notch) — the standard-mechanics generalization
# of what 421.1R writes for the aligned case. A rotated rectangle therefore
# gives the same vu as the unrotated one (invariance), which the tests assert.
#
# This one polygon path covers every support shape: rectangular/edge/corner,
# non-orthogonal wedges, re-entrant L-notches, circular (ring discretized by
# `circular_critical_section`), and I-/odd shapes (pass the effective loaded-area
# polygon per ACI 421.3R-15 §4.8).
#
# CONVENTION (ACI 421.1R-99 Eq. 3.2, corpus p. 421.1R-4): `Mux` is the moment
# ABOUT the centroidal x-axis; its shear stress varies with the y-coordinate.
# `Muy` is about the y-axis. This is the OPPOSITE labeling to the rectangular
# `punching_check` path above (which treats `Mux` as the moment whose stress
# varies in x); callers must map into this convention explicitly.

"""
    critical_section_segments(points; closed=true) -> Vector{Tuple{Int,Int}}

Index pairs of the straight segments of a critical-section perimeter defined by
ordered `points`. `closed=true` (interior column, full loop) appends the closing
segment `(n, 1)`; `closed=false` leaves the perimeter open (edge/corner, where
the critical section stops at free slab edges).
"""
function critical_section_segments(points::AbstractVector; closed::Bool = true)
    n = length(points)
    n ≥ 2 || throw(ArgumentError("need ≥ 2 points for a critical section; got $n"))
    seg = [(i, i + 1) for i in 1:(n - 1)]
    closed && n ≥ 3 && push!(seg, (n, 1))
    return seg
end

"""
    critical_section_properties(points, d; closed=true) -> NamedTuple

ACI 421.1R-99 Appendix B properties of the critical section whose perimeter is
the polyline/polygon through `points` (each a `(x, y)` `Tuple` of `Length` in
the slab plane, in any consistent frame — typically centered on the column).
`closed=true` adds the closing segment (4-sided interior / full ring);
`closed=false` keeps the perimeter open (edge/corner with free edges).

Second moments are evaluated by the Appendix B segment summation, extended to
the product of inertia so the section's **true principal axes** can be found —
ACI 421.1R-99 Eq. (3.2) is the special case in which `x,y` are already
principal. For a straight segment with centroidal endpoints `(xi,yi),(xj,yj)`
and length `l`:

    Ix = Σ (d·l/3)(yi² + yi·yj + yj²)                       (B-2)
    Iy = Σ (d·l/3)(xi² + xi·xj + xj²)                       (B-3)
    Ixy = Σ (d·l/6)(2·xi·yi + xi·yj + xj·yi + 2·xj·yj)      (standard line ∫xy ds)

The principal angle is `θp = ½·atan2(−2·Ixy, Ix−Iy)` (where `Ixy'→0`), with
principal second moments `J1 ≈ Ix'`, `J2 ≈ Iy'` re-summed in the rotated frame
(so `Jx≈Ix`, `Jy≈Iy` per App. B, but now on the principal axes).

Returns `(Ac, b0, xc, yc, Ix, Iy, Ixy, θp, J1, J2, l1, l2, e1, e2)`:
- `Ac = d·Σl`, `b0 = Σl`                                   (Eq. B-1)
- `(xc, yc)`: length-weighted centroid in the INPUT frame
- `Ix, Iy, Ixy`: centroidal second moments in the INPUT frame
- `θp`: principal-axis rotation (rad); `e1, e2`: principal unit vectors
- `J1, J2`: principal second moments (≈ polar-moment analogs)
- `l1, l2`: section projections on the principal axes (Fig. B2), for γv.

All dimensional quantities are Unitful.

Reference: ACI 421.1R-99 Appendix B, Eq. (B-1)–(B-3) (corpus: aci-421-1r-99,
p. 421.1R-11); principal-axis rotation is standard mechanics.
"""
function critical_section_properties(points::AbstractVector, d::Length;
                                     closed::Bool = true)
    xs = [ustrip(u"inch", p[1]) for p in points]
    ys = [ustrip(u"inch", p[2]) for p in points]
    dd = ustrip(u"inch", d)
    seg = critical_section_segments(points; closed = closed)

    # (B-1): perimeter b0 and the length-weighted (uniform-strip) centroid.
    b0 = 0.0
    sx = 0.0
    sy = 0.0
    for (i, j) in seg
        l = hypot(xs[j] - xs[i], ys[j] - ys[i])
        b0 += l
        sx += l * (xs[i] + xs[j]) / 2
        sy += l * (ys[i] + ys[j]) / 2
    end
    b0 > 0 || throw(ArgumentError("degenerate critical section (zero perimeter)"))
    xc = sx / b0
    yc = sy / b0

    # Second moments about the centroidal axes of the INPUT frame (per unit d),
    # including the product of inertia Ixy needed for the principal axes.
    Ix = 0.0
    Iy = 0.0
    Ixy = 0.0
    for (i, j) in seg
        xi = xs[i] - xc
        yi = ys[i] - yc
        xj = xs[j] - xc
        yj = ys[j] - yc
        l = hypot(xj - xi, yj - yi)
        Ix += dd * l / 3 * (yi^2 + yi * yj + yj^2)
        Iy += dd * l / 3 * (xi^2 + xi * xj + xj^2)
        Ixy += dd * l / 6 * (2xi * yi + xi * yj + xj * yi + 2xj * yj)
    end

    # Principal axes: rotate to the frame where the product of inertia vanishes.
    # Both θp and θp±90° are valid principal choices; normalize to (−45°, 45°] so
    # axis 1 stays aligned with the input x-axis for (near-)axis-aligned sections.
    # This only fixes which principal axis is labeled "1" vs "2" — the stress
    # result is invariant to the choice (the moment vector and vertex coordinates
    # are resolved with the same θp).
    θp = 0.5 * atan(-2 * Ixy, Ix - Iy)
    if θp > π / 4
        θp -= π / 2
    elseif θp ≤ -π / 4
        θp += π / 2
    end
    c = cos(θp)
    s = sin(θp)

    # Re-sum J1≈Ix', J2≈Iy' and the projections in the principal frame, reusing
    # the App. B summation on the rotated vertices (x' = x·c + y·s, y' = −x·s + y·c).
    J1 = 0.0
    J2 = 0.0
    for (i, j) in seg
        xi = xs[i] - xc; yi = ys[i] - yc
        xj = xs[j] - xc; yj = ys[j] - yc
        xi1 = xi * c + yi * s; yi1 = -xi * s + yi * c
        xj1 = xj * c + yj * s; yj1 = -xj * s + yj * c
        l = hypot(xj1 - xi1, yj1 - yi1)
        J1 += dd * l / 3 * (yi1^2 + yi1 * yj1 + yj1^2)
        J2 += dd * l / 3 * (xi1^2 + xi1 * xj1 + xj1^2)
    end
    x1 = [(xs[k] - xc) * c + (ys[k] - yc) * s for k in eachindex(xs)]
    y1 = [-(xs[k] - xc) * s + (ys[k] - yc) * c for k in eachindex(xs)]
    l1 = maximum(x1) - minimum(x1)
    l2 = maximum(y1) - minimum(y1)

    return (Ac = dd * b0 * u"inch^2", b0 = b0 * u"inch",
            xc = xc * u"inch", yc = yc * u"inch",
            Ix = Ix * u"inch^4", Iy = Iy * u"inch^4", Ixy = Ixy * u"inch^4",
            θp = θp, J1 = J1 * u"inch^4", J2 = J2 * u"inch^4",
            l1 = l1 * u"inch", l2 = l2 * u"inch",
            e1 = (c, s), e2 = (-s, c))
end

"""
    gamma_v_general(l1, l2) -> (γv1, γv2)

Moment-transfer fractions by eccentricity of shear for a general-shape critical
section, ACI 421.1R-99 Eq. (3.3) / Fig. B2 (corpus: aci-421-1r-99, p. 421.1R-4):

    γv1 = 1 − 1/(1 + (2/3)√(l2/l1))
    γv2 = 1 − 1/(1 + (2/3)√(l1/l2))

`l1`, `l2` are the section's projections on its principal axes. `γv1` pairs with
the moment about principal axis 1 (stress ∝ the axis-2 coordinate); `γv2` with
the moment about principal axis 2.
"""
function gamma_v_general(l1::Length, l2::Length)
    r1 = ustrip(u"inch", l2) / ustrip(u"inch", l1)
    r2 = ustrip(u"inch", l1) / ustrip(u"inch", l2)
    γv1 = 1.0 - 1.0 / (1.0 + (2.0 / 3.0) * sqrt(r1))
    γv2 = 1.0 - 1.0 / (1.0 + (2.0 / 3.0) * sqrt(r2))
    return (γv1, γv2)
end

"""
    punching_stress_general(Vu, Mux, Muy, points, d; closed=true) -> NamedTuple

Maximum factored punching shear stress on a critical section of general shape,
ACI 421.1R-99 Eq. (3.2) with γv from Eq. (3.3), evaluated on the section's
**true principal axes** so it is exact (within the App. B `J≈I` approximation)
for asymmetric sections too. `Mux`/`Muy` are the unbalanced moments about the
centroidal x/y axes of the INPUT frame (`Mux` about x, `Muy` about y); they are
resolved into principal components `(M1, M2)` internally:

!!! warning "Moment convention differs from `punching_check`"
    This engine follows the standard-mechanics / ACI 421.1R convention: `Mux`
    is the moment **about the x-axis**, so it drives stress variation in **y**
    (at `θp=0`, the term is `γv1·Mux·y/J1`); `Muy` (about y) drives stress in
    **x**. The closed-form [`punching_check`](@ref) names its arguments by the
    *direction of stress variation* instead — its `Mux` drives stress in **x**.
    So mapping a moment between the two is a swap: `punching_check` `Mux`
    (stress in x) ≡ this engine's `Muy`, and vice-versa. Callers bridging the
    two (e.g. the re-entrant corner path in `check_punching_for_column`) must
    map explicitly; a convention-lock test pins this against the closed form.

    vu = Vu/Ac + γv1·M1·s2/J1 + γv2·M2·s1/J2

where `(s1, s2)` are a vertex's coordinates on the principal axes. The stress is
evaluated at every vertex and the governing value returned; the moment term is
taken in absolute value before adding the always-additive `Vu/Ac`, matching the
closed-form practice of evaluating at the farthest fiber.

Returns `(vu, Ac, b0, J1, J2, θp, γv1, γv2, props)`.

Reference: ACI 421.1R-99 Eq. (3.2)–(3.3), Appendix B (corpus: aci-421-1r-99,
p. 421.1R-4, 11).
"""
function punching_stress_general(Vu::Force, Mux::Torque, Muy::Torque,
                                 points::AbstractVector, d::Length;
                                 closed::Bool = true)
    p = critical_section_properties(points, d; closed = closed)
    c = cos(p.θp)
    s = sin(p.θp)

    # Resolve the applied moment vector (Mux about x, Muy about y) onto the
    # principal axes with the same rotation used for the geometry.
    M1 = Mux * c + Muy * s
    M2 = -Mux * s + Muy * c
    γv1, γv2 = gamma_v_general(p.l1, p.l2)

    v_direct = uconvert(u"psi", Vu / p.Ac)

    v_moment = 0.0u"psi"
    for pt in points
        x = pt[1] - p.xc
        y = pt[2] - p.yc
        s1 = x * c + y * s        # coordinate on principal axis 1
        s2 = -x * s + y * c       # coordinate on principal axis 2
        term = uconvert(u"psi", γv1 * M1 * s2 / p.J1 + γv2 * M2 * s1 / p.J2)
        v_moment = max(v_moment, abs(term))
    end

    return (vu = v_direct + v_moment, Ac = p.Ac, b0 = p.b0,
            J1 = p.J1, J2 = p.J2, θp = p.θp, γv1 = γv1, γv2 = γv2, props = p)
end

"""
    circular_critical_section(D, d; n=64, center=(0u"inch", 0u"inch")) -> Vector

Vertices of the punching critical section for a **circular** column/loaded area
of diameter `D`: the ring at `d/2` from the column face, i.e. a circle of
diameter `D + d`, discretized into `n` straight segments for the general-shape
method. Pass to `punching_stress_general`/`critical_section_properties` with
`closed=true`. Converges to the analytic ring (`b0 = π(D+d)`, `J1 = J2 =
d·π·r³`, `r = (D+d)/2`) as `n` grows; `n=64` is well within ~0.1%.

For an **I-shaped or other odd support**, pass the effective loaded-area polygon
(ACI 421.3R-15 §4.8: the minimum-perimeter area enclosing the actual shape)
directly as `points` instead — no special case is needed.

Reference: ACI 318-11 §11.11.1.2 critical section at d/2 (corpus: aci-318-11);
general-shape treatment ACI 421.1R-99 Appendix B (corpus: aci-421-1r-99).
"""
function circular_critical_section(D::Length, d::Length; n::Int = 64,
                                   center = (0.0u"inch", 0.0u"inch"))
    n ≥ 8 || throw(ArgumentError("need n ≥ 8 segments to approximate a circle; got $n"))
    r = (D + d) / 2
    return [(center[1] + r * cos(2π * k / n), center[2] + r * sin(2π * k / n))
            for k in 0:(n - 1)]
end

"""
    rectangular_critical_section(c1, c2, d; position=:interior) -> (points, closed)

Vertices (and open/closed flag) of the orthogonal rectangular critical section at
`d/2` from the faces of a `c1×c2` column, for the general-shape engine. The
column is centered at the origin with faces aligned to x/y.

- `:interior` — the full `(c1+d)×(c2+d)` loop (4 sides, `closed=true`).
- `:edge` — free edge along `x = +c1/2` (slab on `x ≤ c1/2`); open 3-sided U.
- `:corner` — convex outside corner, free edges at `x=+c1/2` and `y=+c2/2`
  (slab in the `−x,−y` quadrant); open 2-sided L.

These reproduce the closed-form `b0`/`cAB` geometry while routing through the
Appendix B engine (used to test the general path against the closed forms).

Reference: ACI 318-11 §11.11.1.2, critical section at d/2 where slab exists
(corpus: aci-318-11, pages 200, 209).
"""
function rectangular_critical_section(c1::Length, c2::Length, d::Length;
                                      position::Symbol = :interior)
    ax = c1 / 2 + d / 2   # offset half-width (x)
    ay = c2 / 2 + d / 2   # offset half-width (y)
    fx = c1 / 2           # free-edge location (x) when present
    fy = c2 / 2           # free-edge location (y) when present
    if position === :interior
        return ([(ax, ay), (-ax, ay), (-ax, -ay), (ax, -ay)], true)
    elseif position === :edge
        # Open U: free edge at x = +c1/2, slab on x ≤ c1/2.
        return ([(fx, ay), (-ax, ay), (-ax, -ay), (fx, -ay)], false)
    elseif position === :corner
        # Open L: free edges at x=+c1/2 and y=+c2/2, slab in −x,−y quadrant.
        return ([(fx, -ay), (-ax, -ay), (-ax, fy)], false)
    else
        throw(ArgumentError("position must be :interior, :edge, or :corner; got :$position"))
    end
end

"""
    reentrant_critical_section(c1, c2, d; notch=(1, 1)) -> (points, closed)

Vertices of the critical section at a **re-entrant** (L-shape inside) corner: a
`c1×c2` column seated in the inside corner of an L, with one empty quadrant
(`notch`, a sign pair like `(+1,+1)`). Per ACI 318-11 §11.11.1.2 the critical
section follows the `d/2` offset wherever slab exists and terminates at the two
free edges bounding the notch. The resisting section is therefore the full
offset loop **minus** the two `d/2` notch edges (which lie along the free edges
and carry no shear): an **open** polyline with

    b0 = 2(c1 + c2) + 3d.

This is `d` less than the full 4-sided `2(c1+d)+2(c2+d)` — only the resisting
perimeter is counted — and far more than the legacy 2-sided `:corner` section,
which severely under-counts a re-entrant corner.

Thin wrapper over [`corner_critical_section`](@ref) with `kind=:reentrant` and
the orthogonal inward normals implied by `notch` (single source of truth for the
clipped geometry).

Reference: ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 200); free-edge
effective-perimeter treatment ACI 421.3R-15 §4.6.2 (corpus: aci-421-3r-15).
"""
function reentrant_critical_section(c1::Length, c2::Length, d::Length;
                                    notch::Tuple{Int,Int} = (1, 1))
    sx, sy = sign(notch[1]), sign(notch[2])
    (sx != 0 && sy != 0) ||
        throw(ArgumentError("notch must be a nonzero sign pair, e.g. (1,1); got $notch"))
    # Inward normals point from each free edge toward the slab, i.e. away from
    # the empty notch quadrant: −sign(notch) on each axis.
    normals = [(-float(sx), 0.0), (0.0, -float(sy))]
    return corner_critical_section(c1, c2, d, :reentrant, normals)
end

"""
    corner_critical_section(c1, c2, d, kind, inward_normals; θ=0.0) -> (points, closed)

Effective punching critical section for a corner column of **any free-edge
angle**, built by offsetting the `c1×c2` column rectangle by `d/2` and clipping
the offset perimeter to the slab region defined by the two free edges. Returns an
**open** polyline (`closed=false`) of the resisting, slab-facing perimeter; the
free-edge cuts carry no shear and are excluded.

- `kind=:convex` — outside corner. Slab is the wedge = intersection of the two
  inward half-planes; the offset perimeter is kept only where it faces slab on
  *both* edges.
- `kind=:reentrant` — inside (L) corner. Slab is the complement of the notch =
  union of the two inward half-planes; the perimeter is kept everywhere except
  the notch corner (both edges' void side).

`inward_normals` are the two unit normals pointing from each free edge **into**
the slab (need not be unit; they are normalized). The free-edge lines pass
through the column's void-side corner along the edge directions (the column is
seated in the corner with its faces tangent to the edges). `θ` rotates the
column. All lengths internally reduced to inches.

Exact reductions (orthogonal edges `[(-1,0),(0,-1)]`):
- `:convex`    → 2-sided L, `b0 = (c1+d/2)+(c2+d/2)` (matches
  `rectangular_critical_section(:corner)`).
- `:reentrant` → `b0 = 2(c1+c2)+3d` — the full offset loop **minus** the two
  `d/2` notch edges, which lie along the free edges and do not resist. (This is
  `d` less than the closed 6-vertex `reentrant_critical_section`, correcting an
  unconservative over-count of the resisting perimeter.)

Reference: ACI 318-11 §11.11.1.2 — critical section at `d/2` wherever slab
exists (corpus: aci-318-11, page 200); general-shape App. B engine
(corpus: aci-421-1r-99); free-edge effective-perimeter ACI 421.3R-15 §4.6.2.
"""
function corner_critical_section(c1::Length, c2::Length, d::Length, kind::Symbol,
                                 inward_normals::AbstractVector; θ::Float64 = 0.0)
    length(inward_normals) == 2 ||
        throw(ArgumentError("a corner has exactly 2 free edges; got $(length(inward_normals))"))
    kind in (:convex, :reentrant) ||
        throw(ArgumentError("kind must be :convex or :reentrant; got :$kind"))
    ax = ustrip(u"inch", c1) / 2 + ustrip(u"inch", d) / 2   # offset half-width x
    ay = ustrip(u"inch", c2) / 2 + ustrip(u"inch", d) / 2   # offset half-width y
    hx = ustrip(u"inch", c1) / 2                            # column half-width x
    hy = ustrip(u"inch", c2) / 2                            # column half-width y
    cθ = cos(θ); sθ = sin(θ)
    rot(x, y) = (x * cθ - y * sθ, x * sθ + y * cθ)
    # Offset rectangle corners, CCW, in the (rotated) global frame.
    V = [rot(ax, -ay), rot(ax, ay), rot(-ax, ay), rot(-ax, -ay)]
    # Normalize the inward normals.
    N = map(inward_normals) do n
        m = hypot(float(n[1]), float(n[2]))
        m == 0 && throw(ArgumentError("inward normal must be nonzero; got $n"))
        (n[1] / m, n[2] / m)
    end
    # Void direction ≈ −(sum of inward normals); the void-side column corner is
    # the column-rectangle corner farthest along it. Both free edges pass through
    # this corner.
    svx = -(N[1][1] + N[2][1]); svy = -(N[1][2] + N[2][2])
    colV = [rot(hx, -hy), rot(hx, hy), rot(-hx, hy), rot(-hx, -hy)]
    vc = colV[argmax([cc[1] * svx + cc[2] * svy for cc in colV])]
    # Signed slab-side distance of point p from free edge k (≥ 0 ⇒ slab side).
    g(p, k) = (p[1] - vc[1]) * N[k][1] + (p[2] - vc[2]) * N[k][2]
    tol = 1e-9 * max(ax, ay)
    keep(p) = kind === :reentrant ? (g(p, 1) ≥ -tol || g(p, 2) ≥ -tol) :
                                    (g(p, 1) ≥ -tol && g(p, 2) ≥ -tol)
    # Walk the closed offset perimeter, inserting the constraint-line crossings
    # so every resulting segment is wholly kept or wholly dropped.
    nV = length(V)
    aug = Tuple{Float64,Float64}[]
    for i in 1:nV
        A = V[i]; B = V[mod1(i + 1, nV)]
        push!(aug, A)
        ts = Float64[]
        for k in 1:2
            gA = g(A, k); gB = g(B, k)
            if (gA < 0) != (gB < 0) && gA != gB
                t = gA / (gA - gB)
                (0 < t < 1) && push!(ts, t)
            end
        end
        sort!(ts)
        for t in ts
            push!(aug, (A[1] + t * (B[1] - A[1]), A[2] + t * (B[2] - A[2])))
        end
    end
    m = length(aug)
    # Classify each segment aug[i]→aug[i+1] by its midpoint.
    kept = [keep(((aug[i][1] + aug[mod1(i + 1, m)][1]) / 2,
                  (aug[i][2] + aug[mod1(i + 1, m)][2]) / 2)) for i in 1:m]
    any(kept) || throw(ArgumentError("corner clip produced an empty critical section"))
    d0 = findfirst(!, kept)           # a dropped (free-edge) segment
    if d0 === nothing
        # Fully enclosed (no free edge cuts the offset) — return the closed loop.
        pts = [(v[1] * u"inch", v[2] * u"inch") for v in V]
        return (pts, true)
    end
    # Advance to the first kept segment after the drop, then collect one run so the
    # open ends sit at the free-edge terminations.
    i = d0
    while !kept[mod1(i, m)]; i += 1; end
    j = mod1(i, m)
    chain = [aug[j]]
    cnt = 0
    while kept[j] && cnt < m
        push!(chain, aug[mod1(j + 1, m)])
        j = mod1(j + 1, m); cnt += 1
    end
    # Drop consecutive duplicates, then collinear interior points.
    uniq = Tuple{Float64,Float64}[]
    for p in chain
        if isempty(uniq) ||
           hypot(p[1] - uniq[end][1], p[2] - uniq[end][2]) > tol
            push!(uniq, p)
        end
    end
    simp = Tuple{Float64,Float64}[]
    for (idx, p) in enumerate(uniq)
        if 1 < idx < length(uniq)
            a = simp[end]; b = p; cc = uniq[idx + 1]
            cross = (b[1] - a[1]) * (cc[2] - a[2]) - (b[2] - a[2]) * (cc[1] - a[1])
            abs(cross) ≤ tol * max(ax, ay) && continue   # b is collinear with a–c
        end
        push!(simp, p)
    end
    out = [(p[1] * u"inch", p[2] * u"inch") for p in simp]
    return (out, false)
end

"""
    section_symmetry(points, props; rtol=1e-6) -> (sym1, sym2)

Whether the critical section's vertex set is symmetric about principal axis 1
and/or axis 2 (reflection invariance in the principal frame from `props`). Used
to flag sections with no axis of symmetry, where the γv (Fig. B2) and
farthest-fiber evaluation of Eq. (3.2) are approximate.
"""
function section_symmetry(points::AbstractVector, props; rtol::Float64 = 1e-6)
    c = cos(props.θp); s = sin(props.θp)
    xc = props.xc; yc = props.yc
    s1 = Float64[]; s2 = Float64[]
    for pt in points
        x = ustrip(u"inch", pt[1] - xc)
        y = ustrip(u"inch", pt[2] - yc)
        push!(s1, x * c + y * s)
        push!(s2, -x * s + y * c)
    end
    scale = max(maximum(abs, s1; init = 0.0), maximum(abs, s2; init = 0.0), 1.0)
    tol = rtol * scale
    _has(set1, set2, a, b) = any(i -> abs(set1[i] - a) ≤ tol && abs(set2[i] - b) ≤ tol,
                                 eachindex(set1))
    # Symmetry about axis 1 (s1-axis): (s1, s2) → (s1, −s2).
    sym1 = all(k -> _has(s1, s2, s1[k], -s2[k]), eachindex(s1))
    # Symmetry about axis 2 (s2-axis): (s1, s2) → (−s1, s2).
    sym2 = all(k -> _has(s1, s2, -s1[k], s2[k]), eachindex(s1))
    return (sym1, sym2)
end

"""
    punching_check_general(Vu, Mux, Muy, d, fc, points; ...) -> NamedTuple

Full punching check for a critical section of **general shape** (non-orthogonal,
re-entrant, circular, I-/odd supports), combining the ACI 421.1R-99 Appendix B
demand stress (`punching_stress_general`) with the §11.11.2.1 capacity stress.

`Mux`/`Muy` follow the 421.1R convention (`Mux` about x, `Muy` about y). Pass the
critical-section `points` (e.g. from `rectangular_critical_section`,
`reentrant_critical_section`, `circular_critical_section`, or a building-derived
polygon) and `closed`. `β` and `αs` feed the capacity (ACI 318-11 §11.11.2.1);
supply them from the column / section side-count (defaults: `β=1`, `αs=40`).

Returns `(ok, utilization, vu, ϕvc, b0, J1, J2, θp, asymmetric, sym1, sym2,
props)`. `asymmetric=true` (no principal axis of symmetry) flags that γv and the
peak-stress point are approximate and an FEA cross-check is advised.

Reference: ACI 421.1R-99 Eq. (3.2)/(3.3), Appendix B (corpus: aci-421-1r-99);
capacity ACI 318-11 §11.11.2.1 (corpus: aci-318-11).
"""
function punching_check_general(Vu::Force, Mux::Torque, Muy::Torque,
                                d::Length, fc::Pressure, points::AbstractVector;
                                closed::Bool = true, β::Float64 = 1.0, αs::Int = 40,
                                λ::Float64 = 1.0, ϕ::Float64 = 0.75)
    res = punching_stress_general(Vu, Mux, Muy, points, d; closed = closed)
    vc = punching_capacity_stress(fc, β, αs, res.b0, d; λ = λ)
    ϕvc = ϕ * vc
    sym1, sym2 = section_symmetry(points, res.props)
    ok = res.vu ≤ ϕvc
    utilization = ustrip(u"psi", res.vu) / max(ustrip(u"psi", ϕvc), 1e-10)
    return (ok = ok, utilization = utilization, vu = res.vu, ϕvc = ϕvc,
            b0 = res.b0, J1 = res.J1, J2 = res.J2, θp = res.θp,
            asymmetric = !(sym1 || sym2), sym1 = sym1, sym2 = sym2,
            props = res.props)
end

# ─────────────────────────────────────────────────────────────────────────────
# §11.11.2.1 — Punching Shear Capacity
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_capacity_stress(fc, β, αs, b0, d; λ=1.0) → Pressure

Nominal punching shear stress vc per ACI 318-11 §11.11.2.1:

    vc = min( (2+4/β)λ√f'c,  (αs d/b0+2)λ√f'c,  4λ√f'c )

Eq. (11-31), (11-32), (11-33) respectively. Returns vc as a Pressure (psi).
"""
function punching_capacity_stress(fc::Pressure, β::Float64, αs::Int,
                                   b0::Length, d::Length; λ::Float64 = 1.0)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    vc_a = (2 + 4 / β) * λ * sqrt_fc               # Eq. (11-31)
    vc_b = (αs * d / b0 + 2) * λ * sqrt_fc         # Eq. (11-32)
    vc_c = 4 * λ * sqrt_fc                          # Eq. (11-33)
    return min(vc_a, vc_b, vc_c) * u"psi"
end

"""
    punching_capacity_interior(b0, d, fc; ...) → Force

Nominal punching shear capacity Vc = vc × b₀ × d (as a force).
"""
function punching_capacity_interior(
    b0::Length, d::Length, fc::Pressure;
    c1::Length = 0u"inch", c2::Length = 0u"inch",
    λ::Float64 = 1.0, position::Symbol = :interior,
    shape::Symbol = :rectangular
)
    β = punching_β(c1, c2; shape = shape)
    αs = punching_αs(position)
    vc = punching_capacity_stress(fc, β, αs, b0, d; λ = λ)
    # vc (psi) × b0 (inch) × d (inch) → lbf
    Vc = ustrip(u"psi", vc) * ustrip(u"inch", b0) * ustrip(u"inch", d)
    return Vc * u"lbf"
end

# ─────────────────────────────────────────────────────────────────────────────
# Punching Shear Demand & Combined Stress
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_demand(qu, At, c1, c2, d; shape=:rectangular) → Force

Punching shear demand: Vu = qu × (At − Ac).
"""
function punching_demand(qu::Pressure, At::Area, c1::Length, c2::Length, d::Length;
                          shape::Symbol = :rectangular)
    Ac = shape == :circular ? π * (c1 + d)^2 / 4 : (c1 + d) * (c2 + d)
    return qu * (At - Ac)
end

"""
    combined_punching_stress(Vu, Mub, b0, d, γv, Jc, cAB) → Pressure

Direct + eccentric shear stress per ACI R8.4.4.2.3:

    vu = Vu/(b₀·d) + γv·Mub·cAB / Jc
"""
function combined_punching_stress(Vu::Force, Mub::Torque, b0::Length, d::Length,
                                   γv::Float64, Jc, cAB::Length)
    return Vu / (b0 * d) + γv * Mub * cAB / Jc
end

# ─────────────────────────────────────────────────────────────────────────────
# Simple Check Functions
# ─────────────────────────────────────────────────────────────────────────────

"""Check concentric punching: Vu ≤ φVc."""
function check_punching_shear(Vu, Vc; φ::Float64 = 0.75)
    φVc = φ * Vc
    ratio = Vu / φVc
    ok = ratio ≤ 1.0
    msg = ok ? "OK: Vu/φVc = $(round(ratio, digits=3))" :
               "NG: Vu/φVc = $(round(ratio, digits=3)) > 1.0"
    return (ok = ok, ratio = ratio, message = msg)
end

"""Check combined punching stress: vu ≤ φvc."""
function check_combined_punching(vu::Pressure, vc::Pressure; φ::Float64 = 0.75)
    ratio = vu / (φ * vc)
    ok = ratio ≤ 1.0
    msg = ok ? "OK: vu/φvc = $(round(ratio, digits=3))" :
               "NG: vu/φvc = $(round(ratio, digits=3)) > 1.0"
    return (ok = ok, ratio = ratio, message = msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# §11.2 — One-Way (Beam) Shear
# ─────────────────────────────────────────────────────────────────────────────

"""
    one_way_shear_capacity(fc, bw, d; λ=1.0) → Force

Vc = 2λ√f'c × bw × d (calibrated for psi/inch → lbf).

Reference: ACI 318-11 §11.2.1.1 (Eq. 11-3)
"""
function one_way_shear_capacity(fc::Pressure, bw::Length, d::Length;
                                 λ::Float64 = 1.0)
    Vc = 2 * λ * sqrt(ustrip(u"psi", fc)) * ustrip(u"inch", bw) * ustrip(u"inch", d)
    return Vc * u"lbf"
end

"""
    one_way_shear_demand(qu, bw, ln, d) → Force

One-way shear demand at critical section (d from support face):
    Vu = qu × bw × (ln/2 − d)

Reference: ACI 318-11 §11.1.3.1
"""
function one_way_shear_demand(qu::Pressure, bw::Length, ln::Length, d::Length)
    return qu * bw * ln / 2 - qu * bw * d
end

"""Check one-way shear: Vu ≤ φVc."""
function check_one_way_shear(Vu, Vc; φ::Float64 = 0.75)
    φVc = φ * Vc
    ratio = ustrip(u"lbf", Vu) / ustrip(u"lbf", φVc)
    ok = ratio ≤ 1.0
    msg = ok ? "OK: Vu/φVc = $(round(ratio, digits=3))" :
               "NG: Vu/φVc = $(round(ratio, digits=3)) > 1.0"
    return (ok = ok, ratio = ratio, message = msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Edge-column orientation (ACI 318-11 §11.11.7 / R11.11.7.2)
# ─────────────────────────────────────────────────────────────────────────────

"""
    _governing_edge_moment(Mux, Muy) → Torque

Uniaxial 3-sided edge check can apply one transfer moment. When both
components are present, keep the larger |M| so `punching_check`'s
subsequent `Muy = 0` cannot drop the governing transfer. Single-axis
callers pass the other component as zero and keep that axis unchanged.

ENGINEERING JUDGMENT: ACI 318-11 §11.11.7.1 / R11.11.7.2 (corpus:
aci-318-11, pages 209–211) transfer γv Mu about the centroid of the
§11.11.1.2 critical section; they do not rank Mux vs Muy. The uniaxial
edge path takes `max(|Mux|, |Muy|)` so a leftover axis cannot govern.
"""
function _governing_edge_moment(Mux::Torque, Muy::Torque)
    Mux_zero = abs(to_kipft(Mux)) < 1e-10
    Muy_zero = abs(to_kipft(Muy)) < 1e-10
    Mux_zero && return Muy
    Muy_zero && return Mux
    return abs(to_kipft(Mux)) ≥ abs(to_kipft(Muy)) ? Mux : Muy
end

"""
    _orient_edge_column(c1, c2, Mux, Muy; free_edge_parallel=:c2)

ACI 318-11 R11.11.7.2 (corpus: aci-318-11, pages 209–211): `c1` is the column
dimension in the direction of the span for which moments are determined —
the dimension **perpendicular to the free edge**. The unbalanced moment used
on the 3-sided critical section is the moment about the axis **parallel to
the free edge**.

- `free_edge_parallel = :c1`: free edge runs along the named `c1` face;
  swap so ACI `c1` = named `c2`. Do **not** skip this swap.
- `free_edge_parallel = :c2` (default): caller already stored `c1` perp to
  the edge.

On **both** `:c1` and `:c2`, after any geometry swap, `M_edge` is the
governing `|M|` when both components are present (`_governing_edge_moment`).
Single-moment callers pass the edge transfer as `Mux` (or as `Muy` with
`Mux = 0`).
"""
function _orient_edge_column(c1::Length, c2::Length, Mux::Torque, Muy::Torque;
                             free_edge_parallel::Symbol = :c2)
    free_edge_parallel in (:c1, :c2) ||
        throw(ArgumentError("free_edge_parallel must be :c1 or :c2; got :$free_edge_parallel"))
    M_edge = _governing_edge_moment(Mux, Muy)
    if free_edge_parallel === :c1
        return (c1 = c2, c2 = c1, M_edge = M_edge)
    end
    return (c1 = c1, c2 = c2, M_edge = M_edge)
end

"""
    _infer_free_edge_parallel(col) -> Symbol

Infer `free_edge_parallel` from a column's `boundary_edge_dirs` (unit vector
along the slab free edge). Aligns the edge with local x (`:c1`) or local y
(`:c2`). Defaults to `:c2` when no boundary direction is stored (c1 already
perp to the edge — the historical convention).
"""
function _infer_free_edge_parallel(col)
    if hasproperty(col, :boundary_edge_dirs)
        dirs = getfield(col, :boundary_edge_dirs)
        if !isempty(dirs)
            θ = hasproperty(col, :θ) ? Float64(getfield(col, :θ)) : 0.0
            ex, ey = dirs[1]
            lx = abs(ex * cos(θ) + ey * sin(θ))
            ly = abs(-ex * sin(θ) + ey * cos(θ))
            return lx ≥ ly ? :c1 : :c2
        end
    end
    return :c2
end

# ─────────────────────────────────────────────────────────────────────────────
# High-Level: Punching Check with Biaxial Unbalanced Moment
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_check(Vu, Mux, Muy, d, fc, c1, c2; ...) → NamedTuple

Full ACI 318-11 §11.11 + §11.11.7 punching shear check with eccentric shear
from biaxial unbalanced moments.

# Arguments
- `Vu::Force`: Net punching shear at critical section (Pu − qu·Ac)
- `Mux::Torque`, `Muy::Torque`: Unbalanced moments about x- and y-axes
- `d::Length`: Effective depth
- `fc::Pressure`: f'c
- `c1::Length`, `c2::Length`: Column dimensions (c1 = diameter for :circular)

# Keywords
- `position`: `:interior` (default), `:edge`, `:corner`
- `shape`: `:rectangular` (default), `:circular`
- `λ`: Lightweight factor (1.0)
- `ϕ`: Shear strength reduction factor (0.75)
- `free_edge_parallel`: For `:edge` only. `:c2` (default) means `c1` is
  already perp to the free edge; `:c1` means the free edge runs along the
  named `c1` face (swap so ACI `c1` = named `c2` — the swap is not
  skipped). On both `:c1` and `:c2`, after any geometry swap, the uniaxial
  transfer moment is `max(|Mux|, |Muy|)` when both are present.
  ACI 318-11 R11.11.7.2 (corpus: aci-318-11, pages 209–211).

# Returns
`(ok, utilization, vu, ϕvc, b0, geom)`

# Biaxial Interior Column
For interior columns with biaxial moment (Mux ≠ 0, Muy ≠ 0):

    vu = Vu/(b₀d) + γv_x |Mux| (b1/2) / Jc_x + γv_y |Muy| (b2/2) / Jc_y

where Jc_x and Jc_y are computed with b1, b2 swapped appropriately.
"""
function punching_check(
    Vu::Force, Mux::Torque, Muy::Torque,
    d::Length, fc::Pressure,
    c1::Length, c2::Length;
    position::Symbol = :interior,
    shape::Symbol = :rectangular,
    λ::Float64 = 1.0,
    ϕ::Float64 = 0.75,
    free_edge_parallel::Symbol = :c2,
)
    if position == :edge
        ori = _orient_edge_column(c1, c2, Mux, Muy; free_edge_parallel = free_edge_parallel)
        c1 = ori.c1
        c2 = ori.c2
        Mux = ori.M_edge
        Muy = zero(Muy)
    end
    # Geometry
    geom = punching_geometry(c1, c2, d; position = position, shape = shape)
    b0 = geom.b0

    # Capacity
    β = punching_β(c1, c2; shape = shape)
    αs = punching_αs(position)
    vc = punching_capacity_stress(fc, β, αs, b0, d; λ = λ)
    ϕvc = ϕ * vc

    # Direct shear stress
    v_direct = uconvert(u"psi", Vu / (b0 * d))

    # Moment magnitudes — test for zero
    Mux_zero = abs(to_kipft(Mux)) < 1e-10
    Muy_zero = abs(to_kipft(Muy)) < 1e-10

    if Mux_zero && Muy_zero
        # Concentric — simple stress
        vu = v_direct

    elseif position == :interior
        # Biaxial eccentric shear (superposition of both moment axes)
        b1 = c1 + d   # x-direction critical section dim
        b2 = c2 + d   # y-direction critical section dim

        # Mux transfers stress in x-direction: γv(b1, b2), Jc(b1, b2), cAB = b1/2
        γv_x  = gamma_v(b1, b2)
        Jc_x  = polar_moment_Jc_interior(b1, b2, d)
        cAB_x = b1 / 2

        # Muy transfers stress in y-direction: γv(b2, b1), Jc(b2, b1), cAB = b2/2
        γv_y  = gamma_v(b2, b1)
        Jc_y  = polar_moment_Jc_interior(b2, b1, d)
        cAB_y = b2 / 2

        v_Mux = uconvert(u"psi", γv_x * abs(Mux) * cAB_x / Jc_x)
        v_Muy = uconvert(u"psi", γv_y * abs(Muy) * cAB_y / Jc_y)
        vu = v_direct + v_Mux + v_Muy

    elseif position == :edge
        # Edge — ACI 318-11 §11.11.7 / R11.11.7.2 (corpus: aci-318-11,
        # pages 209–211): c1 is perp to the free edge (applied above);
        # transfer moment is about the axis parallel to the edge (`Mux`
        # after `_orient_edge_column`).
        Mub = abs(Mux)
        γv_val = gamma_v(geom.b1, geom.b2)
        Jc = polar_moment_Jc_edge(geom.b1, geom.b2, d, geom.cAB)
        # R11.11.7.2 (corpus: aci-318-11, page 210): Mu at centroidal axis c-c.
        # e = (b1 − cAB) − c1/2. See eccentricity_to_critical_centroid.
        e = eccentricity_to_critical_centroid(geom.b1, c1, geom.cAB)
        Mub_adj = max(Mub - Vu * e, zero(Mub))
        v_moment = uconvert(u"psi", γv_val * Mub_adj * geom.cAB / Jc)
        vu = v_direct + v_moment

    else
        # :corner — two-sided critical section.  ACI 318-11 §11.11.7.1
        # (corpus: aci-318-11, page 209) transfers γv Mu by eccentricity of
        # shear at every slab-column connection, including corners.
        # γv from Eq. (11-37) / Eq. (13-1) with the 2-sided b1, b2
        # (§13.5.3.2, page 250).  Jc and cAB from PCA EB712 Fig. 16-13
        # Case D (page 486).  Each axis contributes (biaxial superposition,
        # same as the interior path).
        b1 = geom.b1
        b2 = geom.b2
        cAB_x = geom.cAB_x
        cAB_y = geom.cAB_y

        γv_x = gamma_v(b1, b2)
        γv_y = gamma_v(b2, b1)
        Jc_x = polar_moment_Jc_corner(b1, b2, d, cAB_x)
        Jc_y = polar_moment_Jc_corner(b2, b1, d, cAB_y)

        # Mu at the critical-section centroid (R11.11.7.2, page 210):
        # e = (b − cAB) − c/2 on each free-edge axis.
        # See eccentricity_to_critical_centroid.
        e_x = eccentricity_to_critical_centroid(b1, c1, cAB_x)
        e_y = eccentricity_to_critical_centroid(b2, c2, cAB_y)
        Mux_adj = max(abs(Mux) - Vu * e_x, zero(Mux))
        Muy_adj = max(abs(Muy) - Vu * e_y, zero(Muy))

        v_Mux = uconvert(u"psi", γv_x * Mux_adj * cAB_x / Jc_x)
        v_Muy = uconvert(u"psi", γv_y * Muy_adj * cAB_y / Jc_y)
        vu = v_direct + v_Mux + v_Muy
    end

    ok = vu ≤ ϕvc
    utilization = ustrip(u"psi", vu) / max(ustrip(u"psi", ϕvc), 1e-10)

    return (ok = ok, utilization = utilization, vu = vu, ϕvc = ϕvc,
            b0 = b0, geom = geom)
end

