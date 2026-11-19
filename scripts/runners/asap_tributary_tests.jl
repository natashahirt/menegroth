# Asap's tributary and slab-load test files, without the rest of its suite.
#
#     julia --project=external/Asap scripts/runners/asap_tributary_tests.jl

using Test

const ASAP_TEST = joinpath(@__DIR__, "..", "..", "external", "Asap", "test")

const FILES = [
    "tributary/test_tributaries.jl",
    "tributary/test_tributary_balance.jl",
    "tributary/test_cell_depths.jl",
    "tributary/test_ring_supports.jl",
    "tributary/test_voronoi_tributaries.jl",
    "loads/test_area_load.jl",
    "loads/test_polygon_split.jl",
    "loads/test_tributary_load.jl",
    "loads/test_tributary_release_fields.jl",
    "integration_and_api/test_load_approaches.jl",
    "integration_and_api/test_shell_beam_interactions.jl",
]

@testset "Asap tributary and slab loads" begin
    for f in FILES
        @testset "$f" begin
            include(joinpath(ASAP_TEST, f))
        end
    end
end
