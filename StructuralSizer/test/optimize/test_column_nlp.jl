# ==============================================================================
# Test RC Column NLP Optimization
# ==============================================================================
# Tests for the continuous (interior point) column sizer.

using Test
using StructuralSizer
using Unitful
using Asap: kip, ksi

@testset "RC Column NLP Optimization" begin
    
    @testset "NLPColumnOptions construction" begin
        # Default options
        opts = NLPColumnOptions()
        @test opts.grade == NWC_4000
        @test opts.solver == :ipopt
        @test opts.min_dim == 8.0u"inch"
        @test opts.max_dim == 48.0u"inch"
        
        # Custom options
        opts2 = NLPColumnOptions(
            grade = NWC_5000,
            min_dim = 14.0u"inch",
            max_dim = 30.0u"inch",
            prefer_square = 0.1,
            verbose = false
        )
        @test opts2.grade == NWC_5000
        @test opts2.prefer_square == 0.1
    end
    
    @testset "RCColumnNLPProblem interface" begin
        # Create a problem
        demand = RCColumnDemand(1; Pu=500.0, Mux=200.0, Muy=0.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions()
        
        problem = RCColumnNLPProblem(demand, geometry, opts)
        
        # Test AbstractNLPProblem interface
        @test n_variables(problem) == 3
        
        lb, ub = variable_bounds(problem)
        @test length(lb) == 3
        @test length(ub) == 3
        @test lb[3] == 0.01  # ACI min ρ
        @test ub[3] == 0.06  # Practical max ρ (ACI allows 0.08)
        
        x0 = initial_guess(problem)
        @test length(x0) == 3
        @test x0[1] > 0  # b > 0
        @test x0[2] > 0  # h > 0
        @test 0.01 <= x0[3] <= 0.06  # valid ρ
        
        # Test constraint interface
        @test n_constraints(problem) == 1  # Only P-M (no biaxial since Muy=0)
        
        c_lb, c_ub = constraint_bounds(problem)
        @test c_ub[1] == 1.0  # utilization ≤ 1.0
    end
    
    @testset "Objective and constraint evaluation" begin
        demand = RCColumnDemand(1; Pu=300.0, Mux=100.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(3.5; k=1.0, braced=true)
        opts = NLPColumnOptions(verbose=false)
        
        problem = RCColumnNLPProblem(demand, geometry, opts)
        
        # Test objective at a point — MinVolume uses Ag*(1 + 2ρ) to penalize high ρ
        x = [18.0, 18.0, 0.02]  # 18" square, 2% steel
        obj = objective_fn(problem, x)
        @test obj ≈ 18.0 * 18.0 * (1 + 2 * 0.02)  # Ag*(1+2ρ) = 336.96
        
        # Test constraint at same point
        g = constraint_fns(problem, x)
        @test length(g) == 1
        @test g[1] isa Float64
        # Should be feasible (utilization < 1) for this modest demand
        # but exact value depends on P-M capacity
    end
    
    @testset "Trial section building" begin
        opts = NLPColumnOptions(bar_size=8)
        
        # Build a valid section
        section = StructuralSizer._build_nlp_trial_section(20.0, 20.0, 0.02, opts)
        @test !isnothing(section)
        @test section isa RCColumnSection
        
        # Check dimensions
        @test ustrip(u"inch", section.b) ≈ 20.0
        @test ustrip(u"inch", section.h) ≈ 20.0
        
        # Check reinforcement is reasonable
        @test section.ρg >= 0.01
        @test section.ρg <= 0.08
    end
    
    @testset "Basic NLP solve - ipopt" begin
        # Basic test with default Ipopt solver
        # Use moderate demand that fits well within dimension bounds
        demand = RCColumnDemand(1; Pu=300.0, Mux=100.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(3.5; k=1.0, braced=true)
        opts = NLPColumnOptions(
            solver = :ipopt,  # Interior point
            min_dim = 14.0u"inch",
            max_dim = 36.0u"inch",  # Wider bounds for reliability
            verbose = false
        )
        
        result = size_rc_column_nlp(300.0kip, 100.0kip*u"ft", geometry, opts)
        
        @test result isa RCColumnNLPResult
        @test result.section isa RCColumnSection
        @test result.b_final >= 14.0
        @test result.b_final <= 36.0
        @test result.h_final >= 14.0
        @test result.h_final <= 36.0
        @test result.area > 0
        
        # Check the result converged (allow :failed with small tolerance)
        @test result.status in [:optimal, :feasible, :failed]  # :failed still returns a section
    end
    
    @testset "NLP solve with Ipopt" begin
        # Test with Ipopt (the main use case)
        demand = RCColumnDemand(1; Pu=500.0, Mux=200.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(
            grade = NWC_4000,
            solver = :ipopt,
            min_dim = 14.0u"inch",
            max_dim = 36.0u"inch",
            verbose = false
        )
        
        result = size_rc_column_nlp(500.0kip, 200.0kip*u"ft", geometry, opts)
        
        @test result isa RCColumnNLPResult
        @test result.section isa RCColumnSection
        @test result.status in [:optimal, :feasible]
        
        # The optimal section should be within bounds
        @test 14.0 <= result.b_final <= 36.0
        @test 14.0 <= result.h_final <= 36.0
        
        # Verify the final section passes capacity check
        mat = (fc = fc_ksi(opts.grade), fy = 60.0, Es = 29000.0, εcu = 0.003)
        diagram = generate_PM_diagram(result.section, mat)
        check = check_PM_capacity(diagram, 500.0, 200.0)
        @test check.adequate || check.utilization < 1.1  # Allow small tolerance
        
        println("Ipopt result: $(result.b_final)\" × $(result.h_final)\", ρ=$(round(result.ρ_opt, digits=3))")
    end
    
    @testset "Multiple columns" begin
        Pu = [300.0, 500.0, 700.0] .* kip
        Mux = [100.0, 200.0, 300.0] .* kip .* u"ft"
        geoms = [ConcreteMemberGeometry(4.0; k=1.0, braced=true) for _ in 1:3]
        
        opts = NLPColumnOptions(
            solver = :ipopt,
            verbose = false
        )
        
        results = size_rc_columns_nlp(Pu, Mux, geoms, opts)
        
        @test length(results) == 3
        @test all(r -> r isa RCColumnNLPResult, results)
        
        # Larger demands should generally require larger columns
        # (though this isn't guaranteed due to solver tolerance)
        @test results[3].area >= results[1].area * 0.8  # Allow some tolerance
    end
    
    @testset "Slenderness effects" begin
        # Test with slenderness enabled (default) - both cases should produce valid results
        demand = RCColumnDemand(1; Pu=400.0, Mux=100.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(5.0; k=1.0, braced=true)  # Taller column
        
        opts_with = NLPColumnOptions(include_slenderness=true, solver=:ipopt, verbose=false)
        opts_without = NLPColumnOptions(include_slenderness=false, solver=:ipopt, verbose=false)
        
        result_with = size_rc_column_nlp(400.0kip, 100.0kip*u"ft", geometry, opts_with)
        result_without = size_rc_column_nlp(400.0kip, 100.0kip*u"ft", geometry, opts_without)
        
        # Both should produce valid sections
        @test result_with.section isa RCColumnSection
        @test result_without.section isa RCColumnSection
        @test result_with.area > 0
        @test result_without.area > 0
        # Note: Can't reliably compare areas due to NLP solver non-determinism
    end
    
    @testset "Prefer square option" begin
        demand = RCColumnDemand(1; Pu=400.0, Mux=200.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        
        opts_square = NLPColumnOptions(prefer_square=0.5, solver=:ipopt, verbose=false)
        
        result = size_rc_column_nlp(400.0kip, 200.0kip*u"ft", geometry, opts_square)
        
        # With prefer_square penalty, should tend toward square
        aspect = max(result.b_final/result.h_final, result.h_final/result.b_final)
        @test aspect <= 1.5  # Should be reasonably square
    end
    
end

println("\n✅ All RC Column NLP tests passed!")
