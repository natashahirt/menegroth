# AISC 360 Chapter D - Design of Members for Tension

"""
    get_Pn_tension(s::AbstractSection, mat::Metal; Ae_ratio=0.75) -> Force

Nominal tensile strength per AISC 360-16 Section D2, considering:
- D2-1: Tensile yielding on gross section (Pn = Fy × Ag)
- D2-2: Tensile rupture on effective net section (Pn = Fu × Ae)

`Ae_ratio` is a conservative placeholder for Ae/Ag (default 0.75).
"""
function get_Pn_tension(s::AbstractSection, mat::Metal; Ae_ratio=0.75)
    # D2-1: Tensile Yielding
    # Pn = Fy * Ag
    Pn_yield = mat.Fy * section_area(s)

    # D2-2: Tensile Rupture
    # Pn = Fu * Ae
    # Ae = An * U
    # Without connection details, we assume an effective net area ratio.
    # U typically 0.8-0.9 for W-shapes. An depends on bolt holes.
    # 0.75 is a conservative placeholder for Ae/Ag.
    # Note: Optimization of members usually controlled by gross yielding.
    # Connection design handles rupture locally.
    Pn_rupture = mat.Fu * (section_area(s) * Ae_ratio)

    return min(Pn_yield, Pn_rupture)
end

"""
    get_ϕPn_tension(s::AbstractSection, mat::Metal; Ae_ratio=0.75) -> Force

Design tensile strength per AISC 360-16 (LRFD).
ϕ_t = 0.90 for yielding (D2-1), ϕ_t = 0.75 for rupture (D2-2).
"""
function get_ϕPn_tension(s::AbstractSection, mat::Metal; Ae_ratio=0.75)
    # ϕ = 0.90 for yielding
    ϕ_yield = 0.90
    ϕPn_yield = ϕ_yield * (mat.Fy * section_area(s))

    # ϕ = 0.75 for rupture
    ϕ_rupture = 0.75
    ϕPn_rupture = ϕ_rupture * (mat.Fu * (section_area(s) * Ae_ratio))

    return min(ϕPn_yield, ϕPn_rupture)
end
