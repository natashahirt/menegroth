using Test

@testset "All Beam Tests" begin
    include("concrete_beam/test_beam_section.jl")
    include("concrete_beam/test_beam_flexure.jl")
    include("concrete_beam/test_beam_design.jl")
    include("concrete_beam/test_cantilever_beam.jl")
    include("concrete_beam/test_doubly_reinforced.jl")
    include("concrete_beam/test_beam_deflection.jl")
    include("concrete_beam/test_signed_demands.jl")
end
