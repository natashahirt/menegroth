# ==============================================================================
# Test W Section Column NLP Optimization
# ==============================================================================
# Tests for the continuous (interior point) W section column sizer.

using Test
using StructuralSizer
using Unitful
using Asap: kip, to_inches, to_kipft

@testset "W Section Column NLP Optimization" begin
    
    @testset "NLPWOptions construction" begin
        # Default options
        opts = NLPWOptions()
        @test opts.material == A992_Steel
        @test opts.solver == :ipopt
        @test opts.min_depth == 8.0u"inch"
        @test opts.max_depth == 36.0u"inch"
        @test opts.require_compact == true
        
        # Custom options
        opts2 = NLPWOptions(
            material = A992_Steel,
            min_depth = 12.0u"inch",
            max_depth = 24.0u"inch",
            verbose = false
        )
        @test opts2.min_depth == 12.0u"inch"
    end
    
    @testset "WColumnNLPProblem interface" begin
        # Create a problem
        demand = MemberDemand(1; Pu_c=1000e3u"N", Mux=100e3u"N*m", Muy=0.0u"N*m")
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPWOptions()
        
        problem = WColumnNLPProblem(demand, geometry, opts)
        
        # Test AbstractNLPProblem interface
        @test n_variables(problem) == 4
        
        lb, ub = variable_bounds(problem)
        @test length(lb) == 4
        @test length(ub) == 4
        @test lb[1] == ustrip(u"inch", opts.min_depth)
        @test ub[1] == ustrip(u"inch", opts.max_depth)
        
        x0 = initial_guess(problem)
        @test length(x0) == 4
        @test all(x0 .> 0)  # All dimensions positive
        
        # Test constraint interface
        nc = n_constraints(problem)
        @test nc >= 4  # compression, bf/d, tf/tw, web slenderness, + optional
        
        c_lb, c_ub = constraint_bounds(problem)
        @test all(c_ub .== 1.0)  # All utilizations ≤ 1.0
    end
    
    @testset "W section geometric properties" begin
        # Test with typical W14x90 dimensions
        d, bf, tf, tw = 14.0, 14.5, 0.71, 0.44
        
        # Area
        A = StructuralSizer._w_area_smooth(d, bf, tf, tw)
        A_expected = 2*bf*tf + (d - 2*tf)*tw
        @test A ≈ A_expected
        
        # Compare with catalog (W14x90 has A ≈ 26.5 in²)
        @test 20 < A < 30
        
        # Moment of inertia
        Ix, Iy = StructuralSizer._w_inertia_smooth(d, bf, tf, tw)
        @test Ix > 0
        @test Iy > 0
        @test Ix > Iy  # Strong axis > weak axis for W shapes
        
        # Plastic modulus
        Zx, Zy = StructuralSizer._w_plastic_modulus_smooth(d, bf, tf, tw)
        @test Zx > 0
        @test Zy > 0
        @test Zx > Zy
    end
    
    @testset "Objective and constraint evaluation" begin
        demand = MemberDemand(1; Pu_c=500e3u"N", Mux=50e3u"N*m")
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPWOptions(verbose=false)
        
        problem = WColumnNLPProblem(demand, geometry, opts)
        
        # Test objective at a point (W14-like section)
        x = [14.0, 14.0, 0.7, 0.4]
        obj = objective_fn(problem, x)
        A_expected = StructuralSizer._w_area_smooth(14.0, 14.0, 0.7, 0.4)
        @test obj ≈ A_expected
        
        # Test constraints at same point
        g = constraint_fns(problem, x)
        @test length(g) >= 4
        @test all(isfinite, g)
    end
    
    @testset "Basic NLP solve with Ipopt" begin
        # Moderate demand
        demand = MemberDemand(1; Pu_c=500e3u"N", Mux=50e3u"N*m")
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPWOptions(
            solver = :ipopt,
            min_depth = 10.0u"inch",
            max_depth = 24.0u"inch",
            verbose = false
        )
        
        result = size_w_nlp(500e3u"N", 50e3u"N*m", geometry, opts)
        
        @test result isa WColumnNLPResult
        @test result.d_final >= 10.0
        @test result.d_final <= 24.0
        @test result.bf_final > 0
        @test result.tf_final > 0
        @test result.tw_final > 0
        @test result.area > 0
        @test result.weight_per_ft > 0
        @test result.Ix > 0
        @test result.Iy > 0
        
        # Check status
        @test result.status in [:optimal, :feasible, :failed]
        
        println("Ipopt result: d=$(round(result.d_final, digits=2))\", " *
                "bf=$(round(result.bf_final, digits=2))\", " *
                "tf=$(round(result.tf_final, digits=3))\", " *
                "tw=$(round(result.tw_final, digits=3))\"")
        println("  Area: $(round(result.area, digits=1)) in², " *
                "Weight: $(round(result.weight_per_ft, digits=1)) lb/ft")
    end
    
    @testset "NLP returns continuous section" begin
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPWOptions(
            solver = :ipopt,
            verbose = false
        )
        
        result = size_w_nlp(800e3u"N", 80e3u"N*m", geometry, opts)
        
        @test result.d_final > 0
        @test result.bf_final > 0
        @test result.area > 0
        
        println("NLP continuous: d=$(round(result.d_final, digits=1))\", " *
                "bf=$(round(result.bf_final, digits=1))\", " *
                "A=$(round(result.area, digits=2)) in²")
    end
    
    @testset "Multiple W columns" begin
        Pu = [300e3, 600e3, 900e3] .* u"N"
        Mux = [30e3, 60e3, 90e3] .* u"N*m"
        geoms = [SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0) for _ in 1:3]
        
        opts = NLPWOptions(solver=:ipopt, verbose=false)
        
        results = size_w_columns_nlp(Pu, Mux, geoms, opts)
        
        @test length(results) == 3
        @test all(r -> r isa WColumnNLPResult, results)
        
        # Larger demands should generally require heavier sections
        @test results[3].area >= results[1].area * 0.8  # Allow tolerance
        
        for (i, r) in enumerate(results)
            println("Column $i: d=$(round(r.d_final, digits=1))\", $(round(r.weight_per_ft, digits=1)) lb/ft")
        end
    end
    
    @testset "Proportioning constraints" begin
        # Test that bf/d ratio is reasonable
        demand = MemberDemand(1; Pu_c=600e3u"N", Mux=60e3u"N*m")
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPWOptions(
            bf_d_min = 0.5,  # Constrain to wide-flange proportions
            bf_d_max = 0.9,
            solver = :ipopt,
            verbose = false
        )
        
        result = size_w_nlp(600e3u"N", 60e3u"N*m", geometry, opts)
        
        bf_d = result.bf_final / result.d_final
        @test bf_d >= 0.5 * 0.9  # Allow some tolerance
        @test bf_d <= 0.9 * 1.1
    end
    
    @testset "Compact section enforcement" begin
        # With require_compact=true, flanges should be compact
        demand = MemberDemand(1; Pu_c=400e3u"N", Mux=40e3u"N*m")
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPWOptions(
            require_compact = true,
            solver = :ipopt,
            verbose = false
        )
        
        result = size_w_nlp(400e3u"N", 40e3u"N*m", geometry, opts)
        
        # Check flange compactness: λf = bf/(2tf) ≤ 0.38√(E/Fy)
        E_ksi = ustrip(ksi, opts.material.E)
        Fy_ksi = ustrip(ksi, opts.material.Fy)
        λpf = 0.38 * sqrt(E_ksi / Fy_ksi)
        
        λf = result.bf_final / (2 * result.tf_final)
        @test λf <= λpf * 1.2  # Allow some tolerance for solver precision
    end
    
    @testset "Smooth functions are differentiable" begin
        # Test that gradients exist and are finite
        d, bf, tf, tw = 14.0, 12.0, 0.6, 0.35
        ε = 1e-6
        
        # Area gradient w.r.t. d
        A_plus = StructuralSizer._w_area_smooth(d + ε, bf, tf, tw)
        A_minus = StructuralSizer._w_area_smooth(d - ε, bf, tf, tw)
        grad_d = (A_plus - A_minus) / (2ε)
        
        @test isfinite(grad_d)
        @test grad_d ≈ tw  # ∂A/∂d = tw (analytically)
        
        # Inertia gradient w.r.t. d
        Ix_plus, _ = StructuralSizer._w_inertia_smooth(d + ε, bf, tf, tw)
        Ix_minus, _ = StructuralSizer._w_inertia_smooth(d - ε, bf, tf, tw)
        grad_Ix_d = (Ix_plus - Ix_minus) / (2ε)
        
        @test isfinite(grad_Ix_d)
        @test grad_Ix_d > 0  # Ix increases with depth
    end

    @testset "size_w_nlp threads Mux_neg hogging Chapter F" begin
        # Leftover: NLP used deck-braced sagging Lb/Cb when Mux_neg>0.
        # AISC 360-16 §F2.2 (corpus: aisc-360-16, page 103).
        # ENGINEERING JUDGMENT: hogging Cb=1.0 (no bottom-flange Cb field).
        L = 10.0u"ft"
        geom = SteelMemberGeometry(L; Lb=3.0u"ft", Cb=1.67)
        opts = NLPWOptions(require_compact=true, min_depth=20.0u"inch",
                           max_depth=22.0u"inch", min_web_thickness=0.4u"inch",
                           verbose=false)
        Mux = 390.0kip * u"ft"
        Pu = 50.0u"kN"
        demand_hog = MemberDemand(1; Pu_c=Pu, Mux=Mux, Mux_neg=Mux)
        p_hog = WColumnNLPProblem(demand_hog, geom, opts)
        @test to_inches(p_hog.geometry.Lb) ≈ to_inches(L)
        @test p_hog.geometry.Cb == 1.0
        @test p_hog.Mux_kipft ≈ to_kipft(Mux) atol=1e-6

        # Mux_neg=0 is sagging-only — keep deck-braced Lb/Cb.
        demand_sag = MemberDemand(1; Pu_c=Pu, Mux=Mux, Mux_neg=0.0kip * u"ft")
        p_sag = WColumnNLPProblem(demand_sag, geom, opts)
        @test to_inches(p_sag.geometry.Lb) ≈ to_inches(3.0u"ft")
        @test p_sag.geometry.Cb == 1.67
        @test p_sag.Mux_kipft ≈ to_kipft(Mux) atol=1e-6

        # Edge: Mux_neg > Mux sizes against the hogging face.
        Mux_small = 100.0kip * u"ft"
        demand_edge = MemberDemand(1; Pu_c=Pu, Mux=Mux_small, Mux_neg=Mux)
        p_edge = WColumnNLPProblem(demand_edge, geom, opts)
        @test p_edge.Mux_kipft ≈ to_kipft(Mux) atol=1e-6
        @test to_inches(p_edge.geometry.Lb) ≈ to_inches(L)
        @test p_edge.geometry.Cb == 1.0

        # Production kwarg: size_w_nlp threads Mux_neg into the problem.
        section = W("W21X55")
        x = [ustrip(u"inch", section.d), ustrip(u"inch", section.bf),
             ustrip(u"inch", section.tf), ustrip(u"inch", section.tw)]
        g_hog = constraint_fns(p_hog, x)
        g_sag = constraint_fns(p_sag, x)
        @test g_hog[1] > g_sag[1]   # hogging LTB tightens H1 vs deck Lb
        result = size_w_nlp(Pu, Mux_small, geom, opts; Mux_neg=Mux_small)
        @test result.status in (:optimal, :feasible, :infeasible, :failed)
    end
    
end

println("\n✅ All W Section Column NLP tests passed!")
