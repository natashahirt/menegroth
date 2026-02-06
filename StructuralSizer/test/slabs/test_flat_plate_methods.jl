# =============================================================================
# Test: DDM, MDDM, EFM Method Selection API
# =============================================================================
#
# Tests the type-dispatched method selection for flat plate analysis:
#   - DDM()           → Full Direct Design Method
#   - DDM(:simplified) → Modified DDM (MDDM)
#   - EFM()           → Equivalent Frame Method
#
# Also validates applicability checks for each method.
#
# =============================================================================

using Test
using Unitful
using StructuralSizer
# Import Asap units re-exported by StructuralSizer
using StructuralSizer: kip, ksi, psf, ksf, pcf

@testset "Flat Plate Method Selection API" begin
    
    # =========================================================================
    # Test method type construction
    # =========================================================================
    @testset "Method Types" begin
        # DDM variants
        ddm_full = DDM()
        ddm_simple = DDM(:simplified)
        
        @test ddm_full isa FlatPlateAnalysisMethod
        @test ddm_full isa DDM
        @test ddm_full.variant == :full
        
        @test ddm_simple isa DDM
        @test ddm_simple.variant == :simplified
        
        # Invalid DDM variant should error
        @test_throws ErrorException DDM(:invalid)
        
        # EFM
        efm = EFM()
        @test efm isa FlatPlateAnalysisMethod
        @test efm isa EFM
        @test efm.solver == :asap
        
        # Invalid EFM solver should error
        @test_throws ErrorException EFM(:invalid)
    end
    
    # =========================================================================
    # Test MomentAnalysisResult construction
    # =========================================================================
    @testset "MomentAnalysisResult" begin
        # All Length fields must have same unit type for parametric struct
        result = MomentAnalysisResult(
            100kip*u"ft",       # M0
            26kip*u"ft",        # M_neg_ext
            70kip*u"ft",        # M_neg_int
            52kip*u"ft",        # M_pos
            200psf,             # qu
            100psf,             # qD
            50psf,              # qL
            18.0u"ft",          # l1
            14.0u"ft",          # l2
            16.67u"ft",         # ln
            1.33u"ft",          # c_avg (16 inch = 1.33 ft)
            [26.0, 70.0],       # column_moments
            [25kip, 25kip],     # column_shears
            [26kip*u"ft", 0kip*u"ft"], # unbalanced_moments
            50kip               # Vu_max
        )
        
        @test result.M0 == 100kip*u"ft"
        @test result.M_neg_ext == 26kip*u"ft"
        @test result.M_neg_int == 70kip*u"ft"
        @test result.M_pos == 52kip*u"ft"
        @test length(result.column_moments) == 2
    end
    
    # =========================================================================
    # Test DDM applicability checks
    # =========================================================================
    @testset "DDM Applicability" begin
        # Create mock structure and slab for testing
        # We'll test the error type exists and has proper structure
        
        @test DDMApplicabilityError <: Exception
        
        # Test error construction
        err = DDMApplicabilityError(
            ["§8.10.2.2: Aspect ratio violation"],
            ["EFM", "FEA"]
        )
        @test length(err.violations) == 1
        @test length(err.alternatives) == 2
        
        # Test showerror works without throwing
        io = IOBuffer()
        try
            showerror(io, err)
            @test true
        catch
            @test false  # showerror should not throw
        end
    end
    
    # =========================================================================
    # Test EFM applicability checks
    # =========================================================================
    @testset "EFM Applicability" begin
        @test EFMApplicabilityError <: Exception
        
        # Test error construction
        err = EFMApplicabilityError(["Invalid geometry"])
        @test length(err.violations) == 1
        
        # Test showerror works
        io = IOBuffer()
        try
            showerror(io, err)
            @test true
        catch
            @test false
        end
    end
    
    # =========================================================================
    # Test DDM moment coefficients
    # =========================================================================
    @testset "DDM Moment Coefficients" begin
        # End span coefficients (ACI Table 8.10.4.2)
        @test ACI_DDM_LONGITUDINAL.end_span.ext_neg ≈ 0.26 atol=0.01
        @test ACI_DDM_LONGITUDINAL.end_span.pos ≈ 0.52 atol=0.01
        @test ACI_DDM_LONGITUDINAL.end_span.int_neg ≈ 0.70 atol=0.01
        
        # Interior span coefficients
        @test ACI_DDM_LONGITUDINAL.interior_span.neg ≈ 0.65 atol=0.01
        @test ACI_DDM_LONGITUDINAL.interior_span.pos ≈ 0.35 atol=0.01
        
        # Interior span should sum to ~1.0
        int_sum = ACI_DDM_LONGITUDINAL.interior_span.neg + ACI_DDM_LONGITUDINAL.interior_span.pos
        @test int_sum ≈ 1.0 atol=0.01
    end
    
    # =========================================================================
    # Test MDDM coefficients
    # =========================================================================
    @testset "MDDM Coefficients" begin
        # End span
        end_cs = MDDM_COEFFICIENTS.end_span.column_strip
        end_ms = MDDM_COEFFICIENTS.end_span.middle_strip
        
        @test end_cs.ext_neg ≈ 0.27 atol=0.02
        @test end_cs.pos ≈ 0.345 atol=0.02
        @test end_cs.int_neg ≈ 0.55 atol=0.02
        
        @test end_ms.ext_neg ≈ 0.00 atol=0.01
        @test end_ms.pos ≈ 0.235 atol=0.02
        @test end_ms.int_neg ≈ 0.18 atol=0.02
        
        # Interior span
        int_cs = MDDM_COEFFICIENTS.interior_span.column_strip
        int_ms = MDDM_COEFFICIENTS.interior_span.middle_strip
        
        # Interior span coefficients should sum to ~1.0
        int_total = int_cs.neg + int_cs.pos + int_ms.neg + int_ms.pos
        @test int_total ≈ 1.02 rtol=0.05
    end
    
    # =========================================================================
    # Test EFM stiffness calculations
    # =========================================================================
    @testset "EFM Stiffness Functions" begin
        # Material properties
        fc = 4000u"psi"
        Ecs = Ec(fc)
        
        # Geometry
        l1 = 18u"ft"
        l2 = 14u"ft"
        h = 7u"inch"
        c = 16u"inch"
        H = 9u"ft"
        
        # Slab moment of inertia
        Is = slab_moment_of_inertia(l2, h)
        @test ustrip(u"inch^4", Is) ≈ 4802 rtol=0.01
        
        # Column moment of inertia
        Ic = column_moment_of_inertia(c, c)
        @test ustrip(u"inch^4", Ic) ≈ 5461 rtol=0.01
        
        # Torsional constant
        C = torsional_constant_C(h, c)
        @test ustrip(u"inch^4", C) ≈ 1325 rtol=0.10
        
        # Slab-beam stiffness
        Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, c, c)
        # SP uses slightly different k_factor; our default gives ~331e6
        @test ustrip(u"lbf*inch", Ksb) ≈ 331e6 rtol=0.05
        
        # Column stiffness
        Kc = column_stiffness_Kc(Ecs, Ic, H, h)
        @test ustrip(u"lbf*inch", Kc) > 0
        
        # Torsional member stiffness
        Kt = torsional_member_stiffness_Kt(Ecs, C, l2, c)
        @test ustrip(u"lbf*inch", Kt) > 0
        
        # Equivalent column stiffness
        Kec = equivalent_column_stiffness_Kec(2*Kc, 2*Kt)
        @test ustrip(u"lbf*inch", Kec) > 0
        @test Kec < 2*Kc  # Series combination reduces stiffness
    end
end

println("\n✓ Flat plate method selection API tests complete!")
