# A joist drawn toward −X, at the default roll π/2, has local y pointing down.
# `default_seat_eccentricity` returns a physical upward seat (positive local y
# = global up). `orient_up_eccentricity` signs slot 3, `e_f2`, so the rigid
# offset `θ × e` in `eccentricity_transformation!` puts that seat above the
# girder for both directions. A web-below offset is the same convention with
# a negative physical component, and must stay below the slab on a −X beam.
# A vertical member has no up/down seat: slot 3 is left unchanged.

using Test
using Unitful
using StructuralSizer
using Asap

"""Global Z of both rigid-offset ends, using the axes `process!` stored."""
function _offset_end_z(el)
    f1, f2, f3 = el.LCS
    e1, e2, ef2, ef3 = el.eccentricity
    zs = Float64[]
    for (node, axial) in ((el.nodeStart, e1), (el.nodeEnd, e2))
        p = [ustrip(u"m", node.position[k]) for k in 1:3]
        q = p .+ axial .* f1 .+ ef2 .* f2 .+ ef3 .* f3
        push!(zs, q[3])
    end
    return zs
end

@testset "Up eccentricity follows global Z" begin
    # Production steel-joist seat. Slot 3 is (host depth + joist depth) / 2.
    up = default_seat_eccentricity(:joist, A992_Steel, 0.50u"m", 0.30u"m")
    @test up[1] == 0.0 && up[2] == 0.0 && up[4] == 0.0
    @test up[3] > 0

    z = 4.0
    sec = Asap.Section(0.01u"m^2", 200e9u"Pa", 80e9u"Pa",
                       1.0e-4u"m^4", 1.0e-4u"m^4", 1.0e-5u"m^4", 7850.0u"kg/m^3")
    girder_a = Asap.Node([0.0u"m", 0.0u"m", z * u"m"], :pinned)
    girder_b = Asap.Node([10.0u"m", 0.0u"m", z * u"m"], :pinned)
    # Joist drawn toward +X, and one drawn toward −X, at the girder elevation.
    plus_a = Asap.Node([0.0u"m", 2.0u"m", z * u"m"], :free)
    plus_b = Asap.Node([6.0u"m", 2.0u"m", z * u"m"], :free)
    minus_a = Asap.Node([6.0u"m", 4.0u"m", z * u"m"], :free)
    minus_b = Asap.Node([0.0u"m", 4.0u"m", z * u"m"], :free)
    # Confirmed failure direction: axis (−1, +1).
    diag_a = Asap.Node([6.0u"m", 1.0u"m", z * u"m"], :free)
    diag_b = Asap.Node([3.0u"m", 4.0u"m", z * u"m"], :free)

    seated(a, b) = Asap.Element(a, b, sec; eccentricity = Asap.orient_up_eccentricity(up, a, b))
    girder = Asap.Element(girder_a, girder_b, sec, :girder)
    joist_plus = seated(plus_a, plus_b)
    joist_minus = seated(minus_a, minus_b)
    joist_diag = seated(diag_a, diag_b)
    nodes = [girder_a, girder_b, plus_a, plus_b, minus_a, minus_b, diag_a, diag_b]
    elements = [girder, joist_plus, joist_minus, joist_diag]
    Asap.process!(Asap.FrameModel(nodes, elements, Asap.AbstractLoad[]))

    expect = z + up[3]
    z_plus = _offset_end_z(joist_plus)
    z_minus = _offset_end_z(joist_minus)
    z_diag = _offset_end_z(joist_diag)
    @test all(≈(expect), z_plus)
    @test all(≈(expect), z_minus)
    @test all(≈(expect), z_diag)
    @test z_plus[1] ≈ z_minus[1]
    @test expect > z
    # Slot 3 is the only component the helper may change, and only when
    # local y is not already up.
    @test joist_plus.eccentricity[3] ≈ up[3]
    @test joist_minus.eccentricity[1] == 0.0
    @test joist_minus.eccentricity[2] == 0.0
    @test joist_minus.eccentricity[4] == 0.0
    @test joist_minus.eccentricity[3] ≈ -up[3]

    # Production web-below offset: negative physical up, centroid under the
    # slab mid-plane. A beam drawn toward −X must stay below.
    below = StructuralSizer.web_below_slab_eccentricity(0.20u"m", 0.50u"m")
    @test below[3] < 0
    slab_z = 3.0
    web_a = Asap.Node([8.0u"m", 1.0u"m", slab_z * u"m"], :pinned)
    web_b = Asap.Node([1.0u"m", 1.0u"m", slab_z * u"m"], :free)
    web_plus_a = Asap.Node([1.0u"m", 3.0u"m", slab_z * u"m"], :pinned)
    web_plus_b = Asap.Node([8.0u"m", 3.0u"m", slab_z * u"m"], :free)
    web = Asap.Element(web_a, web_b, sec, :web_minus;
                       eccentricity = Asap.orient_up_eccentricity(below, web_a, web_b))
    web_plus = Asap.Element(web_plus_a, web_plus_b, sec, :web_plus;
                            eccentricity = Asap.orient_up_eccentricity(below, web_plus_a, web_plus_b))
    Asap.process!(Asap.FrameModel(
        [web_a, web_b, web_plus_a, web_plus_b], [web, web_plus], Asap.AbstractLoad[]))
    expect_web = slab_z + below[3]
    z_web = _offset_end_z(web)
    z_web_plus = _offset_end_z(web_plus)
    @test all(<(slab_z), z_web)
    @test all(≈(expect_web), z_web)
    @test all(≈(expect_web), z_web_plus)

    # A vertical member has no up/down seat. Either travel direction.
    raw = (0.1, -0.2, 0.35, -0.05)
    foot = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], :fixed)
    head = Asap.Node([0.0u"m", 0.0u"m", 3.0u"m"], :free)
    @test Asap.orient_up_eccentricity(raw, foot, head) == raw
    @test Asap.orient_up_eccentricity(raw, head, foot) == raw

    # A zero chord has no local y. Leave the tuple unchanged and do not throw.
    same = Asap.Node([1.0u"m", 2.0u"m", 3.0u"m"], :free)
    same2 = Asap.Node([1.0u"m", 2.0u"m", 3.0u"m"], :free)
    @test Asap.orient_up_eccentricity(raw, same, same2) == raw
end
