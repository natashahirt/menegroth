# =============================================================================
# Test EFM Stiffness Calculations Against StructurePoint Example
# =============================================================================
#
# Reference: DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf
# Section 3.2: Equivalent Frame Method (EFM)
#
# Example geometry:
#   - Spans: l1 = 18 ft, l2 = 14 ft
#   - Slab: h = 7 in
#   - Columns: c1 = c2 = 16 in (square)
#   - Story height: H = 9 ft = 108 in
#   - f'c slab: 4000 psi
#   - f'c column: 6000 psi
#   - SDL = 20 psf, LL = 40 psf
#
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using Asap  # Register Asap units (psf, ksf, kip, etc.) with Unitful's @u_str
using StructuralSizer

@testset "EFM Stiffness Calculations - StructurePoint Validation" begin
    
    # ==========================================================================
    # Input parameters from StructurePoint example
    # ==========================================================================
    
    l1 = 18u"ft"           # Span length
    l2 = 14u"ft"           # Panel width (tributary width)
    h = 7u"inch"           # Slab thickness
    c1 = 16u"inch"         # Column dimension in span direction
    c2 = 16u"inch"         # Column dimension perpendicular to span
    H = 9u"ft"             # Story height
    
    fc_slab = 4000u"psi"   # Slab concrete strength
    fc_col = 6000u"psi"    # Column concrete strength
    
    SDL = 20psf         # Superimposed dead load
    LL = 40psf          # Live load
    
    # ==========================================================================
    # StructurePoint reference values (from document Section 3.2.2)
    # ==========================================================================
    
    # Concrete modulus values
    Ecs_ref = 3.834e6u"psi"     # E_cs = 33 × 150^1.5 × √4000 = 3,834×10³ psi (ACI 19.2.2.1.a, wc=150 pcf)
    Ecc_ref = 4.696e6u"psi"     # E_cc = 33 × 150^1.5 × √6000 = 4,696×10³ psi (ACI 19.2.2.1.a, wc=150 pcf)
    
    # Moment of inertia values
    Is_ref = 4802u"inch^4"      # Slab: l2 × h³/12 = 168 × 7³/12 = 4,802 in⁴
    Ic_ref = 5461u"inch^4"      # Column: c1⁴/12 = 16⁴/12 = 5,461 in⁴
    C_ref = 1325u"inch^4"       # Torsional constant C
    
    # Stiffness values (in in-lb)
    Ksb_ref = 351.766909e6     # Slab-beam stiffness
    Kc_ref = 1125.592936e6     # Column stiffness (single)
    Kt_ref = 367.484240e6      # Torsional member stiffness (single)
    Kec_ref = 554.074058e6     # Equivalent column stiffness
    
    # Distribution factors
    DF_ext_ref = 0.388         # Exterior joint
    DF_int_ref = 0.280         # Interior joint
    COF_ref = 0.507            # Carryover factor
    
    # ==========================================================================
    # Tests
    # ==========================================================================
    
    @testset "Material Properties" begin
        # Test concrete modulus (ACI 318 uses E = 57000√f'c for normalweight)
        Ecs = Ec(fc_slab)
        @test isapprox(ustrip(u"psi", Ecs), 3.605e6, rtol=0.01)  # Our formula: 57000√4000
        
        # Note: StructurePoint uses wc^1.5 × 33√f'c for normalweight concrete
        # which gives slightly different values. Our ACI 19.2.2.1 formula is correct.
    end
    
    @testset "Slab Moment of Inertia" begin
        Is = slab_moment_of_inertia(l2, h)
        Is_in4 = ustrip(u"inch^4", Is)
        @test isapprox(Is_in4, ustrip(u"inch^4", Is_ref), rtol=0.01)
    end
    
    @testset "Column Moment of Inertia" begin
        Ic = column_moment_of_inertia(c1, c2)
        Ic_in4 = ustrip(u"inch^4", Ic)
        @test isapprox(Ic_in4, ustrip(u"inch^4", Ic_ref), rtol=0.01)
    end
    
    @testset "Torsional Constant C" begin
        C = torsional_constant_C(h, c2)
        C_in4 = ustrip(u"inch^4", C)
        @test isapprox(C_in4, ustrip(u"inch^4", C_ref), rtol=0.02)
    end
    
    @testset "Slab-Beam Stiffness Ksb" begin
        # Use StructurePoint's Ecs value for validation
        Is = slab_moment_of_inertia(l2, h)
        sf = pca_slab_beam_factors(c1, l1, c2, l2)
        Ksb = slab_beam_stiffness_Ksb(Ecs_ref, Is, l1, c1, c2; k_factor=sf.k)
        Ksb_val = ustrip(u"lbf*inch", Ksb)
        @test isapprox(Ksb_val, Ksb_ref, rtol=0.02)
    end
    
    @testset "Column Stiffness Kc" begin
        # Use StructurePoint's Ecc value for validation
        Ic = column_moment_of_inertia(c1, c2)
        cf = pca_column_factors(H, h)
        Kc = column_stiffness_Kc(Ecc_ref, Ic, H, h; k_factor=cf.k)
        Kc_val = ustrip(u"lbf*inch", Kc)
        @test isapprox(Kc_val, Kc_ref, rtol=0.02)
    end
    
    @testset "Torsional Member Stiffness Kt" begin
        C = torsional_constant_C(h, c2)
        Kt = torsional_member_stiffness_Kt(Ecs_ref, C, l2, c2)
        Kt_val = ustrip(u"lbf*inch", Kt)
        @test isapprox(Kt_val, Kt_ref, rtol=0.03)
    end
    
    @testset "Equivalent Column Stiffness Kec" begin
        # For interior floor: 2 columns (upper + lower), 2 torsional members
        Kc_sum = 2 * Kc_ref * u"lbf*inch"
        Kt_sum = 2 * Kt_ref * u"lbf*inch"
        
        Kec = equivalent_column_stiffness_Kec(Kc_sum, Kt_sum)
        Kec_val = ustrip(u"lbf*inch", Kec)
        @test isapprox(Kec_val, Kec_ref, rtol=0.02)
    end
    
    @testset "Distribution Factors" begin
        Ksb = Ksb_ref * u"lbf*inch"
        Kec = Kec_ref * u"lbf*inch"
        
        # Exterior joint: DF = Ksb / (Ksb + Kec)
        DF_ext = distribution_factor_DF(Ksb, Kec, is_exterior=true)
        @test isapprox(DF_ext, DF_ext_ref, rtol=0.02)
        
        # Interior joint: DF = Ksb / (Ksb + Ksb + Kec)
        DF_int = distribution_factor_DF(Ksb, Kec, is_exterior=false, Ksb_adjacent=Ksb)
        @test isapprox(DF_int, DF_int_ref, rtol=0.02)
    end
    
    @testset "Carryover Factor" begin
        # COF now comes from PCA Table A1 lookup
        sf_cof = pca_slab_beam_factors(c1, l1, c2, l2)
        @test isapprox(sf_cof.COF, COF_ref, rtol=0.02)
    end
    
    @testset "Fixed-End Moment" begin
        # Self-weight of 7" slab: 7/12 × 150 = 87.5 psf
        sw = 7/12 * 150psf
        qu = 1.2 * (sw + SDL) + 1.6 * LL
        qu_ksf = uconvert(ksf, qu)
        
        sf_fem = pca_slab_beam_factors(c1, l1, c2, l2)
        FEM = fixed_end_moment_FEM(qu_ksf, l2, l1; m_factor=sf_fem.m)
        FEM_kipft = ustrip(kip*u"ft", FEM)
        
        # StructurePoint: FEM = 73.79 ft-kip
        @test isapprox(FEM_kipft, 73.79, rtol=0.02)
    end
end

@testset "Face-of-Support Moment Reduction" begin
    # From StructurePoint Table 5:
    # M_centerline at first interior support = 83.91 ft-kip
    # V at right of span 1-2 = 26.39 kips
    # c = 16 in = 16/12 ft
    
    # The span's far-end moment is chosen so the statics give V = 26.39 kips
    # at the interior support: V = w l1/2 − (M_left − M_right)/l1.
    w = 193psf * 14u"ft"
    l1 = 18u"ft"
    M_int = 83.91kip*u"ft"
    M_ext = M_int - (26.39kip - w * l1 / 2) * l1
    x = efm_face_offset(16u"inch", l1)
    _, M_face = span_face_moments(M_ext, M_int, w, l1, x, x)

    # StructurePoint Table 6 reports 66.99 ft-kip; M_cl − V x alone is 66.32.
    @test ustrip(kip*u"ft", M_face) ≈ 66.99 atol=0.1
end

@testset "EFM joint stiffness follows the frame" begin
    # ACI 318-11 §13.7.4: a rectangular column bends in the frame plane, so
    # its depth is c1 along the span.
    @test column_moment_of_inertia(24u"inch", 12u"inch") ≈ 12u"inch" * (24u"inch")^3 / 12

    l1, l2, h = 18u"ft", 14u"ft", 7u"inch"
    c1, c2 = 24u"inch", 12u"inch"
    Ecs = 3834u"ksi"
    Ecc = 4696u"ksi"
    H = 9u"ft"
    Is = StructuralSizer.slab_moment_of_inertia(l2, h)
    sf = StructuralSizer.pca_slab_beam_factors(c1, l1, c2, l2)
    Ksb = StructuralSizer.slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor = sf.k)
    spans = [StructuralSizer.EFMSpanProperties(i, i, i + 1, l1, l2, l1 - c1, h,
                                               c1, c2, c1, c2, Is, Ksb, sf.m, sf.COF, sf.k)
             for i in 1:2]

    # §13.7.5.1(a): the torsional member is as wide as c1, not c2.
    C = StructuralSizer.torsional_constant_C(h, c1)
    Kt = StructuralSizer.torsional_member_stiffness_Kt(Ecs, C, l2, c2)
    one = StructuralSizer._joint_ΣKt(spans, 1, [:edge, :interior, :edge], Ecs;
                                     column_shape = :rectangular, torsion_l2 = nothing)
    @test one ≈ Kt

    # R13.7.4: an interior frame has a panel on each side, so its end column
    # (a building edge column) has two members. An edge frame has one.
    interior = StructuralSizer._joint_ΣKt(spans, 1, [:edge, :interior, :edge], Ecs;
                                          column_shape = :rectangular, torsion_l2 = (l2, l2))
    @test interior ≈ 2 * Kt
    edge = StructuralSizer._joint_ΣKt(spans, 2, [:edge, :edge, :edge], Ecs;
                                      column_shape = :rectangular, torsion_l2 = (0.0u"m", l2))
    @test edge ≈ Kt
    # R13.7.5: each member uses the transverse span on its own side.
    uneven = StructuralSizer._joint_ΣKt(spans, 1, [:edge, :interior, :edge], Ecs;
                                        column_shape = :rectangular, torsion_l2 = (l2, 2l2))
    @test uneven ≈ Kt + StructuralSizer.torsional_member_stiffness_Kt(Ecs, C, 2l2, c2)
    @test_throws ArgumentError StructuralSizer._joint_ΣKt(
        spans, 1, [:edge, :interior, :edge], Ecs;
        column_shape = :rectangular, torsion_l2 = (0.0u"m", 0.0u"m"))

    # The Kec of an interior frame's end joint is stiffer with both members.
    Kec_pos = StructuralSizer._compute_joint_Kec(spans, [:edge, :interior, :edge], H, Ecs, Ecc)
    Kec_frame = StructuralSizer._compute_joint_Kec(spans, [:edge, :interior, :edge], H, Ecs, Ecc;
                                                   torsion_l2 = (l2, l2))
    @test Kec_frame[1] > Kec_pos[1]
    @test Kec_frame[2] ≈ Kec_pos[2]
end
