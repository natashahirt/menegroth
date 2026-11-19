# =============================================================================
# Tests for RC T-Beam Section, Flexure, and Checker
# =============================================================================
# Validates:
#   1. RCTBeamSection construction and properties
#   2. Effective flange width (ACI 318-19 Table 6.3.2.1)
#   3. φMn with stress block in flange (rectangular behavior)
#   4. φMn with stress block in web (true T-beam decomposition)
#   5. Shear uses bw (web width)
#   6. Minimum reinforcement uses bw
#   7. T-beam catalog generation
#   8. Checker integration (precompute + is_feasible)
#   9. Asap section conversion
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using StructuralSizer
using Asap: kip, ksi

# =============================================================================
# HAND-CALCULATED REFERENCE DATA
# =============================================================================
#
# Case 1 — Stress block in flange:
#   bw=12", h=24", bf=48", hf=5", 3 #9 bars
#   f'c = 4000 psi, fy = 60000 psi
#   d = 24 − 1.5 − 0.375 − 1.128/2 = 21.561 in
#   a = 3.00 × 60000 / (0.85 × 4000 × 48) = 1.1029 in  (< hf=5 ✓)
#   c = 1.1029 / 0.85 = 1.2976 in
#   εt = 0.003 × (21.561 − 1.2976) / 1.2976 = 0.04685
#   φ = 0.90 (tension controlled)
#   Mn = 3.00 × 60000 × (21.561 − 0.5515) = 3,781,715 lb·in
#   φMn = 0.90 × 3,781,715 / 12000 = 283.6 kip·ft
#
# Case 2 — Stress block in web (true T-beam):
#   bw=14", h=20", bf=22", hf=3", 4 #9 bars
#   f'c = 3000 psi, fy = 60000 psi
#   d = 20 − 1.5 − 0.375 − 1.128/2 = 17.561 in
#   a_trial = 4.00 × 60000 / (0.85 × 3000 × 22) = 4.278 in  (> hf=3 ✓)
#   Cf = 0.85 × 3000 × (22−14) × 3 = 61200 lb
#   Cw = 240000 − 61200 = 178800 lb
#   a = 178800 / (0.85 × 3000 × 14) = 5.008 in
#   c = 5.008 / 0.85 = 5.892 in
#   εt = 0.003 × (17.561 − 5.892) / 5.892 = 0.005940
#   φ = 0.90 (tension controlled)
#   Mn = 61200 × 16.061 + 178800 × 15.057 = 3,675,089 lb·in
#   φMn = 0.90 × 3,675,089 / 12000 = 275.6 kip·ft
#
# =============================================================================

@testset "RC T-Beam" begin

    # =================================================================
    # §1  Section Construction
    # =================================================================
    @testset "RCTBeamSection construction" begin
        sec = RCTBeamSection(
            bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
            bar_size=9, n_bars=3,
        )

        @test ustrip(u"inch", sec.bw) ≈ 12.0
        @test ustrip(u"inch", sec.h)  ≈ 24.0
        @test ustrip(u"inch", sec.bf) ≈ 48.0
        @test ustrip(u"inch", sec.hf) ≈ 5.0
        @test ustrip(u"inch", sec.d)  ≈ 21.561 rtol=0.01
        @test ustrip(u"inch^2", sec.As) ≈ 3.00 rtol=0.001

        # Auto-name
        @test sec.name == "T12x24-bf48-3#9"

        # No compression steel
        @test sec.n_bars_prime == 0
        @test !is_doubly_reinforced(sec)
    end

    @testset "RCTBeamSection validation" begin
        # bf < bw should throw
        @test_throws ArgumentError RCTBeamSection(
            bw=24u"inch", h=24u"inch", bf=12u"inch", hf=5u"inch",
            bar_size=9, n_bars=3,
        )

        # A flange that is the web, added to a zero length in metres, converts
        # a few ulps under 12 in and 24 in. That is still the web.
        for bw in (12.0u"inch", 24.0u"inch")
            sec_web = RCTBeamSection(
                bw = bw, h = 30u"inch", bf = bw + 0.0u"m", hf = 2.5u"inch",
                bar_size = 5, n_bars = 2,
            )
            @test sec_web.bf == sec_web.bw
        end

        # hf ≥ h should throw
        @test_throws ArgumentError RCTBeamSection(
            bw=12u"inch", h=24u"inch", bf=48u"inch", hf=24u"inch",
            bar_size=9, n_bars=3,
        )
    end

    # =================================================================
    # §2  Section Interface
    # =================================================================
    @testset "Section interface" begin
        sec = RCTBeamSection(
            bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
            bar_size=9, n_bars=3,
        )

        # Ag = bf × hf + bw × (h − hf) = 48×5 + 12×19 = 240 + 228 = 468
        Ag = section_area(sec)
        @test ustrip(u"inch^2", Ag) ≈ 468.0

        @test section_depth(sec) == sec.h
        @test section_width(sec) == sec.bw
        @test flange_width(sec) == sec.bf
        @test flange_thickness(sec) == sec.hf

        ρ = rho(sec)
        @test 0.005 < ρ < 0.05  # sanity
    end

    # =================================================================
    # §3  Gross Section Properties
    # =================================================================
    @testset "Gross section properties (T-shape)" begin
        sec = RCTBeamSection(
            bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
            bar_size=9, n_bars=3,
        )

        # Centroid from top:
        # Af = 48×5 = 240, Aw = 12×19 = 228, Ag = 468
        # ȳ = (240×2.5 + 228×14.5) / 468 = (600 + 3306) / 468 = 8.346 in
        ȳ = gross_centroid_from_top(sec)
        @test ustrip(u"inch", ȳ) ≈ 8.346 rtol=0.01

        Ig = gross_moment_of_inertia(sec)
        # Ig_f = 48×5³/12 + 240×(8.346−2.5)² = 500 + 240×34.218 = 500 + 8212 = 8712
        # Ig_w = 12×19³/12 + 228×(14.5−8.346)² = 6859 + 228×37.894 = 6859 + 8640 = 15499
        # Ig = 8712 + 15499 = 24211 in⁴
        @test ustrip(u"inch^4", Ig) ≈ 24211 rtol=0.02

        Sb = section_modulus_bottom(sec)
        yb = 24.0 - 8.346
        @test ustrip(u"inch^3", Sb) ≈ ustrip(u"inch^4", Ig) / yb rtol=0.01
    end

    # =================================================================
    # §4  Effective Flange Width (ACI 318-19 Table 6.3.2.1)
    # =================================================================
    @testset "Effective flange width" begin
        @testset "Interior beam" begin
            # Each side: min(8×5, 48/2, 240/8) = min(40, 24, 30) = 24
            # bf = 12 + 2×24 = 60 in
            bf = effective_flange_width(
                bw=12u"inch", hf=5u"inch", sw=48u"inch", ln=240u"inch",
                position=:interior,
            )
            @test ustrip(u"inch", bf) ≈ 60.0
        end

        @testset "Edge beam" begin
            # Overhang: min(6×5, 48/2, 240/12) = min(30, 24, 20) = 20
            # bf = 12 + 20 = 32 in
            bf = effective_flange_width(
                bw=12u"inch", hf=5u"inch", sw=48u"inch", ln=240u"inch",
                position=:edge,
            )
            @test ustrip(u"inch", bf) ≈ 32.0
        end

        @testset "Edge cases" begin
            # Very short span governs ln/8
            bf = effective_flange_width(
                bw=12u"inch", hf=6u"inch", sw=60u"inch", ln=96u"inch",
                position=:interior,
            )
            # Each side: min(48, 30, 12) = 12
            @test ustrip(u"inch", bf) ≈ 36.0

            # Invalid position
            @test_throws ErrorException effective_flange_width(
                bw=12u"inch", hf=5u"inch", sw=48u"inch", ln=240u"inch",
                position=:invalid,
            )
        end
    end

    # =================================================================
    # §5  φMn — Stress Block in Flange (Case 1)
    # =================================================================
    @testset "φMn — stress block in flange" begin
        sec = RCTBeamSection(
            bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
            bar_size=9, n_bars=3,
        )

        fc_psi = 4000.0
        fy_psi = 60000.0

        φMn = StructuralSizer._compute_φMn(sec, fc_psi, fy_psi)
        @test φMn ≈ 283.6 rtol=0.01

        εt = StructuralSizer._compute_εt(sec, fc_psi, fy_psi)
        @test εt > 0.005  # tension controlled
        @test εt ≈ 0.04685 rtol=0.02
    end

    # =================================================================
    # §6  φMn — Stress Block in Web (Case 2, True T-beam)
    # =================================================================
    @testset "φMn — stress block in web" begin
        sec = RCTBeamSection(
            bw=14u"inch", h=20u"inch", bf=22u"inch", hf=3u"inch",
            bar_size=9, n_bars=4,
        )

        fc_psi = 3000.0
        fy_psi = 60000.0

        φMn = StructuralSizer._compute_φMn(sec, fc_psi, fy_psi)
        @test φMn ≈ 275.6 rtol=0.01

        εt = StructuralSizer._compute_εt(sec, fc_psi, fy_psi)
        @test εt ≈ 0.00594 rtol=0.02
        @test εt > 0.005  # still tension controlled
    end

    # =================================================================
    # §7  Shear Uses bw (Not bf)
    # =================================================================
    @testset "Shear capacity uses bw" begin
        sec = RCTBeamSection(
            bw=14u"inch", h=20u"inch", bf=22u"inch", hf=3u"inch",
            bar_size=9, n_bars=4,
        )

        fc_psi = 3000.0
        φVn = StructuralSizer._compute_φVn_max(sec, fc_psi, 1.0)

        # Vc = 2×1.0×√3000×14×17.561 = 26929 lb
        # Vs_max = 4×Vc = 107716 lb
        # φVn = 0.75 × (26929 + 107716) / 1000 = 100.98 kip
        @test φVn ≈ 100.98 rtol=0.02
    end

    # =================================================================
    # §8  Minimum Reinforcement Uses bw
    # =================================================================
    @testset "Minimum reinforcement uses bw" begin
        bw = 14u"inch"
        d  = 17.561u"inch"
        fc = 3000.0u"psi"
        fy = 60000.0u"psi"

        As_min = beam_min_reinforcement(bw, d, fc, fy)
        # As_min_a = 3×√3000×14×17.561/60000 = 0.673 in²
        # As_min_b = 200×14×17.561/60000 = 0.820 in² (governs)
        @test ustrip(u"inch^2", As_min) ≈ 0.820 rtol=0.02
    end

    # =================================================================
    # §9  T-Beam Degrades to Rectangular When bf = bw
    # =================================================================
    @testset "Degrades to rectangular when bf = bw" begin
        sec_t = RCTBeamSection(
            bw=12u"inch", h=24u"inch", bf=12u"inch", hf=5u"inch",
            bar_size=9, n_bars=3,
        )
        sec_r = RCBeamSection(
            b=12u"inch", h=24u"inch",
            bar_size=9, n_bars=3,
        )

        fc_psi = 4000.0
        fy_psi = 60000.0

        φMn_t = StructuralSizer._compute_φMn(sec_t, fc_psi, fy_psi)
        φMn_r = StructuralSizer._compute_φMn(sec_r, fc_psi, fy_psi)
        @test φMn_t ≈ φMn_r rtol=0.001

        εt_t = StructuralSizer._compute_εt(sec_t, fc_psi, fy_psi)
        εt_r = StructuralSizer._compute_εt(sec_r, fc_psi, fy_psi)
        @test εt_t ≈ εt_r rtol=0.001
    end

    # =================================================================
    # §10  T-Beam Catalog
    # =================================================================
    @testset "T-beam catalog generation" begin
        cat = standard_rc_tbeams(
            flange_width = 48u"inch",
            flange_thickness = 5u"inch",
            web_widths = [12, 14],
            depths = [20, 24],
            bar_sizes = [8, 9],
            n_bars_range = 2:4,
        )
        @test length(cat) > 0
        @test all(s -> s isa RCTBeamSection, cat)
        @test all(s -> ustrip(u"inch", s.bf) ≈ 48.0, cat)
        @test all(s -> ustrip(u"inch", s.hf) ≈ 5.0, cat)

        # The building caller passes bf as a function of the candidate web.
        per_web = standard_rc_tbeams(
            flange_width = bw -> 4 * bw,
            flange_thickness = 5u"inch",
            web_widths = [12, 16],
            depths = [20],
            bar_sizes = [8],
            n_bars_range = 2:2,
        )
        @test length(per_web) > 0
        @test all(s -> ustrip(u"inch", s.bf) ≈ 4 * ustrip(u"inch", s.bw), per_web)
        wider_than_flange = standard_rc_tbeams(
            flange_width = _ -> 10u"inch",
            flange_thickness = 5u"inch",
            web_widths = [12],
            depths = [20],
            bar_sizes = [8],
            n_bars_range = 2:2,
        )
        @test isempty(wider_than_flange)
    end

    # =================================================================
    # §11  Checker Integration (precompute + feasibility)
    # =================================================================
    @testset "ACIBeamChecker with T-beam" begin
        # Create a small catalog of T-beams
        cat = standard_rc_tbeams(
            flange_width = 48u"inch",
            flange_thickness = 5u"inch",
            web_widths = [12, 14],
            depths = [20, 24],
            bar_sizes = [8, 9],
            n_bars_range = 2:4,
        )

        checker = ACIBeamChecker(fy_ksi=60.0, fyt_ksi=60.0)
        mat = NWC_4000
        cache = StructuralSizer.create_cache(checker, length(cat))

        # Precompute should work without errors
        StructuralSizer.precompute_capacities!(
            checker, cache, cat, mat, MinVolume(),
        )

        # All capacities should be positive
        @test all(cache.φMn .> 0)
        @test all(cache.φVn_max .> 0)
        @test all(cache.εt .> 0)

        # Feasibility check with moderate demand
        demand = RCBeamDemand(1; Mu=100.0kip*u"ft", Vu=20.0kip)
        geom = ConcreteMemberGeometry(20.0u"ft")

        # At least some sections should be feasible for this moderate demand
        feasible_count = sum(
            StructuralSizer.is_feasible(checker, cache, j, cat[j], mat, demand, geom)
            for j in 1:length(cat)
        )
        @test feasible_count > 0
    end

    # =================================================================
    # §12  Asap Section Conversion
    # =================================================================
    @testset "to_asap_section for T-beam" begin
        sec = RCTBeamSection(
            bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
            bar_size=9, n_bars=3,
        )
        mat = NWC_4000

        asap_sec = to_asap_section(sec, mat)
        @test asap_sec !== nothing

        # T-shape area > rectangular web area
        A_web = 12 * 24 * (0.0254)^2  # m²
        @test asap_sec.A > A_web * u"m^2"
    end

    @testset "T-beam weighs only its stem; the flange is the slab" begin
        sec = RCTBeamSection(
            bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
            bar_size=9, n_bars=3,
        )
        mat = NWC_4000
        stem = 12u"inch" * (24u"inch" - 5u"inch")
        @test self_weight_area(sec) ≈ stem
        @test section_area(sec) ≈ stem + 48u"inch" * 5u"inch"

        # Asap frame self-weight is ρ·A·g: it must equal the stem's weight.
        asap_sec = to_asap_section(sec, mat)
        @test asap_sec.ρ * asap_sec.A ≈ uconvert(u"kg/m", mat.ρ * stem)
        @test asap_sec.A ≈ uconvert(u"m^2", section_area(sec))

        rect = RCBeamSection(b=12u"inch", h=24u"inch", bar_size=9, n_bars=3)
        @test self_weight_area(rect) == section_area(rect)
    end

end

@testset "§10.5.3 waives As,min when the bars already exceed the analysis steel" begin
    # A deep web with two #5 bars is under §10.5.1. A small moment needs far
    # less than three-quarters of that steel, so §10.5.3 (ACI 318-11 p. 145)
    # passes the section. A moment that needs more than that does not.
    sec = RCTBeamSection(bw = 12u"inch", h = 24u"inch", bf = 48u"inch", hf = 5u"inch",
                         bar_size = 5, n_bars = 2)
    opts = ConcreteBeamOptions(material = NWC_4000, rebar_material = Rebar_60)
    geom = ConcreteMemberGeometry(20.0u"ft")
    light = StructuralSizer.check_tbeam_section(sec, 10.0u"kip*ft", 2.0u"kip", geom, opts;
                                               Mu_neg = 0.0u"kip*ft")
    minr = only(c for c in light.checks if c.name == "min_reinforcement")
    @test minr.passed
    @test minr.code_clause == "ACI 318-11 10.5.3"
    heavy = StructuralSizer.check_tbeam_section(sec, 80.0u"kip*ft", 2.0u"kip", geom, opts;
                                               Mu_neg = 0.0u"kip*ft")
    minr = only(c for c in heavy.checks if c.name == "min_reinforcement")
    @test !minr.passed
    @test minr.code_clause == "ACI 318-11 10.5.1"
end

println("\n✓ RC T-Beam tests passed")
