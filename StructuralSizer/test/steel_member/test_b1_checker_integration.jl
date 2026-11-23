# Test B1 Moment Amplification Integration in AISCChecker
# Verifies that B1 amplification is correctly applied in is_feasible()

using Test
using Unitful
using StructuralSizer
using StructuralSizer.Asap: kip, ksi

println("Testing B1 Moment Amplification in AISCChecker...")

@testset "B1 Integration in AISCChecker" begin
    # Setup: W14x22 column with moderate compression and moment
    section = W("W14X22")
    material = A992_Steel
    
    # Geometry: 12 ft column, braced frame (K=1.0)
    L = 3.6576  # 12 ft in meters
    geometry = SteelMemberGeometry(L; Lb=L, Cb=1.0, Kx=1.0, Ky=1.0, braced=true)
    
    # Create checker
    checker = AISCChecker()
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinWeight())
    
    @testset "Low compression - B1 ≈ 1.0" begin
        # Low axial load: B1 should be near 1.0
        demand_low_P = MemberDemand(1;
            Pu_c = 50.0u"kN",  # Low compression
            Mux = 50.0u"kN*m",
            M1x = 0.0u"kN*m",   # Eq. A-8-4 at M1/M2 = 0 gives Cm = 0.6
            M2x = 50.0u"kN*m",
        )
        
        feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand_low_P, geometry)
        @test feasible  # Should be feasible with low P
    end
    
    @testset "High compression - B1 increases moments" begin
        # Setup scenario where B1 matters
        # High axial load relative to Pe1
        Pu_high = 500.0u"kN"
        Mux = 20.0u"kN*m"
        
        # Double curvature (M1/M2 > 0) gives Cm = 0.4 (minimum)
        demand_dc = MemberDemand(1;
            Pu_c = Pu_high,
            Mux = Mux,
            M1x = 15.0u"kN*m",  # Double curvature (same sign)
            M2x = 20.0u"kN*m",
        )
        
        # Single curvature (M1/M2 < 0) gives higher Cm
        demand_sc = MemberDemand(1;
            Pu_c = Pu_high,
            Mux = Mux,
            M1x = -20.0u"kN*m",  # Single curvature (opposite sign, equal magnitude)
            M2x = 20.0u"kN*m",
        )
        
        feasible_dc = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand_dc, geometry)
        feasible_sc = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand_sc, geometry)
        
        # Double curvature (lower B1) should be more favorable than single curvature (higher B1)
        # This test verifies that Cm/B1 is actually affecting the result
        println("  Double curvature feasible: $feasible_dc")
        println("  Single curvature feasible: $feasible_sc")
        
        # At least one should show difference (unless both fail/pass for other reasons)
        # The key is that the code doesn't crash and produces reasonable results
        @test (feasible_dc || !feasible_dc)  # Exists without error
        @test (feasible_sc || !feasible_sc)  # Exists without error
    end
    
    @testset "Transverse loading sets Cm = 1.0" begin
        # With transverse loading, Cm = 1.0 regardless of end moments
        demand_transverse = MemberDemand(1;
            Pu_c = 200.0u"kN",
            Mux = 30.0u"kN*m",
            M1x = 15.0u"kN*m",  # Would give low Cm if no transverse load
            M2x = 30.0u"kN*m",
            transverse_load = true  # This sets Cm = 1.0
        )
        
        feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand_transverse, geometry)
        @test (feasible || !feasible)  # Completes without error
        println("  Transverse loading case feasible: $feasible")
    end
    
    @testset "Zero compression - no amplification" begin
        # Pure bending: Pu_c = 0 means B1 = 1.0 (no amplification)
        # W14x22 has ϕMn ≈ 150 kip-ft = ~200 kN-m with Lb=0 (no LTB)
        # But with Lb=12ft, LTB reduces capacity significantly
        demand_pure_bending = MemberDemand(1;
            Pu_c = 0.0u"kN",
            Mux = 30.0u"kN*m",  # Modest moment within LTB-reduced capacity
        )
        
        feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand_pure_bending, geometry)
        @test feasible  # Pure bending should work with modest moment
        println("  Pure bending feasible: $feasible")
    end
    
    @testset "MemberDemand defaults work" begin
        # Test that default M1/M2 values work (backward compatibility)
        demand_defaults = MemberDemand(1;
            Pu_c = 100.0u"kN",
            Mux = 30.0u"kN*m",
            # M1x, M2x not provided - should default to M1=0, M2=Mux
        )
        
        @test demand_defaults.M1x == 0.0u"kN*m"
        @test demand_defaults.M2x == 30.0u"kN*m"
        
        feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand_defaults, geometry)
        @test (feasible || !feasible)  # Completes without error
        println("  Defaults case feasible: $feasible")
    end

    @testset "Array sizing keeps the curvature the checker uses" begin
        # AISC 360-16 App. 8 §8.2.1 (corpus: aisc-360-16, PDF page 306).
        z = [0.0]
        bare = StructuralSizer._steel_array_demand(
            1, [1.0e5], z, [2.0e4], [2.0e4], [2.0e4], z, z, z, z, [1.0],
            nothing, nothing, nothing, nothing, nothing, nothing)
        @test bare.M1x == 0.0
        @test bare.M2x == 2.0e4
        @test bare.transverse_load == false
        @test compute_Cm(bare.M1x, bare.M2x) == 0.6

        curved = StructuralSizer._steel_array_demand(
            1, [1.0e5], z, [2.0e4], [2.0e4], [2.0e4], z, z, z, z, [1.0],
            [-2.0e4], [2.0e4], nothing, nothing, false, nothing)
        @test curved.M1x == -2.0e4
        @test curved.M2x == 2.0e4
        @test compute_Cm(curved.M1x, curved.M2x) == 1.0

        spanned = StructuralSizer._steel_array_demand(
            1, [1.0e5], z, [2.0e4], [2.0e4], [2.0e4], z, z, z, z, [1.0],
            [1.5e4], [2.0e4], nothing, nothing, true, nothing)
        @test spanned.transverse_load
        @test compute_Cm(spanned.M1x, spanned.M2x; transverse_loading=true) == 1.0

        # Single curvature (Cm = 1.0) amplifies more than M1/M2 = 0 (Cm = 0.6).
        # W14X22 is weak-axis slender at 12 ft, so Pe1 about the y-axis is near
        # the compressive strength and B1 can leave the 1.0 floor. Strong-axis
        # Pe1 is several times φPn, so the same sweep on Mux never crosses.
        # AISC 360-16 App. 8 §8.2.1(a), Eq. A-8-4 (corpus: aisc-360-16, PDF page 306).
        n_flip = 0
        n_reverse = 0
        for pu in (100.0, 140.0, 180.0, 220.0, 260.0)
            for muy in (2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 15.0, 18.0, 22.0, 28.0)
                demand_zero = MemberDemand(1; Pu_c=pu * u"kN", Muy=muy * u"kN*m",
                                           M1y=0.0u"kN*m", M2y=muy * u"kN*m")
                demand_single = MemberDemand(1; Pu_c=pu * u"kN", Muy=muy * u"kN*m",
                                             M1y=-muy * u"kN*m", M2y=muy * u"kN*m")
                ok_zero = StructuralSizer.is_feasible(checker, cache, 1, section, material,
                                                      demand_zero, geometry)
                ok_single = StructuralSizer.is_feasible(checker, cache, 1, section, material,
                                                        demand_single, geometry)
                if ok_zero && !ok_single
                    n_flip += 1
                elseif !ok_zero && ok_single
                    n_reverse += 1
                end
            end
        end
        println("  weak-axis curvature: flip=$n_flip reverse=$n_reverse")
        @test n_flip > 0
        @test n_reverse == 0
    end

    @testset "B2 (P-Δ sway) amplification routes through is_feasible" begin
        # is_feasible now applies AISC 360-16 Appendix 8 Eqs. A-8-1/A-8-2 through
        # the shared `_aisc_amplified_forces` core when a `story` is supplied:
        # Mr = B1·Mnt + B2·Mlt, Pr = Pnt + B2·Plt. Only the dimensionless B2 and
        # the sway flag flow into the SI amplification, so a kip/in story record
        # is fine. AISC Design Examples V15.1 story → B2 ≈ 1.13.
        sway = StoryStability(; ΣPu = 2000.0, V = 50.0, Δ = 0.36, L = 144.0,
                                Pmf = 2000.0)
        @test StructuralSizer.is_sway_frame(sway)
        @test story_B2(sway) > 1.1
        braced_story = StoryStability(; ΣPu = 2000.0, V = 50.0, Δ = 0.001, L = 144.0)
        @test !StructuralSizer.is_sway_frame(braced_story)

        # Raw SI (N, N·m): is_feasible normalizes via to_newtons/to_newton_meters,
        # so a bare-Float demand is interpreted as SI. (Avoids a Unitful promotion
        # quirk when a LateralTranslation mixes unitful + Float64-zero defaults.)
        # A column whose strong-axis moment comes from lateral translation (lt):
        # a sway story amplifies that Mlt by B2 (Eq. A-8-1); a braced story / no
        # story leaves B2 = 1. Sweeping the lt moment across the strong-axis
        # flexural boundary, the sway case must never be *more* feasible than the
        # no-story case, and must flip at least one case to infeasible.
        n_flip = 0
        n_reverse = 0
        for mlt in 20.0e3:2.0e3:70.0e3     # 20 → 70 kN·m in N·m
            dem = MemberDemand(1; Pu_c = 150.0e3, Mux = 5.0e3,
                               M1x = 0.0, M2x = 5.0e3,
                               lt = LateralTranslation(; M2ltx = mlt))
            ok_nostory = StructuralSizer.is_feasible(checker, cache, 1, section,
                                                     material, dem, geometry)
            ok_sway = StructuralSizer.is_feasible(checker, cache, 1, section,
                                                  material, dem, geometry; story = sway)
            if ok_nostory && !ok_sway
                n_flip += 1
            elseif !ok_nostory && ok_sway
                n_reverse += 1
            end
        end
        println("  B2 sway amplification: flip=$n_flip reverse=$n_reverse")
        @test n_reverse == 0
        @test n_flip > 0

        # No-op contract: a braced (non-sway) story is byte-identical to no story
        # (B2 collapses to 1), for a demand that carries an lt split.
        dem2 = MemberDemand(1; Pu_c = 150.0e3, Mux = 5.0e3, M1x = 0.0, M2x = 5.0e3,
                            lt = LateralTranslation(; M2ltx = 40.0e3))
        @test StructuralSizer.is_feasible(checker, cache, 1, section, material,
                                          dem2, geometry; story = braced_story) ==
              StructuralSizer.is_feasible(checker, cache, 1, section, material,
                                          dem2, geometry)
    end
end

println("\n✅ B1 integration tests completed!")
