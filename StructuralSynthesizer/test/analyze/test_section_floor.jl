# A section floor narrows a group's catalog to its current section and every
# strictly heavier one, so a story-shell pass can only move a group up.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer

@testset "Section floor masks" begin
    cat = [W("W4X13"), W("W10X12"), W("W6X12"), W("W6X15"), W("W8X18")]
    opts = SteelBeamOptions(custom_catalog = cat)
    names(idx, c) = Set(c[j].name for j in idx)
    gids = UInt64[1, 2, 3]
    floors = Dict(UInt64(1) => (section = W("W4X13"), exact = false),
                  UInt64(2) => (section = W("W6X15"), exact = true))
    c, feas = SY._apply_section_floor(opts, gids, nothing, nothing, floors)
    @test c == cat
    # Equal or lighter shapes never replace the floor; heavier ones may.
    @test names(feas[1], c) == Set(["W4X13", "W6X15", "W8X18"])
    @test names(feas[2], c) == Set(["W6X15"])
    @test names(feas[3], c) == Set(s.name for s in cat)

    # An existing per-group mask is narrowed, never widened.
    _, feas2 = SY._apply_section_floor(opts, gids, cat, [[1, 2], [4], [3]], floors)
    @test names(feas2[1], cat) == Set(["W4X13"])
    @test names(feas2[2], cat) == Set(["W6X15"])
    @test names(feas2[3], cat) == Set(["W6X12"])

    # Two separately built RC columns with the same bars are the same section;
    # a different bar layout is not.
    rc(n) = RCColumnSection(b = 10u"inch", h = 10u"inch", bar_size = 5, n_bars = n)
    @test SY._sections_identical(rc(4), rc(4))
    @test !SY._sections_identical(rc(4), rc(8))

    # Groups sized together cannot each keep their own floor.
    @test_throws ArgumentError SY._apply_section_floor(
        SteelBeamOptions(custom_catalog = cat, n_max_sections = 2), gids, nothing, nothing, floors)
end
