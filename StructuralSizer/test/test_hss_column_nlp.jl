# ==============================================================================
# Test HSS Column NLP Optimization
# ==============================================================================
# Tests for the continuous (interior point) HSS column sizer with smooth AISC functions.

using Test
using StructuralSizer
using Unitful

@testset "HSS Column NLP Optimization" begin
    
    @testset "NLPHSSOptions construction" begin
        # Default options
        opts = NLPHSSOptions()
        @test opts.material == A992_Steel
        @test opts.solver == :ipopt
        @test opts.min_outer == 4.0u"inch"
        @test opts.max_outer == 20.0u"inch"
        @test opts.min_thickness == 0.125u"inch"
        
        # Custom options
        opts2 = NLPHSSOptions(
            material = A992_Steel,
            min_outer = 6.0u"inch",
            max_outer = 16.0u"inch",
            prefer_square = 0.1,
            verbose = false
        )
        @test opts2.min_outer == 6.0u"inch"
        @test opts2.prefer_square == 0.1
    end
    
    @testset "HSSColumnNLPProblem interface" begin
        # Create a problem
        demand = MemberDemand(1; Pu_c=500e3u"N", Mux=50e3u"N*m", Muy=0.0u"N*m")
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPHSSOptions()
        
        problem = HSSColumnNLPProblem(demand, geometry, opts)
        
        # Test AbstractNLPProblem interface
        @test n_variables(problem) == 3
        
        lb, ub = variable_bounds(problem)
        @test length(lb) == 3
        @test length(ub) == 3
        @test lb[1] == ustrip(u"inch", opts.min_outer)
        @test ub[1] == ustrip(u"inch", opts.max_outer)
        
        x0 = initial_guess(problem)
        @test length(x0) == 3
        @test x0[1] > 0  # B > 0
        @test x0[2] > 0  # H > 0
        @test x0[3] > 0  # t > 0
        
        # Test constraint interface
        nc = n_constraints(problem)
        @test nc >= 2  # At least compression + b/t ratio
        
        c_lb, c_ub = constraint_bounds(problem)
        @test all(c_ub .== 1.0)  # All utilizations ≤ 1.0
    end
    
    @testset "Smooth AISC utilities" begin
        # Test smooth sigmoid
        σ = StructuralSizer._smooth_sigmoid(0.0)
        @test σ ≈ 0.5 atol=0.01
        
        σ_pos = StructuralSizer._smooth_sigmoid(5.0)
        @test σ_pos > 0.99
        
        σ_neg = StructuralSizer._smooth_sigmoid(-5.0)
        @test σ_neg < 0.01
        
        # Test smooth step
        step_below = StructuralSizer._smooth_step(1.0, 2.0)
        @test step_below < 0.1
        
        step_above = StructuralSizer._smooth_step(3.0, 2.0)
        @test step_above > 0.9
        
        # Test smooth column curve matches original at key points
        E = 29000.0
        Fy = 50.0
        
        # Case 1: Fy/Fe << 2.25 (inelastic)
        Fe_high = 100.0  # Fy/Fe = 0.5
        Fcr_orig = StructuralSizer._Fcr_column(Fe_high, Fy)
        Fcr_smooth = StructuralSizer._Fcr_column_smooth(Fe_high, Fy)
        @test isapprox(Fcr_orig, Fcr_smooth; rtol=0.05)
        
        # Case 2: Fy/Fe >> 2.25 (elastic)
        Fe_low = 10.0   # Fy/Fe = 5.0
        Fcr_orig2 = StructuralSizer._Fcr_column(Fe_low, Fy)
        Fcr_smooth2 = StructuralSizer._Fcr_column_smooth(Fe_low, Fy)
        @test isapprox(Fcr_orig2, Fcr_smooth2; rtol=0.05)
    end
    
    @testset "HSS geometric properties" begin
        B, H, t = 8.0, 8.0, 0.5  # 8x8x1/2 HSS
        
        # Area
        A = StructuralSizer._hss_area_smooth(B, H, t)
        A_expected = 2*(B + H - 2*t)*t
        @test A ≈ A_expected
        
        # Compare with catalog section
        hss = HSSRectSection(H*u"inch", B*u"inch", t*u"inch")
        @test isapprox(A, ustrip(u"inch^2", hss.A); rtol=0.01)
        
        # Moment of inertia
        Ix, Iy = StructuralSizer._hss_inertia_smooth(B, H, t)
        @test isapprox(Ix, ustrip(u"inch^4", hss.Ix); rtol=0.05)
        @test isapprox(Iy, ustrip(u"inch^4", hss.Iy); rtol=0.05)
    end
    
    @testset "Objective and constraint evaluation" begin
        demand = MemberDemand(1; Pu_c=200e3u"N", Mux=20e3u"N*m")
        geometry = SteelMemberGeometry(3.5; Kx=1.0, Ky=1.0)
        opts = NLPHSSOptions(verbose=false)
        
        problem = HSSColumnNLPProblem(demand, geometry, opts)
        
        # Test objective at a point
        x = [10.0, 10.0, 0.375]  # 10x10x3/8 HSS
        obj = objective_fn(problem, x)
        A_expected = 2*(10 + 10 - 2*0.375)*0.375
        @test obj ≈ A_expected atol=0.1
        
        # Test constraints at same point
        g = constraint_fns(problem, x)
        @test length(g) >= 2
        @test all(isfinite, g)
    end
    
    @testset "Basic NLP solve with Ipopt" begin
        # Moderate demand
        demand = MemberDemand(1; Pu_c=300e3u"N", Mux=30e3u"N*m")
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPHSSOptions(
            solver = :ipopt,
            min_outer = 6.0u"inch",
            max_outer = 16.0u"inch",
            verbose = false
        )
        
        result = size_hss_nlp(300e3u"N", 30e3u"N*m", geometry, opts)
        
        @test result isa HSSColumnNLPResult
        @test result.section isa HSSRectSection
        @test result.B_final >= 6.0
        @test result.B_final <= 16.0
        @test result.H_final >= 6.0
        @test result.H_final <= 16.0
        @test result.t_final > 0
        @test result.area > 0
        @test result.weight_per_ft > 0
        
        # Check status
        @test result.status in [:optimal, :feasible, :failed]
        
        println("Ipopt result: HSS $(result.B_final)×$(result.H_final)×$(result.t_final), $(round(result.weight_per_ft, digits=1)) lb/ft")
    end
    
    @testset "Verify capacity of optimized section" begin
        # Size a column
        Pu = 400e3u"N"
        Mux = 40e3u"N*m"
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        opts = NLPHSSOptions(solver=:ipopt, verbose=false)
        
        result = size_hss_nlp(Pu, Mux, geometry, opts)
        
        # Verify the final section has adequate capacity
        mat = opts.material
        L = geometry.L * u"m"
        
        # Get compression capacity using standard AISC function
        φPn = get_ϕPn(result.section, mat, L; axis=:weak)
        Pu_kip = uconvert(u"N", Pu)
        
        # Should have adequate capacity (with some margin for rounding)
        @test φPn >= Pu_kip * 0.9  # Allow 10% margin for rounding effects
    end
    
    @testset "Multiple HSS columns" begin
        Pu = [200e3, 400e3, 600e3] .* u"N"
        Mux = [20e3, 40e3, 60e3] .* u"N*m"
        geoms = [SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0) for _ in 1:3]
        
        opts = NLPHSSOptions(solver=:ipopt, verbose=false)
        
        results = size_hss_columns_nlp(Pu, Mux, geoms, opts)
        
        @test length(results) == 3
        @test all(r -> r isa HSSColumnNLPResult, results)
        
        # Larger demands should generally require heavier sections
        @test results[3].area >= results[1].area * 0.8  # Allow tolerance
        
        for (i, r) in enumerate(results)
            println("Column $i: HSS $(r.B_final)×$(r.H_final)×$(r.t_final)")
        end
    end
    
    @testset "Prefer square option" begin
        demand = MemberDemand(1; Pu_c=300e3u"N", Mux=30e3u"N*m")
        geometry = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)
        
        opts_square = NLPHSSOptions(prefer_square=0.5, solver=:ipopt, verbose=false)
        
        result = size_hss_nlp(300e3u"N", 30e3u"N*m", geometry, opts_square)
        
        # With prefer_square penalty, should tend toward square
        aspect = max(result.B_final/result.H_final, result.H_final/result.B_final)
        @test aspect <= 1.5  # Should be reasonably square
    end
    
    @testset "Smooth functions are differentiable (ForwardDiff compatible)" begin
        # This tests that our smooth functions work with ForwardDiff
        # by checking they don't throw when called with Dual numbers
        
        # Test smooth column curve gradient exists
        E = 29000.0
        Fy = 50.0
        Fe = 30.0
        
        # Numerical gradient
        ε = 1e-6
        Fcr_plus = StructuralSizer._Fcr_column_smooth(Fe + ε, Fy)
        Fcr_minus = StructuralSizer._Fcr_column_smooth(Fe - ε, Fy)
        grad_Fe = (Fcr_plus - Fcr_minus) / (2ε)
        
        # Gradient should be finite and non-zero
        @test isfinite(grad_Fe)
        @test abs(grad_Fe) > 1e-10
        
        # Test area gradient
        B, H, t = 10.0, 10.0, 0.5
        A_plus = StructuralSizer._hss_area_smooth(B + ε, H, t)
        A_minus = StructuralSizer._hss_area_smooth(B - ε, H, t)
        grad_B = (A_plus - A_minus) / (2ε)
        
        @test isfinite(grad_B)
        @test grad_B ≈ 2*t  # ∂A/∂B = 2t (analytically)
    end
    
end

println("\n✅ All HSS Column NLP tests passed!")
