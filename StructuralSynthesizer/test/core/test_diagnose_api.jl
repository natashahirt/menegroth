using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using JSON3

@testset "Diagnose API" begin
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        floor = FlatPlateOptions(
            method = DDM(),
            deflection_limit = :L_360,
            punching_strategy = :grow_columns,
        ),
        max_iterations = 2,
    )
    design = design_building(struc, params)

    @testset "diagnose payload uses normalized keys and units" begin
        diag = design_to_diagnose(design)
        @test haskey(diag, "columns")
        @test haskey(diag, "slabs")

        if !isempty(diag["columns"])
            c = first(diag["columns"])
            @test haskey(c, "axial_ratio")
            @test haskey(c, "interaction_ratio")
            @test c["area_unit"] in ("ft2", "m2")
        end

        if !isempty(diag["slabs"])
            s = first(diag["slabs"])
            @test haskey(s, "deflection")
            @test haskey(s, "deflection_limit")
            @test haskey(s, "deflection_unit")
            @test !haskey(s, "deflection_in")
            @test !haskey(s, "deflection_limit_in")

            punch_checks = filter(ch -> get(ch, "name", "") == "punching_shear_slab", s["checks"])
            if !isempty(punch_checks)
                p = first(punch_checks)
                @test haskey(p, "demand_vu")
                @test !haskey(p, "demand_psi")
            end
        end

        js = JSON3.write(diag)
        @test !occursin("capacity_φVc", js)
    end

    @testset "column recommendation uses axial/interaction ratios" begin
        col_dicts = Dict{String, Any}[
            Dict(
                "id" => 1,
                "governing_check" => "punching_shear_col",
                "governing_ratio" => 0.96,
                "axial_ratio" => 0.62,
                "interaction_ratio" => 0.71,
            ),
        ]

        recs = StructuralSynthesizer._build_goal_recommendations(
            design,
            params,
            design.params.display_units,
            col_dicts,
            Dict{String, Any}[],
            Dict{String, Any}[],
            Dict{String, Any}[],
        )

        target = filter(r ->
                get(r, "goal", "") == "reduce_column_size" &&
                get(r, "primary_lever", "") == "punching_strategy",
            recs)
        @test !isempty(target)
        @test first(target)["estimated_new_ratio"] == round(0.71; digits=3)
    end

    @testset "deflection direction labels are correct" begin
        slab_dicts = Dict{String, Any}[
            Dict(
                "governing_check" => "deflection",
                "governing_ratio" => 0.90,
                "checks" => Any[Dict("name" => "deflection", "ratio" => 0.90)],
                "ec_kgco2e" => 100.0,
            ),
        ]

        impacts = StructuralSynthesizer._diagnose_lever_impacts(
            design,
            params,
            design.params.display_units,
            Dict{String, Any}[],
            slab_dicts,
        )

        i240 = first(filter(i -> get(i, "alternative_value", "") == "L_240", impacts))
        i480 = first(filter(i -> get(i, "alternative_value", "") == "L_480", impacts))
        @test i240["direction"] == "relaxed"
        @test i480["direction"] == "tighter"
    end
end
