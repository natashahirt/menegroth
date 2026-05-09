ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = "false"

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "core", "test_chat_api.jl"))
