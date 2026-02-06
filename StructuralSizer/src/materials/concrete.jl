# ==============================================================================
# Concrete Material Presets
# ==============================================================================
# ECC values from ICE Database v4.1 (Oct 2025) [kgCO₂e/kg]
# Source: data/ICE DB Educational V4.1 - Oct 2025.xlsx
#
# ICE Concrete ECC (per kg):
#   OPC (300 kg cement/m³): 0.138
#   50% GGBS replacement:   0.099
#   30% PFA replacement:    0.112
#   40/50 MPa (UK avg):     0.173
#
# εcu = 0.003 is the standard ACI 318-19 value for normal concrete.

# ==============================================================================
# Standard OPC Concrete (by compressive strength in psi)
# ==============================================================================

# 3000 psi (~20 MPa) - lower strength for non-critical applications
const NWC_3000 = Concrete(
    26.0u"GPa",         # E (57000√3000 psi ≈ 26 GPa)
    20.7u"MPa",         # fc′ (3000 psi ≈ 21 MPa)
    2380.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.130;              # ecc - slightly lower cement content
    εcu = 0.003         # ACI ultimate strain
)

# 4000 psi (~28 MPa) - standard for columns and beams
const NWC_4000 = Concrete(
    29.0u"GPa",         # E (57000√4000 psi ≈ 29 GPa)
    27.6u"MPa",         # fc′ (4000 psi ≈ 28 MPa)
    2380.0u"kg/m^3",    # ρ  (from ICE)
    0.20,               # ν
    0.138;              # ecc [kgCO₂e/kg] - ICE: OPC 300kg cement/m³
    εcu = 0.003
)

# 5000 psi (~35 MPa) - higher strength for columns
const NWC_5000 = Concrete(
    32.0u"GPa",         # E (57000√5000 psi ≈ 32 GPa)
    34.5u"MPa",         # fc′ (5000 psi ≈ 34.5 MPa)
    2385.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.155;              # ecc - moderate
    εcu = 0.003
)

# 6000 psi (~41 MPa) - high strength for columns
const NWC_6000 = Concrete(
    35.0u"GPa",         # E (57000√6000 psi ≈ 35 GPa)
    41.4u"MPa",         # fc′ (6000 psi ≈ 41 MPa)
    2385.0u"kg/m^3",    # ρ  (from ICE)
    0.20,               # ν
    0.173;              # ecc [kgCO₂e/kg] - ICE: 40/50 MPa
    εcu = 0.003
)

# Low-carbon: 50% GGBS cement replacement
const NWC_GGBS = Concrete(
    29.0u"GPa",         # E
    27.6u"MPa",         # fc′ (~28 MPa typical)
    2380.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.099;              # ecc [kgCO₂e/kg] - ICE: 50% GGBS
    εcu = 0.003
)

# Low-carbon: 30% PFA cement replacement
const NWC_PFA = Concrete(
    29.0u"GPa",         # E
    27.6u"MPa",         # fc′ (~28 MPa typical)
    2380.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.112;              # ecc [kgCO₂e/kg] - ICE: 30% PFA
    εcu = 0.003
)

# ==============================================================================
# Reinforced Concrete Material Presets
# ==============================================================================
# Common combinations of concrete + rebar grades.
# Uses RebarSteel presets from steel.jl (Rebar_60, Rebar_75, etc.)

# Standard: 3000 psi concrete + Grade 60 rebar
const RC_3000_60 = ReinforcedConcreteMaterial(NWC_3000, Rebar_60)

# Standard: 4000 psi concrete + Grade 60 rebar
const RC_4000_60 = ReinforcedConcreteMaterial(NWC_4000, Rebar_60)

# Standard: 5000 psi concrete + Grade 60 rebar
const RC_5000_60 = ReinforcedConcreteMaterial(NWC_5000, Rebar_60)

# High-strength: 6000 psi concrete + Grade 60 rebar
const RC_6000_60 = ReinforcedConcreteMaterial(NWC_6000, Rebar_60)

# High-strength: 5000 psi concrete + Grade 75 rebar
const RC_5000_75 = ReinforcedConcreteMaterial(NWC_5000, Rebar_75)

# High-strength: 6000 psi concrete + Grade 75 rebar
const RC_6000_75 = ReinforcedConcreteMaterial(NWC_6000, Rebar_75)

# Low-carbon: GGBS concrete + Grade 60 rebar
const RC_GGBS_60 = ReinforcedConcreteMaterial(NWC_GGBS, Rebar_60)

# ==============================================================================
# Earthen / Masonry Materials (for unreinforced vaults)
# ==============================================================================
# From BasePlotsWithLim.m reference: Density = 2000 kg/m³, MOE = 500-8000 MPa
# Named by E [MPa] since that's the key variable for vault analysis.
# fc' estimated as E/1000 (typical for earthen materials).
# ECC values are approximate - earthen materials have very low embodied carbon.

const Earthen_500 = Concrete(
    0.5u"GPa",          # E = 500 MPa
    0.5u"MPa",          # fc' (conservative estimate)
    2000.0u"kg/m^3",    # ρ (from Matlab reference)
    0.20,               # ν
    0.01;               # ecc [kgCO₂e/kg] - very low for unfired earth
    εcu = 0.002
)

const Earthen_1000 = Concrete(
    1.0u"GPa",          # E = 1000 MPa
    1.0u"MPa",          # fc'
    2000.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.01;               # ecc
    εcu = 0.002
)

const Earthen_2000 = Concrete(
    2.0u"GPa",          # E = 2000 MPa
    2.0u"MPa",          # fc'
    2000.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.02;               # ecc - slightly higher for stabilized earth
    εcu = 0.002
)

const Earthen_4000 = Concrete(
    4.0u"GPa",          # E = 4000 MPa
    4.0u"MPa",          # fc'
    2000.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.05;               # ecc - compressed earth blocks
    εcu = 0.002
)

const Earthen_8000 = Concrete(
    8.0u"GPa",          # E = 8000 MPa
    8.0u"MPa",          # fc'
    2000.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.10;               # ecc - fired clay brick
    εcu = 0.002
)

# ==============================================================================
# Display Names
# ==============================================================================

"""Get short display name for a concrete material."""
function material_name(mat::Concrete)
    # Standard concrete
    mat === NWC_3000 && return "NWC_3000"
    mat === NWC_4000 && return "NWC_4000"
    mat === NWC_5000 && return "NWC_5000"
    mat === NWC_6000 && return "NWC_6000"
    mat === NWC_GGBS && return "NWC_GGBS"
    mat === NWC_PFA && return "NWC_PFA"
    # Earthen materials
    mat === Earthen_500 && return "Earthen_500"
    mat === Earthen_1000 && return "Earthen_1000"
    mat === Earthen_2000 && return "Earthen_2000"
    mat === Earthen_4000 && return "Earthen_4000"
    mat === Earthen_8000 && return "Earthen_8000"
    # Fallback: show fc' in psi
    fc_psi = round(ustrip(psi, mat.fc′), digits=0)
    return "Concrete ($(Int(fc_psi)) psi)"
end

"""Get short display name for a reinforced concrete material."""
function material_name(mat::ReinforcedConcreteMaterial)
    mat === RC_3000_60 && return "RC_3000_60"
    mat === RC_4000_60 && return "RC_4000_60"
    mat === RC_5000_60 && return "RC_5000_60"
    mat === RC_6000_60 && return "RC_6000_60"
    mat === RC_5000_75 && return "RC_5000_75"
    mat === RC_6000_75 && return "RC_6000_75"
    mat === RC_GGBS_60 && return "RC_GGBS_60"
    # Fallback: use ksi unit from Asap
    conc_name = material_name(mat.concrete)
    fy_ksi_val = round(Int, ustrip(ksi, mat.rebar.Fy))
    return "$(conc_name) + Gr$(fy_ksi_val)"
end
