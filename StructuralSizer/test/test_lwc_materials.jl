# =============================================================================
# Test: Lightweight Concrete (LWC) Material Presets
# =============================================================================
#
# Verifies that LWC_4000 (sand-lightweight) and LWC_4000_AL (all-lightweight)
# have grounded values per:
#   - ACI 318-19 Table 19.2.4.2 (= ACI 318-11 §8.6.1) — λ values
#   - ACI 318-19 §R19.2.4.1                          — density bounds (1440–1840 kg/m³)
#   - NRMCA Industry-Wide EPD v3.2 Table 13a (LW-4000-00-FA/SL, A1–A3)
#       — interim ECC source, 642.49 kgCO₂e/m³ → divide by ρ
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

        # ── Strength + modulus per ACI 318-11 §8.5.1 (NWC formula; LWC
        #    correction is via λ on √f'c, not on Ec itself) ───────────────
        @test ustrip(u"psi", c.fc′) ≈ 4000.0
        @test c.ν ≈ 0.20
        @test c.εcu ≈ 0.003

        # ── ECC: NRMCA EPD v3.2 Table 13a baseline GWP / ρ ───────────────
        # 642.49 kgCO₂e/m³ ÷ 1840 kg/m³ ≈ 0.349 kgCO₂e/kg
        @test isapprox(c.ecc, 0.349; atol = 0.005)
        # Sanity: LWC ECC is meaningfully higher than NWC_4000 (kiln-fired
        # aggregate dominates) — between 2× and 3× NWC.
        @test c.ecc > 2 * NWC_4000.ecc
        @test c.ecc < 3 * NWC_4000.ecc
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

        # ── ECC: same NRMCA baseline GWP / smaller ρ → higher per-kg ─────
        # 642.49 / 1680 ≈ 0.382 kgCO₂e/kg
        @test isapprox(c.ecc, 0.382; atol = 0.005)
        # Per-kg ECC must be larger than sand-LWC because the GWP/m³ is held
        # constant and ρ is smaller (interim assumption — flagged in source).
        @test c.ecc > LWC_4000.ecc
    end

    # =========================================================================
    # Per-volume EC sanity check — both presets must give the same kgCO₂e/m³
    # since both inherit the NRMCA Table 13a baseline. This guards against
    # accidental decoupling of (ρ, ECC) when the interim values get swapped.
    # =========================================================================
    @testset "EC per m³ matches NRMCA baseline" begin
        gwp_per_m3(c) = c.ecc * ustrip(u"kg/m^3", c.ρ)
        # Both presets ought to land near 642.49 kgCO₂e/m³ (within rounding)
        @test isapprox(gwp_per_m3(LWC_4000),    642.49; atol = 5.0)
        @test isapprox(gwp_per_m3(LWC_4000_AL), 642.49; atol = 5.0)
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
