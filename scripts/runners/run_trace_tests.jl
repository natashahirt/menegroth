ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = "false"

using Test
using Unitful
using StructuralSizer
using StructuralSizer.Asap: kip, ksi

@testset "Solver Trace" begin
    include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "trace", "test_trace.jl"))
end
