# AISC 360 Table B4.1b - Slenderness Limits for Compression Elements

"""
    get_slenderness(s::ISymmSection, mat::Metal)

Compute slenderness ratios and limits for flanges and web (AISC Table B4.1b).
Returns NamedTuple with λ values, limits, and classifications.
"""
function get_slenderness(s::ISymmSection, mat::Metal)
    d, bf, tw, tf = s.d, s.bf, s.tw, s.tf
    E, Fy = mat.E, mat.Fy
    
    # Flange slenderness (Case 10: Flanges of rolled I-shapes)
    λ_f  = bf / (2 * tf)
    λp_f = 0.38 * sqrt(E / Fy)
    λr_f = 1.0 * sqrt(E / Fy)
    
    class_f = if λ_f > λr_f
        :slender
    elseif λ_f > λp_f
        :noncompact
    else
        :compact
    end
    
    # Web slenderness (Case 15: Webs of doubly-symmetric I-shapes)
    hw = d - 2 * tf
    λ_w  = hw / tw
    λp_w = 3.76 * sqrt(E / Fy)
    λr_w = 5.70 * sqrt(E / Fy)
    
    class_w = if λ_w > λr_w
        :slender
    elseif λ_w > λp_w
        :noncompact
    else
        :compact
    end
    
    return (
        # Flange
        λ_f = λ_f, λp_f = λp_f, λr_f = λr_f, class_f = class_f,
        # Web
        λ_w = λ_w, λp_w = λp_w, λr_w = λr_w, class_w = class_w
    )
end

"""
    is_compact(s::ISymmSection, mat::Metal)

Check if section is compact in both flange and web.
"""
function is_compact(s::ISymmSection, mat::Metal)
    sl = get_slenderness(s, mat)
    return sl.class_f == :compact && sl.class_w == :compact
end
