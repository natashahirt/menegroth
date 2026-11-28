# Composite deck through design_building, on the beam layouts the deck spans.
#
# Two 10 ft bays. Loads are the Vulcraft hand check (15 psf superimposed,
# 100 psf live). On a regular grid the short span is 10 ft, and 2VLI at 4 in
# needs gage 19: the shortest unshored column for gage 20 stops at 9'-5"
# (Vulcraft 2VLI sheet, PDF p. 89).
#
# Irregular layouts use the same module:
# - :trapezoid shifts the interior column line, so one bay is narrower and
#   its deck span is that bay's short direction, not the 10 ft module.
# - :shift_x slants the beams. Deck ribs follow each slab's span axis, so a
#   slanted beam is neither parallel nor perpendicular to the ribs.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const _DECK_NWC = StructuralSizer.Concrete(
    StructuralSizer.NWC_4000.E, StructuralSizer.NWC_4000.fc′,
    uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, StructuralSizer.NWC_4000.ecc)

function _deck_design(; irregular::Symbol = :none, offset = 0.0u"ft")
    skel = gen_medium_office(20.0u"ft", 10.0u"ft", 12.0u"ft", 2, 1, 1;
                             irregular = irregular, offset = offset)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        floor = CompositeDeckOptions(deck_profile = "2VLI", fill_material = _DECK_NWC),
        loads = GravityLoads(floor_LL = 100.0u"psf", floor_SDL = 15.0u"psf",
                             roof_LL = 100.0u"psf", roof_SDL = 15.0u"psf"),
        materials = MaterialOptions(concrete = _DECK_NWC, steel = StructuralSizer.A992_Steel),
        beams = SteelBeamOptions(composite = true),
        columns = SteelColumnOptions(),
    )
    return design_building(struc, params)
end

"""Rib angles of beams that bear on a sized deck. Beams with no slab throw."""
function _deck_rib_angles(struc)
    angles = Float64[]
    for beam in struc.beams
        try
            push!(angles, StructuralSynthesizer.beam_rib_angle(struc, beam))
        catch e
            e isa ArgumentError || rethrow()
        end
    end
    return angles
end

function _assert_deck_floor(design)
    s = design.structure
    @test !isempty(s.slabs)
    for slab in s.slabs
        r = slab.result
        @test r isa StructuralSizer.CompositeDeckResult
        @test r.deck_profile == "2VLI"
        @test r.checks.ok
        @test isapprox(uconvert(u"m", r.checks.span), uconvert(u"m", slab.spans.primary);
                       rtol = 1e-6)
        mats = collect(keys(slab.volumes))
        @test any(m -> m isa StructuralSizer.Concrete, mats)
        @test any(m -> m isa StructuralSizer.StructuralSteel, mats)
    end
    # design_building restores member sections to the pre-size snapshot.
    # The sized sections live on the design result.
    @test !isempty(s.beams)
    @test length(design.beams) == length(s.beams)
    @test all(r -> r.section_obj !== nothing, values(design.beams))
    return s
end

@testset "Composite deck building" begin
    @testset "Regular rib layout" begin
        design = _deck_design()
        s = _assert_deck_floor(design)
        for slab in s.slabs
            r = slab.result
            @test r.deck_gauge == 19
            @test isapprox(r.total_depth, 4.0u"inch"; rtol = 1e-9)
            @test isapprox(uconvert(u"ft", slab.spans.primary), 10.0u"ft"; atol = 0.05u"ft")
        end
        angles = _deck_rib_angles(s)
        @test !isempty(angles)
        @test all(θ -> StructuralSizer.rib_orientation(θ) in (:parallel, :perpendicular), angles)
    end

    @testset "Unequal bays" begin
        design = _deck_design(; irregular = :trapezoid, offset = 2.0u"ft")
        s = _assert_deck_floor(design)
        spans = [uconvert(u"ft", slab.spans.primary) for slab in s.slabs]
        @test maximum(spans) - minimum(spans) > 1.0u"ft"
        @test any(L -> L < 9.0u"ft", spans)
        angles = _deck_rib_angles(s)
        @test !isempty(angles)
        @test all(θ -> StructuralSizer.rib_orientation(θ) in (:parallel, :perpendicular), angles)
    end

    @testset "Slanted beams" begin
        design = _deck_design(; irregular = :shift_x, offset = 2.0u"ft")
        s = _assert_deck_floor(design)
        angles = _deck_rib_angles(s)
        @test !isempty(angles)
        @test any(θ -> StructuralSizer.rib_orientation(θ) === :skewed, angles)
    end
end
