using StructuralSynthesizer
using Test

@testset "API scoped override payload parsing" begin
    @testset "json_to_params parses scoped overrides with unit conversion" begin
        api_params = StructuralSynthesizer.APIParams(
            floor_type = "flat_plate",
            floor_options = StructuralSynthesizer.APIFloorOptions(),
            scoped_overrides = [
                StructuralSynthesizer.APIScopedOverride(
                    floor_type = "vault",
                    floor_options = StructuralSynthesizer.APIScopedFloorOptions(vault_lambda = 7.5),
                    faces = [
                        [
                            [0.0, 0.0, 10.0],
                            [20.0, 0.0, 10.0],
                            [20.0, 15.0, 10.0],
                            [0.0, 15.0, 10.0],
                        ],
                    ],
                ),
            ],
        )

        params = StructuralSynthesizer.json_to_params(api_params, "feet")
        @test length(params.scoped_floor_overrides) == 1

        ov = only(params.scoped_floor_overrides)
        @test ov.floor_type == :vault
        @test ov.vault_lambda == 7.5
        @test length(ov.faces) == 1
        @test length(ov.faces[1]) == 4

        # 20 ft -> 6.096 m, 10 ft -> 3.048 m
        @test isapprox(ov.faces[1][2][1], 6.096; atol = 1e-9)
        @test isapprox(ov.faces[1][1][3], 3.048; atol = 1e-9)
    end

    @testset "json_to_params keeps empty scoped override list" begin
        params = StructuralSynthesizer.json_to_params(StructuralSynthesizer.APIParams(), "meters")
        @test isempty(params.scoped_floor_overrides)
    end

    @testset "validate_input catches malformed scoped override payload" begin
        bad_input = StructuralSynthesizer.APIInput(
            units = "feet",
            vertices = [
                [0.0, 0.0, 0.0],
                [10.0, 0.0, 0.0],
                [10.0, 10.0, 0.0],
                [0.0, 10.0, 0.0],
            ],
            edges = StructuralSynthesizer.APIEdgeGroups(beams = [[1, 2], [2, 3], [3, 4], [4, 1]]),
            supports = [1],
            params = StructuralSynthesizer.APIParams(
                scoped_overrides = [
                    StructuralSynthesizer.APIScopedOverride(
                        floor_type = "vault",
                        floor_options = StructuralSynthesizer.APIScopedFloorOptions(vault_lambda = -2.0),
                        faces = [
                            [
                                [0.0, 0.0, 0.0],
                                [10.0, 0.0],  # invalid coordinate length
                                [10.0, 10.0, 0.0],
                            ],
                        ],
                    ),
                ],
            ),
        )

        vr = validate_input(bad_input)
        @test !vr.ok
        @test any(e -> occursin("scoped_overrides[1].floor_options.vault_lambda", e.field), vr.errors)
        @test any(e -> occursin("expected 3", e.message), vr.errors)
    end
end
