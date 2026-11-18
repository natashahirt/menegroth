using StructuralSynthesizer
using Test

function _strategy_errors(params)
    result = validate_input(APIInput(units="feet", params=params))
    return filter(
        e -> e.field in ("column_sizing_strategy", "beam_sizing_strategy"),
        result.errors,
    )
end

@testset "API sizing strategy capability contract" begin
    @testset "deserialization never defaults an unknown strategy" begin
        @test_throws ArgumentError json_to_params(
            APIParams(beam_sizing_strategy="discerete"), "feet")
        @test_throws ArgumentError json_to_params(
            APIParams(beam_type="rc_rect", beam_sizing_strategy="nlp"), "feet")
        @test_throws ArgumentError json_to_params(
            APIParams(column_type="pixelframe", column_sizing_strategy="nlp"), "feet")
        @test_throws ArgumentError json_to_params(
            APIParams(
                beam_type="steel_w",
                beam_sizing_strategy="nlp",
                composite=true,
            ),
            "feet",
        )
    end

    @testset "RC and PixelFrame beam NLP is rejected at the boundary" begin
        for beam_type in ("rc_rect", "rc_tbeam", "pixelframe")
            errors = _strategy_errors(APIParams(
                beam_type=beam_type,
                beam_sizing_strategy="nlp",
            ))
            @test any(e -> e.field == "beam_sizing_strategy" &&
                           e.constraint == "compatibility", errors)
        end
    end

    @testset "PixelFrame column NLP is rejected at the boundary" begin
        errors = _strategy_errors(APIParams(
            column_type="pixelframe",
            column_sizing_strategy="nlp",
        ))
        @test any(e -> e.field == "column_sizing_strategy" &&
                       e.constraint == "compatibility", errors)
    end

    @testset "composite steel beam NLP is rejected at the boundary" begin
        errors = _strategy_errors(APIParams(
            beam_type="steel_w",
            beam_sizing_strategy="nlp",
            composite=true,
        ))
        @test any(e -> e.field == "beam_sizing_strategy" &&
                       e.constraint == "compatibility", errors)
    end

    @testset "implemented NLP combinations remain accepted" begin
        errors = _strategy_errors(APIParams(
            column_type="rc_rect",
            column_sizing_strategy="nlp",
            beam_type="steel_w",
            beam_sizing_strategy="nlp",
        ))
        @test isempty(errors)
    end
end
