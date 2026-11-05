# AISC 360-16 Chapter E — Design of Members for Compression
# Source: corpus aisc-360-16, pp. 91–101.
#
# Implementation note (AISC 360-16 §E7 unified effective-area approach):
#   AISC 360-16 §E7 replaced the AISC 360-10 Qs/Qa decomposition with a
#   unified effective-area approach. This module now implements §E7 directly:
#
#     1. Compute Fe (§E3-4 for flexural buckling, §E4-2 for torsional).
#     2. Compute Fcr from §E3-2/E3-3 using full Ag's slenderness ratio
#        (Eq. E3-2 or E3-3, NO Q multiplier).
#     3. Compute Ae per §E7 (Eqs. E7-1 — E7-5, Table E7.1) using that Fcr.
#        Each plate element either takes its full width (be = b) when
#        λ ≤ λr·√(Fy/Fcr), or a reduced effective width per Eq. E7-3.
#     4. Pn = Fcr · Ae (Eq. E7-1).
#
#   This handles slender flanges, slender webs, and built-up plate girders
#   correctly. For the rolled-W catalog at Fy ≤ 65 ksi, Ae = Ag essentially
#   always, so the result matches the older Q-based path numerically.

"""
    get_Fe_flexural(s::ISymmSection, mat::Metal, L; axis=:weak) -> Pressure

Elastic flexural buckling stress per AISC 360-16 §E3, Eq. E3-4 (corpus
aisc-360-16, p. 92):

    Fe = π² E / (Lc/r)²

# Arguments
- `L`:    Effective length `Lc = KL`
- `axis`: `:strong` (uses `rx`) or `:weak` (uses `ry`)
"""
function get_Fe_flexural(s::ISymmSection, mat::Metal, L; axis=:weak)
    E = mat.E
    r = axis == :weak ? s.ry : s.rx
    KL_r = L / r
    return π^2 * E / KL_r^2
end

"""
    get_Fe_torsional(s::ISymmSection, mat::Metal, Lz) -> Pressure

Elastic torsional buckling stress for **doubly symmetric** members twisting
about the shear center, per AISC 360-16 §E4(a), Eq. E4-2 (corpus aisc-360-16,
p. 92):

    Fe = (π² E Cw / Lcz² + G J) · 1/(Ix + Iy)

# Arguments
- `Lz`: Effective length for torsional buckling, `Lcz = Kz·L` (§E4 User Note,
        p. 93). May conservatively be taken as the full member length.
"""
function get_Fe_torsional(s::ISymmSection, mat::Metal, Lz)
    # AISC 360-16 §E4(a), Eq. E4-2 (doubly symmetric shapes about shear center).
    # Catalogue shapes store Cw and J in metres; a plate girder from the beam
    # NLP stores them in inches. Adding those two terms through Unitful builds
    # an inch^6 ↔ metre factor that overflows Int64, so the sum is done in
    # inches. `_torsion_props_in` converts Cw with a float inch factor.
    p = _torsion_props_in(s)
    Iy = ustrip(u"inch^4", s.Iy)
    E = to_ksi(mat.E)
    G = to_ksi(mat.G)
    Lz_in = to_inches(Lz)
    term1 = π^2 * E * p.Cw / Lz_in^2
    term2 = G * p.J
    return ((term1 + term2) / (p.Ix + Iy)) * u"ksi"
end

"""
    calculate_Fcr(Fe, Fy) -> Pressure

Critical buckling stress `Fcr` per AISC 360-16 §E3, Eqs. E3-2/E3-3 (corpus
aisc-360-16, p. 92):

    Fy/Fe ≤ 2.25:    Fcr = (0.658^(Fy/Fe)) · Fy        (Eq. E3-2)
    Fy/Fe > 2.25:    Fcr = 0.877 · Fe                  (Eq. E3-3)

In AISC 360-16 the slender-element reduction is applied through the
effective area `Ae` (§E7), **not** through `Fcr`. So this function takes no
`Q` argument and produces the unreduced §E3 critical stress, which is then
multiplied by the §E7 effective area in [`get_Pn`](@ref).
"""
function calculate_Fcr(Fe, Fy)
    ratio = Fy / Fe
    if ratio <= 2.25
        return (0.658^ratio) * Fy
    else
        return 0.877 * Fe
    end
end

"""
    calculate_Fcr(Fe, Fy, Q) -> Pressure

Legacy AISC 360-10 §E7-2/E7-3 form `Fcr = Q · 0.658^(Q Fy/Fe) · Fy`. Retained
for backward compatibility with downstream callers; new code should use the
two-argument form together with [`get_Pn`](@ref) and the §E7 effective area.
"""
function calculate_Fcr(Fe, Fy, Q)
    ratio = Q * Fy / Fe
    if ratio <= 2.25
        return Q * (0.658^ratio) * Fy
    else
        return 0.877 * Fe
    end
end

"""
    get_Pn(s::ISymmSection, mat::Metal, L; axis=:weak) -> Force

Nominal compressive strength per AISC 360-16 §E7, Eq. E7-1 (corpus
aisc-360-16, p. 98):

    Pn = Fcr · Ae

with `Fcr` from §E3-2/E3-3 (computed from full `Ag`) and `Ae` from §E7-2 –
E7-5 (effective area accounting for any slender elements).

# Limit states considered
- Flexural buckling about the strong or weak axis (§E3, Eq. E3-4)
- Torsional buckling about the shear center (§E4(a), Eq. E4-2)
- Local buckling of slender plate elements via the §E7 effective-width
  reduction (`Ae < Ag` for plate-girder webs or built-up slender flanges)

The caller is responsible for taking the minimum `Pn` across applicable axes.

# Arguments
- `L`:    Effective length `Lc = KL` (or `Lcz = Kz L` for `:torsional`)
- `axis`: `:strong`, `:weak`, or `:torsional`
"""
function get_Pn(s::ISymmSection, mat::Metal, L; axis=:weak)
    Fy = mat.Fy

    # Step 1: elastic buckling stress Fe — flexural (§E3) or torsional (§E4(a)).
    if axis == :torsional
        Fe = get_Fe_torsional(s, mat, L)  # `L` here is the torsional Lcz
    else
        Fe = get_Fe_flexural(s, mat, L; axis=axis)
    end

    # Step 2: critical stress Fcr from §E3-2/E3-3 (no Q multiplier).
    Fcr = calculate_Fcr(Fe, Fy)

    # Step 3: effective area Ae per §E7 using that Fcr.
    Ae = _compute_Ae_E7(s, mat, Fcr).Ae

    # Step 4: §E7 Eq. E7-1.
    return Fcr * Ae
end

"""
    get_ϕPn(s::ISymmSection, mat::Metal, L; axis=:weak, ϕ=0.90) -> Force

Design compressive strength `ϕPn` per AISC 360-16 §E1 (LRFD). The resistance
factor `ϕ_c = 0.90` applies to all Chapter E limit states (corpus
aisc-360-16, p. 91).
"""
get_ϕPn(s::ISymmSection, mat::Metal, L; axis=:weak, ϕ=0.90) = ϕ * get_Pn(s, mat, L; axis=axis)
