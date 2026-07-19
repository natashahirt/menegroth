# Run only test/integration/test_auto_framing_integration.jl.
# Usage: from repo root: julia --project=StructuralSynthesizer scripts/runners/run_auto_framing_test.jl

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Pkg
Pkg.activate("StructuralSynthesizer")

root = dirname(dirname(@__DIR__))
synth = joinpath(root, "StructuralSynthesizer")
test_file = joinpath(synth, "test", "integration", "test_auto_framing_integration.jl")

println("Running auto-framing integration tests...")
include(test_file)
