using StructuralSizer
using Unitful
using Test
import JuMP
const MOI = JuMP.MOI

# Coupled MIP warm start: seeding the section-count-capped problem (n_max_sections
# > 0) now seeds the coupling `z` binaries alongside `x`. The invariant is the
# OPTIMAL OBJECTIVE (a warm start is a pure hint); the exact assignment need not
# match when several equally-optimal section sets exist.

@testset "coupled warm start (n_max_sections > 0)" begin
    # Deflection-governed beams with spread required stiffness so the unconstrained
    # optimum uses several distinct sections (a cap then genuinely binds).
    catalog = steel_column_catalog(:w, :all)
    Ix_cat = [ustrip(u"m^4", Ix(s)) for s in catalog]
    Ix_sorted = sort(Ix_cat)
    n = length(catalog)
    N = 10
    ranks = round.(Int, range(0.2n, 0.6n; length = N))
    I_req = [Ix_sorted[r] * 1.0005 for r in ranks]
    Ls = [7.0 + 0.3 * (g - 1) for g in 1:N]
    lim = 1 / 360
    demands = [MemberDemand(g; Mux = 5.0e3, δ_max_LL = I_req[g] * lim * Ls[g], I_ref = 1.0)
               for g in 1:N]
    geoms = [SteelMemberGeometry(Ls[g]; Lb = Ls[g]) for g in 1:N]
    checker = AISCChecker(; deflection_limit = lim)

    run(; nmax, mip_start = nothing) = optimize_discrete(
        checker, demands, geoms, catalog, A992_Steel;
        objective = MinVolume(), n_max_sections = nmax, mip_start = mip_start,
        time_limit_sec = 60.0)

    @testset "warm start preserves the capped optimum" begin
        for nmax in (2, 3, 5)
            cold = run(; nmax = nmax)
            @test cold.status == MOI.OPTIMAL
            @test length(unique(cold.section_indices)) ≤ nmax        # cap respected
            # Seed from the cold optimum itself: a valid ≤ nmax-distinct feasible seed.
            warm = run(; nmax = nmax, mip_start = cold.section_indices)
            @test warm.status == MOI.OPTIMAL
            @test length(unique(warm.section_indices)) ≤ nmax
            # Objective is the invariant a hint must preserve (assignment may differ).
            @test warm.objective_value ≈ cold.objective_value rtol = 1e-6
        end
    end

    @testset "over-rich seed is safely ignored" begin
        # The unconstrained optimum uses more than `nmax` distinct sections; seeding
        # it into a capped solve is an infeasible start the solver must discard —
        # the capped optimum is still reached.
        unconstrained = run(; nmax = 0)
        nmax = 2
        @test length(unique(unconstrained.section_indices)) > nmax
        capped_cold = run(; nmax = nmax)
        capped_warm = run(; nmax = nmax, mip_start = unconstrained.section_indices)
        @test capped_warm.status == MOI.OPTIMAL
        @test length(unique(capped_warm.section_indices)) ≤ nmax
        @test capped_warm.objective_value ≈ capped_cold.objective_value rtol = 1e-6
    end

    @testset "part-count cap is a real trade-off (monotone front)" begin
        # Fewer unique sections ⇒ never lighter: volume is non-increasing in nmax.
        vols = [run(; nmax = k).objective_value for k in 1:5]
        for k in 1:4
            @test vols[k] ≥ vols[k + 1] - 1e-9
        end
    end

    @testset "separable_lower_bound certifies the capped optimum" begin
        lb = separable_lower_bound(checker, demands, geoms, catalog, A992_Steel;
                                   objective = MinVolume())
        # Exactly the uncapped (separable) optimum.
        full = run(; nmax = 0)
        @test lb ≈ full.objective_value rtol = 1e-9
        # A valid lower bound on every capped solve, and tight as nmax grows.
        for nmax in (1, 2, 3, 5)
            capped = run(; nmax = nmax)
            @test capped.objective_value ≥ lb - 1e-9
            @test optimality_gap(capped.objective_value, lb) ≥ -1e-12
        end
        # Strictly tighter than the continuous convex-hull envelope.
        law = fit_section_scaling_law(
            [ustrip(u"m^4", Ix(s)) for s in catalog],
            [ustrip(u"m^2", s.A) for s in catalog])
        Ls_v = [g.L isa Unitful.Length ? ustrip(u"m", g.L) : Float64(g.L) for g in geoms]
        hull_lb = relaxation_lower_bound(law, I_req, Ls_v)
        @test lb ≥ hull_lb - 1e-9
    end
end

@testset "continuation_seed (DP-optimal part-count bucketing)" begin
    # Pure numeric contract — no solver needed.
    @testset "respects the cap and only up-assigns" begin
        section_idx = [10, 20, 30, 40, 50]
        coeffs = [1.0, 2.0, 3.0, 4.0, 5.0]        # monotone size proxy
        lengths = ones(5)
        for nmax in 1:6
            seed = continuation_seed(section_idx, coeffs, lengths, nmax)
            @test length(unique(seed)) ≤ nmax
            # Every group adopts a section ≥ its own (feasible under monotonicity).
            for g in 1:5
                gi = findfirst(==(seed[g]), section_idx)
                @test coeffs[gi] ≥ coeffs[g] - 1e-12
            end
        end
    end

    @testset "nmax ≥ #distinct returns the separable optimum unchanged" begin
        section_idx = [3, 1, 4, 2]
        coeffs = [3.0, 1.0, 4.0, 2.0]
        seed = continuation_seed(section_idx, coeffs, ones(4), 4)
        @test seed == section_idx
    end

    @testset "DP beats a naive equal-width split" begin
        # Skewed lengths: the optimal split must put the break where weight is saved.
        section_idx = collect(1:6)
        coeffs = Float64.(1:6)
        lengths = [1.0, 1.0, 1.0, 10.0, 10.0, 10.0]
        seed = continuation_seed(section_idx, coeffs, lengths, 2)
        w(s) = sum(coeffs[s[g]] * lengths[g] for g in 1:6)
        # Naive midpoint split {1:3},{4:6}: reps = sections 3 and 6.
        naive = [3, 3, 3, 6, 6, 6]
        @test w(seed) ≤ w(naive) + 1e-9
        @test length(unique(seed)) ≤ 2
    end

    @testset "handles unsorted input by its own ordering" begin
        section_idx = [50, 10, 40, 20, 30]
        coeffs = [5.0, 1.0, 4.0, 2.0, 3.0]
        seed = continuation_seed(section_idx, coeffs, ones(5), 2)
        @test length(unique(seed)) ≤ 2
        for g in 1:5
            gi = findfirst(==(seed[g]), section_idx)
            @test coeffs[gi] ≥ coeffs[g] - 1e-12
        end
    end

    @testset "seed drives the real capped MIP to its optimum" begin
        catalog = steel_column_catalog(:w, :all)
        Ix_cat = [ustrip(u"m^4", Ix(s)) for s in catalog]
        Ix_sorted = sort(Ix_cat)
        N = 10
        ranks = round.(Int, range(0.2length(catalog), 0.6length(catalog); length = N))
        I_req = [Ix_sorted[r] * 1.0005 for r in ranks]
        Ls = [7.0 + 0.3 * (g - 1) for g in 1:N]
        lim = 1 / 360
        demands = [MemberDemand(g; Mux = 5.0e3, δ_max_LL = I_req[g] * lim * Ls[g], I_ref = 1.0)
                   for g in 1:N]
        geoms = [SteelMemberGeometry(Ls[g]; Lb = Ls[g]) for g in 1:N]
        checker = AISCChecker(; deflection_limit = lim)

        sep = optimize_binary_search(checker, demands, geoms, catalog, A992_Steel;
                                     objective = MinVolume())
        coeffs = [ustrip(u"m^2", catalog[j].A) for j in sep.section_indices]
        for nmax in (2, 3)
            seed = continuation_seed(sep.section_indices, coeffs, Ls, nmax)
            @test length(unique(seed)) ≤ nmax
            cold = optimize_discrete(checker, demands, geoms, catalog, A992_Steel;
                                     objective = MinVolume(), n_max_sections = nmax)
            warm = optimize_discrete(checker, demands, geoms, catalog, A992_Steel;
                                     objective = MinVolume(), n_max_sections = nmax,
                                     mip_start = seed)
            @test warm.objective_value ≈ cold.objective_value rtol = 1e-6
        end
    end
end
