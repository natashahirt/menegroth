# ==============================================================================
# AISC 360-16 - Flexure for Round HSS / Pipe (Section F8)
# ==============================================================================

"""
    get_Mn(s::HSSRoundSection, mat::Metal; Lb, Cb=1.0, axis=:strong) -> Moment

Nominal flexural strength for round HSS per AISC 360-16 Section F8.
Considers compact (F8-1), noncompact (F8-2), and slender (F8-3) limit states
based on D/t slenderness.
"""
function get_Mn(s::HSSRoundSection, mat::Metal; Lb=zero(s.OD), Cb=1.0, axis=:strong)
    E, Fy = mat.E, mat.Fy
    Mp = Fy * s.Z
    My = Fy * s.S

    sl = get_slenderness(s, mat)
    if sl.class == :compact
        return Mp
    elseif sl.class == :noncompact
        Mn = _linear_interp(sl.λ, sl.λp, sl.λr, Mp, My)
        return min(Mn, Mp)
    else
        # Slender: Mn = Fcr*S (F8-3). Conservative local-buckling stress model:
        Fcr = min(0.33 * E / sl.λ, Fy)
        return Fcr * s.S
    end
end

"""
    get_ϕMn(s::HSSRoundSection, mat::Metal; Lb, Cb=1.0, axis=:strong, ϕ=0.9) -> Moment

Design flexural strength ϕMn for round HSS per AISC 360-16 (LRFD).
"""
get_ϕMn(s::HSSRoundSection, mat::Metal; Lb=zero(s.OD), Cb=1.0, axis=:strong, ϕ=0.9) =
    ϕ * get_Mn(s, mat; Lb=Lb, Cb=Cb, axis=axis)

