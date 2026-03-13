"""
Test Hardy Cross moment distribution for larger frame geometries.

This test verifies the implementation scales correctly beyond the 3-span
StructurePoint validation case. For 5+ spans:
1. Hardy Cross and ASAP should agree (cross-validation)
2. Symmetry should be preserved for symmetric geometry
3. Interior spans should have similar moments (for equal spans)

Since we don't have StructurePoint reference values for these cases,
we validate by comparing Hardy Cross vs ASAP column-stub results.
"""

using Test
using Unitful
using Asap  # For units like psf, pcf, and ASAP functions
using StructuralSizer

@testset "Hardy Cross - Larger Geometries" begin
    
    # Common parameters (based on StructurePoint example, but more spans)
    fc = 4000.0u"psi"
    fy = 60000.0u"psi"
    
    # Compute Ec per ACI 318-14 Table 19.2.2.1
    Ecs = 57000 * sqrt(ustrip(u"psi", fc)) * u"psi"  # Slab Ec
    Ecc = Ecs  # Same concrete for columns
    
    # Geometry
    h = 7u"inch"       # Slab thickness
    l1 = 18u"ft"       # Span length
    l2 = 14u"ft"       # Tributary width
    c1 = 18u"inch"     # Column dimension parallel to l1
    c2 = 18u"inch"     # Column dimension parallel to l2
    H = 12u"ft"        # Story height
    ln = l1 - c1       # Clear span
    
    # Loads
    DL = 87.5psf + 20.0psf  # Self-weight + superimposed
    LL = 40.0psf
    qu = 1.2 * DL + 1.6 * LL  # Factored load = 193 psf
    
    # Compute span properties using PCA table lookup
    Is = StructuralSizer.slab_moment_of_inertia(l2, h)
    sf_lg = StructuralSizer.pca_slab_beam_factors(c1, l1, c2, l2)
    Ksb = StructuralSizer.slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2; k_factor=sf_lg.k)
    
    @testset "5-Span Symmetric Frame" begin
        n_spans = 5
        n_joints = n_spans + 1
        
        # Create span properties
        spans = [
            StructuralSizer.EFMSpanProperties(
                i, i, i+1,
                l1, l2, ln,
                h, c1, c2, c1, c2,
                Is, Ksb,
                sf_lg.m, sf_lg.COF, sf_lg.k
            )
            for i in 1:n_spans
        ]
        
        # All interior joints for this test
        joint_positions = fill(:interior, n_joints)
        
        # Compute Kec at each joint
        joint_Kec = StructuralSizer._compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc)
        
        # Run Hardy Cross
        hc_moments = StructuralSizer.solve_moment_distribution(
            spans, joint_Kec, joint_positions, qu;
            COF=sf_lg.COF, max_iterations=30, tolerance=0.001, verbose=false
        )
        
        println("\n=== 5-Span Hardy Cross Results ===")
        for (i, m) in enumerate(hc_moments)
            println("Span $i: M_left=$(round(ustrip(kip*u"ft", m.M_neg_left), digits=2)), " *
                    "M_pos=$(round(ustrip(kip*u"ft", m.M_pos), digits=2)), " *
                    "M_neg_right=$(round(ustrip(kip*u"ft", m.M_neg_right), digits=2))")
        end
        
        # Test symmetry: spans 1 and 5 should be mirror images
        @test ustrip(kip*u"ft", hc_moments[1].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[5].M_neg_right) rtol=0.01
        @test ustrip(kip*u"ft", hc_moments[1].M_neg_right) ≈ ustrip(kip*u"ft", hc_moments[5].M_neg_left) rtol=0.01
        @test ustrip(kip*u"ft", hc_moments[1].M_pos) ≈ ustrip(kip*u"ft", hc_moments[5].M_pos) rtol=0.01
        
        # Test symmetry: spans 2 and 4 should be mirror images
        @test ustrip(kip*u"ft", hc_moments[2].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[4].M_neg_right) rtol=0.01
        @test ustrip(kip*u"ft", hc_moments[2].M_neg_right) ≈ ustrip(kip*u"ft", hc_moments[4].M_neg_left) rtol=0.01
        @test ustrip(kip*u"ft", hc_moments[2].M_pos) ≈ ustrip(kip*u"ft", hc_moments[4].M_pos) rtol=0.01
        
        # Center span (3) should be symmetric
        @test ustrip(kip*u"ft", hc_moments[3].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[3].M_neg_right) rtol=0.01
        
        # Exterior moments should be less than first interior (typical for flat plates)
        @test ustrip(kip*u"ft", hc_moments[1].M_neg_left) < ustrip(kip*u"ft", hc_moments[1].M_neg_right)
        
        # Positive moments: exterior spans should have larger positive moment than interior
        @test ustrip(kip*u"ft", hc_moments[1].M_pos) > ustrip(kip*u"ft", hc_moments[3].M_pos)
    end
    
    @testset "6-Span Frame - Even Number" begin
        n_spans = 6
        n_joints = n_spans + 1
        
        spans = [
            StructuralSizer.EFMSpanProperties(
                i, i, i+1,
                l1, l2, ln,
                h, c1, c2, c1, c2,
                Is, Ksb,
                sf_lg.m, sf_lg.COF, sf_lg.k
            )
            for i in 1:n_spans
        ]
        
        joint_positions = fill(:interior, n_joints)
        joint_Kec = StructuralSizer._compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc)
        
        hc_moments = StructuralSizer.solve_moment_distribution(
            spans, joint_Kec, joint_positions, qu;
            COF=sf_lg.COF, max_iterations=30, tolerance=0.001, verbose=false
        )
        
        println("\n=== 6-Span Hardy Cross Results ===")
        for (i, m) in enumerate(hc_moments)
            println("Span $i: M_left=$(round(ustrip(kip*u"ft", m.M_neg_left), digits=2)), " *
                    "M_pos=$(round(ustrip(kip*u"ft", m.M_pos), digits=2)), " *
                    "M_neg_right=$(round(ustrip(kip*u"ft", m.M_neg_right), digits=2))")
        end
        
        # Test symmetry for 6-span (symmetric about centerline between spans 3 and 4)
        @test ustrip(kip*u"ft", hc_moments[1].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[6].M_neg_right) rtol=0.01
        @test ustrip(kip*u"ft", hc_moments[2].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[5].M_neg_right) rtol=0.01
        @test ustrip(kip*u"ft", hc_moments[3].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[4].M_neg_right) rtol=0.01
        
        # Interior spans (3 and 4) should have similar positive moments
        @test ustrip(kip*u"ft", hc_moments[3].M_pos) ≈ ustrip(kip*u"ft", hc_moments[4].M_pos) rtol=0.01
    end
    
    @testset "Hardy Cross vs ASAP Cross-Validation (5 spans)" begin
        # Both solvers should agree when using the same column stiffness model.
        # Use Kc (raw column stiffness, no torsional reduction) for Hardy Cross,
        # and col_I_factor=1.0 (gross Ig) for ASAP so the column elements match.
        n_spans = 5
        n_joints = n_spans + 1
        
        spans = [
            StructuralSizer.EFMSpanProperties(
                i, i, i+1,
                l1, l2, ln,
                h, c1, c2, c1, c2,
                Is, Ksb,
                sf_lg.m, sf_lg.COF, sf_lg.k
            )
            for i in 1:n_spans
        ]
        
        joint_positions = fill(:interior, n_joints)

        # Hardy Cross with raw Kc (no torsional reduction)
        joint_Kc = StructuralSizer._compute_joint_Kec(
            spans, joint_positions, H, Ecs, Ecc; use_kc_only=true
        )
        
        hc_moments = StructuralSizer.solve_moment_distribution(
            spans, joint_Kc, joint_positions, qu;
            COF=sf_lg.COF, max_iterations=30, tolerance=0.001, verbose=false
        )
        
        # Mock column objects (identical columns above & below at each joint)
        col_above_mock = (c1=c1, c2=c2, base=(L=H,), column_above=nothing)
        mock_columns = [(c1=c1, c2=c2, base=(L=H,), column_above=col_above_mock) for _ in 1:n_joints]
        
        # ASAP column-stub solution with gross Ig (col_I_factor=1.0)
        model, span_elements, _ = StructuralSizer.build_efm_asap_model(
            spans, joint_positions, qu;
            Ecs=Ecs, Ecc=Ecc,
            ν_concrete=0.20, ρ_concrete=2380.0u"kg/m^3",
            columns=mock_columns,
            col_I_factor=1.0,
        )
        StructuralSizer.solve_efm_frame!(model)
        asap_moments = StructuralSizer.extract_span_moments(model, span_elements, spans; qu=qu)
        
        println("\n=== Hardy Cross vs ASAP Comparison (5 spans, Kc mode) ===")
        println("Span | HC M_left | ASAP M_left | HC M_pos | ASAP M_pos | HC M_right | ASAP M_right")
        println("-" ^ 85)
        for i in 1:n_spans
            hc = hc_moments[i]
            asap = asap_moments[i]
            println("  $i  |  $(round(ustrip(kip*u"ft", hc.M_neg_left), digits=1))   |   " *
                    "$(round(ustrip(kip*u"ft", asap.M_neg_left), digits=1))     |  " *
                    "$(round(ustrip(kip*u"ft", hc.M_pos), digits=1))   |   " *
                    "$(round(ustrip(kip*u"ft", asap.M_pos), digits=1))    |   " *
                    "$(round(ustrip(kip*u"ft", hc.M_neg_right), digits=1))    |    " *
                    "$(round(ustrip(kip*u"ft", asap.M_neg_right), digits=1))")
        end
        
        # Compare Hardy Cross vs ASAP — with matching Kc stiffness they should agree within ~5%
        for i in 1:n_spans
            hc = hc_moments[i]
            asap = asap_moments[i]
            
            # Negative moments at supports
            @test ustrip(kip*u"ft", hc.M_neg_left) ≈ ustrip(kip*u"ft", asap.M_neg_left) rtol=0.05
            @test ustrip(kip*u"ft", hc.M_neg_right) ≈ ustrip(kip*u"ft", asap.M_neg_right) rtol=0.05
            
            # Positive moments (slightly larger tolerance — midspan interpolation)
            @test ustrip(kip*u"ft", hc.M_pos) ≈ ustrip(kip*u"ft", asap.M_pos) rtol=0.10
        end
    end
    
    @testset "Hardy Cross vs ASAP Cross-Validation (5 spans, Kec mode)" begin
        # With Kec reduction applied to ASAP column stubs, both solvers should
        # agree even when using the standard Kec (torsional reduction) model.
        n_spans = 5
        n_joints = n_spans + 1
        
        spans = [
            StructuralSizer.EFMSpanProperties(
                i, i, i+1,
                l1, l2, ln,
                h, c1, c2, c1, c2,
                Is, Ksb,
                sf_lg.m, sf_lg.COF, sf_lg.k
            )
            for i in 1:n_spans
        ]
        
        joint_positions = fill(:interior, n_joints)

        # Hardy Cross with Kec (standard torsional reduction)
        joint_Kec = StructuralSizer._compute_joint_Kec(
            spans, joint_positions, H, Ecs, Ecc; use_kc_only=false
        )
        
        hc_moments = StructuralSizer.solve_moment_distribution(
            spans, joint_Kec, joint_positions, qu;
            COF=sf_lg.COF, max_iterations=30, tolerance=0.001, verbose=false
        )
        
        # Mock column objects (identical columns above & below at each joint)
        col_above_mock = (c1=c1, c2=c2, base=(L=H,), column_above=nothing)
        mock_columns = [(c1=c1, c2=c2, base=(L=H,), column_above=col_above_mock) for _ in 1:n_joints]
        
        # Kec reduction factors (same computation the production code uses)
        kec_factors = StructuralSizer._compute_kec_reduction_factors(
            spans, joint_positions, H, Ecs, Ecc; use_kc_only=false, columns=mock_columns
        )
        
        # ASAP column-stub solution with Kec-reduced I
        model, span_elements, _ = StructuralSizer.build_efm_asap_model(
            spans, joint_positions, qu;
            Ecs=Ecs, Ecc=Ecc,
            ν_concrete=0.20, ρ_concrete=2380.0u"kg/m^3",
            columns=mock_columns,
            col_I_factor=1.0,
            kec_factors=kec_factors,
        )
        StructuralSizer.solve_efm_frame!(model)
        asap_moments = StructuralSizer.extract_span_moments(model, span_elements, spans; qu=qu)
        
        println("\n=== Hardy Cross vs ASAP Comparison (5 spans, Kec mode) ===")
        println("Kec/Kc factors: $(round.(kec_factors, digits=3))")
        println("Span | HC M_left | ASAP M_left | HC M_pos | ASAP M_pos | HC M_right | ASAP M_right")
        println("-" ^ 85)
        for i in 1:n_spans
            hc = hc_moments[i]
            asap = asap_moments[i]
            println("  $i  |  $(round(ustrip(kip*u"ft", hc.M_neg_left), digits=1))   |   " *
                    "$(round(ustrip(kip*u"ft", asap.M_neg_left), digits=1))     |  " *
                    "$(round(ustrip(kip*u"ft", hc.M_pos), digits=1))   |   " *
                    "$(round(ustrip(kip*u"ft", asap.M_pos), digits=1))    |   " *
                    "$(round(ustrip(kip*u"ft", hc.M_neg_right), digits=1))    |    " *
                    "$(round(ustrip(kip*u"ft", asap.M_neg_right), digits=1))")
        end
        
        # With Kec reduction, ASAP and Hardy Cross should agree within ~10%
        for i in 1:n_spans
            hc = hc_moments[i]
            asap = asap_moments[i]
            
            @test ustrip(kip*u"ft", hc.M_neg_left) ≈ ustrip(kip*u"ft", asap.M_neg_left) rtol=0.10
            @test ustrip(kip*u"ft", hc.M_neg_right) ≈ ustrip(kip*u"ft", asap.M_neg_right) rtol=0.10
            @test ustrip(kip*u"ft", hc.M_pos) ≈ ustrip(kip*u"ft", asap.M_pos) rtol=0.15
        end
    end

    @testset "Single Span Edge Case" begin
        # Single span with columns at both ends
        n_spans = 1
        n_joints = 2
        
        spans = [
            StructuralSizer.EFMSpanProperties(
                1, 1, 2,
                l1, l2, ln,
                h, c1, c2, c1, c2,
                Is, Ksb,
                sf_lg.m, sf_lg.COF, sf_lg.k
            )
        ]
        
        joint_positions = [:interior, :interior]  # Both are "exterior" but with columns
        joint_Kec = StructuralSizer._compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc)
        
        hc_moments = StructuralSizer.solve_moment_distribution(
            spans, joint_Kec, joint_positions, qu;
            COF=sf_lg.COF, max_iterations=20, tolerance=0.001, verbose=false
        )
        
        println("\n=== Single Span Results ===")
        m = hc_moments[1]
        println("M_left = $(round(ustrip(kip*u"ft", m.M_neg_left), digits=2)) kip-ft")
        println("M_pos  = $(round(ustrip(kip*u"ft", m.M_pos), digits=2)) kip-ft")
        println("M_right = $(round(ustrip(kip*u"ft", m.M_neg_right), digits=2)) kip-ft")
        
        # Single span should be symmetric
        @test ustrip(kip*u"ft", m.M_neg_left) ≈ ustrip(kip*u"ft", m.M_neg_right) rtol=0.01
        
        # Moments should be reasonable (not zero, not infinite)
        @test 0 < ustrip(kip*u"ft", m.M_neg_left) < 100
        @test 0 < ustrip(kip*u"ft", m.M_pos) < 100
    end
    
    @testset "Convergence for 10 Spans" begin
        # Test that algorithm converges for very long frames
        n_spans = 10
        n_joints = n_spans + 1
        
        spans = [
            StructuralSizer.EFMSpanProperties(
                i, i, i+1,
                l1, l2, ln,
                h, c1, c2, c1, c2,
                Is, Ksb,
                sf_lg.m, sf_lg.COF, sf_lg.k
            )
            for i in 1:n_spans
        ]
        
        joint_positions = fill(:interior, n_joints)
        joint_Kec = StructuralSizer._compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc)
        
        # Should converge within 30 iterations
        hc_moments = StructuralSizer.solve_moment_distribution(
            spans, joint_Kec, joint_positions, qu;
            COF=sf_lg.COF, max_iterations=30, tolerance=0.001, verbose=false
        )
        
        println("\n=== 10-Span Results (checking convergence) ===")
        println("Exterior span 1: M_left=$(round(ustrip(kip*u"ft", hc_moments[1].M_neg_left), digits=2))")
        println("Center span 5: M_left=$(round(ustrip(kip*u"ft", hc_moments[5].M_neg_left), digits=2))")
        println("Center span 6: M_left=$(round(ustrip(kip*u"ft", hc_moments[6].M_neg_left), digits=2))")
        
        # Verify symmetry (1 mirrors 10, 5 mirrors 6 at center)
        @test ustrip(kip*u"ft", hc_moments[1].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[10].M_neg_right) rtol=0.01
        @test ustrip(kip*u"ft", hc_moments[5].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[6].M_neg_right) rtol=0.01
        
        # Interior spans should have stabilized moments
        @test ustrip(kip*u"ft", hc_moments[5].M_neg_left) ≈ ustrip(kip*u"ft", hc_moments[5].M_neg_right) rtol=0.02
    end
end

println("\n✓ Hardy Cross larger geometry tests complete!")
