# HAND CHECK — SDI C-2017 one-way shear of a composite deck-slab.
#
# Not a published example. The area is Figure 2-1 (corpus: sdi-c-2017,
# PDF p. 14): concrete between the rib webs, webs extended through the
# topping at the same slope, width cut off at the pitch. The strength is
# §2.4.B.9 Eq. 2.4.7a and Eq. 2.4.8a (PDF p. 13).
#
# 2VLI, 3 in topping, no overlap (extended width 10 in < pitch 12 in):
#   Ac = (5 + 10) / 2 * 5 = 37.5 in² per pitch.
# 3VLI, 3 in topping (extended width 9.75 in):
#   Ac = (4.75 + 9.75) / 2 * 6 = 43.5 in².
# 1.5VL, 3 in topping (extended width 4.625 in < pitch 6 in):
#   Ac = (1.625 + 4.625) / 2 * 4.5 = 14.0625 in².
# Overlap: hr 2, bottom 5, top 7, pitch 12, topping 6.
#   Width hits 12 in at 7 in above the rib bottom.
#   Ac = (5 + 12) / 2 * 7 + 12 * 1 = 71.5 in².
#
# f′c = 4000 psi, Ac = 37.5 in², λ = 1, VD = 0:
#   Vc = 2 √4000 * 37.5 lbf
#   φVn = 0.75 Vc, and the λ-free cap is 0.75 * 4 √4000 * 37.5 lbf.

using Test
using Unitful
using StructuralSizer

@testset "SDI C-2017 composite deck one-way shear" begin
    @testset "HAND CHECK Figure 2-1 concrete area" begin
        p2 = composite_deck_profile("2VLI")
        p3 = composite_deck_profile("3VLI")
        p15 = composite_deck_profile("1.5VL")
        @test isapprox(deck_shear_concrete_area(p2, 3.0u"inch"), 37.5u"inch^2"; rtol=1e-9)
        @test isapprox(deck_shear_concrete_area(p3, 3.0u"inch"), 43.5u"inch^2"; rtol=1e-9)
        @test isapprox(deck_shear_concrete_area(p15, 3.0u"inch"), 14.0625u"inch^2"; rtol=1e-9)
        # Vertical webs keep the rib-top width. No flare, no overlap.
        @test isapprox(
            deck_shear_concrete_area(2.0u"inch", 4.0u"inch", 4.0u"inch", 12.0u"inch", 3.0u"inch"),
            20.0u"inch^2"; rtol=1e-12)
        # Topping deep enough that the extended webs pass the pitch.
        @test isapprox(
            deck_shear_concrete_area(2.0u"inch", 7.0u"inch", 5.0u"inch", 12.0u"inch", 6.0u"inch"),
            71.5u"inch^2"; rtol=1e-12)
        @test_throws ArgumentError deck_shear_concrete_area(
            0.0u"inch", 7.0u"inch", 5.0u"inch", 12.0u"inch", 3.0u"inch")
    end

    @testset "HAND CHECK Eq. 2.4.7 and Eq. 2.4.8" begin
        fc = 4000.0u"psi"
        Ac = 37.5u"inch^2"
        √fc = sqrt(4000.0)
        Vc = 2 * √fc * 37.5
        nwc = deck_one_way_shear(fc, Ac, 145.0u"lb/ft^3")
        @test nwc.λ == 1.0
        @test nwc.governing === :section
        @test nwc.deck_webs_included == false
        @test isapprox(nwc.Vc, Vc * u"lbf"; rtol=1e-12)
        @test isapprox(nwc.capacity, 0.75 * Vc * u"lbf"; rtol=1e-12)
        # Density of 130 lb/ft³ does not exceed the threshold: λ = 0.75.
        # The upper bound has no λ.
        light = deck_one_way_shear(fc, Ac, 130.0u"lb/ft^3")
        @test light.λ == 0.75
        @test deck_shear_lambda(130.0u"lb/ft^3" + 0.1u"lb/ft^3") == 1.0
        @test isapprox(light.Vc, 0.75 * Vc * u"lbf"; rtol=1e-12)
        @test isapprox(light.upper_bound, nwc.upper_bound; rtol=1e-12)
        @test isapprox(light.capacity, 0.75 * 0.75 * Vc * u"lbf"; rtol=1e-12)
        # Deck-web shear large enough to hit the cap. Cap = φv * 4 √f′c Ac.
        capped = deck_one_way_shear(fc, 10.0u"inch^2", 145.0u"lb/ft^3"; VD=10.0u"kip")
        @test capped.governing === :upper_bound
        @test capped.deck_webs_included == true
        @test isapprox(capped.capacity, 0.75 * 4 * √fc * 10.0 * u"lbf"; rtol=1e-12)
        # ASD: Vn/Ω = Vc/Ωv with Ωv = 2, VD = 0.
        asd = deck_one_way_shear(fc, Ac, 145.0u"lb/ft^3"; design=:asd)
        @test isapprox(asd.capacity, (Vc / 2) * u"lbf"; rtol=1e-12)
        @test_throws ArgumentError deck_one_way_shear(fc, Ac, 145.0u"lb/ft^3"; design=:usd)
        # One pitch of 1.5VL is 6 in, so a foot of width carries twice the pitch strength.
        p15 = composite_deck_profile("1.5VL")
        Ac15 = deck_shear_concrete_area(p15, 3.0u"inch")
        sh15 = deck_one_way_shear(fc, Ac15, 145.0u"lb/ft^3")
        @test isapprox(uconvert(u"lbf/ft", sh15.capacity / p15.pitch),
                       2 * sh15.capacity / (1.0u"ft"); rtol=1e-9)
    end
end
