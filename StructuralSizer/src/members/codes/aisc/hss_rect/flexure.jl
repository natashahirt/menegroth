# ==============================================================================
# AISC 360-16 - Flexure for Rectangular/Square HSS (Section F7)
# ==============================================================================

"""
    _Se_rect_hss(s::HSSRectSection, mat::Metal; axis::Symbol)

Effective section modulus for slender rectangular HSS per AISC F7-3.

For slender compression flanges (webs in minor-axis bending), uses effective width
from E7 to compute reduced section modulus. Uses simplified scaling approach rather
than full sectional recalculation.

# AISC F7.2(c): Compression Flange Local Buckling
For slender elements:
- be = 1.92t√(E/Fy) × [1 - 0.38/(b/t)√(E/Fy)] ≤ b  (F7-4)
- Se = S × (be/b)  (approximate; F7-3 uses Mn = Fy × Se)
"""
function _Se_rect_hss(s::HSSRectSection, mat::Metal; axis::Symbol)
    E, Fy = mat.E, mat.Fy
    t = s.t
    
    # Compression element: flange for strong-axis, web for weak-axis
    # For strong axis bending (about x), compression is in the top/bottom walls (width b)
    # For weak axis bending (about y), compression is in the side walls (height h)
    if axis === :weak
        bcomp = s.H - 3*t  # Clear web height
        S = s.Sy
    else
        bcomp = s.B - 3*t  # Clear flange width
        S = s.Sx
    end
    
    λ = ustrip(bcomp / t)
    
    # F7-4: Effective width for slender compression elements
    rt = sqrt(E / Fy)
    be = 1.92 * t * rt * (1 - 0.38 / λ * rt)
    be = clamp(be, zero(be), bcomp)
    
    # Approximate Se by scaling S by effective width ratio
    # This is conservative; exact solution requires rebuilding section properties
    Se = S * (be / bcomp)
    
    return Se
end

function get_Mn(s::HSSRectSection, mat::Metal; Lb=zero(s.H), Cb=1.0, axis=:strong)
    Fy = mat.Fy
    Z = axis === :weak ? s.Zy : s.Zx
    S = axis === :weak ? s.Sy : s.Sx
    Mp = Fy * Z
    My = Fy * S

    sl = get_slenderness(s, mat)
    class_f = sl.class_f
    class_w = sl.class_w

    # Compact: Mn = Mp (F7-1)
    if class_f == :compact && class_w == :compact
        return Mp
    end

    # Slender: Mn = Fy*Se (F7-3 style; Se is computed approximately)
    if class_f == :slender || class_w == :slender
        Se = _Se_rect_hss(s, mat; axis=axis)
        return Fy * Se
    end

    # Noncompact: interpolate between Mp and My (F7-2 style)
    if class_f == :noncompact
        Mn = _linear_interp(sl.λ_f, sl.λp_f, sl.λr_f, Mp, My)
        return min(Mn, Mp)
    else
        Mn = _linear_interp(sl.λ_w, sl.λp_w, sl.λr_w, Mp, My)
        return min(Mn, Mp)
    end
end

get_ϕMn(s::HSSRectSection, mat::Metal; Lb=zero(s.H), Cb=1.0, axis=:strong, ϕ=0.9) =
    ϕ * get_Mn(s, mat; Lb=Lb, Cb=Cb, axis=axis)

