# ==============================================================================
# AISC 360-16 - Rectangular/Square HSS Slenderness (Table B4.1a / B4.1b)
# ==============================================================================

"""
Flexure slenderness classification for rectangular HSS (Table B4.1b).

Returns a named tuple:
- `class_f`, `class_w` in `(:compact, :noncompact, :slender)`
- `λ_f`, `λp_f`, `λr_f`
- `λ_w`, `λp_w`, `λr_w`
"""
function get_slenderness(s::HSSRectSection, mat::Metal)
    E, Fy = mat.E, mat.Fy

    # Width-to-thickness ratios (B4.1b note d: use clear flat widths with tdes)
    λ_f = s.λ_f  # b/t
    λ_w = s.λ_w  # h/t

    # Table B4.1b:
    # Flanges of rectangular HSS: λp = 1.12√(E/Fy), λr = 1.40√(E/Fy)
    λp_f = 1.12 * sqrt(E / Fy)
    λr_f = 1.40 * sqrt(E / Fy)

    # Webs of rectangular HSS and box sections (Table B4.1b Case 19):
    # λp = 2.42√(E/Fy), λr = 5.70√(E/Fy)
    λp_w = 2.42 * sqrt(E / Fy)
    λr_w = 5.70 * sqrt(E / Fy)

    class_f = λ_f > λr_f ? :slender : (λ_f > λp_f ? :noncompact : :compact)
    class_w = λ_w > λr_w ? :slender : (λ_w > λp_w ? :noncompact : :compact)

    return (;
        λ_f, λp_f, λr_f, class_f,
        λ_w, λp_w, λr_w, class_w
    )
end

"""
Compression slenderness limit for rectangular HSS walls (Table B4.1a).

Returns: `(; λ_f, λ_w, λr)` with λr being the nonslender/slender boundary.
"""
function get_compression_limits(s::HSSRectSection, mat::Metal)
    E, Fy = mat.E, mat.Fy
    λ_f = s.λ_f
    λ_w = s.λ_w
    # Table B4.1a: Walls of rectangular HSS: λr = 1.40√(E/Fy)
    λr = 1.40 * sqrt(E / Fy)
    return (; λ_f, λ_w, λr)
end

