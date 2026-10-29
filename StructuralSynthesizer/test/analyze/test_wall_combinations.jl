# One combination, one concurrent pier (N, M, V).
#
# The arithmetic does not build a building. The pier cut that feeds it is
# checked on the two-story fixture in test_wall_story_cuts.jl.

using Test
using Unitful
using StructuralSynthesizer

function _wall_x()
    return Wall([1], 6.0u"m"; thickness=0.3u"m", x1=0.0, y1=0.0, x2=6.0, y2=0.0)
end

function _wall_y()
    return Wall([1], 4.0u"m"; thickness=0.3u"m", x1=0.0, y1=0.0, x2=0.0, y2=4.0)
end

function _gravity(; roof::Symbol=:Lr)
    return PierGravityActions(roof,
        WallAction(1000.0, 10.0, 100.0),
        WallAction(200.0, 1.0, 4.0),
        WallAction(50.0, 0.5, 2.0))
end

const _WIND = WallAction(0.0, 80.0, 400.0)
const _QE = WallAction(5.0, 100.0, 500.0)
const _RHO = 1.3
const _SDS = 1.0

@testset "pier axes" begin
    along_x = wall_action_from_global(_wall_x(), 10.0, 7.0, -1000.0, 3.0, 40.0, 9.0)
    @test along_x.N ≈ 1000.0
    @test along_x.V ≈ 10.0
    @test along_x.M ≈ 40.0

    along_y = wall_action_from_global(_wall_y(), 7.0, 10.0, -20.0, -40.0, 3.0, 1.0)
    @test along_y.N ≈ 20.0
    @test along_y.V ≈ 10.0
    @test along_y.M ≈ 40.0
end

@testset "one combination keeps N, V, and M together" begin
    g = _gravity()
    d = combine_wall_action(strength_1_4D, g)
    @test d.alternative === :only
    @test d.N ≈ 1.4 * 1000.0
    @test d.V ≈ 1.4 * 10.0
    @test d.M ≈ 1.4 * 100.0

    live = combine_wall_action(strength_1_2D_1_6L, g)
    @test live.N ≈ 1.2 * 1000.0 + 1.6 * 200.0 + 0.5 * 50.0
    @test live.V ≈ 1.2 * 10.0 + 1.6 * 1.0 + 0.5 * 0.5
    @test live.M ≈ 1.2 * 100.0 + 1.6 * 4.0 + 0.5 * 2.0

    # Snow is not added on top of roof live. This companion is :Lr.
    snow = combine_wall_action(strength_1_2D_1_0E, g; qe=_QE, rho=_RHO, SDS=_SDS)
    @test snow.N ≈ 1.2 * 1000.0 + 1.0 * 200.0 + _RHO * 5.0 + 0.2 * _SDS * 1000.0
    @test snow.V ≈ 1.2 * 10.0 + 1.0 * 1.0 + _RHO * 100.0
    @test snow.M ≈ 1.2 * 100.0 + 1.0 * 4.0 + _RHO * 500.0

    as_snow = combine_wall_action(strength_1_2D_1_0E, _gravity(roof=:S);
                                  qe=_QE, rho=_RHO, SDS=_SDS)
    @test as_snow.N ≈ snow.N + 0.15 * 50.0
    @test as_snow.V ≈ snow.V + 0.15 * 0.5

    tension = combine_wall_action(strength_0_9D_1_0E, g; qe=_QE, rho=_RHO, SDS=_SDS)
    @test tension.N ≈ 0.9 * 1000.0 + _RHO * 5.0 - 0.2 * _SDS * 1000.0
    @test tension.V ≈ 0.9 * 10.0 + _RHO * 100.0
    @test tension.M ≈ 0.9 * 100.0 + _RHO * 500.0

    winded = combine_wall_action(strength_1_2D_1_0W, g; wind=_WIND)
    @test winded.N ≈ 1.2 * 1000.0 + 1.0 * 200.0 + 0.5 * 50.0
    @test winded.V ≈ 1.2 * 10.0 + 1.0 * 1.0 + 0.5 * 0.5 + 80.0
    @test winded.M ≈ 1.2 * 100.0 + 1.0 * 4.0 + 0.5 * 2.0 + 400.0

    uplift = combine_wall_action(strength_0_9D_1_0W, g; wind=_WIND)
    @test uplift.N ≈ 0.9 * 1000.0
    @test uplift.V ≈ 0.9 * 10.0 + 80.0
    @test uplift.M ≈ 0.9 * 100.0 + 400.0
end

@testset "combination 3 does not add L and 0.5W" begin
    g = _gravity()
    with_live = combine_wall_action(strength_1_2D_1_6Lr, g; wind=_WIND, alternative=:L)
    with_wind = combine_wall_action(strength_1_2D_1_6Lr, g; wind=_WIND, alternative=:W)
    @test with_live.alternative === :L
    @test with_wind.alternative === :W
    @test with_live.N ≈ 1.2 * 1000.0 + 1.0 * 200.0 + 1.6 * 50.0
    @test with_live.V ≈ 1.2 * 10.0 + 1.0 * 1.0 + 1.6 * 0.5
    @test with_wind.N ≈ 1.2 * 1000.0 + 1.6 * 50.0
    @test with_wind.V ≈ 1.2 * 10.0 + 1.6 * 0.5 + 0.5 * 80.0
    @test with_wind.M ≈ 1.2 * 100.0 + 1.6 * 2.0 + 0.5 * 400.0
    @test_throws ArgumentError combine_wall_action(strength_1_2D_1_6L, g; alternative=:L)
    @test_throws ArgumentError combine_wall_action(strength_1_2D_1_6Lr, g; alternative=:W)
end

@testset "rho and SDS are not assumed" begin
    g = _gravity()
    @test_throws ArgumentError combine_wall_action(strength_1_2D_1_0E, g; qe=_QE, SDS=_SDS)
    @test_throws ArgumentError combine_wall_action(strength_1_2D_1_0E, g; qe=_QE, rho=_RHO)
    @test_throws ArgumentError combine_wall_action(strength_1_2D_1_0E, g; rho=_RHO, SDS=_SDS)
    @test_throws ArgumentError combine_wall_action(strength_1_2D_1_0W, g)
    @test_throws ArgumentError combine_wall_action(strength_0_9D_1_0E, g; qe=_QE, rho=0.0, SDS=_SDS)

    all_cases = wall_strength_actions(g; wind=_WIND, qe=_QE, rho=_RHO, SDS=_SDS)
    @test length(all_cases) == 8
    @test count(c -> c.combination === :strength_1_2D_1_6Lr, all_cases) == 2
    seismic = only(c for c in all_cases if c.combination === :strength_1_2D_1_0E)
    @test seismic.V ≈ 1.2 * 10.0 + 1.0 * 1.0 + _RHO * 100.0
    @test seismic.N ≈ seismic.V * 0 + (1.2 * 1000.0 + 1.0 * 200.0 + _RHO * 5.0 + 0.2 * _SDS * 1000.0)
end
