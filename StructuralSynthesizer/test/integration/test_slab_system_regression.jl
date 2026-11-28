# Each built floor system designs on a small office and keeps a slab result.
#
# Framed floors are a 24 ft square in two bays each way. The composite deck
# uses the 10 ft span that the 2VLI unshored table accepts. Flat plate and
# flat slab are beamless, three spans each way, so the direct design method
# applies. A waffle floor type is not a system here: ribs are framing on an
# existing slab.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const _SLAB_NWC145 = Concrete(
    NWC_4000.E, NWC_4000.fc′,
    uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, NWC_4000.ecc)

function _framed_office()
    return BuildingStructure(gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1))
end

"""Move the beam grid to slab edges so the story is beamless."""
function _beamless_office(n)
    skel = gen_medium_office(18.0u"ft" * n, 18.0u"ft" * n, 12.0u"ft", n, n, 1)
    skel.groups_edges[:slab_edges] = pop!(skel.groups_edges, :beams)
    return BuildingStructure(skel)
end

function _office_loads(; ll = 50.0u"psf", sdl = 15.0u"psf")
    return GravityLoads(floor_LL = ll, floor_SDL = sdl, roof_LL = ll, roof_SDL = sdl)
end

function _design(struc, floor, beams, columns; materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60))
    params = DesignParameters(
        name = "slab_system_regression",
        floor = floor,
        beams = beams,
        columns = columns,
        loads = _office_loads(),
        materials = materials,
        max_iterations = 3,
        skip_visualization = true,
    )
    return design_building(struc, params; restore = false)
end

function _positive_depth(result)
    h = total_depth(result)
    return h isa Unitful.Quantity && ustrip(u"m", h) > 0
end

function _positive_weight(result)
    w = result.self_weight
    return w isa Unitful.Quantity && ustrip(u"kPa", w) > 0
end

"""Every floor slab has the requested type, a positive depth, and a positive self-weight."""
function _assert_slabs(struc, floor_type, result_type)
    floors = [s for s in struc.slabs if s.floor_type != :grade]
    @test !isempty(floors)
    for slab in floors
        @test slab.floor_type == floor_type
        @test slab.result isa result_type
        @test _positive_depth(slab.result)
        @test _positive_weight(slab.result)
    end
    return floors
end

@testset "Slab system regression" begin
    @testset "one-way concrete slab on concrete beams" begin
        struc = _framed_office()
        _design(struc, OneWayOptions(),
                ConcreteBeamOptions(material = NWC_4000, include_flange = true),
                ConcreteColumnOptions(material = NWC_4000))
        _assert_slabs(struc, :one_way, CIPSlabResult)
        # Beams with a slab on a side are T-beams. Grade beams have no flange,
        # so they stay rectangular.
        @test any(b -> b.base.section isa RCTBeamSection, struc.beams)
        @test all(b -> b.base.section isa RCTBeamSection || b.base.section isa RCBeamSection,
                  struc.beams)
        @test all(c -> c.base.section isa RCColumnSection || c.base.section isa RCCircularSection,
                  struc.columns)
    end

    @testset "two-way concrete slab on concrete beams" begin
        struc = _framed_office()
        _design(struc, TwoWayOptions(),
                ConcreteBeamOptions(material = NWC_4000, include_flange = true),
                ConcreteColumnOptions(material = NWC_4000))
        _assert_slabs(struc, :two_way, CIPSlabResult)
        @test any(b -> b.base.section isa RCTBeamSection, struc.beams)
        @test all(b -> b.base.section isa RCTBeamSection || b.base.section isa RCBeamSection,
                  struc.beams)
        @test all(c -> c.base.section isa RCColumnSection || c.base.section isa RCCircularSection,
                  struc.columns)
    end

    @testset "one-way concrete slab on steel beams" begin
        struc = _framed_office()
        _design(struc, OneWayOptions(),
                SteelBeamOptions(composite = false),
                SteelColumnOptions();
                materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60, steel = A992_Steel))
        _assert_slabs(struc, :one_way, CIPSlabResult)
        @test all(b -> b.base.section isa ISymmSection, struc.beams)
        @test all(c -> c.base.section isa ISymmSection, struc.columns)
    end

    @testset "two-way concrete slab composite with steel beams" begin
        struc = _framed_office()
        _design(struc, TwoWayOptions(),
                SteelBeamOptions(composite = true, composite_slab_type = :solid),
                SteelColumnOptions();
                materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60, steel = A992_Steel))
        _assert_slabs(struc, :two_way, CIPSlabResult)
        @test all(b -> b.base.section isa ISymmSection, struc.beams)
        @test all(c -> c.base.section isa ISymmSection, struc.columns)
    end

    @testset "composite steel deck on steel beams" begin
        struc = BuildingStructure(gen_medium_office(20.0u"ft", 10.0u"ft", 12.0u"ft", 2, 1, 1))
        _design(struc,
                CompositeDeckOptions(deck_profile = "2VLI", fill_material = _SLAB_NWC145),
                SteelBeamOptions(composite = true, composite_slab_type = :deck,
                                 composite_deck_profile = "2VLI"),
                SteelColumnOptions();
                materials = MaterialOptions(concrete = _SLAB_NWC145, steel = A992_Steel))
        floors = _assert_slabs(struc, :composite_deck, CompositeDeckResult)
        @test all(s -> s.result.deck_profile == "2VLI" && s.result.checks.ok, floors)
        @test all(b -> b.base.section isa ISymmSection, struc.beams)
        @test all(c -> c.base.section isa ISymmSection, struc.columns)
    end

    @testset "flat plate" begin
        struc = _beamless_office(3)
        _design(struc, FlatPlateOptions(method = DDM()),
                nothing, ConcreteColumnOptions(material = NWC_4000))
        _assert_slabs(struc, :flat_plate, FlatPlatePanelResult)
        @test all(s -> s.drop_panel === nothing, struc.slabs)
        @test all(c -> c.base.section isa RCColumnSection || c.base.section isa RCCircularSection,
                  struc.columns)
    end

    @testset "flat slab" begin
        struc = _beamless_office(3)
        _design(struc, FlatSlabOptions(),
                nothing, ConcreteColumnOptions(material = NWC_4000))
        _assert_slabs(struc, :flat_slab, FlatPlatePanelResult)
        @test all(s -> s.drop_panel isa DropPanelGeometry, struc.slabs)
        @test all(c -> c.base.section isa RCColumnSection || c.base.section isa RCCircularSection,
                  struc.columns)
    end
end
