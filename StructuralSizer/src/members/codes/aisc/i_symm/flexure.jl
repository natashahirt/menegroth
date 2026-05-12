# AISC 360-16 Chapter F — Design of Members for Flexure
# Source: corpus aisc-360-16, pp. 102–104.

"""
    get_Lp_Lr(s::ISymmSection, mat::Metal) -> NamedTuple(:Lp, :Lr, :c)

Limiting unbraced lengths for lateral-torsional buckling per AISC 360-16 §F2.2.

# Returns
- `Lp`: Limiting laterally unbraced length for yielding (Eq. F2-5)
- `Lr`: Limiting laterally unbraced length for inelastic LTB (Eq. F2-6)
- `c`:  LTB modification factor (1.0 for doubly symmetric I-shapes per §F2.2)
"""
function get_Lp_Lr(s::ISymmSection, mat::Metal)
    E, Fy = mat.E, mat.Fy
    ry, J, Sx, ho, rts = s.ry, s.J, s.Sx, s.ho, s.rts
    c = 1.0  # doubly symmetric I-shape (AISC 360-16 §F2.2, p. 104)

    # AISC 360-16 §F2.2, Eq. F2-5 (corpus aisc-360-16, p. 104):
    #   Lp = 1.76 ry √(E/Fy)
    Lp = 1.76 * ry * sqrt(E / Fy)

    # AISC 360-16 §F2.2, Eq. F2-6 (corpus aisc-360-16, p. 104):
    #   Lr = 1.95 rts (E / 0.7Fy) √[ Jc/(Sx ho) + √( (Jc/(Sx ho))² + 6.76 (0.7Fy/E)² ) ]
    jc_term = (J * c) / (Sx * ho)
    Lr = 1.95 * rts * (E / (0.7 * Fy)) * sqrt(jc_term + sqrt(jc_term^2 + 6.76 * (0.7 * Fy / E)^2))

    return (Lp=Lp, Lr=Lr, c=c)
end

"""
    get_Fcr_LTB(s::ISymmSection, mat::Metal, Lb; Cb=1.0) -> Pressure

Critical stress for elastic lateral-torsional buckling per AISC 360-16 Eq. F2-4
(corpus aisc-360-16, p. 103):

    Fcr = Cb π² E / (Lb/rts)² · √[ 1 + 0.078 Jc/(Sx ho) · (Lb/rts)² ]

# Arguments
- `Lb`: Laterally unbraced length
- `Cb`: Lateral-torsional buckling modification factor (default 1.0, §F1)
"""
function get_Fcr_LTB(s::ISymmSection, mat::Metal, Lb; Cb=1.0)
    E = mat.E
    J, Sx, ho, rts = s.J, s.Sx, s.ho, s.rts
    c = 1.0
    lb_rts = Lb / rts
    return Cb * π^2 * E / lb_rts^2 * sqrt(1 + 0.078 * (J * c) / (Sx * ho) * lb_rts^2)
end

"""
    get_Mn(s::ISymmSection, mat::Metal; Lb, Cb=1.0, axis=:strong) -> Moment

Nominal flexural strength per AISC 360-16 Chapter F (corpus aisc-360-16, pp. 102–112).

# Section scope
- Strong axis with **compact web** + **compact flange**:                §F2 (yielding + LTB)
- Strong axis with **compact web** + non-compact / slender flange:     §F3 (LTB + FLB)
- Strong axis with non-compact or slender web:                         §F4 / §F5 (NOT IMPLEMENTED — guarded)
- Weak axis (any web class, since web does not participate):           §F6 (yielding + FLB)

A non-compact or slender web on the strong axis routes the limit-state set into
§F4 (CFY, LTB, CFLB, TFY) or §F5 (slender web). These methods are not implemented
and the function throws rather than silently falling back to F2/F3, which would
be unconservative (web post-buckling limits would be ignored).

# Arguments
- `Lb`:  Laterally unbraced length (default 0 = full bracing)
- `Cb`:  LTB modification factor (default 1.0, §F1)
- `axis`: `:strong` (§F2/F3) or `:weak` (§F6)
"""
function get_Mn(s::ISymmSection, mat::Metal; Lb=zero(s.d), Cb=1.0, axis=:strong)
    E, Fy = mat.E, mat.Fy

    if axis == :strong
        # --- Strong-axis web compactness gate (§F2/F3 vs §F4/F5) ---
        # AISC 360-16 Table B4.1b Case 15 (corpus aisc-360-16, pp. 36, 102):
        #   Compact web:    h/tw ≤ 3.76 √(E/Fy)
        #   Slender web:    h/tw > 5.70 √(E/Fy)
        # F2 and F3 are only valid for compact webs. Non-compact webs require
        # F4 (compression-flange yielding + LTB + CFLB + TFY); slender webs F5.
        sl = get_slenderness(s, mat)
        if sl.class_w !== :compact
            throw(ErrorException(
                "Strong-axis flexure for ISymmSection with web class :$(sl.class_w) " *
                "(h/tw = $(round(sl.λ_w; digits=1))) requires AISC 360-16 §F4 (non-compact web) " *
                "or §F5 (slender web), which are not implemented. " *
                "All current ASTM A6 W, S, and HP shapes have compact webs at Fy ≤ 50 ksi " *
                "(AISC 360-16 §F2 User Note, p. 47), so this should not trigger for the " *
                "standard rolled catalog."))
        end

        Zx, Sx = s.Zx, s.Sx

        # AISC 360-16 §F2.1, Eq. F2-1 (corpus aisc-360-16, p. 102):
        #   Mp = Fy Zx  (yielding)
        Mp = Fy * Zx
        Mn = Mp

        # 1. Lateral-torsional buckling — §F2.2 (Eqs. F2-2, F2-3) (p. 103)
        if Lb > zero(Lb)
            ltb = get_Lp_Lr(s, mat)
            Lp, Lr = ltb.Lp, ltb.Lr

            if Lb > Lr
                # Eq. F2-3 (elastic LTB): Mn = Fcr Sx ≤ Mp
                Fcr = get_Fcr_LTB(s, mat, Lb; Cb=Cb)
                Mn = min(Mn, Fcr * Sx)
            elseif Lb > Lp
                # Eq. F2-2 (inelastic LTB):
                #   Mn = Cb [Mp − (Mp − 0.7 Fy Sx)((Lb − Lp)/(Lr − Lp))] ≤ Mp
                Mn_LTB = Cb * (Mp - (Mp - 0.7 * Fy * Sx) * ((Lb - Lp) / (Lr - Lp)))
                Mn = min(Mn, min(Mn_LTB, Mp))
            end
            # Lb ≤ Lp: yielding governs, no LTB reduction.
        end

        # 2. Compression flange local buckling — §F3.2 (Eqs. F3-1, F3-2) (p. 105)
        # F3 applies to doubly-symmetric I-shapes with compact web AND non-compact
        # or slender flanges. The web-class gate above ensures the compact-web
        # precondition; here we check flange compactness.
        λ_f, λp_f, λr_f = sl.λ_f, sl.λp_f, sl.λr_f

        if sl.class_f == :slender
            # Eq. F3-2: Mn = 0.9 E kc Sx / λ²,  kc = 4/√(h/tw), bounded [0.35, 0.76]
            kc = clamp(4 / sqrt(s.λ_w), 0.35, 0.76)
            Mn = min(Mn, 0.9 * E * kc * Sx / λ_f^2)
        elseif sl.class_f == :noncompact
            # Eq. F3-1: Mn = Mp − (Mp − 0.7 Fy Sx)((λ − λpf)/(λrf − λpf))
            Mn = min(Mn, Mp - (Mp - 0.7 * Fy * Sx) * ((λ_f - λp_f) / (λr_f - λp_f)))
        end

        return Mn

    else
        # --- Weak-axis bending (§F6) ---
        # AISC 360-16 §F6 (corpus aisc-360-16, p. 110):
        #   Eq. F6-1 (yielding): Mp = min(Fy Zy, 1.6 Fy Sy)
        # Web does not participate in weak-axis bending, so no web-class gate here.
        Zy, Sy = s.Zy, s.Sy
        Mp = min(Fy * Zy, 1.6 * Fy * Sy)
        Mn = Mp

        # Flange local buckling — §F6.2 (Eqs. F6-2, F6-3)
        # Limits per Table B4.1b Case 10: λp = 0.38√(E/Fy), λr = 1.0√(E/Fy).
        sl = get_slenderness(s, mat)
        λ = sl.λ_f
        λp = 0.38 * sqrt(E / Fy)
        λr = 1.0 * sqrt(E / Fy)

        if λ > λr
            # Eq. F6-3 (slender flange): Mn = Fcr Sy,  Fcr = 0.69 E / λ²
            Fcr = 0.69 * E / λ^2
            Mn = min(Mn, Fcr * Sy)
        elseif λ > λp
            # Eq. F6-2 (non-compact flange):
            #   Mn = Mp − (Mp − 0.7 Fy Sy)((λ − λpf)/(λrf − λpf))
            Mn = min(Mn, Mp - (Mp - 0.7 * Fy * Sy) * ((λ - λp) / (λr - λp)))
        end

        return Mn
    end
end

"""
    get_ϕMn(s::ISymmSection, mat::Metal; Lb, Cb=1.0, axis=:strong, ϕ=0.9) -> Moment

Design flexural strength ϕMn per AISC 360-16 §F1 (LRFD). The resistance factor
`ϕ_b = 0.90` applies to all flexural limit states in Chapter F (corpus
aisc-360-16, p. 102).
"""
get_ϕMn(s::ISymmSection, mat::Metal; Lb=zero(s.d), Cb=1.0, axis=:strong, ϕ=0.9) =
    ϕ * get_Mn(s, mat; Lb=Lb, Cb=Cb, axis=axis)
