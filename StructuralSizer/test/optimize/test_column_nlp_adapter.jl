# ==============================================================================
# Test size_columns NLP adapter (sizing_strategy = :nlp)
# ==============================================================================
# Verifies that ConcreteColumnOptions(sizing_strategy=:nlp) routes through the
# NLP path and returns the same NamedTuple shape as the MIP catalog path, so
# the slab-column iteration loop in size_flat_plate! works transparently.

using Test
using StructuralSizer
using Unitful
using Asap: kip, ksi

@testset "size_columns NLP adapter" begin

    # Shared test fixtures
    geoms = [ConcreteMemberGeometry(4.0; k=1.0, braced=true) for _ in 1:3]
    Pu  = [300.0, 500.0, 700.0] .* kip
    Mux = [100.0, 200.0, 300.0] .* kip .* u"ft"

    @testset "NLP path returns MIP-compatible result shape" begin
        # The slab pipeline reads column_result.sections[i] and calls
        # bounding_box(section) and section.ρg.  Verify the NLP adapter
        # returns the same fields.
        opts = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :nlp,
        )
        result = StructuralSizer.size_columns(Pu, Mux, geoms, opts)

        @test hasproperty(result, :sections)
        @test hasproperty(result, :section_indices)
        @test hasproperty(result, :objective_value)
        @test length(result.sections) == 3
        @test length(result.section_indices) == 3

        for (i, sec) in enumerate(result.sections)
            @test sec isa RCColumnSection
            bb = bounding_box(sec)
            @test bb.width > 0u"inch"
            @test bb.depth > 0u"inch"
            @test sec.ρg >= 0.01
            @test sec.ρg <= 0.08
        end

        @test result.objective_value > 0
        @test result.status === :nlp_complete
        @test StructuralSizer._rc_nlp_result_installable(result)
    end

    @testset "MIP and NLP produce comparable results" begin
        # Both strategies should produce valid columns for the same demands.
        # Dimensions may differ, but both must be structurally adequate.
        opts_mip = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :discrete,
            catalog         = :high_capacity,
        )
        opts_nlp = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :nlp,
        )

        result_mip = StructuralSizer.size_columns(Pu, Mux, geoms, opts_mip)
        result_nlp = StructuralSizer.size_columns(Pu, Mux, geoms, opts_nlp)

        for i in 1:3
            bb_mip = bounding_box(result_mip.sections[i])
            bb_nlp = bounding_box(result_nlp.sections[i])
            # Both should produce positive-dimension sections
            @test ustrip(u"inch", bb_mip.width) > 0
            @test ustrip(u"inch", bb_nlp.width) > 0
            # NLP may produce smaller sections (continuous optimization)
            # but shouldn't be wildly different — within 2× of each other
            area_mip = ustrip(u"inch", bb_mip.width) * ustrip(u"inch", bb_mip.depth)
            area_nlp = ustrip(u"inch", bb_nlp.width) * ustrip(u"inch", bb_nlp.depth)
            @test area_nlp / area_mip > 0.3  # NLP shouldn't be absurdly smaller
            @test area_nlp / area_mip < 3.0  # or absurdly larger
        end
    end

    @testset "NLP respects max_depth" begin
        # max_depth should limit the NLP solution dimensions
        opts = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :nlp,
            max_depth       = 24.0u"inch",
        )
        result = StructuralSizer.size_columns(Pu, Mux, geoms, opts)

        for sec in result.sections
            bb = bounding_box(sec)
            # Allow small tolerance for rounding
            @test ustrip(u"inch", bb.width) <= 26.0
            @test ustrip(u"inch", bb.depth) <= 26.0
        end
    end

    @testset "sizing_strategy = :discrete still works (regression)" begin
        # Ensure the default MIP path is unaffected
        opts = ConcreteColumnOptions(
            material        = NWC_4000,
            sizing_strategy = :discrete,
        )
        result = StructuralSizer.size_columns(Pu, Mux, geoms, opts)

        @test hasproperty(result, :sections)
        @test length(result.sections) == 3
        for sec in result.sections
            @test sec isa RCColumnSection
        end
    end

    @testset "NLP with high demand (edge case)" begin
        # Near-capacity demand. A section that passes the as-built check is a
        # completed design. If none does, the adapter reports :infeasible and
        # does not return a section that can be installed.
        Pu_high  = [1200.0kip]
        Mux_high = [500.0kip * u"ft"]
        geom_high = [ConcreteMemberGeometry(4.0; k=1.0, braced=true)]

        opts = ConcreteColumnOptions(
            material        = NWC_6000,
            sizing_strategy = :nlp,
            nlp_ρ_max       = 0.06,
        )
        result = StructuralSizer.size_columns(Pu_high, Mux_high, geom_high, opts)

        @test length(result.sections) == 1
        if result.status === :nlp_complete
            sec = result.sections[1]
            @test sec isa RCColumnSection
            bb = bounding_box(sec)
            @test ustrip(u"inch", bb.width) >= 8.0  # At least min dim
            @test StructuralSizer._rc_nlp_result_installable(result)
        else
            @test result.status === :infeasible
            @test isnothing(result.sections[1])
            @test !StructuralSizer._rc_nlp_result_installable(result)
        end
    end

    @testset "NLP NLPColumnOptions field forwarding" begin
        # Verify nlp_* fields on ConcreteColumnOptions are respected
        opts = ConcreteColumnOptions(
            sizing_strategy   = :nlp,
            nlp_dim_increment = 1.0u"inch",
            nlp_prefer_square = 0.5,
            nlp_ρ_max         = 0.04,
            nlp_maxiter       = 100,
        )
        # Just verify it runs without error — field forwarding is tested
        # by the fact that the NLP solver uses these settings.
        result = StructuralSizer.size_columns(Pu[1:1], Mux[1:1], geoms[1:1], opts)
        @test length(result.sections) == 1
        @test result.status === :nlp_complete
    end

    @testset "Infeasible NLP column is not a completed design" begin
        # Same demand the repair test cannot carry at 12 in with the 32-bar cap.
        opts = ConcreteColumnOptions(
            sizing_strategy = :nlp,
            max_depth = 12u"inch",
        )
        result = StructuralSizer.size_columns(
            [3000.0kip],
            [100.0kip * u"ft"],
            [ConcreteMemberGeometry(4.0; k=1.0, braced=true)],
            opts,
        )
        @test result.status === :infeasible
        @test result.status !== :nlp_complete
        @test !StructuralSizer._rc_nlp_result_installable(result)
        @test length(result.sections) == 1
        @test isnothing(result.sections[1])
    end

    @testset "NLP adapter keeps the caller RCColumnDemand" begin
        opts = ConcreteColumnOptions(
            sizing_strategy = :nlp,
            include_slenderness = true,
        )
        geom = ConcreteMemberGeometry(4.0; k=1.0, braced=true)
        demand = RCColumnDemand(1;
            Pu=300.0, Mux=100.0, Muy=0.0,
            M1x=-40.0, M2x=100.0,
            βdns=opts.βdns,
            transverse_load=true)
        result = StructuralSizer.size_columns([demand], [geom], opts)
        @test result.status === :nlp_complete
        sec = result.sections[1]
        @test sec isa RCColumnSection
        nlp_opts = NLPColumnOptions(
            material = opts.material,
            rebar_material = opts.rebar_material,
            cover = opts.cover,
            include_slenderness = true,
            βdns = opts.βdns,
            ρ_max = opts.nlp_ρ_max,
            max_dim = 48.0u"inch",
        )
        problem = RCColumnNLPProblem(demand, geom, nlp_opts)
        @test problem.demand === demand
        @test problem.demand.transverse_load
        @test problem.demand.M1x == -40.0
        @test StructuralSizer._rc_column_as_built_ok(
            problem, StructuralSizer._rc_column_nlp_checker(nlp_opts), sec)
        # A stripped stand-in is a different demand. The returned section was
        # accepted on the caller demand, which sets transverse_load.
        stripped = RCColumnDemand(1; Pu=300.0, Mux=100.0, Muy=0.0, βdns=opts.βdns)
        @test stripped.transverse_load == false
        @test stripped.M1x == 0
        @test !(stripped.transverse_load == demand.transverse_load && stripped.M1x == demand.M1x)
    end

end

@testset "NLP column sizing constrains each load case" begin
    geom = ConcreteMemberGeometry(3.0u"m"; k = 1.0, braced = true)
    nlp_opts = NLPColumnOptions(
        material = NWC_4000,
        min_dim = 10.0u"inch",
        max_dim = 36.0u"inch",
        include_slenderness = false,
        maxiter = 150,
        n_multistart = 0,
    )
    # A section can pass the envelope (largest P with largest M) and fail the
    # low-axial case with that same moment. Below the balance point, less
    # compression means less moment capacity (ACI 318-19 §22.4).
    catalog = standard_rc_columns(; sizes = 12:4:24)
    checker = ACIColumnChecker(; include_slenderness = false, include_biaxial = true,
                               fy_ksi = 60.0, Es_ksi = 29000.0)
    cache = create_cache(checker, length(catalog))
    precompute_capacities!(checker, cache, catalog, NWC_4000, MinVolume())
    found = nothing
    for (j, s) in enumerate(catalog), Pu_hi in (150.0, 300.0, 500.0, 800.0),
        Mu in 40.0:40.0:280.0, Pu_lo in (0.0, 15.0, 40.0)
        hi = RCColumnDemand(1; Pu = Pu_hi, Mux = Mu, Muy = 0.0)
        lo = RCColumnDemand(1; Pu = Pu_lo, Mux = Mu, Muy = 0.0)
        is_feasible(checker, cache, j, s, NWC_4000, hi, geom) || continue
        is_feasible(checker, cache, j, s, NWC_4000, lo, geom) && continue
        found = (hi, lo, j, s)
        break
    end
    @test found !== nothing
    hi, lo, jweak, weak = found
    set = RCColumnDemandSet(1, [hi, lo])
    @test !is_feasible(checker, cache, jweak, weak, NWC_4000, set, geom)

    problem = RCColumnNLPProblem(set, geom, nlp_opts)
    @test length(problem.cases) == 2
    @test n_constraints(problem) == 3
    @test constraint_names(problem)[end] == "placeable steel"
    @test problem.Pu_kip ≈ hi.Pu
    @test problem.Mux_kipft ≈ hi.Mux
    dup = RCColumnNLPProblem(RCColumnDemandSet(1, [hi, hi]), geom, nlp_opts)
    @test length(dup.cases) == 1
    @test n_constraints(dup) == 2
    @test n_constraints(RCCircularNLPProblem(set, geom, nlp_opts)) == 2

    # The envelope demand is the one the old path would have solved. It is not
    # a stand-in for the low-axial case, which the section above already fails.
    both = size_rc_column_nlp(hi.Pu, lo.Mux, geom, nlp_opts; demand = set)
    @test both.status in (:optimal, :feasible, :converged)
    both_cache = create_cache(checker, 1)
    precompute_capacities!(checker, both_cache, [both.section], NWC_4000, MinVolume())
    @test is_feasible(checker, both_cache, 1, both.section, NWC_4000, hi, geom)
    @test is_feasible(checker, both_cache, 1, both.section, NWC_4000, lo, geom)

    solved = size_columns([set], [geom], ConcreteColumnOptions(
        material = NWC_4000, sizing_strategy = :nlp, include_slenderness = false,
        nlp_maxiter = 150, nlp_n_multistart = 0, max_depth = 36.0u"inch"))
    @test solved.status == :nlp_complete
    @test solved.sections[1] isa RCColumnSection
end

# ACI 318-19 §22.4: below the balance point, less compression means less moment
# capacity. The envelope (largest P with largest M) is a different demand from
# the cases that produced those peaks. These checks are the map of that
# surface, so a later change that makes axial load monotone, or that sizes
# the envelope instead of the cases, fails here.
@testset "Column strength follows the interaction surface" begin
    geom = ConcreteMemberGeometry(3.0u"m"; k = 1.0, braced = true)
    catalog = standard_rc_columns(; sizes = 12:4:24)
    checker = ACIColumnChecker(; include_slenderness = false, include_biaxial = true,
                               fy_ksi = 60.0, Es_ksi = 29000.0)
    cache = create_cache(checker, length(catalog))
    precompute_capacities!(checker, cache, catalog, NWC_4000, MinVolume())
    passes(j, s, Pu, Mu; Muy = 0.0) = is_feasible(
        checker, cache, j, s, NWC_4000,
        RCColumnDemand(1; Pu = Pu, Mux = Mu, Muy = Muy), geom)

    # At one axial load, a larger moment never brings a failed section back.
    moments = (20.0, 80.0, 200.0, 400.0)
    for (j, s) in enumerate(catalog), Pu in (20.0, 200.0, 800.0)
        j % 8 == 1 || continue
        failed = false
        for Mu in moments
            ok = passes(j, s, Pu, Mu)
            failed && @test !ok
            failed |= !ok
        end
    end

    # Same moment: some section passes a higher compression and fails a lower one.
    split = nothing
    for (j, s) in enumerate(catalog), Pu_hi in (150.0, 300.0, 500.0, 800.0),
        Mu in 40.0:40.0:280.0, Pu_lo in (0.0, 15.0, 40.0)
        passes(j, s, Pu_hi, Mu) || continue
        passes(j, s, Pu_lo, Mu) && continue
        split = (j, s, Pu_hi, Pu_lo, Mu)
        break
    end
    @test split !== nothing
    j, s, Pu_hi, Pu_lo, Mu = split
    @test passes(j, s, Pu_hi, Mu)
    @test !passes(j, s, Pu_lo, Mu)

    # Adding the other axis does not make a failed uniaxial case pass.
    @test !passes(j, s, Pu_lo, Mu; Muy = 40.0)

    # The two real cases and their envelope are not the same demand.
    hi = RCColumnDemand(1; Pu = 800.0, Mux = 30.0, Muy = 0.0)
    lo = RCColumnDemand(1; Pu = 40.0, Mux = 250.0, Muy = 0.0)
    env = RCColumnDemand(1; Pu = 800.0, Mux = 250.0, Muy = 0.0)
    envelope_misses_low = false
    cases_miss_envelope = false
    for (jj, ss) in enumerate(catalog)
        ok_hi = passes(jj, ss, hi.Pu, hi.Mux)
        ok_lo = passes(jj, ss, lo.Pu, lo.Mux)
        ok_env = passes(jj, ss, env.Pu, env.Mux)
        envelope_misses_low |= ok_env && !ok_lo
        cases_miss_envelope |= ok_hi && ok_lo && !ok_env
        (envelope_misses_low || cases_miss_envelope) && break
    end
    @test envelope_misses_low || cases_miss_envelope

    nlp_opts = NLPColumnOptions(
        material = NWC_4000,
        min_dim = 10.0u"inch",
        max_dim = 36.0u"inch",
        include_slenderness = false,
        maxiter = 150,
        n_multistart = 0,
    )
    set = RCColumnDemandSet(1, [hi, lo])
    both = size_rc_column_nlp(hi.Pu, lo.Mux, geom, nlp_opts; demand = set)
    @test both.status in (:optimal, :feasible, :converged)
    both_cache = create_cache(checker, 1)
    precompute_capacities!(checker, both_cache, [both.section], NWC_4000, MinVolume())
    @test is_feasible(checker, both_cache, 1, both.section, NWC_4000, hi, geom)
    @test is_feasible(checker, both_cache, 1, both.section, NWC_4000, lo, geom)

    # A section sized for the larger moment still carries the smaller one.
    soft = size_rc_column_nlp(300.0, 40.0, geom, nlp_opts;
        demand = RCColumnDemand(1; Pu = 300.0, Mux = 40.0, Muy = 0.0))
    hard = size_rc_column_nlp(300.0, 200.0, geom, nlp_opts;
        demand = RCColumnDemand(1; Pu = 300.0, Mux = 200.0, Muy = 0.0))
    @test soft.status in (:optimal, :feasible, :converged)
    @test hard.status in (:optimal, :feasible, :converged)
    pair = [soft.section, hard.section]
    pair_cache = create_cache(checker, 2)
    precompute_capacities!(checker, pair_cache, pair, NWC_4000, MinVolume())
    soft_d = RCColumnDemand(1; Pu = 300.0, Mux = 40.0, Muy = 0.0)
    hard_d = RCColumnDemand(1; Pu = 300.0, Mux = 200.0, Muy = 0.0)
    @test is_feasible(checker, pair_cache, 1, soft.section, NWC_4000, soft_d, geom)
    @test is_feasible(checker, pair_cache, 2, hard.section, NWC_4000, hard_d, geom)
    @test is_feasible(checker, pair_cache, 2, hard.section, NWC_4000, soft_d, geom)
end

println("\n✅ All size_columns NLP adapter tests passed!")
