# Targeted Asap verification for #7 (rigid-link reduced factorization cache).
# Runs the rigid-link closed-form suite and the factorization-cache suite, the
# two directly exercised by routing solve!(model, links) through
# _get_reduced_factorization!.
#
#   julia --project=external/Asap scripts/runners/test_rigidlink_factor_cache.jl
using Asap, Test, LinearAlgebra, Unitful
Unitful.register(Asap)

const _ASAP_TEST = joinpath(@__DIR__, "..", "..", "external", "Asap", "test")

@testset "#7 RigidLink + factorization cache" begin
    include(joinpath(_ASAP_TEST, "rigidlink", "test_rigidlink.jl"))
    include(joinpath(_ASAP_TEST, "integration_and_api", "test_factorization_cache.jl"))
    # Rigid links in building-like contexts: the diaphragm reduction and the
    # P-delta / mixed-model solves also go through solve!(model, links).
    include(joinpath(_ASAP_TEST, "elements", "shell", "test_diaphragm.jl"))
    include(joinpath(_ASAP_TEST, "nonlinear", "test_pdelta.jl"))
    include(joinpath(_ASAP_TEST, "integration_and_api", "test_mixed_model.jl"))
end
