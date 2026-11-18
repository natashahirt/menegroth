#=
Gravity equilibrium of the saved core office foundations.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralSynthesizer scripts/runners/check_core_office_equilibrium.jl

Loads viewer/public/core_office.mgdesign, solves the restored frame once,
and checks that the mat's wall line loads plus every footing's column
demands equal the solved vertical reactions. The four core-bay corners
must belong to the mat and to no spread.
=#

using Printf
using Unitful
using Meshes
using StructuralSynthesizer

const design_path = isempty(ARGS) ?
    joinpath(@__DIR__, "..", "..", "viewer", "public", "core_office.mgdesign") :
    ARGS[1]
const CORNERS = ((8.0, 8.0), (16.0, 8.0), (16.0, 16.0), (8.0, 16.0))

function _plan(struc, i)
    v = struc.skeleton.vertices[struc.supports[i].vertex_idx]
    c = Meshes.coords(v)
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function _near_corner(xy)
    for (k, c) in enumerate(CORNERS)
        hypot(xy[1] - c[1], xy[2] - c[2]) < 0.05 && return k
    end
    return 0
end

function main()
println("load ", design_path)
flush(stdout)
design = load_design(design_path)
struc = design.structure
println("  foundations stored: ", length(struc.foundations),
        "  captured: ", length(design.foundations),
        "  supports stored: ", length(struc.supports))
for (i, fnd) in enumerate(struc.foundations)
    r = fnd.result
    println(@sprintf("  saved %2d  %-10s  %5.2f × %5.2f × %5.2f m  util %5.1f%%  supports %d  walls %d",
                     i, fnd.foundation_type,
                     ustrip(u"m", r.B), ustrip(u"m", r.L_ftg), ustrip(u"m", r.D),
                     100 * r.utilization, length(fnd.support_indices), length(fnd.wall_indices)))
end
flush(stdout)

println("solve")
flush(stdout)
t_solve = @elapsed StructuralSynthesizer.Asap.solve!(struc.asap_model)
println("  solve: ", round(t_solve; digits = 1), " s")
flush(stdout)

saved_idx = [copy(f.support_indices) for f in struc.foundations]
initialize_supports!(struc)
demands = StructuralSynthesizer.support_demands(struc)
groups = StructuralSynthesizer.collect_grade_wall_groups(struc)

on_wall = Set{Int}()
wall_Pu = 0.0u"kN"
wall_Ps = 0.0u"kN"
println("wall groups: ", length(groups))
for (k, g) in enumerate(groups)
    pu = sum(smp.Pu for leg in g.legs for smp in leg.samples)
    ps = sum(smp.Ps for leg in g.legs for smp in leg.samples)
    wall_Pu += uconvert(u"kN", pu)
    wall_Ps += uconvert(u"kN", ps)
    union!(on_wall, g.support_indices)
    println(@sprintf("  %d  %-5s  pieces %d  on-wall supports %d  Pu %8.1f kN  Ps %8.1f kN",
                     k, g.group.kind, length(g.legs), length(g.support_indices),
                     ustrip(u"kN", pu), ustrip(u"kN", ps)))
end

total_Pu = sum(d.Pu for d in demands)
total_Ps = sum(d.Ps for d in demands)
spread_Pu = 0.0u"kN"
spread_Ps = 0.0u"kN"
mat_col_Pu = 0.0u"kN"
mat_col_Ps = 0.0u"kN"
claimed = Set{Int}()
corner_home = Dict{Int, Vector{String}}()

for (i, fnd) in enumerate(struc.foundations)
    idxs = saved_idx[i]
    for si in idxs
        push!(get!(corner_home, _near_corner(_plan(struc, si)), String[]),
              string(fnd.foundation_type, " ", i))
    end
    cols = [si for si in idxs if si ∉ on_wall]
    pu = sum((demands[si].Pu for si in cols); init = 0.0u"kN")
    ps = sum((demands[si].Ps for si in cols); init = 0.0u"kN")
    if fnd.foundation_type == :spread
        spread_Pu += pu
        spread_Ps += ps
    elseif fnd.foundation_type == :mat
        mat_col_Pu += pu
        mat_col_Ps += ps
    end
    overlap = [si for si in idxs if si in claimed]
    union!(claimed, idxs)
    println(@sprintf("  fnd %2d %-10s column supports %d (of %d)  Pu %8.1f  Ps %8.1f  overlap %s",
                     i, fnd.foundation_type, length(cols), length(idxs),
                     ustrip(u"kN", pu), ustrip(u"kN", ps),
                     isempty(overlap) ? "none" : string(overlap)))
end

# `total_*` is the 16 column supports. Wall bases are fixed nodes too, so the
# balance is spreads + wall line loads against every fixed vertical reaction.
model = struc.asap_model
R_s = StructuralSynthesizer._service_reactions(struc)
fixed_Pu = 0.0u"kN"
fixed_Ps = 0.0u"kN"
for n in model.nodes
    length(n.dof) >= 3 && n.dof[3] == false || continue
    fixed_Pu += uconvert(u"kN", n.reaction[3])
    fixed_Ps += uconvert(u"kN", R_s[n.globalID[3]] * u"N")
end
accounted_Pu = spread_Pu + wall_Pu
accounted_Ps = spread_Ps + wall_Ps
println()
println(@sprintf("vertical Pu  all fixed %10.1f   spreads %10.1f   wall lines %10.1f   sum %10.1f   residual %8.2f",
                 ustrip(u"kN", fixed_Pu), ustrip(u"kN", spread_Pu),
                 ustrip(u"kN", wall_Pu), ustrip(u"kN", accounted_Pu),
                 ustrip(u"kN", accounted_Pu - fixed_Pu)))
println(@sprintf("vertical Ps  all fixed %10.1f   spreads %10.1f   wall lines %10.1f   sum %10.1f   residual %8.2f",
                 ustrip(u"kN", fixed_Ps), ustrip(u"kN", spread_Ps),
                 ustrip(u"kN", wall_Ps), ustrip(u"kN", accounted_Ps),
                 ustrip(u"kN", accounted_Ps - fixed_Ps)))
println(@sprintf("Pu/Ps   spreads %.2f   wall lines %.2f   all fixed %.2f",
                 ustrip(spread_Pu) / ustrip(spread_Ps),
                 ustrip(wall_Pu) / ustrip(wall_Ps),
                 ustrip(fixed_Pu) / ustrip(fixed_Ps)))
println(@sprintf("column supports only   Pu %10.1f   Ps %10.1f   (mat columns off a wall %8.1f / %8.1f)",
                 ustrip(u"kN", total_Pu), ustrip(u"kN", total_Ps),
                 ustrip(u"kN", mat_col_Pu), ustrip(u"kN", mat_col_Ps)))

println("core corners")
for (k, c) in enumerate(CORNERS)
    homes = String[]
    owner = 0
    for (i, supp) in enumerate(struc.supports)
        _near_corner(_plan(struc, i)) == k || continue
        owner = i
        break
    end
    println(@sprintf("  corner %d (%.1f, %.1f)  support %d  homes %s",
                     k, c[1], c[2], owner,
                     owner == 0 ? "MISSING" : string(get(corner_home, k, ["none"]))))
end

unclaimed = [i for i in eachindex(demands) if i ∉ claimed && !(i in on_wall)]
println("supports on no footing and not on a wall line: ", isempty(unclaimed) ? "none" : string(unclaimed))
end

main()
