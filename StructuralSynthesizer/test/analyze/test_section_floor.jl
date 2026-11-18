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

@testset "Rectangular concrete beams keep a section floor" begin
    light = RCBeamSection(b = 10u"inch", h = 16u"inch", bar_size = 5, n_bars = 3, name = "light")
    mid = RCBeamSection(b = 12u"inch", h = 24u"inch", bar_size = 7, n_bars = 4, name = "mid")
    heavy = RCBeamSection(b = 16u"inch", h = 32u"inch", bar_size = 9, n_bars = 5, name = "heavy")
    cat = [light, mid, heavy]
    opts = ConcreteBeamOptions(custom_catalog = cat, deflection_limit = nothing,
                               material = NWC_4000, rebar_material = Rebar_60)
    gids = UInt64[1]
    floors = Dict(UInt64(1) => (section = mid, exact = false))
    c, feas = SY._apply_section_floor(opts, gids, nothing, nothing, floors)
    @test c == cat
    @test length(feas[1]) == 2
    @test any(j -> SY._sections_identical(c[j], mid), feas[1])
    @test all(j -> SY._sections_identical(c[j], mid) ||
                   SY._section_objective(opts, c[j]) > SY._section_objective(opts, mid),
              feas[1])

    # A demand the light section can carry still stays at the floor.
    struc = BuildingStructure(gen_medium_office(6.0u"m", 6.0u"m", 3.0u"m", 1, 1, 1))
    geom = [ConcreteMemberGeometry(6.0u"m")]
    Mu = [20.0u"kN*m"]
    Vu = [10.0u"kN"]
    Mu_neg = [20.0u"kN*m"]
    Nu = [0.0u"kN"]
    held = SY._rectangular_rc_beam_result(struc, opts, gids, Mu, Vu, Mu_neg, Nu,
                                          geom, nothing, floors)
    free = SY._rectangular_rc_beam_result(struc, opts, gids, Mu, Vu, Mu_neg, Nu,
                                          geom, nothing, nothing)
    @test SY._sections_identical(only(held.sections), mid)
    @test SY._section_objective(opts, only(free.sections)) < SY._section_objective(opts, mid)

    exact = Dict(UInt64(1) => (section = light, exact = true))
    _, feas_x = SY._apply_section_floor(opts, gids, cat, nothing, exact)
    @test length(only(feas_x)) == 1
    @test SY._sections_identical(cat[only(feas_x)[1]], light)
    @test_throws ArgumentError SY._apply_section_floor(
        ConcreteBeamOptions(custom_catalog = cat, n_max_sections = 1),
        gids, nothing, nothing, floors)
    @test_throws ArgumentError SY._apply_section_floor(
        ConcreteBeamOptions(custom_catalog = cat, include_flange = true),
        gids, nothing, nothing, floors)

    @test SY._shell_ratchet_ok(struc, ConcreteBeamOptions())
    @test SY._shell_ratchet_ok(struc, SteelBeamOptions())
    @test !SY._shell_ratchet_ok(struc, ConcreteBeamOptions(include_flange = true))
    @test !SY._shell_ratchet_ok(struc, ConcreteBeamOptions(n_max_sections = 2))
    @test !SY._shell_ratchet_ok(struc, ConcreteBeamOptions(materials = [NWC_4000, NWC_5000]))
    @test !SY._shell_ratchet_ok(struc, ConcreteBeamOptions(sizing_strategy = :nlp))
    @test !SY._shell_ratchet_ok(struc, ConcreteBeamOptions(), (; method = :nlp))
    @test_throws ArgumentError size_beams!(struc, ConcreteBeamOptions(include_flange = true);
                                           section_floor = floors)
end
