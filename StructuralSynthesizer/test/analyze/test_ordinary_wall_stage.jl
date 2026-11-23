# Ordinary-wall stage: one isolated pier from the unified model.
#
# The ELF and wind numbers below are fixture wiring so the stage can run.
# The lateral system is Table 12.2-1 row A.3, so R, Cd, and Ω0 are that row's.
# Cd is 4, the same as row F, so the θ band of a fixture does not move with
# the row. Row F is a separate test.
#
# When the inputs state cracked stiffness, to_asap! multiplies wall-shell E
# by 0.35. The stage itself does not scale E. Thickness and length stay
# fixed. ρl and ρt are set to the lightest ratios that pass. A ratio
# already on the wall is not kept.
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
                       material=RC_4000_60, SDS=0.05, S1=0.02, SD1=0.02,
                       qz=[1.0, 1.5, 2.0])
    return OrdinaryWallInputs(;
        directions=((1.0, 0.0), (0.0, 1.0)),
        qz=qz,
        qh=2.0,
        Kd=1.0,
        G=0.85,
        GCpi=0.18,
        roof=:Lr,
        method=:sds,
        SDS=SDS,
        S1=S1,
        Ie=1.0,
        T=0.4,
        β=1.0,
        SD1=SD1,
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

"""
Story 0 is the support level and has no beam grid. Copy the story-1 beam
plan down to the column bases so a ground wall has an edge to claim.
"""
function _stage_grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    any(e -> e in beams && _stage_horizontal(skel, e), skel.stories[0].edges) && return skel
    z0 = skel.stories_z[1]
    for e in skel.stories[1].edges
        (e in beams && _stage_horizontal(skel, e)) || continue
        v1, v2 = skel.edge_indices[e]
        x1, y1 = _stage_xy(skel, v1)
        x2, y2 = _stage_xy(skel, v2)
        StructuralSynthesizer.add_element!(skel, Meshes.Segment(
            Meshes.Point(x1 * u"m", y1 * u"m", z0),
            Meshes.Point(x2 * u"m", y2 * u"m", z0));
            group=:beams, level_idx=0)
    end
    grade_of = Dict{NTuple{2, Float64}, Int}()
    for (k, v) in enumerate(skel.vertices)
        c = Meshes.coords(v)
        abs(ustrip(u"m", c.z) - ustrip(u"m", z0)) <= 1e-6 || continue
        grade_of[(round(ustrip(u"m", c.x); digits=6), round(ustrip(u"m", c.y); digits=6))] = k
    end
    for face in skel.stories[1].faces
        cycle = Int[]
        for v in skel.face_vertex_indices[face]
            x, y = _stage_xy(skel, v)
            key = (round(x; digits=6), round(y; digits=6))
            haskey(grade_of, key) || error("ordinary-wall fixture: no grade vertex at $key")
            push!(cycle, grade_of[key])
        end
        StructuralSynthesizer.add_face!(skel, Meshes.Ngon(skel.vertices[cycle]...);
                                        group=:grade, level_idx=0, v_indices=cycle)
    end
    return skel
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
                       segments=_STAGE_BOTH_AXES, thickness=0.3u"m",
                       park_wall_overlaps::Bool=true)
    skel = gen_medium_office(x, y, 4.0u"m", x_bays, y_bays, 3)
    _stage_grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    _stage_claim_segments!(skel, beams, segments)
    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=_STAGE_VAULT,
        wall_thickness=thickness,
        park_wall_overlaps=park_wall_overlaps)
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
function _stage_office_pdelta(; park_wall_overlaps::Bool=true)
    return _stage_office(;
        park_wall_overlaps=park_wall_overlaps,
        x=10.0u"m", y=6.0u"m", x_bays=2, y_bays=1,
        segments=((0.0, 0.0, 5.0, 0.0),
                  (0.0, 6.0, 5.0, 6.0),
                  (10.0, 0.0, 10.0, 6.0)))
end

"""10×6 m, three stories, one wall line along X. Y has no wall."""
function _stage_office_unstable(; park_wall_overlaps::Bool=true)
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 2, 3)
    _stage_grade_beams!(skel)
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
        wall_thickness=0.3u"m",
        park_wall_overlaps=park_wall_overlaps)
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end

"""One story, 10×6 m, a wall on each long side. No wall above a lintel."""
function _stage_office_one_story()
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 2, 1)
    _stage_grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    ground = [e for e in skel.stories[0].edges if e in beams && _stage_horizontal(skel, e)]
    longest = maximum(_stage_plan_length(skel, e) for e in ground)
    long = [e for e in ground if _stage_plan_length(skel, e) >= longest - 1e-6]
    ordered = sort(long; by=e -> _stage_across(skel, e))
    length(ordered) >= 2 || error("ordinary-wall fixture: expected two long sides")
    for e0 in ordered
        v1, v2 = skel.edge_indices[e0]
        x1, y1 = _stage_xy(skel, v1)
        x2, y2 = _stage_xy(skel, v2)
        _stage_claim_stacked_wall!(skel, 0, beams, x1, y1, x2, y2)
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
Y pier out of the story. The X piers are then scaled by `0.4`: a fixed grade
base lets them brace Y out of plane, and that factor puts θ back in
(0.10, θmax]. It is not an ACI cracked-section factor.
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

"""Multiply E of piers whose plan line runs in X by `extra`, then reprocess."""
function _stage_soften_x_piers!(struc, extra)
    n = 0
    for pier in struc.wall_mesh.piers
        wall = struc.walls[pier.wall_index]
        abs(wall.x2 - wall.x1) > abs(wall.y2 - wall.y1) || continue
        for sh in pier.shells
            sh.E *= extra
            n += 1
        end
    end
    n > 0 || error("ordinary-wall fixture: no X pier to soften")
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

@testset "dual system stage backbone" begin
    # The _stage_office fixture is a steel moment frame + concrete-wall core — a
    # genuine dual system. A steel SMF + special RC walls is Table 12.2-1 row D.9
    # (permitted in SDC D). The backbone is material-agnostic: it reads R/Cd/Ω0
    # from the row and runs the shared ELF/wind/drift plumbing on the solved
    # frame+core model. `material` in the inputs is the concrete core.
    dual = DesignParameters(
        lateral=LateralDesign(;
            system=DualSystem(; moment_frame=:steel_smf, wall=:special_rc),
            assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(; sdc=:D, material=RC_4000_60),
        skip_visualization=true,
        jump_wall_thickness=false,
    )

    # Refusals land before any solve: a non-dual system, and a no-walls building.
    walls_params = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(; sdc=:D), skip_visualization=true, jump_wall_thickness=false)
    @test_throws ArgumentError design_dual_system!(_stage_office(), walls_params)
    no_walls = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1))
    @test design_dual_system!(no_walls, dual) === nothing

    # park_wall_overlaps=false keeps the frame columns and column-to-column
    # girders (park=true collapses them into the walls), so this fixture is a
    # genuine moment frame + core.
    struc = _stage_office(; park_wall_overlaps=false)
    @test count(b -> b.role === :girder, struc.beams) > 0
    # Designate the primary girders as the moment frame (override path). Joists
    # and secondary beams stay gravity: only a column-to-column girder is a
    # steel moment-frame member (the only declared steel moment-frame release).
    for b in struc.beams
        b.role === :girder && (b.lateral_role = :moment_frame)
    end
    @test any(b -> b.lateral_role === :moment_frame, struc.beams)
    # The Asap model must be processed first.
    @test_throws ArgumentError design_dual_system!(struc, dual)

    to_asap!(struc; params=dual, diaphragms=:rigid)
    result = design_dual_system!(struc, dual)
    @test result isa DualSystemResult
    @test result.row_x === :D9 && result.row_y === :D9
    @test result.moment_frame.source === :override && !isempty(result.moment_frame.beams)
    @test !isempty(result.drift)
    @test length(result.pdelta_multipliers) == length(result.drift)
    @test isfinite(result.max_story_stability) && result.max_story_stability ≥ 0.0
    @test haskey(struc.stage_diagnostics, :dual)
    @test length(result.pending) == 3
end

@testset "Ordinary wall stage" begin
    bare = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1))
    gravity = DesignParameters()
    @test gravity.lateral === nothing
    @test gravity.wall_inputs === nothing
    @test length(build_pipeline(gravity)) == 3
    @test design_ordinary_walls!(bare, gravity) === nothing
    @test bare.ordinary_wall_result === nothing
    g0 = build_design_graph(bare, gravity)
    wall_gravity = only(n for n in g0.nodes if node_key(n) == NODE_ORDINARY_WALLS)
    @test dependencies(wall_gravity) == [NODE_MEMBERS]
    @test needs_sync(wall_gravity) == false
    # The footing is sized after the wall stage. A thickness jump remeshes
    # inside that stage; ACI 318-11 §15.2.2 sizes the base from the force
    # on the thickness that remains. Foundations also depend on members:
    # the wall hash is thickness, and a force change that does not change
    # thickness must still recompute the footing.
    with_fdn = DesignParameters(
        foundation_options = FoundationParameters(
            soil = medium_sand,
            options = FoundationOptions(strategy = :all_spread),
        ),
    )
    g_fdn = build_design_graph(bare, with_fdn)
    wall_fdn = only(n for n in g_fdn.nodes if node_key(n) == NODE_ORDINARY_WALLS)
    fdn_node = only(n for n in g_fdn.nodes if node_key(n) == NODE_FOUNDATIONS)
    @test dependencies(wall_fdn) == [NODE_MEMBERS]
    @test dependencies(fdn_node) == [NODE_MEMBERS, NODE_ORDINARY_WALLS]

    inputs = _stage_inputs()
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=inputs,
        skip_visualization=true,
        jump_wall_thickness=false,
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
        jump_wall_thickness=false,
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
    # The model has not been meshed, so the stage stops there.
    @test occursin("wall mesh is empty", sprint(showerror, err))
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
    # The summary covers every element group. The 50 mm stage vault fails its kern check.
    others_ok = all(StructuralSynthesizer._slab_design_ok, values(design.slabs)) &&
                all(c -> c.ok, values(design.columns)) &&
                all(b -> b.ok, values(design.beams)) &&
                all(f -> f.ok, values(design.foundations))
    @test !others_ok
    @test design.summary.all_checks_pass == (!any_fail && others_ok)
    payload = design_to_json(design)
    @test length(payload.walls) == sum(length, values(result.checks); init=0)
    @test length(payload.seismic_story_drift) == length(result.drift)
    @test payload.walls[1].check == result.checks[1][1].check

end

@testset "Ordinary wall stage includes P-delta" begin
    # The Y frame is what this test weakens. Its columns stand at the pier
    # ends, so they stay instead of being parked.
    struc = _stage_office_pdelta(; park_wall_overlaps=false)
    @test length(struc.walls) == 9
    @test sort([w.story for w in struc.walls]) == [0, 0, 0, 1, 1, 1, 2, 2, 2]
    @test all(a -> !a.joined, wall_assemblies(struc.walls))
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
        skip_visualization=true,
        jump_wall_thickness=false,
        # This fixture is the softened Y frame. The default 10 psf façade
        # is enough to push θ over θmax. Zero leaves that weight out.
        loads=GravityLoads(wall_SDL=0.0u"psf"),
    )
    to_asap!(struc; params=lateral, diaphragms=:rigid)
    # Fixture knobs, not ACI factors. The Y pier is taken out, the X piers
    # are softened so their out-of-plane stiffness does not brace Y, and the
    # placeholder's weak axis is put in Y. See the helpers above.
    _stage_soften_y_piers!(struc, 0.001)
    _stage_soften_x_piers!(struc, 0.4)
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
    # The story magnifier is about 1/(1−θ). This fixture also multiplies the
    # Y pier's stiffness by 0.001, so a pier's own wind moment can still
    # exceed 1.4. That record is the action's ratio. Dead and wind opposing
    # each other is not the check; the unit test below covers that case.
    second_order = [r for r in Iterators.flatten(values(result.checks))
                    if r.check == "second-order moment"]
    @test all(r -> !r.passed && r.clause == "ACI 318-19 §6.2.5.3" && r.ratio > 1.4,
              second_order)
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
        jump_wall_thickness=false,
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
    # The frame's weak axis is what pushes θ past θmax. Its columns stand at
    # the wall ends, so they stay instead of being parked.
    struc = _stage_office_unstable(; park_wall_overlaps=false)
    @test length(struc.walls) == 3
    lateral = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
        skip_visualization=true,
        jump_wall_thickness=false,
    )
    to_asap!(struc; params=lateral, diaphragms=:rigid)
    # The fixed grade base lets the X wall brace Y out of plane, so θ stays
    # under θmax until the frames' weak axis is put in Y. Fixture, not an
    # ACI factor.
    _stage_put_weak_axis_in_y!(struc)
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

@testset "wall shells share the column centerline joint" begin
    # The column centerline is the skeleton vertex. structural_offset stays
    # (0, 0), so the shell reuses that frame node rather than a shifted one.
    struc = _stage_office()
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
            @test d <= 1e-3
            top = _stage_node_above(model, nd)
            @test top !== nothing
            @test objectid(top) in owned
        end
    end
end

@testset "design_building publishes ordinary-wall records" begin
    # The walls end slab spans. Direct design is not used there: the support
    # stiffness at the wall is not defined (ACI 318-11 R13.1, corpus:
    # aci-318-11, page 243). The floor is analyzed by FEA.
    struc = _stage_office(; x_bays=3, y_bays=3, segments=_STAGE_THREE_BAY)
    floor = FlatPlateOptions(method=FEA())
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
        max_iterations=10,
        skip_visualization=true,
        jump_wall_thickness=false,
    )
    gdesign = design_building(struc, gravity)
    # Gravity axial sizes the piers. There is no wind or earthquake, so no drift.
    @test sort(collect(keys(gdesign.walls))) == collect(1:length(struc.walls))
    @test all(records -> !isempty(records), values(gdesign.walls))
    @test all(records -> all(r -> r.case === :D, records), values(gdesign.walls))
    @test isempty(gdesign.seismic_story_drift)

    gjson = design_to_json(gdesign)
    @test !isempty(gjson.walls)
    @test isempty(gjson.seismic_story_drift)
    gbuf = IOBuffer()
    engineering_report(gdesign; io=gbuf, report_units=:metric)
    greport = String(take!(gbuf))
    @test occursin("ORDINARY WALLS", greport)
    @test !occursin("SEISMIC STORY DRIFT", greport)

    lateral = DesignParameters(
        name="ordinary-walls",
        floor=floor,
        materials=materials,
        beams=beams,
        columns=columns,
        wall_thickness=0.3u"m",
        diaphragm_mode=:rigid,
        max_iterations=10,
        skip_visualization=true,
        jump_wall_thickness=false,
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

@testset "§6.2.5.3 is the ratio of each action" begin
    wall = _ratio_wall()
    records = WallCheckRecord[]
    first = _ratio_action(0.0, 0.0, 20.0)
    grown = _ratio_action(0.0, 0.0, 50.0)
    # Gravity 1000 → 1050 and earthquake −980 → −1000. The nets are 20 and 50.
    StructuralSynthesizer._record_second_order_moment!(
        records, wall, first, grown; wall_index=1, case=:QE,
        first_parts=[1000.0, -980.0], grown_parts=[1050.0, -1000.0])
    @test isempty(records)

    # The earthquake moment itself doubles. That part is the ratio.
    StructuralSynthesizer._record_second_order_moment!(
        records, wall, first, grown; wall_index=1, case=:QE,
        first_parts=[1000.0, 100.0], grown_parts=[1050.0, 200.0])
    @test length(records) == 1
    @test records[1].ratio ≈ 2.0
    @test records[1].demand ≈ 200.0
    @test records[1].capacity ≈ 140.0
    @test records[1].clause == "ACI 318-19 §6.2.5.3"
    @test !records[1].passed

    # One action, and no parts: the combination moment is that action.
    empty!(records)
    StructuralSynthesizer._record_second_order_moment!(
        records, wall,
        _ratio_action(0.0, 0.0, 100.0), _ratio_action(0.0, 0.0, 150.0);
        wall_index=1, case=:D)
    @test length(records) == 1
    @test records[1].ratio ≈ 1.5

    gravity = PierGravityActions(:Lr,
        WallAction(1.0e6, 100.0, 50.0), WallAction(10.0, 20.0, 30.0),
        WallAction(0.0, 0.0, 4.0))
    qe = WallAction(2.0e5, 5.0e5, 8.0e6)
    seismic = StructuralSynthesizer._seismic_strength_actions(gravity, qe, 1.0, 1.0)
    seismic_parts = StructuralSynthesizer._seismic_moment_parts(gravity, qe, 1.0, 1.0)
    earthquake_factor = Dict(combo.name => combo.E for combo in asce7_strength_combinations)
    @test length(seismic) == length(seismic_parts) > 0
    for (action, part) in zip(seismic, seismic_parts)
        @test length(part) == 2
        @test sum(part) ≈ action.M
        @test part[2] ≈ earthquake_factor[action.combination] * qe.M
    end
    wind = WallAction(0.0, 1.0e5, 2.0e6)
    wind_actions = StructuralSynthesizer._wind_strength_actions(gravity, wind)
    wind_parts = StructuralSynthesizer._wind_moment_parts(gravity, wind)
    wind_factor = Dict(combo.name => combo.W for combo in asce7_strength_combinations)
    @test length(wind_actions) == length(wind_parts) > 0
    for (action, part) in zip(wind_actions, wind_parts)
        @test sum(part) ≈ action.M
        @test part[2] ≈ wind_factor[action.combination] * wind.M
    end
end

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

    # A carried ratio above the requirement is not kept. The shear here is
    # inside the concrete term, so both ratios return to the 0.0025 floor.
    carried = _ratio_wall(; ρl=0.0030, ρt=0.0081)
    select!(carried, [_ratio_action(1e3, 1e3, 1e3)], mat; hw)
    @test carried.ρl == 0.0025
    @test carried.ρt == 0.0025

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

    # A carried ratio above the grid is not kept when the cap is exceeded.
    # The wall stops at the top of the grid.
    above_caller = _ratio_wall(; ρt=0.03)
    select!(above_caller, [_ratio_action(1e3, Vu_over, 1e3)], mat; hw)
    @test above_caller.ρt == StructuralSynthesizer.ORDINARY_WALL_RHO_GRID[end]

    # Squat wall: ρt required for strength is 0.003. The selector drops the
    # carried 0.005 to the lightest covering grid ratio. ρl is Eq. (11.6.2)
    # at that ratio, and need not exceed the strength requirement. The
    # recorded minimum check uses that same floor.
    cap0s = wall_shear_capacity_si(fc, fyt, 4.0, 0.3, 0.0, 4.0; λ=λ)
    capps = wall_shear_capacity_si(fc, fyt, 4.0, 0.3, 1e-4, 4.0; λ=λ)
    Vu_squat = cap0s.ϕVn + 0.003 * (capps.ϕVn - cap0s.ϕVn) / 1e-4
    squat = _ratio_wall(; ρt=0.005, lw=4.0, h=4.0)
    ρ_squat = select!(squat, [_ratio_action(1e3, Vu_squat, 1e3)], mat; hw=4.0u"m")
    @test isapprox(ρ_squat, 0.003; rtol=1e-4)
    @test squat.ρt in StructuralSynthesizer.ORDINARY_WALL_RHO_GRID
    @test 0.003 - 1e-6 <= squat.ρt < 0.005
    # ACI 318-19 Eq. (11.6.2) at hw/ℓw = 1, capped by ρt required for strength.
    formula = 0.0025 + 0.5 * (2.5 - 1.0) * (squat.ρt - 0.0025)
    expect_l = min(max(formula, 0.0025), max(ρ_squat, 0.0025))
    @test isapprox(squat.ρl, expect_l; atol=1e-6)
    @test squat.ρl <= ρ_squat + 1e-6
    squat_records = check_ordinary_wall(squat, [_ratio_action(1e3, Vu_squat, 1e3)];
                                        material=mat, wall_index=1, case=:D,
                                        boundary=:pinned, hw=4.0u"m", ρt_strength=ρ_squat)
    min_l = only(r for r in squat_records if r.check == "min longitudinal reinf ρl")
    @test min_l.passed
    @test isapprox(min_l.demand, expect_l; atol=1e-6)
end

@testset "Building frame gravity share" begin
    ok = [StructuralSynthesizer.WallGravityShare(1, 10.0, 100.0, 0.10)]
    @test StructuralSynthesizer._refuse_building_frame_gravity!(:A3, ok) === ok
    @test StructuralSynthesizer._refuse_building_frame_gravity!(:A1, ok) === ok
    @test StructuralSynthesizer._refuse_building_frame_gravity!(:B6, ok) === ok
    @test StructuralSynthesizer._refuse_building_frame_gravity!(:B4, ok) === ok
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
    @test occursin(":A3", sprint(showerror, err))
    err4 = try
        StructuralSynthesizer._refuse_building_frame_gravity!(:B4, over)
        nothing
    catch e
        e
    end
    @test err4 isa ArgumentError
    @test occursin("20%", sprint(showerror, err4))
    @test occursin("C12.2.1", sprint(showerror, err4))
    @test occursin(":A1", sprint(showerror, err4))
end

"""In-plane shear demands for one check family, sorted, one vector per wall."""
function _stage_shear_demands(result, pred)
    return Dict(idx => sort(collect(r.demand for r in records
                                    if r.check == "in-plane shear" && pred(r)))
                for (idx, records) in result.checks)
end

@testset "A1 and A3 move only the seismic coefficient each row owns" begin
    # The row lookup runs before the mesh. A short building in D is not refused.
    # The table height is enforced from the story elevations.
    bare = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1))
    tall = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 20))
    function refuse(struc, row, sdc)
        params = DesignParameters(
            lateral=LateralDesign(; system=WallsSeismicSystem(row),
                                   assignment=BuildingUnit()),
            wall_inputs=_stage_inputs(; sdc=sdc),
            skip_visualization=true,
            jump_wall_thickness=false)
        try
            design_ordinary_walls!(struc, params)
            nothing
        catch e
            e
        end
    end
    for row in (:A1, :B4)
        err = refuse(tall, row, :D)
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("160", msg)
        @test !occursin("NP", msg)
    end
    msgF = sprint(showerror, refuse(tall, :A1, :F))
    @test occursin("100", msgF)
    @test !occursin("NP", msgF)
    @test occursin("NP", sprint(showerror, refuse(bare, :A3, :D)))

    # One story, so qz is one value. SDS = 0.20 sits above the Eq. 12.8-6
    # floor for both R = 4 and R = 5. SDS = 0.03 sits on that floor for both,
    # so strength shear no longer reads R. Drift drops the floor. A1 and A3
    # both have Cd/R = 1, so the design drift matches at either SDS.
    function design_row(row, SDS, SD1)
        struc = _stage_office_one_story()
        params = DesignParameters(
            lateral=LateralDesign(; system=WallsSeismicSystem(row),
                                   assignment=BuildingUnit()),
            wall_inputs=_stage_inputs(; SDS=SDS, S1=0.02, SD1=SD1, qz=[1.5]),
            skip_visualization=true,
            jump_wall_thickness=false)
        to_asap!(struc; params=params, diaphragms=:rigid)
        return struc, design_ordinary_walls!(struc, params)
    end
    function same_demands(a, b)
        @test collect(keys(a)) == collect(keys(b))
        for idx in keys(a)
            @test a[idx] ≈ b[idx]
        end
    end
    for (SDS, SD1, strength_follows_R) in ((0.20, 0.08, true), (0.03, 0.02, false))
        sa3, a3 = design_row(:A3, SDS, SD1)
        sa1, a1 = design_row(:A1, SDS, SD1)
        @test [w.thickness for w in sa3.walls] == [w.thickness for w in sa1.walls]
        for (i, w) in enumerate(sa1.walls)
            @test w.ρl <= sa3.walls[i].ρl + 1e-12
            @test w.ρt <= sa3.walls[i].ρt + 1e-12
        end
        @test length(a3.drift) == length(a1.drift)
        for i in eachindex(a3.drift)
            @test a3.drift[i].drift_m ≈ a1.drift[i].drift_m rtol = 1e-5
            @test a3.drift[i].story == a1.drift[i].story
            @test a3.drift[i].direction == a1.drift[i].direction
        end
        # θ reads the drift, so the §12.8.7 factor matches too. It is not
        # required to be 1: a larger SDS can push θ past 0.10.
        @test a3.pdelta_multipliers ≈ a1.pdelta_multipliers
        dead(r) = r.case === :D
        wind(r) = startswith(string(r.case), "W")
        seismic(r) = startswith(string(r.case), "QE")
        same_demands(_stage_shear_demands(a3, dead), _stage_shear_demands(a1, dead))
        same_demands(_stage_shear_demands(a3, wind), _stage_shear_demands(a1, wind))
        d3 = _stage_shear_demands(a3, seismic)
        d1 = _stage_shear_demands(a1, seismic)
        @test sort(collect(keys(d3))) == sort(collect(keys(d1)))
        # A pier's in-plane shear reads the earthquake along the pier.
        # The other direction leaves that shear at the gravity combination,
        # so those records match. The loaded direction scales with R above
        # the Eq. 12.8-6 floor and matches on the floor.
        seismic_scaled = false
        for idx in keys(d3)
            @test length(d3[idx]) == length(d1[idx])
            @test !isempty(d3[idx])
            for (v3, v1) in zip(d3[idx], d1[idx])
                if strength_follows_R && !isapprox(v1, v3; rtol=1e-6)
                    @test v1 ≈ v3 * (4 / 5) rtol = 0.02
                    seismic_scaled = true
                else
                    @test v1 ≈ v3 rtol = 0.02
                end
            end
        end
        @test seismic_scaled == strength_follows_R
        for records in values(a1.checks)
            @test !any(r -> occursin("18.10.6", r.check) || occursin("18.10.6", r.clause),
                       records)
        end
    end
end

@testset "Interactive system, row F" begin
    # The frame beside the walls is what drifts past θmax. Its columns stand
    # at the pier ends, so they stay instead of being parked.
    struc = _stage_office(; park_wall_overlaps=false)
    params = DesignParameters(
        lateral=LateralDesign(; system=InteractiveShearWallFrameSystem(),
                               assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(),
        skip_visualization=true,
        jump_wall_thickness=false)
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

@testset "Gravity axial sizes the piers" begin
    struc = _stage_office_unstable()
    @test !isempty(struc.walls)
    for wall in struc.walls
        wall.ρl = 0.001
        wall.ρt = 0.001
    end
    params = DesignParameters(diaphragm_mode=:rigid, skip_visualization=true,
                              jump_wall_thickness=false)
    to_asap!(struc; params=params, diaphragms=:rigid)
    result = design_ordinary_walls!(struc, params)
    @test result isa OrdinaryWallResult
    @test struc.ordinary_wall_result === result
    @test isempty(result.drift)
    @test isempty(result.interactive_shear)
    @test isempty(result.frame_members)
    @test sort(collect(keys(result.checks))) == collect(eachindex(struc.walls))
    for (idx, records) in result.checks
        @test any(r -> r.case === :D && occursin("bearing wall", r.check), records)
        @test any(r -> r.case === :D && r.check == "in-plane shear", records)
        @test !any(r -> startswith(string(r.case), "W") ||
                       startswith(string(r.case), "QE"), records)
        @test all(r -> r.wall_index == idx, records)
    end
    @test all(w -> w.ρl >= 0.0025 - 1e-12 && w.ρt >= 0.0025 - 1e-12, struc.walls)
    @test all(w -> w.thickness == 0.3u"m", struc.walls)
end

@testset "A pierced wall is checked with the building" begin
    # One story, so the lintel is not merged with a wall above it.
    struc = _stage_office_one_story()
    @test length(struc.walls) >= 2
    wall = first(struc.walls)
    L = hypot(wall.x2 - wall.x1, wall.y2 - wall.y1)
    width = min(3.0, 0.5 * L)
    s0 = 0.5 * (L - width)
    # Bands 0.4 m deep. The clear span is longer than four times that depth,
    # so each band is an ordinary beam.
    wall.openings = [WallOpening(s0, 0.4, width, 3.2, :window)]
    params = DesignParameters(diaphragm_mode=:rigid, skip_visualization=true,
                              jump_wall_thickness=false)
    to_asap!(struc; params=params, diaphragms=:rigid)
    result = design_ordinary_walls!(struc, params)
    idx = findfirst(w -> w === wall, struc.walls)
    records = result.checks[idx]
    @test any(r -> r.check == "spandrel flexure" && r.passed, records)
    @test any(r -> r.check == "spandrel shear" && r.passed, records)
    # A vertical pier is a wall segment. Its shear record carries the cut face.
    @test any(r -> occursin("in-plane shear", r.check), records)
    @test !any(r -> r.check == "horizontal segment unchecked", records)
    for (j, other) in enumerate(struc.walls)
        j == idx && continue
        @test any(r -> r.case === :D && occursin("bearing wall", r.check), result.checks[j])
        @test any(r -> r.check == "in-plane shear", result.checks[j])
        @test !any(r -> r.check == "spandrel flexure", result.checks[j])
        @test isempty(other.openings)
    end
end

@testset "A window on the ground story leaves the stories above solid" begin
    struc = _stage_office_unstable()
    wall = only(w for w in struc.walls if w.story == 0)
    L = hypot(wall.x2 - wall.x1, wall.y2 - wall.y1)
    width = min(3.0, 0.5 * L)
    s0 = 0.5 * (L - width)
    wall.openings = [WallOpening(s0, 0.4, width, 3.2, :window)]
    params = DesignParameters(diaphragm_mode=:rigid, skip_visualization=true,
                              jump_wall_thickness=false)
    to_asap!(struc; params=params, diaphragms=:rigid)
    result = design_ordinary_walls!(struc, params)
    idx = findfirst(w -> w === wall, struc.walls)
    records = result.checks[idx]
    @test any(r -> r.check == "spandrel flexure" && r.passed, records)
    @test any(r -> r.check == "spandrel shear" && r.passed, records)
    @test !any(r -> r.check == "horizontal segment unchecked", records)
    above = 0
    for (j, other) in enumerate(struc.walls)
        other.story == 0 && continue
        above += 1
        @test isempty(other.openings)
        @test any(r -> r.case === :D && occursin("bearing wall", r.check), result.checks[j])
        @test any(r -> r.check == "in-plane shear", result.checks[j])
        @test !any(r -> r.check == "spandrel flexure", result.checks[j])
        @test !any(r -> r.check == "horizontal segment unchecked", result.checks[j])
    end
    @test above >= 2
end

@testset "Wall tributaries without columns; a flexible floor refuses a strut" begin
    # With the columns removed, every wall that bounds a cell keeps that
    # cell's complement. Corner columns otherwise keep the larger Voronoi
    # region and the complement on the upper floors is empty.
    bare = _stage_office_unstable()
    empty!(bare.columns)
    StructuralSynthesizer.compute_column_tributaries!(bare)
    @test all(w -> StructuralSynthesizer.wall_tributary_area(w) > 0, bare.walls)

    struc = _stage_office_unstable()
    params = DesignParameters(diaphragm_mode=:flexible, skip_visualization=true,
                              jump_wall_thickness=false)
    to_asap!(struc; params=params, diaphragms=:flexible)
    @test isempty(struc.asap_rigid_links)
    push!(struc.struts, Strut([1], 4.0u"m"))
    err = try
        to_asap!(struc; params=params, diaphragms=:flexible)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("strut", msg)
    @test !occursin("walls or struts", msg)
end

"""Thickness and reinforcement, ordered by plan so the grouping runs can be compared."""
function _stage_wall_rows(struc)
    rows = [(story=w.story, x1=w.x1, y1=w.y1, x2=w.x2, y2=w.y2,
             t=ustrip(u"m", w.thickness), ρl=w.ρl, ρt=w.ρt) for w in struc.walls]
    return sort(rows; by=r -> (r.story, r.y1, r.x1, r.y2, r.x2))
end

@testset "Symmetric walls agree under every thickness grouping" begin
    function sized(grouping)
        struc = _stage_office_one_story()
        for wall in struc.walls
            wall.thickness = 0.10u"m"
        end
        params = DesignParameters(
            diaphragm_mode=:rigid, skip_visualization=true,
            jump_wall_thickness=true, wall_thickness_grouping=grouping,
            wall_thickness=0.10u"m")
        to_asap!(struc; params=params, diaphragms=:rigid)
        result = design_ordinary_walls!(struc, params)
        passed = all(r -> r.passed, Iterators.flatten(values(result.checks)))
        return (rows=_stage_wall_rows(struc), passed=passed,
                settled=!haskey(struc.stage_diagnostics, :walls),
                t_param=ustrip(u"m", params.wall_thickness))
    end
    runs = Dict(g => sized(g) for g in WALL_THICKNESS_GROUPINGS)
    @test all(run.passed for run in values(runs))
    @test all(run.settled for run in values(runs))
    @test all(row.t > 0.10 + 1e-4 for row in runs[:all].rows)
    for grouping in WALL_THICKNESS_GROUPINGS
        @testset "$grouping" begin
            @test length(runs[grouping].rows) == length(runs[:all].rows)
            for (got, ref) in zip(runs[grouping].rows, runs[:all].rows)
                @test got.t ≈ ref.t atol=1e-9
                @test got.ρl ≈ ref.ρl atol=1e-9
                @test got.ρt ≈ ref.ρt atol=1e-9
            end
            @test runs[grouping].t_param ≈ runs[:all].t_param atol=1e-9
        end
    end
end

"""One story, the first wall thin and the others already thick."""
function _stage_mixed_office()
    struc = _stage_office_one_story()
    length(struc.walls) >= 2 || error("one-story office has one wall")
    struc.walls[1].thickness = 0.10u"m"
    for wall in struc.walls[2:end]
        wall.thickness = 0.30u"m"
    end
    return struc
end

function _stage_design_grouping(struc, grouping)
    params = DesignParameters(
        diaphragm_mode=:rigid, skip_visualization=true,
        jump_wall_thickness=true, wall_thickness_grouping=grouping,
        wall_thickness=0.10u"m")
    to_asap!(struc; params=params, diaphragms=:rigid)
    return params, design_ordinary_walls!(struc, params)
end

@testset "A thin wall thickens alone when the grouping splits it off" begin
    probe = _stage_mixed_office()
    thin = 1
    for grouping in WALL_THICKNESS_GROUPINGS
        @testset "$grouping" begin
            ids = wall_thickness_groups(probe.walls; grouping)
            shares = any(i -> i != thin && ids[i] == ids[thin], eachindex(probe.walls))
            struc = _stage_mixed_office()
            if shares && grouping !== :all
                err = try
                    _stage_design_grouping(struc, grouping)
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin("more than one thickness", sprint(showerror, err))
            elseif grouping === :all
                _, result = _stage_design_grouping(struc, grouping)
                @test ustrip(u"m", struc.walls[thin].thickness) ≈ 0.10 atol=1e-6
                @test all(w -> ustrip(u"m", w.thickness) ≈ 0.30, struc.walls[2:end])
                @test !all(r -> r.passed, Iterators.flatten(values(result.checks)))
            else
                _, result = _stage_design_grouping(struc, grouping)
                @test ustrip(u"m", struc.walls[thin].thickness) > 0.10 + 1e-4
                @test all(w -> ustrip(u"m", w.thickness) ≈ 0.30, struc.walls[2:end])
                @test all(r -> r.passed, Iterators.flatten(values(result.checks)))
                @test all(w -> w.ρl >= 0.0025 - 1e-12 && w.ρt >= 0.0025 - 1e-12,
                          struc.walls)
            end
        end
    end
end

