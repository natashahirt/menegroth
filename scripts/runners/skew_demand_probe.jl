# Probe: where do the rotated-office pier demands differ from the axis-aligned run?
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/skew_demand_probe.jl

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Unitful, Asap, StructuralSynthesizer, StructuralSizer
import Meshes
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

"""Turn every vertical frame element's section by `roll` about Z, then re-solve."""
function roll_columns!(struc, roll)
    m = struc.asap_model
    n = 0
    for el in m.frame_elements
        a = ustrip.(u"m", el.nodeStart.position)
        b = ustrip.(u"m", el.nodeEnd.position)
        hypot(b[1] - a[1], b[2] - a[2]) < 1e-9 || continue
        el.Ψ = roll
        n += 1
    end
    Asap.process!(m)
    Asap.solve!(m, struc.asap_rigid_links; reprocess=false)
    return n
end

function run(map, p; roll=nothing)
    struc = _skew_office(map; floor_type=:vault)
    to_asap!(struc; params=p, diaphragms=:rigid)
    isnothing(roll) || println("rolled ", roll_columns!(struc, roll), " vertical elements")
    return struc, design_ordinary_walls!(struc, p)
end

α = deg2rad(30)
e1 = (cos(α), sin(α)); e2 = (-sin(α), cos(α))
s0, r0 = run((x, y) -> (x, y), params((1.0, 0.0), ((1.0, 0.0), (0.0, 1.0))))
s1, r1 = run(_skew_rotation(α), params(e1, (e1, e2)); roll=(haskey(ENV, "SKEW_ROLL_DEG") ? deg2rad(parse(Float64, ENV["SKEW_ROLL_DEG"])) : nothing))

out = joinpath(@__DIR__, "..", "..", "logs", "skew_demand_probe.txt")
open(out, "w") do io
    println(io, "max |u| aligned ", maximum(abs, s0.asap_model.u), "  rotated ", maximum(abs, s1.asap_model.u))
    for (a, b) in zip(r0.drift, r1.drift)
        println(io, "drift ", a.story, " ", a.direction, " ", a.torsion, "  ", a.drift_m, "  ", b.drift_m)
    end
    tally = Dict{Tuple{String, String}, Vector{Float64}}()
    for idx in sort(collect(keys(r0.checks)))
        w0, w1 = s0.walls[idx], s1.walls[idx]
        println(io, "\nwall $idx story $(w0.story) dir $(r0.checks[idx][1].direction)  ",
                "aligned ($(w0.x1),$(w0.y1))-($(w0.x2),$(w0.y2))  rotated ($(w1.x1),$(w1.y1))-($(w1.x2),$(w1.y2))")
        for (x, y) in zip(r0.checks[idx], r1.checks[idx])
            rel = abs(x.demand - y.demand) / max(abs(x.demand), abs(y.demand), 1.0)
            fam = first(split(string(x.case), "_"))
            push!(get!(tally, (string(x.check), fam), Float64[]), rel)
            rel > 2e-3 || continue
            println(io, "  rel ", round(rel; sigdigits=3), "  ", x.check, "  A ", x.case, " ", x.demand,
                    "  B ", y.case, " ", y.demand)
        end
    end
    println(io, "\nworst rel by (check, case family):")
    for k in sort(collect(keys(tally)))
        println(io, "  ", k, "  n=", length(tally[k]), "  max=", round(maximum(tally[k]); sigdigits=3))
    end
end
println("wrote ", out)
