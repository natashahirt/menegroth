# Shared second-order column design: StoryStability record + design_column_moments
# trait. Validates the ACI 318-11 §10.10.7 (RC) and AISC 360-16 App.8 (steel)
# paths against published worked examples, and the byte-identical no-op contract.

using StructuralSizer
using Test

const SS = StructuralSizer

@testset "Shared column moments (StoryStability + design_column_moments)" begin

    # =========================================================================
    # StoryStability adapters — ACI Q and AISC B2 from one record
    # =========================================================================
    @testset "StoryStability bridges ACI Q and AISC B2" begin
        # AISC Design Examples V15.1 story: Pstory=2000, H=50, L=144, ΔH=0.36,
        # moment frame (Pmf=Pstory) → RM=0.85, Pe_story=17000, B2≈1.13.
        s_steel = StoryStability(; ΣPu = 2000.0, V = 50.0, Δ = 0.36, L = 144.0,
                                   Pmf = 2000.0)
        @test isapprox(story_B2(s_steel), 1.13; rtol = 0.02)
        @test isapprox(B2StoryProperties(s_steel).Pe_story, 17000.0; rtol = 0.01)
        @test isapprox(B2StoryProperties(s_steel).RM, 0.85; atol = 0.01)

        # StructurePoint 18x18 sway story: ΣPu=2031, Vus=20, Δo=0.16, lc=186.
        # Q = 2031·0.16/(20·186) = 0.0874 > 0.05 → sway.
        s_rc = StoryStability(; ΣPu = 2031.0, V = 20.0, Δ = 0.16, L = 186.0,
                                ΣPc = 49976.83)
        @test isapprox(stability_index(s_rc), 0.0874; atol = 0.001)
        @test is_sway_frame(s_rc)
        # The shared record must agree with the native ACI record it adapts to.
        @test stability_index(s_rc) == stability_index(SwayStoryProperties(s_rc))

        # A stiff/braced story (tiny drift) is non-sway: Q ≤ 0.05.
        s_braced = StoryStability(; ΣPu = 2031.0, V = 20.0, Δ = 0.01, L = 186.0)
        @test !is_sway_frame(s_braced)
        @test isapprox(story_B2(s_braced), 1.0; atol = 0.02)  # negligible P-Δ
    end

    # =========================================================================
    # RC trait — ACI 318-11 §10.10.7.1, Eq. 10-18: M = Mns + δs·Ms
    # StructurePoint "Slender Column in Sway Frames" 18x18 example.
    # =========================================================================
    @testset "RC sway end-moment magnification (StructurePoint 18x18)" begin
        story = StoryStability(; ΣPu = 2031.0, V = 20.0, Δ = 0.16, L = 186.0,
                                 ΣPc = 49976.83)
        # Non-sway (gravity) end moments in M1x/M2x; sway (wind) moments in lt.
        demand = SS.RCColumnDemand(1; Pu = 381.8,
                                   M1x = 50.2, M2x = 47.6,
                                   lt = LateralTranslation(; M1ltx = 53.8, M2ltx = 46.3))

        res = design_column_moments(demand, story)
        @test res.sway_applied
        @test res.method == :Q                      # δs_Q = 1.096 ≤ 1.5
        @test isapprox(res.δs, 1.096; atol = 0.005)  # 1/(1-0.0874)
        # Eq. 10-18 at each end: M = Mns + δs·Ms.
        @test isapprox(res.M1x, 50.2 + res.δs * 53.8; atol = 1e-6)
        @test isapprox(res.M2x, 47.6 + res.δs * 46.3; atol = 1e-6)
        @test isapprox(res.M1x, 109.1; atol = 0.3)   # StructurePoint Q-method
        @test isapprox(res.M2x, 98.3; atol = 0.3)
    end

    @testset "RC no-op contract (gravity-only / non-sway)" begin
        story = StoryStability(; ΣPu = 2031.0, V = 20.0, Δ = 0.16, L = 186.0,
                                 ΣPc = 49976.83)
        # No lateral-translation split → end moments unchanged even on a sway story.
        grav = SS.RCColumnDemand(1; Pu = 381.8, M1x = 50.2, M2x = 47.6)
        r0 = design_column_moments(grav, story)
        @test !r0.sway_applied
        @test r0.δs == 1.0
        @test r0.M1x == grav.M1x && r0.M2x == grav.M2x

        # lt present but non-sway story (Q ≤ 0.05) → no magnification.
        braced = StoryStability(; ΣPu = 2031.0, V = 20.0, Δ = 0.01, L = 186.0)
        sway_dem = SS.RCColumnDemand(1; Pu = 381.8, M1x = 50.2, M2x = 47.6,
                                     lt = LateralTranslation(; M1ltx = 53.8, M2ltx = 46.3))
        r1 = design_column_moments(sway_dem, braced)
        @test !r1.sway_applied && r1.M1x == 50.2 && r1.M2x == 47.6

        # No story at all → unchanged.
        r2 = design_column_moments(sway_dem, nothing)
        @test !r2.sway_applied && r2.M1x == 50.2
    end

    # =========================================================================
    # Steel trait — AISC 360-16 App.8: Mr = B1·Mnt + B2·Mlt, Pr = Pnt + B2·Plt
    # =========================================================================
    @testset "Steel B1/B2 amplification (AISC App.8)" begin
        story = StoryStability(; ΣPu = 2000.0, V = 50.0, Δ = 0.36, L = 144.0,
                                 Pmf = 2000.0)              # B2 ≈ 1.13
        B2 = story_B2(story)
        # W14x132-ish: E=29000, I=1530, Lc=168 → Pe1≈15511.
        Pe1 = compute_Pe1(29000.0, 1530.0, 168.0)
        # Mnt=200, Mlt env=100, Pnt=500, Plt=50; Cm from M1x=0,M2x=200 → 0.6.
        demand = SS.MemberDemand(1; Pu_c = 500.0, Mux = 200.0, M1x = 0.0, M2x = 200.0,
                                 lt = LateralTranslation(; M1ltx = 0.0, M2ltx = 100.0,
                                                           Plt = 50.0))
        res = design_column_moments(demand, story, Pe1, Pe1)

        @test isapprox(res.B2, B2; atol = 1e-9)
        # B1 uses Pr = Pnt + Plt = 550 (first-order), Cm=0.6 → B1 clamps to 1.0.
        B1_expect = compute_B1(550.0, Pe1, 0.6)
        @test isapprox(res.B1x, B1_expect; atol = 1e-9)
        @test res.B1x == 1.0
        # Eq. A-8-1 and A-8-2.
        @test isapprox(res.Mrx, res.B1x * 200.0 + B2 * 100.0; atol = 1e-6)
        @test isapprox(res.Pr, 500.0 + B2 * 50.0; atol = 1e-6)
        @test res.sway_applied
    end

    @testset "Steel no-op contract (gravity-only / non-sway)" begin
        Pe1 = compute_Pe1(29000.0, 1530.0, 168.0)
        # No lt, braced story → B2=1, Mlt=Plt=0 → Mr = B1·Mnt, Pr = Pnt.
        braced = StoryStability(; ΣPu = 2000.0, V = 50.0, Δ = 0.001, L = 144.0)
        grav = SS.MemberDemand(1; Pu_c = 500.0, Mux = 200.0, M1x = 0.0, M2x = 200.0)
        res = design_column_moments(grav, braced, Pe1, Pe1)
        @test isapprox(res.B2, 1.0; atol = 1e-6)
        @test !res.sway_applied
        @test isapprox(res.Mrx, res.B1x * 200.0; atol = 1e-6)
        @test isapprox(res.Pr, 500.0; atol = 1e-9)

        # No story → B2 = 1 as well.
        res2 = design_column_moments(grav, nothing, Pe1, Pe1)
        @test isapprox(res2.B2, 1.0; atol = 1e-9) && !res2.sway_applied
    end
end
