# The core office shaft: floors below the roof lose the center bay, the roof
# keeps it, and the slab bears on the core walls.

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

include(joinpath(@__DIR__, "..", "..", "..", "scripts", "runners", "core_office_geometry.jl"))

function _core_face(skel, z)
    x0, x1 = 8.0, 16.0
    for (fi, vis) in enumerate(skel.face_vertex_indices)
        vc = skel.geometry.vertex_coords
        zs = [vc[v, 3] for v in vis]
        all(zz -> abs(zz - z) <= 1e-3, zs) || continue
        xs = [vc[v, 1] for v in vis]
        ys = [vc[v, 2] for v in vis]
        all(x -> x0 - 1e-3 <= x <= x1 + 1e-3, xs) || continue
        all(y -> x0 - 1e-3 <= y <= x1 + 1e-3, ys) || continue
        return fi
    end
    return nothing
end

_loop_area(loop) = 0.5 * sum(loop[k][1] * loop[mod1(k + 1, length(loop))][2] -
    loop[mod1(k + 1, length(loop))][1] * loop[k][2] for k in eachindex(loop))

@testset "Core shaft below the roof" begin
    skel = core_office_skeleton()

    @testset "The center bay is a slab only on the roof" begin
        roof = _core_face(skel, 14.4)
        @test roof !== nothing
        @test roof in skel.groups_faces[:roof]
        for z in (0.0, 3.6, 7.2, 10.8)
            fi = _core_face(skel, z)
            @test fi !== nothing
            @test !(fi in StructuralSynthesizer.slab_face_indices(skel))
        end
    end

    @testset "A floor outline has the shaft as a hole; the roof does not" begin
        floor = skel.stories[1]   # z = 3.6 m
        loops = story_floor_outline(skel, floor)
        areas = sort(_loop_area.(loops))
        @test length(loops) == 2
        @test areas[1] ≈ -64.0 atol = 1e-6
        @test areas[2] ≈ 576.0 atol = 1e-6
        roof_story = skel.stories[4]
        @test length(story_floor_outline(skel, roof_story)) == 1
    end

    struc = BuildingStructure(skel)
    initialize!(struc; floor_type = :flat_plate, wall_thickness = 0.3u"m")

    function _at(z0)
        i = findfirst(struc.slabs) do s
            z = StructuralSizer._slab_elevation_m(struc, s)
            z !== nothing && abs(z - z0) < 0.1
        end
        i === nothing && error("no slab at z = $z0")
        return struc.slabs[i]
    end
    open_slab = _at(3.6)
    roof_slab = _at(14.4)

    @testset "The missing bay is a void, and direct design is refused" begin
        voids = StructuralSizer.slab_void_loops(struc, open_slab)
        @test length(voids) == 1
        @test abs(_loop_area(voids[1])) ≈ 64.0 atol = 1e-6
        @test isempty(StructuralSizer.slab_void_loops(struc, roof_slab))

        cols = StructuralSizer.find_supporting_columns(struc, Set(open_slab.cell_indices))
        appl = StructuralSizer.check_ddm_applicability(
            struc, open_slab, cols; throw_on_failure = false)
        @test !appl.ok
        @test any(v -> occursin("13.6.1.1", v), appl.violations)
        @test any(v -> occursin("ends at a wall", v), appl.violations)
        @test length(StructuralSizer.supporting_wall_segments(struc, open_slab)) == 4
        # The roof is closed, and the piers below still land on it.
        @test length(StructuralSizer.supporting_wall_segments(struc, roof_slab)) == 4
    end

    @testset "The design kernel keeps the wall lines the building resolved" begin
        open_idx = findfirst(s -> s === open_slab, struc.slabs)
        input = StructuralSynthesizer._flat_plate_design_input(struc, open_idx)
        @test length(input.floors[open_idx].wall_segments) == 4
        state = StructuralSizer.FlatPlateKernelState(input)
        kslab = state.slabs[open_idx]
        segs = StructuralSizer.supporting_wall_segments(state, kslab)
        @test length(segs) == 4
        kcols = StructuralSizer.find_supporting_columns(state, Set(kslab.cell_indices))
        appl = StructuralSizer.check_ddm_applicability(
            state, kslab, kcols; throw_on_failure = false)
        @test any(v -> occursin("ends at a wall", v), appl.violations)
        sec = Asap.ShellSection(0.2u"m", 30u"GPa", 0.2)
        mesh = StructuralSizer.build_slab_shell_mesh(
            state, kslab, typeof(state.columns)(), sec; target_edge = 2.0u"m")
        @test StructuralSizer._hold_slab_on_walls!(mesh.shells, segs) > 4
    end

    @testset "FEA holds the slab on the core walls and leaves the shaft empty" begin
        sec = Asap.ShellSection(0.2u"m", 30u"GPa", 0.2)
        mesh = StructuralSizer.build_slab_shell_mesh(
            struc, open_slab, typeof(struc.columns)(), sec; target_edge = 2.0u"m")
        segs = StructuralSizer.supporting_wall_segments(struc, open_slab)
        n_held = StructuralSizer._hold_slab_on_walls!(mesh.shells, segs)
        @test n_held > 4
        held = 0
        free_bay = 0
        for sh in mesh.shells
            xs = [ustrip(u"m", n.position[1]) for n in sh.nodes]
            ys = [ustrip(u"m", n.position[2]) for n in sh.nodes]
            cx, cy = sum(xs) / 3, sum(ys) / 3
            @test !(8.0 < cx < 16.0 && 8.0 < cy < 16.0)
            for n in sh.nodes
                x, y = ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2])
                if abs(y - 8.0) <= 1e-3 && 8.0 - 1e-6 <= x <= 16.0 + 1e-6
                    @test n.dof[3] == false
                    held += 1
                elseif 1.0 < x < 7.0 && 1.0 < y < 7.0
                    @test n.dof[3] == true
                    free_bay += 1
                end
            end
        end
        @test held > 0
        @test free_bay > 0
    end

    @testset "A wall node on the shaft edge is shared; one inside the shaft is not" begin
        corners = Asap.Node[
            Asap.Node([0.0u"m", 0.0u"m", 3.6u"m"], :free),
            Asap.Node([24.0u"m", 0.0u"m", 3.6u"m"], :free),
            Asap.Node([24.0u"m", 24.0u"m", 3.6u"m"], :free),
            Asap.Node([0.0u"m", 24.0u"m", 3.6u"m"], :free),
        ]
        hole = [(8.0, 8.0), (16.0, 8.0), (16.0, 16.0), (8.0, 16.0)]
        on_edge = Asap.Node([12.0u"m", 8.0u"m", 3.6u"m"], :free)
        in_shaft = Asap.Node([12.0u"m", 12.0u"m", 3.6u"m"], :free)
        got = StructuralSynthesizer._slab_wall_nodes(
            Asap.Node[on_edge, in_shaft], Asap.Node[], corners; holes = [hole])
        @test on_edge in got
        @test !(in_shaft in got)
    end
end
