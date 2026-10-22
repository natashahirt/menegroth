# Targeted suite for signed-moment / φv / signed-Nu work.
using Test
using StructuralSizer

@testset "Signed demand + φv suite" begin
    include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test",
                     "concrete_beam", "test_signed_demands.jl"))
    include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test",
                     "steel_member", "test_phi_v_provision.jl"))
    include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test",
                     "concrete_beam", "test_beam_design.jl"))
    include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test",
                     "concrete_beam", "test_beam_shear.jl"))
    include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test",
                     "concrete_beam", "test_tbeam.jl"))
end
