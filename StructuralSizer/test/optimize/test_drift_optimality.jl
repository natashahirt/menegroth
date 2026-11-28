using StructuralSizer
using Asap
using Test
using Unitful

# Virtual-work drift optimality-criteria resizer. Synthetic tests exercise the
# pure math (constraint satisfaction, KKT stationarity, strength floors, weight
# efficiency); the final test closes the loop against Asap — resize, re-solve,
# and confirm the drift converges to the allowable.

@testset "drift optimality-criteria resizer" begin

    @testset "single member meets the drift limit exactly" begin
        # δ_now = Σ c = 0.02 > 0.01: the one member grows so γ/s' = δ_allow.
        res = drift_optimality_resize([0.02], [1.0e-4], [1.0], [0.0], 0.01)
        @test res.active
        @test res.sizes[1] ≈ 2.0e-4 rtol = 1e-9          # s' = γ/δ_allow = c·s/δ_allow
        @test res.predicted_drift ≈ 0.01 rtol = 1e-9
        @test !res.frozen[1]
    end

    @testset "two members: KKT stationarity and constraint" begin
        c = [0.015, 0.005]; s = [1.0e-4, 1.0e-4]
        w = [1.0, 4.0]; s_min = [0.0, 0.0]; δ_allow = 0.01
        res = drift_optimality_resize(c, s, w, s_min, δ_allow)
        @test res.active
        @test res.predicted_drift ≈ δ_allow rtol = 1e-9
        # Off the floor, w_e s'_e² / γ_e is the same λ for every member.
        γ = c .* s
        stat = [w[e] * res.sizes[e]^2 / γ[e] for e in 1:2]
        @test stat[1] ≈ stat[2] rtol = 1e-9
        @test stat[1] ≈ res.λ rtol = 1e-9
        @test all(.!res.frozen)
    end

    @testset "optimality beats uniform step-up on weight" begin
        c = [0.015, 0.005]; s = [1.0e-4, 1.0e-4]
        w = [1.0, 4.0]; δ_allow = 0.01
        res = drift_optimality_resize(c, s, w, fill(0.0, 2), δ_allow)
        W_oc = sum(w .* res.sizes)
        # Uniform scaling s → α s to meet the same drift: α = δ_now/δ_allow.
        α = sum(c) / δ_allow
        W_uniform = sum(w .* (α .* s))
        @test W_oc < W_uniform                           # strictly lighter
        @test res.predicted_drift ≈ δ_allow rtol = 1e-9
    end

    @testset "inactive constraint leaves sizes untouched" begin
        s = [1.0e-4, 1.0e-4]
        res = drift_optimality_resize([0.01, 0.005], s, [1.0, 1.0], [0.0, 0.0], 0.05)
        @test !res.active
        @test res.sizes == s
        @test res.predicted_drift ≈ 0.015 rtol = 1e-12
    end

    @testset "strength floor freezes a member; the rest take the budget" begin
        c = [0.019, 0.001]; s = [1.0e-4, 1.0e-4]
        w = [1.0, 1.0]; s_min = [0.0, 3.0e-4]; δ_allow = 0.01
        res = drift_optimality_resize(c, s, w, s_min, δ_allow)
        @test res.frozen == [false, true]
        @test res.sizes[2] ≈ 3.0e-4 rtol = 1e-12          # pinned to its floor
        @test res.sizes[1] > s[1]                         # the active one grows
        @test res.predicted_drift ≈ δ_allow rtol = 1e-9
    end

    @testset "zero-participation member drops to its floor, gets no material" begin
        c = [0.02, 0.0]; s = [1.0e-4, 1.0e-4]
        w = [1.0, 1.0]; s_min = [0.0, 5.0e-5]; δ_allow = 0.01
        res = drift_optimality_resize(c, s, w, s_min, δ_allow)
        @test res.frozen[2]
        @test res.sizes[2] ≈ 5.0e-5 rtol = 1e-12
        @test res.sizes[1] ≈ 2.0e-4 rtol = 1e-9           # carries the whole limit
        @test res.predicted_drift ≈ δ_allow rtol = 1e-9
    end

    @testset "input validation" begin
        @test_throws ArgumentError drift_optimality_resize([0.1], [1.0, 2.0], [1.0], [0.0], 0.01)
        @test_throws ArgumentError drift_optimality_resize([0.1], [1.0], [1.0], [0.0], -1.0)
        @test_throws ArgumentError drift_optimality_resize([0.1], [0.0], [1.0], [0.0], 0.01)
        @test_throws ArgumentError drift_optimality_resize([0.1], [1.0], [0.0], [0.0], 0.01)
    end

    @testset "closed loop vs Asap: resize → re-solve converges to δ_allow" begin
        # Portal frame; tighten the sway limit and iterate resize/re-solve. The
        # first-order drift model + Asap participation must converge to δ_allow.
        H = 3.0; W = 4.0; E = 200.0e9; G = 80.0e9; P = 1.0e5
        A = 1.0e-2; J = 1.0e-6
        mksec(I) = Section(A * u"m^2", E * u"Pa", G * u"Pa",
                           I * u"m^4", I * u"m^4", J * u"m^4")
        n1 = Node([0.0u"m", 0.0u"m", 0.0u"m"], :fixed)
        n2 = Node([0.0u"m", 0.0u"m", H * u"m"], :free)
        n3 = Node([W * u"m", 0.0u"m", H * u"m"], :free)
        n4 = Node([W * u"m", 0.0u"m", 0.0u"m"], :fixed)
        els = [Element(n1, n2, mksec(8.0e-5)),
               Element(n4, n3, mksec(8.0e-5)),
               Element(n2, n3, mksec(1.5e-4))]
        model = FrameModel([n1, n2, n3, n4], els,
                           [NodeForce(n2, [P * u"N", 0.0u"N", 0.0u"N"])])
        solve!(model)
        dof = n2.globalID[1]
        δ0 = drift_participation(model, dof).δ
        δ_allow = 0.6 * δ0                                  # tighten the sway limit

        Lvec = [ustrip(u"m", el.length) for el in model.elements]  # weight ∝ length
        for _ in 1:6
            solve!(model)                                  # fresh u after each resize
            dp = drift_participation(model, dof)
            s = [ustrip(u"m^4", el.section.Ix) for el in model.elements]
            res = drift_optimality_resize(dp.c, s, Lvec, fill(1.0e-8, length(s)), δ_allow)
            for (i, el) in enumerate(model.elements)
                el.section = mksec(res.sizes[i])
            end
            Asap.update!(model; values_only = true)
        end
        solve!(model)
        δ_final = drift_participation(model, dof).δ
        @test δ_final ≈ δ_allow rtol = 3e-2                 # converged to the target
    end
end

@testset "multi-constraint drift optimality-criteria resizer" begin

    @testset "m = 1 reproduces the single-constraint closed form" begin
        c = [0.015, 0.005]; s = [1.0e-4, 1.0e-4]; w = [1.0, 4.0]
        s_min = [0.0, 0.0]; δ_allow = 0.01
        single = drift_optimality_resize(c, s, w, s_min, δ_allow)
        multi = drift_optimality_resize_multi(reshape(c, :, 1), s, w, s_min, [δ_allow])
        @test multi.converged
        @test multi.sizes ≈ single.sizes rtol = 1e-4
        @test multi.predicted_drift[1] ≈ δ_allow rtol = 1e-4
    end

    @testset "two uncoupled constraints each solve independently" begin
        # Members 1,2 feed constraint 1 only; members 3,4 feed constraint 2 only.
        C = [0.015 0.0;
             0.005 0.0;
             0.0   0.012;
             0.0   0.008]
        s = fill(1.0e-4, 4); w = [1.0, 4.0, 1.0, 2.0]; s_min = zeros(4)
        δ_allow = [0.01, 0.01]
        res = drift_optimality_resize_multi(C, s, w, s_min, δ_allow)
        @test res.converged
        @test res.predicted_drift[1] ≈ 0.01 rtol = 2e-3
        @test res.predicted_drift[2] ≈ 0.01 rtol = 2e-3
        # Must match the two independent single-constraint solves.
        s1 = drift_optimality_resize([0.015, 0.005], [1.0e-4, 1.0e-4], [1.0, 4.0], zeros(2), 0.01)
        @test res.sizes[1:2] ≈ s1.sizes rtol = 3e-3
    end

    @testset "coupled constraints: feasibility + KKT stationarity" begin
        # Both constraints share all three members (lower members participate more).
        C = [0.012 0.010;
             0.006 0.007;
             0.004 0.002]
        s = fill(1.0e-4, 3); w = [1.0, 1.5, 2.0]; s_min = zeros(3)
        δ_allow = [0.012, 0.010]
        res = drift_optimality_resize_multi(C, s, w, s_min, δ_allow)
        @test res.converged
        @test all(res.predicted_drift .≤ δ_allow .* (1 + 2e-3))   # feasible
        # Stationarity: w_e s_e² == Σ_j λ_j γ_{e,j} for every (off-floor) member.
        γ = C .* s
        for e in 1:3
            lhs = w[e] * res.sizes[e]^2
            rhs = sum(res.λ[j] * γ[e, j] for j in 1:2)
            @test lhs ≈ rhs rtol = 1e-3
        end
    end

    @testset "slack constraint drops out (λ → 0)" begin
        # Constraint 2 is generously loose; only constraint 1 should bind.
        C = [0.015 0.001;
             0.005 0.001]
        s = fill(1.0e-4, 2); w = [1.0, 1.0]; s_min = zeros(2)
        δ_allow = [0.01, 0.05]
        res = drift_optimality_resize_multi(C, s, w, s_min, δ_allow)
        @test res.converged
        @test res.active[1]
        @test !res.active[2]
        @test res.predicted_drift[1] ≈ 0.01 rtol = 2e-3
        @test res.predicted_drift[2] < δ_allow[2]
    end

    @testset "all limits already satisfied is a no-op" begin
        C = [0.004 0.003; 0.002 0.001]
        s = fill(1.0e-4, 2)
        res = drift_optimality_resize_multi(C, s, [1.0, 1.0], zeros(2), [0.01, 0.01])
        @test res.converged
        @test all(.!res.active)
        @test res.sizes == s
    end

    @testset "closed loop vs Asap: multi-story drifts driven feasible" begin
        # Vertical cantilever stick with a drift limit at every story. Resize each
        # element's I, re-solve, and confirm every inter-story drift lands at or
        # below its allowable — the multi-λ recursion on a real FE model.
        E = 200.0e9; G = 80.0e9; story_h = 3.5; P = 8.0e4
        A = 1.0e-2; J = 1.0e-6; nstory = 4
        mksec(I) = Section(A * u"m^2", E * u"Pa", G * u"Pa",
                           I * u"m^4", I * u"m^4", J * u"m^4")
        nodes = [Node([0.0u"m", 0.0u"m", (k * story_h)u"m"], k == 0 ? :fixed : :free)
                 for k in 0:nstory]
        els = [Element(nodes[k], nodes[k + 1], mksec(6.0e-4)) for k in 1:nstory]
        loads = [NodeForce(nodes[k + 1], [P * u"N", 0.0u"N", 0.0u"N"]) for k in 1:nstory]
        model = FrameModel(nodes, els, loads)
        solve!(model)

        story_dofs = [nodes[k + 1].globalID[1] for k in 1:nstory]   # x-DOF per story top
        # Baseline inter-story drifts, then tighten every limit to 65%.
        base = [drift_participation(model, d).δ for d in story_dofs]
        story0 = [base[1]; diff(base)]
        δ_allow = 0.65 .* story0

        Lvec = [ustrip(u"m", el.length) for el in model.elements]
        local res
        for _ in 1:12
            solve!(model)
            # Nodal participations → inter-story participation columns (exact by linearity).
            nodal = [drift_participation(model, d).c for d in story_dofs]
            C = zeros(nstory, nstory)
            C[:, 1] = nodal[1]
            for k in 2:nstory
                C[:, k] = nodal[k] .- nodal[k - 1]
            end
            s = [ustrip(u"m^4", el.section.Ix) for el in model.elements]
            res = drift_optimality_resize_multi(C, s, Lvec, fill(1.0e-8, nstory), δ_allow)
            for (i, el) in enumerate(model.elements)
                el.section = mksec(res.sizes[i])
            end
            Asap.update!(model; values_only = true)
        end
        solve!(model)
        u = [drift_participation(model, d).δ for d in story_dofs]
        story_final = [u[1]; diff(u)]
        @test all(story_final .≤ δ_allow .* (1 + 3e-2))     # every story feasible
        @test res.converged
    end
end
