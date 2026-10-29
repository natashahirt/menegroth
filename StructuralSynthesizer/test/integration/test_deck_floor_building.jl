# End to end: composite deck floor and composite steel beams through design_building.
#
# 2 × 2 bays of 10 ft. Each slab spans 10 ft between beams. With the shortest
# unshored column (span count unknown), 2VLI at 4 in needs gage 19 (10'-1");
# gage 20 stops at 9'-5". Vulcraft 2VLI sheet, PDF p. 89.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

@testset "Composite deck building" begin
    nwc145 = StructuralSizer.Concrete(StructuralSizer.NWC_4000.E, StructuralSizer.NWC_4000.fc′,
        uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, StructuralSizer.NWC_4000.ecc)
    skel = gen_medium_office(20.0u"ft", 20.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        floor = CompositeDeckOptions(deck_profile = "2VLI", fill_material = nwc145),
        materials = MaterialOptions(concrete = nwc145, steel = StructuralSizer.A992_Steel),
        beams = SteelBeamOptions(composite = true),
        columns = SteelColumnOptions(),
    )
    design = design_building(struc, params)
    s = design.structure
    @test !isempty(s.slabs)
    for slab in s.slabs
        r = slab.result
        @test r isa StructuralSizer.CompositeDeckResult
        @test r.deck_profile == "2VLI"
        @test r.deck_gauge == 19
        @test isapprox(r.total_depth, 4.0u"inch"; rtol = 1e-9)
        @test r.checks.ok
        mats = collect(keys(slab.volumes))
        @test any(m -> m isa StructuralSizer.Concrete, mats)
        @test any(m -> m isa StructuralSizer.StructuralSteel, mats)
    end
    # design_building restores member sections to the pre-size snapshot.
    # The sized sections live on the design result.
    @test !isempty(s.beams)
    @test length(design.beams) == length(s.beams)
    @test all(r -> r.section_obj !== nothing, values(design.beams))
end
