# ==============================================================================
# Concrete Material Presets
# ==============================================================================
# ECC values are anchored to the empirical median of the NRMCA / RMC
# ready-mix EPD dataset (n = 1078 individual plant-mix EPDs, 2021–2025,
# A1–A3 cradle-to-gate, US plants only). See:
#
#   StructuralSizer/src/materials/ecc/data/rmc_epd_2021_2025.csv
#   StructuralSizer/src/materials/ecc/data/README.md
#   StructuralSizer/src/materials/ecc/distributions.jl
#
# Per-strength medians (kg CO₂e / m³ → divide by ρ for kg/kg below):
#
#   class       n      p50      ECC = p50 / ρ
#   ──────────  ────  ──────   ────────────────
#   NWC 3 ksi   159    264     0.111  (ρ = 2380 kg/m³)
#   NWC 4 ksi   263    301     0.127
#   NWC 5 ksi   156    338     0.142  (ρ = 2385 kg/m³)
#   NWC 6 ksi    53    309     0.130  *
#   LWC 4 ksi   447    448     0.243  (sand-LWC, ρ = 1840 kg/m³)
#
# (*) The 6 ksi median sits *below* the 5 ksi median because high-strength
#     mixes in the dataset are heavily SCM-blended (PLC penetration is
#     ~65–68 % at 5–6 ksi vs ~35 % at 3–4 ksi). Quote with caution at
#     n = 53 — the 5 ksi value is the safer default for high-strength
#     central-tendency estimates.
#
# Cross-check (footnote, not primary source):
#     ICE Database v4.1 (Oct 2025), UK procurement averages —
#     OPC: 0.138 / 0.155 / 0.173 ; GGBS 50 %: 0.099 ; PFA 30 %: 0.112.
#     These sit at the ~70th–85th percentile of the US distribution and
#     are kept for regional comparison; do not use as the primary value.
#
# εcu = 0.003 is the standard ACI 318-11 value for normal concrete.

"""
    _aci_Ec(fc′, ρ) -> Unitful.Pressure

Elastic modulus per **ACI 318-11 §8.5.1** (corpus: aci-318-11, page 115;
also ACI 318-19 §19.2.2.1.a):

```
    Ec = wc^1.5 × 33 √f'c     (psi)
```

valid for `wc ∈ [90, 160] lb/ft³` — covers structural lightweight through
normalweight. The simplified normalweight form `Ec = 57,000 √f'c` (which
implicitly assumes `wc ≈ 145 pcf`) is intentionally *not* exposed: it
overstates Ec by ~30 % for sand-LWC and ~38 % for all-LWC, and is only
~5 % off for typical NWC, so we use the general form everywhere for
consistency.
"""
function _aci_Ec(fc′, ρ::Unitful.Density)
    wc_pcf = ustrip(u"lb/ft^3", ρ)
    @assert 90.0 ≤ wc_pcf ≤ 160.0 "ACI 318-11 §8.5.1: wc must be in [90, 160] pcf, got $wc_pcf"
    return wc_pcf^1.5 * 33.0 * sqrt(ustrip(u"psi", fc′)) * u"psi"
end

# ==============================================================================
# Standard OPC Concrete (by compressive strength in psi)
# ==============================================================================

# NWC density 2380–2385 kg/m³ ≈ 148.6–148.9 pcf — within ACI 318-11 §8.5.1
# normalweight range. Using the density-aware Ec form (vs the simplified
# 57000√f'c) gives a ~5 % bump and matches what the rest of ACI uses.

"""Normal-weight concrete, f'c = 3000 psi (ECC = 0.111 kgCO₂e/kg, RMC EPD median, n = 159)."""
const NWC_3000 = let fc = 3000u"psi", ρ = 2380.0u"kg/m^3"
    Concrete(_aci_Ec(fc, ρ), fc, ρ, 0.20, 0.111; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 4000 psi (ECC = 0.127 kgCO₂e/kg, RMC EPD median, n = 263)."""
const NWC_4000 = let fc = 4000u"psi", ρ = 2380.0u"kg/m^3"
    Concrete(_aci_Ec(fc, ρ), fc, ρ, 0.20, 0.127; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 5000 psi (ECC = 0.142 kgCO₂e/kg, RMC EPD median, n = 156)."""
const NWC_5000 = let fc = 5000u"psi", ρ = 2385.0u"kg/m^3"
    Concrete(_aci_Ec(fc, ρ), fc, ρ, 0.20, 0.142; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 6000 psi (ECC = 0.130 kgCO₂e/kg, RMC EPD median, n = 53)."""
const NWC_6000 = let fc = 6000u"psi", ρ = 2385.0u"kg/m^3"
    Concrete(_aci_Ec(fc, ρ), fc, ρ, 0.20, 0.130; color = "#C8C8C8")
end

# NWC_GGBS / NWC_PFA: empirical sub-bucket medians from the same
# RMC EPD dataset, restricted to mixes that contain slag cement (ASTM
# C989) or fly ash (ASTM C618) respectively. These are *presence*
# medians — not fixed-replacement-rate medians — so the dosage in any
# real mix may differ. ICE DB v4.1 reports tighter values (0.099 for
# 50 % GGBS, 0.112 for 30 % PFA) which match a fixed UK replacement
# rate; they sit near the p10–p25 of the US distribution and are kept
# in the cross-check footer below as an "aggressive low-carbon mix"
# reference rather than the primary value.

"""Normal-weight concrete, f'c = 4000 psi, slag-blended (ECC = 0.131 kgCO₂e/kg, RMC EPD slag-only p50, n = 60)."""
const NWC_GGBS = let fc = 4000u"psi", ρ = 2380.0u"kg/m^3"
    Concrete(_aci_Ec(fc, ρ), fc, ρ, 0.20, 0.131; color = "#C8C8C8")
end

"""Normal-weight concrete, f'c = 4000 psi, fly-ash-blended (ECC = 0.121 kgCO₂e/kg, RMC EPD fa-only p50, n = 121)."""
const NWC_PFA = let fc = 4000u"psi", ρ = 2380.0u"kg/m^3"
    Concrete(_aci_Ec(fc, ρ), fc, ρ, 0.20, 0.121; color = "#C8C8C8")
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
# Ec: ACI 318-11 §8.5.1 (corpus: aci-318-11, page 115) — for any concrete with
#   wc ∈ [90, 160] pcf, Ec = wc^1.5 × 33√f'c (psi). The simplified
#   normalweight form 57,000√f'c overstates Ec by ~29 % for sand-LWC and
#   ~38 % for all-LWC, so the density-aware overload `_aci_Ec(fc, ρ)` must
#   be used here.
# ECC: anchored to the RMC EPD dataset (`rmc_epd_2021_2025.csv`), LWC
# 4 ksi bucket, n = 447, A1–A3 cradle-to-gate. Per-strength p50 = 448
# kg CO₂e/m³.
#   Sand-LWC at 1840 kg/m³: 448 / 1840 ≈ 0.243 kgCO₂e/kg
#   All-LWC  at 1680 kg/m³: 448 / 1680 ≈ 0.267 kgCO₂e/kg  (extrapolated)
#
# Cross-check: NRMCA Industry-Wide EPD v3.2, Table 13a baseline
# `LW-4000-00-FA/SL` reports 642.49 kg CO₂e/m³, which corresponds to
# 0.349 / 0.382 kgCO₂e/kg at the same densities. That value sits at the
# ~96th percentile of the empirical distribution — it is a conservative
# envelope, not a representative central value. The all-LWC entry remains
# an extrapolation pending an all-LWC-specific EPD.

"""Sand-lightweight concrete, f'c = 4000 psi (ECC = 0.243 kgCO₂e/kg, λ = 0.85, ρ = 1840 kg/m³, Ec ≈ 2,567 ksi)."""
const LWC_4000 = let fc = 4000u"psi", ρ = 1840.0u"kg/m^3"
    Concrete(_aci_Ec(fc, ρ), fc, ρ, 0.20, 0.243;
             λ = 0.85, aggregate_type = sand_lightweight, color = "#D8D8D8")
end

"""All-lightweight concrete, f'c = 4000 psi (ECC = 0.267 kgCO₂e/kg, λ = 0.75, ρ = 1680 kg/m³, Ec ≈ 2,239 ksi)."""
const LWC_4000_AL = let fc = 4000u"psi", ρ = 1680.0u"kg/m^3"
    Concrete(_aci_Ec(fc, ρ), fc, ρ, 0.20, 0.267;
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
