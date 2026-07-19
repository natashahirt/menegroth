using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using JSON3
using StructTypes
using Meshes

# Helper to access non-exported API types if needed
const SS = StructuralSynthesizer

@testset "Phase 5 Framing Integration" begin
    # =========================================================================
    # 1. API PAYLOAD DESERIALIZATION
    # =========================================================================
    @testset "API Payload Deserialization" begin
        # The APIInput schema expects a "params" key
        payload = """
        {
            "params": {
                "floor": {
                    "type": "one_way",
                    "material": "concrete"
                },
                "framing_levels": [
                    {
                        "material": "steel",
                        "spacing_in": 24.0
                    },
                    {
                        "material": "steel",
                        "role": "beam",
                        "axis": [1.0, 0.0],
                        "count": 2
                    }
                ],
                "materials": {
                    "steel": "A992",
                    "concrete": "NWC_4000",
                    "rebar": "Rebar_60"
                }
            }
        }
        """
        
        input = JSON3.read(payload, SS.APIInput)
        params = SS.json_to_params(input.params)
        
        @test !isempty(params.framing_opts)
        @test haskey(params.framing_opts, :materials)
        @test params.framing_opts.spacing == 24.0u"inch"
        @test haskey(params.framing_opts, :level_2)
        @test params.framing_opts.level_2.role == :beam
        @test params.framing_opts.level_2.axis == (1.0, 0.0)
        @test params.framing_opts.level_2.count == 2
    end

    # =========================================================================
    # 2. FULL WORKFLOW INTEGRATION (prepare!)
    # =========================================================================
    @testset "Workflow Integration (prepare!)" begin
        # Setup a simple 3-bay, 3-story structure
        # Using a multi-bay grid to ensure we don't hit edge cases of 1x1 subdivision
        # while keeping it simple.
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
        struc = BuildingStructure(skel)
        
        # Define parameters with framing levels
        # Level 1: steel joists at 5ft spacing
        # Level 2: 2 steel beams
        params = DesignParameters(
            floor = OneWayOptions(),
            materials = MaterialOptions(steel = A992_Steel, concrete = NWC_4000, rebar = Rebar_60),
            framing_opts = (; 
                materials = (; steel = A992_Steel, beam = A992_Steel),
                spacing = 5.0u"ft",
                level_2 = (; material = A992_Steel, count = 2, role = :beam, axis = (1.0, 0.0))
            )
        )
        
        # initialize! is called inside prepare!
        # Before prepare!, no members have been initialized yet
        @test isempty(struc.beams)
        
        # Running prepare! triggers initialize!, populate_levels!, and estimate_column_sizes!
        prepare!(struc, params)
        
        # After prepare!, should have auto-generated members
        @test length(struc.beams) > 0
        
        # Level-1 joists must be auto-generated from framing_opts (the core of the
        # integration fix: framing_opts → prepare! → populate_levels!).
        joists = filter(b -> b.level == 1, struc.beams)
        @test !isempty(joists)
        @test all(b -> b.role == :joist, joists)
        
        # Member material is recorded on the generated joists. `volumes(b)` returns
        # the member's MaterialVolumes (a Dict{AbstractMaterial, VolumeType}); the
        # level material is stamped as a zero-volume entry at populate time
        # (populate.jl materialize_level!), so the steel key is present pre-sizing.
        @test all(b -> haskey(volumes(b), A992_Steel), joists)
        
        # Multi-level plumbing: the level_2 schema in framing_opts must reach
        # populate_levels!. Verify each slab carries a materialized level-2
        # FramingLevel with the requested role (proves the schema propagated end to
        # end, independent of how many beams the level's pattern lays out).
        @test !isempty(struc.slabs)
        for slab in struc.slabs
            l1 = findfirst(fl -> fl.level == 1, slab.framing_levels)
            l2 = findfirst(fl -> fl.level == 2, slab.framing_levels)
            @test l1 !== nothing
            @test l2 !== nothing
            @test slab.framing_levels[l1].role == :joist
            @test slab.framing_levels[l2].role == :beam
            # group_id !== nothing ⇒ the level was materialized by populate_levels!.
            @test slab.framing_levels[l2].group_id !== nothing
        end
    end

    # =========================================================================
    # 3. EDGE CASE: Empty framing_levels
    # =========================================================================
    @testset "Edge Case: Empty framing_levels" begin
        skel = gen_medium_office(30.0u"ft", 30.0u"ft", 10.0u"ft", 1, 1, 1)
        struc = BuildingStructure(skel)
        
        params = DesignParameters(
            floor = OneWayOptions(),
            framing_opts = NamedTuple()
        )
        
        prepare!(struc, params)
        
        # Should NOT have any level >= 1 members
        @test all(b -> b.level == 0, struc.beams)
    end

    # =========================================================================
    # 4. EDGE CASE: Invalid material
    # =========================================================================
    @testset "Edge Case: Invalid material" begin
        # Invalid material in the API params should throw during resolution
        api_params = SS.APIParams()
        push!(api_params.framing_levels, SS.APIFramingLevel(material = "unobtainium"))
        
        @test_throws ErrorException SS.json_to_params(api_params)
    end
end
