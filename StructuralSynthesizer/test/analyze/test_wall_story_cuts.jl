# Two-story building cut, with the rigid diaphragm on.
#
# One wall stacks through both stories. The opposite wall stops at the first
# story. Story forces are applied at the diaphragm masters. The base cut
# carries both. The upper cut carries the roof force only, and the stopped
# pier is not part of that cut.

using Test
using Unitful
using Meshes
using Asap
using StructuralSynthesizer

const _STORY_VAULT = VaultOptions(rise=1.0u"m", thickness=0.05u"m")
const _P_FLOOR = 1.0e5   # N, at the second-floor master
const _P_ROOF = 2.5e5    # N, at the roof master

function _xy(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function _is_horizontal(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    c1 = Meshes.coords(skel.vertices[v1])
    c2 = Meshes.coords(skel.vertices[v2])
    return abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

function _plan_length(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    x1, y1 = _xy(skel, v1)
    x2, y2 = _xy(skel, v2)
    return hypot(x2 - x1, y2 - y1)
end

function _plan_key(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    x1, y1 = _xy(skel, v1)
    x2, y2 = _xy(skel, v2)
    a = (round(Int, x1 * 1000), round(Int, y1 * 1000))
    b = (round(Int, x2 * 1000), round(Int, y2 * 1000))
    return a <= b ? (a, b) : (b, a)
end

function _y_of(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    return (_xy(skel, v1)[2] + _xy(skel, v2)[2]) / 2
end

function _horizontal_beams(skel, story)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    return [e for e in skel.stories[story].edges if e in beams && _is_horizontal(skel, e)]
end

function _claim_as_wall!(skel, eidx)
    filter!(!=(eidx), skel.groups_edges[:beams])
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)
    return eidx
end

"""
Two-story 1×1 office.

The long wall at the smaller y stacks through both stories. The long wall at
the larger y is claimed on story 0 only, so the upper cut must not inherit it.
The two lines do not share a corner.
"""
function _two_story_walls()
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 2)
    lower = _horizontal_beams(skel, 0)
    upper = _horizontal_beams(skel, 1)
    @assert !isempty(lower) && !isempty(upper)
    long = [e for e in lower if _plan_length(skel, e) > 8.0]
    @assert length(long) >= 2 "fixture: expected two opposite long edges"
    sort!(long; by=e -> _y_of(skel, e))
    continue_0 = long[1]
    stop_0 = long[end]
    @assert _y_of(skel, stop_0) > _y_of(skel, continue_0) + 1.0
    key = _plan_key(skel, continue_0)
    slot = findfirst(e -> _plan_key(skel, e) == key, upper)
    @assert slot !== nothing "fixture: stacked edge is missing on story 1"
    continue_1 = upper[slot]
    _claim_as_wall!(skel, continue_0)
    _claim_as_wall!(skel, stop_0)
    _claim_as_wall!(skel, continue_1)
    return skel
end

"""Rigid-diaphragm master at each story elevation, in millimetres."""
function _masters(struc)
    found = Dict{Int, Asap.Node}()
    for link in struc.asap_rigid_links
        zk = round(Int, ustrip(u"m", link.nodeA.position[3]) * 1000)
        found[zk] = link.nodeA
    end
    return found
end

function _pier_bottom(pier)
    z = Inf
    for sh in pier.shells, nd in sh.nodes
        z = min(z, ustrip(u"m", nd.position[3]))
    end
    return z
end

@testset "two-story rigid-diaphragm cuts" begin
    skel = _two_story_walls()
    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=_STORY_VAULT,
        wall_thickness=0.3u"m")
    params = DesignParameters(materials=MaterialOptions(concrete=NWC_5000))
    model = to_asap!(struc; params=params, diaphragms=:rigid)

    @test length(struc.walls) == 3
    stacked = only(w for w in struc.walls if w.story == 0 && w.wall_above !== nothing)
    stopped = only(w for w in struc.walls if w.story == 0 && w.wall_above === nothing)
    upper = stacked.wall_above
    @test upper.story == 1
    @test upper.wall_above === nothing
    @test abs(stacked.y1 - stopped.y1) > 1.0

    mesh = struc.wall_mesh
    @test length(mesh.piers) == 3
    @test all(length(p.shells) == 2 * WALL_MESH_DIV * WALL_MESH_ROWS for p in mesh.piers)
    @test all(!a.joined for a in mesh.assemblies)
    @test count(a -> a.story == 0, mesh.assemblies) == 2
    @test count(a -> a.story == 1, mesh.assemblies) == 1
    owned = [objectid(s) for p in mesh.piers for s in p.shells]
    @test length(owned) == length(unique(owned))
    tagged = [objectid(s) for s in model.shell_elements if s.id === :wall]
    @test sort(owned) == sort(tagged)

    z_base = ustrip(u"m", skel.stories[0].elevation)
    z_floor = ustrip(u"m", skel.stories[1].elevation)
    z_roof = z_floor + ustrip(u"m", upper.base.L)
    @test z_floor > z_base + 1.0
    @test z_roof > z_floor + 1.0

    # The stopped pier stands on the base. Only the upper pier stands on the floor.
    bottoms = [_pier_bottom(p) for p in mesh.piers]
    @test count(z -> isapprox(z, z_base; atol=1e-4), bottoms) == 2
    on_floor = findall(z -> isapprox(z, z_floor; atol=1e-4), bottoms)
    @test length(on_floor) == 1
    @test mesh.piers[only(on_floor)].wall_index == findfirst(w -> w === upper, struc.walls)

    @test !isempty(struc.asap_rigid_links)
    masters = _masters(struc)
    floor_master = masters[round(Int, z_floor * 1000)]
    roof_master = masters[round(Int, z_roof * 1000)]
    @test ustrip(u"m", floor_master.position[3]) ≈ z_floor atol=1e-6
    @test ustrip(u"m", roof_master.position[3]) ≈ z_roof atol=1e-6

    basic = solve_gravity_basic_cases(struc; params=params, roof=:Lr)
    @test basic.symbols == [:D, :L, :Lr]
    @test_throws ArgumentError solve_gravity_basic_cases(struc; params=params, roof=:W)
    u_sum = basic.u[1] .+ basic.u[2] .+ basic.u[3]
    u_all = only(Asap.solve(model, [vcat(basic.loads...)], struc.asap_rigid_links))
    @test u_sum ≈ u_all atol=1e-6

    roof_faces = Set(get(skel.groups_faces, :roof, Int[]))
    # Grade has no tributary. The basic cases carry the same cells the factored path does.
    on_frame(c) = c.floor_type != :grade && c.floor_type != :unknown
    cell_force(pred, pressure) = sum(c -> pred(c) ?
        -ustrip(u"N", pressure(c) * c.area) : 0.0, struc.cells)
    Fz_L = StructuralSynthesizer._loads_above(basic.loads[2], (0.0, 0.0, -1.0), -1.0)[3]
    Fz_R = StructuralSynthesizer._loads_above(basic.loads[3], (0.0, 0.0, -1.0), -1.0)[3]
    @test Fz_L ≈ cell_force(c -> on_frame(c) && c.face_idx ∉ roof_faces, c -> c.live_load) rtol=1e-6 atol=1.0
    @test Fz_R ≈ cell_force(c -> on_frame(c) && c.face_idx ∈ roof_faces, c -> c.live_load) rtol=1e-6 atol=1.0
    @test abs(Fz_R) > 1.0
    base_g = check_story_cut_equilibrium(model, basic.u[1], mesh, basic.loads[1], z_base;
                                        fixed_end_from_loads=true)
    @test base_g.passed
    base_g.passed || @error "dead base cut" residual=base_g.residual cut=base_g.cut applied=base_g.applied

    pier_i = findfirst(w -> w === stacked, struc.walls)
    pier = mesh.piers[findfirst(p -> p.wall_index == pier_i, mesh.piers)]
    gact = pier_gravity_actions(struc, basic, pier)
    @test gact.D.N > 1.0
    dead_combo = combine_wall_action(strength_1_4D, gact)
    @test dead_combo.N ≈ 1.4 * gact.D.N rtol=1e-9 atol=1e-6
    @test dead_combo.V ≈ 1.4 * gact.D.V rtol=1e-9 atol=1e-6
    @test dead_combo.M ≈ 1.4 * gact.D.M rtol=1e-9 atol=1e-6
    asm = mesh.assemblies[findfirst(a -> pier_i in a.wall_indices, mesh.assemblies)]
    lone = assembly_wall_action(struc, asm, basic.u[1];
                                loads=basic.loads[1], fixed_end_from_loads=true)
    @test lone.N ≈ gact.D.N rtol=1e-9 atol=1e-6
    @test_throws ArgumentError assembly_wall_action(
        struc, WallAssembly(0, [1, 2], true), basic.u[1])

    loads = Asap.AbstractLoad[
        Asap.NodeForce(floor_master, [_P_FLOOR, 0.0, 0.0] .* u"N"),
        Asap.NodeForce(roof_master, [_P_ROOF, 0.0, 0.0] .* u"N"),
    ]
    model.loads = loads
    model._elemental_loads = nothing
    Asap.process!(model)
    Asap.solve!(model, struc.asap_rigid_links; reprocess=false)

    base = check_story_cut_equilibrium(model, model.u, mesh, loads, z_base)
    floor = check_story_cut_equilibrium(model, model.u, mesh, loads, z_floor)
    @test base.passed
    @test floor.passed
    # A load at the floor is carried by the story below. The upper cut sees the roof only.
    @test base.applied[1] ≈ _P_FLOOR + _P_ROOF atol=1.0
    @test base.cut[1] ≈ _P_FLOOR + _P_ROOF atol=1.0
    @test floor.applied[1] ≈ _P_ROOF atol=1.0
    @test floor.cut[1] ≈ _P_ROOF atol=1.0

    qe = pier_wall_action(stacked, pier, model.u)
    seismic = combine_wall_action(strength_1_2D_1_0E, gact; qe=qe, rho=1.3, SDS=1.0)
    Ev = vertical_seismic_load_effect(1.0, gact.D.N)
    @test seismic.N ≈ 1.2 * gact.D.N + gact.L.N + 1.3 * qe.N + Ev rtol=1e-9 atol=1e-4
    @test seismic.V ≈ 1.2 * gact.D.V + gact.L.V + 1.3 * qe.V rtol=1e-9 atol=1e-4
    @test seismic.M ≈ 1.2 * gact.D.M + gact.L.M + 1.3 * qe.M rtol=1e-9 atol=1e-4

    dead_checks = check_ordinary_wall(stacked, [dead_combo];
                                      wall_index=pier_i, material=RC_4000_60,
                                      case=:D, boundary=:restrained)
    @test length(dead_checks) == 5
    @test all(r.wall_index == pier_i && r.story == stacked.story for r in dead_checks)
    @test all(r.case == :D && r.combination == :strength_1_4D && r.alternative == :only
              for r in dead_checks)
    @test abs(stacked.x2 - stacked.x1) > abs(stacked.y2 - stacked.y1)
    @test all(r.direction == :X for r in dead_checks)
    shear = only(filter(r -> r.check == "in-plane shear", dead_checks))
    @test shear.demand ≈ abs(dead_combo.V) atol=1e-6
    @test shear.capacity > 0
    @test shear.clause == "ACI 318-19 11.5.4.3"
    @test !any(occursin("out-of-plane", r.check) for r in dead_checks)
    @test_throws ArgumentError check_ordinary_wall(
        stacked, [dead_combo]; wall_index=pier_i, material=RC_4000_60,
        case=:D, boundary=:restrained, assembly=WallAssembly(0, [1, 2], true))
end
