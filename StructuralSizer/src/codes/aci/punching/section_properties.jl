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

