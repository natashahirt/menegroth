# Ordinary-wall stage: one isolated pier from the unified model.
#
# The ELF and wind numbers below are fixture wiring so the stage can run.
# The lateral system is Table 12.2-1 row A.3, so R, Cd, and Ω0 are that row's.
# Cd is 4, the same as row F, so the θ band of a fixture does not move with
# the row. Row F is a separate test.
#
# When the inputs state cracked stiffness, to_asap! multiplies wall-shell E
# by 0.35. The stage itself does not scale E. Thickness and length stay
# fixed. ρl and ρt may be raised above the ratios the wall already carries.
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

function _stage_inputs(; cracked::Bool=true, pdelta::Bool=false, sdc::Symbol=:B,
                       material=RC_4000_60)
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
        Ie=1.0,
        T=0.4,
        β=1.0,
        SD1=0.02,
        TL=8.0,
        rho=1.0,
        sdc=sdc,
        risk_category=:II,
        drift_system=:other,
        boundary=:pinned,
        material=material,
        model_uses_cracked_section_stiffness=cracked,
        sustained_lateral_loads=false,
        sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false,
        type5_horizontal_irregularity=false,
        orthogonal_combination=false,
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

# 12 m square, 4 m bays. Same isolation rule. Three bays is the smallest
# grid the direct design method accepts.
const _STAGE_THREE_BAY = (
    (0.0, 0.0, 4.0, 0.0),
    (8.0, 12.0, 12.0, 12.0),
    (12.0, 0.0, 12.0, 4.0),
    (0.0, 8.0, 0.0, 12.0),
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

Used where 0.10 < θ ≤ θmax. `to_asap!` applies the stated 0.35 cracked-wall
factor. Then call [`_stage_soften_y_piers!`](@ref) with `0.001`.
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

"""
Multiply E of piers whose plan line runs in Y by `extra`, then reprocess.

Fixture knob for the P-delta office. `0.001` after the 0.35 crack takes the
Y pier out of the story. Paired with [`_stage_put_weak_axis_in_y!`](@ref),
θ lands in (0.10, θmax]. It is not an ACI cracked-section factor.
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

"""
Put the placeholder's weak inertia on Y sway.

`Column.θ = 0` rolls section x onto global X, so `Ix` resists Y. The
pre-sizing section is a W with `Ix` much larger than `Iy`. This fixture
still needs a flexible Y direction. Swapping the two inertias on vertical
frame members puts the weak axis there. Wall edges are left at zero.
"""
function _stage_put_weak_axis_in_y!(struc)
    n = 0
    for el in struc.asap_model.frame_elements
        el isa Asap.Element || continue
        s = el.section
        ustrip(u"m^4", s.Ix) > 0 || continue
        a = ustrip.(u"m", el.nodeStart.position)
        b = ustrip.(u"m", el.nodeEnd.position)
        hypot(b[1] - a[1], b[2] - a[2]) <= 1e-6 * max(abs(b[3] - a[3]), 1.0) || continue
        el.section = Asap.Section(s.A, s.E, s.G, s.Iy, s.Ix, s.J, s.ρ; Ay=s.Ay, Az=s.Az)
        n += 1
    end
    n > 0 || error("ordinary-wall fixture: no vertical frame member to weaken")
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
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
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
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()))
    err = try
        design_ordinary_walls!(bare, missing)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("wall_inputs", sprint(showerror, err))

    # Row F is NP in Category C. The refusal is the table, before any solve.
    refused = DesignParameters(
        lateral=LateralDesign(; system=InteractiveShearWallFrameSystem(),
                               assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(; sdc=:C),
        skip_visualization=true,
    )
    err = try
        design_ordinary_walls!(bare, refused)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("NP", sprint(showerror, err))
    @test occursin("F", sprint(showerror, err))

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
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3),
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
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
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
    shells = _stage_wall_shells(struc)
    @test !isempty(shells)
    # ShellTri3 stores E as pascals, not a quantity.
    E_gross = ustrip(u"Pa", RC_4000_60.concrete.E)
    @test shells[1].E ≈ 0.35 * E_gross
    @test all(sh -> sh.E == shells[1].E, shells)
    E_cracked = [sh.E for sh in shells]

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
    @test length(result.gravity_shares) == 3
    @test all(s -> isfinite(s.share) && s.total_N > 0, result.gravity_shares)
    @test isempty(result.interactive_shear)
    @test isempty(result.frame_members)
    @test length(result.pdelta_multipliers) == length(result.drift)
    @test all(m -> m ≈ 1.0, result.pdelta_multipliers)
    @test all(i -> struc.walls[i].thickness == sections[i][1], eachindex(struc.walls))
    @test all(i -> struc.walls[i].ρl + 1e-12 >= sections[i][2] &&
                   struc.walls[i].ρt + 1e-12 >= sections[i][3], eachindex(struc.walls))
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

end

@testset "Ordinary wall stage includes P-delta" begin
    struc = _stage_office_pdelta()
    @test length(struc.walls) == 9
    @test sort([w.story for w in struc.walls]) == [0, 0, 0, 1, 1, 1, 2, 2, 2]
    @test all(a -> !a.joined, wall_assemblies(struc.walls))
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
        skip_visualization=true,
    )
    to_asap!(struc; params=lateral, diaphragms=:rigid)
    # Fixture knobs, not ACI factors. The Y pier is softened, and the
    # placeholder's weak axis is put in Y. See the helpers above.
    _stage_soften_y_piers!(struc, 0.001)
    _stage_put_weak_axis_in_y!(struc)
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
    @test all(i -> struc.walls[i].thickness == sections[i][1], eachindex(struc.walls))
    @test all(i -> struc.walls[i].ρl + 1e-12 >= sections[i][2] &&
                   struc.walls[i].ρt + 1e-12 >= sections[i][3], eachindex(struc.walls))
end

"""
Design the joined L office with transverse steel of grade `fy_ksi`.

Fixture knob, not a bar grade. Corner φVn is proportional to fy: 1.30 MN
at 60 ksi and the 0.0025 floor on this corner. The wind corner demand is
80–95 kN. Pier shear here is carried by the concrete term, so the piers do
not depend on fy.
"""
function _stage_joined_l(fy_ksi)
    ties = RebarSteel(29000.0u"ksi", 11200.0u"ksi", fy_ksi * u"ksi", 90.0u"ksi",
                      490.0u"lb/ft^3", 0.30, 1.72u"kgCO2e/kg")
    material = ReinforcedConcreteMaterial(NWC_4000, Rebar_60, ties)
    struc = _stage_office(; segments=((0.0, 0.0, 6.0, 0.0), (0.0, 0.0, 0.0, 6.0)))
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(; material),
        skip_visualization=true,
    )
    to_asap!(struc; params=lateral, diaphragms=:rigid)
    result = design_ordinary_walls!(struc, lateral)
    return struc, lateral, result
end

function _stage_corner_records(result, name)
    return [(idx, r) for (idx, records) in result.checks for r in records if r.check == name]
end

@testset "A weak corner is given its own horizontal ratio" begin
    # 1 ksi: about 22 kN at ρ = 0.0025, so each corner needs roughly ρ ≈ 0.011.
    struc, lateral, result = _stage_joined_l(1.0)
    @test length(struc.walls) == 6
    @test all(a -> a.joined, struc.wall_mesh.assemblies)
    friction = _stage_corner_records(result, "shear friction")
    selected = _stage_corner_records(result, "corner horizontal ratio (selected)")
    @test length(friction) == 3
    @test length(selected) == 3
    @test all(((_, r),) -> r.passed && r.ratio <= 1.0, friction)
    @test all(((_, r),) -> occursin("22.9.5.1", r.clause), friction)
    @test all(((_, r),) -> r.ratio == 0.0 && r.demand > r.capacity + 1e-12, selected)
    @test all(((_, r),) -> any(g -> isapprox(r.demand, g; atol=1e-12),
                                StructuralSynthesizer.ORDINARY_WALL_RHO_GRID), selected)
    # The legs keep their own ratios. Only the corner was raised.
    @test all(w -> w.ρt ≈ 0.0025, struc.walls)
    hosts = sort([idx for (idx, _) in friction])
    @test hosts == sort([minimum(a.wall_indices) for a in struc.wall_mesh.assemblies])
    @test all(r -> r.passed, Iterators.flatten(values(result.checks)))
end

@testset "A corner the grid cannot reach fails the design" begin
    # 0.1 ksi: about 17 kN at the 0.0200 top of the grid, below the demand.
    struc, lateral, result = _stage_joined_l(0.1)
    friction = _stage_corner_records(result, "shear friction")
    selected = _stage_corner_records(result, "corner horizontal ratio (selected)")
    @test length(friction) == 3
    @test all(((_, r),) -> !r.passed && r.ratio > 1.0 && r.demand > r.capacity, friction)
    @test all(((_, r),) -> !occursin("Table 22.9.4.4 limit", r.clause), friction)
    top = last(StructuralSynthesizer.ORDINARY_WALL_RHO_GRID)
    @test all(((_, r),) -> r.demand ≈ top, selected)
    others = [r for records in values(result.checks) for r in records
              if r.check != "shear friction"]
    @test all(r -> r.passed, others)

    design = capture_design(struc, lateral)
    @test !design.summary.all_checks_pass
end

@testset "Y-weak office exceeds θmax" begin
    struc = _stage_office_unstable()
    @test length(struc.walls) == 3
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
        skip_visualization=true,
    )
    to_asap!(struc; params=lateral, diaphragms=:rigid)
    err = try
        design_ordinary_walls!(struc, lateral)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("redesigned", sprint(showerror, err))
end

"""Node above `bn` on a column, or `nothing` when the story ends."""
function _stage_node_above(model, bn)
    z0 = ustrip(u"m", bn.position[3])
    above = nothing
    for el in model.frame_elements
        (el.nodeStart === bn || el.nodeEnd === bn) || continue
        other = el.nodeStart === bn ? el.nodeEnd : el.nodeStart
        ustrip(u"m", other.position[3]) > z0 + 0.5 || continue
        above = other
        break
    end
    return above
end

@testset "wall shells share offset column joints" begin
    struc = _stage_office()
    for col in struc.columns
        # The story above is smaller, so the shared floor joint is not a
        # vertical extrusion of the grid line.
        c = col.story == 0 ? 0.8u"m" : 0.4u"m"
        col.c1 = c
        col.c2 = c
    end
    update_structural_offsets!(struc; input_is_centerline=false)
    @test any(c -> hypot(c.structural_offset...) > 0.05, struc.columns)
    to_asap!(struc; params=DesignParameters(diaphragm_mode=:rigid), diaphragms=:rigid)
    model = struc.asap_model
    @test maximum(abs, model.u) < 1.0
    for (iw, wall) in enumerate(struc.walls)
        eidx = struc.segments[first(segment_indices(wall))].edge_idx
        el = model.frame_elements[eidx]
        pier = only(p for p in struc.wall_mesh.piers if p.wall_index == iw)
        owned = Set(objectid(nd) for sh in pier.shells for nd in sh.nodes)
        for nd in (el.nodeStart, el.nodeEnd)
            @test objectid(nd) in owned
            d = min(hypot(ustrip(u"m", nd.position[1]) - wall.x1,
                          ustrip(u"m", nd.position[2]) - wall.y1),
                    hypot(ustrip(u"m", nd.position[1]) - wall.x2,
                          ustrip(u"m", nd.position[2]) - wall.y2))
            @test 1e-3 < d < 1.0
            top = _stage_node_above(model, nd)
            @test top !== nothing
            @test objectid(top) in owned
        end
    end
end

@testset "design_building publishes ordinary-wall records" begin
    # Three bays each way. ACI 318-11 §13.6.1.1 requires three continuous
    # spans for the direct design method.
    struc = _stage_office(; x_bays=3, y_bays=3, segments=_STAGE_THREE_BAY)
    floor = FlatPlateOptions(method=DDM())
    materials = MaterialOptions(concrete=RC_4000_60.concrete, rebar=Rebar_60)
    # Concrete framing stays fixed. Column centerline offsets stay on.
    beams = ConcreteBeamOptions(material=RC_4000_60.concrete, rebar_material=Rebar_60)
    columns = ConcreteColumnOptions(material=RC_4000_60.concrete, rebar_material=Rebar_60)
    gravity = DesignParameters(
        name="gravity-walls",
        floor=floor,
        materials=materials,
        beams=beams,
        columns=columns,
        wall_thickness=0.3u"m",
        diaphragm_mode=:rigid,
        max_iterations=3,
        skip_visualization=true,
    )
    gdesign = design_building(struc, gravity)
    @test isempty(gdesign.walls)
    @test isempty(gdesign.seismic_story_drift)
    gjson = design_to_json(gdesign)
    @test isempty(gjson.walls)
    @test isempty(gjson.seismic_story_drift)
    gbuf = IOBuffer()
    engineering_report(gdesign; io=gbuf, report_units=:metric)
    greport = String(take!(gbuf))
    @test !occursin("ORDINARY WALLS", greport)
    @test !occursin("SEISMIC STORY DRIFT", greport)

    lateral = DesignParameters(
        name="ordinary-walls",
        floor=floor,
        materials=materials,
        beams=beams,
        columns=columns,
        wall_thickness=0.3u"m",
        diaphragm_mode=:rigid,
        max_iterations=3,
        skip_visualization=true,
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
    )
    design = design_building(struc, lateral)
    @test sort(collect(keys(design.walls))) == collect(1:length(struc.walls))
    @test all(records -> !isempty(records), values(design.walls))
    @test !isempty(design.seismic_story_drift)
    payload = design_to_json(design)
    @test length(payload.walls) == sum(length, values(design.walls); init=0)
    @test any(w -> w.check == "in-plane shear", payload.walls)
    @test length(payload.seismic_story_drift) == length(design.seismic_story_drift)
    @test all(d -> d.drift_m isa Float64 && d.allowable_m isa Float64, payload.seismic_story_drift)
    buf = IOBuffer()
    engineering_report(design; io=buf, report_units=:metric)
    report = String(take!(buf))
    @test occursin("ORDINARY WALLS", report)
    @test occursin("SEISMIC STORY DRIFT", report)
end

function _ratio_wall(; ρl=0.0025, ρt=0.0025, lw=6.0, t=0.3, h=4.0)
    return Wall([1], h * u"m"; thickness=t * u"m",
                x1=0.0, y1=0.0, x2=lw, y2=0.0, story=0, ρl=ρl, ρt=ρt)
end

_ratio_action(N, V, M) = CombinedWallAction(:strength_1_2D_1_6L, :only, N, V, M)

"First grid ratio at or above `floor` whose in-plane flexure passes, else nothing."
function _first_passing_ρl(floor, lw, t, material, N, M)
    candidates = [floor]
    for r in StructuralSynthesizer.ORDINARY_WALL_RHO_GRID
        r > floor + 1e-12 && push!(candidates, r)
    end
    for ρl in candidates
        section = WallSection(lw * u"m", t * u"m"; ρl=ρl, ρt=0.0025)
        check_wall_inplane_flexure(section, material, N, M).passed && return ρl
    end
    return nothing
end

@testset "ordinary wall reinforcement selection" begin
    mat = RC_4000_60
    hw = 12.0u"m"
    select! = StructuralSynthesizer.select_ordinary_wall_reinforcement!

    # A demand the minimum ratios already cover is left alone.
    light = _ratio_wall()
    ρ_light = select!(light, [_ratio_action(1e3, 1e3, 1e3)], mat; hw)
    @test light.ρl == 0.0025
    @test light.ρt == 0.0025
    @test ρ_light == 0.0

    # Shear sets ρt. A 1 kN·m moment does not push ρl above the §11.6.2 floor.
    fc = ustrip(u"Pa", mat.concrete.fc′)
    fyt = ustrip(u"Pa", mat.transverse.Fy)
    λ = mat.concrete.λ
    cap0 = wall_shear_capacity_si(fc, fyt, 6.0, 0.3, 0.0, 12.0; λ=λ)
    cap_p = wall_shear_capacity_si(fc, fyt, 6.0, 0.3, 1e-4, 12.0; λ=λ)
    slope = (cap_p.ϕVn - cap0.ϕVn) / 1e-4
    Vu = cap0.ϕVn + 0.0045 * slope
    sheared = _ratio_wall()
    ρ_shear = select!(sheared, [_ratio_action(1e3, Vu, 1e3)], mat; hw)
    @test isapprox(ρ_shear, 0.0045; rtol=1e-6)
    @test isapprox(sheared.ρt, 0.0045; atol=1e-6)
    shear_at = check_wall_inplane_shear(
        WallSection(6.0u"m", 0.3u"m"; ρl=sheared.ρl, ρt=sheared.ρt), mat, Vu, hw)
    @test shear_at.passed
    shear_below = check_wall_inplane_shear(
        WallSection(6.0u"m", 0.3u"m"; ρl=sheared.ρl, ρt=sheared.ρt - 0.0005), mat, Vu, hw)
    @test !shear_below.passed
    # hw/lw = 2: Eq. (11.6.2) = 0.0025 + 0.25·(ρt − 0.0025) = 0.0030,
    # and it need not exceed ρt required for strength.
    @test isapprox(sheared.ρl, 0.0030; atol=1e-6)

    # Flexure sets ρl. Shear stays at the 0.0025 floor. The value kept is the
    # first ratio, walking upward, that the recorded flexure check accepts.
    Nflex = 1.0e5
    φ_min = check_wall_inplane_flexure(
        WallSection(6.0u"m", 0.3u"m"; ρl=0.0025, ρt=0.0025), mat, Nflex, 0.0).capacity
    best = maximum(check_wall_inplane_flexure(
                       WallSection(6.0u"m", 0.3u"m"; ρl=ρ, ρt=0.0025), mat, Nflex, 0.0).capacity
                   for ρ in StructuralSynthesizer.ORDINARY_WALL_RHO_GRID)
    # φMn is not monotone in ρl, so the moment sits between the minimum-ratio
    # capacity and the best capacity on the grid. The selector must stop at
    # the first ratio that passes, not at the ratio with the largest φMn.
    @test best > φ_min
    Mu = φ_min + 0.5 * (best - φ_min)
    bent = _ratio_wall()
    select!(bent, [_ratio_action(Nflex, 1e3, Mu)], mat; hw)
    @test bent.ρt == 0.0025
    expected = _first_passing_ρl(0.0025, 6.0, 0.3, mat, Nflex, Mu)
    @test expected !== nothing
    @test bent.ρl == expected
    @test bent.ρl > 0.0025

    # A caller ratio that already meets the requirement is kept, including
    # one that is not on the grid. Here the §11.6.2 formula would ask for
    # about 0.0039, and the strength cap brings that back to 0.0025, so the
    # caller's 0.0030 is not raised.
    kept = _ratio_wall(; ρl=0.0030, ρt=0.0081)
    select!(kept, [_ratio_action(1e3, 1e3, 1e3)], mat; hw)
    @test kept.ρl == 0.0030
    @test kept.ρt == 0.0081

    # Shear above φ·Vn,max does not throw. ρt goes to the top of the grid and
    # the recorded shear check fails.
    above = _ratio_wall()
    Vu_over = 2 * WALL_PHI_SHEAR * cap0.Vn_max
    ρ_over = select!(above, [_ratio_action(1e3, Vu_over, 1e3)], mat; hw)
    @test ρ_over === nothing
    @test above.ρt == StructuralSynthesizer.ORDINARY_WALL_RHO_GRID[end]
    over_records = check_ordinary_wall(above, [_ratio_action(1e3, Vu_over, 1e3)];
                                       material=mat, wall_index=1, case=:D,
                                       boundary=:pinned, hw, ρt_strength=ρ_over)
    @test any(r -> r.check == "in-plane shear" && !r.passed, over_records)

    # A caller ratio already above the grid is kept when the cap is exceeded.
    above_caller = _ratio_wall(; ρt=0.03)
    select!(above_caller, [_ratio_action(1e3, Vu_over, 1e3)], mat; hw)
    @test above_caller.ρt == 0.03

    # Squat wall: Eq. (11.6.2) at ρt = 0.005 and hw/lw = 1 is 0.004375.
    # ρt required for strength is 0.003, so ρl stops at 0.003, and the
    # recorded minimum check uses that same cap.
    cap0s = wall_shear_capacity_si(fc, fyt, 4.0, 0.3, 0.0, 4.0; λ=λ)
    capps = wall_shear_capacity_si(fc, fyt, 4.0, 0.3, 1e-4, 4.0; λ=λ)
    Vu_squat = cap0s.ϕVn + 0.003 * (capps.ϕVn - cap0s.ϕVn) / 1e-4
    squat = _ratio_wall(; ρt=0.005, lw=4.0, h=4.0)
    ρ_squat = select!(squat, [_ratio_action(1e3, Vu_squat, 1e3)], mat; hw=4.0u"m")
    @test isapprox(ρ_squat, 0.003; rtol=1e-4)
    @test squat.ρt == 0.005
    @test isapprox(squat.ρl, 0.003; atol=1e-6)
    squat_records = check_ordinary_wall(squat, [_ratio_action(1e3, Vu_squat, 1e3)];
                                        material=mat, wall_index=1, case=:D,
                                        boundary=:pinned, hw=4.0u"m", ρt_strength=ρ_squat)
    min_l = only(r for r in squat_records if r.check == "min longitudinal reinf ρl")
    @test min_l.passed
    @test isapprox(min_l.demand, 0.003; atol=1e-6)
end

@testset "Building frame gravity share" begin
    ok = [StructuralSynthesizer.WallGravityShare(1, 10.0, 100.0, 0.10)]
    @test StructuralSynthesizer._refuse_building_frame_gravity!(:A3, ok) === ok
    @test StructuralSynthesizer._refuse_building_frame_gravity!(:B6, ok) === ok
    at = [StructuralSynthesizer.WallGravityShare(1, 20.0, 100.0, 0.20)]
    @test StructuralSynthesizer._refuse_building_frame_gravity!(:B6, at) === at
    over = [StructuralSynthesizer.WallGravityShare(2, 30.0, 100.0, 0.30)]
    err = try
        StructuralSynthesizer._refuse_building_frame_gravity!(:B6, over)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("20%", sprint(showerror, err))
    @test occursin("C12.2.1", sprint(showerror, err))
end

@testset "Interactive system, row F" begin
    struc = _stage_office()
    params = DesignParameters(
        lateral=LateralDesign(; system=InteractiveShearWallFrameSystem(),
                               assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
        skip_visualization=true)
    to_asap!(struc; params=params, diaphragms=:rigid)
    # The unsized vault frame, without the wall shells, drifts far enough that
    # story-1 θ/(1+θ) exceeds θmax. §12.8.7 requires a redesign, so the stage
    # throws instead of reporting member results.
    err = try
        design_ordinary_walls!(struc, params)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("redesigned", msg)
    @test occursin("12.2.5.8", msg)
    @test occursin("12.8.7", msg)
end
