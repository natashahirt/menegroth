ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = "false"

using StructuralSizer
using Test
include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "runtests.jl"))
