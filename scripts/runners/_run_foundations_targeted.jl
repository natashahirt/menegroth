using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))
ENV["SS_ENABLE_VISUALIZATION"] = "false"

using Test
using Unitful
using StructuralSizer
using Asap

@testset "Foundations targeted" begin
    test_dir = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "foundations")
    for f in (
        "test_spread_footing.jl",
        "test_mat_aci.jl",
        "test_spread_aci.jl",
        "test_strip_aci.jl",
    )
        include(joinpath(test_dir, f))
    end
end
