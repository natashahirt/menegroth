# ==============================================================================
# AISC 360-16 - Shear for Round HSS / Pipe (Section G5)
# ==============================================================================

using Asap: ksi

"""
    get_Vn(s::HSSRoundSection, mat::Metal; Lv=nothing, axis=:strong, kv=5.0, rolled=false)

Nominal shear strength for round HSS per AISC 360-16 Section G5.

Vn = Fcr × Ag / 2  (G5-1)

where Fcr is the larger of the shear buckling stresses but ≤ 0.6Fy:

- Fcr1 = 1.60E / √(Lv/D) × (D/t)^(5/4)  (G5-2a)
- Fcr2 = 0.78E / (D/t)^(3/2)  (G5-2b)

# Arguments
- `s::HSSRoundSection`: Round HSS section
- `mat::Metal`: Material with E, Fy
- `Lv`: Distance from maximum to zero shear (length). If nothing, uses Fcr = 0.6Fy (conservative)
- `axis`: Axis of bending (shear is symmetric for round sections)
- `kv`: Shear buckling coefficient (default 5.0, not used for round HSS)
- `rolled`: Whether section is rolled (not used for round HSS)

# Notes
- If Lv is not provided, conservatively assumes shear yielding (Fcr = 0.6Fy)
- For simple spans with uniform load, Lv ≈ L/2 (shear max at supports, zero at midspan)
- For point loads at midspan, Lv = L/2
- User note: For most standard round HSS, shear yielding controls
"""
function get_Vn(s::HSSRoundSection, mat::Metal; Lv=nothing, axis=:strong, kv=5.0, rolled=false)
    E, Fy = mat.E, mat.Fy
    D = s.OD  # Outer diameter
    t = s.t   # Wall thickness
    Ag = s.A
    
    # Shear yielding limit
    Fcr_yield = 0.6 * Fy
    
    if isnothing(Lv)
        # Conservative: use shear yielding
        Fcr = Fcr_yield
    else
        # Calculate buckling stresses per G5-2
        # D_t and Lv_D are dimensionless ratios
        D_t = D / t
        Lv_D = Lv / D
        
        # G5-2a: Fcr1 = 1.60E / √(Lv/D) × (D/t)^(5/4)
        if Lv_D > 0
            Fcr1 = 1.60 * E / (sqrt(Lv_D) * D_t^(5/4))
        else
            Fcr1 = Inf * ksi  # No length means no buckling from this mode
        end
        
        # G5-2b: Fcr2 = 0.78E / (D/t)^(3/2)
        Fcr2 = 0.78 * E / D_t^(3/2)
        
        # Fcr is the larger of Fcr1 and Fcr2, but ≤ 0.6Fy
        Fcr = min(max(Fcr1, Fcr2), Fcr_yield)
    end
    
    # G5-1: Vn = Fcr × Ag / 2
    return Fcr * Ag / 2
end

"""
    get_ϕVn(s::HSSRoundSection, mat::Metal; Lv, axis=:strong, ϕ=nothing) -> Force

Design shear strength ϕVn for round HSS per AISC 360-16 Section G5 (LRFD).
Default `ϕ_v = 0.9` per G1.
"""
get_ϕVn(s::HSSRoundSection, mat::Metal; Lv=nothing, axis=:strong, kv=5.0, rolled=false, ϕ=nothing) =
    (isnothing(ϕ) ? 0.9 : ϕ) * get_Vn(s, mat; Lv=Lv, axis=axis, kv=kv, rolled=rolled)

