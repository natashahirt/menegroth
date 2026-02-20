# Test shear and moment transfer calculations against StructurePoint
# Reference: DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14

using Test
using Unitful
using Asap  # Register Asap units (psf, ksf, kip, etc.) with Unitful's @u_str
using StructuralSizer

@testset "Shear and Moment Transfer - StructurePoint Validation" begin
    
    # Common parameters from StructurePoint example
    fc = 4000u"psi"
    fy = 60000u"psi"
    h = 7u"inch"
    d = 5.75u"inch"
    c1 = 16u"inch"  # Column dimension
    c2 = 16u"inch"
    l1 = 18u"ft"    # Span in direction 1
    l2 = 14u"ft"    # Span in direction 2
    
    # =========================================================================
    # Test 1: One-Way Shear Capacity (Section 5.1)
    # =========================================================================
    @testset "One-Way Shear Capacity" begin
        # From StructurePoint page 41:
        # Vc = 0.75 × 2 × 1.0 × √4000 × (14×12) × 5.75 = 91.64 kips
        
        bw = l2  # Full tributary width = 14 ft
        Vc = StructuralSizer.one_way_shear_capacity(fc, bw, d)
        
        # Unfactored capacity
        Vc_kips = ustrip(u"kip", Vc)
        
        # SP reports φVc = 91.64 kips, so Vc = 91.64/0.75 = 122.2 kips
        expected_Vc = 91.64 / 0.75
        
        println("\n=== One-Way Shear Capacity ===")
        println("bw = $(ustrip(u"ft", bw)) ft = $(ustrip(u"inch", bw)) in")
        println("d = $(ustrip(u"inch", d)) in")
        println("Vc = $(round(Vc_kips, digits=2)) kips")
        println("φVc = $(round(0.75 * Vc_kips, digits=2)) kips (SP: 91.64)")
        
        @test Vc_kips ≈ expected_Vc rtol=0.02
    end
    
    # =========================================================================
    # Test 2: Gamma Factors (Section 3.2.5)
    # =========================================================================
    @testset "Moment Transfer Factors γf and γv" begin
        # For exterior column (from SP page 42-43):
        # b1 = 18.88 in, b2 = 21.75 in
        # γf = 1/(1 + 2/3×√(18.88/21.75)) = 0.617
        # γv = 1 - 0.617 = 0.383
        
        b1_ext = 18.88u"inch"
        b2_ext = 21.75u"inch"
        
        γf_ext = StructuralSizer.gamma_f(b1_ext, b2_ext)
        γv_ext = StructuralSizer.gamma_v(b1_ext, b2_ext)
        
        @test γf_ext ≈ 0.617 rtol=0.01
        @test γv_ext ≈ 0.383 rtol=0.01
        @test γf_ext + γv_ext ≈ 1.0 rtol=0.001
        
        # For interior column (from SP page 44):
        # b1 = b2 = 21.75 in (symmetric)
        # γf = 1/(1 + 2/3×√1) = 0.60
        # γv = 0.40
        
        b1_int = 21.75u"inch"
        b2_int = 21.75u"inch"
        
        γf_int = StructuralSizer.gamma_f(b1_int, b2_int)
        γv_int = StructuralSizer.gamma_v(b1_int, b2_int)
        
        @test γf_int ≈ 0.60 rtol=0.01
        @test γv_int ≈ 0.40 rtol=0.01
        
        println("\n=== Moment Transfer Factors ===")
        println("Exterior column (b1=18.88, b2=21.75):")
        println("  γf = $(round(γf_ext, digits=3)) (SP: 0.617)")
        println("  γv = $(round(γv_ext, digits=3)) (SP: 0.383)")
        println("Interior column (b1=b2=21.75):")
        println("  γf = $(round(γf_int, digits=3)) (SP: 0.60)")
        println("  γv = $(round(γv_int, digits=3)) (SP: 0.40)")
    end
    
    # =========================================================================
    # Test 3: Effective Slab Width for Flexure Transfer
    # =========================================================================
    @testset "Effective Slab Width" begin
        # Interior column: bb = c2 + 3h = 16 + 3×7 = 37 in (from SP page 31)
        bb_int = StructuralSizer.effective_slab_width(c2, h; position=:interior)
        @test ustrip(u"inch", bb_int) ≈ 37 rtol=0.01
        
        # Edge column: bb = c2 + 1.5h = 16 + 1.5×7 = 26.5 in (ACI 8.4.2.3.3)
        bb_edge = StructuralSizer.effective_slab_width(c2, h; position=:edge)
        @test ustrip(u"inch", bb_edge) ≈ 26.5 rtol=0.01
        
        println("\n=== Effective Slab Width ===")
        println("Interior: bb = c2+3h = $(ustrip(u"inch", bb_int)) in (SP: 37)")
        println("Edge:     bb = c2+1.5h = $(ustrip(u"inch", bb_edge)) in (expected: 26.5)")
    end
    
    # =========================================================================
    # Test 4: Edge Column Punching Geometry (Section 5.2a)
    # =========================================================================
    @testset "Edge Column Punching Geometry" begin
        # From StructurePoint page 42:
        # b1 = c1 + d/2 = 16 + 5.75/2 = 18.88 in
        # b2 = c2 + d = 16 + 5.75 = 21.75 in
        # b0 = 2×b1 + b2 = 2×18.88 + 21.75 = 59.50 in
        # cAB = 2×b1²/(2×b1 + b2) = 2×18.88²/(2×18.88 + 21.75) = 5.99 in
        
        geom = StructuralSizer.punching_geometry_edge(c1, c2, d)
        
        @test ustrip(u"inch", geom.b1) ≈ 18.88 rtol=0.01
        @test ustrip(u"inch", geom.b2) ≈ 21.75 rtol=0.01
        @test ustrip(u"inch", geom.b0) ≈ 59.50 rtol=0.01
        @test ustrip(u"inch", geom.cAB) ≈ 5.99 rtol=0.02
        
        println("\n=== Edge Column Punching Geometry ===")
        println("b1 = $(round(ustrip(u"inch", geom.b1), digits=2)) in (SP: 18.88)")
        println("b2 = $(round(ustrip(u"inch", geom.b2), digits=2)) in (SP: 21.75)")
        println("b0 = $(round(ustrip(u"inch", geom.b0), digits=2)) in (SP: 59.50)")
        println("cAB = $(round(ustrip(u"inch", geom.cAB), digits=2)) in (SP: 5.99)")
    end
    
    # =========================================================================
    # Test 5: Interior Column Punching Geometry (Section 5.2b)
    # =========================================================================
    @testset "Interior Column Punching Geometry" begin
        # From StructurePoint page 44:
        # b1 = b2 = c + d = 16 + 5.75 = 21.75 in
        # b0 = 4×21.75 = 87 in
        # cAB = b1/2 = 10.88 in
        
        geom = StructuralSizer.punching_geometry_interior(c1, c2, d)
        
        @test ustrip(u"inch", geom.b1) ≈ 21.75 rtol=0.01
        @test ustrip(u"inch", geom.b2) ≈ 21.75 rtol=0.01
        @test ustrip(u"inch", geom.b0) ≈ 87.0 rtol=0.01
        @test ustrip(u"inch", geom.cAB) ≈ 10.875 rtol=0.01
        
        println("\n=== Interior Column Punching Geometry ===")
        println("b1 = $(round(ustrip(u"inch", geom.b1), digits=2)) in (SP: 21.75)")
        println("b2 = $(round(ustrip(u"inch", geom.b2), digits=2)) in (SP: 21.75)")
        println("b0 = $(round(ustrip(u"inch", geom.b0), digits=2)) in (SP: 87.0)")
        println("cAB = $(round(ustrip(u"inch", geom.cAB), digits=2)) in (SP: 10.88)")
    end
    
    # =========================================================================
    # Test 6: Polar Moment Jc - Edge Column (Section 5.2a)
    # =========================================================================
    @testset "Polar Moment Jc - Edge Column" begin
        # From StructurePoint page 42-43:
        # Jc = 14,109 in⁴
        
        b1 = 18.88u"inch"
        b2 = 21.75u"inch"
        cAB = 5.99u"inch"
        
        Jc = StructuralSizer.polar_moment_Jc_edge(b1, b2, d, cAB)
        Jc_in4 = ustrip(u"inch^4", Jc)
        
        println("\n=== Polar Moment Jc - Edge Column ===")
        println("Jc = $(round(Jc_in4, digits=0)) in⁴ (SP: 14,109)")
        
        @test Jc_in4 ≈ 14109 rtol=0.01
    end
    
    # =========================================================================
    # Test 7: Polar Moment Jc - Interior Column (Section 5.2b)
    # =========================================================================
    @testset "Polar Moment Jc - Interior Column" begin
        # From StructurePoint page 44:
        # Jc = 40,431 in⁴
        
        b1 = 21.75u"inch"
        b2 = 21.75u"inch"
        
        Jc = StructuralSizer.polar_moment_Jc_interior(b1, b2, d)
        Jc_in4 = ustrip(u"inch^4", Jc)
        
        println("\n=== Polar Moment Jc - Interior Column ===")
        println("Jc = $(round(Jc_in4, digits=0)) in⁴ (SP: 40,431)")
        
        # SP reports 40,431 but uses rounded cAB. Our calculation may differ slightly
        @test Jc_in4 ≈ 40431 rtol=0.03
    end
    
    # =========================================================================
    # Test 8: Combined Punching Stress - Edge Column (Section 5.2a)
    # =========================================================================
    @testset "Combined Punching Stress - Edge Column" begin
        # From StructurePoint page 42-43:
        # Vu = 21.70 kips
        # Mub = 37.81 kip-ft
        # vu = 21.70×1000/(59.5×5.75) + 0.383×(37.81×12×1000)×5.99/14109
        #    = 63.43 + 73.77 = 137.20 psi
        
        Vu = 21.70u"kip"
        Mub = 37.81u"kip*ft"
        b0 = 59.50u"inch"
        γv = 0.383
        Jc = 14109u"inch^4"
        cAB = 5.99u"inch"
        
        vu = StructuralSizer.combined_punching_stress(Vu, Mub, b0, d, γv, Jc, cAB)
        vu_psi = ustrip(u"psi", vu)
        
        # Component breakdown
        v_direct = ustrip(u"lbf", Vu) / (ustrip(u"inch", b0) * ustrip(u"inch", d))
        v_moment = γv * ustrip(u"lbf*inch", Mub) * ustrip(u"inch", cAB) / ustrip(u"inch^4", Jc)
        
        println("\n=== Combined Punching Stress - Edge Column ===")
        println("Vu = $(ustrip(u"kip", Vu)) kips")
        println("Mub = $(ustrip(u"kip*ft", Mub)) kip-ft")
        println("v_direct = $(round(v_direct, digits=2)) psi (SP: 63.43)")
        println("v_moment = $(round(v_moment, digits=2)) psi (SP: 73.77)")
        println("vu = $(round(vu_psi, digits=2)) psi (SP: 137.20)")
        
        @test vu_psi ≈ 137.20 rtol=0.02
    end
    
    # =========================================================================
    # Test 9: Combined Punching Stress - Interior Column (Section 5.2b)
    # =========================================================================
    @testset "Combined Punching Stress - Interior Column" begin
        # From StructurePoint page 44-45:
        # Vu = 50.08 kips
        # Mub = 7.70 kip-ft (small, from unbalanced moment)
        # vu = 50.08×1000/(87×5.75) + 0.40×(7.70×12×1000)×10.88/40431
        #    = 100.10 + 10.02 = 110.12 psi
        
        Vu = 50.08u"kip"
        Mub = 7.70u"kip*ft"
        b0 = 87.0u"inch"
        γv = 0.40
        Jc = 40431u"inch^4"
        cAB = 10.88u"inch"
        
        vu = StructuralSizer.combined_punching_stress(Vu, Mub, b0, d, γv, Jc, cAB)
        vu_psi = ustrip(u"psi", vu)
        
        println("\n=== Combined Punching Stress - Interior Column ===")
        println("Vu = $(ustrip(u"kip", Vu)) kips")
        println("Mub = $(ustrip(u"kip*ft", Mub)) kip-ft")
        println("vu = $(round(vu_psi, digits=2)) psi (SP: 110.12)")
        
        @test vu_psi ≈ 110.12 rtol=0.03
    end
    
    # =========================================================================
    # Test 10: Punching Capacity Stress (Table 22.6.5.2)
    # =========================================================================
    @testset "Punching Capacity Stress" begin
        # From StructurePoint page 43:
        # For edge column with b0 = 59.5 in, β = 1, αs = 30:
        # vc = min(4√4000, (2+4/1)√4000, (30×5.75/59.5+2)√4000)
        #    = min(252.98, 379.47, 309.85) = 252.98 psi
        # φvc = 0.75 × 252.98 = 189.74 psi
        
        β = 1.0  # Square column
        αs_edge = 30
        b0_edge = 59.5u"inch"
        
        vc_edge = StructuralSizer.punching_capacity_stress(fc, β, αs_edge, b0_edge, d)
        vc_edge_psi = ustrip(u"psi", vc_edge)
        
        println("\n=== Punching Capacity Stress ===")
        println("Edge column (αs=30):")
        println("  vc = $(round(vc_edge_psi, digits=2)) psi (SP: 252.98)")
        println("  φvc = $(round(0.75 * vc_edge_psi, digits=2)) psi (SP: 189.74)")
        
        @test vc_edge_psi ≈ 252.98 rtol=0.01
        
        # Interior column check (αs = 40)
        αs_int = 40
        b0_int = 87.0u"inch"
        
        vc_int = StructuralSizer.punching_capacity_stress(fc, β, αs_int, b0_int, d)
        vc_int_psi = ustrip(u"psi", vc_int)
        
        # SP page 45: vc = 252.98 psi (same, 4√f'c governs)
        println("Interior column (αs=40):")
        println("  vc = $(round(vc_int_psi, digits=2)) psi (SP: 252.98)")
        
        @test vc_int_psi ≈ 252.98 rtol=0.01
    end
    
    # =========================================================================
    # Test 11: Complete Punching Check - Edge Column
    # =========================================================================
    @testset "Complete Punching Check - Edge Column" begin
        # vu = 137.20 psi
        # φvc = 189.74 psi
        # vu < φvc → OK
        
        vu = 137.20u"psi"
        vc = 252.98u"psi"
        
        result = StructuralSizer.check_combined_punching(vu, vc)
        
        println("\n=== Punching Check - Edge Column ===")
        println("vu = $(ustrip(u"psi", vu)) psi")
        println("φvc = $(0.75 * ustrip(u"psi", vc)) psi")
        println("Result: $(result.message)")
        
        @test result.ok == true
        @test result.ratio < 1.0
    end
    
    # =========================================================================
    # Test 12: Complete Punching Check - Interior Column
    # =========================================================================
    @testset "Complete Punching Check - Interior Column" begin
        # vu = 110.12 psi
        # φvc = 189.74 psi
        # vu < φvc → OK
        
        vu = 110.12u"psi"
        vc = 252.98u"psi"
        
        result = StructuralSizer.check_combined_punching(vu, vc)
        
        println("\n=== Punching Check - Interior Column ===")
        println("vu = $(ustrip(u"psi", vu)) psi")
        println("φvc = $(0.75 * ustrip(u"psi", vc)) psi")
        println("Result: $(result.message)")
        
        @test result.ok == true
        @test result.ratio < 1.0
    end
    
    # =========================================================================
    # Test 13: Moment Transfer Reinforcement (Table 8)
    # =========================================================================
    @testset "Moment Transfer Reinforcement" begin
        # From StructurePoint Table 8 (page 32):
        # Exterior column:
        #   Mu = 46.65 kip-ft
        #   γf = 0.62 (note: slightly different from 0.617 due to rounding)
        #   γf×Mu = 28.78 kip-ft
        #   bb = 37 in
        #   As,req = 1.17 in²
        
        Mu = 46.65u"kip*ft"
        γf = 0.62  # SP uses 0.62
        bb = 37u"inch"
        
        As_transfer = StructuralSizer.transfer_reinforcement(Mu, γf, bb, d, fc, fy)
        As_in2 = ustrip(u"inch^2", As_transfer)
        
        println("\n=== Moment Transfer Reinforcement ===")
        println("Exterior column:")
        println("  Mu = $(ustrip(u"kip*ft", Mu)) kip-ft")
        println("  γf = $(γf)")
        println("  γf×Mu = $(round(γf * ustrip(u"kip*ft", Mu), digits=2)) kip-ft (SP: 28.78)")
        println("  bb = $(ustrip(u"inch", bb)) in")
        println("  As,req = $(round(As_in2, digits=2)) in² (SP: 1.17)")
        
        @test As_in2 ≈ 1.17 rtol=0.05
    end
    
    # =========================================================================
    # Test 14: Additional Transfer Bars (Table 8)
    # =========================================================================
    @testset "Additional Transfer Bars" begin
        # From StructurePoint Table 8:
        # As,provided in column strip = 1.40 in² (from flexure design)
        # bb = 37 in, strip width = 84 in
        # As within bb = 1.40 × (37/84) = 0.62 in²
        # As,req = 1.17 in²
        # Additional = 1.17 - 0.62 = 0.55 in² → 3 #4 bars (0.60 in²)
        
        As_transfer = 1.17u"inch^2"
        As_provided = 1.40u"inch^2"
        bb = 37u"inch"
        strip_width = 84u"inch"
        bar_area = 0.20u"inch^2"  # #4 bar
        
        result = StructuralSizer.additional_transfer_bars(
            As_transfer, As_provided, bb, strip_width, bar_area
        )
        
        println("\n=== Additional Transfer Bars ===")
        println("As,provided = $(ustrip(u"inch^2", As_provided)) in²")
        println("As within bb = $(round(ustrip(u"inch^2", result.As_within_bb), digits=2)) in² (SP: 0.62)")
        println("As,additional = $(round(ustrip(u"inch^2", result.As_additional), digits=2)) in² (SP: 0.55)")
        println("Additional bars = $(result.n_bars_additional) - #4 (SP: 3 - #4)")
        
        @test ustrip(u"inch^2", result.As_within_bb) ≈ 0.62 rtol=0.02
        @test ustrip(u"inch^2", result.As_additional) ≈ 0.55 rtol=0.05
        @test result.n_bars_additional == 3
    end
end

println("\n✓ Shear and moment transfer tests complete!")

# =============================================================================
# Circular Column — Punching Geometry & Combined Stress
# =============================================================================
# ACI 318-19 R22.6.4.1: For circular columns, the critical section for
# interior punching is circular with perimeter b₀ = π(D+d).
# Edge/corner circular columns are converted to equivalent square.
# =============================================================================

@testset "Circular Column — Punching & Moment Transfer" begin

    fc = 4000u"psi"
    fy = 60000u"psi"
    h = 7u"inch"
    d = 5.75u"inch"
    D = 16u"inch"     # Circular column diameter
    l1 = 18u"ft"
    l2 = 14u"ft"

    # =========================================================================
    # Circular Interior Column — Punching Geometry
    # =========================================================================
    @testset "Circular Interior — Punching Geometry" begin
        geom = StructuralSizer.punching_geometry_interior(D, D, d; shape=:circular)

        # b₀ = π(D + d) = π(16 + 5.75) = π × 21.75 ≈ 68.33 in
        b0_expected = π * (16 + 5.75)
        @test ustrip(u"inch", geom.b0) ≈ b0_expected rtol=0.001

        # b1 = b2 = b₀/4 (equivalent square)
        b_side = b0_expected / 4
        @test ustrip(u"inch", geom.b1) ≈ b_side rtol=0.001
        @test ustrip(u"inch", geom.b2) ≈ b_side rtol=0.001

        # Centroid is at b1/2
        @test ustrip(u"inch", geom.cAB) ≈ b_side / 2 rtol=0.001
    end

    # =========================================================================
    # Circular Interior Column — β Factor
    # =========================================================================
    @testset "Circular Interior — β = 1.0" begin
        β_circ = StructuralSizer.punching_β(D, D; shape=:circular)
        @test β_circ == 1.0

        # Compare with rectangular
        β_rect = StructuralSizer.punching_β(D, D; shape=:rectangular)
        @test β_rect == 1.0  # Also 1.0 since it's square

        # Non-square rectangular should have β > 1
        β_rect_nonsq = StructuralSizer.punching_β(20u"inch", 12u"inch"; shape=:rectangular)
        @test β_rect_nonsq ≈ 20 / 12 rtol=0.01
    end

    # =========================================================================
    # Circular Interior Column — Gamma Factors
    # =========================================================================
    @testset "Circular Interior — Gamma Factors" begin
        geom = StructuralSizer.punching_geometry_interior(D, D, d; shape=:circular)

        # For circular, b1 = b2 → γf = 0.60, γv = 0.40 (same as square)
        γf = StructuralSizer.gamma_f(geom.b1, geom.b2)
        γv = StructuralSizer.gamma_v(geom.b1, geom.b2)

        @test γf ≈ 0.60 rtol=0.01
        @test γv ≈ 0.40 rtol=0.01
        @test γf + γv ≈ 1.0 rtol=0.001
    end

    # =========================================================================
    # Circular Interior Column — Polar Moment Jc
    # =========================================================================
    @testset "Circular Interior — Polar Moment Jc" begin
        geom = StructuralSizer.punching_geometry_interior(D, D, d; shape=:circular)

        Jc = StructuralSizer.polar_moment_Jc_interior(geom.b1, geom.b2, d)

        # Jc should be positive
        @test ustrip(u"inch^4", Jc) > 0

        # Compare with rectangular 16" square
        geom_rect = StructuralSizer.punching_geometry_interior(D, D, d; shape=:rectangular)
        Jc_rect = StructuralSizer.polar_moment_Jc_interior(geom_rect.b1, geom_rect.b2, d)

        # Circular column has smaller critical section → smaller Jc
        @test Jc < Jc_rect
    end

    # =========================================================================
    # Circular Interior Column — Combined Punching Stress
    # =========================================================================
    @testset "Circular Interior — Combined Punching Stress" begin
        geom = StructuralSizer.punching_geometry_interior(D, D, d; shape=:circular)
        Jc = StructuralSizer.polar_moment_Jc_interior(geom.b1, geom.b2, d)
        γv = StructuralSizer.gamma_v(geom.b1, geom.b2)

        Vu = 50u"kip"
        Mub = 8u"kip*ft"

        vu = StructuralSizer.combined_punching_stress(Vu, Mub, geom.b0, d, γv, Jc, geom.cAB)

        # Should be a valid stress (positive, reasonable magnitude)
        vu_psi = ustrip(u"psi", vu)
        @test vu_psi > 0
        @test vu_psi < 500  # Sanity bound

        # Capacity check: 4√f'c should be ~253 psi, φvc ≈ 190 psi
        vc = StructuralSizer.punching_capacity_stress(fc, 1.0, 40, geom.b0, d)
        @test ustrip(u"psi", vu) < 0.75 * ustrip(u"psi", vc)  # Should pass
    end

    # =========================================================================
    # Circular Edge Column — Equivalent Square Conversion
    # =========================================================================
    @testset "Circular Edge — Equivalent Square" begin
        c_eq = StructuralSizer.equivalent_square_column(D)

        # Edge geometry uses equivalent square
        geom = StructuralSizer.punching_geometry_edge(c_eq, c_eq, d)

        # b1 = c_eq + d/2, b2 = c_eq + d
        @test ustrip(u"inch", geom.b1) ≈ ustrip(u"inch", c_eq) + 5.75 / 2 rtol=0.01
        @test ustrip(u"inch", geom.b2) ≈ ustrip(u"inch", c_eq) + 5.75 rtol=0.01

        # Perimeter should be positive
        @test ustrip(u"inch", geom.b0) > 0
    end

    # =========================================================================
    # High-Level Punching Check — Circular Column
    # =========================================================================
    @testset "Punching Check API — Circular" begin
        Vu = 45u"kip"
        Mux = 5u"kip*ft"
        Muy = 0u"kip*ft"

        # Interior circular column
        result = StructuralSizer.punching_check(
            Vu, Mux, Muy, d, fc, D, D;
            position=:interior, shape=:circular
        )

        @test result.ok == true
        @test result.utilization < 1.0
        @test result.utilization > 0.0
        @test ustrip(u"psi", result.vu) > 0
        @test ustrip(u"psi", result.ϕvc) > 0

        # Compare with rectangular
        result_rect = StructuralSizer.punching_check(
            Vu, Mux, Muy, d, fc, D, D;
            position=:interior, shape=:rectangular
        )

        # Circular should have higher utilization (less b₀)
        @test result.utilization > result_rect.utilization
    end
end

println("\n✓ Circular column punching and moment transfer tests complete!")
