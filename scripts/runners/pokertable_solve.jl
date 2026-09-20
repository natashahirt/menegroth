# Seed FEA for the convertible poker table (poker + dining).
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralStudies \
#     scripts/runners/pokertable_solve.jl

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src", "pokertable", "study.jl"))

leaf = length(ARGS) >= 1 ? Symbol(ARGS[1]) : :struts
leaf in (:struts, :endleg) || error("usage: pokertable_solve.jl [struts|endleg]")
solve_seed(; leaf_support = leaf)
