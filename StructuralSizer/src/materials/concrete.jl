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

"""
    _aci_Ec(fc′) -> Unitful.Pressure

Compute elastic modulus per ACI 318-11 §8.5.1: Ec = 57000√f'c [psi].
"""
_aci_Ec(fc′) = 57000 * sqrt(ustrip(u"psi", fc′)) * u"psi"

# ==============================================================================
# Standard OPC Concrete (by compressive strength in psi)
# ==============================================================================

"""Normal-weight concrete, f'c = 3000 psi, OPC (ECC = 0.130 kgCO₂e/kg)."""
const NWC_3000 = let fc = 3000u"psi"
    Concrete(_aci_Ec(fc), fc, 2380.0u"kg/m^3", 0.20, 0.130; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 4000 psi, OPC (ECC = 0.138 kgCO₂e/kg)."""
const NWC_4000 = let fc = 4000u"psi"
    Concrete(_aci_Ec(fc), fc, 2380.0u"kg/m^3", 0.20, 0.138; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 5000 psi, OPC (ECC = 0.155 kgCO₂e/kg)."""
const NWC_5000 = let fc = 5000u"psi"
    Concrete(_aci_Ec(fc), fc, 2385.0u"kg/m^3", 0.20, 0.155; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 6000 psi, OPC (ECC = 0.173 kgCO₂e/kg)."""
const NWC_6000 = let fc = 6000u"psi"
    Concrete(_aci_Ec(fc), fc, 2385.0u"kg/m^3", 0.20, 0.173; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 4000 psi, 50% GGBS replacement (ECC = 0.099 kgCO₂e/kg)."""
const NWC_GGBS = let fc = 4000u"psi"
    Concrete(_aci_Ec(fc), fc, 2380.0u"kg/m^3", 0.20, 0.099; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 4000 psi, 30% PFA replacement (ECC = 0.112 kgCO₂e/kg)."""
const NWC_PFA = let fc = 4000u"psi"
    Concrete(_aci_Ec(fc), fc, 2380.0u"kg/m^3", 0.20, 0.112; color = "#C8C8C8")
end

# ==============================================================================
# Structural Lightweight Concrete (LWC)
# ==============================================================================
# λ (lightweight modifier): ACI 318-19 Table 19.2.4.2 (= ACI 318-11 §8.6.1)
#   Sand-lightweight = 0.85, All-lightweight = 0.75 (Normalweight = 1.00).
#   λ multiplies √f'c in shear / punching / bond / development.
# Density bounds: ACI 318-19 §R19.2.4.1 — structural LWC equilibrium density
#   range 1440–1840 kg/m³ (90–115 pcf). Sand-LWC sits near the upper bound;
#   all-LWC is mid-range.
# ECC (interim — flagged for replacement in dedicated ECC integration pass):
#   NRMCA Industry-Wide EPD v3.2 (valid through 2026-03-31), Table 13a
#   "3001-4000 psi Lightweight, per cubic meter", baseline mix LW-4000-00-FA/SL
#   (no SCM): GWP A1–A3 = 642.49 kgCO₂e/m³.
#     Sand-LWC at 1840 kg/m³: 642.49 / 1840 ≈ 0.349 kgCO₂e/kg
#     All-LWC  at 1680 kg/m³: 642.49 / 1680 ≈ 0.382 kgCO₂e/kg
#   Note: the NRMCA EPD assumes manufactured (kiln-fired) lightweight aggregate
#   substituting only the coarse fraction — strictly a sand-LWC mix. The
#   all-LWC ECC here is an extrapolation pending an all-LWC-specific EPD.

"""Sand-lightweight concrete, f'c = 4000 psi (ECC = 0.349 kgCO₂e/kg, λ = 0.85, ρ = 1840 kg/m³)."""
const LWC_4000 = let fc = 4000u"psi"
    Concrete(_aci_Ec(fc), fc, 1840.0u"kg/m^3", 0.20, 0.349;
             λ = 0.85, aggregate_type = sand_lightweight, color = "#D8D8D8")
end

"""All-lightweight concrete, f'c = 4000 psi (ECC = 0.382 kgCO₂e/kg, λ = 0.75, ρ = 1680 kg/m³)."""
const LWC_4000_AL = let fc = 4000u"psi"
    Concrete(_aci_Ec(fc), fc, 1680.0u"kg/m^3", 0.20, 0.382;
             λ = 0.75, aggregate_type = lightweight, color = "#E0E0E0")
end

# ==============================================================================
# Reinforced Concrete Material Presets
# ==============================================================================
# Common combinations of concrete + rebar grades.
# Uses RebarSteel presets from steel.jl (Rebar_60, Rebar_75, etc.)

"""Reinforced concrete: 3000 psi + Grade 60 rebar."""
const RC_3000_60 = ReinforcedConcreteMaterial(NWC_3000, Rebar_60)

"""Reinforced concrete: 4000 psi + Grade 60 rebar."""
const RC_4000_60 = ReinforcedConcreteMaterial(NWC_4000, Rebar_60)

"""Reinforced concrete: 5000 psi + Grade 60 rebar."""
const RC_5000_60 = ReinforcedConcreteMaterial(NWC_5000, Rebar_60)

"""Reinforced concrete: 6000 psi + Grade 60 rebar."""
const RC_6000_60 = ReinforcedConcreteMaterial(NWC_6000, Rebar_60)

"""Reinforced concrete: 5000 psi + Grade 75 rebar."""
const RC_5000_75 = ReinforcedConcreteMaterial(NWC_5000, Rebar_75)

"""Reinforced concrete: 6000 psi + Grade 75 rebar."""
const RC_6000_75 = ReinforcedConcreteMaterial(NWC_6000, Rebar_75)

"""Reinforced concrete: GGBS 4000 psi + Grade 60 rebar (low-carbon)."""
const RC_GGBS_60 = ReinforcedConcreteMaterial(NWC_GGBS, Rebar_60)

"""Reinforced concrete: sand-lightweight 4000 psi + Grade 60 rebar (LWC, λ = 0.85)."""
const RC_LWC_4000_60 = ReinforcedConcreteMaterial(LWC_4000, Rebar_60)

"""Reinforced concrete: all-lightweight 4000 psi + Grade 60 rebar (LWC, λ = 0.75)."""
const RC_LWC_4000_AL_60 = ReinforcedConcreteMaterial(LWC_4000_AL, Rebar_60)

# ==============================================================================
# Earthen / Masonry Materials (for unreinforced vaults)
# ==============================================================================
# From BasePlotsWithLim.m reference: Density = 2000 kg/m³, MOE = 500-8000 MPa
# Named by E [MPa] since that's the key variable for vault analysis.
# fc' estimated as E/1000 (typical for earthen materials).
# ECC values are approximate - earthen materials have very low embodied carbon.

"""Earthen material, E = 500 MPa (unfired earth, very low ECC)."""
const Earthen_500 = Concrete(
    0.5u"GPa",          # E = 500 MPa
    0.5u"MPa",          # fc' (conservative estimate)
    2000.0u"kg/m^3",    # ρ (from Matlab reference)
    0.20,               # ν
    0.01;               # ecc [kgCO₂e/kg] - very low for unfired earth
    εcu = 0.002,
    color = "#B8926A"
)

"""Earthen material, E = 1000 MPa."""
const Earthen_1000 = Concrete(
    1.0u"GPa",          # E = 1000 MPa
    1.0u"MPa",          # fc'
    2000.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.01;               # ecc
    εcu = 0.002,
    color = "#B8926A"
)

"""Earthen material, E = 2000 MPa (stabilized earth)."""
const Earthen_2000 = Concrete(
    2.0u"GPa",          # E = 2000 MPa
    2.0u"MPa",          # fc'
    2000.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.02;               # ecc - slightly higher for stabilized earth
    εcu = 0.002,
    color = "#A97C50"
)

"""Earthen material, E = 4000 MPa (compressed earth blocks)."""
const Earthen_4000 = Concrete(
    4.0u"GPa",          # E = 4000 MPa
    4.0u"MPa",          # fc'
    2000.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.05;               # ecc - compressed earth blocks
    εcu = 0.002,
    color = "#9A6B43"
)

"""Earthen material, E = 8000 MPa (fired clay brick)."""
const Earthen_8000 = Concrete(
    8.0u"GPa",          # E = 8000 MPa
    8.0u"MPa",          # fc'
    2000.0u"kg/m^3",    # ρ
    0.20,               # ν
    0.10;               # ecc - fired clay brick
    εcu = 0.002,
    color = "#8A5B34"
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
register_material!(LWC_4000, "LWC_4000")
register_material!(LWC_4000_AL, "LWC_4000_AL")
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
register_material!(RC_LWC_4000_60, "RC_LWC_4000_60")
register_material!(RC_LWC_4000_AL_60, "RC_LWC_4000_AL_60")

"""_fallback_material_name for unregistered `Concrete`: formats as "Concrete (XXXX psi)"."""
function _fallback_material_name(mat::Concrete)
    fc_psi = round(Int, ustrip(psi, mat.fc′))
    "Concrete ($(fc_psi) psi)"
end

"""_fallback_material_name for unregistered `ReinforcedConcreteMaterial`: formats as "Concrete + GrXX"."""
function _fallback_material_name(mat::ReinforcedConcreteMaterial)
    conc = material_name(mat.concrete)
    fy = round(Int, ustrip(ksi, mat.rebar.Fy))
    "$(conc) + Gr$(fy)"
end
