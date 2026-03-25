#!/usr/bin/env julia
# =============================================================================
# Runner: API cleanup checks
# =============================================================================
# Verifies:
# 1) StructuralSynthesizer API files compile/load after enum/constants cleanup.
# 2) StructuralSizer biaxial tests pass after pca_load_contour signature cleanup.
#
# Usage:
#   julia scripts/runners/run_api_cleanup_checks.jl
# =============================================================================

using Pkg

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const SSZ_DIR = joinpath(REPO_ROOT, "StructuralSizer")
const SYN_DIR = joinpath(REPO_ROOT, "StructuralSynthesizer")
const BIAXIAL_TEST = joinpath(SSZ_DIR, "test", "concrete_column", "test_biaxial.jl")

function run_structural_synthesizer_smoke()
    @info "Running StructuralSynthesizer API smoke load"
    Pkg.activate(SYN_DIR)
    Pkg.instantiate()
    Base.eval(Main, :(using StructuralSynthesizer))
    @info "StructuralSynthesizer loaded successfully"
    return nothing
end

function run_structural_sizer_biaxial_test()
    @info "Running StructuralSizer biaxial test file"
    Pkg.activate(SSZ_DIR)
    Pkg.instantiate()
    include(BIAXIAL_TEST)
    @info "StructuralSizer biaxial tests completed"
    return nothing
end

function main()
    run_structural_synthesizer_smoke()
    run_structural_sizer_biaxial_test()
    @info "All API cleanup checks passed"
end

main()
