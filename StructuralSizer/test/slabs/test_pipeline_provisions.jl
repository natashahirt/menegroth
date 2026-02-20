# =============================================================================
# Tests for Flat Plate Pipeline Provisions
# Validates: edge beam β_t, DDM coefficient interpolation, ρ' feedback,
#            face-of-support reduction, moment transfer, integrity reinforcement,
#            DDM applicability guards
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "Pipeline Provisions" begin

    # Common material properties
    fc = 4000u"psi"
    fy = 60000u"psi"

    # =========================================================================
    # 1. Edge Beam β_t Computation
    # =========================================================================
    @testset "Edge Beam β_t (ACI 8.10.5.2)" begin
        h  = 7.0u"inch"
        c1 = 16.0u"inch"
        c2 = 16.0u"inch"
        l2 = 14.0u"ft"

        # Compute β_t for a flat plate edge with column = 16"
        βt = edge_beam_βt(h, c1, c2, l2)

        # β_t should be a small positive number for a flat plate edge
        # C = (1 - 0.63×7/16) × (7³×16/3) ≈ (1 - 0.2756) × (5488/3) ≈ 0.7244 × 1829.3 ≈ 1325 in⁴
        # Is = 168 × 7³/12 = 168 × 343/12 = 4802 in⁴
        # β_t = C / (2 × Is) = 1325 / (2 × 4802) ≈ 0.138
        @test βt > 0.0
        @test βt < 1.0  # shallow edge beam should give small β_t
        @test βt ≈ 1325 / (2 * 4802) atol=0.02

        # Larger column should give larger β_t (more torsion capacity)
        βt_big = edge_beam_βt(h, 24.0u"inch", 24.0u"inch", l2)
        @test βt_big > βt

        # Thicker slab (same column) should change β_t
        βt_thick = edge_beam_βt(9.0u"inch", c1, c2, l2)
        @test βt_thick != βt  # different slab thickness changes both C and Is
    end

    # =========================================================================
    # 2. DDM Longitudinal Distribution with Edge Beam
    # =========================================================================
    @testset "DDM Coefficients with Edge Beam (Table 8.10.4.2)" begin
        # No edge beam: standard coefficients
        coeffs_0 = aci_ddm_longitudinal_with_edge_beam(0.0)
        @test coeffs_0.ext_neg ≈ 0.26
        @test coeffs_0.pos ≈ 0.52
        @test coeffs_0.int_neg ≈ 0.70

        # Full edge beam (β_t ≥ 2.5)
        coeffs_25 = aci_ddm_longitudinal_with_edge_beam(2.5)
        @test coeffs_25.ext_neg ≈ 0.30
        @test coeffs_25.pos ≈ 0.50
        @test coeffs_25.int_neg ≈ 0.70  # unchanged

        # β_t > 2.5 should clamp to same values
        coeffs_5 = aci_ddm_longitudinal_with_edge_beam(5.0)
        @test coeffs_5.ext_neg ≈ 0.30
        @test coeffs_5.pos ≈ 0.50

        # Intermediate β_t = 1.25 → midpoint interpolation
        coeffs_mid = aci_ddm_longitudinal_with_edge_beam(1.25)
        @test coeffs_mid.ext_neg ≈ 0.28  atol=0.001
        @test coeffs_mid.pos ≈ 0.51  atol=0.001
    end

    # =========================================================================
    # 3. Column Strip Exterior Negative Fraction (Table 8.10.5.2)
    # =========================================================================
    @testset "Column Strip Ext Neg Fraction with β_t (Table 8.10.5.2)" begin
        # β_t = 0: 100% to column strip
        @test aci_col_strip_ext_neg_fraction(0.0) ≈ 1.00

        # β_t ≥ 2.5: 75% to column strip
        @test aci_col_strip_ext_neg_fraction(2.5) ≈ 0.75
        @test aci_col_strip_ext_neg_fraction(5.0) ≈ 0.75  # clamped

        # β_t = 1.25: midpoint → 87.5%
        @test aci_col_strip_ext_neg_fraction(1.25) ≈ 0.875
    end

    # =========================================================================
    # 4. distribute_moments_aci with β_t
    # =========================================================================
    @testset "Moment Distribution with Edge Beam β_t" begin
        M0 = 100.0kip * u"ft"
        l2_l1 = 1.0

        # Without edge beam — standard
        mom_no_beam = distribute_moments_aci(M0, :end_span, l2_l1; edge_beam=false)
        @test ustrip(kip * u"ft", mom_no_beam.column_strip.ext_neg) ≈ 26.0 atol=0.5

        # With edge beam (boolean, no explicit βt → uses βt=2.5)
        mom_beam = distribute_moments_aci(M0, :end_span, l2_l1; edge_beam=true)
        # ext_neg_longitudinal = 0.30 × M0 = 30 kip-ft
        # col strip fraction = 0.75 → cs_ext_neg = 0.75 × 30 = 22.5 kip-ft
        @test ustrip(kip * u"ft", mom_beam.column_strip.ext_neg) ≈ 22.5 atol=0.5

        # With explicit βt = 1.25 (partial edge beam)
        mom_partial = distribute_moments_aci(M0, :end_span, l2_l1; βt=1.25)
        # ext_neg_longitudinal = 0.28 × M0 = 28 kip-ft
        # col strip fraction ≈ 0.875 → cs_ext_neg ≈ 0.875 × 28 = 24.5 kip-ft
        @test ustrip(kip * u"ft", mom_partial.column_strip.ext_neg) ≈ 24.5 atol=0.5

        # Interior span unaffected by edge beam
        mom_int_beam = distribute_moments_aci(M0, :interior_span, l2_l1; edge_beam=true)
        mom_int_no   = distribute_moments_aci(M0, :interior_span, l2_l1; edge_beam=false)
        @test ustrip(kip * u"ft", mom_int_beam.column_strip.neg) ≈
              ustrip(kip * u"ft", mom_int_no.column_strip.neg) atol=0.01
    end

    # =========================================================================
    # 5. Face-of-Support Moment Reduction (ACI 8.11.6.1)
    # =========================================================================
    @testset "Face-of-Support Moment Reduction (ACI 8.11.6.1)" begin
        # StructurePoint reference: M_cl = 83.91 kip-ft, V = 26.39 kip, c = 16"
        # M_face = 83.91 - 26.39 × (16/12/2) = 83.91 - 17.59 = 66.32 kip-ft
        M_cl = 83.91kip * u"ft"
        V = 26.39kip
        c = 16.0u"inch"
        l1 = 18.0u"ft"

        M_face = face_of_support_moment(M_cl, V, c, l1)
        @test ustrip(kip * u"ft", M_face) ≈ 66.32 atol=1.5

        # Large column: should be limited by 0.175×l1
        c_large = 8.0u"ft"  # huge column
        M_face_large = face_of_support_moment(M_cl, V, c_large, l1)
        # 0.175 × 18 = 3.15 ft limit → M_face = 83.91 - 26.39 × 3.15 = 0.78 kip-ft
        # But d_face = 4.0 ft > 3.15 ft, so limited to 3.15 ft
        @test ustrip(kip * u"ft", M_face_large) ≈ 83.91 - 26.39 * 3.15 atol=1.0
    end

    # =========================================================================
    # 6. Moment Transfer Reinforcement (ACI 8.4.2.3)
    # =========================================================================
    @testset "Moment Transfer Reinforcement (ACI 8.4.2.3)" begin
        h = 7.0u"inch"
        d = 5.75u"inch"
        c1 = 16.0u"inch"
        c2 = 16.0u"inch"

        # Effective width bb = c2 + 3h
        bb = c2 + 3 * h
        @test ustrip(u"inch", bb) ≈ 37.0

        # γf from critical section dimensions
        b1 = c1 + d
        b2 = c2 + d
        γf_val = SS.gamma_f(b1, b2)
        @test γf_val ≈ 0.60 atol=0.02  # b1=b2 for square columns → γf = 1/(1+2/3) = 0.60

        # Transfer reinforcement for a moderate unbalanced moment
        Mub = 20.0kip * u"ft"
        As_transfer = SS.transfer_reinforcement(Mub, γf_val, bb, d, fc, fy)
        @test ustrip(u"inch^2", As_transfer) > 0.0
        @test ustrip(u"inch^2", As_transfer) < 2.0  # reasonable range for 20 kip-ft
    end

    # =========================================================================
    # 7. Structural Integrity Reinforcement (ACI 8.7.4.2)
    # =========================================================================
    @testset "Structural Integrity Reinforcement (ACI 8.7.4.2)" begin
        A_trib = 252.0u"ft^2"   # 18' × 14'
        qD = 107.5psf            # sw + SDL
        qL = 40.0psf

        integrity = SS.integrity_reinforcement(A_trib, qD, qL, fy)
        @test ustrip(u"inch^2", integrity.As_integrity) > 0.0
        @test ustrip(kip, integrity.Pu_integrity) > 0.0

        # Check: Pu = 2 × (107.5 + 40) × 252 = 74,340 lbf ≈ 74.3 kip
        @test ustrip(kip, integrity.Pu_integrity) ≈ 74.34 atol=1.0

        # As = Pu / (φ × fy) = 74340 / (0.9 × 60000) = 1.38 in²
        @test ustrip(u"inch^2", integrity.As_integrity) ≈ 1.38 atol=0.1

        # Check function
        check_pass = SS.check_integrity_reinforcement(1.5u"inch^2", integrity.As_integrity)
        @test check_pass.ok == true

        check_fail = SS.check_integrity_reinforcement(1.0u"inch^2", integrity.As_integrity)
        @test check_fail.ok == false
    end

    # =========================================================================
    # 8. ρ' Estimation
    # =========================================================================
    @testset "Compression Reinforcement Ratio ρ' Effect" begin
        # Verify that ρ' > 0 reduces the long-term deflection multiplier
        ξ = 2.0  # 5+ year factor

        λ_Δ_0 = SS.long_term_deflection_factor(ξ, 0.0)
        @test λ_Δ_0 ≈ 2.0  # ξ/(1+50×0) = 2.0

        λ_Δ_rho = SS.long_term_deflection_factor(ξ, 0.005)
        @test λ_Δ_rho ≈ 2.0 / (1 + 50 * 0.005) atol=0.001  # = 1.6
        @test λ_Δ_rho < λ_Δ_0  # compression steel reduces long-term deflection
    end

    # =========================================================================
    # 9. DDM Applicability Guard — Aspect Ratio
    # =========================================================================
    @testset "DDM Applicability — Aspect Ratio Check" begin
        # Mock slab and struc for aspect ratio check
        mock_slab = (
            spans = (primary=20.0u"ft", secondary=20.0u"ft"),
            cell_indices = [1],
            is_rectangular = true,
        )
        mock_cell = (
            position = :interior,
            area = 400.0u"ft^2",
            sdl = 20.0psf,
            live_load = 40.0psf,
            self_weight = 87.5psf,
        )
        mock_col = (
            c1 = 16.0u"inch",
            c2 = 16.0u"inch",
            position = :interior,
        )
        mock_struc = (
            cells = [mock_cell],
            slabs = [],
        )

        # Square panel: l2/l1 = 1.0 → should be OK (aspect)
        result = SS.check_ddm_applicability(mock_struc, mock_slab, [mock_col, mock_col];
                                             throw_on_failure=false)
        # Should not have aspect ratio violation
        aspect_violations = filter(v -> occursin("aspect", v), result.violations)
        @test isempty(aspect_violations)

        # Oblong panel: l2/l1 = 2.5 → should fail
        oblong_slab = (
            spans = (primary=10.0u"ft", secondary=25.0u"ft"),
            cell_indices = [1],
        )
        result_oblong = SS.check_ddm_applicability(mock_struc, oblong_slab, [mock_col, mock_col];
                                                     throw_on_failure=false)
        aspect_fails = filter(v -> occursin("8.10.2.2", v), result_oblong.violations)
        @test !isempty(aspect_fails)
    end

    # =========================================================================
    # 10. Sizing with Edge Beam Option
    # =========================================================================
    @testset "Sizing with Edge Beam (FlatPlateOptions)" begin
        span = 18.0u"ft"
        sdl = 20.0psf
        live = 40.0psf

        # Without edge beam
        opts_no_beam = FlatPlateOptions(has_edge_beam=false)
        result_no = SS._size_span_floor(FlatPlate(), span, sdl, live;
                                         options=opts_no_beam, position=:edge)

        # With edge beam
        opts_beam = FlatPlateOptions(has_edge_beam=true)
        result_beam = SS._size_span_floor(FlatPlate(), span, sdl, live;
                                           options=opts_beam, position=:edge)

        # Both should produce valid results
        @test ustrip(u"m", result_no.thickness) > 0.0
        @test ustrip(u"m", result_beam.thickness) > 0.0

        # Thickness should be similar (edge beam affects moment distribution, not h_min)
        @test isapprox(ustrip(u"inch", result_no.thickness),
                       ustrip(u"inch", result_beam.thickness), atol=1.0)
    end

    # =========================================================================
    # 11. FlatPlateOptions edge_beam_βt explicit override
    # =========================================================================
    @testset "FlatPlateOptions edge_beam_βt override" begin
        # Default: nothing
        opts_default = FlatPlateOptions()
        @test isnothing(opts_default.edge_beam_βt)
        @test opts_default.has_edge_beam == false

        # Explicit βt
        opts_bt = FlatPlateOptions(edge_beam_βt=1.5)
        @test opts_bt.edge_beam_βt ≈ 1.5

        # Sizing with explicit βt should work
        span = 18.0u"ft"
        sdl = 20.0psf
        live = 40.0psf
        opts_f = FlatPlateOptions(edge_beam_βt=1.5)
        result = SS._size_span_floor(FlatPlate(), span, sdl, live;
                                      options=opts_f, position=:edge)
        @test ustrip(u"m", result.thickness) > 0.0
    end

    # =========================================================================
    # 12. DDM run_moment_analysis with βt kwarg
    # =========================================================================
    @testset "DDM run_moment_analysis βt passthrough" begin
        # Mock structures for DDM
        mock_cell_ddm = (
            position = :edge,
            area = 252.0u"ft^2",
            sdl = 20.0psf,
            live_load = 40.0psf,
            self_weight = 87.5psf,
        )
        mock_slab_ddm = (
            spans = (primary=18.0u"ft", secondary=14.0u"ft", axis=(1.0, 0.0)),
            cell_indices = [1],
        )
        mock_col_ext = (
            c1 = 16.0u"inch",
            c2 = 16.0u"inch",
            position = :edge,
            boundary_edge_dirs = [(-1.0, 0.0)],
            vertex_idx = 1,
            tributary_cell_areas = Dict(1 => 11.71),
        )
        mock_col_int = (
            c1 = 16.0u"inch",
            c2 = 16.0u"inch",
            position = :interior,
            boundary_edge_dirs = [],
            vertex_idx = 2,
            tributary_cell_areas = Dict(1 => 23.43),
        )
        mock_struc_ddm = (
            cells = [mock_cell_ddm],
            slabs = [mock_slab_ddm],
            skeleton = (geometry = (vertex_coords = [0.0 0.0; 5.486 0.0],),),
            _tributary_caches = (vertex = Dict{Int, Dict}(),),
        )

        # DDM without edge beam
        h = 7.0u"inch"
        fc_ddm = 4000u"psi"
        wc = 150.0
        Ecs_ddm = SS.Ec(fc_ddm, wc)
        γ_ddm = SS.NWC_4000.ρ

        result_no_bt = SS.run_moment_analysis(
            SS.DDM(), mock_struc_ddm, mock_slab_ddm,
            [mock_col_ext, mock_col_int], h, fc_ddm, Ecs_ddm, γ_ddm;
            βt=0.0
        )
        # Exterior negative should use 0.26 coefficient
        @test ustrip(kip * u"ft", result_no_bt.M_neg_ext) > 0.0

        # DDM with βt = 2.5 (full edge beam)
        result_bt25 = SS.run_moment_analysis(
            SS.DDM(), mock_struc_ddm, mock_slab_ddm,
            [mock_col_ext, mock_col_int], h, fc_ddm, Ecs_ddm, γ_ddm;
            βt=2.5
        )
        # With edge beam, ext_neg coefficient is 0.30 vs 0.26 → higher moment
        @test ustrip(kip * u"ft", result_bt25.M_neg_ext) >
              ustrip(kip * u"ft", result_no_bt.M_neg_ext)

        # Ratio should match coefficient ratio: 0.30/0.26 ≈ 1.154
        ratio = ustrip(kip * u"ft", result_bt25.M_neg_ext) /
                ustrip(kip * u"ft", result_no_bt.M_neg_ext)
        @test ratio ≈ 0.30 / 0.26 atol=0.01

        # Positive moment: 0.50 vs 0.52 → slightly lower with edge beam
        @test ustrip(kip * u"ft", result_bt25.M_pos) <
              ustrip(kip * u"ft", result_no_bt.M_pos)
    end

    # =========================================================================
    # 13. Face-of-support with per-column c1
    # =========================================================================
    @testset "Face-of-support per-column c1 (conservative)" begin
        M_cl = 100.0kip * u"ft"
        V = 30.0kip
        l1 = 20.0u"ft"

        # Small column: less reduction
        c_small = 12.0u"inch"
        M_face_small = face_of_support_moment(M_cl, V, c_small, l1)

        # Large column: more reduction
        c_large = 24.0u"inch"
        M_face_large = face_of_support_moment(M_cl, V, c_large, l1)

        # Smaller column gives less reduction → higher design moment (conservative)
        @test ustrip(kip * u"ft", M_face_small) > ustrip(kip * u"ft", M_face_large)

        # Using minimum c1 among columns gives the most conservative result
        c_min = min(c_small, c_large)
        M_face_min = face_of_support_moment(M_cl, V, c_min, l1)
        @test M_face_min ≈ M_face_small  # min c1 = c_small → same result
    end
end

println("\n✓ All pipeline provision tests complete.")
