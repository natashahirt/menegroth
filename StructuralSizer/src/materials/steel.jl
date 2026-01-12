# ASTM A992 Steel (USA) - using SI units for compatibility
const A992_Steel = Metal(
    200.0u"GPa",        # E  (29000 ksi ≈ 200 GPa)
    77.2u"GPa",         # G  (11500 ksi ≈ 77.2 GPa)
    345.0u"MPa",        # Fy (50 ksi ≈ 345 MPa)
    450.0u"MPa",        # Fu (65 ksi ≈ 450 MPa)
    7850.0u"kg/m^3",    # ρ  (490 lb/ft³ ≈ 7850 kg/m³)
    0.26                # ν
)

# S355 Steel (European)
const S355_Steel = Metal(
    210.0u"GPa",        # E
    80.7u"GPa",         # G
    355.0u"MPa",        # Fy
    510.0u"MPa",        # Fu
    7850.0u"kg/m^3",    # ρ
    0.30                # ν
)