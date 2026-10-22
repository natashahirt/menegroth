# ==============================================================================
# Tests: RC T-Beam NLP + MIP Optimization
# ==============================================================================
# Tests both continuous (NLP) and discrete (MIP) optimization of RC T-beams.
# Flange width (bf) and flange thickness (hf) are fixed (from slab sizing).

using Test
using Unitful
using StructuralSizer
using Asap
using Asap: kip, ksi, psf

@testset "RC T-Beam Optimization" begin

    # ============================================================
    # 1. NLP Problem Construction
    # ============================================================
    @testset "NLP problem construction" begin
        bf = 48.0u"inch"
        hf = 5.0u"inch"
        Mu = 250.0kip * u"ft"
        Vu = 50.0kip
        opts = NLPBeamOptions(min_width=10.0u"inch", max_width=24.0u"inch",
                              min_depth=16.0u"inch", max_depth=30.0u"inch")

        prob = RCTBeamNLPProblem(Mu, Vu, bf, hf, opts)

        @test prob.bf_in ≈ 48.0
        @test prob.hf_in ≈ 5.0
        @test prob.Mu_kipft ≈ 250.0
        @test prob.Vu_kip ≈ 50.0
        @test prob.bw_max ≤ 48.0   # bw ≤ bf
        @test prob.h_min > 5.0     # h > hf

        # Correct number of variables/constraints
        @test StructuralSizer.n_variables(prob) == 3
        @test StructuralSizer.n_constraints(prob) == 4

        # Variable bounds
        lb, ub = StructuralSizer.variable_bounds(prob)
        @test lb[1] ≈ 10.0    # bw_min
        @test ub[1] ≤ 48.0    # bw_max ≤ bf
        @test lb[2] ≥ 7.0     # h_min > hf + clearance

        # Initial guess is within bounds
        x0 = StructuralSizer.initial_guess(prob)
        @test all(lb .≤ x0 .≤ ub)
    end

    # ============================================================
    # 2. NLP bw_max clamping (bw ≤ bf)
    # ============================================================
    @testset "NLP bw_max clamped to bf" begin
        # Small flange: bf = 16", max_width = 24" → bw_max = 16"
        opts = NLPBeamOptions(max_width=24.0u"inch")
        prob = RCTBeamNLPProblem(100.0kip*u"ft", 20.0kip, 16.0u"inch", 4.0u"inch", opts)
        @test prob.bw_max ≈ 16.0
    end

    # ============================================================
    # 3. NLP Constraint Evaluation
    # ============================================================
    @testset "NLP constraint evaluation" begin
        bf = 48.0u"inch"
        hf = 5.0u"inch"
        Mu = 200.0kip * u"ft"
        Vu = 30.0kip
        opts = NLPBeamOptions()

        prob = RCTBeamNLPProblem(Mu, Vu, bf, hf, opts)

        # A generous section should be feasible (all utils < 1.0)
        x_generous = [14.0, 24.0, 0.012]
        c = StructuralSizer.constraint_fns(prob, x_generous)
        @test length(c) == 4
        @test c[1] < 1.0   # Flexure OK
        @test c[2] < 1.0   # Shear OK
        @test c[3] < 1.0   # Strain OK
        @test c[4] < 1.0   # Min rebar OK

        # A tiny section should be infeasible for flexure
        x_tiny = [10.0, 12.0, 0.003]
        c_tiny = StructuralSizer.constraint_fns(prob, x_tiny)
        @test c_tiny[1] > 1.0  # Flexure violated
    end

    # ============================================================
    # 4. NLP: Stress block in flange vs web
    # ============================================================
    @testset "NLP flexure: flange vs web cases" begin
        opts = NLPBeamOptions()

        # Case A: Wide flange, small moment → stress block stays in flange
        prob_flange = RCTBeamNLPProblem(
            50.0kip*u"ft", 10.0kip, 60.0u"inch", 6.0u"inch", opts)
        x = [12.0, 20.0, 0.005]  # Low ρ
        c_flange = StructuralSizer.constraint_fns(prob_flange, x)
        @test c_flange[1] < 1.0  # Feasible

        # Case B: Narrow flange, large moment → stress block into web
        prob_web = RCTBeamNLPProblem(
            300.0kip*u"ft", 60.0kip, 20.0u"inch", 3.0u"inch", opts)
        x_web = [14.0, 28.0, 0.014]  # Higher ρ
        c_web = StructuralSizer.constraint_fns(prob_web, x_web)
        @test length(c_web) == 4
    end

    # ============================================================
    # 5. NLP Objective (web area only)
    # ============================================================
    @testset "NLP objective uses web area" begin
        opts = NLPBeamOptions(objective=MinVolume())
        prob = RCTBeamNLPProblem(200.0kip*u"ft", 30.0kip, 48.0u"inch", 5.0u"inch", opts)

        x = [12.0, 24.0, 0.01]
        obj = StructuralSizer.objective_fn(prob, x)
        # Web area = 12 × 24 = 288, with ρ penalty
        @test obj ≈ 288.0 * (1 + 2.0 * 0.01) atol=1.0
    end

    # ============================================================
    # 6. Full NLP solve (single beam)
    # ============================================================
    @testset "NLP full solve" begin
        Mu = 200.0kip * u"ft"
        Vu = 40.0kip
        bf = 48.0u"inch"
        hf = 5.0u"inch"
        opts = NLPBeamOptions(
            min_width=10.0u"inch", max_width=20.0u"inch",
            min_depth=14.0u"inch", max_depth=30.0u"inch",
        )

        # Sagging-only example: hogging demand is zero (default Mu_neg=Mu
        # would reject a flange-in-compression T-beam on the web face).
        result = size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts; Mu_neg=0.0)

        @test result isa RCTBeamNLPResult
        @test result.section isa RCTBeamSection
        @test result.status ∈ [:optimal, :feasible]

        # Dimensions within bounds
        @test result.bw_final ≥ 10.0
        @test result.bw_final ≤ 48.0    # ≤ bf
        @test result.h_final ≥ 14.0
        @test result.h_final ≤ 30.0

        # Fixed flange
        @test result.bf ≈ 48.0
        @test result.hf ≈ 5.0

        # Section properties
        @test ustrip(u"inch", result.section.bf) ≈ 48.0
        @test ustrip(u"inch", result.section.hf) ≈ 5.0
        @test result.section.n_bars ≥ 2
    end

    # ============================================================
    # 7. NLP multiple beams
    # ============================================================
    @testset "NLP multiple beams (scalar bf/hf)" begin
        Mu = [150.0, 250.0, 350.0] .* kip .* u"ft"
        Vu = [30.0, 50.0, 70.0] .* kip
        bf = 48.0u"inch"
        hf = 5.0u"inch"
        opts = NLPBeamOptions()

        results = size_rc_tbeams_nlp(Mu, Vu, bf, hf, opts)
        @test length(results) == 3
        @test all(r -> r isa RCTBeamNLPResult, results)

        # Higher Mu should require larger section or more rebar
        areas = [r.area_web for r in results]
        @test areas[3] ≥ areas[1]
    end

    # ============================================================
    # 8. NLP multiple beams (per-beam bf/hf)
    # ============================================================
    @testset "NLP multiple beams (vector bf/hf)" begin
        Mu = [150.0, 250.0] .* kip .* u"ft"
        Vu = [30.0, 50.0] .* kip
        bf = [36.0, 48.0] .* u"inch"
        hf = [4.0, 6.0] .* u"inch"
        opts = NLPBeamOptions()

        results = size_rc_tbeams_nlp(Mu, Vu, bf, hf, opts)
        @test length(results) == 2
        @test ustrip(u"inch", results[1].section.bf) ≈ 36.0
        @test ustrip(u"inch", results[2].section.bf) ≈ 48.0
    end

    # ============================================================
    # 9. NLP: T-beam vs rectangular comparison
    # ============================================================
    @testset "NLP: T-beam smaller web than rectangular beam" begin
        Mu = 250.0kip * u"ft"
        Vu = 40.0kip
        opts = NLPBeamOptions(
            min_width=10.0u"inch", max_width=24.0u"inch",
            min_depth=14.0u"inch", max_depth=36.0u"inch",
        )

        # Rectangular beam
        rect_result = size_rc_beam_nlp(Mu, Vu, opts)

        # T-beam with generous flange
        tbeam_result = size_rc_tbeam_nlp(Mu, Vu, 60.0u"inch", 6.0u"inch", opts)

        # T-beam web should be no larger than rectangular (the flange helps!)
        @test tbeam_result.area_web ≤ rect_result.area * 1.05  # Allow 5% tolerance
    end

    # ============================================================
    # 10. MIP T-Beam Sizing
    # ============================================================
    @testset "MIP T-beam sizing" begin
        Mu = [150.0, 250.0] .* kip .* u"ft"
        Vu = [30.0, 50.0] .* kip
        geoms = [ConcreteMemberGeometry(8.0u"m") for _ in 1:2]
        opts = ConcreteBeamOptions()

        result = size_tbeams(Mu, Vu, geoms, opts;
                             flange_width=48.0u"inch",
                             flange_thickness=5.0u"inch")

        @test length(result.sections) == 2
        @test all(s -> s isa RCTBeamSection, result.sections)

        # All selected sections should have correct flange
        for sec in result.sections
            @test ustrip(u"inch", sec.bf) ≈ 48.0
            @test ustrip(u"inch", sec.hf) ≈ 5.0
        end

        # Higher Mu should get a deeper/stronger section
        @test ustrip(u"inch", result.sections[2].h) ≥ ustrip(u"inch", result.sections[1].h) - 2.0
    end

    # ============================================================
    # 11. MIP with custom catalog
    # ============================================================
    @testset "MIP with custom T-beam catalog" begin
        custom_cat = standard_rc_tbeams(
            flange_width=36.0u"inch",
            flange_thickness=4.0u"inch",
            web_widths=[12, 14],
            depths=[18, 20, 22, 24],
            bar_sizes=[6, 7, 8],
            n_bars_range=2:4,
        )
        @test length(custom_cat) > 0

        Mu = [100.0] .* kip .* u"ft"
        Vu = [20.0] .* kip
        geoms = [ConcreteMemberGeometry(6.0u"m")]
        opts = ConcreteBeamOptions(custom_catalog=custom_cat)

        result = size_tbeams(Mu, Vu, geoms, opts;
                             flange_width=36.0u"inch",
                             flange_thickness=4.0u"inch")

        @test length(result.sections) == 1
        @test result.sections[1] isa RCTBeamSection
    end

    # ============================================================
    # 12. MIP catalog sizes
    # ============================================================
    @testset "MIP catalog sizes: small, standard, large" begin
        bf = 48.0u"inch"
        hf = 5.0u"inch"
        Mu = [120.0] .* kip .* u"ft"
        Vu = [25.0] .* kip
        geoms = [ConcreteMemberGeometry(7.0u"m")]
        opts = ConcreteBeamOptions()

        for sz in [:small, :standard, :large]
            result = size_tbeams(Mu, Vu, geoms, opts;
                                 flange_width=bf, flange_thickness=hf,
                                 catalog_size=sz)
            @test length(result.sections) == 1
            @test result.sections[1] isa RCTBeamSection
        end
    end

    # ============================================================
    # 13. MIP: T-beam section has correct properties
    # ============================================================
    @testset "MIP selected section satisfies ACI checks" begin
        Mu = [300.0] .* kip .* u"ft"
        Vu = [60.0] .* kip
        geoms = [ConcreteMemberGeometry(9.0u"m")]
        opts = ConcreteBeamOptions()

        result = size_tbeams(Mu, Vu, geoms, opts;
                             flange_width=60.0u"inch",
                             flange_thickness=6.0u"inch",
                             Mu_neg=[0.0])

        sec = result.sections[1]

        # Verify the checker agrees this section is feasible
        checker = ACIBeamChecker(; fy_ksi=60.0, λ=1.0)
        cache = StructuralSizer.ACIBeamCapacityCache(1)
        fc_psi = StructuralSizer.fc_ksi(NWC_4000) * 1000.0
        fy_psi = 60.0 * 1000.0
        cache.fc_ksi = StructuralSizer.fc_ksi(NWC_4000)
        cache.fy_ksi = 60.0
        cache.Es_ksi = 29000.0
        cache.φMn[1] = StructuralSizer._compute_φMn(sec, fc_psi, fy_psi)
        cache.φMn_neg[1] = StructuralSizer._compute_φMn_neg(sec, fc_psi, fy_psi)
        cache.φVn_max[1] = StructuralSizer._compute_φVn_max(sec, fc_psi, 1.0)
        cache.εt[1] = StructuralSizer._compute_εt(sec, fc_psi, fy_psi)
        cache.depths[1] = ustrip(u"m", sec.h)

        demand = RCBeamDemand(1; Mu=300.0, Mu_neg=0.0, Vu=60.0)
        geom = ConcreteMemberGeometry(9.0u"m")

        feas = StructuralSizer.is_feasible(checker, cache, 1, sec, NWC_4000, demand, geom)
        @test feas
    end

    # ============================================================
    # 14. NLP result section buildability
    # ============================================================
    @testset "NLP result builds valid RCTBeamSection" begin
        result = size_rc_tbeam_nlp(
            200.0kip * u"ft", 35.0kip,
            48.0u"inch", 5.0u"inch",
            NLPBeamOptions(),
        )

        sec = result.section
        @test sec.bw ≤ sec.bf
        @test sec.hf < sec.h
        @test sec.As > 0.0u"inch^2"
        @test sec.d > 0.0u"inch"
        @test !isnothing(sec.name)
    end

    # ============================================================
    # 15. Edge case: bf ≈ bw (degenerate T → rectangular)
    # ============================================================
    @testset "Edge: bf ≈ bw (T-beam degenerates to rectangular)" begin
        opts = NLPBeamOptions(min_width=12.0u"inch", max_width=14.0u"inch")

        # bf = 14" ≈ bw → essentially rectangular
        result = size_rc_tbeam_nlp(
            150.0kip * u"ft", 30.0kip,
            14.0u"inch", 4.0u"inch",
            opts,
        )

        @test result isa RCTBeamNLPResult
        @test result.status ∈ [:optimal, :feasible]
        @test result.bw_final ≤ 14.0
    end

    # ============================================================
    # 16. Edge case: very large moment (needs web contribution)
    # ============================================================
    @testset "Edge: large moment pushes stress block into web" begin
        opts = NLPBeamOptions(
            min_width=12.0u"inch", max_width=24.0u"inch",
            min_depth=20.0u"inch", max_depth=40.0u"inch",
        )

        result = size_rc_tbeam_nlp(
            500.0kip * u"ft", 80.0kip,
            36.0u"inch", 4.0u"inch",
            opts;
            Mu_neg=0.0,
        )

        @test result isa RCTBeamNLPResult
        @test result.status ∈ [:optimal, :feasible]
        @test result.section.n_bars ≥ 3
    end

end  # @testset "RC T-Beam Optimization"

println("\n✅ All RC T-Beam optimization tests passed!")
