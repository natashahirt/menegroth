# A sizing loop that only grows may take one step per remaining increment.
# The caller's iteration count is a minimum, not a reason to stop early.

using Test
using Unitful
using StructuralSizer

const SZ = StructuralSizer

@testset "Monotone sizing budgets" begin
    @testset "steps between two sizes" begin
        @test SZ.growth_steps(0.0, 1.0, 0.5) == 2
        @test SZ.growth_steps(12.0, 22.0, 0.5) == 20
        @test SZ.growth_steps(1.0, 1.0, 0.1) == 0
        @test SZ.growth_steps(2.0, 1.0, 0.1) == 0
        @test_throws ArgumentError SZ.growth_steps(0.0, 1.0, 0.0)
        @test_throws ArgumentError SZ.growth_steps(0.0, 1.0, -1.0)
        @test SZ.growth_steps(SZ._growth_meters(8.0u"inch"),
                              SZ._growth_meters(12.0u"inch"),
                              SZ._growth_meters(0.5u"inch")) == 8
    end

    @testset "budget keeps room to grow" begin
        # A column still short of the size that passed at 12 iterations is
        # not cut off at a caller's cap of 10. See the honeycomb note in
        # test_irregular_layout_fallback.jl.
        @test SZ.monotone_budget(10, SZ.growth_steps(12.0, 22.0, 0.5)) >= 12
        @test SZ.monotone_budget(5, 2) == 5
        @test SZ.monotone_budget(5, 20) == 20
        @test SZ.monotone_budget(5, 100) == 48
        @test SZ.monotone_budget(60, 100) == 60
        @test SZ.monotone_budget(5, 0) == 5
        @test_throws ArgumentError SZ.monotone_budget(0, 3)
        @test_throws ArgumentError SZ.monotone_budget(2, -1)
    end

    @testset "a stopped floor names why and is not installed" begin
        raw = (converged = false, failure_reason = "non_convergence",
               failing_check = "punching_shear", stop = :budget)
        status, code, message = SZ.floor_design_failure(raw)
        @test status == SZ.FLOOR_DESIGN_NOT_CONVERGED
        @test code === :non_convergence
        @test occursin("punching_shear", message)
        @test occursin("budget", message)

        limited = (converged = false, failure_reason = "non_convergence",
                   failing_check = "flexural_adequacy", stop = :at_limit)
        status_lim, _, message_lim = SZ.floor_design_failure(limited)
        @test status_lim == SZ.FLOOR_DESIGN_NOT_CONVERGED
        @test occursin("at_limit", message_lim)

        other = (converged = false, failure_reason = "column_pm_infeasible",
                 failing_check = "column_pm")
        status_pm, code_pm, message_pm = SZ.floor_design_failure(other)
        @test status_pm == SZ.FLOOR_DESIGN_INFEASIBLE
        @test code_pm === :column_pm_infeasible
        @test !occursin(";", message_pm)
    end

    @testset "a remesh keeps the analysis counts" begin
        cache = SZ.FEAModelCache()
        @test cache.n_rebuilds == 0
        @test cache.n_updates == 0
        cache.n_rebuilds = 3
        cache.n_updates = 4
        cache.initialized = true
        SZ._reset_fea_cache!(cache)
        @test cache.n_rebuilds == 3
        @test cache.n_updates == 4
        @test cache.initialized == false
    end
end
