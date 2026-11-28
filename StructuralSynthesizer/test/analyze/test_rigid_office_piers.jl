# Gravity-stage piers on the rigid office.
#
# Twelve walls, 6 m by 0.3 m, three stories, isolated ends. No lateral
# design. Rigid-diaphragm masters make the gravity stage use the
# second-order cut. A pier with length / thickness ≤ 3 is a column
# (ACI 318-19 §2.3). That column is checked only when §6.6.4.3(a) holds.
# §6.6.4.6 is not applied.

using Test
using Unitful
using Meshes
using Asap
using StructuralSynthesizer

const _RIGID_SEGMENTS = (
    (0.0, 0.0, 6.0, 0.0),
    (6.0, 12.0, 12.0, 12.0),
    (12.0, 0.0, 12.0, 6.0),
    (0.0, 6.0, 0.0, 12.0),
)

function _rigid_xy(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function _rigid_horizontal(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    c1 = Meshes.coords(skel.vertices[v1])
    c2 = Meshes.coords(skel.vertices[v2])
    return abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

function _rigid_same_plan(skel, eidx, x1, y1, x2, y2)
    v1, v2 = skel.edge_indices[eidx]
    ax, ay = _rigid_xy(skel, v1)
    bx, by = _rigid_xy(skel, v2)
    return (hypot(ax - x1, ay - y1) <= 1e-6 && hypot(bx - x2, by - y2) <= 1e-6) ||
           (hypot(ax - x2, ay - y2) <= 1e-6 && hypot(bx - x1, by - y1) <= 1e-6)
end

function _rigid_claim!(skel, beams, x1, y1, x2, y2)
    for story in 0:2
        edges = [e for e in skel.stories[story].edges
                 if e in beams && _rigid_horizontal(skel, e) &&
                    _rigid_same_plan(skel, e, x1, y1, x2, y2)]
        eidx = only(edges)
        filter!(!=(eidx), skel.groups_edges[:beams])
        delete!(beams, eidx)
        walls = get!(skel.groups_edges, :walls, Int[])
        eidx in walls || push!(walls, eidx)
    end
end

"The south ground wall, the 6 m line at y = 0."
function _rigid_south_wall(struc)
    return only(w for w in struc.walls if w.story == 0 &&
        min(w.y1, w.y2) == 0.0 && max(w.y1, w.y2) == 0.0 &&
        min(w.x1, w.x2) == 0.0 && max(w.x1, w.x2) == 6.0)
end

function _rigid_office(; narrow::Bool=false, deep::Bool=false, rigid::Bool=true)
    skel = gen_medium_office(12.0u"m", 12.0u"m", 4.0u"m", 2, 2, 3)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    for seg in _RIGID_SEGMENTS
        _rigid_claim!(skel, beams, seg...)
    end
    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=VaultOptions(rise=1.0u"m", thickness=0.05u"m"),
        wall_thickness=0.3u"m")
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    narrow && deep && error("ordinary-wall fixture: one opening case at a time")
    if narrow
        # Two 0.8 m piers beside a door. 0.8 / 0.3 < 3, so §2.3 routes
        # them as columns. The head is a 0.4 m beam, span / depth = 11.
        _rigid_south_wall(struc).openings = [WallOpening(0.8, 0.0, 4.4, 3.6, :door)]
    elseif deep
        # Door head from 2 m to 4 m over a 3 m opening. Span / depth = 1.5,
        # so §9.9.1.1(a) routes the lintel as one deep beam. The piers beside
        # it are 1.5 m, longer than 3t, so they stay walls.
        _rigid_south_wall(struc).openings = [WallOpening(1.5, 0.0, 3.0, 2.0, :door)]
    end
    mode = rigid ? :rigid : :flexible
    params = DesignParameters(diaphragm_mode=mode, skip_visualization=true)
    to_asap!(struc; params=params, diaphragms=mode)
    return struc, design_ordinary_walls!(struc, params)
end

@testset "a rigid office withholds no solid pier" begin
    struc, result = _rigid_office()
    @test length(struc.asap_rigid_links) > 0
    @test length(struc.walls) == 12
    @test length(result.checks) == 12
    for wall in struc.walls
        t = ustrip(u"m", wall.thickness)
        @test hypot(wall.x2 - wall.x1, wall.y2 - wall.y1) / t > 3
        @test isempty(wall.openings)
    end
    for records in values(result.checks)
        @test all(r -> r.passed, records)
        @test !any(r -> occursin("withheld", r.check), records)
        @test any(r -> r.check == "in-plane shear" && r.passed, records)
        @test any(r -> occursin("bearing wall", r.check) && r.passed, records)
    end
end

@testset "a narrow pier on the rigid office stops at out-of-plane slenderness" begin
    struc, result = _rigid_office(; narrow=true)
    @test length(struc.asap_rigid_links) > 0
    layout = StructuralSynthesizer.wall_segment_layout(struc.walls, struc.skeleton)
    columns = [seg for seg in layout.segments if seg.design === :column]
    @test length(columns) == 2
    @test all(seg -> seg.s1 - seg.s0 ≈ 0.8 && seg.z1 - seg.z0 ≈ 3.6, columns)
    @test only(seg.design for seg in layout.segments if seg.kind === :horizontal) === :beam

    south = findfirst(w -> w === _rigid_south_wall(struc), struc.walls)
    records = result.checks[south]
    # §6.6.4.3(a) passed, so the column check ran. §6.6.4.6 was not applied.
    @test !any(r -> r.check == "column segment withheld", records)
    inp = [r for r in records if r.check == "in-plane slenderness"]
    oop = [r for r in records if r.check == "out-of-plane slenderness"]
    @test !isempty(inp) && all(r -> r.passed && r.demand ≈ 15.0, inp)
    # Weak-axis r = 0.3b, b = 0.3 m, ℓu = 3.6 m, k = 1 → kℓu/r = 40.
    # The neglect limit is at most 40, and this pier is past it.
    @test !isempty(oop) && all(r -> !r.passed && r.demand ≈ 40.0 && r.capacity < 40, oop)
    @test all(r -> occursin("6.2.5.1", r.clause), oop)
    @test !any(r -> occursin("axial-flexure", r.check), records)
    @test any(r -> r.check == "spandrel flexure" && r.passed, records)
    @test any(r -> r.check == "spandrel shear" && r.passed, records)
    for (i, other) in enumerate(struc.walls)
        i == south && continue
        @test all(r -> r.passed, result.checks[i])
        @test !any(r -> occursin("withheld", r.check), result.checks[i])
    end
end

@testset "without a rigid diaphragm a narrow pier stays withheld" begin
    struc, result = _rigid_office(; narrow=true, rigid=false)
    @test isempty(struc.asap_rigid_links)
    south = findfirst(w -> w === _rigid_south_wall(struc), struc.walls)
    records = result.checks[south]
    # One record for each of the two column piers beside the door.
    withheld = [r for r in records if r.check == "column segment withheld"]
    @test length(withheld) == 2
    @test all(r -> r.passed == false && occursin("6.6.4.3", r.clause), withheld)
    @test !any(r -> occursin("slenderness", r.check), records)
    @test !any(r -> occursin("axial-flexure", r.check), records)
    @test any(r -> r.check == "spandrel flexure" && r.passed, records)
    @test any(r -> r.check == "spandrel shear" && r.passed, records)
end

@testset "a deep lintel on the meshed office is one strut and one tie" begin
    struc, result = _rigid_office(; deep=true)
    @test length(struc.asap_rigid_links) > 0
    layout = StructuralSynthesizer.wall_segment_layout(struc.walls, struc.skeleton)
    lintels = [seg for seg in layout.segments if seg.kind === :horizontal]
    lintel = only(lintels)
    @test lintel.design === :stm
    @test lintel.s1 - lintel.s0 ≈ 3.0
    @test lintel.z1 - lintel.z0 ≈ 2.0
    south = findfirst(w -> w === _rigid_south_wall(struc), struc.walls)
    records = result.checks[south]
    @test !any(r -> r.check == "horizontal segment unchecked", records)
    @test !any(r -> r.check == "spandrel flexure", records)
    for name in ("deep-beam shear limit", "deep-beam side reinforcement",
                 "deep-beam strut", "deep-beam tie", "deep-beam node")
        hits = [r for r in records if r.check == name]
        @test !isempty(hits)
        @test all(r -> r.passed, hits)
    end
    shear = [r for r in records if r.check == "deep-beam shear limit"]
    @test all(r -> occursin("9.9.2.1", r.clause) && r.capacity > 0, shear)
    tie = [r for r in records if r.check == "deep-beam tie"]
    @test all(r -> occursin("23.7.2", r.clause), tie)
    # The stories above the door stay on the gross pier.
    above = 0
    for (i, wall) in enumerate(struc.walls)
        wall.story == 0 && continue
        above += 1
        @test isempty(wall.openings)
        @test any(r -> occursin("bearing wall", r.check) && r.passed, result.checks[i])
        @test !any(r -> startswith(r.check, "deep-beam"), result.checks[i])
    end
    @test above >= 2
end
