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
        row = check_opening_row_equilibrium(model, model.u, mesh, loads, 0.0)
        @test row.passed
        @test all(isapprox.(row.cut, eq.cut; rtol=1e-9, atol=1e-3))
        wall = _wall(0.0, 0.0, 6.0, 0.0)
        ends_action = pier_segment_actions(wall, shells, model.u, 0.0, 4.0)
        base_action = pier_wall_action(wall, mesh.piers[1], model.u)
        @test ends_action.bottom.N ≈ base_action.N atol=1e-3
        @test ends_action.bottom.V ≈ base_action.V atol=1e-3
        @test ends_action.bottom.M ≈ base_action.M atol=1e-3
        @test ends_action.bottom.V ≈ _P rtol=1e-6 atol=1.0
        @test ends_action.bottom.M ≈ _P * 4.0 rtol=1e-6 atol=1.0
        # The load sits on the top nodes. The top cut reads that load, and
        # the moment arm about the top centroid is zero.
        @test ends_action.top.V ≈ _P rtol=1e-6 atol=1.0
        @test ends_action.top.M ≈ 0.0 atol=1.0
        @test ends_action.top.N ≈ 0.0 atol=1.0
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
        base_row = check_opening_row_equilibrium(model, model.u, mesh, loads, 0.0)
        upper_row = check_opening_row_equilibrium(model, model.u, mesh, loads, 4.0)
        @test all(isapprox.(base_row.cut, base.cut; rtol=1e-9, atol=1e-3))
        @test all(isapprox.(upper_row.cut, upper_cut.cut; rtol=1e-9, atol=1e-3))
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

"""
Rectangles on y = 0. Quads whose centre lies inside `hole` are left out.

`mirror` flips the diagonal of a quad whose centre is past mid-length, so a
wall and the load on it can be symmetric. One diagonal direction on every
quad is not.
"""
function _opening_panel(xs, zs; hole=nothing, fix_z=nothing, mirror=false)
    nodes = Asap.Node[]
    function node(x, z)
        for nd in nodes
            p = nd.position
            dx = ustrip(u"m", p[1]) - x
            dz = ustrip(u"m", p[3]) - z
            dx * dx + dz * dz < 1e-12 && return nd
        end
        fixed = fix_z !== nothing && isapprox(z, fix_z; atol=1e-9)
        nd = Asap.Node([x, 0.0, z] .* u"m", fixed ? :fixed : :free, :wall)
        push!(nodes, nd)
        return nd
    end
    shells = Asap.ShellTri3[]
    for i in 1:(length(xs) - 1), j in 1:(length(zs) - 1)
        x0, x1 = xs[i], xs[i + 1]
        z0, z1 = zs[j], zs[j + 1]
        if hole !== nothing
            a, b, c, d = hole
            a < (x0 + x1) / 2 < b && c < (z0 + z1) / 2 < d && continue
        end
        nb0 = node(x0, z0)
        nb1 = node(x1, z0)
        nt1 = node(x1, z1)
        nt0 = node(x0, z1)
        mid = (xs[1] + xs[end]) / 2
        if mirror && (x0 + x1) / 2 > mid
            push!(shells, Asap.ShellTri3((nb1, nt1, nt0), 0.3u"m", 30e9u"Pa", 0.2; id=:wall))
            push!(shells, Asap.ShellTri3((nb1, nt0, nb0), 0.3u"m", 30e9u"Pa", 0.2; id=:wall))
        else
            push!(shells, Asap.ShellTri3((nb0, nb1, nt1), 0.3u"m", 30e9u"Pa", 0.2; id=:wall))
            push!(shells, Asap.ShellTri3((nb0, nt1, nt0), 0.3u"m", 30e9u"Pa", 0.2; id=:wall))
        end
    end
    return nodes, shells
end

function _shells_in(shells, s0, s1, z0, z1)
    out = Asap.ShellTri3[]
    for sh in shells
        x = z = 0.0
        for nd in sh.nodes
            x += ustrip(u"m", nd.position[1])
            z += ustrip(u"m", nd.position[3])
        end
        n = length(sh.nodes)
        s0 < x / n < s1 && z0 < z / n < z1 && push!(out, sh)
    end
    return out
end

@testset "segment cuts around an opening" begin
    @testset "a strip fixed at one end carries the midspan load" begin
        nodes, shells = _opening_panel([0.0, 2.0, 4.0], [2.0, 3.0])
        for nd in nodes
            isapprox(ustrip(u"m", nd.position[1]), 0.0; atol=1e-9) || continue
            Asap.fixnode!(nd, :fixed)
        end
        W = _P
        mids = [nd for nd in nodes if isapprox(ustrip(u"m", nd.position[1]), 2.0; atol=1e-9)]
        @test length(mids) == 2
        share = (-W / 2) * u"N"
        loads = Asap.AbstractLoad[Asap.NodeForce(nd, [0.0u"N", 0.0u"N", share]) for nd in mids]
        model = Asap.Model(nodes, shells, loads)
        Asap.solve!(model)
        wall = _wall(0.0, 0.0, 4.0, 0.0)
        face = spandrel_segment_actions(wall, shells, model.u, 0.0, 4.0, 2.0, 3.0)
        # Support pushes up with W. The load is 2 m from the fixed face.
        # Moment about the face centroid is -W * 2, about the horizontal normal.
        @test face.at_start.V ≈ W rtol=1e-6 atol=1.0
        @test face.at_start.M ≈ -W * 2.0 rtol=1e-6 atol=1.0
        @test face.at_start.N ≈ 0.0 atol=1.0
        @test face.at_end.V ≈ 0.0 atol=1.0
        @test face.at_end.M ≈ 0.0 atol=1.0
        @test face.at_start.V + face.at_end.V ≈ W rtol=1e-6 atol=1.0

        nodes2, shells2 = _opening_panel([0.0, 2.0, 4.0], [2.0, 3.0])
        for nd in nodes2
            isapprox(ustrip(u"m", nd.position[1]), 0.0; atol=1e-9) || continue
            Asap.fixnode!(nd, :fixed)
        end
        mids2 = [nd for nd in nodes2 if isapprox(ustrip(u"m", nd.position[1]), 2.0; atol=1e-9)]
        axial = Asap.AbstractLoad[
            Asap.NodeForce(nd, [(W / 2) * u"N", 0.0u"N", 0.0u"N"]) for nd in mids2]
        pulled = Asap.Model(nodes2, shells2, axial)
        Asap.solve!(pulled)
        tension = spandrel_segment_actions(wall, shells2, pulled.u, 0.0, 4.0, 2.0, 3.0)
        @test tension.at_start.N ≈ -W rtol=1e-6 atol=1.0
        @test tension.at_end.N ≈ 0.0 atol=1.0
    end

    @testset "two piers share a symmetric load and the opening row closes" begin
        # A station at mid-length, and mirrored diagonals, so the two piers match.
        xs = [0.0, 2.0, 3.0, 4.0, 6.0]
        zs = [0.0, 1.0, 3.0, 4.0]
        nodes, shells = _opening_panel(xs, zs; hole=(2.0, 4.0, 1.0, 3.0), fix_z=0.0, mirror=true)
        tops = [nd for nd in nodes if isapprox(ustrip(u"m", nd.position[3]), 4.0; atol=1e-9) &&
                    abs(ustrip(u"m", nd.position[1]) - 3.0) > 1.0]
        @test length(tops) == 2
        share = (_P / 2) * u"N"
        loads = Asap.AbstractLoad[Asap.NodeForce(nd, [share, 0.0u"N", 0.0u"N"]) for nd in tops]
        model = Asap.Model(nodes, shells, loads)
        Asap.solve!(model)
        wall = _wall(0.0, 0.0, 6.0, 0.0)
        left_shells = _shells_in(shells, 0.0, 2.0, 1.0, 3.0)
        right_shells = _shells_in(shells, 4.0, 6.0, 1.0, 3.0)
        lintel_shells = _shells_in(shells, 2.0, 4.0, 3.0, 4.0)
        @test length(left_shells) == 2
        @test length(right_shells) == 2
        @test length(lintel_shells) == 4
        left = pier_segment_actions(wall, left_shells, model.u, 1.0, 3.0)
        right = pier_segment_actions(wall, right_shells, model.u, 1.0, 3.0)
        @test left.bottom.V ≈ _P / 2 rtol=1e-6 atol=1.0
        @test right.bottom.V ≈ _P / 2 rtol=1e-6 atol=1.0
        @test left.bottom.V + right.bottom.V ≈ _P rtol=1e-6 atol=1.0
        @test left.top.V ≈ left.bottom.V rtol=1e-6 atol=1.0
        @test right.top.V ≈ right.bottom.V rtol=1e-6 atol=1.0
        # +Fx at the top tensions the left pier and compresses the right.
        @test left.bottom.N < 0
        @test left.bottom.N + right.bottom.N ≈ 0.0 atol=1.0
        lintel = spandrel_segment_actions(wall, lintel_shells, model.u, 2.0, 4.0, 3.0, 4.0)
        @test lintel.at_start.V + lintel.at_end.V ≈ 0.0 atol=1.0

        mesh = WallMesh([shells], wall_assemblies([wall]))
        left_seg = StructuralSynthesizer.WallSegment(
            :vertical, [1], [1], 0.0, 2.0, 1.0, 3.0, left_shells, :wall)
        right_seg = StructuralSynthesizer.WallSegment(
            :vertical, [1], [1], 4.0, 6.0, 1.0, 3.0, right_shells, :wall)
        lintel_seg = StructuralSynthesizer.WallSegment(
            :horizontal, [1], [1], 2.0, 4.0, 3.0, 4.0, lintel_shells, :stm)
        layout = StructuralSynthesizer.WallSegmentLayout(
            [left_seg, right_seg, lintel_seg], StructuralSynthesizer.WallSolidRow[])
        report = segment_opening_forces([wall], layout, model.u)
        @test length(report.vertical) == 2
        @test length(report.horizontal) == 1
        @test report.vertical[1].bottom.V ≈ left.bottom.V atol=1e-3
        @test report.horizontal[1].at_start.V ≈ lintel.at_start.V atol=1e-3
        gates = opening_row_equilibria(model, model.u, mesh, loads, layout)
        @test length(gates) == 1
        @test only(gates).z_m ≈ 1.0
        @test only(gates).stacks == [[1]]
        @test only(gates).equilibrium.passed
        @test only(gates).equilibrium.cut[1] ≈ _P rtol=1e-6 atol=1.0
    end

    @testset "a shell that crosses the elevation is not cut" begin
        n1 = Asap.Node([0.0, 0.0, 0.0]u"m", :fixed, :wall)
        n2 = Asap.Node([1.0, 0.0, 0.0]u"m", :fixed, :wall)
        n3 = Asap.Node([0.0, 0.0, 2.0]u"m", :free, :wall)
        sh = Asap.ShellTri3((n1, n2, n3), 0.3u"m", 30e9u"Pa", 0.2; id=:wall)
        wall = _wall(0.0, 0.0, 1.0, 0.0)
        mesh = WallMesh([Asap.ShellTri3[sh]], wall_assemblies([wall]))
        model = Asap.Model([n1, n2, n3], Asap.ShellTri3[sh], Asap.AbstractLoad[])
        err = try
            check_opening_row_equilibrium(model, Float64[], mesh, Asap.AbstractLoad[], 1.0)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("does not conform", err.msg)
    end
end
