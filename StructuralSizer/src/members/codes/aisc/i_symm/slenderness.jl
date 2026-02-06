# AISC 360 Table B4.1b - Slenderness Limits for Flexure

"""Slenderness ratios and limits for flanges and web (Flexure)."""
function get_slenderness(s::ISymmSection, mat::Metal)
    λ_f, λ_w = s.λ_f, s.λ_w
    E, Fy = mat.E, mat.Fy
    
    # Flange (Case 10)
    λp_f = 0.38 * sqrt(E / Fy)
    λr_f = 1.0 * sqrt(E / Fy)
    class_f = λ_f > λr_f ? :slender : (λ_f > λp_f ? :noncompact : :compact)
    
    # Web (Case 15)
    λp_w = 3.76 * sqrt(E / Fy)
    λr_w = 5.70 * sqrt(E / Fy)
    class_w = λ_w > λr_w ? :slender : (λ_w > λp_w ? :noncompact : :compact)
    
    return (λ_f=λ_f, λp_f=λp_f, λr_f=λr_f, class_f=class_f,
            λ_w=λ_w, λp_w=λp_w, λr_w=λr_w, class_w=class_w)
end

"""Slenderness limits for Compression (Table B4.1a). Returns Qs, Qa."""
function get_compression_factors(s::ISymmSection, mat::Metal)
    λ_f, λ_w = s.λ_f, s.λ_w
    E, Fy = mat.E, mat.Fy

    # --- Qs: Unstiffened Elements (Flanges) ---
    # Case 1: Rolled I-shapes
    qs_limit_1 = 0.56 * sqrt(E / Fy)
    qs_limit_2 = 1.03 * sqrt(E / Fy)

    if λ_f <= qs_limit_1
        Qs = 1.0
    elseif λ_f < qs_limit_2
        # E7-5
        Qs = 1.415 - 0.74 * λ_f * sqrt(Fy / E)
    else
        # E7-6
        Qs = 0.69 * E / (Fy * λ_f^2)
    end

    # --- Qa: Stiffened Elements (Webs) ---
    # Case 5: Doubly symmetric I-shapes (Table B4.1a)
    # Limit for slender web: λr = 1.49√(E/Fy)
    λr_w = 1.49 * sqrt(E / Fy)

    if λ_w <= λr_w
        Qa = 1.0
    else
        # AISC E7: Members with Slender Elements
        # Qa = Ae/Ag where Ae uses reduced effective width be
        Qa = _calc_Qa_web(s, mat, λ_w, λr_w)
    end

    return (Qs=Qs, Qa=Qa, Q=Qs*Qa)
end

"""
    _calc_Qa_web(s::ISymmSection, mat::Metal, λ_w, λr_w) -> Float64

Calculate Qa for slender web per AISC 360-16 Section E7.
Uses effective width formula (E7-3) with imperfection factors from Table E7.1.

# AISC E7 Formulas
- be = b × √(Fel/Fcr) × (1 - c1×√(Fel/Fcr))  (E7-3)
- Fel = (c2 × λr/λ)² × Fy  (E7-5)

For stiffened I-shape webs (Table E7.1 Case a):
- c1 = 0.18
- c2 = 1.31

Note: This uses Fcr = Fy (conservative). For more economy, iterate with actual Fcr.
"""
function _calc_Qa_web(s::ISymmSection, mat::Metal, λ_w::Real, λr_w::Real)
    E, Fy = mat.E, mat.Fy
    
    # Table E7.1 Case (a): Stiffened elements (I-shape webs)
    c1 = 0.18
    c2 = 1.31
    
    # Web dimensions
    h = s.h  # clear web height
    tw = s.tw
    
    # Elastic local buckling stress (E7-5)
    Fel = (c2 * λr_w / λ_w)^2 * Fy
    
    # Critical stress - use Fy (conservative, no iteration)
    # For rolled shapes, actual Fcr is typically close to Fy anyway
    Fcr = Fy
    
    # Effective width (E7-3)
    ratio = sqrt(Fel / Fcr)
    be = h * ratio * (1 - c1 * ratio)
    
    # Ensure be ≤ h and be > 0
    be = clamp(be, 0.0*h, h)
    
    # Effective area
    # Ae = Ag - (h - be) × tw
    ΔA = (h - be) * tw
    Ag = s.A
    Ae = Ag - ΔA
    
    # Qa = Ae/Ag
    Qa = Ae / Ag
    
    return max(Qa, 0.0)  # Ensure non-negative
end

"""Check if section is compact in both flange and web (Flexure)."""
function is_compact(s::ISymmSection, mat::Metal)
    sl = get_slenderness(s, mat)
    return sl.class_f == :compact && sl.class_w == :compact
end
