# ECC values from ICE Database v4.1 (Oct 2025) [kgCO₂e/kg]
# Source: data/ICE DB Educational V4.1 - Oct 2025.xlsx
#
# Steel, section: 1.61
# Steel, rebar: 1.72

# ASTM A992 Steel (USA)
const A992_Steel = StructuralSteel(
    200.0u"GPa",        # E  (29000 ksi ≈ 200 GPa)
    77.2u"GPa",         # G  (11500 ksi ≈ 77.2 GPa)
    345.0u"MPa",        # Fy (50 ksi ≈ 345 MPa)
    450.0u"MPa",        # Fu (65 ksi ≈ 450 MPa)
    7850.0u"kg/m^3",    # ρ  (490 lb/ft³ ≈ 7850 kg/m³)
    0.26,               # ν
    1.61                # ecc [kgCO₂e/kg]
)

# S355 Steel (European)
const S355_Steel = StructuralSteel(
    210.0u"GPa",        # E
    80.7u"GPa",         # G
    355.0u"MPa",        # Fy
    510.0u"MPa",        # Fu
    7850.0u"kg/m^3",    # ρ
    0.30,               # ν
    1.61                # ecc [kgCO₂e/kg]
)

# ASTM A615 Rebar Steel Grades (portlandbolt.com)
const Rebar_40 = RebarSteel(200.0u"GPa", 77.2u"GPa", 276.0u"MPa", 414.0u"MPa", 7850.0u"kg/m^3", 0.30, 1.72)  # Fy=40ksi, Fu=60ksi
const Rebar_60 = RebarSteel(200.0u"GPa", 77.2u"GPa", 414.0u"MPa", 620.0u"MPa", 7850.0u"kg/m^3", 0.30, 1.72)  # Fy=60ksi, Fu=90ksi
const Rebar_75 = RebarSteel(200.0u"GPa", 77.2u"GPa", 517.0u"MPa", 689.0u"MPa", 7850.0u"kg/m^3", 0.30, 1.72)  # Fy=75ksi, Fu=100ksi
const Rebar_80 = RebarSteel(200.0u"GPa", 77.2u"GPa", 552.0u"MPa", 724.0u"MPa", 7850.0u"kg/m^3", 0.30, 1.72)  # Fy=80ksi, Fu=105ksi

# ASTM A1044 Headed Shear Stud Steel (for punching shear reinforcement)
# Reference: Ancon Shearfix Design Manual to ACI 318-19
const Stud_51 = RebarSteel(200.0u"GPa", 77.2u"GPa", 351.6u"MPa", 448.2u"MPa", 7850.0u"kg/m^3", 0.30, 1.72)  # Fy=51ksi, Fu=65ksi

# ==============================================================================
# Display Names
# ==============================================================================

"""Get short display name for a steel material."""
function material_name(mat::StructuralSteel)
    mat === A992_Steel && return "A992"
    mat === S355_Steel && return "S355"
    # Fallback: show Fy
    Fy_ksi = round(ustrip(ksi, mat.Fy), digits=0)
    return "Steel (Fy=$(Int(Fy_ksi)) ksi)"
end

function material_name(mat::RebarSteel)
    mat === Rebar_40 && return "Gr40"
    mat === Rebar_60 && return "Gr60"
    mat === Rebar_75 && return "Gr75"
    mat === Rebar_80 && return "Gr80"
    mat === Stud_51 && return "Stud51"
    Fy_ksi = round(ustrip(ksi, mat.Fy), digits=0)
    return "Rebar (Fy=$(Int(Fy_ksi)) ksi)"
end