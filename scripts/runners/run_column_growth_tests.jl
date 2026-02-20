# =============================================================================
# Runner: Column Growth & Secondary Analysis Tests
# =============================================================================
# Tests the new column sizing infrastructure:
#   - Column shape/growth control (square, bounded, free)
#   - Direct punching solve
#   - Secondary moment analysis
#
# Usage (from repo root):
#   julia scripts/runners/run_column_growth_tests.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

# Force fresh precompile (clear stale caches)
Pkg.precompile()

using Test, Unitful
using StructuralSizer

test_root = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test")

println("═"^60)
println("  Column Growth & Secondary Analysis Tests")
println("═"^60)

@testset "Column Growth Suite" begin
    include(joinpath(test_root, "slabs", "test_column_growth.jl"))
end
