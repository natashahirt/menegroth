# Run StructuralSynthesizer micro-experiment tests only.
# Usage: SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/run_micro_experiment_tests.jl

using Test
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "core", "test_micro_experiments.jl"))
