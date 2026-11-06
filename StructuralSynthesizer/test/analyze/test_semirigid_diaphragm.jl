# HAND CHECK — semirigid membrane floors.
#
# Not a published example. The checks are the clause's own statements:
# story force and accidental torsion land on the floor nodes and sum to the
# applied force and moment (ASCE 7-22 §12.8.4, §12.8.4.2, C12.8.4.2;
# corpus: asce-7-22, PDF pages 187 and 727), and the center-of-mass
# displacement is the rigid motion fitted to the seismic-system walls
# (C12.8.6, PDF page 730).

using Test
using Unitful
using Meshes
using StructuralSynthesizer
using StructuralSizer

"""Plan coordinates of a skeleton vertex."""
function _semi_xyz(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z))
end

"""
One-bay by two-bay office with perimeter walls.

10 × 6 m plan. `diaphragms=:semirigid` meshes each slab as a membrane.
"""
function semi_office(; nstory=1, params=nothing, analyze::Bool=true)
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 2, nstory)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    walls = get!(skel.groups_edges, :walls, Int[])
    near(a, b) = abs(a - b) <= 1e-6
    for story in 0:(nstory - 1)
        for e in skel.stories[story].edges
            e in beams || continue
            v1, v2 = skel.edge_indices[e]
            x1, y1, z1 = _semi_xyz(skel, v1)
            x2, y2, z2 = _semi_xyz(skel, v2)
            near(z1, z2) || continue
            edge = (near(y1, 0) && near(y2, 0)) || (near(y1, 6) && near(y2, 6)) ||
                   (near(x1, 0) && near(x2, 0)) || (near(x1, 10) && near(x2, 10))
            edge || continue
            filter!(!=(e), skel.groups_edges[:beams])
            delete!(beams, e)
            e in walls || push!(walls, e)
        end
    end
    struc = BuildingStructure(skel)
    initialize!(struc; wall_thickness=0.3u"m", material=NWC_4000)
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    analyze || return struc
    p = params === nothing ? DesignParameters(diaphragm_mode=:semirigid) : params
    to_asap!(struc; params=p)
    return struc
end

const SEMI_WALLS = LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit())

"""Resultant and moment about `c` of nodal plan forces."""
function _force_moment(loads, c)
    fx = fy = m = 0.0
    for load in loads
        load isa Asap.NodeForce || continue
        x, y = StructuralSynthesizer._xy(load.node)
        dx, dy = ustrip(u"kN", load.value[1]), ustrip(u"kN", load.value[2])
        fx += dx
        fy += dy
        m += (x - c[1]) * dy - (y - c[2]) * dx
    end
    return fx, fy, m
end

@testset "semirigid membrane diaphragm" begin
    @testset "the floor is a membrane meshed through the wall tops" begin
        struc = semi_office()
        layout = struc.diaphragm_layout
        @test layout isa SemirigidDiaphragmLayout
        @test length(layout.floors) == 1
        @test isempty(struc.asap_rigid_links)
        floor = only(layout.floors)
        @test floor.elevation_m ≈ 4.0
        @test all(sh -> sh.membrane_only && sh.id === :semirigid_diaphragm, floor.shells)
        # Twelve elements across the 6 m width.
        @test floor.mesh_size_m ≈ 0.5
        # Perimeter walls: the long span is 10 m between the short sides, over a 6 m depth.
        span, depth, type5 = StructuralSynthesizer.governing_diaphragm_span_depth(struc)
        @test span ≈ 10.0 atol=1e-6
        @test depth ≈ 6.0 atol=1e-6
        @test type5 == false
        slab_area = sum(ustrip(u"m^2", c.area) for c in struc.cells if c.floor_type != :grade)
        @test sum(sh.area for sh in floor.shells) ≈ slab_area rtol=1e-6
        # Every wall-top node is a node of a floor triangle.
        floor_nodes = Set(objectid(nd) for nd in floor.nodes)
        for pier in struc.wall_mesh.piers, sh in pier.shells, nd in sh.nodes
            abs(ustrip(u"m", nd.position[3]) - floor.elevation_m) > 1e-3 && continue
            @test objectid(nd) in floor_nodes
        end
        # A node the mesh creates does not translate out of plane.
        for nd in floor.nodes
            nd.dof[1] && nd.dof[2] || continue
            any(sh -> sh.id === :wall && nd in sh.nodes, struc.asap_model.shell_elements) && continue
            any(el -> nd === el.nodeStart || nd === el.nodeEnd, struc.asap_model.frame_elements) && continue
            @test nd.dof == [true, true, false, false, false, false]
        end
    end

    @testset "stiffness factor scales the slab modulus and nothing else" begin
        struc = semi_office()
        layout = struc.diaphragm_layout
        base = only(values(layout.base_E_Pa))
        @test all(sh -> sh.E ≈ base, semirigid_shells(layout))
        set_semirigid_stiffness!(layout, 0.35)
        @test layout.stiffness_factor ≈ 0.35
        @test all(sh -> sh.E ≈ 0.35 * base, semirigid_shells(layout))
        @test_throws ArgumentError set_semirigid_stiffness!(layout, 0.0)
    end

    @testset "HAND CHECK seismic force and torsion sum on the floor nodes" begin
        struc = semi_office()
        semirigid_sfrs!(struc, SEMI_WALLS)
        levels = StructuralSynthesizer._elf_levels(struc)
        lv = only(levels)
        loads = StructuralSynthesizer.diaphragm_story_loads(struc, levels,
            [40.0], [10.0], [25.0]; force_id=:elf_story, moment_id=:elf_torsion)
        @test all(l -> l isa Asap.NodeForce, loads)
        floor_nodes = Set(objectid(nd) for nd in only(struc.diaphragm_layout.floors).nodes)
        @test all(l -> objectid(l.node) in floor_nodes, loads)
        fx, fy, m = _force_moment(loads, lv.center_of_mass)
        @test fx ≈ 40.0 atol=1e-6
        @test fy ≈ 10.0 atol=1e-6
        # C12.8.4.2: the nodal forces reproduce the accidental torsional moment.
        @test m ≈ 25.0 atol=1e-6
        # The weight on the nodes is the level weight, at the level's center of mass.
        floor = only(struc.diaphragm_layout.floors)
        w = StructuralSynthesizer._semirigid_node_weights(struc, floor, lv)
        @test sum(w) ≈ lv.weight_kN rtol=1e-9
        xc = sum(w[k] * StructuralSynthesizer._xy(nd)[1] for (k, nd) in enumerate(floor.nodes)) / sum(w)
        yc = sum(w[k] * StructuralSynthesizer._xy(nd)[2] for (k, nd) in enumerate(floor.nodes)) / sum(w)
        @test (xc, yc) ≈ lv.center_of_mass rtol=1e-9
    end

    @testset "HAND CHECK wind force sits on the exterior edge about the centroid" begin
        struc = semi_office()
        levels = StructuralSynthesizer._wind_levels(struc)
        lv = only(levels)
        centroid = (5.0, 3.0)
        loads = StructuralSynthesizer.diaphragm_story_loads(struc, levels,
            [30.0], [12.0], [8.0]; force_id=:wind_story, moment_id=:wind_torsion,
            centroids=[centroid])
        fx, fy, m = _force_moment(loads, centroid)
        @test fx ≈ 30.0 atol=1e-6
        @test fy ≈ 12.0 atol=1e-6
        @test m ≈ 8.0 atol=1e-6
        # Only the exterior boundary carries wind. An interior node is unloaded.
        floor = only(struc.diaphragm_layout.floors)
        tx, ty = StructuralSynthesizer._exterior_edge_widths(floor)
        loaded = Set(objectid(l.node) for l in loads)
        for (k, nd) in enumerate(floor.nodes)
            (tx[k] == 0 && ty[k] == 0) || continue
            @test !(objectid(nd) in loaded)
        end
        # Both pairs of sides: projected widths 6 m and 10 m, counted once per
        # windward edge and once per leeward edge.
        @test sum(tx) ≈ 12.0 atol=1e-6
        @test sum(ty) ≈ 20.0 atol=1e-6
    end

    @testset "HAND CHECK center-of-mass drift is the wall-top rigid motion" begin
        struc = semi_office(; nstory=2)
        semirigid_sfrs!(struc, SEMI_WALLS)
        layout = struc.diaphragm_layout
        elf = elf_story_analysis(struc; method=:sds, SDS=0.05, S1=0.02, R=5.0, Ie=1.0,
            T=0.4, Cd=4.5, β=1.0, SD1=0.02, TL=8.0)
        @test length(elf.levels) == 2
        for (case, u) in zip(elf.cases, elf.displacements)
            case.purpose === :drift || continue
            for (i, lv) in enumerate(elf.levels)
                δ = StructuralSynthesizer._semirigid_disp_at(u, layout, lv.elevation_m,
                    case.direction, lv.center_of_mass)
                @test case.elastic_m[i] ≈ δ rtol=1e-9
                @test case.θ[i] !== nothing && case.θ[i] >= 0
                # §12.3.2.1 permits Δmax and Δavg on a semirigid floor.
                @test case.Ax[i] !== nothing
            end
            @test case.elastic_drift_m[1] ≈ case.elastic_m[1]
            @test case.elastic_drift_m[2] ≈ case.elastic_m[2] - case.elastic_m[1]
        end
        # A rigid translation of the wall tops is read back unchanged, and a
        # rigid rotation about the center of mass reads as zero there.
        floor = layout.floors[1]
        dn = only(d for d in layout.drift_nodes if d.elevation_m == floor.elevation_m)
        n = length(elf.displacements[1])
        u = zeros(n)
        for nd in dn.nodes
            u[nd.globalID[1]] = 0.02
        end
        p = (4.0, 2.5)
        @test StructuralSynthesizer._semirigid_disp_at(u, layout, floor.elevation_m, :x, p) ≈ 0.02
        fill!(u, 0.0)
        for nd in dn.nodes
            x, y = StructuralSynthesizer._xy(nd)
            u[nd.globalID[2]] = 0.01 * (x - p[1])
        end
        @test abs(StructuralSynthesizer._semirigid_disp_at(u, layout, floor.elevation_m, :y, p)) < 1e-12
    end

    @testset "the ordinary-wall stage checks a semirigid floor" begin
        lateral = DesignParameters(
            diaphragm_mode=:semirigid,
            lateral=SEMI_WALLS,
            wall_inputs=OrdinaryWallInputs(;
                directions=((1.0, 0.0), (0.0, 1.0)),
                qz=[1.0],
                qh=1.0,
                Kd=1.0,
                G=0.85,
                GCpi=0.18,
                roof=:Lr,
                method=:sds,
                SDS=0.05,
                S1=0.02,
                Ie=1.0,
                T=0.4,
                β=1.0,
                SD1=0.02,
                TL=8.0,
                rho=1.0,
                sdc=:B,
                risk_category=:II,
                drift_system=:other,
                boundary=:pinned,
                material=RC_4000_60,
                model_uses_cracked_section_stiffness=true,
                sustained_lateral_loads=false,
                sustained_lateral_divisor_applied=false,
                type1_horizontal_irregularity=false,
                type5_horizontal_irregularity=false,
                orthogonal_combination=false,
                orthogonal_12_5_4_conditions_absent=false,
                ax_applied_to_accidental_torsion=false,
                pdelta_included_in_member_forces=false,
            ),
            skip_visualization=true,
        )
        struc = semi_office(; params=lateral)
        result = design_ordinary_walls!(struc, lateral)
        @test result isa OrdinaryWallResult
        @test struc.diaphragm_layout isa SemirigidDiaphragmLayout
        @test struc.diaphragm_layout.plan_axis == SEMI_WALLS.plan_axis
        @test !isempty(result.drift)
        @test result.max_story_stability > 0
        @test !isempty(result.checks)
    end

    @testset "HAND CHECK :auto takes the stricter idealization" begin
        # Span/depth 10/6 is under both limits, and a concrete slab with no
        # irregularity is rigid for wind and for seismic.
        params = DesignParameters(diaphragm_mode=:auto,
            diaphragm_construction=:concrete_slab,
            diaphragm_irregularities=Int[])
        struc = semi_office(; params)
        @test !isempty(struc.asap_rigid_links)
        @test !(struc.diaphragm_layout isa SemirigidDiaphragmLayout)
        # A type 2 irregularity removes the seismic rigid permission, so the
        # floor is the membrane even though wind would still allow rigid.
        blocked = DesignParameters(diaphragm_mode=:auto,
            diaphragm_construction=:concrete_slab,
            diaphragm_irregularities=[2])
        membrane = semi_office(; params=blocked)
        @test isempty(membrane.asap_rigid_links)
        @test membrane.diaphragm_layout isa SemirigidDiaphragmLayout
        bare = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1))
        @test_throws ArgumentError to_asap!(bare; params=DesignParameters(diaphragm_mode=:auto))
    end

    @testset "HAND CHECK a skewed wall is Type 5" begin
        # Two colinear walls are one line, and one line has no span.
        aligned = semi_office(; analyze=false)
        west = [i for (i, w) in enumerate(aligned.walls)
                if abs(w.x1) <= 1e-9 && abs(w.x2) <= 1e-9]
        @test length(west) == 2
        @test_throws ArgumentError StructuralSynthesizer.governing_diaphragm_span_depth(
            aligned; walls=west)

        # One skewed wall, with nothing parallel to it, defines no span.
        one = semi_office(; analyze=false)
        south_i = only(i for (i, w) in enumerate(one.walls)
                       if abs(w.y1) <= 1e-9 && abs(w.y2) <= 1e-9)
        one.walls[south_i].y2 = 1.0
        @test_throws ArgumentError StructuralSynthesizer.governing_diaphragm_span_depth(
            one; walls=[south_i])
        # It is omitted from the axis-aligned lines. The short sides still
        # span 10 m over the 6 m depth, and the wall is Type 5.
        span, depth, type5 = StructuralSynthesizer.governing_diaphragm_span_depth(one)
        @test span ≈ 10.0 atol=1e-6
        @test depth ≈ 6.0 atol=1e-6
        @test type5
        # A wall left out of the measured set is not Type 5.
        others = [i for i in eachindex(one.walls) if i != south_i]
        _, _, held_out = StructuralSynthesizer.governing_diaphragm_span_depth(one; walls=others)
        @test held_out == false

        # Two walls along (3, 4), 5 m apart on the perpendicular.
        # Across (-0.8, 0.6): midpoint (3, 4) offsets 0 and midpoint (-1, 7) offsets 5.
        # The 10 × 6 m outline extends 10.8 m along (0.6, 0.8).
        pair = semi_office(; analyze=false)
        south_i = only(i for (i, w) in enumerate(pair.walls)
                       if abs(w.y1) <= 1e-9 && abs(w.y2) <= 1e-9)
        north_i = only(i for (i, w) in enumerate(pair.walls)
                       if abs(w.y1 - 6) <= 1e-9 && abs(w.y2 - 6) <= 1e-9)
        pair.walls[south_i].x1 = 0.0
        pair.walls[south_i].y1 = 0.0
        pair.walls[south_i].x2 = 6.0
        pair.walls[south_i].y2 = 8.0
        pair.walls[north_i].x1 = -4.0
        pair.walls[north_i].y1 = 3.0
        pair.walls[north_i].x2 = 2.0
        pair.walls[north_i].y2 = 11.0
        span, depth, type5 = StructuralSynthesizer.governing_diaphragm_span_depth(
            pair; walls=[south_i, north_i])
        @test type5
        @test span ≈ 5.0 atol=1e-9
        @test depth ≈ 10.8 atol=1e-9

        # Span/depth 10/6: wind permits a rigid concrete slab. Type 5 removes
        # the seismic permission, so the model is the membrane. The stated
        # list is left as the caller wrote it, including a type already named.
        irr = Int[]
        params = DesignParameters(diaphragm_mode=:auto,
            diaphragm_construction=:concrete_slab,
            diaphragm_irregularities=irr)
        @test resolve_auto_diaphragm(one, params) === :semirigid
        @test irr == Int[]
        stated = [2]
        @test resolve_auto_diaphragm(one, DesignParameters(diaphragm_mode=:auto,
            diaphragm_construction=:concrete_slab,
            diaphragm_irregularities=stated)) === :semirigid
        @test stated == [2]
        to_asap!(one; params)
        @test isempty(one.asap_rigid_links)
        @test one.diaphragm_layout isa SemirigidDiaphragmLayout
        floor = only(one.diaphragm_layout.floors)
        floor_nodes = Set(objectid(nd) for nd in floor.nodes)
        for pier in one.wall_mesh.piers, sh in pier.shells, nd in sh.nodes
            abs(ustrip(u"m", nd.position[3]) - floor.elevation_m) > 1e-3 && continue
            @test objectid(nd) in floor_nodes
        end
    end
end
