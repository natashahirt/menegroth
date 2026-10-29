# HAND CHECK — composite deck floor against the Vulcraft 145 pcf sheets
# (corpus: vulcraft-deck-solutions-2020; 1.5VL p. 81, 2VLI p. 89, 3VLI p. 93).
#
# Self weight. 2VLI, 4 in total, 2 in topping, gage 20:
#   wr = (7 + 5)/2 = 6 in, ribs = 2 × 6 / 12 = 1 in, concrete = 3 in.
#   3/12 × 145 = 36.25 psf, deck 1.9 psf, total 38.15 psf. Catalog 38.2.
#
# Shear, SDI C-2017 Eq. 2.4.7c at f'c = 3000 psi (corpus: sdi-c-2017, PDF p. 13).
#   2VLI 4 in: Ac = 28 in² per 12 in pitch. 4 √3000 × 28 / 2 = 3067 lb/ft.
#   Catalog Vno/Ω = 3.07 kip/ft.
#
# Superimposed allowable load, simple span, L/360 on superimposed load, 2VLI 4 in g20.
#   Mno/Ω = 2.86 kip·ft/ft, Id = 4.43 in⁴/ft, Es = 29,500 ksi (SDI Appendix 5, PDF p. 43).
#   The sheet prints Id = (Icr + Iu)/2, SDI Eq. A5-5 (PDF p. 44).
#   6 ft:  8 × 2860 / 36  − 38.15 = 597.4 psf  (moment).  Catalog 597.
#   10 ft: 8 × 2860 / 100 − 38.15 = 190.6 psf  (moment).  Catalog 190.
#   14 ft: δ = L/360 = 0.4667 in →
#          w = 384 × 29.5e6 × 4.43 × 0.4667 / (5 × 168⁴) = 5.88 lb/in = 70.6 psf.  Catalog 70.
#   Unshored 3-span limit for gage 20 at 4 in is 10'-9", so 14 ft also fails construction.

using Test
using Unitful
using StructuralSizer
const SS = StructuralSizer

const _NWC145_3000 = SS.Concrete(SS.NWC_3000.E, SS.NWC_3000.fc′,
    uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, SS.NWC_3000.ecc)
const _NWC145_4000 = SS.Concrete(SS.NWC_4000.E, SS.NWC_4000.fc′,
    uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, SS.NWC_4000.ecc)

@testset "Composite deck floor" begin
    @testset "Self weight and shear against every catalog row" begin
        for name in ("1.5VL", "2VLI", "3VLI")
            p = composite_deck_profile(name)
            for d in keys(SS._SLAB_ASD_145[name]), g in SS._BEARING_GAGES
                c = deck_slab_candidate(p, d * u"inch", g, 8u"ft", 0u"psf", 0u"psf";
                                        concrete=_NWC145_3000)
                @test isapprox(ustrip(u"psf", c.self_weight), ustrip(u"psf", c.catalog_weight); atol=0.06)
                sdi = ustrip(u"kip/ft", c.sdi_Vn_over_Ω)
                cat = ustrip(u"kip/ft", c.catalog_Vno_over_Ω)
                if name == "1.5VL"
                    # Catalog is below the Figure 2-1 equation; the lesser value gates.
                    @test cat < sdi
                    @test c.Vn_over_Ω == c.catalog_Vno_over_Ω
                else
                    @test isapprox(sdi, cat; atol=0.006)
                end
            end
        end
    end

    @testset "HAND CHECK superimposed-load table, 2VLI 4 in gage 20" begin
        p = composite_deck_profile("2VLI")
        run(L, w) = deck_slab_candidate(p, 4u"inch", 20, L, 0u"psf", w;
            concrete=_NWC145_3000, n_spans=3, superimposed_deflection_limit=1/360)
        c = run(6u"ft", 597u"psf")
        @test c.ok
        @test isapprox(ustrip(u"psf", c.self_weight), 38.15; atol=0.01)
        @test :moment in run(6u"ft", 599u"psf").failed
        @test run(10u"ft", 190u"psf").ok
        @test run(10u"ft", 191u"psf").failed == [:moment]
        @test run(14u"ft", 70u"psf").failed == [:unshored_span]
        f = run(14u"ft", 71u"psf").failed
        @test :live_deflection in f && :superimposed_deflection in f && !(:moment in f)
        @test c.unshored_span_limit == 129u"inch"
        @test c.As_temperature_shrinkage ≈ 0.018u"inch^2/ft"
    end

    @testset "Minimums and construction columns" begin
        p = composite_deck_profile("2VLI")
        low = SS.Concrete(SS.NWC_3000.E, 2500.0u"psi", uconvert(u"kg/m^3", 145.0u"lb/ft^3"),
                          0.2, SS.NWC_3000.ecc)
        @test :fc_min in deck_slab_candidate(p, 4u"inch", 20, 8u"ft", 0u"psf", 50u"psf";
                                             concrete=low).failed
        # Unknown span count takes the shortest column: 9'-5" for gage 20 at 4 in.
        c = deck_slab_candidate(p, 4u"inch", 20, 8u"ft", 0u"psf", 50u"psf"; concrete=_NWC145_3000)
        @test c.unshored_span_limit == 113u"inch"
        @test_throws ArgumentError deck_slab_candidate(p, 4u"inch", 20, 8u"ft", 0u"psf", 50u"psf";
                                                       concrete=SS.NWC_4000)
        @test_throws ArgumentError deck_slab_candidate(p, 4.25u"inch", 20, 8u"ft", 0u"psf", 50u"psf";
                                                       concrete=_NWC145_3000)
    end

    @testset "Lightest passing depth and gage" begin
        p = composite_deck_profile("2VLI")
        best = size_composite_deck_slab(p, 10u"ft", 15u"psf", 100u"psf"; concrete=_NWC145_4000)
        @test best.ok
        for d in keys(SS._SLAB_ASD_145["2VLI"]), g in SS._BEARING_GAGES
            c = deck_slab_candidate(p, d * u"inch", g, 10u"ft", 15u"psf", 100u"psf";
                                    concrete=_NWC145_4000)
            c.self_weight < best.self_weight && @test !c.ok
        end
        # 10 ft: unknown span count needs gage 19 at 4 in (shortest column 10'-1").
        @test best.total_depth == 4u"inch"
        @test best.gage == 19
        @test_throws ArgumentError size_composite_deck_slab(p, 16u"ft", 15u"psf", 100u"psf";
                                                            concrete=_NWC145_4000)
    end

    @testset "Floor result" begin
        opts = CompositeDeckOptions(deck_profile="2VLI")
        r = SS._size_span_floor(SS.CompositeDeck(), 10u"ft", 15u"psf", 100u"psf";
                                material=_NWC145_4000, options=opts)
        @test r isa SS.CompositeDeckResult
        @test r.deck_gauge == 19
        @test r.fill_depth ≈ uconvert(u"m", 2u"inch")
        @test r.total_depth ≈ uconvert(u"m", 4u"inch")
        @test r.concrete_vol_per_area ≈ uconvert(u"m", 3u"inch")
        @test SS.self_weight(r) ≈ uconvert(u"Pa", r.checks.self_weight)
        @test SS.materials(r) == (:steel, :concrete)
        # Deck steel: 2.2 psf of A992.
        ρs = SS.A992_Steel.ρ
        @test SS.volume_per_area(r, :steel) ≈ uconvert(u"m", 2.2u"psf" / (ρs * 1u"gn"))
        @test_throws ArgumentError SS._size_span_floor(SS.CompositeDeck(), 10u"ft", 15u"psf",
            100u"psf"; material=SS.NWC_4000, options=opts)
    end
end
