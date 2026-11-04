# Joined ordinary walls: each leg on its own cut, corners by shear friction.
#
# Geometry tests do not build a model. The panel tests are Asap shells with
# a known load, the same size as the single-wall cut tests.

using Test
using Unitful
using Asap
using LinearAlgebra: dot
using StructuralSynthesizer

const _PJ = 1.0e5  # N

function _jwall(x1, y1, x2, y2; story=0, thickness=0.3, height=4.0, segs=[1])
    return Wall(segs, height * u"m"; thickness=thickness * u"m",
                x1=x1, y1=y1, x2=x2, y2=y2, story=story)
end

function _dir(w)
    dx = w.x2 - w.x1
    dy = w.y2 - w.y1
    L = hypot(dx, dy)
    return (dx / L, dy / L)
end

function _fold(a, b)
    α = acos(clamp(dot(a, b), -1.0, 1.0))
    return α <= π / 2 ? α : π - α
end

"""Walls sharing nodes within 1 mm, `nx` bays along each leg and `nz` up."""
function _shared_panels(lines, z0, z1; nx=3, nz=2, t=0.3)
    nodes = Asap.Node[]
    function node(x, y, z)
        for nd in nodes
            p = nd.position
            dx = ustrip(u"m", p[1]) - x
            dy = ustrip(u"m", p[2]) - y
            dz = ustrip(u"m", p[3]) - z
            dx * dx + dy * dy + dz * dz < 1e-12 && return nd
        end
        fix = isapprox(z, z0; atol=1e-9) ? :fixed : :free
        nd = Asap.Node([x, y, z] .* u"m", fix, :wall)
        push!(nodes, nd)
        return nd
    end
    shells_by = Vector{Asap.ShellTri3}[]
    for (x1, y1, x2, y2) in lines
        shells = Asap.ShellTri3[]
        for c in 0:(nx - 1), r in 0:(nz - 1)
            s0 = c / nx
            s1 = (c + 1) / nx
            za = z0 + (z1 - z0) * r / nz
            zb = z0 + (z1 - z0) * (r + 1) / nz
            xa = x1 + (x2 - x1) * s0
            ya = y1 + (y2 - y1) * s0
            xb = x1 + (x2 - x1) * s1
            yb = y1 + (y2 - y1) * s1
            n00 = node(xa, ya, za)
            n10 = node(xb, yb, za)
            n11 = node(xb, yb, zb)
            n01 = node(xa, ya, zb)
            push!(shells, Asap.ShellTri3((n00, n10, n11), t * u"m", 30e9u"Pa", 0.2; id=:wall))
            push!(shells, Asap.ShellTri3((n00, n11, n01), t * u"m", 30e9u"Pa", 0.2; id=:wall))
        end
        push!(shells_by, shells)
    end
    return nodes, shells_by
end

function _at(nodes, x, y, z)
    hits = Asap.Node[]
    for nd in nodes
        p = nd.position
        hypot(ustrip(u"m", p[1]) - x, ustrip(u"m", p[2]) - y) <= 1e-6 &&
            isapprox(ustrip(u"m", p[3]), z; atol=1e-6) && push!(hits, nd)
    end
    return only(hits)
end

function _solve(lines, loads_at; z1=4.0)
    nodes, shells_by = _shared_panels(lines, 0.0, z1)
    loads = Asap.AbstractLoad[]
    for (x, y, z, fx, fy, fz) in loads_at
        push!(loads, Asap.NodeForce(_at(nodes, x, y, z),
                                    [fx, fy, fz] .* u"N"))
    end
    shells = Asap.ShellTri3[]
    for group in shells_by
        append!(shells, group)
    end
    model = Asap.Model(nodes, shells, loads)
    Asap.solve!(model)
    walls = [_jwall(x1, y1, x2, y2) for (x1, y1, x2, y2) in lines]
    mesh = WallMesh(shells_by, wall_assemblies(walls))
    return model, mesh, walls, loads
end

@testset "joined ordinary walls" begin
    @testset "T-junctions split; colinear walls and crossings do not" begin
        web = _jwall(0, 0, 3, 0)
        flange = _jwall(3, -2, 3, 2; segs=[2])
        upper = _jwall(3, -2, 3, 2; story=1)
        flange.wall_above = upper
        walls = [web, flange]
        split_tee_junctions!(walls)
        @test length(walls) == 3
        @test walls[1] === web
        @test web.x1 == 0 && web.x2 == 3
        @test walls[2] === flange
        @test flange.base.segment_indices == [2]
        @test walls[3].base.segment_indices == Int[]
        @test flange.wall_above === upper
        @test walls[3].wall_above === upper
        ys = sort!([flange.y1, flange.y2, walls[3].y1, walls[3].y2])
        @test ys ≈ [-2.0, 0.0, 0.0, 2.0]
        split_tee_junctions!(walls)
        @test length(walls) == 3

        straight = [_jwall(0, 0, 3, 0), _jwall(3, 0, 6, 0)]
        split_tee_junctions!(straight)
        @test length(straight) == 2

        # Ends of neither wall lie on the other. An X is not a T.
        cross = [_jwall(0, 0, 4, 0), _jwall(2, -2, 2, 2)]
        split_tee_junctions!(cross)
        @test length(cross) == 2
    end

    @testset "clear length uses (t/2)/sin(φ) and refuses a vanished pier" begin
        leg = _jwall(0, 0, 6, 0)
        stem = _jwall(0, 0, 0, 4)
        @test joined_clear_length(leg, [leg, stem], 1) ≈ 6.0 - 0.15 atol=1e-12
        skew = _jwall(0, 0, 4 * 0.5, 4 * sin(π / 3))
        @test joined_clear_length(leg, [leg, skew], 1) ≈
              6.0 - (0.15 / sin(π / 3)) atol=1e-12

        # Both ends meet a neighbour. Half of each thickness is more than the pier.
        short = _jwall(0, 0, 0.2, 0)
        left = _jwall(0, 0, 0, 2)
        right = _jwall(0.2, 0, 0.2, 2)
        @test_throws ArgumentError joined_clear_length(short, [short, left, right], 1)

        web = _jwall(0, 0, 3, 0)
        flange = _jwall(3, -2, 3, 2)
        pieces = [web, flange]
        split_tee_junctions!(pieces)
        # The through-wall piece meets the stem at 90° and its twin colinearly.
        @test joined_clear_length(pieces[2], pieces, 2) ≈ 2.0 - 0.15 atol=1e-9
    end

    @testset "a regular octagon miters both ends of each side" begin
        s = 4.0
        t = 0.3
        R = s / (2 * sin(π / 8))
        verts = [(R * cos(i * π / 4), R * sin(i * π / 4)) for i in 0:7]
        walls = [_jwall(verts[i][1], verts[i][2],
                        verts[mod1(i + 1, 8)][1], verts[mod1(i + 1, 8)][2];
                        thickness=t) for i in 1:8]
        φ = _fold(_dir(walls[1]), _dir(walls[2]))
        @test φ ≈ π / 4 atol=1e-9
        @test joined_clear_length(walls[1], walls, 1) ≈
              s - 2 * ((t / 2) / sin(φ)) atol=1e-9
        asm = only(wall_assemblies(walls))
        @test asm.joined
        @test length(assembly_corners(walls, asm)) == 8
    end

    @testset "shear friction matches Table 22.9.4.2 and 22.9.4.4" begin
        fc = 4000.0 * PSI_TO_PA
        fy = 60_000.0 * PSI_TO_PA
        Ac = 0.2 * 3.0
        Avf = 1.0e-4 * Ac
        cap = monolithic_shear_friction_si(fc, fy, Ac, Avf)
        Ac_in2 = Ac / IN_TO_M^2
        Avf_in2 = Avf / IN_TO_M^2
        Vn_lb = 1.4 * Avf_in2 * 60_000.0
        cap_lb = min(0.2 * 4000.0 * Ac_in2,
                     (480.0 + 0.08 * 4000.0) * Ac_in2,
                     1600.0 * Ac_in2)
        @test Vn_lb < cap_lb
        @test cap.μ ≈ 1.4
        @test cap.Vn ≈ Vn_lb * LBF_TO_N rtol=1e-9
        @test cap.ϕVn ≈ WALL_PHI_SHEAR * cap.Vn rtol=1e-12
        high = monolithic_shear_friction_si(fc, 80_000.0 * PSI_TO_PA, Ac, Avf)
        @test high.Vn ≈ cap.Vn rtol=1e-12

        Avf_big = 0.2 * Ac
        nw = monolithic_shear_friction_si(fc, fy, Ac, Avf_big; λ=1.0)
        lt = monolithic_shear_friction_si(fc, fy, Ac, Avf_big; λ=0.75)
        @test nw.Vn_max ≈ min(0.2 * 4000.0, 480.0 + 0.08 * 4000.0, 1600.0) *
                          Ac_in2 * LBF_TO_N rtol=1e-9
        @test lt.Vn_max ≈ min(0.2 * 4000.0, 800.0) * Ac_in2 * LBF_TO_N rtol=1e-9
        @test lt.μ ≈ 1.4 * 0.75

        fail = check_monolithic_shear_friction(fc, fy, Ac, Avf, cap.ϕVn * 1.05)
        @test !fail.passed
        @test fail.demand > fail.capacity
        @test check_monolithic_shear_friction(fc, fy, Ac, Avf, cap.ϕVn * 0.5).passed
    end

    @testset "a corner ratio is raised on the grid up to the Table 22.9.4.4 limit" begin
        fc = 4000.0 * PSI_TO_PA
        fy = 60_000.0 * PSI_TO_PA
        Ac = 0.3 * 4.0
        Ac_in2 = Ac / IN_TO_M^2
        ϕVn(ρ, fy_psi) = WALL_PHI_SHEAR * 1.4 * ρ * Ac_in2 * fy_psi * LBF_TO_N
        ϕlimit = WALL_PHI_SHEAR * 800.0 * Ac_in2 * LBF_TO_N

        kept = select_corner_ratio(fc, fy, Ac, 0.0025, 0.5 * ϕVn(0.0025, 60_000.0))
        @test kept.ρ == 0.0025
        @test kept.check.passed && !kept.capped

        # 1.9 times the legs' capacity needs ρ ≥ 0.00475; the grid step is 0.0005.
        raised = select_corner_ratio(fc, fy, Ac, 0.0025, 1.9 * ϕVn(0.0025, 60_000.0))
        @test raised.ρ ≈ 0.005
        @test raised.check.passed && !raised.capped
        @test !check_monolithic_shear_friction(fc, fy, Ac, 0.0045 * Ac,
                                               1.9 * ϕVn(0.0025, 60_000.0)).passed

        capped = select_corner_ratio(fc, fy, Ac, 0.0025, 1.1 * ϕlimit)
        @test capped.capped
        @test capped.ρ == 0.0025
        @test !capped.check.passed

        # 1 ksi steel: the grid top is below the demand, and the demand is below the limit.
        weak = select_corner_ratio(fc, 1000.0 * PSI_TO_PA, Ac, 0.0025,
                                   2.0 * ϕVn(0.02, 1000.0))
        @test 2.0 * ϕVn(0.02, 1000.0) < ϕlimit
        @test weak.ρ ≈ 0.02
        @test !weak.check.passed && !weak.capped
    end

    @testset "a joined leg is checked on its clear length" begin
        leg = _jwall(0, 0, 6, 0)
        stem = _jwall(0, 0, 0, 4)
        walls = [leg, stem]
        asm = only(wall_assemblies(walls))
        action = CombinedWallAction(:strength_1_4D, :only, 2.0e5, 5.0e4, 1.0e5, 30.0, 40.0)
        clear = joined_clear_length(leg, walls, 1)
        joined = check_ordinary_wall(leg, [action]; wall_index=1, material=RC_4000_60,
                                     case=:D, boundary=:restrained, assembly=asm,
                                     lw=clear * u"m")
        @test any(r -> r.check == "out-of-plane shear (reported)" && r.demand ≈ 30.0, joined)
        @test any(r -> r.check == "out-of-plane moment (reported)" && r.demand ≈ 40.0, joined)
        shear = only(filter(r -> r.check == "in-plane shear", joined))
        full = check_ordinary_wall(leg, [action]; wall_index=1, material=RC_4000_60,
                                   case=:D, boundary=:restrained)
        full_shear = only(filter(r -> r.check == "in-plane shear", full))
        @test shear.capacity ≈ full_shear.capacity * (clear / 6.0) rtol=1e-9
        @test_throws ArgumentError check_ordinary_wall(
            leg, [action]; wall_index=1, material=RC_4000_60, case=:D,
            boundary=:restrained, assembly=asm)

        long = _jwall(0, 0, 6, 0)
        short = _jwall(0, 0, 6, 0)
        # Above the 3 m concrete shear and inside the 6 m minimum-steel capacity,
        # so only the clear-length leg has to leave ρt = 0.0025.
        grown = [CombinedWallAction(:strength_1_4D, :only, 0.0, 2.2e6, 0.0)]
        StructuralSynthesizer.select_ordinary_wall_reinforcement!(
            long, grown, RC_4000_60; hw=4.0u"m")
        StructuralSynthesizer.select_ordinary_wall_reinforcement!(
            short, grown, RC_4000_60; hw=4.0u"m", lw=3.0u"m")
        @test short.ρt > long.ρt
    end

    @testset "an L loaded along one leg puts axial force in the other" begin
        lines = [(0.0, 0.0, 6.0, 0.0), (0.0, 0.0, 0.0, 4.0)]
        model, mesh, walls, loads = _solve(lines, [(6.0, 0.0, 4.0, _PJ, 0.0, 0.0)])
        asm = only(mesh.assemblies)
        @test asm.joined
        cut = joined_assembly_cuts(mesh, asm, model.u)
        @test cut[1] ≈ _PJ rtol=1e-6 atol=1.0
        @test cut[2] ≈ 0.0 atol=1.0
        web = pier_wall_action(walls[1], mesh.piers[1], model.u)
        flange = pier_wall_action(walls[2], mesh.piers[2], model.u)
        @test abs(web.V) > 0.5 * _PJ
        @test abs(flange.N) > 1.0e3
        vu = corner_vertical_shear(mesh.piers, model.u, 0.0, 0.0)
        @test vu ≈ abs(flange.N) rtol=0.05 atol=1.0
        eq = check_story_cut_equilibrium(model, model.u, mesh, loads, 0.0)
        @test eq.passed
    end

    @testset "a symmetric T loaded along the web balances the flange" begin
        lines = [(0.0, 0.0, 6.0, 0.0), (6.0, -3.0, 6.0, 0.0), (6.0, 0.0, 6.0, 3.0)]
        model, mesh, walls, _ = _solve(lines, [(0.0, 0.0, 4.0, _PJ, 0.0, 0.0)])
        @test only(mesh.assemblies).joined
        web = pier_wall_action(walls[1], mesh.piers[1], model.u)
        low = pier_wall_action(walls[2], mesh.piers[2], model.u)
        high = pier_wall_action(walls[3], mesh.piers[3], model.u)
        @test abs(web.V) > 0.5 * _PJ
        @test low.N ≈ high.N rtol=0.05 atol=50.0
        @test abs(low.N) > 1.0e3
        @test abs(low.V) < 0.05 * abs(web.V)
        @test abs(high.V) < 0.05 * abs(web.V)
        @test abs(low.V + high.V) < 1e-3 * _PJ
    end

    @testset "a parallelogram core under torsion shears every leg" begin
        lines = [(0.0, 0.0, 6.0, 0.0), (6.0, 0.0, 8.0, 3.0),
                 (8.0, 3.0, 2.0, 3.0), (2.0, 3.0, 0.0, 0.0)]
        # Nodes of a 3-bay mesh: x = 0, 2, 4, 6 on the bottom, and x = 8, 6, 4, 2 on the top.
        model, mesh, walls, loads = _solve(lines, [
            (2.0, 0.0, 4.0, 0.0, _PJ, 0.0),
            (4.0, 3.0, 4.0, 0.0, -_PJ, 0.0)])
        asm = only(mesh.assemblies)
        @test asm.joined
        @test length(asm.wall_indices) == 4
        @test _fold(_dir(walls[1]), _dir(walls[2])) ≉ π / 2
        cut = joined_assembly_cuts(mesh, asm, model.u)
        @test cut[1] ≈ 0.0 atol=1.0
        @test cut[2] ≈ 0.0 atol=1.0
        @test abs(cut[6]) > 1.0e4
        shears = [abs(pier_wall_action(wall, pier, model.u).V)
                  for (wall, pier) in zip(walls, mesh.piers)]
        # The couple is carried in-plane by the loaded legs. The skewed legs
        # are in the same free body; a coarse corner does not force each of
        # them to take a fixed share.
        @test sum(shears) > 0.5 * _PJ
        @test count(s -> s > 0.2 * _PJ, shears) >= 2
        eq = check_story_cut_equilibrium(model, model.u, mesh, loads, 0.0)
        @test eq.passed
    end
end
