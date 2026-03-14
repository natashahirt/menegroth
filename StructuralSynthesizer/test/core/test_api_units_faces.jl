using StructuralSynthesizer
using Test
using Unitful

@testset "API units and explicit faces" begin
    @testset "_to_display_length fails fast on non-length" begin
        du = DisplayUnits(:imperial)
        @test isapprox(StructuralSynthesizer._to_display_length(du, 1.0u"m"), 3.280839895; atol=1e-9)
        @test_throws ArgumentError StructuralSynthesizer._to_display_length(du, 1.0u"m^2")
    end

    @testset "Explicit face selectors map onto detected faces" begin
        input = StructuralSynthesizer.APIInput(
            units = "m",
            vertices = [
                [0.0, 0.0, 0.0],
                [1.0, 0.0, 0.0],
                [2.0, 0.0, 0.0],
                [2.0, 1.0, 0.0],
                [1.0, 1.0, 0.0],
                [0.0, 1.0, 0.0],
            ],
            edges = StructuralSynthesizer.APIEdgeGroups(
                # Two adjacent floor cells split by the interior edge (2,5).
                beams = [[1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 1], [2, 5]],
                columns = Vector{Vector{Int}}(),
                braces = Vector{Vector{Int}}(),
            ),
            supports = Int[],
            stories_z = [0.0, 3.0],
            faces = Dict(
                "floor" => [
                    [
                        [0.0, 0.0, 0.0],
                        [1.0, 0.0, 0.0],
                        [1.0, 1.0, 0.0],
                        [0.0, 1.0, 0.0],
                    ],
                ],
            ),
        )

        skel = json_to_skeleton(input)
        # Selector should map to one detected floor face.
        @test haskey(skel.groups_faces, :floor)
        @test length(unique(skel.groups_faces[:floor])) == 1
    end

    @testset "Scoped vault override affects only matched region" begin
        # Build a small 2-bay, 1-story structure with beam framing.
        skel = gen_medium_office(40.0u"ft", 20.0u"ft", 10.0u"ft", 2, 1, 1)
        struc = BuildingStructure(skel)

        # Select the left half in plan at first elevated story.
        z_story = ustrip(u"m", skel.stories_z[2])
        scoped = StructuralSynthesizer.ScopedFloorOverride(
            floor_type = :vault,
            vault_lambda = 8.0,
            faces = [[
                (0.0, 0.0, z_story),
                (6.2, 0.0, z_story),
                (6.2, 20.0 * 0.3048, z_story),
                (0.0, 20.0 * 0.3048, z_story),
            ]],
        )

        params = DesignParameters(
            floor = FlatPlateOptions(),
            scoped_floor_overrides = [scoped],
            max_iterations = 2,
        )
        design = design_building(struc, params)

        slab_types = unique([s.floor_type for s in design.structure.slabs])
        @test :vault in slab_types
        @test length(slab_types) >= 2  # mixed: scoped vault + baseline floor

        # Beams remain part of model/results (vault override should not hide them).
        @test !isempty(design.beams)
    end

    @testset "Global vault remains all-vault when no scoped geometry" begin
        skel = gen_medium_office(40.0u"ft", 20.0u"ft", 10.0u"ft", 2, 1, 1)
        struc = BuildingStructure(skel)

        params = DesignParameters(
            floor = VaultOptions(lambda = 8.0),
            max_iterations = 2,
        )
        design = design_building(struc, params)

        @test all(s.floor_type == :vault for s in design.structure.slabs)
        @test !isempty(design.beams)
    end
end
