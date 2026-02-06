# Main test runner for StructuralSynthesizer
# Run with: julia --project=. test/runtests.jl

using Test
using Unitful
using StructuralSynthesizer
using Asap  # ensures `u"kip"`, `u"ksi"`, etc resolve via Asap unit module

@testset "StructuralSynthesizer Tests" begin
    include("test_core_structs.jl")
    include("test_design_architecture.jl")
    include("test_member_hierarchy.jl")
    include("test_voronoi_vis.jl")
    include("test_structuralsizer_workflow_integration.jl")
end