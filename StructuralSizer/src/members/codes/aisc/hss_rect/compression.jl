# ==============================================================================
# AISC 360-16 - Compression for Rectangular/Square HSS
# ==============================================================================
# Implements global buckling per E3 using Euler stress + column curve.
# Local buckling per E7 with effective width for slender walls.

"""
    _Ae_rect_hss(s::HSSRectSection, mat::Metal, Fcr=nothing)

Effective area for rectangular HSS per AISC E7 (Members with Slender Elements).

For slender walls (λ > λr per Table B4.1a), calculates effective width using:
- be = b × √(Fel/Fcr) × (1 - c1×√(Fel/Fcr))  (E7-3)
- Fel = (c2 × λr/λ)² × Fy  (E7-5)

Table E7.1 Case (a) for stiffened elements: c1 = 0.18, c2 = 1.31

If Fcr is not provided, uses Fy as a conservative assumption (no iteration).
"""
function _Ae_rect_hss(s::HSSRectSection, mat::Metal, Fcr=nothing)
    lim = get_compression_limits(s, mat)
    λ_f, λ_w, λr = lim.λ_f, lim.λ_w, lim.λr
    E, Fy = mat.E, mat.Fy
    t = s.t
    
    # Default Fcr to Fy (conservative, avoids iteration)
    if isnothing(Fcr)
        Fcr = Fy
    end
    
    # Table E7.1 Case (a): stiffened elements
    c1 = 0.18
    c2 = 1.31
    
    # Start with gross area
    Ae = s.A
    
    # Check flanges (shorter walls) - width = b - 3t per AISC convention
    if λ_f > λr
        b = s.B - 3*t  # Clear width between corners
        be = _calc_effective_width(b, t, λ_f, λr, Fy, Fcr, c1, c2)
        ΔA_f = 2 * (b - be) * t  # Two flanges
        Ae -= ΔA_f
    end
    
    # Check webs (longer walls) - height = h - 3t
    if λ_w > λr
        h = s.H - 3*t  # Clear height between corners
        be = _calc_effective_width(h, t, λ_w, λr, Fy, Fcr, c1, c2)
        ΔA_w = 2 * (h - be) * t  # Two webs
        Ae -= ΔA_w
    end
    
    # Ensure non-negative
    return max(Ae, zero(Ae))
end

"""
    _calc_effective_width(b, t, λ, λr, Fy, Fcr, c1, c2)

Calculate effective width per AISC E7-3 and E7-5.

# Arguments
- `b`: Full width of element
- `t`: Wall thickness
- `λ`: Slenderness ratio (b/t)
- `λr`: Slenderness limit for noncompact/slender boundary
- `Fy`: Yield stress
- `Fcr`: Critical buckling stress
- `c1, c2`: Imperfection adjustment factors from Table E7.1
"""
function _calc_effective_width(b, t, λ, λr, Fy, Fcr, c1, c2)
    # Elastic local buckling stress (E7-5)
    Fel = (c2 * λr / λ)^2 * Fy
    
    # Effective width (E7-3)
    ratio = sqrt(Fel / Fcr)
    be = b * ratio * (1 - c1 * ratio)
    
    # Clamp to valid range
    return clamp(be, zero(b), b)
end

function get_Pn(s::HSSRectSection, mat::Metal, L; axis=:weak)
    E, Fy = mat.E, mat.Fy
    r = axis === :weak ? s.ry : s.rx
    Fe = _Fe_euler(E, L, r)
    Fcr = _Fcr_column(Fe, Fy)
    Ae = _Ae_rect_hss(s, mat)
    return Fcr * Ae
end

function get_ϕPn(s::HSSRectSection, mat::Metal, L; axis=:weak, ϕ=0.9)
    axis_eff = axis === :torsional ? :weak : axis
    return ϕ * get_Pn(s, mat, L; axis=axis_eff)
end

