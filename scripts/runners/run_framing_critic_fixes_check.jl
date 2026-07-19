# Focused check for the Phase-5 framing critic fixes:
#   - axis alternation (level 3+ perpendicular)
#   - level-1 axis/count deserialization
#   - end_fixity / catalog_override schema plumbing
#   - timber family recognition (safe, no fabricated preset)
#   - incremental-engine state-leak guard (prepare_engine works on a copy)
#
# Runs the two auto-framing integration test files. Per workspace rules this
# lives in scripts/runners/ and only sets up the environment + includes the
# library test files.

using Test
using StructuralSynthesizer
using StructuralSizer
using Unitful
using Asap

const _HERE = @__DIR__
const _TESTDIR = joinpath(_HERE, "..", "..", "StructuralSynthesizer", "test", "integration")

@testset "Framing critic fixes" begin
    include(joinpath(_TESTDIR, "test_auto_framing_integration.jl"))
    include(joinpath(_TESTDIR, "test_phase5_framing_integration.jl"))
end
