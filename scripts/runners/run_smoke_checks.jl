#!/usr/bin/env julia
# =============================================================================
# Smoke checks (StructuralSynthesizer)
# =============================================================================
# Runs core smoke scripts sequentially and fails fast on the first error.
#
# Usage:
#   julia scripts/runners/run_smoke_checks.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
Pkg.instantiate()

scripts = [
    "run_smoke_medium_office_3storey.jl",
    "run_slab_edge_alignment_check.jl",
]

for script in scripts
    path = joinpath(@__DIR__, script)
    println("\n=== Running smoke script: $script ===")
    run(`$(Base.julia_cmd()) $path`)
end

println("\n✓ All smoke checks passed.")
