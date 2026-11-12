# Ordinary checks on one isolated pier. The section is given. A failure is recorded.

using Test
using Unitful
using StructuralSynthesizer

function _pier(; length=10.0, height=3.0, thickness=0.40, story=0, along=:X)
    if along === :X
        x2, y2 = length, 0.0
    elseif along === :Y
        x2, y2 = 0.0, length
    else
        x2, y2 = length * 0.6, length * 0.8
    end
    return Wall([1], height * u"m"; thickness=thickness * u"m",
                x1=0.0, y1=0.0, x2=x2, y2=y2, story=story)
end

function _action(name, N, V, M; alternative=:only)
    return CombinedWallAction(name, alternative, Float64(N), Float64(V), Float64(M))
end

function _check(wall, actions; kwargs...)
    return check_ordinary_wall(wall, actions; wall_index=1, material=RC_4000_60,
                               case=:D, boundary=:restrained, kwargs...)
end

function _named(records, name)
    return only(filter(r -> r.check == name, records))
end

@testset "ordinary wall check" begin
    wall = _pier()
    modest = _action(:strength_1_4D, 2.0e5, 5.0e4, 1.0e5)
    records = _check(wall, [modest])
    @test length(records) == 5
    @test all(r.passed for r in records)
    @test all(r.wall_index == 1 && r.story == 0 && r.direction == :X for r in records)
    @test all(r.case == :D && r.combination == :strength_1_4D && r.alternative == :only
              for r in records)
    shear = _named(records, "in-plane shear")
    @test shear.demand ≈ 5.0e4 atol=1e-6
    @test shear.capacity > shear.demand
    @test shear.clause == "ACI 318-19 11.5.4.3"
    @test !any(occursin("out-of-plane", r.check) for r in records)
    @test wall.thickness == 0.40u"m"
    @test wall.ρl == 0.0025 && wall.ρt == 0.0025

    along_y = _check(_pier(; along=:Y), [modest])
    @test all(r.direction == :Y for r in along_y)

    overloaded = _action(:strength_1_2D_1_0W, 2.0e5, 1.0e12, 1.0e5)
    failed = _check(wall, [overloaded]; case=:wind)
    shear_fail = _named(failed, "in-plane shear")
    @test shear_fail.passed == false
    @test shear_fail.ratio > 1
    @test shear_fail.case == :wind
    @test shear_fail.clause == "ACI 318-19 11.5.4.3"
    @test wall.thickness == 0.40u"m"

    reversed = _check(wall, [_action(:strength_1_4D, 2.0e5, -1.0e12, -1.0e5)])
    @test _named(reversed, "in-plane shear").passed == false
    @test _named(reversed, "in-plane shear").demand ≈ 1.0e12 atol=1.0

    tension = _action(:strength_0_9D_1_0E, -1.0e5, 1.0e3, 1.0e3)
    tensioned = _check(wall, [tension]; case=:QE)
    bearing = only(filter(r -> occursin("tension", r.check), tensioned))
    @test bearing.passed == false
    @test bearing.clause == "ACI 318-19 11.5.3"
    @test bearing.demand ≈ -1.0e5 atol=1.0

    squat = _pier(; length=4.0, height=4.0, thickness=0.30)
    above = _pier(; length=4.0, height=4.0, thickness=0.30, story=1)
    squat.wall_above = above
    small = _action(:strength_1_4D, 1.0e5, 1.0e4, 1.0e4)
    stacked = _check(squat, [small])
    explicit = _check(squat, [small]; hw=8.0u"m")
    story_only = _check(_pier(; length=4.0, height=4.0, thickness=0.30), [small])
    @test _named(stacked, "in-plane shear").capacity ≈
          _named(explicit, "in-plane shear").capacity rtol=1e-9
    @test _named(stacked, "in-plane shear").capacity <
          _named(story_only, "in-plane shear").capacity

    skewed = _check(_pier(; along=:skew), [modest])
    @test all(r.direction === :skew for r in skewed)
    @test all(r.passed for r in skewed)
    @test_throws ArgumentError _check(wall, CombinedWallAction[])
    @test_throws ArgumentError check_ordinary_wall(
        wall, [modest]; wall_index=1, material=NWC_4000, case=:D, boundary=:restrained)
    mismatched = _pier()
    mismatched.concrete = NWC_5000
    @test_throws ArgumentError _check(mismatched, [modest])
    @test_throws ArgumentError check_ordinary_wall(
        wall, [modest]; wall_index=1, material=RC_4000_60, case=:D,
        boundary=:restrained, assembly=WallAssembly(0, [1, 2], true))
end

@testset "slab moment outside the middle third" begin
    # h = 0.30 m, h/6 = 0.05 m. N = 500 kN holds a moment of 25 kN·m at the edge
    # of the middle third. ACI 318-19 §11.5.3.1. Past that edge the empirical
    # method is not the strength check; §6.6.4.5 and §22.2 are.
    wall = _pier(; length=8.0, height=3.6, thickness=0.30)
    axial = _action(:strength_1_4D, 500e3, 1.0e3, 1.0e3)
    inside = _check(wall, [axial]; Moop=20e3u"N*m")
    @test any(occursin("bearing", r.check) for r in inside)
    @test !any(occursin("out-of-plane", r.check) for r in inside)

    outside = _check(wall, [axial]; Moop=200e3u"N*m")
    @test !any(occursin("bearing", r.check) for r in outside)
    oop = only(filter(r -> occursin("out-of-plane", r.check), outside))
    @test occursin("22.2", oop.clause)

    huge = _check(wall, [axial]; Moop=5.0e6u"N*m")
    failed = only(filter(r -> occursin("out-of-plane", r.check), huge))
    @test failed.passed == false

    thin = _pier(; length=4.0, height=4.0, thickness=0.20)
    StructuralSynthesizer.select_ordinary_wall_reinforcement!(
        thin, [axial], RC_4000_60; hw=4.0u"m", Moop=5.0e6u"N*m")
    @test thin.ρl > 0.0025
end
