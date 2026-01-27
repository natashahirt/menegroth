# ECC values from ICE Database v4.1 (Oct 2025) [kgCO₂e/kg]
# Source: data/ICE DB Educational V4.1 - Oct 2025.xlsx
#
# ICE Concrete ECC (per kg):
#   OPC (300 kg cement/m³): 0.138
#   50% GGBS replacement:   0.099
#   30% PFA replacement:    0.112
#   40/50 MPa (UK avg):     0.173

# Standard OPC concrete (~20-30 MPa)
const NWC_4000 = Concrete(
    29.0u"GPa",         # E
    27.6u"MPa",         # fc′ (4000 psi ≈ 28 MPa)
    2380.0u"kg/m^3",    # ρ  (from ICE)
    0.20,               # ν
    0.138               # ecc [kgCO₂e/kg] - ICE: OPC 300kg cement/m³
)

# Higher strength concrete (~40-50 MPa)
const NWC_6000 = Concrete(
    35.0u"GPa",         # E
    41.4u"MPa",         # fc′ (6000 psi ≈ 41 MPa)
    2385.0u"kg/m^3",    # ρ  (from ICE)
    0.20,               # ν
    0.173               # ecc [kgCO₂e/kg] - ICE: 40/50 MPa
)

# Low-carbon: 50% GGBS cement replacement
const NWC_GGBS = Concrete(
    29.0u"GPa",         # E
    27.6u"MPa",         # fc′ (~28 MPa typical)
    2380.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.099               # ecc [kgCO₂e/kg] - ICE: 50% GGBS
)

# Low-carbon: 30% PFA cement replacement
const NWC_PFA = Concrete(
    29.0u"GPa",         # E
    27.6u"MPa",         # fc′ (~28 MPa typical)
    2380.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.112               # ecc [kgCO₂e/kg] - ICE: 30% PFA
)
