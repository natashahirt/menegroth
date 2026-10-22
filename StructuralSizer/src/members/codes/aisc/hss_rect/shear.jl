# ==============================================================================
# AISC 360-16 - Shear for Rectangular/Square HSS (Section G4)
# ==============================================================================

"""
Web shear buckling coefficient `Cv2` per AISC 360-16 Section G2.2.

We use the standard three-branch form with limits at:
- 1.10√(kv E/Fy)
- 1.37√(kv E/Fy)
"""
function _Cv2(E, Fy, w; kv::Float64)
    lim1 = 1.10 * sqrt(kv * E / Fy)
    lim2 = 1.37 * sqrt(kv * E / Fy)
    if w <= lim1
        return 1.0
    elseif w <= lim2
        return 1.10 * sqrt(kv * E / Fy) / w
    else
        return 1.51 * kv * E / (Fy * w^2)
    end
end

"""
Nominal shear strength for rectangular HSS (G4-1).

Vn = 0.6 Fy Aw Cv2, with Aw = 2 h t for rectangular HSS (two walls resist shear).
"""
function get_Vn(s::HSSRectSection, mat::Metal; axis=:strong, kv=5.0, rolled=false)
    E, Fy = mat.E, mat.Fy

    # For vertical shear (strong axis), the resisting wall "width" is the clear distance
    # between flanges -> use `h`. For horizontal shear, use `b`.
    h_resist = axis === :weak ? s.b : s.h
    t = s.t

    Aw = 2 * h_resist * t
    w = ustrip(h_resist / t)
    Cv2 = _Cv2(E, Fy, w; kv=Float64(kv))

    return 0.6 * Fy * Aw * Cv2
end

"""
    get_ϕVn(s::HSSRectSection, mat::Metal; axis=:strong, kv=5.0, rolled=false, ϕ=nothing) -> Force

Design shear strength ϕVn for rectangular HSS per AISC 360-16 Section G4 (LRFD).
Default `ϕ_v = 0.90` per §G1(a) (corpus: aisc-360-16, page 126).
"""
get_ϕVn(s::HSSRectSection, mat::Metal; axis=:strong, kv=5.0, rolled=false, ϕ=nothing) =
    (isnothing(ϕ) ? 0.9 : ϕ) * get_Vn(s, mat; axis=axis, kv=kv, rolled=rolled)

