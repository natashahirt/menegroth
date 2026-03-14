using Pkg
Pkg.activate("StructuralSynthesizer")

using Test
using StructuralSynthesizer

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
@testset "Visualization" begin
    include(joinpath(repo_root, "StructuralSynthesizer", "test", "visualization", "test_voronoi_vis.jl"))
end
