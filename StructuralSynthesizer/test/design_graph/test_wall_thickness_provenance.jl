# A jump has to rerun ordinary walls, and the new thickness has to reach the
# foundations. `wall_thickness` is baked when the walls are meshed, so that
# edit builds a new engine. `jump_wall_thickness` and
# `wall_thickness_grouping` are read by the jump. The wall node's output
# hash is the thickness list, so a jump cannot leave the foundation snapshot
# on the old walls.

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using Meshes

const _SS = StructuralSynthesizer

function _near3(a, b)
    all(abs(a[i] - b[i]) <= 1e-3 for i in 1:3)
end

function _plan_edge(skel, x1, y1, z, x2, y2)
    for (eidx, (a, b)) in enumerate(skel.edge_indices)
        ca = Meshes.coords(skel.vertices[a])
        cb = Meshes.coords(skel.vertices[b])
        p = (ustrip(u"m", ca.x), ustrip(u"m", ca.y), ustrip(u"m", ca.z))
        q = (ustrip(u"m", cb.x), ustrip(u"m", cb.y), ustrip(u"m", cb.z))
        (_near3(p, (x1, y1, z)) && _near3(q, (x2, y2, z))) && return eidx
        (_near3(p, (x2, y2, z)) && _near3(q, (x1, y1, z))) && return eidx
    end
    error("no edge from ($x1, $y1, $z) to ($x2, $y2, $z)")
end

"""One 8 m bay, one 6 m story. The four base edges are walls, so the cell is a mat.

The story is tall enough that 150 mm walls keep the mat rigid. They pass
the pier check by raising reinforcement, so the jump does not change the
thickness; the hash check covers a thickness that does change.
"""
function _wall_cell_skeleton()
    skel = gen_medium_office(8.0u"m", 8.0u"m", 6.0u"m", 1, 1, 1)
    corners = ((0.0, 0.0), (8.0, 0.0), (8.0, 8.0), (0.0, 8.0))
    edges = ((corners[1], corners[2]), (corners[2], corners[3]),
             (corners[3], corners[4]), (corners[4], corners[1]))
    for ((ax, ay), (bx, by)) in edges
        eidx = _plan_edge(skel, ax, ay, 0.0, bx, by)
        filter!(!=(eidx), skel.groups_edges[:beams])
        walls = get!(skel.groups_edges, :walls, Int[])
        eidx in walls || push!(walls, eidx)
    end
    return skel
end

function _wall_params(; wall_thickness = 0.15u"m",
                      jump_wall_thickness = false,
                      wall_thickness_grouping = :all)
    DesignParameters(
        name = "wall_thickness_provenance",
        floor = FlatPlateOptions(method = FEA(design_approach = :strip)),
        materials = MaterialOptions(concrete = RC_4000_60.concrete, rebar = Rebar_60),
        columns = ConcreteColumnOptions(material = RC_4000_60.concrete,
                                        rebar_material = Rebar_60),
        wall_thickness = wall_thickness,
        jump_wall_thickness = jump_wall_thickness,
        wall_thickness_grouping = wall_thickness_grouping,
        foundation_options = FoundationParameters(
            soil = medium_sand,
            options = FoundationOptions(strategy = :all_spread),
        ),
        skip_visualization = true,
    )
end

function _thicknesses(design)
    [w.thickness for w in design.structure.walls]
end

function _footing_plans(design)
    [(f.foundation_type, f.result.B, f.result.L_ftg, f.result.D)
     for f in design.structure.foundations]
end

function _plans_match(a, b)
    length(a) == length(b) || return false
    for (x, y) in zip(a, b)
        x[1] == y[1] || return false
        for i in 2:4
            x[i] ≈ y[i] || return false
        end
    end
    return true
end

@testset "wall thickness edits rerun walls and foundations" begin
    params = _wall_params()
    session = DesignSession(BuildingStructure(_wall_cell_skeleton()), params)
    base_t = _thicknesses(base_design(session))
    @test length(base_t) == 4
    @test any(f.foundation_type == :mat for f in base_design(session).structure.foundations)

    # The starting thickness is meshed at prepare. An incremental edit would
    # keep the old walls, so the session refuses it.
    @test requires_new_engine(session; wall_thickness = 0.40u"m")
    @test_throws ArgumentError redesign(session; wall_thickness = 0.40u"m")

    # Each override is measured from the session base, not from the previous edit.
    # These walls pass by raising reinforcement, so the jump does not grow them.
    # A jump that does change a thickness has to recompute the foundations.
    edits = (
        (jump_wall_thickness = true,),
        (wall_thickness_grouping = :story,),
    )
    for edit in edits
        frontier = dirty_frontier(session; edit...)
        @test frontier[1] == _SS.NODE_ORDINARY_WALLS
        @test _SS.NODE_FOUNDATIONS in frontier
        @test !any(_SS.is_slab_node_key, frontier)

        inc = redesign(session; edit...)
        recomputed = last_recomputed(session)
        @test _SS.NODE_ORDINARY_WALLS in recomputed
        varied = with(params; edit...)
        ref = design_building(BuildingStructure(_wall_cell_skeleton()), varied)
        @test _thicknesses(inc) ≈ _thicknesses(ref)
        @test _plans_match(_footing_plans(inc), _footing_plans(ref))
        if any(t -> t ≉ base_t[1], _thicknesses(ref))
            @test _SS.NODE_FOUNDATIONS in recomputed
        end
    end

    # Foundations rerun when this hash changes. The fingerprint is the
    # thickness list, so one wall moving has to change it.
    node = _SS.get_node(session.engine.graph, _SS.NODE_ORDINARY_WALLS)
    struc = session.engine.struc
    before = output_hash(node, struc)
    wall = struc.walls[1]
    saved = wall.thickness
    wall.thickness = saved + 0.05u"m"
    after = output_hash(node, struc)
    wall.thickness = saved
    @test before != after
end
