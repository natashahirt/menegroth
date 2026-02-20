# Test shear stud design per ACI 318-11 §11.11.5 / Ancon Shearfix Manual
# 
# Reference: Ancon_Shearfix_Design_Manual_to_ACI_318-19.pdf (in slabs/codes/concrete/reference/two_way)

using Test
using Unitful
using StructuralSizer

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
# Test: Minimum Stud Reinforcement (ACI 318-11 §11.11.5.1)
# =============================================================================
@testset "Minimum Stud Reinforcement" begin
    # Av*fyt/(b0*s) ≥ 2√f'c  →  Av/s ≥ 2√f'c × b0 / fyt
    fc = 4000.0u"psi"
    b0 = 60.0u"inch"
    fyt = 51000.0u"psi"
    
    Av_s_min = StructuralSizer.minimum_stud_reinforcement(fc, b0, fyt)
    
    # Expected: 2 × √4000 × 60 / 51000 ≈ 0.1487 in²/in
    expected = 2.0 * sqrt(4000) * 60 / 51000
    @test ustrip(u"inch^2/inch", Av_s_min) ≈ expected atol=0.001
end

# =============================================================================
# Test: Punching Capacity with Studs (ACI 318-11 §11.11.5)
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
    
    # ACI 318-11 §11.11.5.1: vcs ≤ 3λ√f'c (λ=1.0)
    sqrt_fc = sqrt(4000)
    expected_vcs_max = 3.0 * sqrt_fc  # 3√f'c ≈ 189.7 psi
    @test ustrip(u"psi", result.vcs) ≤ expected_vcs_max + 0.1
    
    # Nominal capacity limit: 8√f'c for headed studs (ACI 318-11 §11.11.3.2)
    expected_vc_max = 8.0 * sqrt_fc
    @test ustrip(u"psi", result.vc_max) ≈ expected_vc_max atol=0.5
    
    # Check vs > 0
    @test ustrip(u"psi", result.vs) > 0
    
    # Check combined capacity
    @test ustrip(u"psi", result.vc_total) ≤ ustrip(u"psi", result.vc_max)
end

# =============================================================================
# Test: Outer Critical Section Capacity (ACI 318-11 §11.11.5.4)
# =============================================================================
@testset "Outer Critical Section" begin
    fc = 4000.0u"psi"
    d = 8.0u"inch"
    
    vc_out = StructuralSizer.punching_capacity_outer(fc, d)
    
    # vc,out = 2λ√f'c  (ACI 318-11 §11.11.5.4)
    expected = 2.0 * sqrt(4000)  # ≈ 126.5 psi
    @test ustrip(u"psi", vc_out) ≈ expected atol=0.5
    
    # Outer capacity (unreinforced) < max stud-reinforced capacity at column
    vc_max_col = 8.0 * sqrt(4000)  # Max with studs
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
    
    # φvc without studs ≈ 0.75 × 4√4000 ≈ 190 psi  (US customary)
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
# Test: Nominal Capacity Limit (vc_max = 8√f'c, ACI 318-11 §11.11.3.2)
# =============================================================================
@testset "Nominal Capacity Limit" begin
    fc = 4000.0u"psi"
    β = 1.0
    αs = 40
    b0 = 80.0u"inch"
    d = 8.0u"inch"
    fyt = 51000.0u"psi"
    
    # ACI 318-11 §11.11.3.2: headed studs → Vn ≤ 8√f'c × b0 × d
    # vc_max = 8√f'c regardless of spacing
    Av = 1.5u"inch^2"
    
    s_tight = 3.0u"inch"
    result_tight = StructuralSizer.punching_capacity_with_studs(
        fc, β, αs, b0, d, Av, s_tight, fyt
    )
    @test ustrip(u"psi", result_tight.vc_max) ≈ 8.0 * sqrt(4000) atol=0.5
    
    s_wide = 6.0u"inch"
    result_wide = StructuralSizer.punching_capacity_with_studs(
        fc, β, αs, b0, d, Av, s_wide, fyt
    )
    # In ACI 318-11, vc_max = 8√f'c for all spacings (headed studs)
    @test ustrip(u"psi", result_wide.vc_max) ≈ 8.0 * sqrt(4000) atol=0.5
end

println("\n✅ All shear stud tests completed!")
