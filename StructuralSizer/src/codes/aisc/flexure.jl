# AISC 360 Chapter F - Design of Members for Flexure

"""
    get_Lp_Lr(s::ISymmSection, mat::Metal)

Compute limiting unbraced lengths for LTB (AISC F2-5, F2-6).
Returns (Lp, Lr, rts, ho, c).
"""
function get_Lp_Lr(s::ISymmSection, mat::Metal)
    E, Fy = mat.E, mat.Fy
    d, tf = s.d, s.tf
    ry, J, Sx, Iy, Cw = s.ry, s.J, s.Sx, s.Iy, s.Cw
    
    ho = d - tf  # distance between flange centroids
    c = 1.0      # doubly symmetric I-shape
    rts = sqrt((Iy * Cw) / Sx)  # F2-7: effective radius of gyration
    
    # Eq F2-5: Limiting length for yielding
    Lp = 1.76 * ry * sqrt(E / Fy)
    
    # Eq F2-6: Limiting length for inelastic LTB
    jc_term = (J * c) / (Sx * ho)
    Lr = 1.95 * rts * (E / (0.7 * Fy)) * sqrt(jc_term + sqrt(jc_term^2 + 6.76 * (0.7 * Fy / E)^2))
    
    return (Lp=Lp, Lr=Lr, rts=rts, ho=ho, c=c)
end

"""
    get_Fcr(s::ISymmSection, mat::Metal, Lb; Cb=1.0)

Critical stress for elastic LTB (AISC Eq F2-4).
"""
function get_Fcr(s::ISymmSection, mat::Metal, Lb; Cb=1.0)
    E = mat.E
    ltb = get_Lp_Lr(s, mat)
    rts, ho, c = ltb.rts, ltb.ho, ltb.c
    J, Sx = s.J, s.Sx
    
    lb_rts = Lb / rts
    Fcr = Cb * π^2 * E / lb_rts^2 * sqrt(1 + 0.078 * (J * c) / (Sx * ho) * lb_rts^2)
    return Fcr
end

"""
    get_Mn(s::ISymmSection, mat::Metal; Lb=0, Cb=1.0)

Nominal flexural strength about strong axis (AISC Chapter F2).
Considers yielding, LTB, and FLB limit states.

# Arguments
- `s`: ISymmSection
- `mat`: Metal material
- `Lb`: Unbraced length (0 = fully braced)
- `Cb`: Moment gradient factor (1.0 = conservative)
"""
function get_Mn(s::ISymmSection, mat::Metal; Lb=zero(s.d), Cb=1.0)
    E, Fy = mat.E, mat.Fy
    d, tw, tf = s.d, s.tw, s.tf
    Zx, Sx = s.Zx, s.Sx
    
    # F2.1 Yielding
    Mp = Fy * Zx
    Mn = Mp
    
    # F2.2 Lateral-Torsional Buckling
    if Lb > zero(Lb)
        ltb = get_Lp_Lr(s, mat)
        Lp, Lr = ltb.Lp, ltb.Lr
        
        if Lb > Lr
            # Elastic LTB (Eq F2-3)
            Fcr = get_Fcr(s, mat, Lb; Cb=Cb)
            Mn_LTB = Fcr * Sx
            Mn = min(Mn, Mn_LTB)
        elseif Lb > Lp
            # Inelastic LTB (Eq F2-2)
            Mn_LTB = Cb * (Mp - (Mp - 0.7 * Fy * Sx) * ((Lb - Lp) / (Lr - Lp)))
            Mn = min(Mn, min(Mn_LTB, Mp))
        end
    end
    
    # F3.2 Compression Flange Local Buckling
    sl = get_slenderness(s, mat)
    λ_f, λp_f, λr_f = sl.λ_f, sl.λp_f, sl.λr_f
    
    if sl.class_f == :slender
        # Eq F3-2
        h = d - tf  # Distance between flange centroids (F3.2)
        kc = 4 / sqrt(h / tw)
        kc = clamp(kc, 0.35, 0.76)
        Mn_FLB = 0.9 * E * kc * Sx / λ_f^2
        Mn = min(Mn, Mn_FLB)
    elseif sl.class_f == :noncompact
        # Eq F3-1
        Mn_FLB = Mp - (Mp - 0.7 * Fy * Sx) * ((λ_f - λp_f) / (λr_f - λp_f))
        Mn = min(Mn, Mn_FLB)
    end
    
    return Mn
end

"""
    get_ϕMn(s::ISymmSection, mat::Metal; Lb=0, Cb=1.0, ϕ=0.9)

Design flexural strength (LRFD).
"""
get_ϕMn(s::ISymmSection, mat::Metal; Lb=zero(s.d), Cb=1.0, ϕ=0.9) = ϕ * get_Mn(s, mat; Lb=Lb, Cb=Cb)
