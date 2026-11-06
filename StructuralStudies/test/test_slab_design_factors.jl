# Geometry loading, transcribed-section alignment, and floor-system parameters.
# No building is designed.

using Test

include(joinpath(@__DIR__, "..", "src", "slab_design_factors", "study.jl"))

@testset "Slab Design Factors plans" begin
    if !isdir(SDF_ROOT)
        @test_skip "Slab Design Factors geometries are not beside this repo"
    else
        @testset "a parametric plan keeps its beam lines" begin
            plan = load_plan("grid/x0y0")
            @test length(plan.xy) == 9
            @test length(plan.lines) == 12
            @test length(plan.columns) == 9
            @test isempty(plan.sections)
            skel = plan_skeleton(plan)
            @test length(skel.groups_edges[:beams]) == 24
            @test length(skel.groups_edges[:columns]) == 9
            @test :floor in keys(skel.groups_faces)
            @test !isempty(skel.groups_faces[:floor])
        end

        @testset "transcribed sections are one per beam line" begin
            office = load_plan("validation/office")
            @test length(office.sections) == length(office.lines) == 252
            @test count(isnothing, office.sections) == 16
            school = load_plan("validation/school")
            warehouse = load_plan("validation/warehouse")
            @test length(school.sections) == 298
            @test length(warehouse.sections) == 131
            @test length(office.holes) == 12
            office_skel = plan_skeleton(office)
            @test length(office_skel.openings) == 12
            @test w_name(18, 35) == "W18X35"
            @test w_name(6, 8.5) == "W6X8.5"
            @test canonical_w("W18x35") == "W18X35"
            @test canonical_w("w30X90.0") == "W30X90"
        end

        @testset "loads follow the thesis occupancies" begin
            @test plan_loads("validation/office").ll == 60.0
            @test plan_loads("validation/school").ll == 50.0
            @test plan_loads("validation/warehouse").ll == 250.0
            @test plan_loads("validation/office").sdl == 20.0
            @test plan_loads("grid/x1y1").occupancy == "parametric"
            @test plan_loads("grid/x1y1").ll == 60.0
        end

        @testset "the three systems build" begin
            for system in SYSTEMS
                params = system_parameters("validation/office", system)
                @test params.loads.floor_LL == 60.0u"psf"
                @test params.loads.floor_SDL == 20.0u"psf"
            end
            deck = system_parameters("validation/warehouse", :deck)
            @test deck.floor.deck_profile == "3VLI"
            @test deck.floor.live_deflection_limit == 1 / 360
            @test deck.floor.superimposed_deflection_limit == 1 / 240
            @test deck.beams.composite
            @test deck.beams.composite_shored == false
            @test deck.loads.floor_LL == 250.0u"psf"
            @test uconvert(u"lb/ft^3", DECK_FILL.ρ) ≈ 145.0u"lb/ft^3" atol = 0.1u"lb/ft^3"
        end
    end
end
