# Asap's tributary test files, without the rest of the Asap suite.
#
#   julia --project=external/Asap scripts/runners/asap_tributary_tests.jl [files...]
#
# Files are relative to external/Asap/test; with none, every tributary file runs.

using Test, Asap
const TDIR = joinpath(@__DIR__, "..", "..", "external", "Asap", "test")
const FILES = isempty(ARGS) ?
    ["tributary/test_tributaries.jl", "tributary/test_tributary_balance.jl",
     "tributary/test_cell_depths.jl", "tributary/test_spans.jl",
     "loads/test_tributary_load.jl"] : ARGS

@testset "Asap tributaries" begin
    for f in FILES
        @testset "$f" begin
            include(joinpath(TDIR, f))
        end
    end
end
