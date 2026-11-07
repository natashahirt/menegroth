# Wall bar placement on a building: ratios, an opening, a corner, and the scene record.

using Test
using Unitful
using StructuralSynthesizer

function _shear_record(idx, Vu_N)
    return WallCheckRecord(idx, 0, :X, :D, :strength_1_4D, :only,
                           "in-plane shear", true, 0.2, Float64(Vu_N), 1.0e6,
                           "ACI 318-19 11.5.4.3")
end

@testset "wall detailing on a building" begin
    skel = gen_medium_office(20.0u"ft", 20.0u"ft", 12.0u"ft", 1, 1, 1)
    struc = BuildingStructure(skel)
    empty!(struc.walls)
    push!(struc.walls, Wall([1], 3.658u"m"; thickness = 0.3048u"m",
                            x1 = 0.0, y1 = 0.0, x2 = 6.096, y2 = 0.0,
                            openings = [WallOpening(1.5, 0.0, 0.9, 2.1, :door)]))
    push!(struc.walls, Wall([1], 3.658u"m"; thickness = 0.3048u"m",
                            x1 = 6.096, y1 = 0.0, x2 = 6.096, y2 = 4.0))
    design = BuildingDesign(struc, DesignParameters(name = "wall detail", skip_visualization = true))
    design.walls[1] = [_shear_record(1, 50_000.0)]
    design.walls[2] = [_shear_record(2, 50_000.0)]

    bd = detail_building(design)
    @test isempty(bd.errors)
    @test length(bd.walls) == 2
    pier = bd.walls[1]
    @test !isempty(pier.groups)
    @test length(pier.voids) == 1
    @test any(g -> g.role === :trim, pier.groups)
    @test any(g -> g.role === :dowel, pier.groups)
    leg = bd.walls[2]
    @test any(g -> g.role === :horizontal && occursin("corner lap", g.note), leg.groups)
    # The pier's ratios are the calculated areas. Placed bars have to cover them.
    # ρ · ℓw · h and ρ · height · h, with ℓw = 4 m, height = 3.658 m, h = 0.3048 m.
    Ab(g) = ustrip(u"m^2", StructuralSizer.bar_area(g.bar_size))
    placed(role) = sum(g -> g.count * Ab(g), (g for g in leg.groups if g.role === role); init = 0.0)
    @test placed(:vertical) >= 0.0025 * 4.0 * 0.3048
    @test placed(:horizontal) >= 0.0025 * 3.658 * 0.3048
    smear = (0.0025 + 0.0025) * 4.0 * 3.658 * 0.3048
    # Takeoff volume exceeds the smeared volume: spacing rounds down, and the
    # centerlines include hooks, the corner lap, and the dowels.
    vol = sum(leg.groups) do g
        g.count * ustrip(u"m", g.length) * ustrip(u"m^2", StructuralSizer.bar_area(g.bar_size))
    end
    @test vol > smear

    rec = StructuralSynthesizer._detail_record(pier)
    @test rec["kind"] == "wall"
    @test !isempty(rec["groups"])
    @test length(rec["voids_m"]) == 1
    @test !isempty(rec["section_dots_m"])
    @test haskey(rec["groups"][1], "z_positions_m")
    areas = rec["areas_in2"]
    @test areas["vertical_placed_in2"] >= areas["vertical_ideal_in2"]
    @test areas["horizontal_placed_in2"] >= areas["horizontal_ideal_in2"]
end
