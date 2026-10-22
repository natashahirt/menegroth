# Targeted oracles: stale pattern_u after section change, and signed
# strip-footing x_bar (+400/−200 kN, 20 ft). Invoked from the repo root:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/run_pattern_foundation_oracles.jl

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] =
    get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const TEST_DIR = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test")

@testset "pattern_u + strip x_bar oracles" begin
    include(joinpath(TEST_DIR, "analyze", "test_pattern_loading.jl"))
    include(joinpath(TEST_DIR, "analyze", "test_foundation_demands.jl"))
end
