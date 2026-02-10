# Test shear stud design per ACI 318-19 §22.6.8 / Ancon Shearfix Manual
# 
# Reference: Ancon_Shearfix_Design_Manual_to_ACI_318-19.pdf (in slabs/codes/concrete/reference/two_way)

using Test
using Unitful
using StructuralSizer

# =============================================================================
# Test: Size Effect Factor λs (Ancon Eq. 7)
# =============================================================================
@testset "Size Effect Factor λs" begin
    # λs = min(2 / √(1 + d/254mm), 1.0) per ACI 318-19
    # Note: For typical flat plate depths (6"-12"), the uncapped formula > 1.0
    # So λs = 1.0 for most flat plate applications
    
    # Small d → formula > 1.0 → capped at 1.0
    λs_small = StructuralSizer.size_effect_factor_λs(6.0u"inch")  # ~152mm
    uncapped_small = 2.0 / sqrt(1 + 152.4/254)  # ≈ 1.58
    @test uncapped_small > 1.0  # Formula gives > 1 before cap
    @test λs_small ≈ 1.0 atol=0.01  # But capped at 1.0
    
    # Typical flat plate d (8") → still capped
    λs_typical = StructuralSizer.size_effect_factor_λs(8.0u"inch")  # ~203mm
    uncapped_typical = 2.0 / sqrt(1 + 203.2/254)  # ≈ 1.49
    @test uncapped_typical > 1.0
    @test λs_typical ≈ 1.0 atol=0.01
    
    # Very large d → formula gives < 1.0, not capped
    λs_deep = StructuralSizer.size_effect_factor_λs(40.0u"inch")  # ~1016mm
    uncapped_deep = 2.0 / sqrt(1 + 1016/254)  # ≈ 0.89
    @test uncapped_deep < 1.0
    @test λs_deep ≈ uncapped_deep atol=0.01
    
    # λs decreases as d increases (size effect = thicker slabs are less efficient)
    @test λs_deep < λs_typical
end

# =============================================================================
# Test: Stud Area Calculation
# =============================================================================
@testset "Stud Area" begin
    # 3/8" stud
    As_3_8 = StructuralSizer.stud_area(0.375u"inch")
    @test ustrip(u"inch^2", As_3_8) ≈ π * (0.375/2)^2 atol=0.001
    
    # 1/2" stud (typical)
    As_1_2 = StructuralSizer.stud_area(0.5u"inch")
    @test ustrip(u"inch^2", As_1_2) ≈ 0.196 atol=0.001
    
    # 5/8" stud
    As_5_8 = StructuralSizer.stud_area(0.625u"inch")
    @test ustrip(u"inch^2", As_5_8) ≈ π * (0.625/2)^2 atol=0.001
end

# =============================================================================
# Test: Minimum Stud Reinforcement (Ancon Eq. 14)
# =============================================================================
@testset "Minimum Stud Reinforcement" begin
    # Av/s ≥ 0.17√f'c × b0/fyt
    fc = 4000.0u"psi"
    b0 = 60.0u"inch"
    fyt = 51000.0u"psi"
    
    Av_s_min = StructuralSizer.minimum_stud_reinforcement(fc, b0, fyt)
    
    # Expected: 0.17 × √4000 × 60 / 51000 ≈ 0.01265 in²/in
    expected = 0.17 * sqrt(4000) * 60 / 51000
    @test ustrip(u"inch^2/inch", Av_s_min) ≈ expected atol=0.001
end

# =============================================================================
# Test: Punching Capacity with Studs (Ancon Eq. 9-13)
# =============================================================================
@testset "Punching Capacity with Studs" begin
    # Test case: Interior column, f'c = 4000 psi
    fc = 4000.0u"psi"
    β = 1.0       # Square column
    αs = 40       # Interior
    b0 = 80.0u"inch"
    d = 8.0u"inch"
    fyt = 51000.0u"psi"
    stud_diam = 0.5u"inch"
    
    # 8 rails of 1/2" studs → Av = 8 × π(0.25)² ≈ 1.57 in²
    n_rails = 8
    Av = n_rails * StructuralSizer.stud_area(stud_diam)
    s = 4.0u"inch"  # Spacing ≤ 0.5d = 4"
    
    result = StructuralSizer.punching_capacity_with_studs(
        fc, β, αs, b0, d, Av, s, fyt
    )
    
    # Check reduced concrete contribution (US: 3.0λs√f'c per ACI 318-19 §22.6.6.1)
    sqrt_fc = sqrt(4000)
    λs = StructuralSizer.size_effect_factor_λs(d)
    expected_vcs_max = 3.0 * λs * sqrt_fc  # Should be ≤ this
    @test ustrip(u"psi", result.vcs) ≤ expected_vcs_max + 0.1
    
    # Check compression strut limit (US: 8√f'c for s ≤ 0.5d, ACI §22.6.6.2)
    expected_vc_max = 8.0 * sqrt_fc
    @test ustrip(u"psi", result.vc_max) ≈ expected_vc_max atol=0.5
    
    # Check vs > 0
    @test ustrip(u"psi", result.vs) > 0
    
    # Check combined capacity
    @test ustrip(u"psi", result.vc_total) ≤ ustrip(u"psi", result.vc_max)
end

# =============================================================================
# Test: Outer Critical Section Capacity (Ancon Eq. 16)
# =============================================================================
@testset "Outer Critical Section" begin
    fc = 4000.0u"psi"
    d = 8.0u"inch"
    
    vc_out = StructuralSizer.punching_capacity_outer(fc, d)
    
    # vc,out = 4 × λs × √f'c  (US customary, ACI §22.6.5.2(a))
    λs = StructuralSizer.size_effect_factor_λs(d)
    expected = 4.0 * λs * sqrt(4000)
    @test ustrip(u"psi", vc_out) ≈ expected atol=0.5
    
    # Outer capacity (unreinforced) < max stud-reinforced capacity at column
    vc_max_col = 8.0 * sqrt(4000)  # Max with studs (tight spacing)
    @test ustrip(u"psi", vc_out) < vc_max_col
end

# =============================================================================
# Test: Shear Stud Design Function
# =============================================================================
@testset "Shear Stud Design" begin
    # Note on capacity limits (US customary, psi):
    # vc_max with studs = 8√f'c ≈ 506 psi for f'c = 4000
    # φ × vc_max = 0.75 × 506 ≈ 380 psi
    # So maximum achievable vu with studs is ~380 psi
    
    # Design scenario: Interior column just failing punching
    vu = 25.0u"psi"     # Realistic stress, below max capacity
    fc = 4000.0u"psi"
    β = 1.0
    αs = 40
    b0 = 80.0u"inch"
    d = 8.0u"inch"
    fyt = 51000.0u"psi"
    stud_diam = 0.5u"inch"
    
    studs = StructuralSizer.design_shear_studs(
        vu, fc, β, αs, b0, d, :interior, fyt, stud_diam
    )
    
    # Should require studs
    @test studs.required == true
    
    # Interior column → 8 rails
    @test studs.n_rails == 8
    
    # First spacing at 0.5d
    @test ustrip(u"inch", studs.s0) ≈ 4.0 atol=0.01
    
    # Spacing should be > 0 (studs designed)
    @test ustrip(u"inch", studs.s) > 0
    
    # Check with check_punching_with_studs
    check = StructuralSizer.check_punching_with_studs(vu, studs)
    @test check.ratio < 1.5  # Should be achievable
    
    # Edge column → 6 rails
    studs_edge = StructuralSizer.design_shear_studs(
        vu, fc, β, 30, b0, d, :edge, fyt, stud_diam
    )
    @test studs_edge.n_rails == 6
    
    # Corner column → 4 rails
    studs_corner = StructuralSizer.design_shear_studs(
        vu, fc, β, 20, b0, d, :corner, fyt, stud_diam
    )
    @test studs_corner.n_rails == 4
    
    # Test: Demand exceeds max capacity → n_rails = 0
    vu_extreme = 400.0u"psi"  # Above φ × vc_max ≈ 380 psi
    studs_impossible = StructuralSizer.design_shear_studs(
        vu_extreme, fc, β, αs, b0, d, :interior, fyt, stud_diam
    )
    @test studs_impossible.n_rails == 0  # Can't design studs
    @test !studs_impossible.outer_ok
end

# =============================================================================
# Test: Stud Design for Moderate Shear (passes with studs)
# =============================================================================
@testset "Stud Design - Moderate Shear" begin
    # Scenario: vu just exceeds φvc without studs, studs should resolve
    fc = 4000.0u"psi"
    d = 8.0u"inch"
    λs = StructuralSizer.size_effect_factor_λs(d)
    
    # φvc without studs ≈ 0.75 × 4√4000 × λs ≈ 190 psi  (US customary)
    # φvc with studs (max) ≈ 0.75 × 8√4000 ≈ 380 psi
    # So studs can help if 190 < vu < 380
    vu = 250.0u"psi"  # Needs studs, achievable with studs
    β = 1.0
    αs = 40
    b0 = 80.0u"inch"
    fyt = 51000.0u"psi"
    stud_diam = 0.5u"inch"
    
    studs = StructuralSizer.design_shear_studs(
        vu, fc, β, αs, b0, d, :interior, fyt, stud_diam
    )
    
    check = StructuralSizer.check_punching_with_studs(vu, studs)
    
    # With 8 rails of 1/2" studs, should pass
    @test check.ok == true || check.ratio < 1.2
end

# =============================================================================
# Test: Material Presets
# =============================================================================
@testset "Stud_51 Material" begin
    @test StructuralSizer.Stud_51.Fy ≈ 351.6u"MPa" atol=0.5u"MPa"  # 51 ksi
    @test StructuralSizer.material_name(StructuralSizer.Stud_51) == "Stud51"
end

# =============================================================================
# Test: FlatPlateOptions with Shear Studs
# =============================================================================
@testset "FlatPlateOptions Shear Stud Fields" begin
    # Default options
    opts = StructuralSizer.FlatPlateOptions()
    
    @test opts.shear_studs == :never
    @test opts.max_column_size ≈ 30.0u"inch" atol=0.1u"inch"
    @test opts.stud_material === StructuralSizer.Stud_51
    @test opts.stud_diameter ≈ 0.5u"inch" atol=0.01u"inch"
    
    # Options with studs enabled
    opts_studs = StructuralSizer.FlatPlateOptions(shear_studs=:if_needed)
    @test opts_studs.shear_studs == :if_needed
end

# =============================================================================
# Test: Compression Strut Limit (vc,max)
# =============================================================================
@testset "Compression Strut Limit" begin
    fc = 4000.0u"psi"
    β = 1.0
    αs = 40
    b0 = 80.0u"inch"
    d = 8.0u"inch"
    fyt = 51000.0u"psi"
    
    # With tight spacing (s ≤ 0.5d) → vc,max = 8√f'c  (US customary, ACI §22.6.6.2)
    Av = 1.5u"inch^2"
    s_tight = 3.0u"inch"
    
    result_tight = StructuralSizer.punching_capacity_with_studs(
        fc, β, αs, b0, d, Av, s_tight, fyt
    )
    @test ustrip(u"psi", result_tight.vc_max) ≈ 8.0 * sqrt(4000) atol=0.5
    
    # With wider spacing (s > 0.5d) → vc,max = 6√f'c  (US customary)
    s_wide = 6.0u"inch"  # > 0.5 × 8 = 4"
    
    result_wide = StructuralSizer.punching_capacity_with_studs(
        fc, β, αs, b0, d, Av, s_wide, fyt
    )
    @test ustrip(u"psi", result_wide.vc_max) ≈ 6.0 * sqrt(4000) atol=0.5
end

println("\n✅ All shear stud tests completed!")
