# Run design API and API-related tests (StructuralSynthesizer)
# Usage: julia --project=StructuralSynthesizer scripts/runners/run_design_api_tests.jl

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Pkg
Pkg.activate("StructuralSynthesizer")
Pkg.test(StructuralSynthesizer; test_args = ["core/test_design_api.jl"])
