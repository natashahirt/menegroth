# Wall assemblies and free-body cuts.
#
# Assemblies are geometry only. The cut tests are Asap models with a known
# load, so the six-component residual can be checked without a building.

using Test
using Unitful
using Asap
using StructuralSynthesizer

const _P = 1.0e5  # N

function _wall(x1, y1, x2, y2; story=0)
    return Wall([1], 4.0u"m"; thickness=0.3u"m",
                x1=x1, y1=y1, x2=x2, y2=y2, story=story)
end

"""One rectangular wall panel, base fixed, `nx` quads along its length."""
function _panel(x1, y1, x2, y2, z0, z1; nx=2)
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
    shells = Asap.ShellTri3[]
    for c in 0:(nx - 1)
        s0 = c / nx
        s1 = (c + 1) / nx
        xa = x1 + (x2 - x1) * s0
        ya = y1 + (y2 - y1) * s0
        xb = x1 + (x2 - x1) * s1
        yb = y1 + (y2 - y1) * s1
        nb0 = node(xa, ya, z0)
        nb1 = node(xb, yb, z0)
        nt1 = node(xb, yb, z1)
        nt0 = node(xa, ya, z1)
        push!(shells, Asap.ShellTri3((nb0, nb1, nt1), 0.3u"m", 30e9u"Pa", 0.2; id=:wall))
        push!(shells, Asap.ShellTri3((nb0, nt1, nt0), 0.3u"m", 30e9u"Pa", 0.2; id=:wall))
    end
    return nodes, shells
end

function _top_nodes(nodes, z)
    return [nd for nd in nodes if isapprox(ustrip(u"m", nd.position[3]), z; atol=1e-9)]
end

@testset "wall assemblies and cuts" begin
    @testset "separate walls stay separate; a shared corner joins" begin
        a = _wall(0, 0, 6, 0)
        b = _wall(10, 0, 16, 0)
        apart = wall_assemblies([a, b])
        @test length(apart) == 2
        @test all(!asm.joined for asm in apart)

        c = _wall(6, 0, 6, 4)
        joined = wall_assemblies([a, c])
        @test length(joined) == 1
        @test only(joined).joined
        @test only(joined).wall_indices == [1, 2]
        @test_throws msg -> occursin("flange width", msg) refuse_joined_wall_design(only(joined))
        @test refuse_joined_wall_design(first(apart)) === nothing

        # Stacked walls share a plan line and stay two assemblies.
        above = _wall(0, 0, 6, 0; story=1)
        stacked = wall_assemblies([a, above])
        @test length(stacked) == 2
        @test all(!asm.joined for asm in stacked)
    end

    @testset "base cut of one wall equals the load above it" begin
        nodes, shells = _panel(0.0, 0.0, 6.0, 0.0, 0.0, 4.0)
        tops = _top_nodes(nodes, 4.0)
        # Ends only, equal shares, so the resultant sits on the base centroid.
        ends = [nd for nd in tops if abs(ustrip(u"m", nd.position[1]) - 3.0) > 1.0]
        @test length(ends) == 2
        share = (_P / 2) * u"N"
        loads = Asap.AbstractLoad[Asap.NodeForce(nd, [share, 0.0u"N", 0.0u"N"]) for nd in ends]
        model = Asap.Model(nodes, shells, loads)
        Asap.solve!(model)
        mesh = WallMesh([shells], wall_assemblies([_wall(0, 0, 6, 0)]))
        cut = wall_pier_cut(shells, model.u, 0.0; wall_indices=[1])
        @test cut.Fx ≈ _P rtol=1e-6 atol=1.0
        @test cut.Fy ≈ 0.0 atol=1.0
        @test cut.Fz ≈ 0.0 atol=1.0
        # Load is 4 m above the cut and centered: My = P * 4.
        @test cut.My ≈ _P * 4.0 rtol=1e-6 atol=1.0
        @test cut.Mx ≈ 0.0 atol=1.0
        @test cut.Mz ≈ 0.0 atol=1.0
        eq = check_story_cut_equilibrium(model, model.u, mesh, loads, 0.0)
        @test eq.passed
    end

    @testset "upper cut carries only the load above it" begin
        n0, lower = _panel(0.0, 0.0, 6.0, 0.0, 0.0, 4.0)
        n1, upper = _panel(0.0, 0.0, 6.0, 0.0, 4.0, 8.0)
        # Share the z = 4 nodes. _panel builds its own nodes, so stitch by
        # replacing upper-base nodes with the lower-top nodes at the same point.
        function steal(nd)
            x, y, z = (ustrip(u"m", nd.position[1]), ustrip(u"m", nd.position[2]),
                       ustrip(u"m", nd.position[3]))
            for other in n0
                p = other.position
                dx = ustrip(u"m", p[1]) - x
                dy = ustrip(u"m", p[2]) - y
                dz = ustrip(u"m", p[3]) - z
                dx * dx + dy * dy + dz * dz < 1e-12 && return other
            end
            return nd
        end
        stitched = Asap.ShellTri3[]
        for sh in upper
            a, b, c = steal(sh.nodes[1]), steal(sh.nodes[2]), steal(sh.nodes[3])
            push!(stitched, Asap.ShellTri3((a, b, c), 0.3u"m", 30e9u"Pa", 0.2; id=:wall))
        end
        nodes = Asap.Node[]
        seen = Set{UInt64}()
        for sh in [lower; stitched], nd in sh.nodes
            id = objectid(nd)
            id in seen && continue
            push!(seen, id)
            push!(nodes, nd)
        end
        roof = [nd for nd in nodes if isapprox(ustrip(u"m", nd.position[3]), 8.0; atol=1e-9) &&
                    abs(ustrip(u"m", nd.position[1]) - 3.0) > 1.0]
        mid = [nd for nd in nodes if isapprox(ustrip(u"m", nd.position[3]), 4.0; atol=1e-9) &&
                   abs(ustrip(u"m", nd.position[1]) - 3.0) > 1.0]
        @test length(roof) == 2
        @test length(mid) == 2
        share = (_P / 2) * u"N"
        loads = Asap.AbstractLoad[]
        for nd in roof
            push!(loads, Asap.NodeForce(nd, [share, 0.0u"N", 0.0u"N"]))
        end
        for nd in mid
            push!(loads, Asap.NodeForce(nd, [share, 0.0u"N", 0.0u"N"]))
        end
        model = Asap.Model(nodes, [lower; stitched], loads)
        Asap.solve!(model)
        walls = [_wall(0, 0, 6, 0; story=0), _wall(0, 0, 6, 0; story=1)]
        mesh = WallMesh([lower, stitched], wall_assemblies(walls))
        @test length(mesh.assemblies) == 2
        base = check_story_cut_equilibrium(model, model.u, mesh, loads, 0.0)
        upper_cut = check_story_cut_equilibrium(model, model.u, mesh, loads, 4.0)
        @test base.passed
        @test upper_cut.passed
        @test base.cut[1] ≈ 2 * _P rtol=1e-6 atol=1.0
        @test upper_cut.cut[1] ≈ _P rtol=1e-6 atol=1.0
    end

    @testset "a column crossing the cut is part of the same residual" begin
        base = Asap.Node([0.0, 0.0, 0.0] .* u"m", :fixed)
        top = Asap.Node([0.0, 0.0, 4.0] .* u"m", :free)
        sec = Asap.Section(0.1u"m^2", 30e9u"Pa", 12e9u"Pa",
                           0.01u"m^4", 0.01u"m^4", 0.001u"m^4", 0.0u"kg/m^3")
        el = Asap.Element(base, top, sec)
        load = Asap.NodeForce(top, [_P * u"N", 0.0u"N", 0.0u"N"])
        model = Asap.Model([base, top], Asap.Element[el], Asap.AbstractLoad[load])
        Asap.solve!(model)
        eq = check_story_cut_equilibrium(model, model.u, WallMesh(), [load], 0.0)
        @test eq.passed
        @test eq.cut[1] ≈ _P rtol=1e-6 atol=1.0
        @test eq.cut[5] ≈ _P * 4.0 rtol=1e-6 atol=1.0
    end

    @testset "self-weight is the weight of the triangles above the cut" begin
        ρ = 2400.0
        t = 0.30
        L = 6.0
        H = 4.0
        g = ustrip(u"m/s^2", Asap.GRAVITY)
        nodes = Asap.Node[]
        function node(x, y, z)
            for nd in nodes
                p = nd.position
                dx = ustrip(u"m", p[1]) - x
                dy = ustrip(u"m", p[2]) - y
                dz = ustrip(u"m", p[3]) - z
                dx * dx + dy * dy + dz * dz < 1e-12 && return nd
            end
            fix = isapprox(z, 0.0; atol=1e-9) ? :fixed : :free
            nd = Asap.Node([x, y, z] .* u"m", fix, :wall)
            push!(nodes, nd)
            return nd
        end
        shells = Asap.ShellTri3[]
        for (s0, s1, r0, r1) in wall_panel_quads(2, 2)
            x0 = L * s0
            x1 = L * s1
            z0 = H * r0
            z1 = H * r1
            nb0 = node(x0, 0.0, z0)
            nb1 = node(x1, 0.0, z0)
            nt1 = node(x1, 0.0, z1)
            nt0 = node(x0, 0.0, z1)
            push!(shells, Asap.ShellTri3((nb0, nb1, nt1), t * u"m", 30e9u"Pa", 0.2;
                                          id=:wall, ρ=ρ))
            push!(shells, Asap.ShellTri3((nb0, nt1, nt0), t * u"m", 30e9u"Pa", 0.2;
                                          id=:wall, ρ=ρ))
        end

        raw = wall_self_weight_loads(shells)
        @test length(raw) == 1
        @test ustrip(u"Pa", only(raw).pressure) ≈ ρ * t * g
        thin = Asap.ShellTri3(shells[1].nodes, 0.20u"m", 30e9u"Pa", 0.2; id=:wall, ρ=ρ)
        split = wall_self_weight_loads([shells[1], thin])
        @test length(split) == 2
        @test sort(ustrip.(u"Pa", [ld.pressure for ld in split])) ≈
              sort([ρ * t * g, ρ * 0.20 * g])
        @test isempty(wall_self_weight_loads([
            Asap.ShellTri3(shells[1].nodes, t * u"m", 30e9u"Pa", 0.2; id=:wall, ρ=0.0)]))

        loads = Asap.AbstractLoad[only(raw)]
        model = Asap.Model(nodes, shells, loads)
        Asap.solve!(model)
        mesh = WallMesh([shells], wall_assemblies([_wall(0.0, 0.0, L, 0.0)]))
        eq = check_story_cut_equilibrium(model, model.u, mesh, loads, 0.0)
        @test eq.passed

        p = ustrip(u"Pa", only(raw).pressure)
        above = on_cut = 0.0
        for sh in shells
            fpn = p * sh.area / length(sh.nodes)
            for nd in sh.nodes
                z = ustrip(u"m", nd.position[3])
                if z > 1e-4
                    above += fpn
                else
                    on_cut += fpn
                end
            end
        end
        W = ρ * g * t * L * H
        @test sum(sh.area for sh in shells) ≈ L * H atol=1e-8
        @test above + on_cut ≈ W rtol=1e-9
        @test eq.cut[3] ≈ -above rtol=1e-6 atol=1.0
        @test on_cut > 1.0

        top = 0.0
        for sh in shells
            fpn = p * sh.area / length(sh.nodes)
            for nd in sh.nodes
                ustrip(u"m", nd.position[3]) > H / 2 + 1e-4 || continue
                top += fpn
            end
        end
        mid = wall_pier_cut(
            [sh for sh in shells if any(nd -> ustrip(u"m", nd.position[3]) > H / 2 + 1e-4, sh.nodes)],
            model.u, H / 2)
        @test mid.Fz ≈ -top rtol=1e-6 atol=1.0
        @test abs(mid.Fz) < abs(eq.cut[3])
    end
end

@testset "a line load on nodes above the cut is in the free body" begin
    n1 = Asap.Node([0.0, 0.0, 3.0]u"m", :free)
    n2 = Asap.Node([4.0, 0.0, 3.0]u"m", :free)
    sec = Asap.Section(1e-3u"m^2", 200e9u"Pa", 80e9u"Pa", 1e-5u"m^4", 1e-5u"m^4", 1e-6u"m^4")
    el = Asap.Element(n1, n2, sec)
    model = Asap.Model([n1, n2], [el], Asap.AbstractLoad[])
    Asap.process!(model)
    w = 1000.0
    ld = Asap.LineLoad(el, [0.0, 0.0, -w]u"N/m")
    above = StructuralSynthesizer._loads_above([ld], (0.0, 0.0, 0.0), 0.0)
    on_beam = StructuralSynthesizer._loads_above([ld], (0.0, 0.0, 0.0), 3.0)
    @test above[3] ≈ -w * 4.0 atol=1e-4
    @test on_beam[3] ≈ 0.0 atol=1e-6
end
