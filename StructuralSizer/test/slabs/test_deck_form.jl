# HAND CHECK — AISI S100-16 §G2.1 web shear, and the Vulcraft gage tables.
#
# Web, no stiffener, kv = 5.34, E = 29,500 ksi, μ = 0.30
# (corpus: aisi-s100-16, PDF pp. 26, 114–116).
#
# Yield: h = 1 in, t = 0.06 in, Fy = 50 ksi.
#   Aw = 0.06 in², Vy = 0.6 × 0.06 × 50 = 1.8 kip.
#   h/t = 16.67, so Vcr is far above Vy and λv < 0.815. Vn = Vy.
#
# Elastic: h = 5 in, t = 0.05 in, Fy = 50 ksi. h/t = 100.
#   Fcr = π² × 29500 × 5.34 / (12 × 0.91 × 100²) = 14.2386 ksi
#   Vcr = 0.25 × 14.2386 = 3.5597 kip, Vy = 7.5 kip
#   λv = √(7.5 / 3.5597) = 1.452 > 1.227, so Vn = Vcr.
#
# Catalog: 1.5VL gage 20, Vn/Ω = 3207 lb/ft (PDF p. 80). Pitch is 6 in.
#   VD on one pitch = 3207 × 1.60 × (6/12) = 2565.6 lbf.
#   Ωv = 1.60 is AISI S100-16 §G2 where §B4 is met.
#
# Unshored spans, 1.5VL, total slab 6 in, 145 pcf (PDF p. 81):
#   1 span: gage 20 reaches 6 ft 3 in, gage 18 reaches 7 ft 2 in.
#   2 spans: gage 20 reaches 7 ft 3 in.

using Test
using Unitful
using StructuralSizer

@testset "Deck sheet: web shear and unshored gage" begin
    @testset "HAND CHECK AISI S100-16 §G2.1" begin
        yielded = aisi_web_shear(1.0u"inch", 0.06u"inch", 50.0u"ksi")
        @test yielded.branch === :yield
        @test yielded.λv < 0.815
        @test isapprox(yielded.Vn, 1.8u"kip"; rtol=1e-12)
        @test yielded.Ωv == 1.60
        @test yielded.ϕv == 0.95

        buckled = aisi_web_shear(5.0u"inch", 0.05u"inch", 50.0u"ksi")
        Fcr = (π^2 * 29500.0 * 5.34) / (12 * 0.91 * 100.0^2)
        Vcr = 0.25 * Fcr
        @test buckled.branch === :elastic
        @test isapprox(buckled.Vcr, Vcr * u"kip"; rtol=1e-12)
        @test isapprox(buckled.Vn, Vcr * u"kip"; rtol=1e-12)
        @test isapprox(buckled.λv, sqrt(7.5 / Vcr); rtol=1e-12)
    end

    @testset "HAND CHECK catalog web shear and one-way shear" begin
        p = composite_deck_profile("1.5VL")
        section = deck_gage_section(p, 20)
        @test section.Fy == 50.0u"ksi"
        @test isapprox(section.I_positive, 0.197u"inch^4/ft"; rtol=1e-12)
        @test isapprox(section.Mn_positive_over_Ω, 559.0u"lbf"; rtol=1e-12)
        @test isapprox(section.Vn_over_Ω, 3207.0u"lbf/ft"; rtol=1e-12)
        VD = deck_pitch_nominal_web_shear(p, 20)
        @test isapprox(VD, 2565.6u"lbf"; rtol=1e-12)

        # 2VLI gage 20, pitch 12 in: VD = 2419 × 1.60 lbf on one pitch.
        p2 = composite_deck_profile("2VLI")
        @test isapprox(deck_pitch_nominal_web_shear(p2, 20), 2419.0 * 1.60 * u"lbf"; rtol=1e-12)
        sh = deck_one_way_shear(p2, 20, 3.0u"inch", 4000.0u"psi", 145.0u"lb/ft^3")
        @test sh.deck_webs_included == true
        @test sh.governing === :section
        bare = deck_one_way_shear(4000.0u"psi", sh.Ac, 145.0u"lb/ft^3")
        @test sh.capacity > bare.capacity

        # 1.5VL gage 20 on 3 in topping: the webs push φVn onto the cap.
        sh15 = deck_one_way_shear(p, 20, 3.0u"inch", 4000.0u"psi", 145.0u"lb/ft^3")
        @test sh15.governing === :upper_bound
        @test_throws ArgumentError deck_gage_section(p, 14)
    end

    @testset "HAND CHECK unshored gage, 1.5VL at 6 in" begin
        # 7 ft exceeds gage 20's 6 ft 3 in single span and fits gage 18.
        one = select_unshored_deck_gage("1.5VL", 6.0u"inch", 7.0u"ft", 1)
        @test one.ok
        @test one.gage == 18
        @test isapprox(one.span_limit, (7 * 12 + 2) * u"inch"; rtol=1e-12)
        @test one.web_crippling_checked == false
        @test isapprox(one.topping, 4.5u"inch"; rtol=1e-12)
        # Two spans: gage 20 reaches 7 ft 3 in.
        two = select_unshored_deck_gage("1.5VLI", 6.0u"inch", 7.0u"ft", 2)
        @test two.ok
        @test two.gage == 20
        # Past the heaviest gage.
        over = select_unshored_deck_gage("1.5VL", 6.0u"inch", 8.0u"ft", 1)
        @test over.ok == false
        @test over.gage === nothing
        @test isapprox(over.span_limit, (7 * 12 + 10) * u"inch"; rtol=1e-12)
        @test_throws ArgumentError select_unshored_deck_gage(
            "1.5VL", 6.25u"inch", 6.0u"ft", 1)
        @test_throws ArgumentError select_unshored_deck_gage(
            "1.5VL", 6.0u"inch", 6.0u"ft", 1; concrete_density=110.0u"lb/ft^3")
        @test_throws ArgumentError select_unshored_deck_gage("1.5VL", 6.0u"inch", 6.0u"ft", 4)
    end

    @testset "HAND CHECK web crippling and composite slab" begin
        # 1.5VL gage 20, one-flange end, 2 in bearing: 1263 lb/ft (PDF p. 80).
        cap = deck_web_crippling("1.5VL", 20; flanges=:one, location=:end, bearing=2.0u"inch")
        @test isapprox(cap, 1263.0u"lbf/ft"; rtol=1e-12)
        # 3VLI gage 16, two-flange interior, 8 in bearing: 4474 lb/ft (PDF p. 92).
        @test isapprox(
            deck_web_crippling("3VLI", 16; flanges=:two, location=:interior, bearing=8.0u"inch"),
            4474.0u"lbf/ft"; rtol=1e-12)
        @test_throws ArgumentError deck_web_crippling(
            "1.5VL", 20; flanges=:one, location=:end, bearing=2.5u"inch")

        # 7 ft single span at 6 in total needs 18 gage on span alone.
        # At 2 in one-flange end bearing, 18 gage carries 2105 lb/ft and 16 gage carries 3212.
        held = select_unshored_deck_gage("1.5VL", 6.0u"inch", 7.0u"ft", 1;
            bearing_length=2.0u"inch", flanges=:one, end_reaction=2500.0u"lbf/ft")
        @test held.ok
        @test held.gage == 16
        @test held.web_crippling_checked
        @test held.reason === :ok
        @test isapprox(held.end_Rn_over_Ω, 3212.0u"lbf/ft"; rtol=1e-12)
        @test held.interior_Rn_over_Ω === nothing
        # Two spans, 3 in bearing. Gage 20's interior reaction is 2127 lb/ft.
        # 2200 lb/ft moves the selection to gage 19.
        two = select_unshored_deck_gage("1.5VL", 6.0u"inch", 7.0u"ft", 2;
            bearing_length=3.0u"inch", flanges=:one,
            end_reaction=500.0u"lbf/ft", interior_reaction=2200.0u"lbf/ft")
        @test two.gage == 19
        @test isapprox(two.interior_Rn_over_Ω, 2839.0u"lbf/ft"; rtol=1e-12)
        over = select_unshored_deck_gage("1.5VL", 6.0u"inch", 7.0u"ft", 1;
            bearing_length=2.0u"inch", flanges=:one, end_reaction=4000.0u"lbf/ft")
        @test over.ok == false
        @test over.reason === :bearing
        @test_throws ArgumentError select_unshored_deck_gage("1.5VL", 6.0u"inch", 7.0u"ft", 1;
            bearing_length=2.0u"inch", flanges=:one,
            end_reaction=500.0u"lbf/ft", interior_reaction=500.0u"lbf/ft")

        # 2VLI, total 4 in, gage 20 (PDF p. 89): Mno/Ω = 2.86 kip-ft/ft, Vno/Ω = 3.07 kip/ft.
        slab = composite_slab_catalog("2VLI", 4.0u"inch", 20)
        @test isapprox(slab.topping, 2.0u"inch"; rtol=1e-12)
        @test isapprox(slab.Mno_over_Ω, 2.86u"kip"; rtol=1e-12)
        @test isapprox(slab.Vno_over_Ω, 3.07u"kip/ft"; rtol=1e-12)
        # Figure 2-1 on that 2 in topping, pitch 12 in, does not clip:
        # Ac = (5 + 9) / 2 × 4 = 28 in². With VD from gage 20 the cap governs.
        # φVn = 0.75 × 4 × √4000 × 28 lbf on the pitch, which is one foot.
        report = deck_slab_shear_report("2VLI", 4.0u"inch", 20, 4000.0u"psi", 145.0u"lb/ft^3")
        @test report.catalog_design === :asd
        @test report.computed_design === :lrfd
        @test isapprox(report.catalog_V_over_Ω, 3.07u"kip/ft"; rtol=1e-12)
        @test isapprox(report.computed.Ac, 28.0u"inch^2"; rtol=1e-9)
        @test isapprox(report.ϕVn_per_length,
                       0.75 * 4 * sqrt(4000.0) * 28.0 * u"lbf/ft"; rtol=1e-9)
        deep = composite_slab_catalog("3VLI", 7.5u"inch", 16)
        @test isapprox(deep.Mno_over_Ω, 10.12u"kip"; rtol=1e-12)
        @test isapprox(deep.Vno_over_Ω, 6.47u"kip/ft"; rtol=1e-12)
    end
end
