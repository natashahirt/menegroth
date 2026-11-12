# ==============================================================================
# Test RC Column NLP Optimization
# ==============================================================================
# Tests for the continuous (interior point) column sizer.

using Test
using StructuralSizer
using Unitful
using Asap: kip, ksi

const N_MAX_BARS = StructuralSizer.RC_COLUMN_NLP_MAX_BARS
nlp_acceptable(status) = status in (:optimal, :feasible, :converged)

# Independent as-built check of a returned section: the real ACIColumnChecker
# with the flags the NLP enforces, built here rather than through the api.jl
# helper so a misconfigured helper cannot hide a failure. Demands in kip / kip-ft.
function passes_aci_as_built(section, Pu, Mux, Muy, geometry, opts)
    demand = RCColumnDemand(1; Pu=Pu, Mux=Mux, Muy=Muy, βdns=opts.βdns)
    checker = ACIColumnChecker(;
        include_slenderness = opts.include_slenderness,
        include_biaxial = true,
        α_biaxial = 1.5,
        fy_ksi = fy_ksi(opts.rebar_material),
        Es_ksi = Es_ksi(opts.rebar_material),
        max_depth = opts.max_dim,
    )
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], opts.material, MinVolume())
    feasible = is_feasible(checker, cache, 1, section, opts.material, demand, geometry)
    b = ustrip(u"inch", section.b)
    h = ustrip(u"inch", section.h)
    lo = ustrip(u"inch", opts.min_dim) - 1e-6
    hi = ustrip(u"inch", opts.max_dim) + 1e-6
    return feasible &&
           0.01 <= section.ρg <= 0.08 &&            # ACI 318-19 §10.6.1.1
           StructuralSizer._rc_column_rho_within_cap(section.ρg, opts.ρ_max) &&
           length(section.bars) <= N_MAX_BARS &&
           lo <= b <= hi && lo <= h <= hi
end

# Reported b_final / h_final / area must describe the returned section.
function reports_returned_section(r)
    return isapprox(r.b_final, ustrip(u"inch", r.section.b); atol=1e-9) &&
           isapprox(r.h_final, ustrip(u"inch", r.section.h); atol=1e-9) &&
           isapprox(r.area, r.b_final * r.h_final; rtol=1e-12)
end

# Every acceptable result must pass the real checker as built.
function check_acceptable_as_built(r, Pu, Mux, Muy, geometry, opts)
    nlp_acceptable(r.status) || return true
    return reports_returned_section(r) &&
           passes_aci_as_built(r.section, Pu, Mux, Muy, geometry, opts)
end

@testset "RC Column NLP Optimization" begin
    
    @testset "Crushed section reports the axial cap, not a flat 100" begin
        # ACI 318-11 §10.3.6 Eq. (10-2), φ = 0.65. corpus: aci-318-11, p. 143 and p. 127.
        # 10×10 in at ρg = 0.02 cannot carry 1000 kip. 12×36 in at the same
        # ratio is under the cap, and the utilization falls as Ag grows.
        small = StructuralSizer._smooth_axial_cap_util(100.0, 0.02, 1000.0, 4.0, 60.0)
        larger = StructuralSizer._smooth_axial_cap_util(12.0 * 36.0, 0.02, 1000.0, 4.0, 60.0)
        @test small > 1.0
        @test larger < small
        # No moment: the row is the axial cap, and it is not the old flat 100.
        @test StructuralSizer._smooth_pm_or_axial_util(0.0, 0.0, small) ≈ small
        @test StructuralSizer._smooth_pm_or_axial_util(0.0, 0.0, small) < 50.0
        # A real moment on a collapsed φMn stays a moment failure. Dropping
        # it down to the axial ratio made that section look almost feasible.
        crushed = StructuralSizer._smooth_pm_or_axial_util(0.0, 500.0, small)
        healthy = StructuralSizer._smooth_pm_or_axial_util(500.0, 500.0, small)
        @test crushed > small
        @test crushed > healthy
    end

    @testset "NLPColumnOptions construction" begin
        # Default options
        opts = NLPColumnOptions()
        @test opts.material == NWC_4000
        @test opts.solver == :ipopt
        @test opts.min_dim == 8.0u"inch"
        @test opts.max_dim == 48.0u"inch"
        
        # Custom options
        opts2 = NLPColumnOptions(
            material = NWC_5000,
            min_dim = 14.0u"inch",
            max_dim = 30.0u"inch",
            prefer_square = 0.1,
            verbose = false
        )
        @test opts2.material == NWC_5000
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
        @test x0[3] == 0.04  # midrange ρ start is unchanged
        # Pu is kip and f'c is ksi in this guess. Mux is kip-ft, so the
        # moment term converts ×12 to kip-in before dividing.
        @test problem.Pu_kip ≈ 500.0
        @test problem.mat.fc ≈ 4.0
        @test problem.Mux_kipft ≈ 200.0
        Ag_axial = problem.Pu_kip / (0.40 * problem.mat.fc)
        h_est = sqrt(max(Ag_axial, problem.b_min^2))
        Mu_kipin = 12.0 * problem.Mux_kipft
        Ag = Ag_axial + 6.0 * Mu_kipin / (problem.mat.fc * h_est)
        c_expect = clamp(sqrt(max(Ag, problem.b_min^2)), problem.b_min, problem.b_max)
        @test x0[1] ≈ c_expect
        @test x0[2] ≈ c_expect
        
        # Test constraint interface: P-M + placeable steel (no biaxial since Muy=0)
        @test n_constraints(problem) == 2
        @test constraint_names(problem) == ["P-M utilization", "placeable steel"]

        c_lb, c_ub = constraint_bounds(problem)
        @test c_ub == [1.0, 1.0]  # utilization ≤ 1.0, required/placeable steel ≤ 1.0
        @test all(isinf, c_lb)

        # Muy > 0 adds the biaxial row; placeable steel stays last.
        problem_biax = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=500.0, Mux=200.0, Muy=100.0, βdns=0.6), geometry, opts)
        @test n_constraints(problem_biax) == 3
        @test constraint_names(problem_biax) ==
              ["P-Mx utilization", "biaxial utilization", "placeable steel"]
        @test constraint_bounds(problem_biax)[2] == [1.0, 1.0, 1.0]
    end
    
    @testset "Objective and constraint evaluation" begin
        demand = RCColumnDemand(1; Pu=300.0, Mux=100.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(3.5; k=1.0, braced=true)
        opts = NLPColumnOptions(verbose=false, objective=MinVolume())
        
        problem = RCColumnNLPProblem(demand, geometry, opts)
        
        # Test objective at a point — MinVolume uses Ag*(1 + 2ρ) to penalize high ρ
        x = [18.0, 18.0, 0.02]  # 18" square, 2% steel
        obj = objective_fn(problem, x)
        @test obj ≈ 18.0 * 18.0 * (1 + 2 * 0.02)  # Ag*(1+2ρ) = 336.96
        
        # Test constraint at same point
        g = constraint_fns(problem, x)
        @test length(g) == 2
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
        @test check_acceptable_as_built(result, 300.0, 100.0, 0.0, geometry, opts)
    end
    
    @testset "NLP solve with Ipopt" begin
        # Test with Ipopt (the main use case)
        demand = RCColumnDemand(1; Pu=500.0, Mux=200.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(
            material = NWC_4000,
            solver = :ipopt,
            min_dim = 14.0u"inch",
            max_dim = 36.0u"inch",
            verbose = false
        )
        
        result = size_rc_column_nlp(500.0kip, 200.0kip*u"ft", geometry, opts)
        
        @test result isa RCColumnNLPResult
        @test result.section isa RCColumnSection
        # :converged is an iteration-limit or slow-progress stop. It is
        # acceptable only because the as-built check below still has to pass.
        @test result.status in [:optimal, :feasible, :converged]
        
        # The optimal section should be within bounds
        @test 14.0 <= result.b_final <= 36.0
        @test 14.0 <= result.h_final <= 36.0
        
        # Verify the final section passes capacity check
        mat = (fc = fc_ksi(opts.material), fy = 60.0, Es = 29000.0, εcu = 0.003)
        diagram = generate_PM_diagram(result.section, mat)
        check = check_PM_capacity(diagram, 500.0, 200.0)
        @test check.adequate || check.utilization < 1.1  # Allow small tolerance
        # Full checker (slenderness on, as the NLP uses) with no tolerance.
        @test check_acceptable_as_built(result, 500.0, 200.0, 0.0, geometry, opts)
        
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

        for (i, r) in enumerate(results)
            @test check_acceptable_as_built(
                r, ustrip(kip, Pu[i]), ustrip(kip * u"ft", Mux[i]), 0.0, geoms[i], opts)
        end
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
        @test check_acceptable_as_built(result_with, 400.0, 100.0, 0.0, geometry, opts_with)
        @test check_acceptable_as_built(result_without, 400.0, 100.0, 0.0, geometry, opts_without)
    end
    
    @testset "Initial guess moment term is only a start" begin
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(min_dim=8.0u"inch", max_dim=48.0u"inch")

        # Zero moment: axial-only side, same 0.40 start as before.
        p_ax = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=500.0, Mux=0.0, Muy=0.0), geometry, opts)
        x_ax = initial_guess(p_ax)
        c_ax = sqrt(max(p_ax.Pu_kip / (0.40 * p_ax.mat.fc), p_ax.b_min^2))
        @test x_ax ≈ [c_ax, c_ax, 0.04]

        # |Muy| governs over a smaller |Mux|. Sign is dropped. kip-ft × 12.
        p_m = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=500.0, Mux=-50.0, Muy=200.0), geometry, opts)
        @test p_m.Mux_kipft ≈ -50.0
        @test p_m.Muy_kipft ≈ 200.0
        h_est = c_ax
        Mu_kipin = 12.0 * 200.0
        Ag = p_m.Pu_kip / (0.40 * p_m.mat.fc) + 6.0 * Mu_kipin / (p_m.mat.fc * h_est)
        c_m = clamp(sqrt(Ag), p_m.b_min, p_m.b_max)
        x_m = initial_guess(p_m)
        @test x_m ≈ [c_m, c_m, 0.04]
        @test c_m > c_ax

        # Same |Mu| on the other axis, negative, matches.
        p_x = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=500.0, Mux=-200.0, Muy=50.0), geometry, opts)
        @test initial_guess(p_x) ≈ x_m

        # Side is clamped to the existing bounds. ρg stays 0.04.
        p_hi = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=4000.0, Mux=8000.0, Muy=0.0),
            geometry,
            NLPColumnOptions(min_dim=10.0u"inch", max_dim=16.0u"inch"))
        x_hi = initial_guess(p_hi)
        @test x_hi[1] == p_hi.b_max
        @test x_hi[2] == p_hi.b_max
        @test x_hi[3] == 0.04

        # Zero load and zero moment: lower bound, not a divide-by-zero.
        p_0 = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=0.0, Mux=0.0, Muy=0.0), geometry, opts)
        x_0 = initial_guess(p_0)
        @test x_0[1] ≈ p_0.b_min
        @test x_0[2] ≈ p_0.b_min
        @test x_0[3] == 0.04

        # The axial-only start stays available. Zero moment matches it.
        # Zero load is the lower bound, not a divide-by-zero.
        @test StructuralSizer.axial_only_initial_guess(p_ax) ≈ x_ax
        @test StructuralSizer.axial_only_initial_guess(p_0) ≈ x_0
        x_ax_m = StructuralSizer.axial_only_initial_guess(p_m)
        @test x_ax_m ≈ [c_ax, c_ax, 0.04]
        @test x_ax_m[1] < x_m[1]
        @test !StructuralSizer._rc_column_starts_match(p_m, x_m, x_ax_m)
        @test StructuralSizer._rc_column_starts_match(p_ax, x_ax, x_ax_m)
        # A short vector is not the axial start, so an explicit x0 is still tried.
        @test !StructuralSizer._rc_column_starts_match(p_ax, Float64[8.0, 8.0], x_ax)
    end

    @testset "Two starts: infeasible or larger moment seed does not win" begin
        # Selector only. Sections are placeholders; the decision reads status,
        # final area, and objective_fn(b_final, h_final, section ρg).
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        demand = RCColumnDemand(1; Pu=500.0, Mux=50.0, Muy=200.0)
        placeholder = StructuralSizer._build_nlp_trial_section(
            16.0, 16.0, 0.02, NLPColumnOptions())
        @test !isnothing(placeholder)

        function snapped(section, b, h, ρ, area, status)
            return RCColumnNLPResult(section, b, h, ρ, b, h, area, status, 1)
        end

        # MinVolume ranks by final area, even when a larger section has a
        # lower Ag*(1+2ρ) because its reinforcement ratio is smaller.
        # 10×10 at ρ=0.06 → 112; 12×9 at ρ=0.01 → 110.16.
        opts_v = NLPColumnOptions(objective=MinVolume())
        problem_v = RCColumnNLPProblem(demand, geometry, opts_v)
        small = snapped(placeholder, 10.0, 10.0, 0.06, 100.0, :optimal)
        large = snapped(placeholder, 12.0, 9.0, 0.01, 108.0, :optimal)
        @test objective_fn(problem_v, [12.0, 9.0, 0.01]) <
              objective_fn(problem_v, [10.0, 10.0, 0.06])
        @test StructuralSizer._rc_column_nlp_candidate_wins(problem_v, large, small)
        @test !StructuralSizer._rc_column_nlp_candidate_wins(problem_v, small, large)

        infeas = snapped(placeholder, 14.0, 14.0, 0.04, 196.0, :infeasible)
        failed = snapped(placeholder, 10.0, 18.0, 0.04, 180.0, :failed)
        converged = snapped(placeholder, 12.0, 36.0, 0.04, 432.0, :converged)
        @test !StructuralSizer._rc_column_nlp_candidate_wins(problem_v, small, infeas)
        @test !StructuralSizer._rc_column_nlp_candidate_wins(problem_v, small, failed)
        @test !StructuralSizer._rc_column_nlp_candidate_wins(problem_v, converged, infeas)
        # A failed or infeasible axial result yields to an acceptable section.
        @test StructuralSizer._rc_column_nlp_candidate_wins(problem_v, infeas, small)
        @test StructuralSizer._rc_column_nlp_candidate_wins(problem_v, failed, converged)
        # A :converged stop on a real 12×36 section goes through the as-built
        # check. If that section passes it comes back unchanged; otherwise it is
        # repaired or marked :infeasible. An acceptable outcome passes the real
        # checker and can still replace a failed start.
        sec_12x36 = StructuralSizer._build_nlp_trial_section(12.0, 36.0, 0.04, opts_v)
        conv_real = RCColumnNLPResult(sec_12x36, 12.0, 36.0, 0.04, 12.0, 36.0, 432.0, :converged, 1)
        kept = StructuralSizer._rc_column_nlp_verify_as_built(problem_v, conv_real)
        if passes_aci_as_built(sec_12x36, 500.0, 50.0, 200.0, geometry, opts_v)
            @test kept === conv_real
        end
        @test check_acceptable_as_built(kept, 500.0, 50.0, 200.0, geometry, opts_v)
        if nlp_acceptable(kept.status)
            @test StructuralSizer._rc_column_nlp_candidate_wins(problem_v, failed, kept)
        end

        # prefer_square may accept a larger area when that penalty is lower.
        opts_sq = NLPColumnOptions(prefer_square=0.5)
        problem_sq = RCColumnNLPProblem(demand, geometry, opts_sq)
        skinny = snapped(placeholder, 8.0, 24.0, 0.02, 192.0, :optimal)
        square = snapped(placeholder, 16.0, 16.0, 0.02, 256.0, :optimal)
        c_skinny = objective_fn(problem_sq, [8.0, 24.0, 0.02])
        c_square = objective_fn(problem_sq, [16.0, 16.0, 0.02])
        @test c_square < c_skinny
        @test StructuralSizer._rc_column_nlp_candidate_wins(problem_sq, skinny, square)
        @test !StructuralSizer._rc_column_nlp_candidate_wins(problem_sq, square, skinny)
    end

    @testset "Moment seed cannot replace a better axial-only section" begin
        # Ipopt is local. The moment start alone has returned an infeasible
        # 14×14 for 500 kip / 50 kip-ft / 200 kip-ft, and a larger 8×22 for
        # 300 kip / 100 kip-ft, while the axial-only start stayed feasible
        # and smaller (probe: 192 in² and 144 in²). The combined result must
        # stay acceptable whenever the axial-only start is, and its area
        # must not grow.
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(verbose=false)
        acceptable(status) = status in (:optimal, :feasible, :converged)

        function axial_only_result(Pu, Mux, Muy)
            demand = RCColumnDemand(1; Pu=Pu, Mux=Mux, Muy=Muy, βdns=opts.βdns)
            problem = RCColumnNLPProblem(demand, geometry, opts)
            x_ax = StructuralSizer.axial_only_initial_guess(problem)
            # Same as-built ACI check (and repair) as the combined solve.
            return StructuralSizer._solve_rc_column_nlp_from(problem, opts, x_ax)
        end

        cases = [
            ("Pu=500 Mux=200 Muy=0", 500.0, 200.0, 0.0),
            ("Pu=500 Mux=50 Muy=200", 500.0, 50.0, 200.0),
            ("Pu=300 Mux=100 Muy=0", 300.0, 100.0, 0.0),
            ("Pu=1000 Mux=500 Muy=0", 1000.0, 500.0, 0.0),
            ("Pu=500 Mux=0 Muy=-500", 500.0, 0.0, -500.0),
        ]

        saved = Dict{String, NamedTuple}()
        for (label, Pu, Mux, Muy) in cases
            combined = size_rc_column_nlp(
                Pu * kip, Mux * kip * u"ft", geometry, opts;
                Muy = Muy * kip * u"ft")
            axial = axial_only_result(Pu, Mux, Muy)
            println("RC_NLP_COMPARE $label combined=$(combined.status) " *
                    "$(combined.b_final)x$(combined.h_final) area=$(combined.area) " *
                    "axial=$(axial.status) $(axial.b_final)x$(axial.h_final) area=$(axial.area)")
            if acceptable(axial.status)
                @test acceptable(combined.status)
                @test combined.area <= axial.area + 1e-6
            end
            @test combined.area > 0
            @test combined.section isa RCColumnSection
            saved[label] = (combined=combined, axial=axial)

            # Whatever the solver status, an acceptable section from either
            # start passes the real ACI checker as built.
            @test check_acceptable_as_built(combined, Pu, Mux, Muy, geometry, opts)
            @test check_acceptable_as_built(axial, Pu, Mux, Muy, geometry, opts)
        end

        # 1000 kip / 500 kip-ft used to come back :infeasible. The smooth
        # P-M row went flat at 100 once the trial section was axially
        # crushed, so Ipopt had no gradient toward a section that passes.
        heavy = saved["Pu=1000 Mux=500 Muy=0"]
        @test acceptable(heavy.combined.status)
        @test passes_aci_as_built(heavy.combined.section, 1000.0, 500.0, 0.0, geometry, opts)

        # 500 kip / 50 kip-ft / 200 kip-ft: moment start alone was infeasible.
        biax = saved["Pu=500 Mux=50 Muy=200"]
        @test acceptable(biax.combined.status)
        @test biax.combined.area <= biax.axial.area + 1e-6

        # 300 kip / 100 kip-ft: both starts were feasible; axial was the
        # smaller section (144 in² on the probe). Do not accept a larger one.
        uni = saved["Pu=300 Mux=100 Muy=0"]
        @test acceptable(uni.combined.status)
        @test uni.combined.area <= uni.axial.area + 1e-6

        # An explicit axial start is that start alone. A worse explicit start
        # is still solved, and does not replace the axial section.
        demand_b = RCColumnDemand(1; Pu=500.0, Mux=50.0, Muy=200.0, βdns=opts.βdns)
        problem_b = RCColumnNLPProblem(demand_b, geometry, opts)
        x_ax = StructuralSizer.axial_only_initial_guess(problem_b)
        from_axial_kw = size_rc_column_nlp(
            500.0kip, 50.0kip * u"ft", geometry, opts;
            Muy=200.0kip * u"ft", x0=x_ax)
        @test acceptable(from_axial_kw.status)
        @test from_axial_kw.area ≈ biax.axial.area
        @test from_axial_kw.b_final ≈ biax.axial.b_final
        @test from_axial_kw.h_final ≈ biax.axial.h_final

        from_corner = size_rc_column_nlp(
            500.0kip, 50.0kip * u"ft", geometry, opts;
            Muy=200.0kip * u"ft", x0=[48.0, 48.0, 0.06])
        @test acceptable(from_corner.status)
        @test from_corner.area <= biax.axial.area + 1e-6
        @test check_acceptable_as_built(from_axial_kw, 500.0, 50.0, 200.0, geometry, opts)
        @test check_acceptable_as_built(from_corner, 500.0, 50.0, 200.0, geometry, opts)
    end

    @testset "Iteration-limit stop: returned section is checked as built" begin
        # maxiter=1 is an ITERATION_LIMIT stop. Ipopt maps that to :converged
        # even when the snapped section is past the constraint bound (the
        # axial basin was reported at a biaxial utilization of about 1.05).
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(maxiter=1, snap=false, verbose=false)
        result = size_rc_column_nlp(
            500.0kip, 50.0kip * u"ft", geometry, opts;
            Muy=200.0kip * u"ft")
        println("RC_NLP_MAXITER1 status=$(result.status) " *
                "$(result.b_final)x$(result.h_final) ρ=$(result.ρ_opt) " *
                "n_bars=$(length(result.section.bars))")
        @test check_acceptable_as_built(result, 500.0, 50.0, 200.0, geometry, opts)

        demand = RCColumnDemand(1; Pu=500.0, Mux=50.0, Muy=200.0, βdns=opts.βdns)
        problem = RCColumnNLPProblem(demand, geometry, opts)
        x_ax = StructuralSizer.axial_only_initial_guess(problem)
        axial = StructuralSizer._solve_rc_column_nlp_from(problem, opts, x_ax)
        @test check_acceptable_as_built(axial, 500.0, 50.0, 200.0, geometry, opts)

        # The raw (unverified) build of that stop. Whatever status the solver
        # had claimed, verification must never hand back a failing section
        # as acceptable.
        raw = build_rc_column_nlp_result(problem, StructuralSizer.optimize_continuous(
            problem; objective=opts.objective, solver=opts.solver, maxiter=opts.maxiter,
            tol=opts.tol, verbose=false, x0=x_ax, n_multistart=opts.n_multistart))
        raw_ok = passes_aci_as_built(raw.section, 500.0, 50.0, 200.0, geometry, opts)
        println("RC_NLP_MAXITER1_RAW status=$(raw.status) " *
                "$(raw.b_final)x$(raw.h_final) passes_as_built=$(raw_ok)")
        for status in (:optimal, :feasible, :converged)
            v = StructuralSizer._rc_column_nlp_verify_as_built(
                problem, StructuralSizer._rc_column_nlp_with_status(raw, status))
            @test check_acceptable_as_built(v, 500.0, 50.0, 200.0, geometry, opts)
            # An acceptable result keeps the solver status.
            @test v.status in (status, :infeasible)
            raw_ok && @test v.section === raw.section
        end
        # :infeasible / :failed are not verified or repaired.
        for status in (:infeasible, :failed)
            r = StructuralSizer._rc_column_nlp_with_status(raw, status)
            @test StructuralSizer._rc_column_nlp_verify_as_built(problem, r) === r
        end

        # Smaller area must not let an :infeasible section replace an acceptable one.
        small_bad = StructuralSizer._rc_column_nlp_with_status(raw, :infeasible)
        large = RCColumnNLPResult(
            raw.section, 24.0, 24.0, raw.ρ_opt, 24.0, 24.0, 576.0, :optimal, 1)
        @test small_bad.area + 1e-6 < large.area
        @test !StructuralSizer._rc_column_nlp_candidate_wins(problem, large, small_bad)
    end

    @testset "Placeable-steel constraint and bar cap" begin
        # The constraint is ρ·b·h / (n_fit·A_bar). n_fit is the bars that
        # fit the faces, capped at N_MAX, not N_MAX itself.
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        @test N_MAX_BARS == 32
        for (bar_size, Muy) in ((8, 0.0), (6, 0.0), (10, 150.0))
            opts = NLPColumnOptions(bar_size=bar_size)
            problem = RCColumnNLPProblem(
                RCColumnDemand(1; Pu=500.0, Mux=200.0, Muy=Muy, βdns=0.6), geometry, opts)
            A_bar = ustrip(u"inch^2", StructuralSizer.rebar(bar_size).A)
            for x in ([20.0, 20.0, 0.08], [14.0, 22.0, 0.025], [30.0, 30.0, 0.01])
                g = constraint_fns(problem, x)
                n_fit = StructuralSizer._rc_column_nlp_fit_bars(x[1], x[2], opts)
                @test length(g) == n_constraints(problem)
                @test g[end] ≈ x[3] * x[1] * x[2] / (n_fit * A_bar) rtol=1e-12
            end
        end
        # #8 at 20×20: ρ·Ag over the steel the faces can hold is 1 at that area.
        p8 = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=600.0, Mux=500.0, βdns=0.6), geometry,
            NLPColumnOptions(bar_size=8, max_dim=20.0u"inch", ρ_max=0.08))
        opts8 = NLPColumnOptions(bar_size=8, max_dim=20.0u"inch", ρ_max=0.08)
        n_fit = StructuralSizer._rc_column_nlp_fit_bars(20.0, 20.0, opts8)
        A_bar = ustrip(u"inch^2", StructuralSizer.rebar(8).A)
        @test constraint_fns(p8, [20.0, 20.0, 0.08])[end] ≈
              (0.08 * 400.0) / (n_fit * A_bar) rtol=1e-12
        ρ_full = n_fit * A_bar / 400.0
        @test constraint_fns(p8, [20.0, 20.0, ρ_full])[end] ≈ 1.0 rtol=1e-12

        # The builder never exceeds the bars that fit, and that count is at most N_MAX.
        # A section too small for the tie-type minimum returns nothing.
        for bar_size in (6, 8, 10), tie in (:tied, :spiral)
            opts = NLPColumnOptions(bar_size=bar_size, tie_type=tie)
            for b in (10.0, 20.0, 36.0, 48.0), h in (10.0, 24.0, 48.0),
                    ρ in (0.01, 0.04, 0.08, 0.2)
                sec = StructuralSizer._build_nlp_trial_section(b, h, ρ, opts)
                n = StructuralSizer._nlp_trial_bar_count(b, h, ρ, opts)
                if n < StructuralSizer._nlp_min_bars(opts)
                    @test isnothing(sec)
                else
                    @test !isnothing(sec)
                    @test length(sec.bars) == n
                    @test length(sec.bars) <= N_MAX_BARS
                end
            end
            @test isnothing(StructuralSizer._build_nlp_column_section(
                20.0, 20.0, N_MAX_BARS + 2, opts))
        end
        # 20×20 #8 at ρ = 0.08 wants more bars than the faces can hold.
        # The built count is that fit, and ρg is the steel actually placed.
        sec_cap = StructuralSizer._build_nlp_trial_section(
            20.0, 20.0, 0.08, NLPColumnOptions(bar_size=8))
        n_cap = StructuralSizer._nlp_trial_bar_count(
            20.0, 20.0, 0.08, NLPColumnOptions(bar_size=8))
        wanted = ceil(Int, 0.08 * 400.0 / A_bar)
        wanted = iseven(wanted) ? wanted : wanted + 1
        @test n_cap < wanted
        @test n_cap <= N_MAX_BARS
        @test length(sec_cap.bars) == n_cap
        @test sec_cap.ρg ≈ n_cap * A_bar / 400.0 rtol=1e-12
    end

    @testset "Regression: 20×20 #8 high-ρ case is checked as built" begin
        # Bounds force Ipopt toward ρ ≈ 0.08 at 20×20. The faces hold 24 #8
        # (ρg ≈ 0.0474), less steel than that ratio. Any acceptable result
        # must pass the real checker as built.
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(max_dim=20.0u"inch", ρ_max=0.08, bar_size=8)
        result = size_rc_column_nlp(600.0kip, 500.0kip * u"ft", geometry, opts)
        println("RC_NLP_20x20 status=$(result.status) $(result.b_final)x$(result.h_final) " *
                "n_bars=$(length(result.section.bars)) ρg=$(result.section.ρg)")
        @test check_acceptable_as_built(result, 600.0, 500.0, 0.0, geometry, opts)
        @test nlp_acceptable(result.status) || result.status in (:infeasible, :failed)

        # Same case as a hand-built :optimal result at the solver's ρ = 0.08.
        problem = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=600.0, Mux=500.0, βdns=opts.βdns), geometry, opts)
        sec = StructuralSizer._build_nlp_trial_section(20.0, 20.0, 0.08, opts)
        claimed = RCColumnNLPResult(sec, 20.0, 20.0, 0.08, 20.0, 20.0, 400.0, :optimal, 1)
        v = StructuralSizer._rc_column_nlp_verify_as_built(problem, claimed)
        @test check_acceptable_as_built(v, 600.0, 500.0, 0.0, geometry, opts)
        # Cannot grow past max_dim = 20 or past 32 bars.
        @test v.b_final <= 20.0 && v.h_final <= 20.0
        @test length(v.section.bars) <= N_MAX_BARS
    end

    @testset "As-built repair: bars first, then dimensions, then infeasible" begin
        # 20×20, #8, Pu=400 kip, Mux=375 kip-ft, 4 m braced. Probe with the real
        # checker: 6, 8, 10, 12 bars fail; 14 bars pass.
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(bar_size=8, ρ_max=0.06)
        problem = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=400.0, Mux=375.0, βdns=opts.βdns), geometry, opts)
        sec6 = StructuralSizer._build_nlp_trial_section(20.0, 20.0, 0.01, opts)
        @test length(sec6.bars) == 6
        @test !passes_aci_as_built(sec6, 400.0, 375.0, 0.0, geometry, opts)
        start = RCColumnNLPResult(sec6, 20.0, 20.0, 0.01, 20.0, 20.0, 400.0, :optimal, 7)

        # Bars only: the smallest passing count at the same dimensions.
        fixed = StructuralSizer._rc_column_nlp_verify_as_built(problem, start)
        @test fixed.status === :optimal
        @test fixed.iterations == 7
        @test (fixed.b_final, fixed.h_final, fixed.area) == (20.0, 20.0, 400.0)
        @test length(fixed.section.bars) == 14
        @test fixed.ρ_opt ≈ fixed.section.ρg
        A8 = ustrip(u"inch^2", StructuralSizer.rebar(8).A)
        @test fixed.ρ_opt ≈ 14 * A8 / 400 rtol=1e-12
        @test (fixed.b_opt, fixed.h_opt) == (20.0, 20.0)
        @test check_acceptable_as_built(fixed, 400.0, 375.0, 0.0, geometry, opts)
        for n in 6:2:12
            s = StructuralSizer._build_nlp_column_section(20.0, 20.0, n, opts)
            @test !passes_aci_as_built(s, 400.0, 375.0, 0.0, geometry, opts)
        end

        # ρ_max = 0.02 allows at most 10 #8 at 20×20 (10·0.79/400 = 0.01975),
        # so bars alone cannot fix it and the section must grow.
        opts_lo = NLPColumnOptions(bar_size=8, ρ_max=0.02)
        problem_lo = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=400.0, Mux=375.0, βdns=opts_lo.βdns), geometry, opts_lo)
        start_lo = RCColumnNLPResult(sec6, 20.0, 20.0, 0.01, 20.0, 20.0, 400.0, :feasible, 3)
        grown = StructuralSizer._rc_column_nlp_verify_as_built(problem_lo, start_lo)
        println("RC_NLP_REPAIR_GROW status=$(grown.status) $(grown.b_final)x$(grown.h_final) " *
                "n_bars=$(length(grown.section.bars)) ρg=$(grown.section.ρg)")
        @test grown.status === :feasible
        @test grown.b_final > 20.0 && grown.h_final > 20.0
        @test grown.b_final == grown.h_final                   # both grow together
        @test rem(grown.b_final - 20.0, 2.0) ≈ 0.0 atol=1e-9  # on the 2 in grid
        @test check_acceptable_as_built(grown, 400.0, 375.0, 0.0, geometry, opts_lo)

        # Nothing within max_dim = 12 and 32 bars carries 3000 kip: the loop
        # stops at the bounds and the start is marked :infeasible.
        opts_tiny = NLPColumnOptions(bar_size=8, max_dim=12.0u"inch", ρ_max=0.08)
        problem_tiny = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=3000.0, Mux=100.0, βdns=opts_tiny.βdns), geometry, opts_tiny)
        sec_t = StructuralSizer._build_nlp_trial_section(10.0, 10.0, 0.04, opts_tiny)
        start_t = RCColumnNLPResult(sec_t, 10.0, 10.0, 0.04, 10.0, 10.0, 100.0, :optimal, 1)
        dead = StructuralSizer._rc_column_nlp_verify_as_built(problem_tiny, start_t)
        @test dead.status === :infeasible
        @test !StructuralSizer._rc_column_nlp_acceptable(dead.status)
        @test dead.section === sec_t

        # A section past max_dim is never accepted as built.
        sec_wide = StructuralSizer._build_nlp_trial_section(14.0, 14.0, 0.04, opts_tiny)
        @test !StructuralSizer._rc_column_as_built_ok(
            problem_tiny, StructuralSizer._rc_column_nlp_checker(opts_tiny), sec_wide)
    end

    @testset "Snap holds dimensions to max_dim" begin
        # Ipopt can return b slightly above an on-grid max_dim. Rounding up a
        # full increment would build a section outside the bounds.
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(max_dim=20.0u"inch", dim_increment=2.0u"inch")
        problem = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=300.0, Mux=100.0, βdns=opts.βdns), geometry, opts)
        fake = (minimizer=[20.0 + 1e-7, 17.3, 0.02], status=:optimal, iterations=1)
        r = build_rc_column_nlp_result(problem, fake)
        @test r.b_final == 20.0
        @test r.h_final == 18.0
        # Off-grid max_dim (25 in, 2 in grid): 24.5 → 25, not 26.
        opts25 = NLPColumnOptions(max_dim=25.0u"inch", dim_increment=2.0u"inch")
        problem25 = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=300.0, Mux=100.0, βdns=opts25.βdns), geometry, opts25)
        r25 = build_rc_column_nlp_result(
            problem25, (minimizer=[24.5, 24.5, 0.02], status=:optimal, iterations=1))
        @test r25.b_final == 25.0
        @test r25.h_final == 25.0
    end

    @testset "Prefer square option" begin
        demand = RCColumnDemand(1; Pu=400.0, Mux=200.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        
        opts_square = NLPColumnOptions(prefer_square=0.5, solver=:ipopt, verbose=false)
        
        result = size_rc_column_nlp(400.0kip, 200.0kip*u"ft", geometry, opts_square)
        
        # With prefer_square penalty, should tend toward square
        aspect = max(result.b_final/result.h_final, result.h_final/result.b_final)
        @test aspect <= 1.5  # Should be reasonably square
        @test check_acceptable_as_built(result, 400.0, 200.0, 0.0, geometry, opts_square)
    end

    @testset "Caller demand is the as-built demand" begin
        # The envelope constructor drops M1 and transverse_load. The NLP path
        # must keep the object the caller passed.
        opts = NLPColumnOptions(βdns=0.6, include_slenderness=true)
        caller = RCColumnDemand(4;
            Pu=400.0, Mux=150.0, Muy=20.0,
            M1x=-30.0, M2x=150.0, M1y=-5.0, M2y=20.0,
            βdns=0.45, transverse_load=true)
        used = StructuralSizer._rc_column_nlp_use_demand(
            1.0, 2.0, 3.0, opts, caller)
        @test used === caller
        @test used.transverse_load
        @test used.M1x == -30.0
        @test used.M2x == 150.0
        @test used.M1y == -5.0
        @test used.M2y == 20.0
        @test used.βdns == 0.45
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        problem = RCColumnNLPProblem(used, geometry, opts)
        @test problem.demand === caller
        @test problem.demand.transverse_load
        # Nothing builds the conservative stand-in (M1 = 0, Cm path without
        # the transverse-load case).
        bare = StructuralSizer._rc_column_nlp_use_demand(400.0, 150.0, 0.0, opts, nothing)
        @test bare.transverse_load == false
        @test bare.M1x == 0
        @test bare.M2x == 150.0
        @test bare.βdns == opts.βdns
        # Empty-ish edge: zero envelope still constructs a demand.
        zero = StructuralSizer._rc_column_nlp_use_demand(0.0, 0.0, 0.0, opts, nothing)
        @test zero.Pu == 0
        @test zero.transverse_load == false
    end

    @testset "Repair returns when the dimension step does not advance" begin
        # dim_increment = 1e-20 in makes Float64 `b + incr == b`, so
        # `b < b_cap` would otherwise stay true forever.
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(
            bar_size=8, dim_increment=1e-20u"inch", max_dim=48.0u"inch", ρ_max=0.08)
        problem = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=3000.0, Mux=100.0, βdns=opts.βdns), geometry, opts)
        sec = StructuralSizer._build_nlp_trial_section(12.0, 12.0, 0.04, opts)
        start = RCColumnNLPResult(sec, 12.0, 12.0, 0.04, 12.0, 12.0, 144.0, :optimal, 1)
        checker = StructuralSizer._rc_column_nlp_checker(opts)
        repaired = StructuralSizer._rc_column_nlp_repair(problem, checker, start)
        @test isnothing(repaired)
        dead = StructuralSizer._rc_column_nlp_verify_as_built(problem, start)
        @test dead.status === :infeasible
        # Already at the cap: the step is refused even with a normal increment.
        opts_cap = NLPColumnOptions(bar_size=8, dim_increment=2.0u"inch", max_dim=12.0u"inch")
        problem_cap = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=3000.0, Mux=100.0, βdns=opts_cap.βdns), geometry, opts_cap)
        at_cap = RCColumnNLPResult(sec, 12.0, 12.0, 0.04, 12.0, 12.0, 144.0, :optimal, 1)
        @test isnothing(StructuralSizer._rc_column_nlp_repair(
            problem_cap, StructuralSizer._rc_column_nlp_checker(opts_cap), at_cap))
    end

    @testset "Repair lowers a ρ_max start instead of skipping the size" begin
        # Ipopt stops at ρ_opt = ρ_max = 0.06 on 8 × 13.1 in. Snapped to
        # 8 × 14 in, the continuous ratio asks for 10 #8, and the faces hold
        # fewer. Repair must still return a section whose placed steel is
        # within ρ_max.
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(
            material=NWC_4000, rebar_material=Rebar_60,
            min_dim=8.0u"inch", max_dim=30.0u"inch", include_slenderness=false)
        problem = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=180.0, Mux=74.0, βdns=opts.βdns), geometry, opts)
        sec = StructuralSizer._build_nlp_trial_section(8.0, 14.0, 0.06, opts)
        # 10 bars is the even round-up of ρ = 0.06, and 8×14 cannot hold them.
        # The builder places the largest even count that fits.
        @test length(sec.bars) ==
              StructuralSizer._nlp_trial_bar_count(8.0, 14.0, 0.06, opts)
        @test length(sec.bars) < 10
        start = RCColumnNLPResult(sec, 8.0, 13.1, 0.06, 8.0, 14.0, 112.0, :optimal, 1)
        checker = StructuralSizer._rc_column_nlp_checker(opts)
        repaired = StructuralSizer._rc_column_nlp_repair(problem, checker, start)
        @test !isnothing(repaired)
        @test StructuralSizer._rc_column_as_built_ok(problem, checker, repaired.section)
        @test repaired.section.ρg <= opts.ρ_max
        @test length(repaired.section.bars) < StructuralSizer.RC_COLUMN_NLP_MAX_BARS
        @test repaired.area <= 12.0 * 18.0
    end

    @testset "ρ_max rejects a minimum bar layout above the cap" begin
        # Tied 8×8, 4 #8: ρg ≈ 0.049. ACI 318-19 §10.6.1.1 allows it
        # (0.01 ≤ ρg ≤ 0.08), but opts.ρ_max = 0.01 does not. Do not raise
        # ρ_max to make the 4-bar minimum legal.
        geometry = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        opts = NLPColumnOptions(
            bar_size=8, tie_type=:tied, ρ_max=0.01,
            min_dim=8.0u"inch", max_dim=8.0u"inch")
        problem = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=50.0, Mux=5.0, βdns=opts.βdns), geometry, opts)
        sec = StructuralSizer._build_nlp_column_section(8.0, 8.0, 4, opts)
        @test !isnothing(sec)
        @test length(sec.bars) == 4
        @test sec.ρg > 0.04
        @test sec.ρg > opts.ρ_max
        @test 0.01 <= sec.ρg <= 0.08
        checker = StructuralSizer._rc_column_nlp_checker(opts)
        @test !StructuralSizer._rc_column_as_built_ok(problem, checker, sec)
        start = RCColumnNLPResult(sec, 8.0, 8.0, 0.01, 8.0, 8.0, 64.0, :optimal, 1)
        # Even the 4-bar minimum is over the cap, so repair must not accept
        # this size. max_dim blocks growth.
        @test isnothing(StructuralSizer._rc_column_nlp_repair(problem, checker, start))
        dead = StructuralSizer._rc_column_nlp_verify_as_built(problem, start)
        @test dead.status === :infeasible
        @test dead.section === sec
        # A section under the cap is not rejected by the ratio check alone.
        # 16×16 with 4 #8 is ρg = 3.16/256 ≈ 0.0123, still above 0.01.
        opts_ok = NLPColumnOptions(bar_size=8, tie_type=:tied, ρ_max=0.02, max_dim=16.0u"inch")
        sec_ok = StructuralSizer._build_nlp_column_section(16.0, 16.0, 4, opts_ok)
        @test sec_ok.ρg <= opts_ok.ρ_max
        @test sec_ok.ρg >= 0.01
        # 16×16 with 4 #8 is ρg ≈ 0.01234. A cap 5e-9 under that ratio used
        # to pass the old 1e-8 slack. One ulp over the cap is still allowed;
        # this gap is not.
        ρ_near = sec_ok.ρg
        opts_near = NLPColumnOptions(
            bar_size=8, tie_type=:tied, ρ_max=ρ_near - 5e-9,
            min_dim=16.0u"inch", max_dim=16.0u"inch")
        problem_near = RCColumnNLPProblem(
            RCColumnDemand(1; Pu=10.0, Mux=0.0, βdns=opts_near.βdns), geometry, opts_near)
        @test ρ_near > opts_near.ρ_max
        @test !StructuralSizer._rc_column_rho_within_cap(ρ_near, opts_near.ρ_max)
        @test StructuralSizer._rc_column_rho_within_cap(opts_near.ρ_max, opts_near.ρ_max)
        @test StructuralSizer._rc_column_rho_within_cap(nextfloat(Float64(opts_near.ρ_max)), opts_near.ρ_max)
        checker_near = StructuralSizer._rc_column_nlp_checker(opts_near)
        @test !StructuralSizer._rc_column_as_built_ok(problem_near, checker_near, sec_ok)
    end

    @testset "Flat plate does not report success for a rejected NLP column" begin
        # false from _update_column_sizes! means "size unchanged." A rejected
        # NLP result must not take that path. The iterative pipeline returns
        # this tuple from Phase A, Phase B, and _run_final_design.
        sec = StructuralSizer._build_nlp_column_section(12.0, 12.0, 8, NLPColumnOptions())
        rejected_result = (
            sections = [nothing],
            status = :infeasible,
        )
        failure = StructuralSizer._flat_plate_column_pm_failure(
            rejected_result, 8.0u"inch", 3, nothing)
        @test failure.converged == false
        @test failure.failure_reason == "column_pm_infeasible"
        @test failure.failing_check == "column_pm"
        @test failure.column_results === nothing
        @test failure.slab_result === nothing
        ok = (sections = [sec], status = :nlp_complete)
        @test isnothing(StructuralSizer._flat_plate_column_pm_failure(
            ok, 8.0u"inch", 1, nothing))
        # Discrete MIP statuses are not Symbols :infeasible / :nlp_complete.
        mip = (sections = [sec], status = "OPTIMAL")
        @test isnothing(StructuralSizer._flat_plate_column_pm_failure(
            mip, 8.0u"inch", 1, nothing))
    end

    @testset "NLP export omits a rejected section" begin
        opts_nlp = NLPColumnOptions()
        sec = StructuralSizer._build_nlp_column_section(12.0, 12.0, 8, opts_nlp)
        bad = RCColumnNLPResult(sec, 12.0, 12.0, sec.ρg, 12.0, 12.0, 144.0, :infeasible, 1)
        good = RCColumnNLPResult(sec, 12.0, 12.0, sec.ρg, 12.0, 12.0, 144.0, :optimal, 1)
        failed_col = RCColumnNLPResult(sec, 12.0, 12.0, sec.ρg, 12.0, 12.0, 144.0, :failed, 1)
        opts = ConcreteColumnOptions(sizing_strategy=:nlp)
        geom = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        failed = StructuralSizer._rc_nlp_export_result([bad], opts, [geom])
        @test failed.status === :infeasible
        @test isnothing(failed.sections[1])
        @test !StructuralSizer._rc_nlp_result_installable(failed)
        mixed = StructuralSizer._rc_nlp_export_result([good, bad], opts, [geom, geom])
        @test mixed.status === :infeasible
        @test all(isnothing, mixed.sections)
        crashed = StructuralSizer._rc_nlp_export_result([failed_col], opts, [geom])
        @test crashed.status === :infeasible
        ok = StructuralSizer._rc_nlp_export_result([good], opts, [geom])
        @test ok.status === :nlp_complete
        @test ok.sections[1] === sec
        @test ok.objective_value > 0
        @test StructuralSizer._rc_nlp_result_installable(ok)
        # No columns: nothing failed, nothing to install.
        empty = StructuralSizer._rc_nlp_export_result(
            RCColumnNLPResult[], opts, ConcreteMemberGeometry[])
        @test empty.status === :nlp_complete
        @test isempty(empty.sections)
        @test StructuralSizer._rc_nlp_result_installable(empty)
        # A non-Symbol status is the discrete MIP termination code.
        @test StructuralSizer._rc_nlp_result_installable((; sections=[sec], status="OPTIMAL"))
        @test !StructuralSizer._rc_nlp_result_installable((; sections=[nothing], status=:nlp_complete))
    end

    @testset "Multi-start fallback is infeasible unless it passes the check" begin
        r = (minimizer = [1.0], objective_value = 2.0, constraints = [0.5], status = :optimal)
        kept = StructuralSizer._multistart_fallback(r, _ -> true)
        @test kept === r
        marked = StructuralSizer._multistart_fallback(r, _ -> false)
        @test marked.status === :infeasible
        @test marked.minimizer == r.minimizer
        @test !nlp_acceptable(marked.status)
    end

    @testset "Circular NLP uses the same 1.4 magnifier cap" begin
        # 30 m, 12 in diameter: kℓu/r is far past §6.2.5.1 and Pu is past
        # 0.75 Pc, so Eq. (6.6.4.5.2) is undefined and the row must exceed 1.
        demand = RCColumnDemand(1; Pu=400.0, Mux=50.0, M1x=0.0, M2x=50.0, βdns=0.6)
        geometry = ConcreteMemberGeometry(30.0; k=1.0, braced=true)
        opts = NLPColumnOptions(tie_type=:spiral, include_slenderness=true)
        problem = RCCircularNLPProblem(demand, geometry, opts)
        @test constraint_fns(problem, [12.0, 0.02])[1] > 1.0
    end

end

println("\n✅ All RC Column NLP tests passed!")
