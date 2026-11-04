ENV["SS_ENABLE_VISUALIZATION"] = "false"

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "api", "test_chat_tools.jl"))
