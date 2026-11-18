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
        # The vault is one cell: a vault slab has to be a single rectangular face.
        # Carving that cell out of the plate leaves a frame with two spans, so
        # the direct design method does not apply (ACI 318-11 §13.6.1.1,
        # corpus: aci-318-11, page 252). The plate is analyzed by FEA.
        skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
        struc = BuildingStructure(skel)

        # Southwest cell only. The cut is inside that bay and short of the
        # next bay's centroid. gen_medium_office rounds each bay to 0.01 m.
        z_story = ustrip(u"m", skel.stories_z[2])
        x_bay = round(ustrip(u"m", 54.0u"ft") / 3, digits = 2)
        y_bay = round(ustrip(u"m", 42.0u"ft") / 3, digits = 2)
        scoped = StructuralSynthesizer.ScopedFloorOverride(
            floor_type = :vault,
            vault_lambda = 8.0,
            faces = [[
                (0.0, 0.0, z_story),
                (0.75 * x_bay, 0.0, z_story),
                (0.75 * x_bay, 0.75 * y_bay, z_story),
                (0.0, 0.75 * y_bay, z_story),
            ]],
        )

        params = DesignParameters(
            floor = FlatPlateOptions(method = FEA()),
            scoped_floor_overrides = [scoped],
            max_iterations = 10,
        )
        design = design_building(struc, params)

        slabs = design.structure.slabs
        slab_types = unique([s.floor_type for s in slabs])
        @test :vault in slab_types
        @test length(slab_types) >= 2  # mixed: scoped vault + baseline floor
        vaults = filter(s -> s.floor_type == :vault, slabs)
        plates = filter(s -> s.floor_type == :flat_plate, slabs)
        @test length(vaults) == 1 && length(only(vaults).cell_indices) == 1
        @test length(plates) == 1 && length(only(plates).cell_indices) == 8

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
