using StructuralSizer
using Test
using Unitful

# ACI 318-19 Table 25.3.1 and Table 25.3.2 (corpus: aci-318-19, printed pp. 469–470).
@testset "Bar detailing" begin
    inch(q) = ustrip(u"inch", q)

    @testset "Tension hooks, Table 25.3.1" begin
        h5 = standard_hook(5; angle=90)
        @test inch(h5.inside_diameter) ≈ 6 * 0.625
        @test inch(h5.extension) ≈ 12 * 0.625

        h9 = standard_hook(9; angle=90)
        @test inch(h9.inside_diameter) ≈ 8 * 1.128
        @test inch(h9.extension) ≈ 12 * 1.128

        h14 = standard_hook(14; angle=180)
        @test inch(h14.inside_diameter) ≈ 10 * 1.693
        @test inch(h14.extension) ≈ max(4 * 1.693, 2.5)

        h3 = standard_hook(3; angle=180)
        @test inch(h3.extension) ≈ 2.5
        @test_throws ArgumentError standard_hook(5; angle=135)
    end

    @testset "Stirrup hooks, Table 25.3.2" begin
        s4 = standard_hook(4; angle=90, role=:stirrup)
        @test inch(s4.inside_diameter) ≈ 4 * 0.5
        @test inch(s4.extension) ≈ 3.0

        s6 = standard_hook(6; angle=90, role=:stirrup)
        @test inch(s6.inside_diameter) ≈ 6 * 0.75
        @test inch(s6.extension) ≈ 12 * 0.75

        s6_135 = standard_hook(6; angle=135, role=:stirrup)
        @test inch(s6_135.extension) ≈ max(6 * 0.75, 3.0)

        s8 = standard_hook(8; angle=180, role=:stirrup)
        @test inch(s8.extension) ≈ max(4 * 1.0, 2.5)
        @test_throws ArgumentError standard_hook(9; angle=90, role=:stirrup)
    end

    @testset "Hook centerline and bar-set mass" begin
        db = 0.625u"inch"
        hook = standard_hook(5; angle=90)
        arc = (π / 2) * (hook.inside_diameter + db) / 2
        @test hook_centerline_length(5; angle=90) ≈ arc + hook.extension

        # #8 is 2.670 lb/ft in the catalog. Four bars, 10 ft each.
        set = BarSet(8, 4, 10.0u"ft")
        @test bar_set_mass(set) ≈ uconvert(u"kg", 4 * 2.670u"lb/ft" * 10.0u"ft")
        @test bar_set_ec(set, 1.0u"kgCO2e/kg") ≈ bar_set_mass(set) * 1.0u"kgCO2e/kg"
    end

    # ACI 318-19 §25.4 and §25.5 (corpus: aci-318-19, printed pp. 471–492).
    @testset "Development length and lap splices" begin
        fc = 4000u"psi"
        fy = 60u"ksi"
        s = sqrt(4000)
        # Table 25.4.2.3, other cases, No. 6 and smaller: 3 fy / (50 λ √f′c) · db
        ld5 = (3 * 60_000) / (50 * s) * 0.625
        @test inch(straight_development_length(5, fc, fy)) ≈ ld5
        # First row of the table: fy / (25 λ √f′c) · db
        @test inch(straight_development_length(5, fc, fy; favorable_cover=true)) ≈
              (60_000) / (25 * s) * 0.625
        # No. 7 and larger, other cases: 3 fy / (40 λ √f′c) · db
        @test inch(straight_development_length(8, fc, fy)) ≈ (3 * 60_000) / (40 * s) * 1.0
        # ψt = 1.3. ψt·ψe is not taken above 1.7, so top epoxy-close is 1.7, not 1.95.
        @test inch(straight_development_length(5, fc, fy; ψt=1.3)) ≈ 1.3 * ld5
        @test inch(straight_development_length(
            5, fc, fy; ψt=1.3, coating=:epoxy, epoxy_close=true)) ≈ 1.7 * ld5
        # ψe: epoxy 1.2, close cover or spacing 1.5, galvanized 1.0.
        @test inch(straight_development_length(5, fc, fy; coating=:epoxy)) ≈ 1.2 * ld5
        @test inch(straight_development_length(5, fc, fy; coating=:zinc_epoxy, epoxy_close=true)) ≈
              1.5 * ld5
        @test inch(straight_development_length(5, fc, fy; coating=:galvanized, epoxy_close=true)) ≈ ld5
        @test_throws ArgumentError straight_development_length(5, fc, fy; coating=:paint)
        # §25.4.1.4: √f′c used in the length is not above 100 psi.
        @test inch(straight_development_length(5, 16_000u"psi", fy)) ≈
              (3 * 60_000) / (50 * 100) * 0.625
        # Grade 80 ψg = 1.15. Grade 75 is not a table row; ψg = 1.0 by project
        # decision, so ℓd is 1.25 times the Grade 60 length.
        @test inch(straight_development_length(5, fc, 80u"ksi")) ≈
              (3 * 80_000 * 1.15) / (50 * s) * 0.625
        @test inch(straight_development_length(5, fc, 75u"ksi")) ≈ 1.25 * ld5
        @test_throws ArgumentError straight_development_length(5, fc, 70u"ksi")
        @test_throws ArgumentError straight_development_length(5, fc, fy, 0.85)
        # §25.4.2.1(b): calculated 9 in. (No. 3, favorable, √f′c = 100) becomes 12 in.
        # §25.4.10.1 does not go below that floor.
        @test inch(straight_development_length(3, 10_000u"psi", fy; favorable_cover=true)) ≈ 12
        @test inch(straight_development_length(
            3, 10_000u"psi", fy; favorable_cover=true, excess=0.5)) ≈ 12
        @test inch(straight_development_length(5, fc, fy; excess=0.5)) ≈ 0.5 * ld5

        # §25.4.3.1. Unconfined, no side cover: ψr = 1.6, ψo = 1.25, ψc = fc/15000+0.6.
        ψc = 4000 / 15_000 + 0.6
        # Eq. 25.4.3.1(a) uses d_b^1.5.
        ldh = (60_000 * 1.6 * 1.25 * ψc) / (55 * s) * 0.625^1.5
        @test inch(hooked_bar_development_length(5, fc, fy)) ≈ ldh
        @test inch(hooked_bar_development_length(5, fc, fy)) ≈ 14.77 atol=0.01  # hand calc
        @test inch(hooked_bar_development_length(5, fc, fy; confined=true, side_cover=true)) ≈
              (60_000 * ψc) / (55 * s) * 0.625^1.5
        # No. 14 stays on the "other" row of Table 25.4.3.2 even when the flags are set.
        db14 = 1.693
        @test inch(hooked_bar_development_length(14, fc, fy; confined=true, side_cover=true)) ≈
              (60_000 * 1.6 * 1.25 * ψc) / (55 * s) * db14^1.5
        # ψc is 1.0 at 6000 psi. Hooked epoxy is 1.2 regardless of cover.
        @test inch(hooked_bar_development_length(5, 6000u"psi", fy; coating=:zinc_epoxy)) ≈
              (60_000 * 1.2 * 1.6 * 1.25 * 1.0) / (55 * sqrt(6000)) * 0.625^1.5

        # §25.4.9. The 0.0003 fy db term is 18 in.; the bond term is longer.
        bond = (60_000) / (50 * s) * 1.0
        @test inch(compression_development_length(8, fc, fy)) ≈ bond
        @test inch(compression_development_length(8, fc, fy; enclosed=true)) ≈ 0.75 * bond
        @test inch(compression_development_length(8, fc, fy; excess=0.5)) ≈ max(0.5 * bond, 8.0)

        # Table 25.5.2.1. ℓd is the calculated length, then the splice floor is 12 in.
        @test inch(tension_lap_length(5, fc, fy; as_ratio=2, percent_spliced=50)) ≈ ld5
        @test inch(tension_lap_length(5, fc, fy; as_ratio=2, percent_spliced=51)) ≈ 1.3 * ld5
        @test inch(tension_lap_length(5, fc, fy; as_ratio=1.5, percent_spliced=50)) ≈ 1.3 * ld5
        @test_throws ArgumentError tension_lap_length(14, fc, fy; as_ratio=2, percent_spliced=50)

        # §25.5.5.1. fy = 60 ksi uses 0.0005 fy db, not the Grade 80 expression.
        @test inch(compression_lap_length(8, fc, fy)) ≈ 0.0005 * 60_000 * 1.0
        @test inch(compression_lap_length(8, fc, 80u"ksi")) ≈ (0.0009 * 80_000 - 24) * 1.0
        @test inch(compression_lap_length(8, 2500u"psi", fy)) ≈ (4 / 3) * 0.0005 * 60_000
        # fy > 80 ksi: longer of (0.0009 fy − 24) db and the Class B tension lap.
        ld8 = (3 * 100_000 * 1.3) / (40 * s) * 1.0
        @test inch(compression_lap_length(8, fc, 100u"ksi")) ≈
              max((0.0009 * 100_000 - 24) * 1.0, 1.3 * ld8)
        @test_throws ArgumentError compression_lap_length(14, fc, fy)
    end

    @testset "Rebar coating is a material property" begin
        @test Rebar_60.coating === :uncoated
        @test A992_Steel.coating === :uncoated
        epoxy = with_coating(Rebar_60, :epoxy)
        @test epoxy.coating === :epoxy
        @test epoxy.Fy == Rebar_60.Fy && epoxy.ecc == Rebar_60.ecc
        @test is_epoxy_coated(epoxy.coating)
        @test !is_epoxy_coated(:galvanized)
        @test material_name(Rebar_60) == "Gr60"
        @test material_name(epoxy) == "Rebar (Fy=60 ksi, epoxy)"
        @test_throws ArgumentError with_coating(Rebar_60, :paint)
        fc, fy = 4000u"psi", epoxy.Fy
        @test straight_development_length(5, fc, fy; coating=epoxy.coating) ≈
              1.2 * straight_development_length(5, fc, fy)
    end
end
