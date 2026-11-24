# Fast, observable smoke check for the dual-system stage backbone.
#
# Builds the _stage_office fixture (steel moment frame + concrete-wall core — a
# genuine dual system), processes it, and runs design_dual_system!. Prints the
# drift, θ, moment-frame designation, and the carried Table 12.2-1 row. This is
# a dev tool; the permanent assertions live in test_ordinary_wall_stage.jl.
#
#   julia --project=StructuralSynthesizer scripts/runners/dual_stage_smoke.jl

using Unitful, Meshes, Asap, StructuralSynthesizer, StructuralSizer

const _VAULT = VaultOptions(rise=1.0u"m", thickness=0.05u"m")
const _BOTH_AXES = ((0.0, 0.0, 6.0, 0.0), (6.0, 12.0, 12.0, 12.0),
                    (12.0, 0.0, 12.0, 6.0), (0.0, 6.0, 0.0, 12.0))

_xy(skel, v) = (ustrip(u"m", Meshes.coords(skel.vertices[v]).x),
                ustrip(u"m", Meshes.coords(skel.vertices[v]).y))

function _horizontal(skel, e)
    v1, v2 = skel.edge_indices[e]
    c1 = Meshes.coords(skel.vertices[v1]); c2 = Meshes.coords(skel.vertices[v2])
    return abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

function _same_plan(skel, e, x1, y1, x2, y2)
    v1, v2 = skel.edge_indices[e]
    ax, ay = _xy(skel, v1); bx, by = _xy(skel, v2)
    return (hypot(ax - x1, ay - y1) <= 1e-6 && hypot(bx - x2, by - y2) <= 1e-6) ||
           (hypot(ax - x2, ay - y2) <= 1e-6 && hypot(bx - x1, by - y1) <= 1e-6)
end

function _claim_stacked_wall!(skel, story, beams, x1, y1, x2, y2)
    edges = [e for e in skel.stories[story].edges
             if e in beams && _horizontal(skel, e) && _same_plan(skel, e, x1, y1, x2, y2)]
    eidx = only(edges)
    filter!(!=(eidx), skel.groups_edges[:beams])
    delete!(beams, eidx)
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)
    return eidx
end

function _grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    any(e -> e in beams && _horizontal(skel, e), skel.stories[0].edges) && return skel
    z0 = skel.stories_z[1]
    for e in skel.stories[1].edges
        (e in beams && _horizontal(skel, e)) || continue
        v1, v2 = skel.edge_indices[e]
        x1, y1 = _xy(skel, v1); x2, y2 = _xy(skel, v2)
        StructuralSynthesizer.add_element!(skel, Meshes.Segment(
            Meshes.Point(x1 * u"m", y1 * u"m", z0), Meshes.Point(x2 * u"m", y2 * u"m", z0));
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
            x, y = _xy(skel, v)
            push!(cycle, grade_of[(round(x; digits=6), round(y; digits=6))])
        end
        StructuralSynthesizer.add_face!(skel, Meshes.Ngon(skel.vertices[cycle]...);
                                        group=:grade, level_idx=0, v_indices=cycle)
    end
    return skel
end

function _ground_edge(skel, beams, x1, y1, x2, y2)
    ground = [e for e in skel.stories[0].edges if e in beams && _horizontal(skel, e)]
    only([e for e in ground if _same_plan(skel, e, x1, y1, x2, y2)])
end

function _claim_segments!(skel, beams, segments)
    for (x1, y1, x2, y2) in segments
        e0 = _ground_edge(skel, beams, x1, y1, x2, y2)
        v1, v2 = skel.edge_indices[e0]
        ax, ay = _xy(skel, v1); bx, by = _xy(skel, v2)
        for story in 0:2
            _claim_stacked_wall!(skel, story, beams, ax, ay, bx, by)
        end
    end
    return skel
end

function stage_office(; segments=_BOTH_AXES, park=true, bays=2, L=12.0u"m")
    skel = gen_medium_office(L, L, 4.0u"m", bays, bays, 3)
    _grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    _claim_segments!(skel, beams, segments)
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type=:vault, material=NWC_4000, floor_opts=_VAULT,
                wall_thickness=0.3u"m", park_wall_overlaps=park)
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end

function inputs(; sdc=:D, material=RC_4000_60)
    return OrdinaryWallInputs(;
        directions=((1.0, 0.0), (0.0, 1.0)), qz=[1.0, 1.5, 2.0], qh=2.0, Kd=1.0,
        G=0.85, GCpi=0.18, roof=:Lr, method=:sds, SDS=0.05, S1=0.02, Ie=1.0, T=0.4,
        β=1.0, SD1=0.02, TL=8.0, rho=1.0, sdc=sdc, risk_category=:II, drift_system=:other,
        boundary=:pinned, material=material, model_uses_cracked_section_stiffness=true,
        sustained_lateral_loads=false, sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false, type5_horizontal_irregularity=false,
        orthogonal_combination=false, orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false, pdelta_included_in_member_forces=false)
end

function main()
    # Probe fixture configs for one with real column-to-column girders + a core.
    configs = [
        (name="2bay/4wall/park", kw=(; segments=_BOTH_AXES, park=true, bays=2, L=12.0u"m")),
        (name="2bay/4wall/nopark", kw=(; segments=_BOTH_AXES, park=false, bays=2, L=12.0u"m")),
        (name="2bay/2wall/nopark", kw=(; segments=(_BOTH_AXES[1], _BOTH_AXES[2]), park=false, bays=2, L=12.0u"m")),
        (name="3bay/2wall/nopark", kw=(; segments=((0.0, 0.0, 6.0, 0.0), (12.0, 18.0, 18.0, 18.0)), park=false, bays=3, L=18.0u"m")),
    ]
    struc = nothing
    for c in configs
        s = try
            stage_office(; c.kw...)
        catch e
            println("  [", c.name, "] build failed: ", sprint(showerror, e))
            continue
        end
        g = count(b -> b.role === :girder, s.beams)
        println("  [", c.name, "] walls=", length(s.walls), " cols=", length(s.columns),
                " beams=", length(s.beams), " girders=", g, " roles=", unique(b.role for b in s.beams))
        if g > 0 && !isempty(s.walls) && struc === nothing
            struc = s
            println("  -> using ", c.name)
        end
    end
    struc === nothing && (println("NO VIABLE FIXTURE (girders + walls)"); return)
    for b in struc.beams
        b.role === :girder && (b.lateral_role = :moment_frame)
    end
    # Assign steel W-shapes to the moment-frame members (the dual stage normally
    # runs after steel member sizing; here we install sections so the AISC
    # beam-column check has real sections to check).
    for c in struc.columns
        c.base.section = W("W14X145")
    end
    for b in struc.beams
        b.role === :girder && (b.base.section = W("W24X84"))
    end
    dual = DesignParameters(
        lateral=LateralDesign(; system=DualSystem(; moment_frame=:steel_smf, wall=:special_rc),
                              assignment=BuildingUnit()),
        wall_inputs=inputs(; sdc=:D), skip_visualization=true, jump_wall_thickness=false)
    to_asap!(struc; params=dual, diaphragms=:rigid)
    println("model processed=", struc.asap_model.processed)
    result = design_dual_system!(struc, dual)
    println("=== design_dual_system! result ===")
    println("row_x=", result.row_x, " row_y=", result.row_y)
    println("moment_frame source=", result.moment_frame.source,
            " beams=", length(result.moment_frame.beams),
            " columns=", length(result.moment_frame.columns))
    println("drift entries=", length(result.drift),
            " pdelta_multipliers=", length(result.pdelta_multipliers))
    println("max_story_stability θ=", result.max_story_stability)
    println("pending=", result.pending)
    println("=== frame_members (AISC App. 8 B1/B2) ===")
    println("checked=", length(result.frame_members),
            " failing=", count(c -> !c.passed, result.frame_members))
    for c in result.frame_members
        println("  ", c.kind, " #", c.index, " passed=", c.passed,
                " ratio=", round(c.governing_ratio; digits=3),
                " check=", c.governing_check, " @ ", c.case_label)
    end
    println("=== frame_shares (§12.2.5.1 in-loop proxy) ===")
    for c in result.frame_shares
        println("  story ", c.story, " ", c.direction, " share=",
                round(c.share; digits=3), " passed=", c.passed)
    end
    println("=== capability gate (25% frame-only) ===")
    println("stability θ checks=", length(result.capability_stability),
            " over θmax=", count(c -> !c.passed, result.capability_stability))
    for c in result.capability_stability
        println("  story ", c.story, " ", c.direction, " θ=", round(c.θ; digits=4),
                " θmax=", round(c.θmax; digits=4), " passed=", c.passed)
    end
    println("members checked=", length(result.capability_members),
            " failing=", count(c -> !c.passed, result.capability_members))
    for c in result.capability_members
        println("  ", c.kind, " #", c.index, " passed=", c.passed,
                " ratio=", round(c.governing_ratio; digits=3))
    end
    println("stage_diagnostics[:dual]=", get(struc.stage_diagnostics, :dual, "<none>"))
    println("SMOKE OK")
end

main()
