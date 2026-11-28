# Story selection, method catalog, and recorded option fields.
# No slab is designed.

using Test

include(joinpath(@__DIR__, "..", "src", "flat_plate_methods",
                 "building_scale_analysis.jl"))

@testset "Intermediate story" begin
    three = Dict(1 => [1], 2 => [2], 3 => [3])
    @test _intermediate_story(three) == 2
    two = Dict(1 => [1], 2 => [2])
    @test _intermediate_story(two) == 1
    @test _intermediate_story(Dict(4 => [7])) == 4
    @test isnothing(_intermediate_story(Dict{Int,Vector{Int}}()))
end

@testset "Canonical method catalog" begin
    @test length(CORE_METHODS) == 6
    @test [m.name for m in CORE_METHODS] == [
        "ACI Min", "DDM (Full)", "EFM (ASAP)",
        "FEA (frame)", "FEA (strip)", "FEA (area)",
    ]
    @test all(m -> m.name in ("MDDM", "EFM (HC)", "EFM (Kc)"),
              SENSITIVITY_METHODS)
    @test !any(m -> m.name == "MDDM", CORE_METHODS)
end

@testset "Recorded design options" begin
    fields = _option_fields(nothing)
    @test fields.shear_demand_source == "analytical"
    @test fields.defl_limit == "L/240"
    @test _option_fields(nothing; deflection_limit = :L_360).defl_limit == "L/360"
    @test_throws ErrorException _option_fields(nothing; deflection_limit = :L_999)
    @test occursin("9.5(b)", fields.defl_category)
    fea = _option_fields(SR.FEA(; pattern_loading=true, pattern_mode=:efm_amp,
                                 design_approach=:frame))
    @test fea.pattern_mode == "efm_amp"
    @test fea.pattern_requested == true
    @test fea.design_approach == "frame"
    @test isnan(fea.averaging_width_factor)
    wide = _option_fields(SR.FEA(; averaging_width_factor=2.5))
    @test wide.averaging_width_factor == 2.5
    @test isnan(_option_fields(SR.DDM(:full)).averaging_width_factor)
end

@testset "Reported-floor column sizes and the E5 cap" begin
    inch = u"inch"
    columns = [
        (story = 2, c1 = 16inch, c2 = 18inch, position = :edge),
        (story = 2, c1 = 14inch, c2 = 14inch, position = :interior),
        (story = 2, c1 = 12inch, c2 = 12inch, position = :corner),
        (story = 1, c1 = 30inch, c2 = 30inch, position = :interior),
        (story = 3, c1 = 10inch, c2 = 10inch, position = :edge),
    ]
    floor = _story_column_sizes(columns, 2; cap_in = 36.0, increment_in = 0.5)
    @test floor.col_c1_in == 16
    @test floor.col_c2_in == 18
    @test floor.col_min_c1_in == 12
    @test floor.col_c1_edge_in == 16
    @test floor.col_c2_edge_in == 18
    @test floor.col_c1_interior_in == 14
    @test floor.col_c1_corner_in == 12
    @test floor.col_at_cap == false
    capped = _story_column_sizes(columns, 2; cap_in = 18.0, increment_in = 0.5)
    @test capped.col_at_cap
    @test span15_max_col(20.0) == 16.0
    @test span15_max_col(30.0) == 24.0
    @test span15_max_col(52.0) == 36.0
    @test _resolve_max_col(20.0) == 16.0
    @test _resolve_max_col(20.0; column_cap = :adaptive) == 36.0
    @test _resolve_max_col(20.0; max_col_in = 24.0) == 24.0
    @test _resolve_max_col(20.0; max_col_in = 24.0, column_cap = :adaptive) == 24.0
    @test_throws ErrorException _resolve_max_col(20.0; column_cap = :e5)
end
