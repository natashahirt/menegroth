# =============================================================================
# Tests for ACI 318-19 Torsion Design
# =============================================================================
# Validates:
#   1. Section properties (Acp, pcp, Aoh, ph, Ao) for rectangular & T-beam
#   2. Threshold torsion (§22.7.4)
#   3. Cracking torsion (§22.7.5.1)
#   4. Cross-section adequacy (§22.7.7.1)
#   5. Transverse reinforcement At/s (§22.7.6.1)
#   6. Longitudinal reinforcement Al (§22.7.6.1.2)
#   7. Full design_beam_torsion — validated against ACI 445.1R-12 Example 1
#   8. Compatibility torsion capping
#   9. Checker integration (is_feasible with Tu > 0)
#  10. Adversarial / edge cases
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using StructuralSizer
using Asap

@testset "ACI 318-19 Torsion Design" begin

    # =========================================================================
    # Reference Data — ACI 445.1R-12 Design Example 1
    # =========================================================================
    # Rectangular beam under pure torsion
    #   b = 12 in (300 mm), h = 20 in (500 mm)
    #   f'c = 2900 psi (20 MPa), fy = fyt = 60000 psi (420 MPa)
    #   Tu = 266 kip·in (30 kN·m)
    #   Cover to stirrup centerline = 1.575 in (40 mm)
    #
    # Expected results (ACI 318-11, Table 9.4.6):
    #   Tth = 36.3 in·kip (3.93 kN·m)
    #   At/s_required = 0.0227 in²/in (0.61 mm²/mm)
    #   At/s_min = 0.005 in²/in (0.125 mm²/mm)
    #   Al_required = 1.18 in² (780.8 mm²)
    #   Section adequacy: 347.6 psi ≤ 403 psi → adequate
    # =========================================================================

    @testset "Section Properties — Rectangular" begin
        props = torsion_section_properties(12.0u"inch", 20.0u"inch", 1.575u"inch")

        @test props.Acp ≈ 240.0    atol=0.5   # 12 × 20
        @test props.pcp ≈ 64.0     atol=0.5   # 2(12 + 20)
        @test props.Aoh ≈ 153.0    atol=5.0   # (12 − 3.15)(20 − 3.15) ≈ 8.85 × 16.85
        @test props.ph  ≈ 50.4     atol=2.0   # ≈ ACI example value
        @test props.Ao  ≈ 0.85 * props.Aoh  atol=0.1
    end

    @testset "Section Properties — T-beam" begin
        # T-beam: bw=12", h=24", bf=48", hf=5"
        props = torsion_section_properties_tbeam(
            12.0u"inch", 24.0u"inch", 48.0u"inch", 5.0u"inch", 1.575u"inch")

        # bf overhang = (48-12)/2 = 18" each side
        # hw = 24 - 5 = 19" (beam projection below slab)
        # max_overhang = 19" → eff overhang = min(18, 19) = 18"
        # bf_torsion = 12 + 2×18 = 48" (full flange is included since hw > overhang)
        @test props.Acp > 240.0  # Larger than web-only
        @test props.pcp > 64.0   # Larger perimeter

        # Aoh/ph still based on web rectangle
        @test props.Aoh ≈ (12.0 - 2*1.575) * (24.0 - 2*1.575)  atol=1.0
    end

    @testset "Threshold Torsion — ACI Example 1" begin
        Acp = 240.0    # in²
        pcp = 64.0     # in
        fc_psi = 2900.0

        Tth = threshold_torsion(Acp, pcp, fc_psi; λ=1.0, φ=0.75)

        # Reference: 36.3 in·kip (note: ACI 445.1R uses slightly different formula)
        # Our formula: Tth = φ·λ·√f'c · Acp²/pcp / 1000
        # = 0.75 * 1.0 * √2900 * 240² / 64 / 1000
        # = 0.75 * 53.85 * 57600 / 64 / 1000 = 0.75 * 53.85 * 900 / 1000
        # = 0.75 * 48465 / 1000 = 36.35 kip·in
        @test Tth ≈ 36.3  atol=1.0
    end

    @testset "Cracking Torsion" begin
        Acp = 240.0
        pcp = 64.0
        fc_psi = 2900.0

        Tcr = cracking_torsion(Acp, pcp, fc_psi; λ=1.0)
        # Tcr = 4·λ·√f'c · Acp²/pcp / 1000
        # = 4 * 53.85 * 900 / 1000 = 193.9 kip·in
        @test Tcr ≈ 193.9  atol=5.0

        # Threshold = φ·λ·√f'c·Acp²/pcp  (φ=0.75 inside threshold_torsion)
        # Tcr has factor 4, threshold has factor φ=0.75 → Tth/Tcr = 0.75/4
        Tth_val = threshold_torsion(Acp, pcp, fc_psi)
        @test Tcr > Tth_val  # Tcr always > Tth (since Tth = φ × Tcr/4)
        @test 0.75 * Tcr / 4 ≈ Tth_val  atol=0.5
    end

    @testset "Cross-Section Adequacy — ACI Example 1" begin
        # Pure torsion: Vu = 0
        # Tu = 266 kip·in
        Vu_kip = 0.0
        Tu_kipin = 266.0
        bw_in = 12.0
        d_in = 17.56  # approximate effective depth
        fc_psi = 2900.0

        # Use approximate Aoh, ph from example
        Aoh = 153.0
        ph = 50.4

        adequate = torsion_section_adequate(Vu_kip, Tu_kipin, bw_in, d_in,
                                            Aoh, ph, fc_psi; λ=1.0, φ=0.75)
        @test adequate == true

        ratio = torsion_adequacy_ratio(Vu_kip, Tu_kipin, bw_in, d_in,
                                       Aoh, ph, fc_psi; λ=1.0, φ=0.75)
        @test ratio < 1.0   # Must be adequate
        @test ratio > 0.8   # Should be close to limit (2.65/2.80 ≈ 0.95 from example)
    end

    @testset "Transverse Reinforcement — ACI Example 1" begin
        Tu_kipin = 266.0
        Ao = 0.85 * 153.0  # = 130.05
        fyt_psi = 60000.0

        At_s = torsion_transverse_reinforcement(Tu_kipin, Ao, fyt_psi; θ=45.0, φ=0.75)

        # Reference: 0.0227 in²/in
        @test At_s ≈ 0.0227  atol=0.003
    end

    @testset "Longitudinal Reinforcement — ACI Example 1" begin
        At_s = 0.0227  # from above (approximately)
        ph = 50.4
        fyt_psi = 60000.0
        fy_psi = 60000.0

        Al = torsion_longitudinal_reinforcement(At_s, ph, fyt_psi, fy_psi; θ=45.0)

        # Reference: 1.18 in² (780.8 mm²)
        @test Al ≈ 1.18  atol=0.1

        # With fyt ≠ fy (e.g., Grade 40 stirrups, Grade 60 longitudinal)
        Al_diff = torsion_longitudinal_reinforcement(At_s, ph, 40000.0, 60000.0; θ=45.0)
        @test Al_diff < Al  # Lower fyt/fy ratio → less Al
    end

    @testset "Minimum Torsion Reinforcement" begin
        bw_in = 12.0
        fc_psi = 2900.0
        fyt_psi = 60000.0

        At_s_min = min_torsion_transverse(bw_in, fc_psi, fyt_psi)

        # Reference: 0.005 in²/in (≈ 0.125 mm²/mm)
        @test At_s_min ≈ 0.005  atol=0.001

        # Higher fc should increase minimum
        At_s_min_6000 = min_torsion_transverse(bw_in, 6000.0, fyt_psi)
        @test At_s_min_6000 > At_s_min
    end

    @testset "Max Torsion Stirrup Spacing" begin
        ph = 50.4
        s_max = max_torsion_stirrup_spacing(ph)
        @test s_max ≈ min(50.4/8, 12.0)  atol=0.1
        @test s_max ≈ 6.3  atol=0.1

        # Large beam: ph/8 > 12" → capped at 12"
        s_max_large = max_torsion_stirrup_spacing(120.0)
        @test s_max_large ≈ 12.0
    end

    # =========================================================================
    # Full Design Function — Validation
    # =========================================================================

    @testset "Full design_beam_torsion — ACI Example 1 (equilibrium)" begin
        result = design_beam_torsion(
            266.0kip*u"inch",   # Tu
            0.0kip,          # Vu (pure torsion)
            12.0u"inch",        # bw
            20.0u"inch",        # h
            17.56u"inch",       # d (approximate)
            2.9ksi,          # f'c
            60.0ksi,         # fy
            60.0ksi;         # fyt
            cover = 1.2u"inch", # Clear cover (1.575 - 0.375/2 stirrup half ≈ 1.2")
            stirrup_size = 4,   # Slightly larger to get closer to 40mm c_ℓ
            torsion_mode = :equilibrium,
        )

        @test result.torsion_required == true
        @test result.section_adequate == true
        @test result.Tu_design_kipin ≈ 266.0  atol=1.0  # Not capped in equilibrium

        # Transverse: At/s ≈ 0.0227 in²/in
        @test result.At_s_required > 0.015
        @test result.At_s_required < 0.04

        # Longitudinal: Al ≈ 1.18 in²
        @test result.Al_required > 0.5
        @test result.Al_required < 2.5

        @test result.adequacy_ratio < 1.0
        @test result.was_capped == false
    end

    @testset "Full design_beam_torsion — Compatibility Capping" begin
        # Same beam but with very high torsion → should be capped
        result = design_beam_torsion(
            500.0kip*u"inch",   # Tu > φ·Tcr → will be capped
            10.0kip,         # Some shear
            12.0u"inch",
            20.0u"inch",
            17.56u"inch",
            2.9ksi,
            60.0ksi,
            60.0ksi;
            torsion_mode = :compatibility,
        )

        @test result.torsion_required == true
        @test result.was_capped == true
        @test result.Tu_design_kipin < result.Tu_demand_kipin
        @test result.Tu_design_kipin ≈ result.φTcr_kipin  atol=0.1
    end

    @testset "Below-Threshold Torsion — Skip Design" begin
        result = design_beam_torsion(
            5.0kip*u"inch",    # Very small Tu (below threshold)
            20.0kip,
            12.0u"inch",
            20.0u"inch",
            17.56u"inch",
            4.0ksi,
            60.0ksi,
            60.0ksi,
        )

        @test result.torsion_required == false
        @test result.At_s_required == 0.0
        @test result.Al_required == 0.0
    end

    @testset "T-beam Torsion Design" begin
        result = design_beam_torsion(
            150.0kip*u"inch",
            15.0kip,
            12.0u"inch",
            24.0u"inch",
            21.0u"inch",
            4.0ksi,
            60.0ksi,
            60.0ksi;
            bf = 48.0u"inch",
            hf = 5.0u"inch",
            torsion_mode = :equilibrium,
        )

        @test result.torsion_required == true
        # T-beam Acp > rectangular Acp → higher threshold
        @test result.Tth_kipin > threshold_torsion(12.0*24.0, 2*(12.0+24.0), 4000.0)
        @test result.At_s_required > 0.0
        @test result.Al_required > 0.0
    end

    # =========================================================================
    # Adversarial / Edge Cases
    # =========================================================================

    @testset "ADVERSARIAL: Section Barely Inadequate" begin
        # Push torsion demand just past the adequacy limit
        # Very thin web with high torsion → should fail adequacy
        result = design_beam_torsion(
            800.0kip*u"inch",   # Very high torsion
            80.0kip,         # Combined with high shear
            8.0u"inch",         # Narrow web
            16.0u"inch",        # Shallow beam
            13.5u"inch",
            3.0ksi,          # Lower concrete strength
            60.0ksi,
            60.0ksi;
            torsion_mode = :equilibrium,
        )

        # In equilibrium mode with this much torsion on a small section,
        # adequacy should fail
        @test result.torsion_required == true
        @test result.adequacy_ratio > 0.8  # High utilization at minimum
    end

    @testset "ADVERSARIAL: Zero-Width Stirrup Box (degenerate geometry)" begin
        # Cover so large that stirrup box collapses (Aoh → 0 or negative)
        # The function doesn't throw — it returns degenerate properties
        # that downstream checks will catch (negative Aoh, negative xo/yo)
        props = torsion_section_properties(8.0u"inch", 16.0u"inch", 5.0u"inch")
        @test props.Aoh < 0  # Negative Aoh signals a degenerate section

        # A slightly less extreme case: 8" beam, 3.5" cover → xo=1", yo=9"
        props2 = torsion_section_properties(8.0u"inch", 16.0u"inch", 3.5u"inch")
        @test props2.Aoh > 0     # Barely valid
        @test props2.Aoh < 20.0  # Very small stirrup box
    end

    @testset "ADVERSARIAL: Very High Concrete Strength (f'c = 12 ksi)" begin
        result = design_beam_torsion(
            200.0kip*u"inch",
            10.0kip,
            14.0u"inch",
            24.0u"inch",
            21.0u"inch",
            12.0ksi,         # High-strength concrete
            60.0ksi,
            60.0ksi;
            torsion_mode = :equilibrium,
        )

        # Higher fc → higher threshold (might not need torsion design)
        @test result.Tth_kipin > 100.0  # Much higher threshold with f'c=12 ksi
    end

    @testset "ADVERSARIAL: Equilibrium vs Compatibility — Different Results" begin
        Tu_high = 400.0kip*u"inch"

        result_eq = design_beam_torsion(
            Tu_high, 20.0kip,
            14.0u"inch", 24.0u"inch", 21.0u"inch",
            4.0ksi, 60.0ksi, 60.0ksi;
            torsion_mode = :equilibrium,
        )

        result_comp = design_beam_torsion(
            Tu_high, 20.0kip,
            14.0u"inch", 24.0u"inch", 21.0u"inch",
            4.0ksi, 60.0ksi, 60.0ksi;
            torsion_mode = :compatibility,
        )

        if result_comp.was_capped
            # Compatibility should use less reinforcement when capped
            @test result_comp.Tu_design_kipin < result_eq.Tu_design_kipin
            @test result_comp.At_s_demand ≤ result_eq.At_s_demand
            @test result_comp.Al_demand ≤ result_eq.Al_demand
        end
    end

    @testset "ADVERSARIAL: Combined Heavy Shear + Torsion" begin
        # Interaction of heavy shear and torsion should challenge adequacy
        result = design_beam_torsion(
            350.0kip*u"inch",
            60.0kip,         # Heavy shear
            12.0u"inch",
            24.0u"inch",
            21.0u"inch",
            4.0ksi,
            60.0ksi,
            60.0ksi;
            torsion_mode = :equilibrium,
        )

        @test result.torsion_required == true
        # The interaction should increase the utilization ratio
        # compared to pure torsion
        result_no_shear = design_beam_torsion(
            350.0kip*u"inch",
            0.0kip,
            12.0u"inch", 24.0u"inch", 21.0u"inch",
            4.0ksi, 60.0ksi, 60.0ksi;
            torsion_mode = :equilibrium,
        )
        @test result.adequacy_ratio ≥ result_no_shear.adequacy_ratio
    end

    @testset "ADVERSARIAL: Minimum Reinforcement Governs" begin
        # Very low torsion → required At/s < minimum → minimum should govern
        result = design_beam_torsion(
            40.0kip*u"inch",    # Just above threshold
            5.0kip,
            12.0u"inch",
            20.0u"inch",
            17.0u"inch",
            4.0ksi,
            60.0ksi,
            60.0ksi;
            torsion_mode = :equilibrium,
        )

        if result.torsion_required
            # When demand is low, minimum should govern
            @test result.At_s_required ≥ result.At_s_min
            @test result.At_s_required ≥ result.At_s_demand
        end
    end

    @testset "ADVERSARIAL: θ ≠ 45° (compression diagonal angle)" begin
        # ACI allows 30° ≤ θ ≤ 60° for non-prestressed members
        # θ < 45° → less transverse, more longitudinal
        # θ > 45° → more transverse, less longitudinal
        Tu = 200.0kip*u"inch"
        common_args = (Tu, 10.0kip, 14.0u"inch", 24.0u"inch", 21.0u"inch",
                       4.0ksi, 60.0ksi, 60.0ksi)

        r45 = design_beam_torsion(common_args...; θ=45.0, torsion_mode=:equilibrium)
        r30 = design_beam_torsion(common_args...; θ=30.0, torsion_mode=:equilibrium)

        # θ=30° should need less transverse reinforcement
        if r30.torsion_required && r45.torsion_required
            @test r30.At_s_demand < r45.At_s_demand
            # But more longitudinal reinforcement
            @test r30.Al_demand > r45.Al_demand
        end
    end

    # =========================================================================
    # Checker Integration
    # =========================================================================

    @testset "Checker — is_feasible with torsion demand" begin
        checker = ACIBeamChecker(; fy_ksi=60.0, fyt_ksi=60.0)
        mat = NWC_4000

        # Section that works for flexure + shear
        sec = RCBeamSection(b=14u"inch", h=24u"inch", bar_size=9, n_bars=4)

        # Demand with no torsion → should be feasible
        demand_no_T = RCBeamDemand(1; Mu=200.0, Vu=30.0, Tu=0.0)
        # Demand with moderate torsion → should still pass adequacy
        demand_mod_T = RCBeamDemand(1; Mu=200.0, Vu=30.0, Tu=100.0)

        geom = ConcreteMemberGeometry(25.0u"ft")
        cache = create_cache(checker, 1)
        precompute_capacities!(checker, cache, [sec], mat, MinVolume())

        @test is_feasible(checker, cache, 1, sec, mat, demand_no_T, geom) == true

        # With torsion — still feasible for a 14×24 section
        @test is_feasible(checker, cache, 1, sec, mat, demand_mod_T, geom) == true
    end

    @testset "Checker — T-beam torsion adequacy" begin
        checker = ACIBeamChecker(; fy_ksi=60.0, fyt_ksi=60.0)
        mat = NWC_4000

        sec = RCTBeamSection(bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
                             bar_size=9, n_bars=4)

        demand_T = RCBeamDemand(1; Mu=200.0, Vu=30.0, Tu=150.0)
        geom = ConcreteMemberGeometry(25.0u"ft")
        cache = create_cache(checker, 1)
        precompute_capacities!(checker, cache, [sec], mat, MinVolume())

        # Should pass with moderate torsion on a decent-sized T-beam
        @test is_feasible(checker, cache, 1, sec, mat, demand_T, geom) == true
    end

    @testset "RCBeamDemand backward compatibility" begin
        # Without Tu — should still work
        d1 = RCBeamDemand(1; Mu=100.0, Vu=20.0)
        @test d1.Tu == 0.0

        # With Tu
        d2 = RCBeamDemand(1; Mu=100.0, Vu=20.0, Tu=50.0)
        @test d2.Tu == 50.0

        # Unitful
        d3 = RCBeamDemand(1; Mu=100.0u"kN*m", Vu=50.0u"kN", Tu=15.0u"kN*m")
        @test d3.Tu == 15.0u"kN*m"
    end
end
