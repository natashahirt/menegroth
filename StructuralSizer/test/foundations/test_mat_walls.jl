# Wall lines on a mat, and the rigid-method gate.
# ACI 336.2R Eq. (5-1), §5.2, §6.1.2 Step 3 (corpus: aci-336-combined-footings-mats, pages 8–11).

using Test
using Unitful
using StructuralSizer

function _equal_columns()
    demands = FoundationDemand[]
    positions = NTuple{2, typeof(1.0u"m")}[]
    for x in (0.0, 3.0), y in (0.0, 3.0)
        push!(demands, FoundationDemand(length(demands) + 1;
            Pu = 400.0u"kN", Ps = 280.0u"kN", c1 = 18.0u"inch", c2 = 18.0u"inch"))
        push!(positions, (x * u"m", y * u"m"))
    end
    return demands, positions
end

soil = Soil(150.0u"kPa", 18.0u"kN/m^3", 32.0, 0.0u"kPa", 25.0u"MPa";
            ks = 25000.0u"kN/m^3")

@testset "Equal short spans stay on the rigid method" begin
    demands, positions = _equal_columns()
    opts = MatParams(min_depth = 48.0u"inch", on_inapplicable = :fallback)
    result = design_footing(MatFoundation(), demands, positions, soil; opts = opts)
    @test result.analysis == :rigid
    @test result.n_columns == 4
    @test result.utilization <= 1.0
end

@testset "Column loads that vary by more than 20% switch to Winkler" begin
    demands, positions = _equal_columns()
    demands[1] = FoundationDemand(1; Pu = 800.0u"kN", Ps = 560.0u"kN",
                                  c1 = 18.0u"inch", c2 = 18.0u"inch")
    fell = design_footing(MatFoundation(), demands, positions, soil;
                          opts = MatParams(min_depth = 48.0u"inch"))
    @test fell.analysis == :winkler
    @test_throws ArgumentError design_footing(MatFoundation(), demands, positions, soil;
        opts = MatParams(min_depth = 48.0u"inch", on_inapplicable = :error))
end

@testset "A wall line is carried and is not punched" begin
    demands, positions = _equal_columns()
    bare = StructuralSizer._design_mat_rigid(demands, positions, soil;
        opts = MatParams(min_depth = 36.0u"inch"))
    samples = [WallLineSample(s * u"m", 200.0u"kN", 140.0u"kN") for s in (0.0, 4.0)]
    wall = WallLineDemand(1, (0.0u"m", 0.0u"m"), (4.0u"m", 0.0u"m"),
                          0.2u"m", 12.0u"m", samples)
    with = StructuralSizer._design_mat_rigid(demands, positions, soil;
        opts = MatParams(min_depth = 36.0u"inch"), walls = [wall])
    @test with.n_columns == bare.n_columns
    @test with.B > bare.B
    @test with.analysis == :rigid
    @test with.utilization <= 1.0
end

@testset "A closed wall cell with no columns is still a mat" begin
    walls = WallLineDemand[]
    sides = (((0.0, 0.0), (8.0, 0.0)),
             ((8.0, 0.0), (8.0, 8.0)),
             ((8.0, 8.0), (0.0, 8.0)),
             ((0.0, 8.0), (0.0, 0.0)))
    for (p1, p2) in sides
        samples = [WallLineSample(s * u"m", 300.0u"kN", 200.0u"kN") for s in (0.0, 8.0)]
        push!(walls, WallLineDemand(length(walls) + 1,
            (p1[1] * u"m", p1[2] * u"m"), (p2[1] * u"m", p2[2] * u"m"),
            0.3u"m", 14.4u"m", samples))
    end
    result = design_footing(MatFoundation(), FoundationDemand[],
                            NTuple{2, typeof(1.0u"m")}[], soil;
                            opts = MatParams(min_depth = 24.0u"inch"),
                            walls = walls)
    @test result.n_columns == 0
    @test result.analysis == :rigid
    @test result.B > 8.0u"m"
    @test result.L_ftg > 8.0u"m"
    @test result.utilization <= 1.0
end

function _dev_cell()
    walls = WallLineDemand[]
    sides = (((0.0, 0.0), (8.0, 0.0)),
             ((8.0, 0.0), (8.0, 8.0)),
             ((8.0, 8.0), (0.0, 8.0)),
             ((0.0, 8.0), (0.0, 0.0)))
    for (p1, p2) in sides
        samples = [WallLineSample(s * u"m", 300.0u"kN", 200.0u"kN") for s in (0.0, 8.0)]
        push!(walls, WallLineDemand(length(walls) + 1,
            (p1[1] * u"m", p1[2] * u"m"), (p2[1] * u"m", p2[2] * u"m"),
            0.3u"m", 14.4u"m", samples))
    end
    return walls
end

function _same_mat(a, b)
    @test a.B ≈ b.B
    @test a.L_ftg ≈ b.L_ftg
    @test a.D ≈ b.D
    @test a.d ≈ b.d
    @test a.As_x_bot ≈ b.As_x_bot
    @test a.As_x_top ≈ b.As_x_top
    @test a.As_y_bot ≈ b.As_y_bot
    @test a.As_y_top ≈ b.As_y_top
    @test a.steel_volume ≈ b.steel_volume
end

@testset "A lip that develops does not change the plan or the bars" begin
    walls = _dev_cell()
    none = FoundationDemand[]
    pos = NTuple{2, typeof(1.0u"m")}[]
    # 1.2 m past the wall center. Clear lip ≈ 1.05 m; cover 3 in leaves
    # more than the Eq. (12-1) length of a No. 8.
    fit = MatParams(min_depth = 24.0u"inch", edge_overhang = 1.2u"m")
    off = MatParams(min_depth = 24.0u"inch", edge_overhang = 1.2u"m",
                    check_development = false)
    checked = StructuralSizer._design_mat_rigid(none, pos, soil; opts = fit, walls = walls)
    open = StructuralSizer._design_mat_rigid(none, pos, soil; opts = off, walls = walls)
    _same_mat(checked, open)
end

@testset "A short lip grows until the bars develop" begin
    walls = _dev_cell()
    none = FoundationDemand[]
    pos = NTuple{2, typeof(1.0u"m")}[]
    # Lip = 0.20 − 0.15 = 0.05 m, shorter than the cover, so neither a
    # straight bar nor a hook fits. The plan grows and the shear and
    # flexure checks run again on that plan.
    short = MatParams(min_depth = 24.0u"inch", edge_overhang = 0.20u"m")
    held = MatParams(min_depth = 24.0u"inch", edge_overhang = 0.20u"m",
                     check_development = false)
    grown = StructuralSizer._design_mat_rigid(none, pos, soil; opts = short, walls = walls)
    frozen = StructuralSizer._design_mat_rigid(none, pos, soil; opts = held, walls = walls)
    @test frozen.B ≈ 8.4u"m" atol = 1e-6u"m"
    @test frozen.L_ftg ≈ 8.4u"m" atol = 1e-6u"m"
    @test grown.B > frozen.B
    @test grown.L_ftg > frozen.L_ftg
    @test (grown.B - 8.0u"m") / 2 >= 0.20u"m" + 3.0u"inch" - 1.0u"mm"
    @test grown.utilization <= 1.0
    @test grown.As_x_bot > 0.0u"m^2"
    @test grown.As_y_bot > 0.0u"m^2"
end

@testset "A column mat develops from the column face" begin
    demands, positions = _equal_columns()
    # Outer face is 1.5 m − 9 in from the edge. Cover leaves more than ld.
    fit = MatParams(min_depth = 24.0u"inch", edge_overhang = 1.5u"m")
    off = MatParams(min_depth = 24.0u"inch", edge_overhang = 1.5u"m",
                    check_development = false)
    checked = StructuralSizer._design_mat_rigid(demands, positions, soil; opts = fit)
    open = StructuralSizer._design_mat_rigid(demands, positions, soil; opts = off)
    _same_mat(checked, open)

    # 0.15 m does not reach the 9 in column face, so the plan has to grow.
    short = MatParams(min_depth = 24.0u"inch", edge_overhang = 0.15u"m")
    held = MatParams(min_depth = 24.0u"inch", edge_overhang = 0.15u"m",
                     check_development = false)
    grown = StructuralSizer._design_mat_rigid(demands, positions, soil; opts = short)
    frozen = StructuralSizer._design_mat_rigid(demands, positions, soil; opts = held)
    @test grown.B > frozen.B
    @test grown.L_ftg > frozen.L_ftg
    @test grown.utilization <= 1.0
end
