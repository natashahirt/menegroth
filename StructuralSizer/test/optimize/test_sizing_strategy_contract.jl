using Test
using StructuralSizer
using Unitful

@testset "Member sizing strategy contract" begin
    @testset "unknown strategies fail before solver dispatch" begin
        bad = :discerete

        @test_throws ArgumentError size_columns(
            Float64[], Float64[], SteelMemberGeometry[],
            SteelColumnOptions(sizing_strategy=bad),
        )
        @test_throws ArgumentError size_columns(
            Float64[], Float64[], ConcreteMemberGeometry[],
            ConcreteColumnOptions(sizing_strategy=bad),
        )
        @test_throws ArgumentError size_beams(
            Float64[], Float64[], ConcreteMemberGeometry[],
            ConcreteBeamOptions(sizing_strategy=bad),
        )
    end

    @testset "advertised but unsupported RC beam NLP fails loudly" begin
        opts = ConcreteBeamOptions(sizing_strategy=:nlp)

        @test_throws ArgumentError size_beams(
            Float64[], Float64[], ConcreteMemberGeometry[], opts,
        )
        @test_throws ArgumentError size_tbeams(
            Float64[], Float64[], ConcreteMemberGeometry[], opts;
            flange_width=48u"inch",
            flange_thickness=5u"inch",
        )
    end

    @testset "steel NLP does not silently substitute MIP" begin
        @test_throws ArgumentError size_columns(
            Float64[], Float64[], SteelMemberGeometry[],
            SteelColumnOptions(sizing_strategy=:nlp, section_type=:pipe),
        )

        @test_throws ArgumentError size_columns(
            [0.0], [0.0], [SteelMemberGeometry(4.0)],
            SteelColumnOptions(sizing_strategy=:nlp);
            Pu_t=[1.0],
        )
    end

    @testset "steel NLP aggregate preserves child failure" begin
        opts = SteelColumnOptions(sizing_strategy=:nlp)
        geom = [SteelMemberGeometry(4.0)]

        failed = StructuralSizer._steel_nlp_export_result(
            [(status=:failed, section=nothing)], opts, geom)
        @test failed.status === :failed
        @test failed.normalized_status === :failed
        @test failed.backend === :nlp
        @test failed.objective === opts.objective
        @test isnothing(failed.sections[1])
        @test failed.objective_value == 0.0
        @test !StructuralSizer._steel_nlp_result_installable(failed)

        infeasible = StructuralSizer._steel_nlp_export_result(
            [(status=:infeasible, section=nothing)], opts, geom)
        @test infeasible.status === :infeasible
        @test infeasible.normalized_status === :infeasible
        @test isnothing(infeasible.sections[1])
        @test !StructuralSizer._steel_nlp_result_installable(infeasible)
    end

    @testset "continuous objectives fail before solver construction" begin
        @test RCBeamNLPProblem(
            100.0, 20.0, NLPBeamOptions(objective=MinVolume()),
        ) isa RCBeamNLPProblem
        @test_throws ArgumentError RCBeamNLPProblem(
            100.0, 20.0, NLPBeamOptions(objective=MinCarbon()),
        )
        @test_throws ArgumentError RCTBeamNLPProblem(
            100.0, 20.0, 48u"inch", 5u"inch",
            NLPBeamOptions(objective=MinCarbon()),
        )

        demand = MemberDemand(1; Pu_c=100u"kip", Mux=10u"kip*ft")
        geometry = SteelMemberGeometry(10u"ft")
        @test_throws ArgumentError WColumnNLPProblem(
            demand, geometry, NLPWOptions(objective=MinVolume()),
        )
        @test_throws ArgumentError HSSColumnNLPProblem(
            demand, geometry, NLPHSSOptions(objective=MinCarbon()),
        )
    end
end
