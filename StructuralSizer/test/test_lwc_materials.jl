# =============================================================================
# Test: Lightweight Concrete (LWC) Material Presets
# =============================================================================
#
# Verifies that LWC_4000 (sand-lightweight) and LWC_4000_AL (all-lightweight)
# have grounded values per:
#   - ACI 318-19 Table 19.2.4.2 (= ACI 318-11 §8.6.1) — λ values
#   - ACI 318-19 §R19.2.4.1                          — density bounds (1440–1840 kg/m³)
#   - RMC EPD dataset (see materials/ecc/data/rmc_epd_2021_2025.csv)
#       — primary ECC source: LWC 4 ksi p50 = 448 kgCO₂e/m³ (n = 447,
#       A1–A3, US plants 2021–2025). Divide by ρ for kg/kg.
#   - NRMCA Industry-Wide EPD v3.2 Table 13a (LW-4000-00-FA/SL)
#       — kept as a conservative envelope cross-check (~p96 of the
#       above distribution); not the primary value.
#
# Run standalone:  julia --project=StructuralSizer test/test_lwc_materials.jl
# =============================================================================

using Test
using StructuralSizer
using Unitful

@testset "LWC Material Presets" begin

    # =========================================================================
    # Sand-lightweight (LWC_4000)
    # =========================================================================
    @testset "LWC_4000 (sand-lightweight)" begin
        c = LWC_4000

        # ── ACI 318-19 Table 19.2.4.2: λ = 0.85 for sand-LWC ─────────────
        @test c.λ ≈ 0.85
        @test c.aggregate_type == sand_lightweight

        # ── ACI 318-19 §R19.2.4.1: ρ within 1440–1840 kg/m³ ──────────────
        ρ_kg = ustrip(u"kg/m^3", c.ρ)
        @test 1440 ≤ ρ_kg ≤ 1840
        @test ρ_kg ≈ 1840.0  # documented upper-bound value

        # ── Strength + Poisson + ultimate strain ─────────────────────────
        @test ustrip(u"psi", c.fc′) ≈ 4000.0
        @test c.ν ≈ 0.20
        @test c.εcu ≈ 0.003

        # ── ECC: RMC EPD dataset LWC 4 ksi p50 / ρ ───────────────────────
        # 448 kgCO₂e/m³ ÷ 1840 kg/m³ ≈ 0.243 kgCO₂e/kg
        @test isapprox(c.ecc, 0.243; atol = 0.005)
        # Sanity: LWC ECC is meaningfully higher than NWC_4000 (kiln-fired
        # aggregate dominates) — at empirical medians, ~1.6×–2.5× NWC.
        @test c.ecc > 1.5 * NWC_4000.ecc
        @test c.ecc < 2.5 * NWC_4000.ecc
    end

    # =========================================================================
    # All-lightweight (LWC_4000_AL)
    # =========================================================================
    @testset "LWC_4000_AL (all-lightweight)" begin
        c = LWC_4000_AL

        # ── ACI 318-19 Table 19.2.4.2: λ = 0.75 for all-LWC ──────────────
        @test c.λ ≈ 0.75
        @test c.aggregate_type == lightweight

        # ── Density: representative all-LWC value, within ACI bounds ─────
        ρ_kg = ustrip(u"kg/m^3", c.ρ)
        @test 1440 ≤ ρ_kg ≤ 1840
        @test ρ_kg ≈ 1680.0

        @test ustrip(u"psi", c.fc′) ≈ 4000.0

        # ── ECC: same RMC EPD per-m³ baseline / smaller ρ → higher per-kg
        # 448 / 1680 ≈ 0.267 kgCO₂e/kg (extrapolated — no all-LWC EPD)
        @test isapprox(c.ecc, 0.267; atol = 0.005)
        # Per-kg ECC must be larger than sand-LWC because the GWP/m³ is held
        # constant and ρ is smaller (extrapolated assumption — flagged in source).
        @test c.ecc > LWC_4000.ecc
    end

    # =========================================================================
    # ACI 318-11 §8.5.1 modulus of elasticity for LWC.
    #
    # `Ec = wc^1.5 × 33 √f'c` (psi), valid for wc ∈ [90, 160] pcf.
    # The simplified normalweight form `57000 √f'c` overstates Ec by ~30 %
    # for sand-LWC and ~38 % for all-LWC, which would silently under-thicken
    # deflection-controlled slabs and overstate frame stiffness.
    # =========================================================================
    @testset "Ec uses density-aware ACI 318-11 §8.5.1 form" begin
        sqrt_fc = sqrt(4000.0)
        Ec_normalweight = 57000.0 * sqrt_fc                      # simplified form
        Ec_sand_aci     = 114.8534^1.5 * 33.0 * sqrt_fc          # 1840 kg/m³ → 114.85 pcf
        Ec_all_aci      = 104.8731^1.5 * 33.0 * sqrt_fc          # 1680 kg/m³ → 104.87 pcf

        Ec_sand = ustrip(u"psi", LWC_4000.E)
        Ec_all  = ustrip(u"psi", LWC_4000_AL.E)

        # Match the wc^1.5 form to within 0.1 % (round-tripping through pcf
        # introduces a tiny conversion error from kg/m³ ↔ lb/ft³).
        @test isapprox(Ec_sand, Ec_sand_aci; rtol = 1e-3)
        @test isapprox(Ec_all,  Ec_all_aci;  rtol = 1e-3)

        # Both LWC presets must come out below the normalweight value at the
        # same f'c — this is the bug-regression guard.
        @test Ec_sand < 0.75 * Ec_normalweight   # sand-LWC ≈ 71 % of NWC
        @test Ec_all  < 0.65 * Ec_normalweight   # all-LWC  ≈ 62 % of NWC

        # And ordered: all-LWC < sand-LWC < NWC.
        @test Ec_all < Ec_sand
        @test Ec_sand < ustrip(u"psi", NWC_4000.E)
    end

    # =========================================================================
    # Per-volume EC sanity check — both presets must give the same kgCO₂e/m³
    # since both inherit the RMC EPD LWC 4 ksi median (448). This guards
    # against accidental decoupling of (ρ, ECC) when the values get swapped.
    # =========================================================================
    @testset "EC per m³ matches RMC EPD median" begin
        gwp_per_m3(c) = c.ecc * ustrip(u"kg/m^3", c.ρ)
        # Both presets ought to land near 448 kgCO₂e/m³ (within rounding)
        @test isapprox(gwp_per_m3(LWC_4000),    448.0; atol = 5.0)
        @test isapprox(gwp_per_m3(LWC_4000_AL), 448.0; atol = 5.0)
    end

    # =========================================================================
    # Material registry round-trip
    # =========================================================================
    @testset "registry round-trip" begin
        @test material_name(LWC_4000)    == "LWC_4000"
        @test material_name(LWC_4000_AL) == "LWC_4000_AL"
    end

    # =========================================================================
    # Reinforced LWC presets
    # =========================================================================
    @testset "RC_LWC_4000_60 / RC_LWC_4000_AL_60" begin
        rc = RC_LWC_4000_60
        @test rc isa ReinforcedConcreteMaterial
        @test rc.concrete === LWC_4000
        @test rc.rebar === Rebar_60

        rc_al = RC_LWC_4000_AL_60
        @test rc_al.concrete === LWC_4000_AL
        @test rc_al.rebar === Rebar_60
    end

    # =========================================================================
    # Comparison with NWC: same f'c, lower density, lower λ, higher per-kg ECC
    # =========================================================================
    @testset "LWC vs NWC_4000 contrasts" begin
        @test LWC_4000.fc′ == NWC_4000.fc′
        @test LWC_4000.ρ < NWC_4000.ρ
        @test LWC_4000.λ < 1.0
        @test NWC_4000.λ ≈ 1.0
        # Per-kg ECC: LWC > NWC (manufactured aggregate); per-m³ ECC: LWC > NWC
        # (the NRMCA mix-design difference outweighs density savings).
        @test LWC_4000.ecc > NWC_4000.ecc
        @test (LWC_4000.ecc * ustrip(u"kg/m^3", LWC_4000.ρ)) >
              (NWC_4000.ecc * ustrip(u"kg/m^3", NWC_4000.ρ))
    end
end
