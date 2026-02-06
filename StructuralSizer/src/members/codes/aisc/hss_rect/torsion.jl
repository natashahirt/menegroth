# ==============================================================================
# AISC 360-16 - Torsion for Rectangular/Square HSS (Section H3)
# ==============================================================================

"""
    torsional_constant_rect_hss(B, H, t)

Torsional constant C for rectangular HSS (AISC H3 User Note).

    C = 2(B-t)(H-t)t - 4.5(4-π)t³

# Arguments
- `B`: Overall width (shorter side for standard orientation)
- `H`: Overall height (longer side)
- `t`: Design wall thickness (0.93 × nominal per B4.2)

# Returns
- `C`: Torsional constant [in³ or mm³]
"""
function torsional_constant_rect_hss(B, H, t)
    return 2 * (B - t) * (H - t) * t - 4.5 * (4 - π) * t^3
end

"""
    get_Fcr_torsion(s::HSSRectSection, mat::Metal)

Critical torsional stress for rectangular HSS per AISC H3.1(b).

Three regimes based on h/t (longer wall slenderness):
- Yielding: h/t ≤ 2.45√(E/Fy) → Fcr = 0.6Fy
- Inelastic: 2.45√(E/Fy) < h/t ≤ 3.07√(E/Fy) → transition
- Elastic: h/t > 3.07√(E/Fy) → Fcr = 0.458π²E/(h/t)²
"""
function get_Fcr_torsion(s::HSSRectSection, mat::Metal)
    E, Fy = mat.E, mat.Fy
    
    # Use the longer wall (h) for torsional buckling check
    # h = flat width of longer side = H - 3t per AISC B4.1b(d)
    h = s.H - 3 * s.t
    t = s.t
    ht = ustrip(h / t)
    
    # Slenderness limits
    rt = sqrt(E / Fy)
    lim1 = 2.45 * rt  # Compact limit
    lim2 = 3.07 * rt  # Noncompact limit
    
    if ht <= lim1
        # H3-3: Yielding (compact)
        return 0.6 * Fy
    elseif ht <= lim2
        # H3-4: Inelastic buckling (noncompact)
        return 0.6 * Fy * (2.45 * rt) / ht
    else
        # H3-5: Elastic buckling (slender)
        return 0.458 * π^2 * E / ht^2
    end
end

"""
    get_Tn(s::HSSRectSection, mat::Metal)

Nominal torsional strength for rectangular HSS per AISC H3-1.

    Tn = Fcr × C

# Returns
- `Tn`: Nominal torsional strength [kip-in or N-mm]
"""
function get_Tn(s::HSSRectSection, mat::Metal)
    Fcr = get_Fcr_torsion(s, mat)
    C = torsional_constant_rect_hss(s.B, s.H, s.t)
    return Fcr * C
end

"""
    get_ϕTn(s::HSSRectSection, mat::Metal; ϕ=0.90)

Design torsional strength (LRFD) for rectangular HSS.
"""
get_ϕTn(s::HSSRectSection, mat::Metal; ϕ=0.90) = ϕ * get_Tn(s, mat)

"""
    check_combined_torsion_interaction(Pr, Mr, Vr, Tr, Pc, Mc, Vc, Tc)

Combined interaction check for HSS with torsion per AISC H3-6.

    (Pr/Pc + Mr/Mc) + (Vr/Vc + Tr/Tc)² ≤ 1.0

# Arguments
- `Pr`, `Mr`, `Vr`, `Tr`: Required strengths (axial, moment, shear, torsion)
- `Pc`, `Mc`, `Vc`, `Tc`: Available strengths (design or allowable)

# Returns
- Interaction ratio (≤1.0 means adequate)

# Notes
- Per H3.2, if Tr ≤ 0.2×Tc, torsion effects may be neglected and H1 applies
"""
function check_combined_torsion_interaction(Pr, Mr, Vr, Tr, Pc, Mc, Vc, Tc)
    # First term: axial + flexure (linear)
    term1 = Pr / Pc + Mr / Mc
    
    # Second term: shear + torsion (squared)
    term2 = (Vr / Vc + Tr / Tc)^2
    
    return term1 + term2
end

"""
    can_neglect_torsion(Tr, Tc)

Check if torsion can be neglected per AISC H3.2.

If Tr ≤ 0.2×Tc, torsion effects may be neglected and standard H1 interaction applies.
"""
can_neglect_torsion(Tr, Tc) = Tr <= 0.2 * Tc
