using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

function _pure_method_result_signature(result)
    return (
        result.thickness,
        result.volume_per_area,
        result.self_weight,
        result.qu,
        result.l1,
        result.l2,
        result.M0,
        result.column_strip_width,
        sprint.(show, result.column_strip_reinf),
        result.middle_strip_width,
        sprint.(show, result.middle_strip_reinf),
        result.secondary_column_strip_width,
        sprint.(show, result.secondary_column_strip_reinf),
        result.secondary_middle_strip_width,
        sprint.(show, result.secondary_middle_strip_reinf),
        result.punching_check.ok,
        result.punching_check.max_ratio,
        sort([
            (index, sprint(show, detail))
            for (index, detail) in result.punching_check.details
        ]),
        sprint(show, result.deflection_check),
    )
end

@testset "Pure flat-plate method parity" begin
    for method in (EFM(), FEA())
        @testset "$(typeof(method))" begin
            options = FlatPlateOptions(
                material = RC_4000_60,
                method = method,
                cover = 0.75u"inch",
                bar_size = 5,
            )
            skeleton = gen_medium_office(
                54.0u"ft",
                42.0u"ft",
                9.0u"ft",
                3,
                3,
                1,
            )
            structure = BuildingStructure(skeleton)
            initialize!(
                structure;
                floor_type = :flat_plate,
                floor_opts = options,
            )
            to_asap!(structure)

            request = floor_design_request(
                structure,
                1;
                options = options,
                max_iterations = 20,
            )
            result_before = deepcopy(structure.slabs[1].result)
            weights_before = deepcopy([cell.self_weight for cell in structure.cells])
            columns_before = deepcopy([
                (column.c1, column.c2, column.base.section)
                for column in structure.columns
            ])

            pure_outcome = StructuralSynthesizer.design_floor(structure, request)
            @test is_installable(pure_outcome)
            @test structure.slabs[1].result == result_before
            @test [cell.self_weight for cell in structure.cells] == weights_before
            @test [
                (column.c1, column.c2, column.base.section)
                for column in structure.columns
            ] == columns_before

            legacy = deepcopy(structure)
            legacy_outcome = StructuralSizer.size_slab!(
                legacy,
                1;
                options = options,
                max_iterations = 20,
                defer_asap_process = true,
            )
            @test is_installable(legacy_outcome)
            @test _pure_method_result_signature(pure_outcome.proposal.result) ==
                  _pure_method_result_signature(legacy.slabs[1].result)
            @test sprint(show, pure_outcome.details.element_rebar_field) ==
                  sprint(show, legacy.slabs[1].design_details.element_rebar_field)
            @test sprint(show, pure_outcome.details.secondary_element_rebar_field) ==
                  sprint(show, legacy.slabs[1].design_details.secondary_element_rebar_field)
            @test sprint(show, pure_outcome.details.deflection_check_crossing_beam) ==
                  sprint(show, legacy.slabs[1].design_details.deflection_check_crossing_beam)
        end
    end
end
