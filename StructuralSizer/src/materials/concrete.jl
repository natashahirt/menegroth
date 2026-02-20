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
# εcu = 0.003 is the standard ACI 318-11 value for normal concrete.

"""ACI 318-11 §8.5.1: Ec = 57000√f'c psi (normal weight concrete)."""
_aci_Ec(fc′) = 57000 * sqrt(ustrip(u"psi", fc′)) * u"psi"

# ==============================================================================
# Standard OPC Concrete (by compressive strength in psi)
# ==============================================================================

const NWC_3000 = let fc = 3000u"psi"
    Concrete(_aci_Ec(fc), fc, 2380.0u"kg/m^3", 0.20, 0.130)
end

const NWC_4000 = let fc = 4000u"psi"
    Concrete(_aci_Ec(fc), fc, 2380.0u"kg/m^3", 0.20, 0.138)
end

const NWC_5000 = let fc = 5000u"psi"
    Concrete(_aci_Ec(fc), fc, 2385.0u"kg/m^3", 0.20, 0.155)
end

const NWC_6000 = let fc = 6000u"psi"
    Concrete(_aci_Ec(fc), fc, 2385.0u"kg/m^3", 0.20, 0.173)
end

const NWC_GGBS = let fc = 4000u"psi"
    Concrete(_aci_Ec(fc), fc, 2380.0u"kg/m^3", 0.20, 0.099)
end

const NWC_PFA = let fc = 4000u"psi"
    Concrete(_aci_Ec(fc), fc, 2380.0u"kg/m^3", 0.20, 0.112)
end

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
# Registry
# ==============================================================================

register_material!(NWC_3000, "NWC_3000")
register_material!(NWC_4000, "NWC_4000")
register_material!(NWC_5000, "NWC_5000")
register_material!(NWC_6000, "NWC_6000")
register_material!(NWC_GGBS, "NWC_GGBS")
register_material!(NWC_PFA, "NWC_PFA")
register_material!(Earthen_500, "Earthen_500")
register_material!(Earthen_1000, "Earthen_1000")
register_material!(Earthen_2000, "Earthen_2000")
register_material!(Earthen_4000, "Earthen_4000")
register_material!(Earthen_8000, "Earthen_8000")
register_material!(RC_3000_60, "RC_3000_60")
register_material!(RC_4000_60, "RC_4000_60")
register_material!(RC_5000_60, "RC_5000_60")
register_material!(RC_6000_60, "RC_6000_60")
register_material!(RC_5000_75, "RC_5000_75")
register_material!(RC_6000_75, "RC_6000_75")
register_material!(RC_GGBS_60, "RC_GGBS_60")

# Fallback display names for unregistered materials
function _fallback_material_name(mat::Concrete)
    fc_psi = round(Int, ustrip(psi, mat.fc′))
    "Concrete ($(fc_psi) psi)"
end

function _fallback_material_name(mat::ReinforcedConcreteMaterial)
    conc = material_name(mat.concrete)
    fy = round(Int, ustrip(ksi, mat.rebar.Fy))
    "$(conc) + Gr$(fy)"
end
