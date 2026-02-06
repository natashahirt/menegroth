# Run steel tests only
using Test
using Unitful
using StructuralSizer
# Units are re-exported from StructuralSizer (via Asap)

@testset "Steel Member Tests" begin
    # Core section tests
    include("steel_member/test_hss_sections.jl")
    
    # AISC reference examples
    include("steel_member/test_aisc_companion_manual_1.jl")
    include("steel_member/test_aisc_360_reference.jl")
    
    # Slenderness and local buckling
    include("steel_member/test_qa_slender_web.jl")
    include("steel_member/test_hss_e7.jl")
    include("steel_member/test_hss_round_shear.jl")
    
    # Torsion (AISC H3)
    include("steel_member/test_hss_torsion.jl")
    
    # Moment amplification (AISC Appendix 8)
    include("steel_member/test_b1_b2_amplification.jl")
    include("steel_member/test_b1_checker_integration.jl")
end
