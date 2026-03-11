# ==============================================================================
# AISC 360-16 - Compression for Round HSS / Pipe (Section E3 + E7 effective area)
# ==============================================================================

"""
Effective area Ae for round HSS per AISC 360-16 Section E7.2 (E7-6 / E7-7).

We implement the common form:
- If D/t ≤ 0.11(E/Fy): Ae = Ag
- Else: Ae = Ag * (2/3 + 0.038(E/Fy)/(D/t)), capped to [0, Ag]

Note: This matches the structure shown in the spec extract and provides a reasonable
transition from compact to slender behavior.
"""
function _Ae_round_hss(s::HSSRoundSection, mat::Metal)
    E, Fy = mat.E, mat.Fy
    Dt = s.D_t
    limit = 0.11 * (E / Fy)
    if Dt <= limit
        return s.A
    end
    Ae = s.A * (2/3 + (0.038 * (E / Fy)) / Dt)
    return clamp(Ae, zero(Ae), s.A)
end

"""
    get_Pn(s::HSSRoundSection, mat::Metal, L; axis=:weak) -> Force

Nominal compressive strength for round HSS per AISC 360-16 Chapters E3/E7.
Considers Euler buckling and effective area for slender walls.
"""
function get_Pn(s::HSSRoundSection, mat::Metal, L; axis=:weak)
    E, Fy = mat.E, mat.Fy
    Fe = _Fe_euler(E, L, s.r)
    Fcr = _Fcr_column(Fe, Fy)
    Ae = _Ae_round_hss(s, mat)
    return Fcr * Ae
end

"""
    get_ϕPn(s::HSSRoundSection, mat::Metal, L; axis=:weak, ϕ=0.9) -> Force

Design compressive strength ϕPn for round HSS per AISC 360-16 (LRFD).
Torsional buckling maps to weak-axis for round HSS.
"""
function get_ϕPn(s::HSSRoundSection, mat::Metal, L; axis=:weak, ϕ=0.9)
    axis_eff = axis === :torsional ? :weak : axis
    return ϕ * get_Pn(s, mat, L; axis=axis_eff)
end

