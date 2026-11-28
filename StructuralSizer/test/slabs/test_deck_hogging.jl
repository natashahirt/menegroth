# HAND CHECK — slab hogging on a composite deck.
#
# ACI 318-19 Table 6.5.2 (corpus: aci-318-19, PDF p. 76).
# Strip load wu = 200 plf. Two clear spans of 20 ft. L/D = 2, prismatic.
#   Negative moment at the first interior support: ln = 20 ft, divisor 9.
#   Mu = 200 × 20² / 9 = 8888.888... lb·ft.
#   Same face with the 10 ft row asserted: divisor 12, Mu = 6666.666... lb·ft.
#   Positive moment, discontinuous end unrestrained: divisor 11,
#   Mu = 200 × 400 / 11 = 7272.727... lb·ft.
#   Exterior column face: divisor 16, Mu = 5000 lb·ft.
#
# Table 6.5.4 (PDF p. 77). End span 18 ft in a 18/20/18 ft floor:
#   Vu = 1.15 × 200 × 18 / 2 = 2070 lbf.
#   Other face, middle span 20 ft: Vu = 200 × 20 / 2 = 2000 lbf.
#
# Cantilever, equilibrium, not Table 6.5.2: 200 plf over 5 ft.
#   Mu = 200 × 25 / 2 = 2500 lb·ft.
#
# Reinforcement, ACI 318-19 §7.6.1.1 and §7.7.3.8.4 (PDF pp. 94, 98).
# b = 12 in, h = 5 in, d = 4 in, f'c = 4 ksi, fy = 60 ksi, Es = 29000 ksi.
# As,min = 0.0018 × 12 × 5 = 0.108 in².
# Mu = 2 kip·ft = 24 kip·in.
#   Rn = 24 / (0.9 × 12 × 16) = 0.138889 ksi
#   β1 = 0.85, so 2 Rn / (β1 f'c) = 0.081699
#   ρ = (0.85 × 4 / 60) × (1 − √(1 − 0.081699)) = 0.002364
#   As = 0.002364 × 12 × 4 = 0.1135 in², which governs over 0.108 in².
# Extension for db = 0.5 in and ln = 20 ft:
#   max(d, 12 db, ln/16) = max(4, 6, 15) = 15 in.
# A moment of 0.05 kip·ft needs less than 0.108 in², so the minimum governs.

using Test
using Unitful
using StructuralSizer

const _WU = 200u"lbf" / u"ft"
const _GATES = (service_live = 100u"lbf" / u"ft", service_dead = 50u"lbf" / u"ft", prismatic = true)

@testset "Deck slab hogging" begin
    @testset "HAND CHECK ACI 318-19 Table 6.5.2" begin
        spans = [20u"ft", 20u"ft"]
        hog = deck_coefficient_moment(_WU, spans;
            location=:negative_first_interior_two_spans, _GATES...)
        @test hog.divisor == 9
        @test hog.ln ≈ 20u"ft"
        @test hog.Mu ≈ (80000 / 9) * u"lbf" * u"ft"
        @test hog.redistribution_permitted == false
        @test hog.deck_as_compression_reinforcement == false
        @test hog.all_supports_coefficient == false

        short = deck_coefficient_moment(_WU, spans;
            location=:negative_first_interior_two_spans,
            spans_not_exceeding_10_ft=true, _GATES...)
        @test short.divisor == 12
        @test short.Mu ≈ (80000 / 12) * u"lbf" * u"ft"
        @test short.all_supports_coefficient == true

        stiff = deck_coefficient_moment(_WU, spans;
            location=:negative_first_interior_two_spans,
            column_to_beam_stiffness_exceeds_8=true, _GATES...)
        @test stiff.divisor == 12

        pos = deck_coefficient_moment(_WU, spans;
            location=:positive_end_unrestrained, span=1, _GATES...)
        @test pos.divisor == 11
        @test pos.Mu ≈ (80000 / 11) * u"lbf" * u"ft"
        # The /12 row is a negative-moment row. A positive moment stays /11.
        pos_flag = deck_coefficient_moment(_WU, spans;
            location=:positive_end_unrestrained, span=1,
            spans_not_exceeding_10_ft=true, _GATES...)
        @test pos_flag.divisor == 11

        col = deck_coefficient_moment(_WU, spans;
            location=:negative_exterior_column, span=2, _GATES...)
        @test col.divisor == 16
        @test col.ln ≈ 20u"ft"
        @test col.Mu ≈ 5000u"lbf" * u"ft"

        three = [20u"ft", 18u"ft", 20u"ft"]
        first = deck_coefficient_moment(_WU, three;
            location=:negative_first_interior, span=1, _GATES...)
        @test first.ln ≈ 19u"ft"
        @test first.divisor == 10
        @test first.Mu ≈ (200 * 361 / 10) * u"lbf" * u"ft"

        four = [20u"ft", 18u"ft", 20u"ft", 18u"ft"]
        other = deck_coefficient_moment(_WU, four;
            location=:negative_other_interior, span=2, _GATES...)
        @test other.ln ≈ 19u"ft"
        @test other.divisor == 11
        @test other.Mu ≈ (200 * 361 / 11) * u"lbf" * u"ft"

        interior = deck_coefficient_moment(_WU, three;
            location=:positive_interior, span=2, _GATES...)
        @test interior.divisor == 16
        @test interior.ln ≈ 18u"ft"
        @test interior.Mu ≈ 4050u"lbf" * u"ft"

        # Exactly 20 percent and exactly L = 3D are inside the limits.
        edge = deck_coefficient_moment(_WU, [20u"ft", 24u"ft"];
            location=:negative_first_interior_two_spans,
            service_live=150u"lbf" / u"ft", service_dead=50u"lbf" / u"ft",
            prismatic=true)
        @test edge.ln ≈ 22u"ft"
    end

    @testset "HAND CHECK ACI 318-19 Table 6.5.4" begin
        spans = [18u"ft", 20u"ft", 18u"ft"]
        end_face = deck_coefficient_shear(_WU, spans;
            location=:first_interior, span=1, _GATES...)
        @test end_face.factor == 1.15
        @test end_face.Vu ≈ 2070u"lbf"
        other = deck_coefficient_shear(_WU, spans;
            location=:other, span=2, _GATES...)
        @test other.factor == 1.0
        @test other.Vu ≈ 2000u"lbf"
        @test_throws ArgumentError deck_coefficient_shear(_WU, spans;
            location=:first_interior, span=2, _GATES...)
    end

    @testset "Coefficient limits" begin
        spans = [20u"ft", 20u"ft"]
        @test_throws ArgumentError deck_coefficient_moment(_WU, [20u"ft"];
            location=:positive_end_unrestrained, _GATES...)
        @test_throws ArgumentError deck_coefficient_moment(_WU, spans;
            location=:negative_first_interior_two_spans, prismatic=false,
            service_live=100u"lbf" / u"ft", service_dead=50u"lbf" / u"ft")
        @test_throws ArgumentError deck_coefficient_moment(_WU, [20u"ft", 24.1u"ft"];
            location=:negative_first_interior_two_spans, _GATES...)
        @test_throws ArgumentError deck_coefficient_moment(_WU, spans;
            location=:negative_first_interior_two_spans,
            service_live=151u"lbf" / u"ft", service_dead=50u"lbf" / u"ft",
            prismatic=true)
        @test_throws ArgumentError deck_coefficient_moment(_WU, [20u"ft", 18u"ft", 20u"ft"];
            location=:negative_other_interior, span=2, _GATES...)
        @test_throws ArgumentError deck_coefficient_moment(200u"lbf" / u"ft^2", spans;
            location=:negative_first_interior_two_spans, _GATES...)
    end

    @testset "Cantilever equilibrium" begin
        cant = deck_cantilever_moment(_WU, 5u"ft")
        @test cant.Mu ≈ 2500u"lbf" * u"ft"
        @test cant.coefficient_method == false
        @test cant.development_length_evaluated == false
    end

    @testset "HAND CHECK negative reinforcement" begin
        sized = deck_negative_reinforcement(
            2u"kip" * u"ft", 12u"inch", 4u"inch", 5u"inch",
            4u"ksi", 60u"ksi", 29000u"ksi", 0.5u"inch", 20u"ft")
        @test sized.As_min ≈ 0.108u"inch^2"
        @test sized.As_flexure ≈ 0.1135u"inch^2" rtol = 1e-3
        @test sized.As ≈ sized.As_flexure
        @test sized.fraction_past_inflection == 1/3
        @test sized.extension_beyond_inflection ≈ 15u"inch"
        @test sized.development_length_evaluated == false
        @test sized.deck_as_compression_reinforcement == false
        @test sized.εt > 60 / 29000 + 0.003

        minimum = deck_negative_reinforcement(
            0.05u"kip" * u"ft", 12u"inch", 4u"inch", 5u"inch",
            4u"ksi", 60u"ksi", 29000u"ksi", 0.5u"inch", 20u"ft")
        @test minimum.As ≈ 0.108u"inch^2"
        @test minimum.As_flexure < minimum.As_min

        @test_throws ArgumentError deck_negative_reinforcement(
            2u"kip" * u"ft", 12u"inch", 5u"inch", 5u"inch",
            4u"ksi", 60u"ksi", 29000u"ksi", 0.5u"inch", 20u"ft")
        @test_throws ArgumentError deck_negative_reinforcement(
            80u"kip" * u"ft", 12u"inch", 4u"inch", 5u"inch",
            4u"ksi", 60u"ksi", 29000u"ksi", 0.5u"inch", 20u"ft")
    end
end
