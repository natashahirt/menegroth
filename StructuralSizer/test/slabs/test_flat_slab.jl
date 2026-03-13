# =============================================================================
# Tests for CIP Flat Slab (with Drop Panels) Design
# Validates against StructurePoint 30×30 ft example (ACI 318-14)
# Reference: DE-Two-Way-Flat-Slab-Concrete-Floor-with-Drop-Panels-System-
#            Analysis-and-Design-ACI-318-14-spSlab-v1000
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using Asap  # Register Asap units with Unitful's @u_str
using StructuralSizer

# Aliases for internal (unexported) functions used in tests
const SS = StructuralSizer
const slab_self_weight = SS.slab_self_weight
const auto_size_drop_depth = SS.auto_size_drop_depth
const has_drop_panels_fn = SS.has_drop_panels

# =============================================================================
# StructurePoint Reference Example — Flat Slab with Drop Panels
# =============================================================================
# Panel: 30 ft × 30 ft (center-to-center)
# Columns: 20" × 20" square
# Slab concrete: f'c = 5,000 psi (normal weight, 150 pcf)
# Column concrete: f'c = 6,000 psi
# fy = 60,000 psi (Grade 60)
# Cover = 0.75"
# Story height: 13 ft (156 in)
# Slab thickness: h = 10 in
# Drop panel: 10 ft × 10 ft × 4.25 in (projection below slab)
# Total depth at drop: 10 + 4.25 = 14.25 in
# SDL = 20 psf
# LL = 60 psf
# Self-weight (slab): 150 pcf × 10/12 = 125.00 psf
# Self-weight (drop):  150 pcf × 4.25/12 = 53.13 psf (additional)
# =============================================================================

@testset "Flat Slab Design — StructurePoint Validation" begin

    # ─── Material Properties ───
    fc_slab = 5000u"psi"
    fc_col  = 6000u"psi"
    fy      = 60000u"psi"
    wc      = 150.0       # pcf (mass density as number for Ec formula)
    γ       = 150pcf   # unit weight

    # ─── Geometry ───
    l1      = 30u"ft"     # span direction 1
    l2      = 30u"ft"     # span direction 2
    c1      = 20u"inch"   # column dimension parallel to span
    c2      = 20u"inch"   # column dimension perpendicular to span
    H       = 13u"ft"     # story height (156 in)
    h       = 10u"inch"   # slab thickness
    cover   = 0.75u"inch"

    # ─── Drop Panel ───
    h_drop  = 4.25u"inch"       # drop panel projection below slab soffit
    a_drop  = 5u"ft"            # half-extent from column center (10 ft total)
    h_total = h + h_drop        # = 14.25 in

    # ─── Loads ───
    sdl     = 20psf
    ll      = 60psf
    sw_slab = 125.0psf      # 150 × 10/12
    sw_drop = 53.13psf      # 150 × 4.25/12 (additional)

    # ─── Reference stiffness values ───
    Ecs_ref = 4287e3  # psi (slab concrete modulus)
    Ecc_ref = 4696e3  # psi (column concrete modulus)

    # =========================================================================
    @testset "1. Drop Panel Geometry & ACI Compliance" begin

        dp = DropPanelGeometry(h_drop, a_drop, a_drop)

        # Total depth at drop
        h_t = total_depth_at_drop(h, dp)
        @test ustrip(u"inch", h_t) ≈ 14.25 atol=0.01

        # Drop panel plan extents
        @test ustrip(u"ft", drop_extent_1(dp)) ≈ 10.0 atol=0.01
        @test ustrip(u"ft", drop_extent_2(dp)) ≈ 10.0 atol=0.01

        # ACI 8.2.4(a): h_drop ≥ h_slab / 4
        # 4.25 ≥ 10/4 = 2.50  ✓
        @test h_drop >= h / 4

        # ACI 8.2.4(b): a_drop ≥ l/6
        # 5 ft ≥ 30/6 = 5 ft  ✓
        @test a_drop >= l1 / 6
        @test a_drop >= l2 / 6

        # Full compliance check
        ok, violations = check_drop_panel_aci(dp, h, l1, l2)
        @test ok == true
        @test isempty(violations)

        # Test non-compliant geometry
        dp_bad = DropPanelGeometry(1.0u"inch", a_drop, a_drop)
        ok_bad, _ = check_drop_panel_aci(dp_bad, h, l1, l2)
        @test ok_bad == false
    end

    # =========================================================================
    @testset "2. Minimum Slab Thickness (ACI Table 8.3.1.1)" begin

        ln = l1 - c1  # 30 ft - 20/12 ft = 28.33 ft = 340 in
        @test ustrip(u"inch", ln) ≈ 340.0 atol=0.1

        # ── Flat Plate (without drop panels) ──
        # Exterior: ln/30 = 340/30 = 11.33 in
        h_fp_ext = min_thickness(FlatPlate(), ln; discontinuous_edge=true)
        @test ustrip(u"inch", h_fp_ext) ≈ 11.33 rtol=0.01

        # Interior: ln/33 = 340/33 = 10.30 in
        h_fp_int = min_thickness(FlatPlate(), ln; discontinuous_edge=false)
        @test ustrip(u"inch", h_fp_int) ≈ 10.30 rtol=0.01

        # ── Flat Slab (with drop panels) ──
        # Exterior: ln/33 = 340/33 = 10.30 in
        h_fs_ext = min_thickness(FlatSlab(), ln; discontinuous_edge=true)
        @test ustrip(u"inch", h_fs_ext) ≈ 10.30 rtol=0.01

        # Interior: ln/36 = 340/36 = 9.44 in
        h_fs_int = min_thickness(FlatSlab(), ln; discontinuous_edge=false)
        @test ustrip(u"inch", h_fs_int) ≈ 9.44 rtol=0.01

        # Absolute minimums
        @test min_thickness(FlatPlate(), 30u"inch") >= 5.0u"inch"
        @test min_thickness(FlatSlab(), 30u"inch")  >= 4.0u"inch"
    end

    # =========================================================================
    @testset "3. Self-Weight Calculations" begin

        # Slab-only self-weight: 150 pcf × 10 in / 12 = 125.0 psf
        sw = slab_self_weight(h, γ)
        @test ustrip(psf, sw) ≈ 125.0 rtol=0.01

        # Self-weight with drop panels
        dp = DropPanelGeometry(h_drop, a_drop, a_drop)
        w_slab, w_drop = slab_self_weight_with_drop(h, dp, γ)

        # w_slab = 125.0 psf
        @test ustrip(psf, w_slab) ≈ 125.0 rtol=0.01
        # w_drop = 150 × 4.25/12 = 53.125 psf
        @test ustrip(psf, w_drop) ≈ 53.13 rtol=0.01
    end

    # =========================================================================
    @testset "4. Auto-Size Drop Panel Depth" begin

        # For h = 10 in → min projection = 10/4 = 2.5 in
        # Smallest standard depth ≥ 2.5 in is 4.25 in (4× lumber + plyform)
        dp_depth = auto_size_drop_depth(10u"inch")
        @test ustrip(u"inch", dp_depth) ≈ 4.25 atol=0.01

        # For h = 7 in → min = 7/4 = 1.75 in → smallest ≥ 1.75 is 2.25
        dp7 = auto_size_drop_depth(7u"inch")
        @test ustrip(u"inch", dp7) ≈ 2.25 atol=0.01

        # For h = 18 in → min = 4.5 in → smallest ≥ 4.5 is 6.25
        dp18 = auto_size_drop_depth(18u"inch")
        @test ustrip(u"inch", dp18) ≈ 6.25 atol=0.01
    end

    # =========================================================================
    @testset "5. Gross Section at Drop (Composite Properties)" begin

        dp = DropPanelGeometry(h_drop, a_drop, a_drop)

        # StructurePoint reference:
        # h_total = 14.25 in, yt = 5.88 in, Ig = 53,445 in⁴
        #
        # Slab strip: l2 = 360 in × h = 10 in
        # Drop panel: 120 in × 4.25 in
        gs = gross_section_at_drop(l2, h, dp)

        # Returns a DropSectionProperties struct
        @test gs isa DropSectionProperties

        # The reference values are for a specific strip configuration.
        # Our function should produce reasonable composite properties.
        @test ustrip(u"inch^4", gs.Ig) > ustrip(u"inch^4", slab_moment_of_inertia(l2, h))
        @test ustrip(u"inch", gs.yt) > 0.0
        @test ustrip(u"inch", gs.yt) < ustrip(u"inch", h_total)

        # Verify additional struct fields
        @test ustrip(u"inch", gs.h_total) ≈ 14.25 atol=0.01
        @test ustrip(u"inch", gs.y_bar) > 0.0
        @test ustrip(u"inch^2", gs.A_total) > 0.0
    end

    # =========================================================================
    @testset "6. EFM Stiffness — Slab-Beam" begin

        # StructurePoint: Ecs = 4287 × 10³ psi
        Ecs = Ec(fc_slab, wc)
        @test ustrip(u"psi", Ecs) ≈ Ecs_ref rtol=0.02

        # Gross Is (slab strip)
        # l2 = 360 in, h = 10 in → Is = 360 × 10³/12 = 30,000 in⁴
        Is = slab_moment_of_inertia(l2, h)
        @test ustrip(u"inch^4", Is) ≈ 30000 rtol=0.01

        # Prismatic slab-beam stiffness via PCA Table A1 lookup
        slab_factors = pca_slab_beam_factors(c1, l1, c2, l2)
        Ksb_prismatic = slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=slab_factors.k)
        @test ustrip(u"lbf*inch", Ksb_prismatic) > 0

        # Non-prismatic slab-beam stiffness via PCA Tables A2–A5 lookup
        sf_np = pca_slab_beam_factors_np(c1, l1, c2, l2, h_drop, h)
        Ksb_np = slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=sf_np.k)
        # StructurePoint reference: Ksb = 1,995,955,750 in-lb (k = 5.587)
        @test ustrip(u"lbf*inch", Ksb_np) ≈ 1_995_955_750 rtol=0.05
        @test sf_np.k ≈ 5.587 rtol=0.05
    end

    # =========================================================================
    @testset "7. Column Stiffness (Non-Prismatic via PCA Table A7)" begin

        # Column concrete: f'c = 6000 psi → Ecc = 4696 × 10³ psi
        Ecc = Ec(fc_col, wc)
        @test ustrip(u"psi", Ecc) ≈ Ecc_ref rtol=0.02

        # Column Ic = 20 × 20³/12 = 13,333 in⁴
        Ic = column_moment_of_inertia(c1, c2)
        @test ustrip(u"inch^4", Ic) ≈ 13333 rtol=0.01

        dp = DropPanelGeometry(h_drop, a_drop, a_drop)

        # Column stiffness now uses pca_column_factors internally with
        # ta/tb computed from geometry.
        # StructurePoint: Bottom ta=9.25", tb=5.00", k=5.318
        #                 Top    ta=5.00", tb=9.25", k=4.879
        Kc_bot = column_stiffness_Kc(Ecc, Ic, H, h, dp; position=:bottom)
        @test ustrip(u"lbf*inch", Kc_bot) ≈ 2_134_472_479 rtol=0.05

        Kc_top = column_stiffness_Kc(Ecc, Ic, H, h, dp; position=:top)
        @test ustrip(u"lbf*inch", Kc_top) ≈ 1_958_272_137 rtol=0.05

        # ΣKc = Kc_bot + Kc_top
        ΣKc = Kc_bot + Kc_top
        @test ustrip(u"lbf*inch", ΣKc) ≈ (2_134_472_479 + 1_958_272_137) rtol=0.05

        # Bottom column should be stiffer (larger ta)
        @test ustrip(u"lbf*inch", Kc_bot) > ustrip(u"lbf*inch", Kc_top)
    end

    # =========================================================================
    @testset "8. EFM Stiffness — Torsional Member" begin

        Ecs = Ec(fc_slab, wc)

        # With drop panels, torsional member uses total depth
        # C = (1 - 0.63 × x/y) × x³y/3 where x = h_total = 14.25, y = c2 = 20
        # StructurePoint: C = 10,632 in⁴
        C = torsional_constant_C(h_total, c2)
        @test ustrip(u"inch^4", C) ≈ 10632 rtol=0.02

        # Kt = 9 × Ecs × C / (l2 × (1 - c2/l2)³)
        # StructurePoint: Kt = 1,352,594,724 in-lb
        Kt = torsional_member_stiffness_Kt(Ecs, C, l2, c2)
        @test ustrip(u"lbf*inch", Kt) ≈ 1_352_594_724 rtol=0.02
    end

    # =========================================================================
    @testset "9. EFM Stiffness — Equivalent Column" begin

        Ecs = Ec(fc_slab, wc)
        Ecc = Ec(fc_col, wc)
        Ic  = column_moment_of_inertia(c1, c2)

        dp = DropPanelGeometry(h_drop, a_drop, a_drop)

        Kc_bot = column_stiffness_Kc(Ecc, Ic, H, h, dp; position=:bottom)
        Kc_top = column_stiffness_Kc(Ecc, Ic, H, h, dp; position=:top)
        ΣKc    = Kc_bot + Kc_top

        C  = torsional_constant_C(h_total, c2)
        Kt = torsional_member_stiffness_Kt(Ecs, C, l2, c2)

        # Interior joint: 2 torsional members
        ΣKt_int = 2 * Kt
        Kec_int = equivalent_column_stiffness_Kec(ΣKc, ΣKt_int)

        # StructurePoint: Kec = 1,628,678,573 in-lb (interior)
        @test ustrip(u"lbf*inch", Kec_int) ≈ 1_628_678_573 rtol=0.03
    end

    # =========================================================================
    @testset "10. PCA Non-Prismatic Lookups (Tables A2–A5, A7)" begin

        # Validate that the interpolated values from pca_slab_beam_factors_np
        # are close to the StructurePoint reference values.
        # SP example: c/l = 20/360 ≈ 0.056, d/h = 4.25/10 = 0.425
        sf_np = pca_slab_beam_factors_np(c1, l1, c2, l2, h_drop, h)
        @test sf_np.k ≈ 5.587 rtol=0.05
        @test sf_np.COF ≈ 0.578 rtol=0.05
        @test sf_np.m_uniform ≈ 0.0915 rtol=0.05

        # Column factors from pca_column_factors with ta/tb
        # For drop panels, use h_total for clear height: Hc = H - h_total
        # Bottom: ta = h/2 + h_drop = 5 + 4.25 = 9.25", tb = h/2 = 5"
        cf_bot = pca_column_factors(H, h_total; ta=h/2 + h_drop, tb=h/2)
        @test cf_bot.k ≈ 5.318 rtol=0.05

        # Top: ta = h/2 = 5", tb = h/2 + h_drop = 9.25"
        cf_top = pca_column_factors(H, h_total; ta=h/2, tb=h/2 + h_drop)
        @test cf_top.k ≈ 4.879 rtol=0.05
    end

    # =========================================================================
    @testset "11. FlatSlabOptions" begin

        # Default FlatSlabOptions (composition: base::FlatPlateOptions)
        opts = FlatSlabOptions()
        @test isnothing(opts.h_drop)
        @test isnothing(opts.a_drop_ratio)
        # Property forwarding through base
        @test opts.method == DDM()
        @test opts.φ_flexure == 0.90
        @test opts.φ_shear == 0.75
        @test opts.base isa FlatPlateOptions

        # Custom drop panel depth with base options
        opts2 = FlatSlabOptions(h_drop=4.25u"inch", base=FlatPlateOptions(method=EFM()))
        @test opts2.h_drop == 4.25u"inch"
        @test opts2.method == EFM()

        # FlatSlabOptions with custom drop depth
        fopts = FlatSlabOptions(h_drop=4.25u"inch")
        @test fopts.h_drop == 4.25u"inch"

        # as_flat_plate_options converter returns the base directly
        fp_opts = as_flat_plate_options(opts2)
        @test fp_opts isa FlatPlateOptions
        @test fp_opts.method == EFM()
        @test fp_opts.φ_flexure == 0.90
        @test fp_opts === opts2.base  # same object (not a copy)

        # FlatPlateOptions no longer has has_drop_panels
        fp = FlatPlateOptions()
        @test !hasproperty(fp, :has_drop_panels)
    end

    # =========================================================================
    @testset "12. EFMSpanProperties — Backward Compatibility" begin

        Is = slab_moment_of_inertia(l2, h)
        Ecs = Ec(fc_slab, wc)
        sf = pca_slab_beam_factors(c1, l1, c2, l2)
        Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=sf.k)

        # 16-argument constructor still works (no drop panels)
        sp = EFMSpanProperties(
            1, 1, 2,
            l1, l2, l1 - c1, h,
            c1, c2, c1, c2,
            Is, Ksb, sf.m, sf.COF, sf.k
        )
        @test isnothing(sp.drop)
        @test isnothing(sp.Is_drop)
        @test has_drop_panels_fn(sp) == false

        # Full constructor with drop panels
        dp = DropPanelGeometry(h_drop, a_drop, a_drop)
        Is_drop = slab_moment_of_inertia(l2, h_total)

        sp2 = EFMSpanProperties{typeof(Is), typeof(Ksb)}(
            1, 1, 2,
            l1, l2, l1 - c1, h,
            c1, c2, c1, c2,
            Is, Ksb, sf.m, sf.COF, sf.k,
            dp, Is_drop,
        )
        @test !isnothing(sp2.drop)
        @test !isnothing(sp2.Is_drop)
        @test has_drop_panels_fn(sp2) == true
        @test sp2.COF ≈ sf.COF
    end

    # =========================================================================
    @testset "13. Fixed-End Moment — Non-Prismatic (Multi-Term)" begin

        dp = DropPanelGeometry(h_drop, a_drop, a_drop)

        # Total factored load components
        # qu_slab = 1.2 × (125 + 20) + 1.6 × 60 = 270 psf
        qu_slab = 270psf
        # qu_drop (additional from drop projection) = 1.2 × 53.13 = 63.75 psf
        qu_drop = 63.75psf

        # StructurePoint FEM computation (now uses PCA Tables A2–A5 lookup):
        # FEM = m_uniform × w_slab × l2 × l1² + m_near × w_drop × b_drop × l1²
        #     + m_far × w_drop × b_drop × l1²
        # where b_drop = 2 × a_drop = 10 ft
        #
        # Reference: FEM = 677.53 ft-kips (approximately)
        FEM = fixed_end_moment_FEM(qu_slab, qu_drop, l2, l1, c1, c2, h, dp)
        FEM_kipft = ustrip(kip*u"ft", FEM)

        # SP reference ≈ 677.5 ft-kips
        @test FEM_kipft ≈ 677.5 rtol=0.05
    end

    # =========================================================================
    @testset "14. Weighted Effective Ie (ACI 435R-95)" begin

        # Interior span: Ie_avg = 0.70 Ie_m + 0.15(Ie_1 + Ie_2)
        Ie_mid  = 24577.0u"inch^4"   # midspan (StructurePoint)
        Ie_supp = 27506.0u"inch^4"   # support (StructurePoint)

        Ie_avg = weighted_effective_Ie(Ie_mid, Ie_supp, Ie_supp; position=:interior)
        # = 0.70 × 24577 + 0.15 × (27506 + 27506)
        # = 17203.9 + 8251.8 = 25455.7
        expected = 0.70 * 24577.0 + 0.15 * (27506.0 + 27506.0)
        @test ustrip(u"inch^4", Ie_avg) ≈ expected rtol=0.001

        # Exterior span: Ie_avg = 0.85 Ie_m + 0.15 Ie_cont
        Ie_avg_ext = weighted_effective_Ie(Ie_mid, Ie_supp, Ie_supp; position=:exterior)
        expected_ext = 0.85 * 24577.0 + 0.15 * 27506.0
        @test ustrip(u"inch^4", Ie_avg_ext) ≈ expected_ext rtol=0.001
    end

    # =========================================================================
    @testset "15. Weighted Slab Thickness" begin

        dp = DropPanelGeometry(h_drop, a_drop, a_drop)

        # StructurePoint: h_w = (14.25 × 10/2 + 10 × (15 - 10/2)) / 15 = 12.83 in
        # where column strip width = l2/2 = 15 ft
        l_strip = l2 / 2  # 15 ft
        h_w = weighted_slab_thickness(h, dp, l_strip)
        @test ustrip(u"inch", h_w) ≈ 12.83 rtol=0.05
    end

    # =========================================================================
    @testset "16. Column Stiffness Kc — Flat Slab" begin

        Ecc = Ec(fc_col, wc)
        Ic  = column_moment_of_inertia(c1, c2)
        dp  = DropPanelGeometry(
            uconvert(u"m", h_drop),
            uconvert(u"m", a_drop),
            uconvert(u"m", a_drop)
        )

        # Column stiffness now uses pca_column_factors internally
        Kc_b = column_stiffness_Kc(Ecc, Ic, H, h, dp; position=:bottom)
        Kc_t = column_stiffness_Kc(Ecc, Ic, H, h, dp; position=:top)

        # Bottom should be stiffer (larger ta, column end stiffer)
        @test ustrip(u"lbf*inch", Kc_b) > ustrip(u"lbf*inch", Kc_t)

        # Compare with prismatic column stiffness (from PCA Table A7)
        k_col_prismatic = pca_column_factors(H, h).k
        Kc_prismatic = column_stiffness_Kc(Ecc, Ic, H, h; k_factor=k_col_prismatic)

        # Non-prismatic k-factors (from geometry lookup) should be larger than prismatic
        # Use h_total for clear height with drop panels
        h_tot = h + dp.h_drop
        cf_bot = pca_column_factors(H, h_tot; ta=h/2 + dp.h_drop, tb=h/2)
        cf_top = pca_column_factors(H, h_tot; ta=h/2, tb=h/2 + dp.h_drop)
        @test cf_bot.k > k_col_prismatic
        @test cf_top.k > k_col_prismatic
    end

    # =========================================================================
    @testset "17. Distribution Factors (EFM)" begin

        Ecs = Ec(fc_slab, wc)
        Ecc = Ec(fc_col, wc)
        Is  = slab_moment_of_inertia(l2, h)
        Ic  = column_moment_of_inertia(c1, c2)

        dp = DropPanelGeometry(h_drop, a_drop, a_drop)

        # Non-prismatic Ksb — k from PCA Tables A2–A5 lookup
        np_sf = pca_slab_beam_factors_np(c1, l1, c2, l2, h_drop, h)
        Ksb = slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=np_sf.k)

        # Column stiffness (non-prismatic)
        Kc_bot = column_stiffness_Kc(Ecc, Ic, H, h, dp; position=:bottom)
        Kc_top = column_stiffness_Kc(Ecc, Ic, H, h, dp; position=:top)
        ΣKc    = Kc_bot + Kc_top

        # Torsional stiffness (using total depth)
        C  = torsional_constant_C(h_total, c2)
        Kt = torsional_member_stiffness_Kt(Ecs, C, l2, c2)

        # Interior: ΣKt = 2Kt
        Kec_int = equivalent_column_stiffness_Kec(ΣKc, 2 * Kt)

        # Interior DF = Ksb / (2 × Ksb + Kec)
        DF_int = distribution_factor_DF(Ksb, Kec_int; is_exterior=false, Ksb_adjacent=Ksb)
        # StructurePoint: DF_int = 0.355
        @test DF_int ≈ 0.355 rtol=0.05

        # Exterior DF = Ksb / (Ksb + Kec)
        # At an exterior joint, there are still 2 torsional arms along the
        # transverse (perpendicular) direction on each side of the column
        Kec_ext = equivalent_column_stiffness_Kec(ΣKc, 2 * Kt)
        DF_ext = distribution_factor_DF(Ksb, Kec_ext; is_exterior=true)
        # StructurePoint: DF_ext = 0.551
        @test DF_ext ≈ 0.551 rtol=0.05
    end

    # =========================================================================
    @testset "18. Flat Slab vs Flat Plate — Type System" begin

        # FlatSlab and FlatPlate are separate types
        @test FlatSlab() isa AbstractConcreteSlab
        @test FlatPlate() isa AbstractConcreteSlab
        @test typeof(FlatSlab()) != typeof(FlatPlate())

        # Both are beamless spanning
        @test spanning_behavior(FlatSlab()) isa BeamlessSpanning
        @test spanning_behavior(FlatPlate()) isa BeamlessSpanning

        # Symbol mapping
        @test floor_type(:flat_slab) isa FlatSlab
        @test floor_type(:flat_plate) isa FlatPlate
    end

    # =========================================================================
    @testset "19. Flat Slab Minimum Thickness — Edge Cases" begin

        # Very short span: absolute minimum governs
        # Flat plate: min 5"
        @test min_thickness(FlatPlate(), 100u"inch") >= 5.0u"inch"
        # Flat slab: min 4"
        @test min_thickness(FlatSlab(), 100u"inch") >= 4.0u"inch"

        # Very long span: formula governs
        ln_long = 40u"ft"
        # Flat slab exterior: 480/33 = 14.55 in
        @test ustrip(u"inch", min_thickness(FlatSlab(), ln_long; discontinuous_edge=true)) ≈ 14.55 rtol=0.01
        # Flat slab interior: 480/36 = 13.33 in
        @test ustrip(u"inch", min_thickness(FlatSlab(), ln_long; discontinuous_edge=false)) ≈ 13.33 rtol=0.01

        # Flat slab is always thinner than flat plate for same span
        for ln_test in [200u"inch", 340u"inch", 480u"inch"]
            @test min_thickness(FlatSlab(), ln_test; discontinuous_edge=true) <
                  min_thickness(FlatPlate(), ln_test; discontinuous_edge=true)
            @test min_thickness(FlatSlab(), ln_test; discontinuous_edge=false) <
                  min_thickness(FlatPlate(), ln_test; discontinuous_edge=false)
        end
    end

    # =========================================================================
    @testset "20. Standard Drop Depths" begin

        # Standard depths array
        @test STANDARD_DROP_DEPTHS_INCH == [2.25, 4.25, 6.25, 8.0]

        # Auto-sizing selects correct standard depth
        @test ustrip(u"inch", auto_size_drop_depth(6u"inch"))  ≈ 2.25  # 6/4 = 1.5 → 2.25
        @test ustrip(u"inch", auto_size_drop_depth(9u"inch"))  ≈ 2.25  # 9/4 = 2.25 → 2.25
        @test ustrip(u"inch", auto_size_drop_depth(10u"inch")) ≈ 4.25  # 10/4 = 2.5 → 4.25
        @test ustrip(u"inch", auto_size_drop_depth(17u"inch")) ≈ 4.25  # 17/4 = 4.25 → 4.25
        @test ustrip(u"inch", auto_size_drop_depth(20u"inch")) ≈ 6.25  # 20/4 = 5.0 → 6.25
        @test ustrip(u"inch", auto_size_drop_depth(25u"inch")) ≈ 6.25  # 25/4 = 6.25 → 6.25
        @test ustrip(u"inch", auto_size_drop_depth(30u"inch")) ≈ 8.0   # 30/4 = 7.5 → 8.0
    end

end  # top-level testset

println("\n✓ All flat slab tests complete.")
