#=
Hand numbers for the saved core-office mat.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralSynthesizer \
        scripts/runners/check_core_office_mat.jl [design.mgdesign]

Prints the stored mat, the service load on its wall lines, and the
cantilever moment and one-way shear the rigid method uses. Also counts
shell triangles whose plan area is below 1e-8 m².
=#

using Printf
using Unitful
using StructuralSynthesizer

const SS = StructuralSynthesizer
const SZ = StructuralSizer

const path = isempty(ARGS) ?
    joinpath(@__DIR__, "..", "..", "logs", "core_office_v3.mgdesign") :
    ARGS[1]

design = SS.load_design(path)
struc = design.structure
fp = design.params.foundation_options
soil = fp.soil
opts = fp.options.mat_params

SS.Asap.solve!(struc.asap_model)
SS.initialize_supports!(struc)
demands_all = SS.support_demands(struc)
groups = SS.collect_grade_wall_groups(struc)
mat = only(f for f in struc.foundations if f.foundation_type == :mat)
r = mat.result
group = only(g for g in groups if g.group.kind == :mat)

Ps = sum(smp.Ps for leg in group.legs for smp in leg.samples)
Pu = sum(smp.Pu for leg in group.legs for smp in leg.samples)
area = r.B * r.L_ftg
cap = soil.qa * area

positions = NTuple{2, typeof(1.0u"m")}[]
demands = SZ.FoundationDemand[]
plan = SZ._mat_plan_sizing(positions, opts; demands = demands, soil = soil,
                           walls = group.legs)
lips = SZ._mat_clear_lips(group.legs, plan)
qu = Pu / (r.B * r.L_ftg)
box = plan.B - 2 * plan.overhang
oh_stored = (r.B - box) / 2
doh = ustrip(u"m", plan.overhang - oh_stored)

println(@sprintf("stored mat  %.4f × %.4f × %.4f m   d %.4f m   util %.4f   %s",
                 ustrip(u"m", r.B), ustrip(u"m", r.L_ftg), ustrip(u"m", r.D),
                 ustrip(u"m", r.d), r.utilization, string(r.analysis)))
println(@sprintf("rebuilt plan  %.4f × %.4f m   overhang %.4f m",
                 ustrip(u"m", plan.B), ustrip(u"m", plan.Lm),
                 ustrip(u"m", plan.overhang)))
println(@sprintf("wall lines  Pu %10.1f kN   Ps %10.1f kN   qa·A %10.1f kN   Ps/(qa·A) %.4f",
                 ustrip(u"kN", Pu), ustrip(u"kN", Ps), ustrip(u"kN", cap),
                 ustrip(u"kN", Ps) / ustrip(u"kN", cap)))
col_Ps = sum(demands_all[i].Ps for i in group.support_indices; init = 0.0u"kN")
col_Pu = sum(demands_all[i].Pu for i in group.support_indices; init = 0.0u"kN")
println(@sprintf("on-wall column supports %d   Pu %8.1f kN   Ps %8.1f kN",
                 length(group.support_indices), ustrip(u"kN", col_Pu), ustrip(u"kN", col_Ps)))
println(@sprintf("qu %.2f kPa   legs %d   lips %d",
                 ustrip(u"kPa", qu), length(group.legs), length(lips)))

fc = opts.material.concrete.fc′
λ = opts.material.concrete.λ
ϕv = opts.ϕ_shear
d = r.d
bw = 1.0u"m"
Vc = ϕv * SZ.one_way_shear_capacity(fc, bw, d; λ = λ)
println(@sprintf("stored overhang %.4f m   wall box %.4f m",
                 ustrip(u"m", oh_stored), ustrip(u"m", box)))
for (dir, lip) in lips
    lip_s = lip - doh
    Mu = qu * (lip_s * u"m")^2 / 2
    proj = max(lip_s - ustrip(u"m", d), 0.0)
    Vu = qu * (proj * u"m") * bw
    println(@sprintf("  lip %-2s  %.3f m   Mu %8.1f kN·m/m   Vu %7.1f kN/m   ϕVc %7.1f kN/m   Vu/ϕVc %.3f",
                     string(dir), lip_s, ustrip(u"kN", Mu), ustrip(u"kN", Vu),
                     ustrip(u"kN", Vc), ustrip(u"kN", Vu) / ustrip(u"kN", Vc)))
end
println(@sprintf("As bot  x %.1f  y %.1f cm²    top  x %.1f  y %.1f cm²",
                 ustrip(u"cm^2", r.As_x_bot), ustrip(u"cm^2", r.As_y_bot),
                 ustrip(u"cm^2", r.As_x_top), ustrip(u"cm^2", r.As_y_top)))

function _shell_census(model)
    n_sh = 0
    n_deg = 0
    n_wall = 0
    for sh in model.shell_elements
        n_sh += 1
        sh.id === :wall && (n_wall += 1)
        length(sh.nodes) == 3 || continue
        p = [ustrip.(u"m", nd.position) for nd in sh.nodes]
        ax = p[2][1] - p[1][1]; ay = p[2][2] - p[1][2]; az = p[2][3] - p[1][3]
        bx = p[3][1] - p[1][1]; by = p[3][2] - p[1][2]; bz = p[3][3] - p[1][3]
        cx = ay * bz - az * by
        cy = az * bx - ax * bz
        cz = ax * by - ay * bx
        0.5 * sqrt(cx * cx + cy * cy + cz * cz) < 1e-8 && (n_deg += 1)
    end
    n_wsw = count(ld -> ld isa SS.Asap.AreaLoad && ld.id === :wall_self_weight,
                  model.loads)
    return n_sh, n_wall, n_deg, n_wsw
end
n_sh, n_wall, n_deg, n_wsw = _shell_census(struc.asap_model)
println("shells $n_sh   wall shells $n_wall   area < 1e-8 m²: $n_deg   wall-self-weight loads $n_wsw")
