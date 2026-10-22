# Verification suite for signed-demand / φv / signed-Nu member work.
# Includes the concrete_beam, steel_member, members, and optimize groups
# from StructuralSizer/test/runtests.jl plus _run_beam_tests.jl.
using Test
using Unitful
using StructuralSizer
using Asap

const TEST = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test")

@testset "eng_members verification" begin
    @testset "Steel Members" begin
        include(joinpath(TEST, "steel_member/test_aisc_beam_examples.jl"))
        include(joinpath(TEST, "steel_member/test_handcalc_beam.jl"))
        include(joinpath(TEST, "steel_member/test_phi_v_provision.jl"))
        include(joinpath(TEST, "steel_member/test_hss_sections.jl"))
        include(joinpath(TEST, "steel_member/test_hss_e7.jl"))
        include(joinpath(TEST, "steel_member/test_hss_round_shear.jl"))
        include(joinpath(TEST, "steel_member/test_hss_torsion.jl"))
        include(joinpath(TEST, "steel_member/test_w_torsion.jl"))
        include(joinpath(TEST, "steel_member/test_qa_slender_web.jl"))
        include(joinpath(TEST, "steel_member/test_qa_slender_flange.jl"))
        include(joinpath(TEST, "steel_member/test_aisc_companion_manual_1.jl"))
        include(joinpath(TEST, "steel_member/test_aisc_360_reference.jl"))
        include(joinpath(TEST, "steel_member/test_b1_b2_amplification.jl"))
        include(joinpath(TEST, "steel_member/test_b1_checker_integration.jl"))
        include(joinpath(TEST, "steel_member/composite/test_composite_beam.jl"))
    end

    @testset "Member Defaults" begin
        include(joinpath(TEST, "members/test_defaults.jl"))
    end

    @testset "Concrete Beams (full)" begin
        include(joinpath(TEST, "concrete_beam/test_beam_section.jl"))
        include(joinpath(TEST, "concrete_beam/test_beam_flexure.jl"))
        include(joinpath(TEST, "concrete_beam/test_beam_shear.jl"))
        include(joinpath(TEST, "concrete_beam/test_beam_design.jl"))
        include(joinpath(TEST, "concrete_beam/test_beam_deflection.jl"))
        include(joinpath(TEST, "concrete_beam/test_deflection.jl"))
        include(joinpath(TEST, "concrete_beam/test_cantilever_beam.jl"))
        include(joinpath(TEST, "concrete_beam/test_doubly_reinforced.jl"))
        include(joinpath(TEST, "concrete_beam/test_rc_beam_reference.jl"))
        include(joinpath(TEST, "concrete_beam/test_torsion.jl"))
        include(joinpath(TEST, "concrete_beam/test_tbeam.jl"))
        include(joinpath(TEST, "concrete_beam/test_tbeam_optimization.jl"))
        include(joinpath(TEST, "concrete_beam/test_tbeam_tributary_flange.jl"))
        include(joinpath(TEST, "concrete_beam/test_signed_demands.jl"))
    end

    @testset "Optimization" begin
        include(joinpath(TEST, "optimize/test_column_optimization.jl"))
        include(joinpath(TEST, "optimize/test_column_full.jl"))
        include(joinpath(TEST, "optimize/test_column_nlp.jl"))
        include(joinpath(TEST, "optimize/test_column_nlp_adapter.jl"))
        include(joinpath(TEST, "optimize/test_hss_column_nlp.jl"))
        include(joinpath(TEST, "optimize/test_w_column_nlp.jl"))
        include(joinpath(TEST, "optimize/test_multi_material_mip.jl"))
    end
end
