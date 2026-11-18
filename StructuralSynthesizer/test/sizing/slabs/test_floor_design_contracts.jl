using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

@testset "Floor design boundary contracts" begin
    options = VaultOptions(rise = 2.0u"ft", thickness = 3.0u"inch")
    skeleton = gen_medium_office(24.0u"ft", 24.0u"ft", 10.0u"ft", 1, 1, 1)
    structure = BuildingStructure(skeleton)
    initialize!(
        structure;
        floor_type = :vault,
        floor_opts = options,
        material = NWC_4000,
    )

    request = floor_design_request(
        structure,
        1;
        options = options,
        max_iterations = 5,
    )
    @test request isa FloorDesignRequest
    @test request.source == FloorSource(1)
    @test request.system isa Vault

    initial_result = deepcopy(structure.slabs[1].result)
    initial_weights = deepcopy([cell.self_weight for cell in structure.cells])
    outcome = design_floor(structure, request)

    @test is_installable(outcome)
    @test outcome.status == FLOOR_DESIGN_SUCCEEDED
    @test outcome.proposal.result isa VaultResult
    @test structure.slabs[1].result == initial_result
    @test [cell.self_weight for cell in structure.cells] == initial_weights

    install_floor_design!(structure, request, outcome)
    @test structure.slabs[1].result isa VaultResult
    @test structure.slabs[1].result == outcome.proposal.result
    @test all(
        structure.cells[update.source_index].self_weight == update.self_weight
        for update in outcome.proposal.cell_updates
    )

    @testset "unsupported systems fail before live-state mutation" begin
        # One-way and two-way now size a thickness. CLT has options, and no
        # sizing method, so it is still the unsupported case.
        unsupported = deepcopy(structure)
        unsupported.slabs[1].floor_type = :clt
        unsupported_request = floor_design_request(
            unsupported,
            1;
            options = TimberOptions(),
        )
        before_result = deepcopy(unsupported.slabs[1].result)
        before_weights = deepcopy([cell.self_weight for cell in unsupported.cells])

        @test_throws UnsupportedFloorSystemError design_floor(
            unsupported,
            unsupported_request,
        )
        @test unsupported.slabs[1].result == before_result
        @test [cell.self_weight for cell in unsupported.cells] == before_weights
    end

    @testset "stale and mismatched requests are rejected before installation" begin
        stale = deepcopy(structure)
        stale.slabs[1].floor_type = :one_way
        before_result = deepcopy(stale.slabs[1].result)

        @test_throws ArgumentError install_floor_design!(stale, request, outcome)
        @test stale.slabs[1].result == before_result
    end

    @testset "normalized flat-plate kernel is pure and deterministic" begin
        fp_options = FlatPlateOptions(
            material = RC_4000_60,
            method = DDM(),
            cover = 0.75u"inch",
            bar_size = 5,
        )
        fp_skeleton = gen_medium_office(
            54.0u"ft",
            42.0u"ft",
            9.0u"ft",
            3,
            3,
            1,
        )
        fp_structure = BuildingStructure(fp_skeleton)
        initialize!(
            fp_structure;
            floor_type = :flat_plate,
            floor_opts = fp_options,
        )
        to_asap!(fp_structure)

        fp_request = floor_design_request(
            fp_structure,
            1;
            options = fp_options,
            max_iterations = 20,
        )
        @test fp_request.input isa FlatPlateDesignInput
        input_type = string(typeof(fp_request.input))
        @test !occursin("BuildingStructure", input_type)
        @test !occursin("Asap.Model", input_type)

        result_before = deepcopy(fp_structure.slabs[1].result)
        weights_before = deepcopy([cell.self_weight for cell in fp_structure.cells])
        columns_before = deepcopy([
            (column.c1, column.c2, column.base.section)
            for column in fp_structure.columns
        ])

        first_outcome = StructuralSynthesizer.design_floor(
            fp_structure,
            fp_request,
        )
        second_outcome = StructuralSynthesizer.design_floor(
            fp_structure,
            fp_request,
        )
        result_signature = result -> (
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

        @test is_installable(first_outcome)
        @test is_installable(second_outcome)
        @test result_signature(first_outcome.proposal.result) ==
              result_signature(second_outcome.proposal.result)
        @test sprint(show, first_outcome.proposal.details) ==
              sprint(show, second_outcome.proposal.details)
        @test fp_structure.slabs[1].result == result_before
        @test [cell.self_weight for cell in fp_structure.cells] == weights_before
        @test [
            (column.c1, column.c2, column.base.section)
            for column in fp_structure.columns
        ] == columns_before

        legacy = deepcopy(fp_structure)
        legacy_outcome = StructuralSizer.size_slab!(
            legacy,
            1;
            options = fp_options,
            max_iterations = 20,
            defer_asap_process = true,
        )
        @test is_installable(legacy_outcome)
        @test result_signature(first_outcome.proposal.result) ==
              result_signature(legacy.slabs[1].result)

        install_floor_design!(fp_structure, fp_request, first_outcome)
        @test result_signature(fp_structure.slabs[1].result) ==
              result_signature(first_outcome.proposal.result)
    end
end
