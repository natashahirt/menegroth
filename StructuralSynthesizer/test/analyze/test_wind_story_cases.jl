# Chapter 27 wind story forces on the rigid-diaphragm masters.
#
# The 1×1 office is the same fixture the ELF story-force test uses. The
# assertions are that each level's force matches the Chapter 27 resultant
# for that story's own height and qz, and that the master is the node that
# was loaded.

using Test
using Unitful
using Meshes
using Asap
using StructuralSynthesizer
using StructuralSizer

const _WIND_VAULT = VaultOptions(rise=1.0u"m", thickness=0.05u"m")

function _wind_xy(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function _wind_horizontal(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    c1 = Meshes.coords(skel.vertices[v1])
    c2 = Meshes.coords(skel.vertices[v2])
    return abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

function _wind_plan_length(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    x1, y1 = _wind_xy(skel, v1)
    x2, y2 = _wind_xy(skel, v2)
    return hypot(x2 - x1, y2 - y1)
end

"""1×1 office, two stories, one wall on story 0, rigid diaphragm."""
function _wind_building()
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 2)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    edges = [e for e in skel.stories[0].edges if e in beams && _wind_horizontal(skel, e)]
    @assert !isempty(edges)
    eidx = edges[argmax(_wind_plan_length.(Ref(skel), edges))]
    filter!(!=(eidx), skel.groups_edges[:beams])
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)

    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=_WIND_VAULT,
        wall_thickness=0.3u"m")
    params = DesignParameters(materials=MaterialOptions(concrete=NWC_5000))
    to_asap!(struc; params=params, diaphragms=:rigid)
    return struc
end

function _wind_pick(result, kind, direction; sign_1=0, sign_2=0)
    hits = [c for c in result.cases
            if c.kind === kind && c.direction == direction &&
               c.sign_1 == sign_1 && c.sign_2 == sign_2]
    @assert length(hits) == 1
    return only(hits)
end

function _wind_pts(outline)
    pts = NTuple{2, Float64}[]
    for loop in outline
        append!(pts, loop)
    end
    return pts
end

@testset "Chapter 27 wind story cases" begin
    bare = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1))
    @test_throws ArgumentError wind_story_analysis(bare;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.0], qh=1.0, Kd=1.0, G=0.85, GCpi=0.18)
    @test_throws ArgumentError wind_story_analysis(bare;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.0], qh=1.0, Kd=1.0, G=0.85, GCpi=0.18, flexible=true)
    @test_throws ArgumentError wind_story_analysis(bare;
        directions=((1.0, 0.0),),
        qz=[1.0], qh=1.0, Kd=1.0, G=0.85, GCpi=0.0)
    @test_throws ArgumentError wind_story_analysis(bare;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.0], qh=1.0, Kd=1.0, G=0.85, GCpi=0.0, roof=:dome)
    @test_throws ArgumentError wind_story_analysis(bare;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.0], qh=1.0, Kd=1.0, G=0.85, GCpi=0.0, roof=:gable)

    struc = _wind_building()
    @test !isempty(struc.asap_rigid_links)
    @test struc.asap_model.processed
    @test_throws ArgumentError wind_story_analysis(struc;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.0], qh=1.5, Kd=1.0, G=0.85, GCpi=0.18)

    qz = [1.0, 2.0]
    qh = 1.5
    Kd = 1.0
    G = 0.85
    GCpi = 0.18

    # A Figure 27.3-1 sloped roof must not become wall-only Cases 1–4.
    # §27.3.1 applies wall and roof pressures together (corpus: asce-7-22,
    # PDF pages 342–345).
    for sloped in (:gable, :hip, :monoslope, :mansard)
        err = try
            wind_story_analysis(struc;
                directions=((1.0, 0.0), (0.0, 1.0)),
                qz=qz, qh=qh, Kd=Kd, G=G, GCpi=GCpi,
                roof=sloped)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        if err isa ArgumentError
            @test occursin(
                "Figure 27.3-1 roof pressures are not applied in this slice",
                err.msg)
            @test occursin(
                "sloped roof cannot be returned as a wall-only case",
                err.msg)
        end
    end

    # Figure 27.3-8 loads each principal axis. A repeated, opposite, or
    # non-perpendicular pair is not two principal axes.
    for pair in (((1.0, 0.0), (1.0, 0.0)),
                 ((1.0, 0.0), (-1.0, 0.0)),
                 ((1.0, 0.0), (1.0, 1.0)))
        @test_throws ArgumentError wind_story_analysis(struc;
            directions=pair, qz=qz, qh=qh, Kd=Kd, G=G, GCpi=GCpi)
    end
    @test_throws MethodError wind_story_analysis(struc;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=qz, qh=qh, Kd=Kd, G=G, GCpi=GCpi, roof_projected_area_m2=10.0)

    result = wind_story_analysis(struc;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=qz, qh=qh, Kd=Kd, G=G, GCpi=GCpi)

    @test length(result.levels) == 2
    @test length(result.cases) == 13
    @test length(result.centroids) == length(result.levels)
    @test length(result.displacements) == length(result.cases)
    @test all(u -> length(u) == struc.asap_model.nDOFs, result.displacements)
    @test issorted(result.levels; by=lv -> lv.elevation_m)
    zmin = minimum(ustrip(u"m", story.elevation) for (_, story) in struc.skeleton.stories)
    @test all(lv -> lv.elevation_m > zmin + 1e-6, result.levels)
    @test all(lv -> lv.story_height_m ≈ 4.0, result.levels)
    @test all(lv -> any(link -> link.nodeA === lv.master, struc.asap_rigid_links), result.levels)

    dx = (1.0, 0.0)
    case1 = _wind_pick(result, :case1, dx)
    @test case1.Fx_kN[2] > case1.Fx_kN[1]
    @test case1.ux_m[end] > 0
    for (i, lv) in enumerate(result.levels)
        pure = wind_wall_resultant(lv.outline, dx; qz=qz[i], qh=qh, Kd=Kd, G=G,
            GCpi=GCpi, height=lv.story_height_m)
        @test case1.Fx_kN[i] ≈ pure.Fx atol=1e-8
        @test case1.Fy_kN[i] ≈ pure.Fy atol=1e-8
        @test pure.Fx > 0
        @test abs(pure.Fy) < 1e-8
    end

    plus = _wind_pick(result, :case2, dx; sign_1=1)
    minus = _wind_pick(result, :case2, dx; sign_1=-1)
    for (i, lv) in enumerate(result.levels)
        B = projected_plan_width(_wind_pts(lv.outline), dx)
        e = wind_rigid_eccentricity(B)
        along = case1.Fx_kN[i]
        @test plus.Fx_kN[i] ≈ 0.75 * case1.Fx_kN[i] atol=1e-8
        @test plus.Mz_kN_m[i] ≈ 0.75 * case1.Mz_kN_m[i] + 0.75 * along * e atol=1e-6
        @test minus.Mz_kN_m[i] ≈ 0.75 * case1.Mz_kN_m[i] - 0.75 * along * e atol=1e-6
    end
    @test plus.Mz_kN_m[1] != minus.Mz_kN_m[1]

    dy = (0.0, 1.0)
    ycase = _wind_pick(result, :case1, dy)
    c3 = _wind_pick(result, :case3, dx)
    for i in eachindex(result.levels)
        @test c3.Fx_kN[i] ≈ 0.75 * case1.Fx_kN[i] + 0.75 * ycase.Fx_kN[i] atol=1e-8
        @test c3.Fy_kN[i] ≈ 0.75 * case1.Fy_kN[i] + 0.75 * ycase.Fy_kN[i] atol=1e-8
        @test c3.Mz_kN_m[i] ≈ 0.75 * case1.Mz_kN_m[i] + 0.75 * ycase.Mz_kN_m[i] atol=1e-6
    end
    @test count(c -> c.kind === :case4, result.cases) == 4

    wind_factored = factored_wind_cases(result, strength_1_2D_1_0W)
    @test length(wind_factored) == length(result.cases)
    @test wind_factored[1].Fx_kN ≈ result.cases[1].Fx_kN
    @test isempty(factored_wind_cases(result, strength_1_2D_1_0E))
    reported = wind_story_drift_report(result)
    @test length(reported) == length(result.cases) * length(result.levels)
    @test reported[1].drift_x_m ≈ result.cases[1].ux_m[1]
    @test any(r -> r.drift_x_m != 0.0 || r.drift_y_m != 0.0, reported)

    mini = _wind_pick(result, :minimum, dx)
    for (i, lv) in enumerate(result.levels)
        B = projected_plan_width(_wind_pts(lv.outline), dx)
        F = wind_minimum_horizontal_force(B * lv.story_height_m, 0.0; system=:kN_m2)
        @test mini.Fx_kN[i] ≈ F atol=1e-8
        @test mini.Fy_kN[i] ≈ 0.0 atol=1e-8
    end

    # A repeated principal axis is not an extra direction. The opposite sense
    # is, because Figure 27.3-8 does not add it. A 45° wind is Case 1 and
    # Case 2 of its own, plus its minimum: four cases on top of the 13.
    kw = (; directions=((1.0, 0.0), (0.0, 1.0)), qz, qh, Kd, G, GCpi)
    @test_throws ArgumentError wind_story_analysis(struc; kw..., extra_directions=((2.0, 0.0),))
    opposite = wind_story_analysis(struc; kw..., extra_directions=((-1.0, 0.0),))
    @test length(opposite.cases) == 17
    @test _wind_pick(opposite, :case1, (-1.0, 0.0)).Fx_kN[1] < 0
    diag = wind_unit_direction((1.0, 1.0))
    added = wind_story_analysis(struc; kw..., extra_directions=((1.0, 1.0),))
    @test length(added.cases) == 17
    # The stored direction is re-normalized, so it is compared by value.
    diag_cases = [c for c in added.cases if c.kind === :case1 &&
                  c.direction[1] ≈ diag[1] && c.direction[2] ≈ diag[2]]
    @test length(diag_cases) == 1
    @test diag_cases[1].Fx_kN[1] > 0 && diag_cases[1].Fy_kN[1] > 0
    diag_min = [c for c in added.cases if c.kind === :minimum &&
                c.direction[1] ≈ diag[1] && c.direction[2] ≈ diag[2]]
    @test length(diag_min) == 1 && length(diag_min[1].Fx_kN) == 2
    # A skewed pair is the caller's override. Cases 3 and 4 are still built.
    skewed = wind_story_analysis(struc;
        directions=((1.0, 0.0), (1.0, 1.0)),
        qz=qz, qh=qh, Kd=Kd, G=G, GCpi=GCpi, perpendicular=false)
    @test length(skewed.cases) == 13
    @test count(c -> c.kind === :case3, skewed.cases) == 1
end
