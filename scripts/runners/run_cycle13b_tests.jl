# Runner: execute the Eq. (13-7) cycle 13b regression suites in one process.
# Usage: SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#        julia --project=StructuralSynthesizer scripts/runners/run_cycle13b_tests.jl
using Test

const TESTDIR = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "slabs")

@testset "cycle 13b fix" begin
    include(joinpath(TESTDIR, "test_eq_13_7_cycle13.jl"))
    include(joinpath(TESTDIR, "test_eq_13_7_cycle12.jl"))
    include(joinpath(TESTDIR, "test_eq_13_7_adjoining.jl"))
end
