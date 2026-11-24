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
end
