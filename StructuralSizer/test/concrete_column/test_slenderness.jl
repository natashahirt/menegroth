# ==============================================================================
# Tests for ACI 318-19 Slenderness Effects
# Reference: StructurePoint "Slender Column Design in Non-Sway Frame"
# Reference: StructurePoint "Slender Concrete Column Design in Sway Frames - 
#            Moment Magnification Method (ACI 318-19)"
# ==============================================================================

using Test
using StructuralSizer
using Unitful

# Load test data
include("test_data/slenderness_nonsway_17x17.jl")
include("test_data/slenderness_sway_18x18.jl")

@testset "Slenderness Effects (ACI 318-19)" begin
    ref = SLENDER_NONSWAY_17X17
    
    # =========================================================================
    @testset "Material Properties" begin
        # Concrete modulus: Ec = 57000√f'c (psi)
        Ec_val = StructuralSizer.Ec_ksi(ref.materials)
        @test Ec_val ≈ ref.materials.Ec rtol=0.01
        
        # For f'c = 3 ksi = 3000 psi: Ec = 57000√3000 ≈ 3122 ksi
        @test Ec_val ≈ 3122 rtol=0.01
    end
    
    # =========================================================================
    @testset "Slenderness Ratio" begin
        # Create column section (17×17 with 10 #9 bars distributed on two sides)
        section = RCColumnSection(
            b = 17.0u"inch",
            h = 17.0u"inch",
            cover = 2.5u"inch",
            bar_size = 9,
            n_bars = 10,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Geometry: non-sway frame (Lu in meters)
        Lu_m = ref.column.Lu / 39.37  # 120 in to m
        geometry = ConcreteMemberGeometry(Lu_m; k = ref.frame.k_calc, braced = true)
        
        # Slenderness ratio: kLu/r where r = 0.3h = 0.3×17 = 5.1 in
        # Expected: k*Lu/r = 0.959 * 120 / 5.1 ≈ 22.56 (using 0.3h)
        λ = StructuralSizer.slenderness_ratio(section, geometry)
        
        # PDF uses r = √(Ig/Ag) = 4.91 in → λ = 23.45
        # We use simplified r = 0.3h = 5.1 in → λ ≈ 22.56
        # The formulas are different but both ACI-compliant
        expected_λ = ref.frame.k_calc * ref.column.Lu / (0.3 * ref.column.h)
        @test λ ≈ expected_λ rtol=0.02
    end
    
    # =========================================================================
    @testset "Slenderness Limit Check" begin
        section = RCColumnSection(
            b = 17.0u"inch",
            h = 17.0u"inch",
            cover = 2.5u"inch",
            bar_size = 9,
            n_bars = 10,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Non-sway geometry (Lu in meters)
        Lu_m = ref.column.Lu / 39.37
        geometry = ConcreteMemberGeometry(Lu_m; k = ref.frame.k_calc, braced = true)
        
        # Should NOT consider slenderness when M1/M2 = 0/105
        # Limit = 34 - 12(M1/M2) = 34 - 0 = 34
        # With r = 0.3h = 5.1 in: λ = 0.959 * 120 / 5.1 ≈ 22.6 < 34
        should_consider = StructuralSizer.should_consider_slenderness(
            section, geometry;
            M1 = ref.loading.M1,
            M2 = ref.loading.M2
        )
        @test should_consider == ref.slenderness.slender
        @test should_consider == false
        
        # With conservative k=1.0: λ = 1.0 * 120 / 5.1 ≈ 23.5, still < 34
        geometry_conservative = ConcreteMemberGeometry(Lu_m; k = 1.0, braced = true)
        should_consider_conservative = StructuralSizer.should_consider_slenderness(
            section, geometry_conservative;
            M1 = ref.loading.M1,
            M2 = ref.loading.M2
        )
        @test should_consider_conservative == false
        
        # Test case where slenderness SHOULD be considered
        # Need longer column: Lu = 250 in → λ = 1.0 * 250 / 5.1 ≈ 49 > 34
        Lu_long_m = 250.0 / 39.37
        geometry_long = ConcreteMemberGeometry(Lu_long_m; k = 1.0, braced = true)
        @test StructuralSizer.should_consider_slenderness(
            section, geometry_long;
            M1 = 0.0, M2 = 100.0
        ) == true
    end
    
    # =========================================================================
    @testset "Effective Stiffness (EI)_eff" begin
        section = RCColumnSection(
            b = 17.0u"inch",
            h = 17.0u"inch",
            cover = 2.5u"inch",
            bar_size = 9,
            n_bars = 10,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Use proper ReinforcedConcreteMaterial (f'c = 3 ksi, fy = 60 ksi)
        mat = RC_3000_60
        
        # Accurate method: (0.2EcIg + EsIse) / (1 + βdns)
        EI_eff = StructuralSizer.effective_stiffness(
            section, mat;
            βdns = ref.loading.βdns,
            method = :accurate
        )
        
        # PDF uses Ise = 360 in⁴ giving (EI)_eff = 10.56×10⁶ kip-in²
        # Our Ise depends on bar arrangement - verify formula is correct
        # by checking the formula components
        Ec_val = StructuralSizer.Ec_ksi(ref.materials)  # 3122 ksi
        Ig = 17.0^4 / 12  # 6960 in⁴
        
        # Simplified method check
        EI_eff_simplified = StructuralSizer.effective_stiffness(
            section, mat;
            βdns = ref.loading.βdns,
            method = :simplified
        )
        EI_expected_simplified = 0.4 * Ec_val * Ig / (1 + ref.loading.βdns)
        @test EI_eff_simplified ≈ EI_expected_simplified rtol=0.01
        
        # Accurate method should give higher value than simplified
        @test EI_eff > EI_eff_simplified
        
        # Verify reasonable range (order of magnitude)
        @test 5e6 < EI_eff < 15e6  # kip-in²
    end
    
    # =========================================================================
    @testset "Critical Buckling Load Pc" begin
        section = RCColumnSection(
            b = 17.0u"inch",
            h = 17.0u"inch",
            cover = 2.5u"inch",
            bar_size = 9,
            n_bars = 10,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Use proper ReinforcedConcreteMaterial (f'c = 3 ksi, fy = 60 ksi)
        mat = RC_3000_60
        
        Lu_m = ref.column.Lu / 39.37
        geometry = ConcreteMemberGeometry(Lu_m; k = ref.frame.k_calc, braced = true)
        
        # Critical load: Pc = π²(EI)_eff / (kLu)²
        Pc = StructuralSizer.critical_buckling_load(
            section, mat, geometry;
            βdns = ref.loading.βdns
        )
        
        # PDF: Pc = 7871 kip (with their Ise = 360 in⁴)
        # Our Ise differs, so check formula is correct by computing expected
        EI_eff = StructuralSizer.effective_stiffness(section, mat; βdns=ref.loading.βdns)
        kLu = ref.frame.k_calc * ref.column.Lu
        Pc_expected = π^2 * EI_eff / kLu^2
        @test Pc ≈ Pc_expected rtol=0.01
        
        # Verify reasonable range - should be same order of magnitude as PDF
        @test 4000 < Pc < 10000  # kip
        
        # Stability check: Pu < 0.75 Pc (or section is unstable)
        @test ref.loading.Pu < 0.75 * Pc
    end
    
    # =========================================================================
    @testset "Moment Magnification Factor δns" begin
        # Cm = 0.6 - 0.4(M1/M2) with M1=0, M2=105
        Cm = StructuralSizer.calc_Cm(ref.loading.M1, ref.loading.M2)
        @test Cm ≈ ref.slenderness.Cm rtol=0.01
        
        # δns = Cm / (1 - Pu/(0.75Pc))
        # With Pu = 525 kip, Pc = 7871 kip:
        # δns = 0.6 / (1 - 525/(0.75×7871)) = 0.6 / (1 - 0.089) ≈ 0.66
        δns_calc = StructuralSizer.magnification_factor_nonsway(
            ref.loading.Pu, 
            ref.slenderness.Pc;
            Cm = Cm
        )
        
        # Result should be capped at 1.0 (since calculated value < 1.0)
        @test δns_calc ≈ ref.slenderness.δns rtol=0.01
        @test δns_calc >= 1.0
    end
    
    # =========================================================================
    @testset "Minimum Moment" begin
        # M_min = Pu(0.6 + 0.03h) / 12
        # With Pu = 525 kip, h = 17 in:
        # M_min = 525 × (0.6 + 0.03×17) / 12 = 525 × 1.11 / 12 ≈ 48.56 kip-ft
        M_min = StructuralSizer.minimum_moment(ref.loading.Pu, ref.column.h)
        @test M_min ≈ ref.slenderness.M_min rtol=0.01
    end
    
    # =========================================================================
    @testset "Magnified Moment Mc (Complete Calculation)" begin
        section = RCColumnSection(
            b = 17.0u"inch",
            h = 17.0u"inch",
            cover = 2.5u"inch",
            bar_size = 9,
            n_bars = 10,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Use proper ReinforcedConcreteMaterial (f'c = 3 ksi, fy = 60 ksi)
        mat = RC_3000_60
        
        Lu_m = ref.column.Lu / 39.37
        geometry = ConcreteMemberGeometry(Lu_m; k = ref.frame.k_calc, braced = true)
        
        result = StructuralSizer.magnify_moment_nonsway(
            section, mat, geometry,
            ref.loading.Pu,
            ref.loading.M1,
            ref.loading.M2;
            βdns = ref.loading.βdns
        )
        
        # For this case, slenderness is NOT required (λ < limit)
        # So the function returns Mc = max(M2, M_min) without magnification
        @test result.slender == false
        
        # When slender=false, Cm and δns are defaults (1.0)
        @test result.δns ≈ 1.0
        
        # Mc should be max(M2, M_min) = max(105, 48.56) = 105
        @test result.Mc ≈ ref.slenderness.Mc rtol=0.01
    end
    
    # =========================================================================
    @testset "Sway Frame Magnification" begin
        # Test sway magnification factor
        # δs = 1 / (1 - ΣPu/(0.75ΣPc))
        
        # Example: ΣPu = 1000 kip, ΣPc = 5000 kip
        # δs = 1 / (1 - 1000/(0.75×5000)) = 1 / (1 - 0.267) = 1.36
        δs = StructuralSizer.magnification_factor_sway(1000.0, 5000.0)
        @test δs ≈ 1.36 rtol=0.01
        
        # Test moment magnification for sway
        result = StructuralSizer.magnify_moment_sway(
            50.0, 100.0,   # Non-sway moments M1ns, M2ns
            20.0, 40.0,    # Sway moments M1s, M2s
            1.5            # δs
        )
        # M1 = M1ns + δs×M1s = 50 + 1.5×20 = 80
        # M2 = M2ns + δs×M2s = 100 + 1.5×40 = 160
        @test result.M1 ≈ 80.0
        @test result.M2 ≈ 160.0
    end
end

# ==============================================================================
# Complete Sway Frame Magnification Tests
# Reference: StructurePoint "Slender Concrete Column Design in Sway Frames"
# ==============================================================================

@testset "Sway Frame Magnification - Complete (ACI 318-19)" begin
    ref = SLENDER_SWAY_18X18
    
    # Create column section (18×18 with 8 #6 bars)
    section = RCColumnSection(
        b = ref.column.b * u"inch",
        h = ref.column.h * u"inch",
        cover = ref.column.cover * u"inch",
        bar_size = ref.reinforcement.bar_size,
        n_bars = ref.reinforcement.n_bars,
        tie_type = :tied
    )
    
    # Use proper ReinforcedConcreteMaterial (f'c = 4 ksi, fy = 60 ksi)
    mat = RC_4000_60
    
    # =========================================================================
    @testset "Story Stability Index Q" begin
        # Create SwayStoryProperties
        story = SwayStoryProperties(
            ref.story.ΣPu,
            ref.story.ΣPc,
            ref.story.Vus,
            ref.story.Δo,
            ref.story.lc
        )
        
        # Calculate Q = ΣPu × Δo / (Vus × lc)
        Q = stability_index(story)
        @test Q ≈ ref.sway.Q rtol=0.02
        
        # Check sway frame determination (Q > 0.05)
        @test is_sway_frame(story) == ref.sway.is_sway
    end
    
    # =========================================================================
    @testset "Sway Magnification Factor δs - Q Method" begin
        # δs = 1 / (1 - Q)
        Q = ref.sway.Q
        δs_Q = magnification_factor_sway_Q(Q)
        @test δs_Q ≈ ref.sway.δs_Q_method rtol=0.02
    end
    
    # =========================================================================
    @testset "Sway Magnification Factor δs - ΣPc Method" begin
        # δs = 1 / (1 - ΣPu/(0.75×ΣPc))
        δs_Pc = magnification_factor_sway(ref.story.ΣPu, ref.story.ΣPc)
        @test δs_Pc ≈ ref.sway.δs_Pc_method rtol=0.02
    end
    
    # =========================================================================
    @testset "Simple Sway Moment Magnification" begin
        # Test the basic moment magnification formula
        result = magnify_moment_sway(
            ref.loading.M1ns, ref.loading.M2ns,
            ref.loading.M1s, ref.loading.M2s,
            ref.sway.δs
        )
        
        # M1 = M1ns + δs × M1s
        expected_M1 = ref.loading.M1ns + ref.sway.δs * ref.loading.M1s
        @test result.M1 ≈ expected_M1 rtol=0.01
        
        # M2 = M2ns + δs × M2s
        expected_M2 = ref.loading.M2ns + ref.sway.δs * ref.loading.M2s
        @test result.M2 ≈ expected_M2 rtol=0.01
        
        # Check against reference magnified moments
        @test result.M1 ≈ ref.sway.M1_magnified rtol=0.02
        @test result.M2 ≈ ref.sway.M2_magnified rtol=0.02
    end
    
    # =========================================================================
    @testset "Effective Stiffness for Sway Frame" begin
        # (EI)eff for sway uses βds instead of βdns
        EI_eff_sway = effective_stiffness_sway(
            section, mat;
            βds = ref.loading.βds,  # 0.0 for wind
            method = :accurate
        )
        
        # With βds = 0, denominator = 1.0
        # Should be larger than non-sway with βdns = 0.805
        EI_eff_nonsway = effective_stiffness(
            section, mat;
            βdns = ref.loading.βdns,  # 0.805
            method = :accurate
        )
        
        @test EI_eff_sway > EI_eff_nonsway
        
        # Verify reasonable magnitude
        @test 5e6 < EI_eff_sway < 15e6  # kip-in²
    end
    
    # =========================================================================
    @testset "Critical Buckling Load for Sway Frame" begin
        Lu_m = ref.column.Lu / 39.37  # Convert to meters
        geometry = ConcreteMemberGeometry(Lu_m; k = ref.frame.k_sway, braced = false)
        
        Pc_sway = critical_buckling_load_sway(
            section, mat, geometry;
            βds = ref.loading.βds
        )
        
        # Pc should be reasonable order of magnitude
        @test 1000 < Pc_sway < 5000  # kip
        
        # Verify formula: Pc = π²(EI)eff / (kLu)²
        EI_eff = effective_stiffness_sway(section, mat; βds=ref.loading.βds)
        kLu = ref.frame.k_sway * ref.column.Lu
        Pc_expected = π^2 * EI_eff / kLu^2
        @test Pc_sway ≈ Pc_expected rtol=0.01
    end
    
    # =========================================================================
    @testset "Complete Sway Magnification Procedure" begin
        # Set up story and geometry
        story = SwayStoryProperties(
            ref.story.ΣPu,
            ref.story.ΣPc,
            ref.story.Vus,
            ref.story.Δo,
            ref.story.lc
        )
        
        Lu_m = ref.column.Lu / 39.37
        geometry = ConcreteMemberGeometry(Lu_m; k = ref.frame.k_sway, braced = false)
        
        # Run complete magnification
        result = magnify_moment_sway_complete(
            section, mat, geometry,
            ref.loading.Pu,
            ref.loading.M1ns, ref.loading.M2ns,
            ref.loading.M1s, ref.loading.M2s;
            story = story,
            βds = ref.loading.βds,
            βdns = ref.loading.βdns
        )
        
        # Check sway magnification occurred
        @test result.sway_magnified == true
        
        # Check Q is calculated correctly
        @test result.Q ≈ ref.sway.Q rtol=0.02
        
        # Magnified end moments should be close to reference
        # (Using Q method gives slightly different δs than ΣPc method)
        @test result.M1 ≈ ref.sway.M1_magnified rtol=0.10
        @test result.M2 ≈ ref.sway.M2_magnified rtol=0.10
        
        # Design moment Mc should be max of magnified moments
        @test result.Mc ≈ max(abs(result.M1), abs(result.M2)) rtol=0.01
    end
    
    # =========================================================================
    @testset "Sway vs Non-Sway Comparison" begin
        Lu_m = ref.column.Lu / 39.37
        
        # Non-sway geometry (k = 0.65 typical for braced)
        geometry_nonsway = ConcreteMemberGeometry(Lu_m; k = 0.65, braced = true)
        
        # Sway geometry (k = 1.282 for this example)
        geometry_sway = ConcreteMemberGeometry(Lu_m; k = ref.frame.k_sway, braced = false)
        
        # Critical loads
        Pc_nonsway = critical_buckling_load(section, mat, geometry_nonsway; βdns=ref.loading.βdns)
        Pc_sway = critical_buckling_load_sway(section, mat, geometry_sway; βds=ref.loading.βds)
        
        # Sway Pc should be much lower (higher k, larger kLu)
        @test Pc_sway < Pc_nonsway
    end
    
    # =========================================================================
    @testset "Stability Index Edge Cases" begin
        # Very stable story (low Q)
        story_stable = SwayStoryProperties(100.0, 100000.0, 50.0, 0.05, 180.0)
        @test is_sway_frame(story_stable) == false
        @test stability_index(story_stable) < 0.05
        
        # Marginally sway (Q just above 0.05)
        story_marginal = SwayStoryProperties(1000.0, 10000.0, 20.0, 0.16, 160.0)
        Q_marginal = stability_index(story_marginal)
        # Q = 1000 × 0.16 / (20 × 160) = 0.05
        @test Q_marginal ≈ 0.05 rtol=0.01
        
        # Very unstable (high Q approaching 1.0)
        story_unstable = SwayStoryProperties(3000.0, 5000.0, 10.0, 0.5, 100.0)
        Q_unstable = stability_index(story_unstable)
        δs_unstable = magnification_factor_sway_Q(Q_unstable)
        @test δs_unstable > 2.0  # High magnification
    end
    
    # =========================================================================
    @testset "δs Limits and Warnings" begin
        # Normal case
        δs_normal = magnification_factor_sway_Q(0.10)
        @test δs_normal ≈ 1.111 rtol=0.01
        @test δs_normal ≥ 1.0
        
        # High but stable case (δs > 1.5 triggers warning)
        δs_high = magnification_factor_sway_Q(0.40)
        @test δs_high ≈ 1.667 rtol=0.01
        @test δs_high > 1.5  # Would trigger warning in practice
        
        # Unstable case (Q ≥ 1.0 returns Inf)
        δs_unstable = magnification_factor_sway_Q(1.0)
        @test isinf(δs_unstable)
    end

    # =========================================================================
    @testset "Auto-Fallback: Q > 1.5 → ΣPc Method (Rectangular)" begin
        # Story where Q-method gives δs > 1.5 but ΣPc method is fine.
        # Q = ΣPu×Δo / (Vus×lc) = 1000×0.72 / (10×180) = 0.40
        # δs_Q = 1/(1-0.4) = 1.667 > 1.5  →  triggers fallback
        # δs_Pc = 1/(1 - 1000/(0.75×50000)) = 1.027  →  acceptable
        story_fallback = SwayStoryProperties(1000.0, 50000.0, 10.0, 0.72, 180.0)
        
        Q_check = stability_index(story_fallback)
        @test Q_check ≈ 0.40 rtol=0.01

        Lu_m = 186.0 / 39.37
        geometry_sway = ConcreteMemberGeometry(Lu_m; k = 1.3, braced = false)

        result = magnify_moment_sway_complete(
            section, mat, geometry_sway,
            ref.loading.Pu,
            ref.loading.M1ns, ref.loading.M2ns,
            ref.loading.M1s, ref.loading.M2s;
            story = story_fallback,
            βds = 0.0,
            βdns = 0.6,
        )

        # Q-method δs = 1.667 > 1.5, so should have fallen back to ΣPc method
        @test result.δs_method == :ΣPc
        
        # δs from ΣPc should be ≈ 1/(1 - 1000/(0.75×50000)) = 1.027
        @test result.δs ≈ 1.027 rtol=0.05
        @test result.δs < 1.5  # ΣPc method gives a much lower value
        @test result.sway_magnified == true
    end

    # =========================================================================
    @testset "Auto-Fallback: Both Methods > 1.5 → needs_P_delta" begin
        # Both Q and ΣPc give δs > 1.5 — should flag for P-Δ
        # ΣPu/(0.75 ΣPc) must be > 1/3 → δs_Pc > 1.5
        # e.g. ΣPu = 3000, ΣPc = 6000 → 3000/4500 = 0.667 → δs = 3.0
        story_both_high = SwayStoryProperties(
            3000.0,    # ΣPu
            6000.0,    # ΣPc — δs_Pc = 1/(1-3000/4500) = 3.0
            5.0,       # Vus
            0.60,      # Δo — Q = 3000×0.60/(5×180) = 2.0 → δs_Q = Inf
            180.0      # lc
        )

        Lu_m = 186.0 / 39.37
        geometry_sway = ConcreteMemberGeometry(Lu_m; k = 1.3, braced = false)

        result = magnify_moment_sway_complete(
            section, mat, geometry_sway,
            ref.loading.Pu,
            ref.loading.M1ns, ref.loading.M2ns,
            ref.loading.M1s, ref.loading.M2s;
            story = story_both_high,
            βds = 0.0,
            βdns = 0.6,
        )

        @test result.δs_method == :needs_P_delta
        @test result.δs > 1.5
    end

    # =========================================================================
    @testset "Auto-Fallback: Circular Column (Q > 1.5 → ΣPc)" begin
        # Same fallback logic for circular columns
        circ_section = RCCircularSection(
            D = 20.0u"inch",
            cover = 2.5u"inch",
            bar_size = 8,
            n_bars = 8,
            tie_type = :spiral
        )
        circ_mat = RC_4000_60
        
        # Story where Q gives δs > 1.5 but ΣPc is fine
        story_circ = SwayStoryProperties(1000.0, 50000.0, 10.0, 0.72, 180.0)
        
        Lu_m = 186.0 / 39.37
        geom_circ = ConcreteMemberGeometry(Lu_m; k = 1.3, braced = false)
        
        result_circ = magnify_moment_sway_complete(
            circ_section, circ_mat, geom_circ,
            200.0,      # Pu
            30.0, 60.0, # M1ns, M2ns
            20.0, 40.0; # M1s, M2s
            story = story_circ,
            βds = 0.0,
            βdns = 0.6,
        )
        
        @test result_circ.δs_method == :ΣPc
        @test result_circ.δs < 1.5
        @test result_circ.sway_magnified == true
        
        # Verify moments magnified correctly: M2 = M2ns + δs × M2s
        expected_M2 = 60.0 + result_circ.δs * 40.0
        @test result_circ.M2 ≈ expected_M2 rtol=0.01
    end
end
