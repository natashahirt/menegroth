# Wall strip plan and the rigid-pressure diagram.
# ACI 318-11 §15.2.2 (aci-318-11, page 271).
# ACI 336.2R §3.2.1 Eq. (3-1) (aci-336-combined-footings-mats, page 6).

using StructuralSizer
using Test
using Unitful

const SS = StructuralSizer

@testset "rectangle union and Eq. 3-1" begin
    a = SS._Aabb(0.0, 4.0, 0.0, 2.0)
    b = SS._Aabb(3.0, 6.0, 0.0, 2.0)
    section = SS._section_of([a, b])
    # 8 + 6 − 2 = 12.
    @test section.A ≈ 12.0 rtol = 1e-9

    # 4 m by 2 m, resultant 0.2 m off center along the length.
    # q = (P/A) (1 ± 6e/L) = (P/A) (1 ± 0.3).
    rect = SS._Aabb(0.0, 4.0, 0.0, 2.0)
    sec = SS._section_of([rect])
    P = 800.0e3
    coeff = SS._linear_pressure(P, sec.cx + 0.2, sec.cy, sec)
    qmin, qmax = SS._q_bounds(coeff, [rect])
    q0 = P / 8.0
    @test qmax ≈ q0 * 1.3 rtol = 1e-9
    @test qmin ≈ q0 * 0.7 rtol = 1e-9
end

@testset "straight wall strip moment" begin
    # Same free body as the mat strip: 20 ft, loads 100 kip at 2 ft and 18 ft,
    # w = 10 kip/ft. Midspan moment is −300 kip·ft (top steel).
    L = 20.0 * 0.3048
    B = 1.0
    w = 10.0 * 4448.2216152605 / 0.3048
    plan = (
        B = B, straight = true,
        section = SS._section_of([SS._Aabb(0.0, L, -B / 2, B / 2)]),
        rects = [SS._Aabb(0.0, L, -B / 2, B / 2)],
        x0 = 0.0, along = L, area = L * B,
    )
    coeff = (a = w / B, b = 0.0, c = 0.0, cx = L / 2, cy = 0.0)
    loads = [(2.0 * 0.3048, 100.0 * 4448.2216152605),
             (18.0 * 0.3048, 100.0 * 4448.2216152605)]
    extremes = SS._straight_extremes(plan, coeff, loads)
    @test ustrip(u"kip*ft", extremes.Mtop * u"N*m") ≈ 300.0 rtol = 0.02
    @test extremes.Mtop > extremes.Mbot
end

@testset "straight wall designs as a rigid strip" begin
    leg = SS.WallLineDemand(1,
        (0.0u"m", 0.0u"m"), (6.0u"m", 0.0u"m"),
        0.30u"m", 40.0u"m",
        [SS.WallLineSample(0.0u"m", 400.0e3u"N", 280.0e3u"N"),
         SS.WallLineSample(6.0u"m", 400.0e3u"N", 280.0e3u"N")])
    soil = Soil(500.0u"kPa", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
                ks = 25000.0u"kN/m^3")
    opts = StripParams(; min_depth = 16.0u"inch", check_bearing = false)
    result = design_footing(StripFooting(), leg, soil; opts = opts)
    @test result.analysis === :rigid
    @test result.n_columns == 0
    @test ustrip(u"m^2", result.B * result.L_ftg) * 500.0e3 >= 560.0e3 * (1 - 1e-6)
    @test ustrip(u"m^2", result.As_long_bot) > 0
    @test ustrip(u"m^2", result.As_long_top) > 0
end

@testset "an L of two walls is one footing" begin
    leg_x = SS.WallLineDemand(1,
        (0.0u"m", 0.0u"m"), (6.0u"m", 0.0u"m"),
        0.30u"m", 40.0u"m",
        [SS.WallLineSample(6.0u"m", 300.0e3u"N", 200.0e3u"N")])
    leg_y = SS.WallLineDemand(2,
        (0.0u"m", 0.0u"m"), (0.0u"m", 6.0u"m"),
        0.30u"m", 40.0u"m",
        [SS.WallLineSample(6.0u"m", 300.0e3u"N", 200.0e3u"N")])
    soil = Soil(500.0u"kPa", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa";
                ks = 25000.0u"kN/m^3")
    opts = StripParams(; min_depth = 16.0u"inch", check_bearing = false)
    result = design_footing(StripFooting(), SS.WallLineDemand[leg_x, leg_y], soil;
                            opts = opts)
    @test result.analysis === :rigid
    @test result.n_columns == 0
    @test ustrip(u"m^2", result.B * result.L_ftg) * 500.0e3 >= 400.0e3 * (1 - 1e-6)
end

@testset "a closed wall cell is not a strip" begin
    legs = SS.WallLineDemand[
        SS.WallLineDemand(1, (0.0u"m", 0.0u"m"), (4.0u"m", 0.0u"m"),
            0.3u"m", 3.0u"m", [SS.WallLineSample(2.0u"m", 100.0e3u"N", 70.0e3u"N")]),
        SS.WallLineDemand(2, (4.0u"m", 0.0u"m"), (4.0u"m", 4.0u"m"),
            0.3u"m", 3.0u"m", [SS.WallLineSample(2.0u"m", 100.0e3u"N", 70.0e3u"N")]),
        SS.WallLineDemand(3, (4.0u"m", 4.0u"m"), (0.0u"m", 4.0u"m"),
            0.3u"m", 3.0u"m", [SS.WallLineSample(2.0u"m", 100.0e3u"N", 70.0e3u"N")]),
        SS.WallLineDemand(4, (0.0u"m", 4.0u"m"), (0.0u"m", 0.0u"m"),
            0.3u"m", 3.0u"m", [SS.WallLineSample(2.0u"m", 100.0e3u"N", 70.0e3u"N")]),
    ]
    soil = Soil(500.0u"kPa", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    @test_throws ArgumentError design_footing(StripFooting(), legs, soil)
end

@testset "a short wall on a wide strip is not rigid" begin
    leg = SS.WallLineDemand(1,
        (0.0u"m", 0.0u"m"), (6.0u"m", 0.0u"m"),
        0.30u"m", 1.0u"m",
        [SS.WallLineSample(3.0u"m", 9000.0e3u"N", 6000.0e3u"N")])
    soil = Soil(150.0u"kPa", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 500.0u"MPa";
                ks = 25000.0u"kN/m^3")
    opts = StripParams(; on_inapplicable = :error, check_bearing = false,
                       check_development = false)
    err = try
        design_footing(StripFooting(), leg, soil; opts = opts)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("0.5", sprint(showerror, err))
end
