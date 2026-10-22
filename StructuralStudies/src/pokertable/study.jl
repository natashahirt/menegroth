# Seed solve for the convertible poker table.
# Usage from the runner: include this file, then `solve_seed()`.

include(joinpath(@__DIR__, "..", "init.jl"))
include(joinpath(@__DIR__, "materials.jl"))
include(joinpath(@__DIR__, "geometry.jl"))
include(joinpath(@__DIR__, "loads.jl"))
include(joinpath(@__DIR__, "model.jl"))
include(joinpath(@__DIR__, "report.jl"))

function seed_geom(; leaf_support::Symbol = :struts)
    return TableGeom(; leaf_support)
end

function solve_seed(; leaf_support::Symbol = :struts)
    g = seed_geom(; leaf_support)
    print_header("Poker table — seed Asap solve")
    poker = solve_table(g; state = :poker, case = :DL_edge)
    print_report(poker)
    dining = solve_table(g; state = :dining, case = :DL_edge)
    print_report(dining)
    print_footer(2, 0, "stdout")
    return (; poker, dining)
end
