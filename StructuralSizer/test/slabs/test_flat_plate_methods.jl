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
        @test efm.column_stiffness == :Kec
        @test efm.cracked_columns == false
        
        # EFM with options
        efm_kc = EFM(column_stiffness=:Kc)
        @test efm_kc.column_stiffness == :Kc
        efm_cracked = EFM(column_stiffness=:Kc, cracked_columns=true)
        @test efm_cracked.cracked_columns == true
        
        # Invalid EFM solver should error
        @test_throws ErrorException EFM(solver=:invalid)
        
        # FEA — new knob-based API
        fea = FEA()
        @test fea isa FlatPlateAnalysisMethod
        @test fea isa FEA
        @test fea.design_approach == :frame
        @test fea.moment_transform == :projection
        @test fea.field_smoothing == :element
        @test fea.cut_method == :delta_band
        @test fea.iso_alpha == 1.0
        @test fea.rebar_direction === nothing
        @test fea.strip_design == :aci_fractions  # backward compat

        # FEA strip with element/delta_band/projection
        fea_strip = FEA(design_approach=:strip)
        @test fea_strip.design_approach == :strip
        @test fea_strip.strip_design == :fea_integration

        # FEA strip with nodal/isoparametric
        fea_nod = FEA(design_approach=:strip, field_smoothing=:nodal, cut_method=:isoparametric)
        @test fea_nod.design_approach == :strip
        @test fea_nod.field_smoothing == :nodal
        @test fea_nod.cut_method == :isoparametric
        @test fea_nod.strip_design == :nodal_cuts

        # FEA strip with Wood–Armer
        fea_wa = FEA(design_approach=:strip, moment_transform=:wood_armer)
        @test fea_wa.moment_transform == :wood_armer
        @test fea_wa.strip_design == :wood_armer

        # FEA area-based design
        fea_area = FEA(design_approach=:area, moment_transform=:wood_armer)
        @test fea_area.design_approach == :area

        # iso_alpha knob
        fea_iso = FEA(design_approach=:strip, field_smoothing=:nodal,
                      cut_method=:isoparametric, iso_alpha=0.3)
        @test fea_iso.iso_alpha == 0.3

        # rebar_direction knob
        fea_rebar = FEA(rebar_direction=π/4)
        @test fea_rebar.rebar_direction ≈ π/4

        # pattern_mode knob
        fea_efm = FEA(pattern_mode=:efm_amp)
        @test fea_efm.pattern_mode == :efm_amp
        fea_resolve = FEA(pattern_mode=:fea_resolve)
        @test fea_resolve.pattern_mode == :fea_resolve
        @test_throws ErrorException FEA(pattern_mode=:invalid)

        # Validation
        @test_throws ErrorException FEA(design_approach=:invalid)
        @test_throws ErrorException FEA(moment_transform=:invalid)
        @test_throws ErrorException FEA(field_smoothing=:invalid)
        @test_throws ErrorException FEA(cut_method=:invalid)
        @test_throws ErrorException FEA(iso_alpha=1.5)

        # Legacy strip_design backward compat
        fea_legacy_cut = FEA(strip_design=:fea_integration)
        @test fea_legacy_cut.design_approach == :strip
        @test fea_legacy_cut.strip_design == :fea_integration

        fea_legacy_nod = FEA(strip_design=:nodal_cuts)
        @test fea_legacy_nod.design_approach == :strip
        @test fea_legacy_nod.field_smoothing == :nodal
        @test fea_legacy_nod.strip_design == :nodal_cuts

        fea_legacy_wa = FEA(strip_design=:wood_armer)
        @test fea_legacy_wa.moment_transform == :wood_armer
        @test fea_legacy_wa.strip_design == :wood_armer

        @test_logs (:warn, r"deprecated") FEA(strip_design=:peak_nodal)

        @test_throws ErrorException FEA(strip_design=:invalid)
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
            [26kip*u"ft", 70kip*u"ft"],  # column_moments
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
            ["§13.6.1.2: Aspect ratio violation"],
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
        
        # Slab-beam stiffness (PCA Table A1 lookup)
        sf_m = pca_slab_beam_factors(c, l1, c, l2)
        Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, c, c; k_factor=sf_m.k)
        @test ustrip(u"lbf*inch", Ksb) > 0
        
        # Column stiffness (PCA Table A7 lookup)
        cf_m = pca_column_factors(H, h)
        Kc = column_stiffness_Kc(Ecs, Ic, H, h; k_factor=cf_m.k)
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
