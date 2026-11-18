# Probe: with column sections rolled so the two models are the same structure,
# do the aligned and rotated offices get the same ELF, wind, and gravity loads?
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/skew_load_probe.jl

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Unitful, Asap, StructuralSynthesizer, StructuralSizer
import Meshes
const SS = StructuralSynthesizer
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "analyze", "skew_plan_fixtures.jl"))

function inputs(directions)
    OrdinaryWallInputs(;
        directions, qz=[1.0, 1.5, 2.0], qh=2.0, Kd=1.0, G=0.85, GCpi=0.18,
        roof=:Lr, method=:sds, SDS=0.05, S1=0.02, Ie=1.0, T=0.4, β=1.0,
        SD1=0.02, TL=8.0, rho=1.0, sdc=:B, risk_category=:II,
        drift_system=:other, boundary=:pinned, material=RC_4000_60,
        model_uses_cracked_section_stiffness=true,
        sustained_lateral_loads=false, sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false, type5_horizontal_irregularity=false,
        orthogonal_combination=false, orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false, pdelta_included_in_member_forces=false)
end
params(axis, dirs) = DesignParameters(
    lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit(), plan_axis=axis),
    wall_inputs=inputs(dirs), diaphragm_mode=:rigid, skip_visualization=true)

function build(map, p, roll; tributary_axis=nothing)
    struc = _skew_office(map; floor_type=:vault)
    if !isnothing(tributary_axis)
        for c in struc.cells
            c.spans = SS.get_cell_spans(struc.skeleton, c.face_idx; axis=tributary_axis)
        end
    end
    println("span axes: ", unique(c.spans.axis for c in struc.cells))
    to_asap!(struc; params=p, diaphragms=:rigid)
    SS.prepare_lateral_model!(struc, p.lateral)
    m = struc.asap_model
    for el in m.frame_elements
        a = ustrip.(u"m", el.nodeStart.position)
        b = ustrip.(u"m", el.nodeEnd.position)
        hypot(b[1] - a[1], b[2] - a[2]) < 1e-9 && (el.Ψ = roll)
    end
    Asap.process!(m)
    Asap.solve!(m, struc.asap_rigid_links; reprocess=false)
    return struc
end

function analyses(struc, p)
    inp = p.wall_inputs
    sys = SS.ordinary_concrete_seismic_system(SS.table_12_2_1_row(WallsSeismicSystem(:A3)), inp.sdc)
    basic = SS.solve_gravity_basic_cases(struc; roof=inp.roof, params=p)
    wind = SS.wind_story_analysis(struc; directions=inp.directions, qz=inp.qz, qh=inp.qh,
        Kd=inp.Kd, G=inp.G, GCpi=inp.GCpi, extra_directions=inp.extra_directions)
    elf = SS.elf_story_analysis(struc; method=inp.method, SDS=inp.SDS, S1=inp.S1, R=sys.R,
        Ie=inp.Ie, T=inp.T, Cd=sys.Cd, β=inp.β, SD1=inp.SD1, TL=inp.TL, Sa=inp.Sa, Ω0=sys.Ω0,
        between=inp.between, Ry=sys.R, Cdy=sys.Cd, Ω0y=sys.Ω0, plan_axis=p.lateral.plan_axis)
    return basic, wind, elf
end

rel(a, b) = abs(a - b) / max(abs(a), abs(b), 1e-12)

α = deg2rad(30)
e1 = (cos(α), sin(α)); e2 = (-sin(α), cos(α))
p0 = params((1.0, 0.0), ((1.0, 0.0), (0.0, 1.0)))
p1 = params(e1, (e1, e2))
s0 = build((x, y) -> (x, y), p0, 0.0)
s1 = build(_skew_rotation(α), p1, α;
           tributary_axis=(get(ENV, "SKEW_SPAN_AXIS", "auto") == "e2" ? e2 : nothing))
b0, w0, l0 = analyses(s0, p0)
b1, w1, l1 = analyses(s1, p1)
unrot(p) = (p[1] * e1[1] + p[2] * e1[2], p[1] * e2[1] + p[2] * e2[2])

out = joinpath(@__DIR__, "..", "..", "logs", "skew_load_probe.txt")
open(out, "w") do io
    println(io, "== ELF levels")
    for (a, b) in zip(l0.levels, l1.levels)
        println(io, "story ", a.story, "  W ", a.weight_kN, " / ", b.weight_kN, "  rel ", rel(a.weight_kN, b.weight_kN),
                "  Px ", a.px_kN, " / ", b.px_kN)
        println(io, "   com ", a.center_of_mass, " / unrot ", unrot(b.center_of_mass),
                "  plan ", a.plan_m, " / ", b.plan_m, "  bounds ", a.bounds_m, " / ", b.bounds_m)
        println(io, "   master ", ustrip.(u"m", a.master.position), " / ", ustrip.(u"m", b.master.position))
    end
    println(io, "\n== ELF cases")
    for (a, b) in zip(l0.cases, l1.cases)
        println(io, a.direction, " ", a.purpose, " ", a.torsion, "  V ", a.V_kN, " / ", b.V_kN,
                "  Fx ", a.Fx_kN, " / ", b.Fx_kN, "  Mz ", a.Mz_kN_m, " / ", b.Mz_kN_m,
                "  drift rel ", maximum(rel.(a.design_drift_m, b.design_drift_m)))
    end
    println(io, "\n== wind cases (forces in each building's plan axes)")
    for (a, b) in zip(w0.cases, w1.cases)
        Fa = [(a.Fx_kN[i], a.Fy_kN[i]) for i in eachindex(a.Fx_kN)]
        Fb = [unrot((b.Fx_kN[i], b.Fy_kN[i])) for i in eachindex(b.Fx_kN)]
        worst = maximum(max(abs(x[1] - y[1]), abs(x[2] - y[2])) for (x, y) in zip(Fa, Fb))
        println(io, a.kind, "  F ", Fa, " / ", Fb, "  Mz ", a.Mz_kN_m, " / ", b.Mz_kN_m, "  max|ΔF| ", worst)
    end
    println(io, "\n== gravity pier actions")
    for (k, sym) in enumerate(b0.symbols)
        for (pa, pb) in zip(s0.wall_mesh.piers, s1.wall_mesh.piers)
            wa, wb = s0.walls[pa.wall_index], s1.walls[pb.wall_index]
            A = SS.pier_wall_action(wa, pa, b0.u[k]; loads=b0.loads[k], fixed_end_from_loads=true)
            B = SS.pier_wall_action(wb, pb, b1.u[k]; loads=b1.loads[k], fixed_end_from_loads=true)
            println(io, sym, " wall ", pa.wall_index, "  N ", A.N, " / ", B.N, "  V ", A.V, " / ", B.V,
                    "  M ", A.M, " / ", B.M)
        end
        tot(ls) = sum((ustrip(u"kN", l.value[3]) for l in ls if l isa Asap.NodeForce); init=0.0)
        println(io, sym, " total NodeForce Fz ", tot(b0.loads[k]), " / ", tot(b1.loads[k]),
                "  n loads ", length(b0.loads[k]), " / ", length(b1.loads[k]),
                "  types ", unique(typeof.(b0.loads[k])), " / ", unique(typeof.(b1.loads[k])))
    end
end
println("wrote ", out)
