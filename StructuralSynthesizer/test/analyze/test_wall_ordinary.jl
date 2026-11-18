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

@testset "slab moment follows the combination" begin
    # h/6 = 0.05 m. At 500 kN the middle-third edge is 25 kN·m.
    # qD = qL = 5 kPa, so 1.2D+1.6L is 14 kPa and 0.9D is 4.5 kPa.
    # The envelope 60 kN·m stays outside the middle third. 0.9D takes
    # 4.5/14 of it, 19.3 kN·m, which is inside.
    wall = _pier(; length=8.0, height=3.6, thickness=0.30)
    basis = (qD = 5000.0, qL = 5000.0, roof = false)
    light = _action(:strength_0_9D_1_0W, 500e3, 1.0e3, 1.0e3)
    heavy = _action(:strength_1_2D_1_6L, 500e3, 1.0e3, 1.0e3)
    paired = _check(wall, [light, heavy]; Moop=60e3u"N*m", slab_basis=basis)
    light_rows = filter(r -> r.combination === :strength_0_9D_1_0W, paired)
    heavy_rows = filter(r -> r.combination === :strength_1_2D_1_6L, paired)
    @test any(occursin("bearing", r.check) for r in light_rows)
    @test !any(occursin("out-of-plane", r.check) for r in light_rows)
    @test any(occursin("out-of-plane", r.check) for r in heavy_rows)
    bare = _check(wall, [light]; Moop=60e3u"N*m")
    @test any(occursin("out-of-plane", r.check) for r in bare)
end

@testset "slab moment pairs each face's dead and live parts" begin
    slab_moment = StructuralSynthesizer._action_slab_moment
    Moop = 76e3u"N*m"
    # Face A: D = 40, L = 10 kN·m. Face B: D = 10, L = 40 kN·m.
    # Envelope over 1.4D and 1.2D + 1.6L: A gives 64, B gives 76, so 76.
    faces = [(D = 40e3, L = 10e3, roof = false), (D = 10e3, L = 40e3, roof = false)]
    basis = (qD = 5000.0, qL = 5000.0, roof = false, faces = faces)
    act(name; alt=:only) = _action(name, 5e5, 1e3, 1e3; alternative=alt)
    # 0.9D: face A governs at 36.
    @test slab_moment(Moop, act(:strength_0_9D_1_0W), basis) ≈ 36e3u"N*m"
    # 1.4D: face A at 56.
    @test slab_moment(Moop, act(:strength_1_4D), basis) ≈ 56e3u"N*m"
    # 1.2D + 1.6L: face B at the envelope.
    @test slab_moment(Moop, act(:strength_1_2D_1_6L), basis) ≈ Moop
    # 1.2D + 1.0E + L: A at 48 + 10 = 58 over B at 12 + 40 = 52.
    @test slab_moment(Moop, act(:strength_1_2D_1_0E), basis) ≈ 58e3u"N*m"
    # The :W reading of combination 3 drops floor live: A at 48.
    @test slab_moment(Moop, act(:strength_1_2D_1_6Lr; alt=:W), basis) ≈ 48e3u"N*m"
    # The pier's share scales Moop and the scale carries it.
    @test slab_moment(Moop / 2, act(:strength_1_4D), basis) ≈ 28e3u"N*m"

    # A roof face takes the combination's Lr. 1.2D + 1.6L carries 0.5Lr:
    # 48 + 5 = 53 on A, 12 + 20 = 32 on B.
    roof = (qD = 5000.0, qL = 5000.0, roof = true,
            faces = [(f..., roof = true) for f in faces])
    @test slab_moment(Moop, act(:strength_1_2D_1_6L), roof) ≈ 53e3u"N*m"

    # Sagging dead that live overcomes is zero, not negative.
    lifted = (qD = 5000.0, qL = 5000.0, roof = false,
              faces = [(D = -10e3, L = 50e3, roof = false)])
    @test slab_moment(68e3u"N*m", act(:strength_0_9D_1_0W), lifted) == 0.0u"N*m"
    @test slab_moment(68e3u"N*m", act(:strength_1_2D_1_6L), lifted) ≈ 68e3u"N*m"

    # Without faces the pressures pair the moment: 0.9·5 / 14 of it.
    unpaired = (qD = 5000.0, qL = 5000.0, roof = false, faces = nothing)
    @test slab_moment(Moop, act(:strength_0_9D_1_0W), unpaired) ≈ Moop * 4.5 / 14
end

@testset "a wall reads the face parts of its span direction" begin
    parts = StructuralSynthesizer._directed_wall_face_parts
    slab = (spans = (primary = 8.0u"m", secondary = 8.0u"m", axis = (1.0, 0.0)),)
    result = (M_wall = 50.0u"kN*m", M_wall_secondary = 30.0u"kN*m",
              wall_face_parts = [(30e3, 10e3)],
              wall_face_parts_secondary = [(20e3, 5e3)])
    # Along y the wall is across the primary span; along x, the secondary.
    @test parts(result, slab, 0.0, 1.0) == [(30e3, 10e3)]
    @test parts(result, slab, 1.0, 0.0) == [(20e3, 5e3)]
    @test parts(result, slab, sqrt(0.5), sqrt(0.5)) == [(30e3, 10e3), (20e3, 5e3)]
    # A direction with a moment but no parts leaves nothing to pair.
    bare = (result..., wall_face_parts_secondary = Tuple{Float64,Float64}[])
    @test isempty(parts(bare, slab, sqrt(0.5), sqrt(0.5)))
    # A direction without a wall moment is not read.
    quiet = (bare..., M_wall_secondary = 0.0u"kN*m")
    @test parts(quiet, slab, sqrt(0.5), sqrt(0.5)) == [(30e3, 10e3)]
end
