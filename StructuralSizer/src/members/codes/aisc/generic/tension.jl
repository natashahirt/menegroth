# AISC 360-16 Chapter D — Design of Members for Tension
# Source: corpus aisc-360-16, pp. 87–90.

"""
    get_Pn_tension(s::AbstractSection, mat::Metal; Ae_ratio=0.75) -> Force

Nominal tensile strength per AISC 360-16 §D2 (corpus aisc-360-16, p. 87):

- §D2(a), Eq. D2-1 — yielding on the gross section:   `Pn = Fy · Ag`
- §D2(b), Eq. D2-2 — rupture on the effective net:    `Pn = Fu · Ae`,
  with `Ae = An · U` per §D3.

# `Ae_ratio` (engineering-judgment default)

ENGINEERING JUDGMENT: Member sizing here precedes connection design, so the
actual net area `An` (which depends on bolt-hole pattern) and shear-lag
factor `U` (Table D3.1) are not yet known. We default `Ae/Ag = 0.75`, which
is conservative for typical W-shape connections where `U ≈ 0.85–0.90` and
`An/Ag ≈ 0.85–0.90` give `Ae/Ag ≈ 0.72–0.81`. Members are usually controlled
by yielding in this regime, and rupture is re-checked locally during
connection design with the actual `An` and `U`. **Not an AISC requirement —
this default must be overridden once connection geometry is fixed.**
"""
function get_Pn_tension(s::AbstractSection, mat::Metal; Ae_ratio=0.75)
    # AISC 360-16 §D2(a), Eq. D2-1: tensile yielding on gross section.
    Pn_yield = mat.Fy * section_area(s)

    # AISC 360-16 §D2(b), Eq. D2-2: tensile rupture on effective net section.
    # See ENGINEERING JUDGMENT note above for the Ae_ratio default.
    Pn_rupture = mat.Fu * (section_area(s) * Ae_ratio)

    return min(Pn_yield, Pn_rupture)
end

"""
    get_ϕPn_tension(s::AbstractSection, mat::Metal; Ae_ratio=0.75) -> Force

Design tensile strength per AISC 360-16 §D2 (LRFD; corpus aisc-360-16, p. 87):

- `ϕ_t = 0.90` for tensile yielding (§D2(a))
- `ϕ_t = 0.75` for tensile rupture  (§D2(b))

See [`get_Pn_tension`](@ref) for the `Ae_ratio` engineering-judgment default.
"""
function get_ϕPn_tension(s::AbstractSection, mat::Metal; Ae_ratio=0.75)
    # AISC 360-16 §D2(a): ϕ_t = 0.90 for yielding.
    ϕPn_yield = 0.90 * (mat.Fy * section_area(s))

    # AISC 360-16 §D2(b): ϕ_t = 0.75 for rupture.
    ϕPn_rupture = 0.75 * (mat.Fu * (section_area(s) * Ae_ratio))

    return min(ϕPn_yield, ϕPn_rupture)
end
