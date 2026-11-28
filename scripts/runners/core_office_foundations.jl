#=
Foundations under the four-story core office.

Gravity reactions only. The core walls, doors included, are classified from
the grade-story centerlines, then sized with the default foundation strategy
on medium sand.

    SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/core_office_foundations.jl
=#

using Printf
using Unitful
using StructuralSynthesizer

include(joinpath(@__DIR__, "core_office_geometry.jl"))

function _print_plan_groups(struc)
    grade = [i for (i, w) in enumerate(struc.walls) if w.story == 0]
    groups = StructuralSynthesizer.classify_wall_foundation_groups(struc.walls, grade)
    println("  grade walls: ", length(grade), "  groups: ", length(groups))
    for (k, g) in enumerate(groups)
        n_open = count(p -> !isempty(struc.walls[p.wall_index].openings), g.pieces)
        println(@sprintf("    %d  %-5s  %d pieces  %d with openings",
                         k, g.kind, length(g.pieces), n_open))
    end
    return groups
end

function _print_foundations(struc)
    println()
    println("=== Foundations ===")
    for (i, fnd) in enumerate(struc.foundations)
        r = fnd.result
        analysis = hasproperty(r, :analysis) ? string(r.analysis) : "-"
        println(@sprintf(
            "%2d  %-10s  %-8s  %5.2f × %5.2f × %5.2f m  util %5.1f%%  supports %d  walls %d",
            i, fnd.foundation_type, analysis,
            ustrip(u"m", r.B), ustrip(u"m", r.L_ftg), ustrip(u"m", r.D),
            100 * r.utilization, length(fnd.support_indices), length(fnd.wall_indices)))
    end
    n = length(struc.foundations)
    n_mat = count(f -> f.foundation_type == :mat, struc.foundations)
    n_wall = count(f -> f.foundation_type == :wall_strip, struc.foundations)
    n_spread = count(f -> f.foundation_type == :spread, struc.foundations)
    println(@sprintf("  %d foundations: %d mat, %d wall strip, %d spread",
                     n, n_mat, n_wall, n_spread))
end

println("Core office foundations (gravity, medium sand)")
flush(stdout)
skel = core_office_skeleton()
struc = BuildingStructure(skel)
t_init = @elapsed initialize!(struc;
    floor_type = :flat_plate,
    floor_opts = FlatPlateOptions(),
    material = NWC_4000,
    wall_thickness = 0.30u"m")
println("  initialize: ", round(t_init; digits = 1), " s  walls: ", length(struc.walls))
_print_plan_groups(struc)
flush(stdout)

params = DesignParameters(materials = MaterialOptions(concrete = NWC_4000))
t_mesh = @elapsed to_asap!(struc; params = params, diaphragms = :rigid)
println("  mesh: ", round(t_mesh; digits = 1), " s")
flush(stdout)
t_solve = @elapsed StructuralSynthesizer.Asap.solve!(struc.asap_model)
println("  solve: ", round(t_solve; digits = 1), " s")
flush(stdout)

initialize_supports!(struc)
println("  supports: ", length(struc.supports))
t_fnd = @elapsed size_foundations!(struc;
    soil = medium_sand,
    opts = FoundationOptions(),
    verbose = true)
println("  size: ", round(t_fnd; digits = 1), " s")
_print_foundations(struc)
