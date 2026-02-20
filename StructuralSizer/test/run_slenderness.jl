# Run slenderness tests only
# Usage: julia --project=. StructuralSizer/test/run_slenderness.jl

using Test
using Unitful
using StructuralSizer
using Asap

cd(joinpath(@__DIR__))

# Load test data
include("concrete_column/test_data/slenderness_nonsway_17x17.jl")
include("concrete_column/test_data/slenderness_sway_18x18.jl")

# Run tests
@testset "Slenderness" begin
    include("concrete_column/test_slenderness.jl")
end
