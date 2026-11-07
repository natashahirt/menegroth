# The core office: a lobby slab along the south of the center bay, three shafts
# north of it, and the walls between those shafts. The roof stays closed, and
# the floor slab bears on the walls that bound a slab edge.

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

"""True when `(x, y)` is within 1 mm of an edge of `loop`."""
function _on_loop(loop, x, y; tol = 1e-3)
    for i in eachindex(loop)
        a = loop[i]
        b = loop[mod1(i + 1, length(loop))]
        dx, dy = b[1] - a[1], b[2] - a[2]
        len2 = dx * dx + dy * dy
        len2 == 0 && continue
        s = clamp(((x - a[1]) * dx + (y - a[2]) * dy) / len2, 0.0, 1.0)
        hypot(x - (a[1] + s * dx), y - (a[2] + s * dy)) <= tol && return true
    end
    return false
end

@testset "Core shaft below the roof" begin
    skel = core_office_skeleton()

    @testset "Shaft doors and a lobby entrance on each core story" begin
        doors = filter(s -> s.opening.kind === :door, skel.wall_openings)
        @test length(doors) == 4 * CORE_STORIES
        elevators = filter(s -> s.opening.width ≈ 1.1, doors)
        stairs = filter(s -> s.opening.width ≈ 1.0, doors)
        entrances = filter(s -> s.opening.width ≈ 1.8, doors)
        @test length(elevators) == 2 * CORE_STORIES
        @test length(stairs) == CORE_STORIES
        @test length(entrances) == CORE_STORIES
        @test all(s -> s.opening.z0 == 0.0 && s.opening.height ≈ 2.1, doors)
        # Elevator and stair doors are on the lobby/shaft wall, not the perimeter.
        for s in Iterators.flatten((elevators, stairs))
            ys = [skel.geometry.vertex_coords[v, 2] for v in (s.v1, s.v2)]
            @test all(y -> y ≈ CORE_LOBBY_Y, ys)
        end
    end

    @testset "The lobby stays a slab and the shafts do not" begin
        roof = _core_face(skel, 14.4)
        @test roof !== nothing
        @test roof in skel.groups_faces[:roof]
        rxs = skel.geometry.vertex_coords[skel.face_vertex_indices[roof], 1]
        rys = skel.geometry.vertex_coords[skel.face_vertex_indices[roof], 2]
        @test maximum(rxs) - minimum(rxs) ≈ CORE_BAY
        @test maximum(rys) - minimum(rys) ≈ CORE_BAY
        slabs = StructuralSynthesizer.slab_face_indices(skel)
        for z in (0.0, 3.6, 7.2, 10.8)
            fi = _core_face(skel, z)
            @test fi !== nothing
            @test fi in slabs
            ys = skel.geometry.vertex_coords[skel.face_vertex_indices[fi], 2]
            @test minimum(ys) ≈ CORE_BAY
            @test maximum(ys) ≈ CORE_LOBBY_Y
        end
    end

    shaft_area = CORE_BAY * (2 * CORE_BAY - CORE_LOBBY_Y)

    @testset "Top-story wall ends have a roof vertex on the same column line" begin
        roof_z = ustrip(u"m", skel.stories_z[end])
        top_z = roof_z - CORE_STORY_H
        vc = skel.geometry.vertex_coords
        n = 0
        for ei in skel.groups_edges[:walls]
            for v in skel.edge_indices[ei]
                abs(vc[v, 3] - top_z) <= 1e-3 || continue
                x, y = vc[v, 1], vc[v, 2]
                found = any(i -> abs(vc[i, 3] - roof_z) <= 1e-3 &&
                                 hypot(vc[i, 1] - x, vc[i, 2] - y) <= 1e-3,
                            axes(vc, 1))
                @test found
                n += 1
            end
        end
        @test n > 0
    end

    @testset "A floor outline has the three shafts as one hole; the roof does not" begin
        floor = skel.stories[1]   # z = 3.6 m
        loops = story_floor_outline(skel, floor)
        areas = sort(_loop_area.(loops))
        @test length(loops) == 2
        @test areas[1] ≈ -shaft_area atol = 1e-6
        @test areas[2] ≈ 576.0 atol = 1e-6
        # The wall between the lobby and the shafts is the hole edge. A
        # divider standing inside the hole is not an outline edge.
        hole = loops[findmin(_loop_area, loops)[2]]
        @test _on_loop(hole, 12.0, CORE_LOBBY_Y)
        @test !_on_loop(hole, CORE_ELEV_X, 13.0)
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
        @test abs(_loop_area(voids[1])) ≈ shaft_area atol = 1e-6
        @test isempty(StructuralSizer.slab_void_loops(struc, roof_slab))

        cols = StructuralSizer.find_supporting_columns(struc, Set(open_slab.cell_indices))
        appl = StructuralSizer.check_ddm_applicability(
            struc, open_slab, cols; throw_on_failure = false)
        @test !appl.ok
        # The lobby is 2.5 m against an 8 m bay, so successive spans on the
        # shaft wall fail §13.6.1.3. The core-corner columns stay in the
        # frame, so the floor is not one 24 m panel.
        @test any(v -> occursin("13.6.1.3", v), appl.violations)
        @test !any(v -> occursin("ends at a wall", v), appl.violations)
        efm = StructuralSizer.check_efm_applicability(
            struc, open_slab, cols; throw_on_failure = false)
        @test !any(v -> occursin("a wall supports this slab", v), efm.violations)
        # West and east are each two edges (the lobby meets them mid-side),
        # plus the south and north sides, the lobby wall, and two dividers.
        @test length(StructuralSizer.supporting_wall_segments(struc, open_slab)) == 9
        # The roof is closed, and the piers below still land on it.
        @test length(StructuralSizer.supporting_wall_segments(struc, roof_slab)) == 9
    end

    @testset "The design kernel keeps the wall lines the building resolved" begin
        open_idx = findfirst(s -> s === open_slab, struc.slabs)
        input = StructuralSynthesizer._flat_plate_design_input(struc, open_idx)
        @test length(input.floors[open_idx].wall_segments) == 9
        state = StructuralSizer.FlatPlateKernelState(input)
        kslab = state.slabs[open_idx]
        segs = StructuralSizer.supporting_wall_segments(state, kslab)
        @test length(segs) == 9
        kcols = StructuralSizer.find_supporting_columns(state, Set(kslab.cell_indices))
        appl = StructuralSizer.check_ddm_applicability(
            state, kslab, kcols; throw_on_failure = false)
        @test !any(v -> occursin("ends at a wall", v), appl.violations)
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
        lobby_held = 0
        lobby_shells = 0
        free_bay = 0
        for sh in mesh.shells
            xs = [ustrip(u"m", n.position[1]) for n in sh.nodes]
            ys = [ustrip(u"m", n.position[2]) for n in sh.nodes]
            cx, cy = sum(xs) / 3, sum(ys) / 3
            @test !(8.0 < cx < 16.0 && CORE_LOBBY_Y < cy < 16.0)
            if 8.0 < cx < 16.0 && 8.0 < cy < CORE_LOBBY_Y
                lobby_shells += 1
            end
            for n in sh.nodes
                x, y = ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2])
                if abs(y - 8.0) <= 1e-3 && 8.0 - 1e-6 <= x <= 16.0 + 1e-6
                    @test n.dof[3] == false
                    @test n.dof[4] == false
                    @test n.dof[5] == true
                    held += 1
                elseif abs(y - CORE_LOBBY_Y) <= 1e-3 && 8.0 + 1e-3 < x < 16.0 - 1e-3 &&
                       abs(x - CORE_ELEV_X) > 1e-3 && abs(x - CORE_STAIR_X) > 1e-3
                    # Clear of the north-south walls. A node that also lies on
                    # one of those is held about that wall's axis instead.
                    @test n.dof[3] == false
                    @test n.dof[4] == false
                    @test n.dof[5] == true
                    lobby_held += 1
                elseif 1.0 < x < 7.0 && 1.0 < y < 7.0
                    @test n.dof[3] == true
                    free_bay += 1
                end
            end
        end
        @test held > 0
        @test lobby_held > 0
        @test lobby_shells > 0
        @test free_bay > 0
    end

    @testset "The shaft wall is a diaphragm edge; a divider inside the hole is not" begin
        corners = Asap.Node[
            Asap.Node([0.0u"m", 0.0u"m", 3.6u"m"], :free),
            Asap.Node([24.0u"m", 0.0u"m", 3.6u"m"], :free),
            Asap.Node([24.0u"m", 24.0u"m", 3.6u"m"], :free),
            Asap.Node([0.0u"m", 24.0u"m", 3.6u"m"], :free),
        ]
        hole = [(8.0, CORE_LOBBY_Y), (16.0, CORE_LOBBY_Y), (16.0, 16.0), (8.0, 16.0)]
        on_shaft_wall = Asap.Node([12.0u"m", CORE_LOBBY_Y * u"m", 3.6u"m"], :free)
        at_tee = Asap.Node([CORE_ELEV_X * u"m", CORE_LOBBY_Y * u"m", 3.6u"m"], :free)
        in_shaft = Asap.Node([CORE_ELEV_X * u"m", 13.0u"m", 3.6u"m"], :free)
        got = StructuralSynthesizer._slab_wall_nodes(
            Asap.Node[on_shaft_wall, at_tee, in_shaft], Asap.Node[], corners; holes = [hole])
        @test on_shaft_wall in got
        @test at_tee in got
        @test !(in_shaft in got)
    end

    @testset "Interior walls join the core at the tees" begin
        # One wall per skeleton edge until the analysis splits a stem that
        # lands mid-wall. West and east are already split at the lobby.
        @test count(w -> w.story == 1, struc.walls) == 9
        split_tee_junctions!(struc.walls)
        for w in struc.walls
            StructuralSynthesizer.check_wall_openings(w)
        end
        StructuralSynthesizer.refuse_openings_in_joined_corners!(struc.walls)
        asms = wall_assemblies(struc.walls)
        joined = filter(a -> a.joined, asms)
        @test length(joined) == CORE_STORIES
        @test length(asms) == CORE_STORIES
        # Each story's dividers now end on the lobby wall and the north wall.
        for story in 0:(CORE_STORIES - 1)
            legs = [struc.walls[i] for i in joined[findfirst(a -> a.story == story, joined)].wall_indices]
            function _has_end(x, y)
                any(w -> (abs(w.x1 - x) <= 1e-6 && abs(w.y1 - y) <= 1e-6) ||
                         (abs(w.x2 - x) <= 1e-6 && abs(w.y2 - y) <= 1e-6), legs)
            end
            @test _has_end(CORE_ELEV_X, CORE_LOBBY_Y)
            @test _has_end(CORE_ELEV_X, 2 * CORE_BAY)
            @test _has_end(CORE_STAIR_X, CORE_LOBBY_Y)
            @test _has_end(CORE_STAIR_X, 2 * CORE_BAY)
        end
    end

    @testset "Core corners stay columns, and a column bay draws their stored areas" begin
        corners = ((CORE_BAY, CORE_BAY), (2 * CORE_BAY, CORE_BAY),
                   (2 * CORE_BAY, 2 * CORE_BAY), (CORE_BAY, 2 * CORE_BAY))
        n = 0
        for col in struc.columns
            c = Meshes.coords(struc.skeleton.vertices[col.vertex_idx])
            p = (ustrip(u"m", c.x), ustrip(u"m", c.y))
            any(q -> hypot(p[1] - q[1], p[2] - q[2]) < 1e-3, corners) && (n += 1)
        end
        @test n == 4 * CORE_STORIES

        vc = struc.skeleton.geometry.vertex_coords
        cell_idx = findfirst(eachindex(struc.cells)) do i
            vis = struc.skeleton.face_vertex_indices[struc.cells[i].face_idx]
            zs = [vc[v, 3] for v in vis]
            xs = [vc[v, 1] for v in vis]
            ys = [vc[v, 2] for v in vis]
            all(z -> abs(z - 3.6) < 1e-3, zs) &&
                all(x -> -1e-3 <= x <= CORE_BAY + 1e-3, xs) &&
                all(y -> -1e-3 <= y <= CORE_BAY + 1e-3, ys)
        end
        cell_idx === nothing && error("no column bay at the origin")
        sides = Int[]
        area = 0.0
        for col in struc.columns
            poly = get(column_tributary_polygons(struc, col), cell_idx, nothing)
            poly === nothing && continue
            push!(sides, length(poly))
            xy = [(ustrip(u"m", x), ustrip(u"m", y)) for (x, y) in poly]
            area += abs(_loop_area(xy))
        end
        @test length(sides) == 4
        @test all(s -> s >= 4, sides)
        @test area ≈ CORE_BAY * CORE_BAY atol = 0.5

        design = BuildingDesign(struc)
        packet = StructuralSynthesizer.ScenePacket(String[], (0.0, 0.0, 0.0),
            Dict{String, Any}("counts" => Dict{String, Any}()),
            StructuralSynthesizer.SceneBuffer[])
        drawn = StructuralSynthesizer._with_tributaries(packet, design)
        kinds = scene_u8(drawn, "tributary_kind")
        cells = scene_u32(drawn, "tributary_cell")
        counts = scene_u32(drawn, "tributary_count")
        @test length(kinds) == length(cells) == length(counts)
        bay = [i for i in eachindex(cells) if cells[i] == UInt32(cell_idx - 1)]
        @test length(bay) == 4
        @test all(i -> kinds[i] == 0x00 && counts[i] >= 4, bay)
    end
end
