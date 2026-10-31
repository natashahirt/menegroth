# Ordinary-wall stage: one isolated pier from the unified model.
#
# The ELF and wind numbers below are fixture wiring so the stage can run.
# They are not a Table 12.2-1 lookup for an ordinary bearing wall. The stage
# passes them through and does not choose them.
#
# Wall-shell E is multiplied by 0.35 before the successful call, and the
# inputs state that the model uses cracked-section stiffness. The stage
# itself does not scale E.
#
# Three stories on a 12 m square, two bays each way. Four piers per story,
# two along X and two along Y, chosen so no two walls share an end. That
# building stays at θ ≤ 0.10, so the §12.8.7 factor is 1.
#
# The 0.10 < θ ≤ θmax fixture is a 10 m × 6 m plan: two X piers on the
# x = 0 to 5 m bays, and one Y pier at x = 10 m so the ends do not meet.
# At 0.35 of gross E that Y pier still leaves θ ≈ 0.0045. The fixture then
# multiplies the Y pier's E by another 0.001 so θ falls in the band. That
# 0.001 is a fixture knob, not an ACI cracked-section factor. Design story
# drifts are multiplied by 1/(1−θ). Member forces come from the story
# stiffness and are not multiplied again.
#
# The same 10 m × 6 m plan with walls only along X has no Y pier. With wall
# self-weight in Px, θ exceeds θmax and the analysis is refused.

using Test
using Unitful
using Meshes
using Asap
using StructuralSynthesizer
using StructuralSizer

const _STAGE_VAULT = VaultOptions(rise=1.0u"m", thickness=0.05u"m")

function _stage_inputs(; cracked::Bool=true, pdelta::Bool=false)
    return OrdinaryWallInputs(;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=[1.0, 1.5, 2.0],
        qh=2.0,
        Kd=1.0,
        G=0.85,
        GCpi=0.18,
        roof=:Lr,
        method=:sds,
        SDS=0.05,
        S1=0.02,
        R=8.0,
        Ie=1.0,
        T=0.4,
        Cd=4.0,
        β=1.0,
        SD1=0.02,
        TL=8.0,
        rho=1.0,
        sdc=:B,
        risk_category=:II,
        drift_system=:other,
        boundary=:pinned,
        material=RC_4000_60,
        model_uses_cracked_section_stiffness=cracked,
        sustained_lateral_loads=false,
        sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false,
        type5_horizontal_irregularity=false,
        orthogonal_combination_applied=false,
        orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false,
        pdelta_included_in_member_forces=pdelta,
    )
end

function _stage_xy(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function _stage_horizontal(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    c1 = Meshes.coords(skel.vertices[v1])
    c2 = Meshes.coords(skel.vertices[v2])
    return abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

function _stage_plan_length(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    x1, y1 = _stage_xy(skel, v1)
    x2, y2 = _stage_xy(skel, v2)
    return hypot(x2 - x1, y2 - y1)
end

"""True when `eidx` lies on the plan segment `(x1, y1)–(x2, y2)`."""
function _stage_same_plan(skel, eidx, x1, y1, x2, y2)
    v1, v2 = skel.edge_indices[eidx]
    ax, ay = _stage_xy(skel, v1)
    bx, by = _stage_xy(skel, v2)
    return (hypot(ax - x1, ay - y1) <= 1e-6 && hypot(bx - x2, by - y2) <= 1e-6) ||
           (hypot(ax - x2, ay - y2) <= 1e-6 && hypot(bx - x1, by - y1) <= 1e-6)
end

"""Move the story's copy of the ground-story wall line from `:beams` to `:walls`."""
function _stage_claim_stacked_wall!(skel, story, beams, x1, y1, x2, y2)
    edges = [e for e in skel.stories[story].edges
             if e in beams && _stage_horizontal(skel, e) &&
                _stage_same_plan(skel, e, x1, y1, x2, y2)]
    length(edges) == 1 || error(
        "ordinary-wall fixture: story $story has $(length(edges)) edges on the wall line")
    eidx = only(edges)
    filter!(!=(eidx), skel.groups_edges[:beams])
    delete!(beams, eidx)
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)
    return eidx
end

"""Midpoint of the coordinate across an edge, so parallel edges can be ordered."""
function _stage_across(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    x1, y1 = _stage_xy(skel, v1)
    x2, y2 = _stage_xy(skel, v2)
    return abs(y2 - y1) <= abs(x2 - x1) ? (y1 + y2) / 2 : (x1 + x2) / 2
end

"""Ground beam on the plan segment, still in `:beams`."""
function _stage_ground_edge(skel, beams, x1, y1, x2, y2)
    ground = [e for e in skel.stories[0].edges if e in beams && _stage_horizontal(skel, e)]
    hits = [e for e in ground if _stage_same_plan(skel, e, x1, y1, x2, y2)]
    length(hits) == 1 || error(
        "ordinary-wall fixture: $(length(hits)) ground edges on " *
        "($x1, $y1)–($x2, $y2)")
    return only(hits)
end

"""Claim `segments` as stacked walls on stories `0:2`. Ends must not meet."""
function _stage_claim_segments!(skel, beams, segments)
    for (x1, y1, x2, y2) in segments
        e0 = _stage_ground_edge(skel, beams, x1, y1, x2, y2)
        v1, v2 = skel.edge_indices[e0]
        ax, ay = _stage_xy(skel, v1)
        bx, by = _stage_xy(skel, v2)
        for story in 0:2
            _stage_claim_stacked_wall!(skel, story, beams, ax, ay, bx, by)
        end
    end
    return skel
end

# 12 m square, 6 m bays. These four segments share no endpoint, so each pier
# is its own assembly. Two run in X and two in Y.
const _STAGE_BOTH_AXES = (
    (0.0, 0.0, 6.0, 0.0),
    (6.0, 12.0, 12.0, 12.0),
    (12.0, 0.0, 12.0, 6.0),
    (0.0, 6.0, 0.0, 12.0),
)

"""Office with isolated piers. Defaults are the 12 m square, stiff in both axes."""
function _stage_office(; x=12.0u"m", y=12.0u"m", x_bays=2, y_bays=2,
                       segments=_STAGE_BOTH_AXES, thickness=0.3u"m")
    skel = gen_medium_office(x, y, 4.0u"m", x_bays, y_bays, 3)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    _stage_claim_segments!(skel, beams, segments)
    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=_STAGE_VAULT,
        wall_thickness=thickness)
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end

"""
10 m × 6 m, two X piers and one Y pier, ends not shared.

Used where 0.10 < θ ≤ θmax. After `_stage_crack_wall_shells!`, call
[`_stage_soften_y_piers!`](@ref) with `0.001`.
"""
function _stage_office_pdelta()
    return _stage_office(;
        x=10.0u"m", y=6.0u"m", x_bays=2, y_bays=1,
        segments=((0.0, 0.0, 5.0, 0.0),
                  (0.0, 6.0, 5.0, 6.0),
                  (10.0, 0.0, 10.0, 6.0)))
end

"""10×6 m, three stories, one wall line along X. Y has no wall, so θ exceeds θmax."""
function _stage_office_unstable()
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 2, 3)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    ground = [e for e in skel.stories[0].edges if e in beams && _stage_horizontal(skel, e)]
    @assert !isempty(ground)
    longest = maximum(_stage_plan_length(skel, e) for e in ground)
    long = [e for e in ground if _stage_plan_length(skel, e) >= longest - 1e-6]
    ordered = sort(long; by=e -> _stage_across(skel, e))
    length(ordered) >= 2 || error("ordinary-wall fixture: expected two long sides")
    e0 = first(ordered)
    v1, v2 = skel.edge_indices[e0]
    x1, y1 = _stage_xy(skel, v1)
    x2, y2 = _stage_xy(skel, v2)
    for story in 0:2
        _stage_claim_stacked_wall!(skel, story, beams, x1, y1, x2, y2)
    end
    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=_STAGE_VAULT,
        wall_thickness=0.3u"m")
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end

function _stage_wall_shells(struc)
    return [sh for sh in struc.asap_model.shell_elements
            if sh isa Asap.ShellTri3 && sh.id === :wall]
end

function _stage_crack_wall_shells!(struc)
    shells = _stage_wall_shells(struc)
    isempty(shells) && error("ordinary-wall fixture: no wall shells to reduce")
    for sh in shells
        sh.E *= 0.35
    end
    Asap.process!(struc.asap_model)
    return length(shells)
end

"""
Multiply E of piers whose plan line runs in Y by `extra`, then reprocess.

Fixture knob for the P-delta office. `0.001` after the 0.35 crack places θ
in (0.10, θmax]. It is not an ACI cracked-section factor.
"""
function _stage_soften_y_piers!(struc, extra)
    n = 0
    for pier in struc.wall_mesh.piers
        wall = struc.walls[pier.wall_index]
        abs(wall.y2 - wall.y1) > abs(wall.x2 - wall.x1) || continue
        for sh in pier.shells
            sh.E *= extra
            n += 1
        end
    end
    n > 0 || error("ordinary-wall fixture: no Y pier to soften")
    Asap.process!(struc.asap_model)
    return n
end

@testset "Ordinary wall stage" begin
    bare = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1))
    gravity = DesignParameters()
    @test gravity.lateral === nothing
    @test gravity.wall_inputs === nothing
    @test length(build_pipeline(gravity)) == 2
    @test design_ordinary_walls!(bare, gravity) === nothing
    @test bare.ordinary_wall_result === nothing
    g0 = build_design_graph(bare, gravity)
    @test NODE_ORDINARY_WALLS ∉ [node_key(n) for n in g0.nodes]

    inputs = _stage_inputs()
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(), assignment=BuildingUnit()),
        wall_inputs=inputs,
        skip_visualization=true,
    )
    @test length(build_pipeline(lateral)) == 3
    g1 = build_design_graph(bare, lateral)
    wall_node = only(n for n in g1.nodes if node_key(n) == NODE_ORDINARY_WALLS)
    @test dependencies(wall_node) == [NODE_MEMBERS]
    @test needs_sync(wall_node) == false
    @test :wall_inputs in param_slice(wall_node)
    @test :lateral in param_slice(wall_node)
    @test :ordinary_wall_result in struc_writes(wall_node)

    missing = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(), assignment=BuildingUnit()))
    err = try
        design_ordinary_walls!(bare, missing)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("wall_inputs", sprint(showerror, err))

    err = try
        design_ordinary_walls!(bare, lateral)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("no walls", sprint(showerror, err))

    outrigger = DesignParameters(
        lateral=LateralDesign(; system=OutriggerSystem(), assignment=BuildingUnit()),
        wall_inputs=inputs)
    err = try
        design_ordinary_walls!(bare, outrigger)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("OutriggerSystem", sprint(showerror, err))

    share = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(),
                               assignment=IsolatedWallShare(0.5)),
        wall_inputs=inputs)
    err = try
        design_ordinary_walls!(bare, share)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("BuildingUnit", sprint(showerror, err))

    claimed = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(; pdelta=true))
    err = try
        design_ordinary_walls!(bare, claimed)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("1/(1", sprint(showerror, err))

    # §12.8.7 scales QE before the combination. Ev stays on unscaled dead.
    gravity_actions = PierGravityActions(:Lr,
        WallAction(1.0e6, 100.0, 50.0), WallAction(10.0, 20.0, 30.0), WallAction())
    qe = WallAction(2.0e5, 5.0e5, 8.0e6)
    m = 1.0 / (1.0 - 0.12)
    scaled = StructuralSynthesizer._scale_seismic_action(qe, m)
    @test scaled.N ≈ qe.N * m
    @test scaled.V ≈ qe.V * m
    @test scaled.M ≈ qe.M * m
    identity = StructuralSynthesizer._scale_seismic_action(qe, 1.0)
    @test (identity.N, identity.V, identity.M) == (qe.N, qe.V, qe.M)
    raw = StructuralSynthesizer._seismic_strength_actions(gravity_actions, qe, 1.0, 0.05)
    amp = StructuralSynthesizer._seismic_strength_actions(gravity_actions, scaled, 1.0, 0.05)
    @test length(raw) == length(amp) > 0
    factor_of = Dict(combo.name => combo.E for combo in asce7_strength_combinations)
    for (a, b) in zip(raw, amp)
        E = factor_of[a.combination]
        @test b.V - a.V ≈ E * (m - 1) * qe.V
        @test b.M - a.M ≈ E * (m - 1) * qe.M
        @test b.N - a.N ≈ E * (m - 1) * qe.N
    end

    master = Asap.Node([0.0u"m", 0.0u"m", 4.0u"m"], :free)
    level = StructuralSynthesizer.ElfLevel(1, 4.0, 4.0, 4.0, 1.0, 1.0, 1.0, master,
        (0.0, 0.0), (10.0, 6.0), (0.0, 10.0, 0.0, 6.0),
        Vector{Vector{NTuple{2, Float64}}}())
    function drift_case(θ, Δ)
        factor = pdelta_displacement_multiplier(θ, 0.125)
        zeros6 = zeros(1)
        return StructuralSynthesizer.ElfCase(:X, :drift, :none, 0.1, 1.0, 1.0,
            zeros6, zeros6, zeros6, zeros6, zeros6, zeros6, [Δ],
            Union{Float64, Nothing}[θ], Union{Float64, Nothing}[factor],
            Union{Float64, Nothing}[nothing])
    end
    above = StructuralSynthesizer.ElfStoryAnalysis([level], [drift_case(0.12, 0.01)])
    checks, multipliers = StructuralSynthesizer._story_drift_with_pdelta(above;
        risk_category=:II, system=:other)
    @test only(multipliers) ≈ 1 / (1 - 0.12)
    @test only(checks).drift_m ≈ 0.01 / (1 - 0.12)
    at_rest = StructuralSynthesizer.ElfStoryAnalysis([level], [drift_case(0.05, 0.01)])
    checks, multipliers = StructuralSynthesizer._story_drift_with_pdelta(at_rest;
        risk_category=:II, system=:other)
    @test only(multipliers) ≈ 1.0
    @test only(checks).drift_m ≈ 0.01

    struc = _stage_office()
    @test length(struc.walls) == 12
    @test sort([w.story for w in struc.walls]) == [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2]
    @test all(a -> !a.joined, wall_assemblies(struc.walls))
    # Each of the four lines links story 0 to 1 and story 1 to 2. The roof line has nothing above.
    @test count(w -> w.wall_above !== nothing, struc.walls) == 8
    sections = [(w.thickness, w.ρl, w.ρt) for w in struc.walls]
    err = try
        design_ordinary_walls!(struc, lateral)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("diaphragm_mode", sprint(showerror, err))
    @test struc.ordinary_wall_result === nothing

    to_asap!(struc; params=lateral, diaphragms=:rigid)
    @test !isempty(struc.asap_rigid_links)
    n_shells = _stage_crack_wall_shells!(struc)
    @test n_shells > 0
    E_cracked = [sh.E for sh in _stage_wall_shells(struc)]

    result = design_ordinary_walls!(struc, lateral)
    @test result isa OrdinaryWallResult
    @test struc.ordinary_wall_result === result
    @test sort(collect(keys(result.checks))) == collect(1:length(struc.walls))
    for (idx, records) in result.checks
        @test !isempty(records)
        cases = [r.case for r in records]
        @test :D in cases
        @test any(c -> startswith(string(c), "W"), cases)
        @test any(c -> startswith(string(c), "QE"), cases)
        @test any(r -> r.case === :D && r.check == "in-plane shear", records)
        @test any(r -> startswith(string(r.case), "W") && r.check == "in-plane shear", records)
        @test any(r -> startswith(string(r.case), "QE") && r.check == "in-plane shear", records)
        @test all(r -> r.wall_index == idx && (r.direction === :X || r.direction === :Y), records)
    end
    @test !isempty(result.drift)
    @test all(c -> c isa SeismicStoryDriftCheck, result.drift)
    @test length(unique(c.story for c in result.drift)) == 3
    @test result.max_story_stability <= 0.10
    @test length(result.pdelta_multipliers) == length(result.drift)
    @test all(m -> m ≈ 1.0, result.pdelta_multipliers)
    @test [(w.thickness, w.ρl, w.ρt) for w in struc.walls] == sections
    @test [sh.E for sh in _stage_wall_shells(struc)] == E_cracked

    design = capture_design(struc, lateral)
    @test sort(collect(keys(design.walls))) == collect(1:length(struc.walls))
    @test design.walls[1] == result.checks[1]
    @test length(design.seismic_story_drift) == length(result.drift)
    any_fail = any(!r.passed for records in values(result.checks) for r in records) ||
               any(!c.passes for c in result.drift)
    @test design.summary.all_checks_pass == !any_fail
    payload = design_to_json(design)
    @test length(payload.walls) == sum(length, values(result.checks); init=0)
    @test length(payload.seismic_story_drift) == length(result.drift)
    @test payload.walls[1].check == result.checks[1][1].check

    push!(struc.wall_mesh.assemblies, WallAssembly(0, [1, 2], true))
    err = try
        design_ordinary_walls!(struc, lateral)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("Joined", sprint(showerror, err))
end

@testset "Ordinary wall stage includes P-delta" begin
    struc = _stage_office_pdelta()
    @test length(struc.walls) == 9
    @test sort([w.story for w in struc.walls]) == [0, 0, 0, 1, 1, 1, 2, 2, 2]
    @test all(a -> !a.joined, wall_assemblies(struc.walls))
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
        skip_visualization=true,
    )
    to_asap!(struc; params=lateral, diaphragms=:rigid)
    _stage_crack_wall_shells!(struc)
    # Fixture knob, not an ACI factor. See `_stage_soften_y_piers!`.
    _stage_soften_y_piers!(struc, 0.001)
    sections = [(w.thickness, w.ρl, w.ρt) for w in struc.walls]
    result = design_ordinary_walls!(struc, lateral)
    θlim = stability_coefficient_limit(1.0, 4.0)
    @test 0.10 < result.max_story_stability <= θlim
    @test length(result.pdelta_multipliers) == length(result.drift)
    @test maximum(result.pdelta_multipliers) ≈ 1 / (1 - result.max_story_stability)
    @test any(m -> m > 1.0, result.pdelta_multipliers)
    @test any(r -> startswith(string(r.case), "QE") && r.check == "in-plane shear",
              result.checks[1])
    # Wind alone amplifies by about 1/(1−θ). On the pier where factored dead
    # and wind moments oppose, the net second-order moment exceeds 1.4 times
    # the net first-order moment, so §6.2.5.3 records a failure.
    @test any(r -> r.check == "second-order moment" && !r.passed &&
                   r.clause == "ACI 318-19 §6.2.5.3",
              Iterators.flatten(values(result.checks)))
    @test [(w.thickness, w.ρl, w.ρt) for w in struc.walls] == sections
end

@testset "Y-weak office exceeds θmax" begin
    struc = _stage_office_unstable()
    @test length(struc.walls) == 3
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
        skip_visualization=true,
    )
    to_asap!(struc; params=lateral, diaphragms=:rigid)
    _stage_crack_wall_shells!(struc)
    err = try
        design_ordinary_walls!(struc, lateral)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("redesigned", sprint(showerror, err))
end
