# Added end bars: §18.10.2.4 (corpus: aci-318-19, page 322), hx of §18.10.6.4(f)
# (page 328), and the §25.2.3 clear spacing (page 469).

using Test
using Unitful
using StructuralSizer

const _FC = 4000.0u"psi"
const _FY = 60.0u"ksi"
const _ES = 29000.0u"ksi"

@testset "The end ratio is 6√f′c/fy over 0.15ℓw" begin
    ratio = special_end_reinforcement_ratio(_FC, _FY)
    @test ratio.ρ ≈ 6 * sqrt(4000) / 60000
    area = special_end_minimum_area(_FC, _FY, 6.0u"m", 0.3u"m")
    @test area.area ≈ ratio.ρ * 0.15 * 6.0u"m" * 0.3u"m"
    @test area.width ≈ 0.9u"m"
end

@testset "The zone is the longer end, and the two ends do not meet" begin
    both = special_end_zone(6.0u"m"; boundary_length = 1.2u"m", code_minimum = true)
    @test both.zone ≈ 1.2u"m"
    ratio_only = special_end_zone(6.0u"m"; code_minimum = true)
    @test ratio_only.zone ≈ 0.9u"m"
    @test special_end_zone(6.0u"m").zone === nothing
    @test_throws ArgumentError special_end_zone(6.0u"m"; boundary_length = 3.0u"m")
end

@testset "The bars extend the greater of ℓw and Mu/3Vu" begin
    short = special_end_bar_extension(2.0u"m", 3.0e6u"N*m", 1.0e6u"N")
    @test short.from_shear ≈ 1.0u"m"
    @test short.extension ≈ 2.0u"m"
    long = special_end_bar_extension(2.0u"m", 9.0e6u"N*m", 1.0e6u"N")
    @test long.extension ≈ 3.0u"m"
end

@testset "The smallest bar that fits is spaced at most hx" begin
    # 2 in² is below what hx places across a 0.9 m zone.
    layout = boundary_end_bar_layout(2.0u"inch^2", 0.9u"m", 0.3u"m")
    @test layout.bar in StructuralSizer.BOUNDARY_END_BAR_SIZES
    @test layout.layers >= 2
    @test layout.area >= 2.0u"inch^2"
    @test layout.per_layer == 1 || layout.spacing <= layout.hx + 0.01u"inch"
    @test layout.inset > 0u"inch"
    @test layout.inset < 0.9u"m"
    # More area than hx already placed still fits, in a larger bar or more bars.
    more = boundary_end_bar_layout(layout.area + 4.0u"inch^2", 0.9u"m", 0.3u"m")
    @test more.area >= layout.area + 4.0u"inch^2" - 0.05u"inch^2"
    @test_throws ArgumentError boundary_end_bar_layout(80.0u"inch^2", 0.3u"m", 0.2u"m")
end

@testset "End bars raise the moment, and the search stops at the first area that passes" begin
    fc = ustrip(u"Pa", _FC)
    fy = ustrip(u"Pa", _FY)
    Es = ustrip(u"Pa", _ES)
    lw, t = 6.0, 0.3
    Ast = 0.0025 * lw * t
    inset = 0.3
    web = wall_moment_capacity_at_axial_si(fc, fy, Es, lw, t, Ast, 0.0)
    added = wall_end_bar_capacity_si(fc, fy, Es, lw, t, Ast, 0.002, inset, 0.0)
    @test added.converged
    @test added.φMn > web.φMn
    # Above the web capacity, below the end-bar capacity.
    target = 0.5 * (web.φMn + added.φMn)
    found = boundary_end_area_si(fc, fy, Es, lw, t, Ast, inset, [(0.0, target)], 0.0)
    @test found !== nothing
    @test found < 0.002
    @test found > 0
    capped = wall_end_bar_capacity_si(fc, fy, Es, lw, t, Ast, found, inset, 0.0)
    @test target <= capped.φMn + 1.0
    half = wall_end_bar_capacity_si(fc, fy, Es, lw, t, Ast, found / 2, inset, 0.0)
    @test target > half.φMn + 1.0
end
