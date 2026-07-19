using Pkg
Pkg.activate("StructuralSynthesizer")
using Test

include(joinpath(@__DIR__, "../../StructuralSynthesizer/test/integration/test_phase5_framing_integration.jl"))
