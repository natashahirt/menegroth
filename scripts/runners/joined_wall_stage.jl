#=
Run design_ordinary_walls! on joined plans.

The ordinary-wall stage tests keep wall ends apart, so the corner record is
never written. This runner claims grid edges that share corners and prints
the assemblies, the clear lengths, and every shear-friction, out-of-plane,
and failing record.

    julia --project=StructuralSynthesizer scripts/runners/joined_wall_stage.jl
=#

using Printf
using Unitful
using Meshes
using StructuralSynthesizer

const VAULT = VaultOptions(rise=1.0u"m", thickness=0.05u"m")

function inputs()
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
    )
end

function xy(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function same_plan(skel, eidx, x1, y1, x2, y2)
    v1, v2 = skel.edge_indices[eidx]
    ax, ay = xy(skel, v1)
    bx, by = xy(skel, v2)
    return (hypot(ax - x1, ay - y1) <= 1e-6 && hypot(bx - x2, by - y2) <= 1e-6) ||
           (hypot(ax - x2, ay - y2) <= 1e-6 && hypot(bx - x1, by - y1) <= 1e-6)
end

function claim!(skel, beams, x1, y1, x2, y2)
    for story in 0:2
        edges = [e for e in skel.stories[story].edges
                 if e in beams && same_plan(skel, e, x1, y1, x2, y2)]
        length(edges) == 1 || error("$story: $(length(edges)) edges on ($x1,$y1)–($x2,$y2)")
        eidx = only(edges)
        filter!(!=(eidx), skel.groups_edges[:beams])
        delete!(beams, eidx)
        walls = get!(skel.groups_edges, :walls, Int[])
        eidx in walls || push!(walls, eidx)
    end
    return skel
end

function office(segments)
    skel = gen_medium_office(12.0u"m", 12.0u"m", 4.0u"m", 2, 2, 3)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    for seg in segments
        claim!(skel, beams, seg...)
    end
    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=VAULT,
        wall_thickness=0.3u"m")
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    return struc
end

function line(w)
    return @sprintf("(%.1f,%.1f)–(%.1f,%.1f) story %d", w.x1, w.y1, w.x2, w.y2, w.story)
end

function report(name, segments)
    println()
    println("=" ^ 72)
    println(name)
    println("=" ^ 72)
    struc = office(segments)
    params = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=inputs(),
        skip_visualization=true,
    )
    to_asap!(struc; params, diaphragms=:rigid)
    println("walls: ", length(struc.walls))
    for (i, w) in enumerate(struc.walls)
        clear = joined_clear_length(w, struc.walls, i)
        println(@sprintf("  %2d  %s  centerline %.3f m  clear %.3f m  ρl %.4f  ρt %.4f",
                         i, line(w), hypot(w.x2 - w.x1, w.y2 - w.y1), clear, w.ρl, w.ρt))
    end
    for asm in struc.wall_mesh.assemblies
        println("assembly story ", asm.story, " joined=", asm.joined,
                " walls ", asm.wall_indices)
        asm.joined || continue
        for corner in assembly_corners(struc.walls, asm)
            println(@sprintf("  corner (%.2f, %.2f) φ=%.1f° walls %s",
                             corner.x, corner.y, rad2deg(corner.φ), corner.wall_indices))
        end
    end
    local result
    try
        result = design_ordinary_walls!(struc, params)
    catch err
        println("DESIGN THREW:")
        showerror(stdout, err, catch_backtrace())
        println()
        return nothing
    end
    println("θmax seen: ", result.max_story_stability)
    println("drift multipliers: ", result.pdelta_multipliers)
    nfail = 0
    for (idx, records) in sort(collect(result.checks); by=first)
        w = struc.walls[idx]
        fails = filter(r -> !r.passed, records)
        nfail += length(fails)
        interesting = filter(records) do r
            r.check == "shear friction" ||
                occursin("out-of-plane", r.check) ||
                occursin("corner", r.check) ||
                !r.passed
        end
        isempty(interesting) && continue
        println("wall ", idx, "  ", line(w), "  ρl ", w.ρl, "  ρt ", w.ρt)
        for r in interesting
            flag = r.passed ? "pass" : "FAIL"
            println(@sprintf("  %-6s %-28s %s/%s  demand %.4g  capacity %.4g  ratio %.3f  %s",
                             flag, r.check, r.case, r.combination,
                             r.demand, r.capacity, r.ratio, r.clause))
        end
    end
    println("failing records: ", nfail)
    return result
end

const L = (
    (0.0, 0.0, 6.0, 0.0),
    (0.0, 0.0, 0.0, 6.0),
)
const BOX = (
    (0.0, 0.0, 6.0, 0.0),
    (6.0, 0.0, 6.0, 6.0),
    (6.0, 6.0, 0.0, 6.0),
    (0.0, 6.0, 0.0, 0.0),
)

report("L at the origin, three stories", L)
report("6 m square core, three stories", BOX)
