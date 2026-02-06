# Main test runner for StructuralSizer
# Run with: julia --project=. test/runtests.jl

using Test
using Unitful
using StructuralSizer
# Units are re-exported from StructuralSizer (via Asap)

@testset "StructuralSizer Tests" begin
    # Nebyu's vault tests (based on MATLAB output)
    include("haile_vault/test_vault.jl")
    # Steel beam tests (W section)
    include("steel_member/test_aisc_beam_examples.jl")
    include("steel_member/test_handcalc_beam.jl")
    # Steel column tests (W section)
    include("steel_member/test_aisc_column_examples.jl")
    # Steel HSS tests
    include("steel_member/test_hss_sections.jl")
    include("steel_member/test_hss_e7.jl")
    include("steel_member/test_hss_round_shear.jl")
    include("steel_member/test_hss_torsion.jl")
    # Steel slenderness tests
    include("steel_member/test_qa_slender_web.jl")
    # AISC companion manual tests for steel elements
    include("steel_member/test_aisc_companion_manual_1.jl")
    include("steel_member/test_aisc_360_reference.jl")
    # Moment amplification (B1/B2)
    include("steel_member/test_b1_b2_amplification.jl")
    include("steel_member/test_b1_checker_integration.jl")
    # ACI strip geometry tests (generic tributary is now in Asap)
    include("slabs/test_strip_geometry.jl")
    # Foundation tests
    include("foundations/test_spread_footing.jl")
    # Concrete column tests (rectangular)
    include("concrete_column/test_data/tied_column_16x16.jl")
    include("concrete_column/test_rc_column_section.jl")
    include("concrete_column/test_column_pm.jl")
    # Concrete column tests (circular)
    include("concrete_column/test_circular_column_pm.jl")
    # RC column catalog generation
    include("concrete_column/test_catalog_gen.jl")
    
    # Full column optimization tests
    include("optimize/test_column_optimization.jl")
    include("optimize/test_column_full.jl")
end