# Wall openings: geometric gates, T-split rebasing, and a mesh that omits the holes.
#
# A solid wall stays on the 8 × 8 grid. A wall with an opening drops the cells
# whose centres lie inside it, and a wall stacked or joined with it shares
# those grid lines so the nodes are the same objects.

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer
import StructuralSynthesizer: wall_segment_layout

const _WO_T = typeof(1.0u"m")

function _wo_skeleton()
    skel = BuildingSkeleton{Float64}()
    skel.geometry = GeometryCache(
        [0.0 0.0 0.0; 6.0 0.0 0.0],
        Float64[], Float64[], Dict{Int, Int}(), Dict{Int, Int}())
    skel.stories[0] = Story{Float64}(0.0)
    skel.stories[1] = Story{Float64}(4.0)
    return skel
end

function _wo_wall(x1, y1, x2, y2; story=0, height=4.0, openings=WallOpening[])
    return Wall([1], height * u"m"; thickness=0.3u"m",
                x1=x1, y1=y1, x2=x2, y2=y2, story=story, openings=openings)
end

function _wo_mesh(walls)
    skel = BuildingSkeleton{_WO_T}()
    for (k, z) in ((0, 0.0), (1, 4.0), (2, 8.0))
        skel.stories[k] = Story{_WO_T}(z * u"m")
    end
    struc = BuildingStructure(skel)
    append!(struc.walls, walls)
    params = DesignParameters(materials=MaterialOptions(concrete=NWC_4000))
    return StructuralSynthesizer._mesh_wall_shells(
        struc, params, Asap.Node[], Asap.ShellTri3[])
end

function _wo_nodes_at(shells, x, y, z)
    hits = Asap.Node[]
    for sh in shells, nd in sh.nodes
        p = nd.position
        hypot(ustrip(u"m", p[1]) - x, ustrip(u"m", p[2]) - y, ustrip(u"m", p[3]) - z) <= 1e-6 ||
            continue
        any(h === nd for h in hits) && continue
        push!(hits, nd)
    end
    return hits
end

function _wo_area(shells)
    area = 0.0
    for sh in shells
        p = [ntuple(k -> ustrip(u"m", nd.position[k]), 3) for nd in sh.nodes]
        ux, uy, uz = p[2][1] - p[1][1], p[2][2] - p[1][2], p[2][3] - p[1][3]
        vx, vy, vz = p[3][1] - p[1][1], p[3][2] - p[1][2], p[3][3] - p[1][3]
        area += 0.5 * hypot(uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
    end
    return area
end

"Story elevations for a stack whose base is at z = 0."
function _wo_elevations()
    skel = BuildingSkeleton{_WO_T}()
    for (k, z) in ((0, 0.0), (1, 4.0), (2, 8.0))
        skel.stories[k] = Story{_WO_T}(z * u"m")
    end
    return skel
end

function _wo_segment(layout, kind, s0, z0)
    hits = [seg for seg in layout.segments
            if seg.kind === kind && isapprox(seg.s0, s0; atol=1e-6) &&
               isapprox(seg.z0, z0; atol=1e-6)]
    return only(hits)
end

"Triangles whose centroid, measured on the wall, lies inside the opening."
function _wo_shells_in_wall_opening(shells, wall, op, zbase)
    L = wall_length(wall)
    dx = (wall.x2 - wall.x1) / L
    dy = (wall.y2 - wall.y1) / L
    n = 0
    for sh in shells
        xs = [ustrip(u"m", nd.position[1]) for nd in sh.nodes]
        ys = [ustrip(u"m", nd.position[2]) for nd in sh.nodes]
        zs = [ustrip(u"m", nd.position[3]) for nd in sh.nodes]
        s = (sum(xs) / 3 - wall.x1) * dx + (sum(ys) / 3 - wall.y1) * dy
        z = sum(zs) / 3 - zbase
        op.s0 < s < op.s0 + op.width && op.z0 < z < op.z0 + op.height && (n += 1)
    end
    return n
end

"Unit normal of the wall in plan."
function _wo_wall_normal(wall)
    L = wall_length(wall)
    return (-(wall.y2 - wall.y1) / L, (wall.x2 - wall.x1) / L)
end

"The column whose top is at this plan point. `z` selects one story of a stack."
function _wo_column_at(struc, x, y; z=nothing)
    hits = [col for col in struc.columns
            if let c = vertex_coords(struc.skeleton, col.vertex_idx)
                hypot(c.x - x, c.y - y) <= 1e-4 &&
                    (z === nothing || abs(c.z - z) <= 1e-4)
            end]
    return only(hits)
end

"Plan position at distance `s` along a wall whose ends are shifted by `off1` and `off2`."
function _wo_offset_xy(wall, s, off1, off2)
    L = wall_length(wall)
    f = s / L
    x = (1 - f) * (wall.x1 + off1[1]) + f * (wall.x2 + off2[1])
    y = (1 - f) * (wall.y1 + off1[2]) + f * (wall.y2 + off2[2])
    return x, y
end

"Triangles whose centroid lies inside the opening, measured along the shifted wall."
function _wo_shells_in_shifted_opening(shells, wall, op, zbase, off1, off2)
    ax = wall.x1 + off1[1]
    ay = wall.y1 + off1[2]
    bx = wall.x2 + off2[1]
    by = wall.y2 + off2[2]
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    L = wall_length(wall)
    n = 0
    for sh in shells
        xs = [ustrip(u"m", nd.position[1]) for nd in sh.nodes]
        ys = [ustrip(u"m", nd.position[2]) for nd in sh.nodes]
        zs = [ustrip(u"m", nd.position[3]) for nd in sh.nodes]
        f = ((sum(xs) / 3 - ax) * dx + (sum(ys) / 3 - ay) * dy) / L2
        s = f * L
        z = sum(zs) / 3 - zbase
        op.s0 < s < op.s0 + op.width && op.z0 < z < op.z0 + op.height && (n += 1)
    end
    return n
end

"Triangles whose centroid lies inside the opening. The wall runs along x at y = 0."
function _wo_shells_in_opening(shells, op::WallOpening)
    n = 0
    for sh in shells
        xs = [ustrip(u"m", nd.position[1]) for nd in sh.nodes]
        zs = [ustrip(u"m", nd.position[3]) for nd in sh.nodes]
        s = sum(xs) / 3
        z = sum(zs) / 3
        op.s0 < s < op.s0 + op.width && op.z0 < z < op.z0 + op.height && (n += 1)
    end
    return n
end

@testset "wall openings" begin
    @testset "an opening has to sit inside one wall" begin
        skel = _wo_skeleton()
        window = WallOpening(1.0, 1.0, 1.5, 1.2, :window)
        add_wall_opening!(skel, 1, 2, 0, window)
        @test length(skel.wall_openings) == 1
        @test skel.wall_openings[1].opening.kind === :window

        @test_throws ArgumentError add_wall_opening!(
            skel, 1, 2, 0, WallOpening(0.0, 0.0, 6.0, 1.0, :door))
        @test_throws ArgumentError add_wall_opening!(
            skel, 1, 2, 0, WallOpening(1.0, 0.0, 1.0, 4.0, :door))
        @test_throws ArgumentError add_wall_opening!(
            skel, 1, 2, 0, WallOpening(1.0, 0.0, 1.0, 1.0, :window))
        @test_throws ArgumentError add_wall_opening!(
            skel, 1, 2, 0, WallOpening(1.0, 0.5, 1.0, 2.0, :door))
        @test_throws ArgumentError add_wall_opening!(
            skel, 1, 2, 0, WallOpening(1.0, 1.0, 1.5, 1.2, :window))
        @test_throws ArgumentError add_wall_opening!(
            skel, 1, 2, 0, WallOpening(5.5, 1.0, 1.0, 1.0, :window))
        @test length(skel.wall_openings) == 1

        copied = StructuralSynthesizer.wall_openings_for_edge(skel, 2, 1, 0, 6.0, 4.0)
        @test only(copied).s0 ≈ 6.0 - 1.0 - 1.5
        @test only(copied).width ≈ 1.5
    end

    @testset "a T-split keeps an opening on its piece" begin
        # The stem ends on the through-wall. A flange that crosses the wall
        # without an end on it is not a junction this split looks for.
        stem() = _wo_wall(3, 0, 3, 2)
        web = _wo_wall(0, 0, 6, 0; openings=[WallOpening(0.4, 1.0, 1.0, 1.0, :window)])
        walls = [web, stem()]
        split_tee_junctions!(walls)
        @test length(walls) == 3
        @test only(walls[1].openings).s0 ≈ 0.4
        @test isempty(walls[2].openings)
        @test isempty(walls[3].openings)

        straddling = _wo_wall(0, 0, 6, 0; openings=[WallOpening(2.5, 1.0, 1.0, 1.0, :window)])
        @test_throws ArgumentError split_tee_junctions!([straddling, stem()])

        far = _wo_wall(0, 0, 6, 0; openings=[WallOpening(4.0, 1.0, 1.0, 1.0, :window)])
        walls = [far, stem()]
        split_tee_junctions!(walls)
        @test isempty(walls[1].openings)
        @test only(walls[2].openings).s0 ≈ 1.0
        @test isempty(walls[3].openings)
    end

    @testset "a solid wall keeps the 8 by 8 mesh" begin
        shells, nodes, by, cells = _wo_mesh([_wo_wall(0, 0, 6, 0)])
        @test length(by[1]) == WALL_MESH_DIV * WALL_MESH_ROWS * 2
        @test length(nodes) == (WALL_MESH_DIV + 1) * (WALL_MESH_ROWS + 1)
        @test cells[1][1] == (1, 1)
        @test cells[1][end] == (WALL_MESH_DIV, WALL_MESH_ROWS)
        @test _wo_area(shells) ≈ 6.0 * 4.0 atol=1e-9
        @test length(_wo_nodes_at(shells, 6.0, 0.0, 4.0)) == 1
    end

    @testset "an opening is a hole, and the net area is the wall minus the hole" begin
        opening = WallOpening(2.0, 1.5, 2.0, 1.0, :window)
        shells, _, by, _ = _wo_mesh([_wo_wall(0, 0, 6, 0; openings=[opening])])
        @test _wo_shells_in_opening(by[1], opening) == 0
        @test _wo_area(shells) ≈ 6.0 * 4.0 - 2.0 * 1.0 atol=1e-8
    end

    @testset "stacked and joined walls share the opening's grid lines" begin
        opening = WallOpening(2.0, 1.2, 1.0, 0.7, :window)
        lower = _wo_wall(0, 0, 6, 0; story=0, openings=[opening])
        upper = _wo_wall(0, 0, 6, 0; story=1)
        lower.wall_above = upper
        shells, _, _, _ = _wo_mesh([lower, upper])
        @test length(_wo_nodes_at(shells, 2.0, 0.0, 4.0)) == 1
        @test length(_wo_nodes_at(shells, 3.0, 0.0, 4.0)) == 1

        reversed = _wo_wall(6, 0, 0, 0; story=1)
        lower.wall_above = reversed
        shells, _, _, _ = _wo_mesh([lower, reversed])
        @test length(_wo_nodes_at(shells, 2.0, 0.0, 4.0)) == 1

        leg = _wo_wall(0, 0, 6, 0; openings=[opening])
        stem = _wo_wall(6, 0, 6, 4)
        shells, _, _, _ = _wo_mesh([leg, stem])
        @test length(_wo_nodes_at(shells, 6.0, 0.0, 1.2)) == 1
        @test length(_wo_nodes_at(shells, 6.0, 0.0, 1.9)) == 1
    end

    @testset "a door in the joined corner is refused" begin
        door = WallOpening(0.0, 0.0, 1.0, 2.0, :door)
        leg = _wo_wall(0, 0, 6, 0; openings=[door])
        stem = _wo_wall(0, 0, 0, 4)
        @test_throws ArgumentError _wo_mesh([leg, stem])

        clear = _wo_wall(0, 0, 6, 0; openings=[WallOpening(1.0, 0.0, 1.0, 2.0, :door)])
        shells, _, _, _ = _wo_mesh([clear, stem])
        @test _wo_area(shells) > 0
    end

    @testset "the hand stiffness formula does not cover a wall with an opening" begin
        solid = _wo_wall(0, 0, 6, 0)
        @test wall_lateral_stiffness(solid, NWC_4000) > 0u"N/m"
        opened = _wo_wall(0, 0, 6, 0; openings=[WallOpening(1.0, 1.0, 1.0, 1.0, :window)])
        @test_throws ArgumentError wall_lateral_stiffness(opened, NWC_4000)
    end

    @testset "segments follow the openings, and a solid wall has none" begin
        skel = _wo_elevations()
        solid = wall_segment_layout([_wo_wall(0, 0, 6, 0)], skel)
        @test isempty(solid.segments)
        @test only(solid.solid_rows).z0 == 0.0
        @test only(solid.solid_rows).z1 == 4.0

        window = WallOpening(2.0, 1.5, 2.0, 1.0, :window)
        layout = wall_segment_layout([_wo_wall(0, 0, 6, 0; openings=[window])], skel)
        left = _wo_segment(layout, :vertical, 0.0, 1.5)
        right = _wo_segment(layout, :vertical, 4.0, 1.5)
        @test left.s1 ≈ 2.0 && left.z1 ≈ 2.5 && left.design === :wall
        @test right.s1 ≈ 6.0 && right.design === :wall
        sill = _wo_segment(layout, :horizontal, 2.0, 0.0)
        lintel = _wo_segment(layout, :horizontal, 2.0, 2.5)
        @test sill.s1 ≈ 4.0 && sill.z1 ≈ 1.5 && sill.design === :stm
        @test lintel.z1 ≈ 4.0 && lintel.design === :stm
        @test sort(collect(r.z0 for r in layout.solid_rows)) ≈ [0.0, 2.5]

        # A pier narrower than 3t is not a wall. The ratio of exactly 3 is the
        # same comparison, on values that are exact in floating point.
        narrow = WallOpening(0.5, 1.0, 5.0, 1.0, :window)
        narrow_layout = wall_segment_layout(
            [_wo_wall(0, 0, 6, 0; openings=[narrow])], skel)
        @test _wo_segment(narrow_layout, :vertical, 0.0, 1.0).design === :column
        @test _wo_segment(narrow_layout, :vertical, 5.5, 1.0).design === :column
        @test StructuralSynthesizer._segment_design(:vertical, 0.0, 3.0, 0.0, 1.0, 1.0) === :column
        @test StructuralSynthesizer._segment_design(:vertical, 0.0, 3.0 + 1e-9, 0.0, 1.0, 1.0) === :wall

        # Clear span / depth = 4 is a deep beam (§9.9.1.1(a): does not exceed 4).
        deep = WallOpening(1.0, 2.0, 4.0, 1.0, :window)
        deep_layout = wall_segment_layout([_wo_wall(0, 0, 6, 0; openings=[deep])], skel)
        @test _wo_segment(deep_layout, :horizontal, 1.0, 3.0).design === :stm
        shallow = WallOpening(0.9, 3.0, 4.2, 0.2, :window)
        shallow_layout = wall_segment_layout(
            [_wo_wall(0, 0, 6, 0; openings=[shallow])], skel)
        @test _wo_segment(shallow_layout, :horizontal, 0.9, 3.2).design === :beam
    end

    @testset "a solid story above a window is not part of the lintel" begin
        skel = _wo_elevations()
        # Lintel depth 0.4 m, clear span 2 m, so the band is a beam.
        lower = _wo_wall(0, 0, 6, 0; story=0,
                         openings=[WallOpening(2.0, 3.2, 2.0, 0.4, :window)])
        upper = _wo_wall(0, 0, 6, 0; story=1)
        lower.wall_above = upper
        layout = wall_segment_layout([lower, upper], skel)
        lintel = _wo_segment(layout, :horizontal, 2.0, 3.6)
        @test lintel.z1 ≈ 4.0
        @test lintel.design === :beam
        @test !any(seg.kind === :horizontal && seg.z0 >= 4.0 - 1e-9
                   for seg in layout.segments)
    end

    @testset "a spandrel crosses the slab, and a pier does when nothing is between" begin
        skel = _wo_elevations()
        lower = _wo_wall(0, 0, 6, 0; story=0,
                         openings=[WallOpening(2.0, 2.0, 2.0, 1.0, :window)])
        upper = _wo_wall(0, 0, 6, 0; story=1,
                         openings=[WallOpening(2.0, 1.0, 2.0, 1.0, :window)])
        lower.wall_above = upper
        layout = wall_segment_layout([lower, upper], skel)
        spandrel = _wo_segment(layout, :horizontal, 2.0, 3.0)
        @test spandrel.z1 ≈ 5.0 && spandrel.design === :stm
        @test _wo_segment(layout, :vertical, 0.0, 2.0).z1 ≈ 3.0
        @test _wo_segment(layout, :vertical, 0.0, 5.0).z1 ≈ 6.0

        door_below = _wo_wall(0, 0, 6, 0; story=0,
                              openings=[WallOpening(2.0, 3.0, 2.0, 1.0, :window)])
        door_above = _wo_wall(0, 0, 6, 0; story=1,
                              openings=[WallOpening(2.0, 0.0, 2.0, 1.0, :door)])
        door_below.wall_above = door_above
        crossed = wall_segment_layout([door_below, door_above], skel)
        pier = _wo_segment(crossed, :vertical, 0.0, 3.0)
        @test pier.z1 ≈ 5.0
        @test !any(seg.kind === :horizontal && seg.z0 ≈ 4.0 for seg in crossed.segments)
    end

    @testset "an overlap cell is a pier" begin
        skel = _wo_elevations()
        wall = _wo_wall(0, 0, 6, 0; openings=[
            WallOpening(1.0, 1.0, 1.0, 1.0, :window),
            WallOpening(3.0, 2.5, 1.0, 1.0, :window),
        ])
        layout = wall_segment_layout([wall], skel)
        @test any(seg.kind === :vertical && seg.s0 <= 3.0 && seg.s1 >= 4.0 &&
                  seg.z0 ≈ 1.0 && seg.z1 ≈ 2.0 for seg in layout.segments)
        @test !any(seg.kind === :horizontal && seg.s0 ≈ 3.0 && seg.z0 ≈ 1.0
                   for seg in layout.segments)
    end

    @testset "an opening on a reversed upper wall is measured from the lower start" begin
        skel = _wo_elevations()
        lower = _wo_wall(0, 0, 6, 0; story=0)
        upper = _wo_wall(6, 0, 0, 0; story=1,
                         openings=[WallOpening(1.0, 1.0, 1.0, 1.0, :window)])
        lower.wall_above = upper
        layout = wall_segment_layout([lower, upper], skel)
        @test _wo_segment(layout, :vertical, 0.0, 5.0).s1 ≈ 4.0
        @test _wo_segment(layout, :vertical, 5.0, 5.0).s1 ≈ 6.0
    end

    @testset "segment shells are the quads inside the segment" begin
        skel = _wo_elevations()
        opening = WallOpening(2.0, 1.5, 2.0, 1.0, :window)
        wall = _wo_wall(0, 0, 6, 0; openings=[opening])
        _, _, by, _ = _wo_mesh([wall])
        layout = wall_segment_layout([wall], skel; shells_by_wall=by)
        @test sum(_wo_area(seg.shells) for seg in layout.segments) ≈ 10.0 atol=1e-6
        for seg in layout.segments
            @test _wo_shells_in_opening(seg.shells, opening) == 0
        end
    end

    @testset "a pierced wall is laid out as segments" begin
        solid = _wo_wall(0, 0, 6, 0)
        opened = _wo_wall(0, 0, 6, 0; openings=[WallOpening(1.0, 1.0, 1.0, 1.0, :window)])
        @test isempty(solid.openings)
        @test length(opened.openings) == 1
        layout = wall_segment_layout([opened], _wo_elevations())
        @test any(seg.kind === :vertical for seg in layout.segments)
        @test any(seg.kind === :horizontal for seg in layout.segments)
    end

    @testset "an opening survives member setup and follows a column offset" begin
        # Two stories: the first floor has beams, floor faces, and a story
        # above. Story 0 is the support level and has no beam grid.
        skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 2)
        beams = Set(get(skel.groups_edges, :beams, Int[]))
        function _wo_plan_length(e)
            v1, v2 = skel.edge_indices[e]
            a = vertex_coords(skel, v1)
            b = vertex_coords(skel, v2)
            return abs(a.z - b.z) <= 1e-6 ? hypot(b.x - a.x, b.y - a.y) : -1.0
        end
        edges = [e for e in skel.stories[1].edges if e in beams]
        eidx = argmax(_wo_plan_length, edges)
        filter!(!=(eidx), skel.groups_edges[:beams])
        push!(get!(skel.groups_edges, :walls, Int[]), eidx)

        v1, v2 = skel.edge_indices[eidx]
        hi, lo = max(v1, v2), min(v1, v2)
        # Stored from the higher vertex. The wall is built from the lower one,
        # so the copy onto the wall has to mirror s.
        add_wall_opening!(skel, hi, lo, 1, WallOpening(2.0, 1.0, 2.0, 1.5, :window))

        struc = BuildingStructure(skel)
        initialize!(struc; floor_type=:vault, material=NWC_4000,
                    floor_opts=VaultOptions(rise=1.0u"m", thickness=0.05u"m"),
                    wall_thickness=0.3u"m")
        wall = only(struc.walls)
        op = only(wall.openings)
        L = wall_length(wall)
        H = ustrip(u"m", wall.base.L)
        @test op.s0 ≈ L - 2.0 - 2.0
        @test op.width ≈ 2.0 && op.z0 ≈ 1.0 && op.height ≈ 1.5
        @test skel.wall_openings[1].opening.s0 ≈ 2.0

        params = DesignParameters(
            materials=MaterialOptions(concrete=NWC_5000),
            diaphragm_mode=:none)
        to_asap!(struc; params=params, diaphragms=:none)
        shells = [s for s in struc.asap_model.shell_elements if s.id === :wall]
        zbase = ustrip(u"m", skel.stories[wall.story].elevation)
        @test _wo_area(shells) ≈ L * H - op.width * op.height atol=1e-6
        @test _wo_shells_in_wall_opening(shells, wall, op, zbase) == 0
        @test length(_wo_nodes_at(shells, wall.x1 + (wall.x2 - wall.x1) * op.s0 / L,
                                   wall.y1 + (wall.y2 - wall.y1) * op.s0 / L,
                                   zbase + op.z0)) == 1

        # The same shift at both ends translates the hole with the column line.
        nx, ny = _wo_wall_normal(wall)
        shift = (0.2 * nx, 0.2 * ny)
        # The wall rises through this story. The columns that move its ends
        # are the ones whose tops are at the top of the wall.
        ztop = zbase + H
        c1 = _wo_column_at(struc, wall.x1, wall.y1; z=ztop)
        c2 = _wo_column_at(struc, wall.x2, wall.y2; z=ztop)
        c1.structural_offset = shift
        c2.structural_offset = shift
        to_asap!(struc; params=params, diaphragms=:none)
        shells = [s for s in struc.asap_model.shell_elements if s.id === :wall]
        x, y = _wo_offset_xy(wall, op.s0, shift, shift)
        @test length(_wo_nodes_at(shells, x, y, zbase + op.z0)) == 1
        @test _wo_area(shells) ≈ L * H - op.width * op.height atol=1e-6

        # Different shifts skew the pier. The opening edge is the fraction
        # along that skewed line, not the point on the architectural line.
        c2.structural_offset = (0.0, 0.0)
        to_asap!(struc; params=params, diaphragms=:none)
        shells = [s for s in struc.asap_model.shell_elements if s.id === :wall]
        xs, ys = _wo_offset_xy(wall, op.s0, shift, (0.0, 0.0))
        xa = wall.x1 + (wall.x2 - wall.x1) * op.s0 / L
        ya = wall.y1 + (wall.y2 - wall.y1) * op.s0 / L
        @test hypot(xs - xa, ys - ya) > 0.05
        @test length(_wo_nodes_at(shells, xs, ys, zbase + op.z0)) == 1
        @test _wo_shells_in_shifted_opening(shells, wall, op, zbase, shift, (0.0, 0.0)) == 0
    end
end
