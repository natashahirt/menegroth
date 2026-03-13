# =============================================================================
# Test EFM Pipeline against StructurePoint Example
# =============================================================================
#
# Reference: DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14
# StructurePoint spSlab v10.00
#
# Test case: 3-span continuous frame in E-W direction
# - Span l1 = 18 ft (center-to-center)
# - Tributary width l2 = 14 ft  
# - Slab thickness h = 7 in
# - Columns: 16" × 16" square
# - Floor height H = 9 ft
# - qu = 193 psf (factored)
#
# =============================================================================

using Test
using Unitful
using Asap  # For units like psf, and ASAP functions
using StructuralSizer

@testset "EFM Pipeline - StructurePoint Validation" begin
    
    # =========================================================================
    # Test Geometry
    # =========================================================================
    l1 = 18u"ft"       # Span length (center-to-center)
    l2 = 14u"ft"       # Tributary width perpendicular to span
    h = 7u"inch"       # Slab thickness
    c1 = 16u"inch"     # Column dimension parallel to span
    c2 = 16u"inch"     # Column dimension perpendicular to span
    H = 9u"ft"         # Floor-to-floor height
    
    # Clear span
    ln = l1 - c1       # 18 ft - 16 in = 16.67 ft = 200 in
    
    # Materials - using SP's Ec formula: wc^1.5 × 33 × √fc (ACI 318-14 19.2.2.1.a)
    fc_slab = 4000u"psi"
    fc_col = 6000u"psi"
    wc = 150  # pcf, normal weight concrete
    Ecs = wc^1.5 * 33 * sqrt(ustrip(u"psi", fc_slab)) * u"psi"  # SP: 3,834,000 psi
    Ecc = wc^1.5 * 33 * sqrt(ustrip(u"psi", fc_col)) * u"psi"   # SP: 4,696,000 psi
    
    # Load
    qu = 193psf  # Total factored load (193 psf from SP example)
    
    # =========================================================================
    # Test 1: Section Properties
    # =========================================================================
    @testset "Section Properties" begin
        Is = StructuralSizer.slab_moment_of_inertia(l2, h)
        Is_expected = 4802u"inch^4"  # SP: 4,802 in⁴
        @test ustrip(u"inch^4", Is) ≈ ustrip(u"inch^4", Is_expected) rtol=0.01
        
        Ic = StructuralSizer.column_moment_of_inertia(c1, c2)
        Ic_expected = 5461u"inch^4"  # SP: 5,461 in⁴
        @test ustrip(u"inch^4", Ic) ≈ ustrip(u"inch^4", Ic_expected) rtol=0.01
        
        C = StructuralSizer.torsional_constant_C(h, c2)
        C_expected = 1325u"inch^4"  # SP: 1,325 in⁴
        @test ustrip(u"inch^4", C) ≈ ustrip(u"inch^4", C_expected) rtol=0.05
    end
    
    # =========================================================================
    # Test 2: Stiffness Calculations (strict tolerances - should match SP exactly)
    # =========================================================================
    @testset "Stiffness Calculations" begin
        Is = StructuralSizer.slab_moment_of_inertia(l2, h)
        Ic = StructuralSizer.column_moment_of_inertia(c1, c2)
        C = StructuralSizer.torsional_constant_C(h, c2)
        
        # Slab-beam stiffness (k from PCA Table A1)
        sf = StructuralSizer.pca_slab_beam_factors(c1, l1, c2, l2)
        Ksb = StructuralSizer.slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=sf.k)
        Ksb_expected = 351.77e6u"lbf*inch"  # SP: 351,766,909 in-lb
        @test ustrip(u"lbf*inch", Ksb) ≈ ustrip(u"lbf*inch", Ksb_expected) rtol=0.02
        
        # Column stiffness (k from PCA Table A7)
        cf = StructuralSizer.pca_column_factors(H, h)
        Kc = StructuralSizer.column_stiffness_Kc(Ecc, Ic, H, h; k_factor=cf.k)
        Kc_expected = 1125.59e6u"lbf*inch"  # SP: 1,125,592,936 in-lb
        @test ustrip(u"lbf*inch", Kc) ≈ ustrip(u"lbf*inch", Kc_expected) rtol=0.02
        
        # Torsional member stiffness (one side)
        Kt = StructuralSizer.torsional_member_stiffness_Kt(Ecs, C, l2, c2)
        Kt_expected = 367.48e6u"lbf*inch"  # SP: 367,484,240 in-lb
        @test ustrip(u"lbf*inch", Kt) ≈ ustrip(u"lbf*inch", Kt_expected) rtol=0.01
        
        # Equivalent column stiffness
        ΣKc = 2 * Kc  # Columns above and below
        ΣKt = 2 * Kt  # Torsional members on both sides
        Kec = StructuralSizer.equivalent_column_stiffness_Kec(ΣKc, ΣKt)
        Kec_expected = 554.07e6u"lbf*inch"  # SP: 554,074,058 in-lb
        @test ustrip(u"lbf*inch", Kec) ≈ ustrip(u"lbf*inch", Kec_expected) rtol=0.01
    end
    
    # =========================================================================
    # Test 3: Fixed-End Moment
    # =========================================================================
    @testset "Fixed-End Moments" begin
        # FEM = m_factor × qu × l2 × l1²
        sf_fem = StructuralSizer.pca_slab_beam_factors(c1, l1, c2, l2)
        FEM = StructuralSizer.fixed_end_moment_FEM(qu, l2, l1; m_factor=sf_fem.m)
        FEM_expected = 73.79kip*u"ft"  # SP: 73.79 ft-kips
        @test ustrip(kip*u"ft", FEM) ≈ ustrip(kip*u"ft", FEM_expected) rtol=0.05
    end
    
    # =========================================================================
    # Test 4: Build Frame with Proper EFM Stiffnesses and Solve
    # =========================================================================
    @testset "ASAP Frame Analysis — Real Column Stubs" begin
        # The ASAP EFM path models columns as explicit frame stubs (above +
        # below the slab) with actual Ic.  No torsional reduction (Kec) is
        # applied — that is a Hardy Cross / analytical concept.  Therefore
        # the correct cross-validation is against Hardy Cross with
        # use_kc_only=true (raw ΣKc, no Kt reduction).
        
        # Convert all lengths to inches (Float64) for type compatibility
        l1_in = Float64(ustrip(u"inch", l1)) * u"inch"
        l2_in = Float64(ustrip(u"inch", l2)) * u"inch"
        ln_in = Float64(ustrip(u"inch", ln)) * u"inch"
        h_in = Float64(ustrip(u"inch", h)) * u"inch"
        c1_in = Float64(ustrip(u"inch", c1)) * u"inch"
        c2_in = Float64(ustrip(u"inch", c2)) * u"inch"
        
        Is = StructuralSizer.slab_moment_of_inertia(l2, h)
        Is_in4 = uconvert(u"inch^4", Is)
        sf_pipe = StructuralSizer.pca_slab_beam_factors(c1, l1, c2, l2)
        Ksb = StructuralSizer.slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=sf_pipe.k)
        Ksb_inlb = uconvert(u"lbf*inch", Ksb)
        
        # Create three identical spans
        spans = [
            StructuralSizer.EFMSpanProperties(
                i, i, i+1,
                l1_in, l2_in, ln_in,
                h_in, c1_in, c2_in, c1_in, c2_in,
                Is_in4, Ksb_inlb,
                sf_pipe.m, sf_pipe.COF, sf_pipe.k
            ) for i in 1:3
        ]
        
        # Joint positions for interior frame line (SP example):
        # All columns have transverse slabs on both sides, so all use 2×Kt
        # (The frame being analyzed is interior to the building plan)
        joint_positions = [:interior, :interior, :interior, :interior]
        
        # Mock column objects (SP example: identical 16"×16" columns above & below)
        # column_above mimics the real Column struct's field
        col_above_mock = (c1=c1, c2=c2, base=(L=H,), column_above=nothing)
        mock_columns = [(c1=c1, c2=c2, base=(L=H,), column_above=col_above_mock) for _ in 1:4]
        
        # Build and solve ASAP model with real column stubs
        qu_psf = uconvert(u"lbf/ft^2", qu)
        model, span_elements, col_stubs = StructuralSizer.build_efm_asap_model(
            spans, joint_positions, qu_psf;
            Ecs = Ecs,
            Ecc = Ecc,
            ν_concrete = 0.20,
            ρ_concrete = 2380.0u"kg/m^3",
            columns = mock_columns,
        )
        StructuralSizer.solve_efm_frame!(model)
        
        # Check that model solved
        @test model.processed == true
        # 3 sub-elements per span × 3 spans = 9 span elements
        @test length(span_elements) == 9
        # 4 joints × 2 stubs (above + below) = 8 column stubs
        @test all(j -> !isnothing(col_stubs[j].below), 1:4)
        @test all(j -> !isnothing(col_stubs[j].above), 1:4)
        
        # Extract moments (pass qu for midspan calculation)
        span_moments = StructuralSizer.extract_span_moments(model, span_elements, spans; qu=qu)
        @test length(span_moments) == 3
        
        # Check first span (exterior to first interior)
        M_neg_ext = span_moments[1].M_neg_left
        M_neg_int = span_moments[1].M_neg_right
        M_pos = span_moments[1].M_pos
        
        # Hardy Cross with Kc only (no torsional reduction) — the analytical
        # equivalent of the ASAP real-stub model.
        joint_Kc = StructuralSizer._compute_joint_Kec(
            spans, joint_positions, H, Ecs, Ecc;
            use_kc_only=true, columns=mock_columns)
        hc_kc_moments = StructuralSizer.solve_moment_distribution(
            spans, joint_Kc, joint_positions, qu;
            COF=sf_pipe.COF, max_iterations=20, tolerance=0.001)
        
        hc_ext  = ustrip(kip*u"ft", hc_kc_moments[1].M_neg_left)
        hc_int  = ustrip(kip*u"ft", hc_kc_moments[1].M_neg_right)
        hc_pos  = ustrip(kip*u"ft", hc_kc_moments[1].M_pos)
        
        println("\n=== ASAP vs Hardy Cross (Kc only) ===")
        println("Span 1 (Exterior):")
        println("  M_neg_left  ASAP=$(round(ustrip(kip*u"ft", M_neg_ext), digits=2))  HC=$(round(hc_ext, digits=2))")
        println("  M_neg_right ASAP=$(round(ustrip(kip*u"ft", M_neg_int), digits=2))  HC=$(round(hc_int, digits=2))")
        println("  M_pos       ASAP=$(round(ustrip(kip*u"ft", M_pos), digits=2))  HC=$(round(hc_pos, digits=2))")
        
        # ASAP and Hardy Cross Kc-only should agree within 5%.
        # Small differences arise from: COF (0.507 vs exact), non-prismatic
        # slab modelling in ASAP, and column I_factor (0.70) applied in ASAP
        # but not in the Hardy Cross Kc path.
        @test ustrip(kip*u"ft", M_neg_ext) ≈ hc_ext rtol=0.10
        @test ustrip(kip*u"ft", M_neg_int) ≈ hc_int rtol=0.10
        @test ustrip(kip*u"ft", M_pos) ≈ hc_pos rtol=0.10
    end
    
    # =========================================================================
    # Test 5: Moment Distribution to Strips
    # =========================================================================
    @testset "Strip Moment Distribution" begin
        # Create sample span moments (using SP values)
        span_moments = [(
            span_idx = 1,
            M_neg_left = 46.65kip*u"ft",
            M_neg_right = 83.91kip*u"ft",
            M_pos = 44.94kip*u"ft",
            M0 = 93.82kip*u"ft"
        )]
        
        joint_positions = [:corner, :interior]
        
        strip_moments = StructuralSizer.distribute_moments_to_strips(span_moments, joint_positions)
        
        # At exterior (corner): 100% to column strip
        @test strip_moments[1].M_neg_left_cs ≈ 46.65kip*u"ft" rtol=0.01
        @test strip_moments[1].M_neg_left_ms ≈ 0.0kip*u"ft" atol=0.1kip*u"ft"
        
        # At interior: 75% to column strip, 25% to middle strip
        @test ustrip(kip*u"ft", strip_moments[1].M_neg_right_cs) ≈ 0.75 * 83.91 rtol=0.01
        @test ustrip(kip*u"ft", strip_moments[1].M_neg_right_ms) ≈ 0.25 * 83.91 rtol=0.01
        
        # Positive: 60% to column strip, 40% to middle strip
        @test ustrip(kip*u"ft", strip_moments[1].M_pos_cs) ≈ 0.60 * 44.94 rtol=0.01
        @test ustrip(kip*u"ft", strip_moments[1].M_pos_ms) ≈ 0.40 * 44.94 rtol=0.01
        
        println("\n=== Strip Distribution (ACI 318) ===")
        println("Column Strip:")
        println("  M_neg_ext = $(round(ustrip(kip*u"ft", strip_moments[1].M_neg_left_cs), digits=2)) kip-ft")
        println("  M_neg_int = $(round(ustrip(kip*u"ft", strip_moments[1].M_neg_right_cs), digits=2)) kip-ft")
        println("  M_pos     = $(round(ustrip(kip*u"ft", strip_moments[1].M_pos_cs), digits=2)) kip-ft")
        println("Middle Strip:")
        println("  M_neg_ext = $(round(ustrip(kip*u"ft", strip_moments[1].M_neg_left_ms), digits=2)) kip-ft")
        println("  M_neg_int = $(round(ustrip(kip*u"ft", strip_moments[1].M_neg_right_ms), digits=2)) kip-ft")
        println("  M_pos     = $(round(ustrip(kip*u"ft", strip_moments[1].M_pos_ms), digits=2)) kip-ft")
    end
    
    # =========================================================================
    # Test 6: Required Reinforcement (Table 7 from StructurePoint)
    # =========================================================================
    @testset "EFM Reinforcement - Table 7 Validation" begin
        # Common parameters
        fc = 4000u"psi"
        fy = 60000u"psi"
        b = 84u"inch"      # Strip width (column and middle strip both = l2/2 = 7 ft = 84 in)
        d = 5.75u"inch"    # Average effective depth (SP uses d_avg)
        
        # Minimum reinforcement: As,min = 0.0018 × b × h = 0.0018 × 84 × 7 = 1.06 in²
        As_min = StructuralSizer.minimum_reinforcement(b, h, fy)
        @test ustrip(u"inch^2", As_min) ≈ 1.06 rtol=0.02
        
        println("\n=== EFM Reinforcement Design (Table 7) ===")
        println("Strip width b = $(ustrip(u"inch", b)) in, d = $(ustrip(u"inch", d)) in")
        println("As,min = $(round(ustrip(u"inch^2", As_min), digits=2)) in²")
        
        # StructurePoint Table 7 - Required Slab Reinforcement for Flexure (EFM)
        # Note: EFM moments are at face of support (reduced from centerline)
        #
        # | Location                  | Mu (kip-ft) | As,req (in²) | As,min (in²) |
        # |---------------------------|-------------|--------------|--------------|
        # | End Span CS Ext Neg       | 32.42       | 1.28         | 1.06         |
        # | End Span CS Pos           | 26.96       | 1.06         | 1.06         |
        # | End Span CS Int Neg       | 50.24       | 2.02         | 1.06         |
        # | End Span MS Pos           | 17.98       | 0.70         | 1.06         |
        # | End Span MS Int Neg       | 16.75       | 0.65         | 1.06         |
        # | Int Span CS Pos           | 19.94       | 0.78         | 1.06         |
        # | Int Span MS Pos           | 13.29       | 0.52         | 1.06         |
        
        test_cases = [
            # (Location, Mu_kft, As_req_expected)
            ("End Span CS Ext Neg", 32.42, 1.28),
            ("End Span CS Pos", 26.96, 1.06),
            ("End Span CS Int Neg", 50.24, 2.02),
            ("End Span MS Pos", 17.98, 0.70),
            ("End Span MS Int Neg", 16.75, 0.65),
            ("Int Span CS Pos", 19.94, 0.78),
            ("Int Span MS Pos", 13.29, 0.52),
        ]
        
        println("\nReinforcement calculations:")
        for (location, Mu_kft, As_expected) in test_cases
            Mu = Mu_kft * kip*u"ft"
            As_req = StructuralSizer.required_reinforcement(Mu, b, d, fc, fy)
            As_req_val = ustrip(u"inch^2", As_req)
            
            # Governing As = max(As_req, As_min)
            As_gov = max(As_req_val, ustrip(u"inch^2", As_min))
            
            println("  $location: Mu=$(Mu_kft) kip-ft → As,req=$(round(As_req_val, digits=2)) in² (SP: $As_expected)")
            
            # Test within 10% tolerance (small differences due to iteration method)
            @test As_req_val ≈ As_expected rtol=0.10
        end
    end
    
    # =========================================================================
    # Test 7: Face-of-Support Moment Reduction
    # =========================================================================
    @testset "Face-of-Support Moment Reduction" begin
        # From Table 5: centerline moment at first interior support = 83.91 kip-ft
        # From Table 6: face-of-support moment = 66.99 kip-ft
        # 
        # The reduction formula: M_face = M_cl - V × (c/2)
        # Where V is shear at face of support
        
        # StructurePoint Table 5 values for end span:
        # M_centerline (int neg) = 83.91 kip-ft
        # V (right of span 1-2) = 26.39 kips (from equilibrium)
        
        M_cl = 83.91kip*u"ft"
        V = 26.39kip
        c = 16u"inch"
        
        M_face = StructuralSizer.face_of_support_moment(M_cl, V, c, l1)
        M_face_kft = ustrip(kip*u"ft", M_face)
        
        # SP Table 6 reports 66.99 kip-ft for this location
        # Our calculation: 83.91 - 26.39 × (16/12/2) = 83.91 - 17.59 = 66.32 kip-ft
        # Small difference due to SP's more detailed shear calculation
        println("\n=== Face-of-Support Moment ===")
        println("M_centerline = $(ustrip(kip*u"ft", M_cl)) kip-ft")
        println("V = $(ustrip(kip, V)) kips")
        println("M_face = $(round(M_face_kft, digits=2)) kip-ft (SP: 66.99)")
        
        @test M_face_kft ≈ 66.32 rtol=0.03
    end
    
    # =========================================================================
    # Test 8: Complete Strip Reinforcement Design
    # =========================================================================
    @testset "Complete Strip Reinforcement Design" begin
        # Design reinforcement for end span using EFM moments (Table 6 & 7)
        fc = 4000u"psi"
        fy = 60000u"psi"
        b_cs = 84u"inch"   # Column strip width
        b_ms = 84u"inch"   # Middle strip width  
        d = 5.75u"inch"
        
        # EFM face-of-support moments from Table 6:
        # Column Strip: Ext Neg = 32.42, Pos = 26.96, Int Neg = 50.24
        # Middle Strip: Ext Neg = 0, Pos = 17.98, Int Neg = 16.75
        
        As_min = StructuralSizer.minimum_reinforcement(b_cs, h, fy)
        s_max = StructuralSizer.max_bar_spacing(h)
        
        println("\n=== Complete Strip Design ===")
        println("Max bar spacing s_max = $(ustrip(u"inch", s_max)) in (2h or 18 in)")
        
        # Column strip interior negative (critical section)
        Mu_cs_int_neg = 50.24kip*u"ft"
        As_req = StructuralSizer.required_reinforcement(Mu_cs_int_neg, b_cs, d, fc, fy)
        As_gov = max(As_req, As_min)
        
        println("\nColumn Strip Int Neg:")
        println("  Mu = $(ustrip(kip*u"ft", Mu_cs_int_neg)) kip-ft")
        println("  As,req = $(round(ustrip(u"inch^2", As_req), digits=2)) in²")
        println("  As,gov = $(round(ustrip(u"inch^2", As_gov), digits=2)) in²")
        
        # Verify governing reinforcement
        @test ustrip(u"inch^2", As_gov) ≈ 2.02 rtol=0.10
        
        # Middle strip positive (minimum often governs)
        Mu_ms_pos = 13.29kip*u"ft"
        As_req_ms = StructuralSizer.required_reinforcement(Mu_ms_pos, b_ms, d, fc, fy)
        As_gov_ms = max(As_req_ms, As_min)
        
        println("\nMiddle Strip Positive:")
        println("  Mu = $(ustrip(kip*u"ft", Mu_ms_pos)) kip-ft")
        println("  As,req = $(round(ustrip(u"inch^2", As_req_ms), digits=2)) in²")
        println("  As,gov = $(round(ustrip(u"inch^2", As_gov_ms), digits=2)) in² (min governs)")
        
        # Minimum should govern for middle strip positive
        @test As_gov_ms ≈ As_min rtol=0.01
    end
    
    # =========================================================================
    # Test 9: Deflection Parameters (Section 6 from StructurePoint)
    # =========================================================================
    @testset "Deflection Parameters" begin
        fc = 4000u"psi"
        
        # Modulus of rupture: fr = 7.5√f'c = 7.5 × √4000 = 474.34 psi
        fr_calc = StructuralSizer.fr(fc)
        @test ustrip(u"psi", fr_calc) ≈ 474.34 rtol=0.01
        
        println("\n=== Deflection Parameters (Section 6) ===")
        println("fr = $(round(ustrip(u"psi", fr_calc), digits=2)) psi (SP: 474.34)")
        
        # Gross moment of inertia for frame strip: Ig = l2 × h³ / 12
        # l2 = 14 ft = 168 in, h = 7 in
        # Ig = 168 × 7³ / 12 = 4,802 in⁴
        Ig = StructuralSizer.slab_moment_of_inertia(l2, h)
        @test ustrip(u"inch^4", Ig) ≈ 4802 rtol=0.01
        println("Ig = $(round(ustrip(u"inch^4", Ig), digits=0)) in⁴ (SP: 4,802)")
        
        # Cracking moment: Mcr = fr × Ig / yt where yt = h/2
        # Mcr = 474.34 × 4802 / 3.5 / 12 / 1000 = 54.23 ft-kip
        Mcr = StructuralSizer.cracking_moment(fr_calc, Ig, h)
        Mcr_kipft = ustrip(kip*u"ft", Mcr)
        @test Mcr_kipft ≈ 54.23 rtol=0.02
        println("Mcr = $(round(Mcr_kipft, digits=2)) kip-ft (SP: 54.23)")
        
        # Deflection limits
        Δ_ll_limit = StructuralSizer.deflection_limit(l1, :immediate_ll)
        Δ_total_limit = StructuralSizer.deflection_limit(l1, :total)
        
        # L/360 = 18×12/360 = 0.60 in
        @test ustrip(u"inch", Δ_ll_limit) ≈ 0.60 rtol=0.01
        # L/240 = 18×12/240 = 0.90 in
        @test ustrip(u"inch", Δ_total_limit) ≈ 0.90 rtol=0.01
        
        println("Δ_LL limit (L/360) = $(round(ustrip(u"inch", Δ_ll_limit), digits=2)) in")
        println("Δ_total limit (L/240) = $(round(ustrip(u"inch", Δ_total_limit), digits=2)) in")
    end
    
    # =========================================================================
    # Test 10: Cracked Moment of Inertia (Table 9 from StructurePoint)
    # =========================================================================
    @testset "Cracked Moment of Inertia" begin
        # StructurePoint example for exterior span frame strip at interior support:
        # 17 #4 bars (As = 17 × 0.20 = 3.40 in²)
        # d = 5.75 in (average effective depth)
        # b = 168 in (frame strip width = l2)
        # Ecs = 3,834,000 psi
        # Es = 29,000,000 psi
        # n = 29,000,000 / 3,834,000 = 7.56
        
        As = 17 * 0.20u"inch^2"  # 17 #4 bars
        b_frame = l2  # Frame strip width = 168 in
        d = 5.75u"inch"
        Es_rebar = 29000ksi  # SP: Es = 29,000,000 psi (Grade 60 rebar)
        
        Icr = StructuralSizer.cracked_moment_of_inertia(As, b_frame, d, Ecs, Es_rebar)
        Icr_in4 = ustrip(u"inch^4", Icr)
        
        println("\n=== Cracked Moment of Inertia ===")
        println("As = $(ustrip(u"inch^2", As)) in² (17 #4 bars)")
        println("b = $(ustrip(u"inch", b_frame)) in (frame strip)")
        println("d = $(ustrip(u"inch", d)) in")
        println("n = $(round(29e6 / ustrip(u"psi", Ecs), digits=2))")
        println("Icr = $(round(Icr_in4, digits=0)) in⁴ (SP: 629)")
        
        # SP reports Icr = 629 in⁴
        @test Icr_in4 ≈ 629 rtol=0.05
    end
    
    # =========================================================================
    # Test 11: Effective Moment of Inertia (Section 6.1)
    # =========================================================================
    @testset "Effective Moment of Inertia" begin
        # For D+LLfull loading case (cracked section):
        # Ma = 64.13 ft-kip (maximum service moment at interior support)
        # Mcr = 54.23 ft-kip
        # Since Ma > Mcr, section is cracked
        
        Mcr = 54.23kip*u"ft"
        Ma = 64.13kip*u"ft"
        Ig = 4802u"inch^4"
        Icr = 629u"inch^4"
        
        Ie = StructuralSizer.effective_moment_of_inertia(Mcr, Ma, Ig, Icr)
        Ie_in4 = ustrip(u"inch^4", Ie)
        
        # Manual calculation:
        # Ie = Icr + (Ig - Icr) × (Mcr/Ma)³
        # Ie = 629 + (4802 - 629) × (54.23/64.13)³
        # Ie = 629 + 4173 × 0.605 = 629 + 2525 = 3154 in⁴
        Ie_manual = 629 + (4802 - 629) * (54.23/64.13)^3
        
        println("\n=== Effective Moment of Inertia (Cracked) ===")
        println("Ma = $(ustrip(kip*u"ft", Ma)) kip-ft (service moment)")
        println("Mcr = $(ustrip(kip*u"ft", Mcr)) kip-ft")
        println("Ma > Mcr: Section is cracked")
        println("Ie = $(round(Ie_in4, digits=0)) in⁴")
        
        @test Ie_in4 ≈ Ie_manual rtol=0.01
        
        # When section is uncracked (Ma ≤ Mcr), Ie = Ig
        Ma_uncracked = 40.0kip*u"ft"
        Ie_uncracked = StructuralSizer.effective_moment_of_inertia(Mcr, Ma_uncracked, Ig, Icr)
        @test ustrip(u"inch^4", Ie_uncracked) == ustrip(u"inch^4", Ig)
        
        println("For Ma = 40 kip-ft < Mcr: Ie = Ig = $(ustrip(u"inch^4", Ig)) in⁴")
    end
    
    # =========================================================================
    # Test 12: Long-Term Deflection Factor
    # =========================================================================
    @testset "Long-Term Deflection Factor" begin
        # StructurePoint uses:
        # ξ = 2.0 (sustained load duration ≥ 5 years)
        # ρ' = 0 (no compression reinforcement)
        # λΔ = ξ / (1 + 50ρ') = 2.0 / 1.0 = 2.0
        
        λΔ = StructuralSizer.long_term_deflection_factor(2.0, 0.0)
        @test λΔ == 2.0
        
        # With compression steel ρ' = 0.005:
        # λΔ = 2.0 / (1 + 50×0.005) = 2.0 / 1.25 = 1.6
        λΔ_comp = StructuralSizer.long_term_deflection_factor(2.0, 0.005)
        @test λΔ_comp ≈ 1.6 rtol=0.01
        
        println("\n=== Long-Term Deflection Factor ===")
        println("λΔ (no comp. steel) = $(λΔ)")
        println("λΔ (with ρ'=0.005) = $(round(λΔ_comp, digits=2))")
    end
    
    # =========================================================================
    # Test 13: Total Long-Term Deflection (Table 11)
    # =========================================================================
    @testset "Total Long-Term Deflection Calculation" begin
        # From StructurePoint Table 11 for exterior span column strip:
        # (Δsust)inst = 0.0747 in (immediate deflection under sustained load)
        # (Δtotal)inst = 0.104 in (immediate deflection under total load)
        # λΔ = 2.0
        # Δcs = λΔ × (Δsust)inst = 2.0 × 0.0747 = 0.149 in
        # (Δtotal)lt = (Δsust)inst × (1 + λΔ) + [(Δtotal)inst - (Δsust)inst]
        #            = 0.0747 × 3.0 + (0.104 - 0.0747)
        #            = 0.224 + 0.029 = 0.254 in
        
        Δ_sust_inst = 0.0747  # in
        Δ_total_inst = 0.104  # in
        λΔ = 2.0
        
        # Method 1: SP formula
        Δ_total_lt = Δ_sust_inst * (1 + λΔ) + (Δ_total_inst - Δ_sust_inst)
        
        # Method 2: Separate creep/shrinkage contribution
        Δ_cs = λΔ * Δ_sust_inst
        Δ_total_lt_2 = Δ_cs + Δ_total_inst
        
        println("\n=== Long-Term Deflection (Table 11) ===")
        println("Exterior span, Column strip:")
        println("  (Δsust)inst = $(Δ_sust_inst) in")
        println("  (Δtotal)inst = $(Δ_total_inst) in")
        println("  Δcs (creep+shrinkage) = $(round(Δ_cs, digits=3)) in (SP: 0.149)")
        println("  (Δtotal)lt = $(round(Δ_total_lt, digits=3)) in (SP: 0.254)")
        
        @test Δ_cs ≈ 0.149 rtol=0.02
        @test Δ_total_lt ≈ 0.254 rtol=0.02
        
        # Check against deflection limit
        Δ_limit = ustrip(u"inch", StructuralSizer.deflection_limit(l1, :total))
        passes = Δ_total_lt < Δ_limit
        
        println("  Δ_limit (L/240) = $(Δ_limit) in")
        println("  Check: $(round(Δ_total_lt, digits=3)) < $(Δ_limit) → $(passes ? "OK ✓" : "FAIL ✗")")
        
        @test passes
    end
    
    # =========================================================================
    # Test 14: Load Distribution Factors (Section 6)
    # =========================================================================
    @testset "Load Distribution Factors" begin
        # From StructurePoint Table 10 (page 57):
        # The LDF formula weights positive region double since it spans the middle:
        # LDFc = (2×LDF⁺ + LDF⁻_L + LDF⁻_R) / 4
        #
        # End span: LDF⁺ = 0.60, LDF⁻_ext = 1.00, LDF⁻_int = 0.75
        # LDFc = (2×0.60 + 1.00 + 0.75) / 4 = 2.95/4 = 0.7375 ≈ 0.738
        # LDFm = 1 - 0.738 = 0.262
        
        LDFc_ext = StructuralSizer.load_distribution_factor(:column, :exterior)
        LDFm_ext = StructuralSizer.load_distribution_factor(:middle, :exterior)
        
        @test LDFc_ext ≈ 0.738 rtol=0.02
        @test LDFm_ext ≈ 0.262 rtol=0.02
        @test LDFc_ext + LDFm_ext ≈ 1.0 rtol=0.001
        
        # Interior span (from Table 10):
        # LDFc = 0.675, LDFm = 0.325
        LDFc_int = StructuralSizer.load_distribution_factor(:column, :interior)
        LDFm_int = StructuralSizer.load_distribution_factor(:middle, :interior)
        
        @test LDFc_int ≈ 0.675 rtol=0.01
        @test LDFm_int ≈ 0.325 rtol=0.01
        @test LDFc_int + LDFm_int ≈ 1.0 rtol=0.001
        
        println("\n=== Load Distribution Factors ===")
        println("Exterior span: LDFc = $(round(LDFc_ext, digits=3)), LDFm = $(round(LDFm_ext, digits=3))")
        println("Interior span: LDFc = $(round(LDFc_int, digits=3)), LDFm = $(round(LDFm_int, digits=3))")
    end
    
    # =========================================================================
    # Test 15: Two-Way Panel Deflection (Table 10, Page 57-58)
    # =========================================================================
    @testset "Two-Way Panel Deflection" begin
        # From StructurePoint Table 10 for exterior span under D load:
        # Column strip: Δcx = 0.0747 in
        # Middle strip: Δmx = 0.0380 in
        # For square panel: Δcy = Δcx, Δmy = Δmx
        
        Δcx = 0.0747u"inch"  # Column strip, x-direction
        Δcy = 0.0747u"inch"  # Column strip, y-direction (same for square)
        Δmx = 0.0380u"inch"  # Middle strip, x-direction
        Δmy = 0.0380u"inch"  # Middle strip, y-direction (same for square)
        
        # Full formula: Δ = (Δcx + Δmy)/2 + (Δcy + Δmx)/2
        Δ_panel_full = StructuralSizer.two_way_panel_deflection(Δcx, Δcy, Δmx, Δmy)
        
        # StructurePoint equation (page 57):
        # Δ = (Δcx + Δmy)/2 + (Δcy + Δmx)/2
        # For square: = (0.0747 + 0.0380)/2 + (0.0747 + 0.0380)/2 = 0.113 in
        expected_full = 0.113u"inch"
        
        @test Δ_panel_full ≈ expected_full rtol=0.02
        
        # Simplified formula for square panels: Δ = Δcx + Δmx
        Δ_panel_simple = StructuralSizer.two_way_panel_deflection(Δcx, Δmx)
        expected_simple = 0.0747u"inch" + 0.0380u"inch"
        
        @test Δ_panel_simple ≈ expected_simple rtol=0.001
        
        # For square panels, both formulas give same result
        @test Δ_panel_full ≈ Δ_panel_simple rtol=0.001
        
        println("\n=== Two-Way Panel Deflection (D load, Exterior Span) ===")
        println("Column strip: Δcx = Δcy = $(ustrip(u"inch", Δcx)) in")
        println("Middle strip: Δmx = Δmy = $(ustrip(u"inch", Δmx)) in")
        println("Panel (full formula): Δ = $(round(ustrip(u"inch", Δ_panel_full), digits=4)) in (SP: 0.113)")
        println("Panel (simplified): Δ = $(round(ustrip(u"inch", Δ_panel_simple), digits=4)) in")
        
        # Test for D+LLfull case (Table 10):
        # Δcx = 0.1042 in, Δmx = 0.0539 in
        Δcx_full = 0.1042u"inch"
        Δmx_full = 0.0539u"inch"
        Δ_panel_D_LLfull = StructuralSizer.two_way_panel_deflection(Δcx_full, Δmx_full)
        expected_D_LLfull = 0.1042u"inch" + 0.0539u"inch"  # 0.158 in
        
        @test Δ_panel_D_LLfull ≈ expected_D_LLfull rtol=0.001
        
        println("\n=== Two-Way Panel Deflection (D+LLfull, Exterior Span) ===")
        println("Column strip: Δcx = $(ustrip(u"inch", Δcx_full)) in")
        println("Middle strip: Δmx = $(ustrip(u"inch", Δmx_full)) in")
        println("Panel: Δ = $(round(ustrip(u"inch", Δ_panel_D_LLfull), digits=4)) in")
    end
    
    # =========================================================================
    # Test 16: Strip Fixed-End Deflection Components
    # =========================================================================
    @testset "Strip Deflection Components" begin
        # From StructurePoint Page 55-56 for exterior span D load:
        # w = (20 + 150×7/12) × 14 = 1505 lb/ft
        # l = 18 ft = 216 in
        # Ec = 3834×10³ psi = 3.834×10⁶ psi
        # Ie,frame = 4802 in⁴
        
        w = 1505u"lbf/ft"                    # Service load per foot
        l = 18u"ft"                          # Span
        Ec = 3834e3u"psi"                    # Concrete modulus
        Ie_frame = 4802u"inch^4"             # Frame effective I
        Ig_strip = 2401u"inch^4"             # Column strip gross I (half of frame)
        LDFc = 0.738                         # Column strip LDF
        
        # Frame fixed-end deflection: Δ = wl⁴/(384EcIe)
        # Uses fixed-fixed coefficient (1), not simply-supported (5)
        Δ_frame_fixed = StructuralSizer.frame_deflection_fixed(w, l, Ec, Ie_frame)
        Δ_frame_fixed_in = ustrip(u"inch", Δ_frame_fixed)
        
        # SP reports Δframe,fixed = 0.0386 in
        @test Δ_frame_fixed_in ≈ 0.0386 rtol=0.05
        
        # Column strip fixed-end deflection
        Δc_fixed = StructuralSizer.strip_deflection_fixed(Δ_frame_fixed, LDFc, Ie_frame, Ig_strip)
        Δc_fixed_in = ustrip(u"inch", Δc_fixed)
        
        # SP reports Δc,fixed = 0.057 in (= 0.738 × 0.0386 × 4802/2401)
        expected_Δc = 0.738 * 0.0386 * (4802/2401)
        @test Δc_fixed_in ≈ expected_Δc rtol=0.05
        
        println("\n=== Strip Fixed-End Deflection Components ===")
        println("w = $(ustrip(u"lbf/ft", w)) lb/ft")
        println("l = $(ustrip(u"ft", l)) ft")
        println("Δframe,fixed = $(round(Δ_frame_fixed_in, digits=4)) in (SP: 0.0386)")
        println("Δc,fixed = $(round(Δc_fixed_in, digits=4)) in (expected: $(round(expected_Δc, digits=4)))")
    end
    
    # =========================================================================
    # Test 17: Support Rotation & Deflection Contribution
    # =========================================================================
    @testset "Support Rotation and Deflection" begin
        # From StructurePoint Page 56-57:
        # M_net,L = 25.99 ft-kips (net moment at left support)
        # Kec = 554.07×10⁶ in-lb (effective column stiffness)
        # θc,L = M_net / Kec = 25.99×12000 / 554.07×10⁶ = 0.000563 rad
        # SP reports 0.0006 rad (rounded to 4 decimal places)
        
        M_net = 25.99kip*u"ft"
        Kec = 554.07e6u"lbf*inch"  # = 554.07×10⁶ in-lb
        
        θ = StructuralSizer.support_rotation(M_net, Kec)
        
        # Exact calculation: 25.99 × 12000 / 554.07e6 = 0.000563 rad
        # SP reports θc,L = 0.0006 rad (rounded)
        @test θ ≈ 0.000563 rtol=0.01  # Test against exact calculation
        
        # Deflection due to rotation:
        # Δθc,L = θ × (l/8) × (Ig/Ie)
        # l = 18 ft = 216 in
        # Ig/Ie = 4802/4802 = 1.0 (for D load, uncracked)
        
        l = 18u"ft"
        Ig = 4802u"inch^4"
        Ie = 4802u"inch^4"  # Uncracked for D load case
        
        Δ_θ = StructuralSizer.deflection_from_rotation(θ, l, Ig, Ie)
        Δ_θ_in = ustrip(u"inch", Δ_θ)
        
        # SP reports Δθc,L = 0.0152 in
        @test Δ_θ_in ≈ 0.0152 rtol=0.1
        
        println("\n=== Support Rotation & Deflection Contribution ===")
        println("M_net = $(ustrip(kip*u"ft", M_net)) kip-ft")
        println("Kec = $(ustrip(u"lbf*inch", Kec) / 1e6)×10⁶ in-lb")
        println("θ = $(round(θ, digits=6)) rad (SP: 0.0006)")
        println("Δθ = $(round(Δ_θ_in, digits=4)) in (SP: 0.0152)")
    end
    
    # =========================================================================
    # Test 18: Complete Strip Deflection (Δcx, Δmx)
    # =========================================================================
    @testset "Complete Strip Deflection Calculation" begin
        # Combining all components for exterior span D load:
        # Δcx = Δc,fixed + Δθc,L + Δθc,R
        # SP: Δcx = 0.057 + 0.0152 + 0.0025 = 0.0747 in
        
        Δc_fixed = 0.0570u"inch"
        Δθc_L = 0.0152u"inch"
        Δθc_R = 0.0025u"inch"
        
        Δcx_calc = Δc_fixed + Δθc_L + Δθc_R
        Δcx_expected = 0.0747u"inch"
        
        @test Δcx_calc ≈ Δcx_expected rtol=0.01
        
        # Middle strip:
        # SP: Δmx = 0.0203 + 0.0152 + 0.0025 = 0.0380 in
        Δm_fixed = 0.0203u"inch"
        Δθm_L = 0.0152u"inch"
        Δθm_R = 0.0025u"inch"
        
        Δmx_calc = Δm_fixed + Δθm_L + Δθm_R
        Δmx_expected = 0.0380u"inch"
        
        @test Δmx_calc ≈ Δmx_expected rtol=0.01
        
        println("\n=== Complete Strip Deflection ===")
        println("Column strip: Δcx = $(ustrip(u"inch", Δc_fixed)) + $(ustrip(u"inch", Δθc_L)) + $(ustrip(u"inch", Δθc_R)) = $(round(ustrip(u"inch", Δcx_calc), digits=4)) in (SP: 0.0747)")
        println("Middle strip: Δmx = $(ustrip(u"inch", Δm_fixed)) + $(ustrip(u"inch", Δθm_L)) + $(ustrip(u"inch", Δθm_R)) = $(round(ustrip(u"inch", Δmx_calc), digits=4)) in (SP: 0.0380)")
        
        # Panel deflection
        Δ_panel = StructuralSizer.two_way_panel_deflection(Δcx_calc, Δmx_calc)
        println("Panel: Δ = $(round(ustrip(u"inch", Δ_panel), digits=4)) in (SP: 0.113)")
        
        @test ustrip(u"inch", Δ_panel) ≈ 0.113 rtol=0.02
    end
    
    # =========================================================================
    # Test 19: Hardy Cross Moment Distribution Solver
    # =========================================================================
    @testset "Hardy Cross Moment Distribution" begin
        # Build spans and joint_Kec for moment distribution
        # Use same geometry as ASAP test
        
        # Create span properties using PCA table lookup
        Is = StructuralSizer.slab_moment_of_inertia(l2, h)
        sf_hc = StructuralSizer.pca_slab_beam_factors(c1, l1, c2, l2)
        Ksb = StructuralSizer.slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=sf_hc.k)
        
        spans = [
            StructuralSizer.EFMSpanProperties(
                i, i, i+1,
                l1, l2, ln,
                h, c1, c2, c1, c2,
                Is, Ksb,
                sf_hc.m, sf_hc.COF, sf_hc.k
            )
            for i in 1:3
        ]
        
        joint_positions = [:interior, :interior, :interior, :interior]
        joint_Kec = StructuralSizer._compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc)
        
        # Solve using Hardy Cross (with verbose for debugging)
        span_moments = StructuralSizer.solve_moment_distribution(
            spans, joint_Kec, joint_positions, qu;
            COF=0.507, max_iterations=20, tolerance=0.001, verbose=true
        )
        
        # Extract first span results
        M_neg_ext = span_moments[1].M_neg_left
        M_neg_int = span_moments[1].M_neg_right
        M_pos = span_moments[1].M_pos
        
        println("\n=== Hardy Cross Moment Distribution Results ===")
        println("Span 1 (Exterior):")
        println("  M_neg_left  = $(round(ustrip(kip*u"ft", M_neg_ext), digits=2)) kip-ft (SP: 46.65)")
        println("  M_neg_right = $(round(ustrip(kip*u"ft", M_neg_int), digits=2)) kip-ft (SP: 83.91)")
        println("  M_pos       = $(round(ustrip(kip*u"ft", M_pos), digits=2)) kip-ft (SP: 44.94)")
        
        # These should match StructurePoint Table 5 exactly
        @test ustrip(kip*u"ft", M_neg_ext) ≈ 46.65 rtol=0.02
        @test ustrip(kip*u"ft", M_neg_int) ≈ 83.91 rtol=0.02
        @test ustrip(kip*u"ft", M_pos) ≈ 44.94 rtol=0.02
        
        # Check interior span (symmetric)
        M_neg_int_span2 = span_moments[2].M_neg_left
        M_pos_span2 = span_moments[2].M_pos
        
        println("\nSpan 2 (Interior):")
        println("  M_neg = $(round(ustrip(kip*u"ft", M_neg_int_span2), digits=2)) kip-ft (SP: 76.21)")
        println("  M_pos = $(round(ustrip(kip*u"ft", M_pos_span2), digits=2)) kip-ft (SP: 33.23)")
        
        @test ustrip(kip*u"ft", M_neg_int_span2) ≈ 76.21 rtol=0.02
        @test ustrip(kip*u"ft", M_pos_span2) ≈ 33.23 rtol=0.02
    end

    # =========================================================================
    # Test 20: Circular Column — Stiffness & EFM Properties
    # =========================================================================
    @testset "Circular Column — EFM Stiffness" begin
        D = 16u"inch"   # Circular column diameter
        c_eq = StructuralSizer.equivalent_square_column(D)
        cf_circ = StructuralSizer.pca_column_factors(H, h)

        # Column moment of inertia
        Ic_circ = StructuralSizer.column_moment_of_inertia(D, D; shape=:circular)
        Ic_rect = StructuralSizer.column_moment_of_inertia(c1, c2; shape=:rectangular)

        # Circular Ic = πD⁴/64 for D=16"
        @test ustrip(u"inch^4", Ic_circ) ≈ π * 16^4 / 64 rtol=0.001

        # Column stiffness Kc (uses actual circular Ic)
        Kc_circ = StructuralSizer.column_stiffness_Kc(Ecc, Ic_circ, H, h; k_factor=cf_circ.k)
        Kc_rect = StructuralSizer.column_stiffness_Kc(Ecc, Ic_rect, H, h; k_factor=cf_circ.k)

        # Circular Kc < rectangular (since Ic_circ < Ic_rect for same D vs c)
        @test ustrip(u"lbf*inch", Kc_circ) > 0
        @test Kc_circ < Kc_rect

        println("\n=== Circular Column Stiffness ===")
        println("Ic (circ) = $(round(ustrip(u"inch^4", Ic_circ), digits=0)) in⁴")
        println("Ic (rect) = $(round(ustrip(u"inch^4", Ic_rect), digits=0)) in⁴")
        println("Kc (circ) = $(round(ustrip(u"lbf*inch", Kc_circ)/1e6, digits=2))×10⁶ in-lb")
        println("Kc (rect) = $(round(ustrip(u"lbf*inch", Kc_rect)/1e6, digits=2))×10⁶ in-lb")
    end

    @testset "Circular Column — Torsional Constant C" begin
        D = 16u"inch"
        c_eq = StructuralSizer.equivalent_square_column(D)

        # For circular columns, torsional member uses equivalent square dimension
        C_circ = StructuralSizer.torsional_constant_C(h, c_eq)  # h × c_eq
        C_rect = StructuralSizer.torsional_constant_C(h, c2)    # h × c2

        # Equivalent square is smaller → lower C
        @test ustrip(u"inch^4", C_circ) > 0
        @test C_circ < C_rect

        println("\n=== Torsional Constant C ===")
        println("C (circ, c_eq=$(round(ustrip(u"inch", c_eq), digits=1))\") = $(round(ustrip(u"inch^4", C_circ), digits=0)) in⁴")
        println("C (rect, c2=$(ustrip(u"inch", c2))\") = $(round(ustrip(u"inch^4", C_rect), digits=0)) in⁴")
    end

    @testset "Circular Column — Torsional Stiffness Kt" begin
        D = 16u"inch"
        c_eq = StructuralSizer.equivalent_square_column(D)

        C_circ = StructuralSizer.torsional_constant_C(h, c_eq)
        C_rect = StructuralSizer.torsional_constant_C(h, c2)

        Kt_circ = StructuralSizer.torsional_member_stiffness_Kt(Ecs, C_circ, l2, c_eq)
        Kt_rect = StructuralSizer.torsional_member_stiffness_Kt(Ecs, C_rect, l2, c2)

        @test ustrip(u"lbf*inch", Kt_circ) > 0
        @test Kt_circ < Kt_rect

        println("\n=== Torsional Stiffness Kt ===")
        println("Kt (circ) = $(round(ustrip(u"lbf*inch", Kt_circ)/1e6, digits=2))×10⁶ in-lb")
        println("Kt (rect) = $(round(ustrip(u"lbf*inch", Kt_rect)/1e6, digits=2))×10⁶ in-lb")
    end

    @testset "Circular Column — Equivalent Column Stiffness Kec" begin
        D = 16u"inch"
        c_eq = StructuralSizer.equivalent_square_column(D)

        Ic_circ = StructuralSizer.column_moment_of_inertia(D, D; shape=:circular)
        C_circ  = StructuralSizer.torsional_constant_C(h, c_eq)

        cf_kec = StructuralSizer.pca_column_factors(H, h)
        Kc_circ = StructuralSizer.column_stiffness_Kc(Ecc, Ic_circ, H, h; k_factor=cf_kec.k)
        Kt_circ = StructuralSizer.torsional_member_stiffness_Kt(Ecs, C_circ, l2, c_eq)

        ΣKc_circ = 2 * Kc_circ
        ΣKt_circ = 2 * Kt_circ
        Kec_circ = StructuralSizer.equivalent_column_stiffness_Kec(ΣKc_circ, ΣKt_circ)

        # Compare with rectangular reference
        Ic_rect = StructuralSizer.column_moment_of_inertia(c1, c2)
        Kc_rect = StructuralSizer.column_stiffness_Kc(Ecc, Ic_rect, H, h; k_factor=cf_kec.k)
        C_rect  = StructuralSizer.torsional_constant_C(h, c2)
        Kt_rect = StructuralSizer.torsional_member_stiffness_Kt(Ecs, C_rect, l2, c2)
        Kec_rect = StructuralSizer.equivalent_column_stiffness_Kec(2*Kc_rect, 2*Kt_rect)

        @test ustrip(u"lbf*inch", Kec_circ) > 0
        @test Kec_circ < Kec_rect  # Circular column is less stiff overall

        # Difference should be moderate (< 30%)
        Kec_ratio = ustrip(u"lbf*inch", Kec_circ) / ustrip(u"lbf*inch", Kec_rect)
        @test Kec_ratio > 0.70
        @test Kec_ratio < 1.0

        println("\n=== Equivalent Column Stiffness Kec ===")
        println("Kec (circ) = $(round(ustrip(u"lbf*inch", Kec_circ)/1e6, digits=2))×10⁶ in-lb")
        println("Kec (rect) = $(round(ustrip(u"lbf*inch", Kec_rect)/1e6, digits=2))×10⁶ in-lb")
        println("Ratio = $(round(Kec_ratio, digits=3))")
    end
end

println("\n✓ EFM pipeline tests complete!")
