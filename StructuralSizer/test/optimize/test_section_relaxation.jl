using StructuralSizer
using Asap
using Test
using Unitful

# Continuous-section scaling laws + catalog projection (Workstream R.1). Synthetic
# tests exercise the pure numerics — exact power-law recovery, the marginal
# dA/dI that feeds the drift resizer, monotone projection, band clamping, and the
# optimality gap — then a real RC-column catalog smoke test closes the loop.

@testset "section relaxation (scaling laws + projection)" begin

    @testset "exact power-law recovery" begin
        # A = 3·I^0.5 exactly ⇒ the log–log fit must recover slope 0.5, ln(3).
        I = [1.0e-4, 2.0e-4, 4.0e-4, 8.0e-4]
        A = 3.0 .* sqrt.(I)
        law = fit_section_scaling_law(I, A)
        @test law.logA_fit[2] ≈ 0.5 rtol = 1e-12          # slope b_A
        @test exp(law.logA_fit[1]) ≈ 3.0 rtol = 1e-12     # coefficient exp(a_A)
        # continuous_area reproduces the generating law at and between the nodes.
        @test continuous_area(law, 2.0e-4) ≈ 3.0 * sqrt(2.0e-4) rtol = 1e-12
        @test continuous_area(law, 3.0e-4) ≈ 3.0 * sqrt(3.0e-4) rtol = 1e-12
    end

    @testset "marginal area dA/dI = b·A/I feeds the drift weight" begin
        I = [1.0e-4, 2.0e-4, 4.0e-4, 8.0e-4]
        A = 3.0 .* sqrt.(I)                                # b = 0.5
        law = fit_section_scaling_law(I, A)
        It = 2.5e-4
        @test marginal_area(law, It) ≈ 0.5 * continuous_area(law, It) / It rtol = 1e-12
        # Finite-difference check of the derivative.
        h = 1.0e-9
        fd = (continuous_area(law, It + h) - continuous_area(law, It - h)) / (2h)
        @test marginal_area(law, It) ≈ fd rtol = 1e-4
    end

    @testset "plastic modulus fit" begin
        I = [1.0e-4, 2.0e-4, 4.0e-4, 8.0e-4]
        A = 3.0 .* sqrt.(I)
        Z = 5.0 .* I .^ 0.75
        law = fit_section_scaling_law(I, A; Z = Z)
        @test law.logZ_fit[2] ≈ 0.75 rtol = 1e-12
        @test continuous_modulus(law, 3.0e-4) ≈ 5.0 * (3.0e-4)^0.75 rtol = 1e-12
        # Without Z, continuous_modulus must refuse rather than return garbage.
        law_noZ = fit_section_scaling_law(I, A)
        @test_throws ArgumentError continuous_modulus(law_noZ, 3.0e-4)
    end

    @testset "projection picks the lightest section meeting the target" begin
        I = [1.0e-4, 2.0e-4, 4.0e-4, 8.0e-4]
        A = 3.0 .* sqrt.(I)
        law = fit_section_scaling_law(I, A)      # sorted ascending in I
        # Target between entries 2 and 3 ⇒ lightest feasible is entry 3 (I = 4e-4).
        idx = project_to_catalog(law, 3.0e-4)
        @test idx == 3
        @test law.I[idx] ≥ 3.0e-4
        # Exactly on a node snaps to that node, not the next.
        @test project_to_catalog(law, 2.0e-4) == 2
        # Beyond the catalog ⇒ needs growth.
        @test project_to_catalog(law, 1.0) === nothing
    end

    @testset "candidate band clamps to catalog bounds" begin
        I = [1.0e-4, 2.0e-4, 4.0e-4, 8.0e-4]
        A = 3.0 .* sqrt.(I)
        law = fit_section_scaling_law(I, A)
        @test candidate_band(law, 3, 1) == 2:4
        @test candidate_band(law, 1, 2) == 1:3          # clamped at the low end
        @test candidate_band(law, 4, 2) == 2:4          # clamped at the high end
        @test candidate_band(law, 2, 0) == 2:2          # zero-width band = the pick
        @test_throws ArgumentError candidate_band(law, 5, 1)
        @test_throws ArgumentError candidate_band(law, 2, -1)
    end

    @testset "projection gap is small and non-negative on a convex family" begin
        # Area strictly convex in log space ⇒ catalog area ≥ continuous price.
        I = [1.0e-4, 2.0e-4, 4.0e-4, 8.0e-4]
        A = 3.0 .* sqrt.(I)
        law = fit_section_scaling_law(I, A)
        for It in (1.3e-4, 2.7e-4, 5.1e-4)
            idx = project_to_catalog(law, It)
            @test idx !== nothing
            gap = projection_gap(law, It, idx)
            @test gap ≥ -1e-12                           # snap up, never below the price
            @test gap < 1.5                              # within ~one catalog step
        end
    end

    @testset "input validation" begin
        @test_throws ArgumentError fit_section_scaling_law([1.0e-4], [1.0e-3])          # < 2 points
        @test_throws ArgumentError fit_section_scaling_law([1.0e-4, 2.0e-4], [1.0e-3])  # length mismatch
        @test_throws ArgumentError fit_section_scaling_law([1.0e-4, 1.0e-4], [1.0, 2.0]) # I not distinct
        @test_throws ArgumentError fit_section_scaling_law([1.0e-4, -2.0e-4], [1.0, 2.0]) # non-positive I
    end

    @testset "warm start maps sorted projection back to catalog order" begin
        # Catalog deliberately OUT OF ORDER in I, to exercise the permutation.
        #   catalog idx:   1      2      3      4
        #   I (m⁴):      4e-4   1e-4   8e-4   2e-4
        I_cat = [4.0e-4, 1.0e-4, 8.0e-4, 2.0e-4]
        A_cat = 3.0 .* sqrt.(I_cat)
        # Two groups: target between 1e-4 and 2e-4 ⇒ catalog idx 4 (I=2e-4);
        #             target just above 4e-4       ⇒ catalog idx 3 (I=8e-4).
        ws = relaxation_warm_start(I_cat, A_cat, [1.5e-4, 4.1e-4]; k = 1)
        @test ws.mip_start == [4, 3]
        @test I_cat[ws.mip_start[1]] ≥ 1.5e-4
        @test I_cat[ws.mip_start[2]] ≥ 4.1e-4
        # The projected index is always inside its own band.
        @test ws.mip_start[1] ∈ ws.band[1]
        @test ws.mip_start[2] ∈ ws.band[2]
        # Band around catalog idx 4 (I=2e-4, sorted rank 2) spans sorted ranks 1..3
        # = I ∈ {1e-4, 2e-4, 4e-4} = catalog idx {2, 4, 1}, returned sorted.
        @test ws.band[1] == [1, 2, 4]
        @test all(ws.gap .≥ -1e-12)
        @test !any(ws.grown)
    end

    @testset "warm start flags targets beyond the catalog" begin
        I_cat = [1.0e-4, 2.0e-4, 4.0e-4]
        A_cat = 3.0 .* sqrt.(I_cat)
        ws = relaxation_warm_start(I_cat, A_cat, [10.0]; k = 1)   # unreachable target
        @test ws.grown == [true]
        @test ws.mip_start == [3]                                # clamped to stiffest
        @test_throws ArgumentError relaxation_warm_start(I_cat, A_cat, [0.0])  # non-positive target
        @test_throws ArgumentError relaxation_warm_start(I_cat, A_cat[1:2], [1.0e-4]) # length mismatch
    end

    @testset "certified lower bound is a true lower envelope (synthetic)" begin
        I_cat = [1.0e-4, 2.0e-4, 4.0e-4, 8.0e-4]
        A_cat = 3.0 .* sqrt.(I_cat)
        law = fit_section_scaling_law(I_cat, A_cat)
        targets = [1.3e-4, 2.7e-4, 5.1e-4]
        lengths = [6.0, 8.0, 10.0]
        lb = relaxation_lower_bound(law, targets, lengths)
        # The discrete (projected) volume must be ≥ the certified bound.
        ws = relaxation_warm_start(I_cat, A_cat, targets; k = 0)
        disc_vol = sum(A_cat[ws.mip_start[g]] * lengths[g] for g in 1:length(targets))
        @test disc_vol ≥ lb
        @test optimality_gap(disc_vol, lb) ≥ -1e-12
        @test optimality_gap(lb, lb) ≈ 0.0 atol = 1e-12
        @test_throws ArgumentError optimality_gap(1.0, 0.0)
        @test_throws ArgumentError relaxation_lower_bound(law, targets, lengths[1:2])
    end

    @testset "lower envelope ≤ lightest feasible on a SCATTERED catalog" begin
        # The failure mode a real catalog exposes: area is NOT a tight function of I.
        # Two families at each stiffness — an efficient deep section and a stocky one —
        # so a least-squares price would sit ABOVE the efficient sections. The convex
        # envelope must still never exceed the lightest feasible section.
        I_cat = Float64[]
        A_cat = Float64[]
        for i in 1:12
            Iv = 1.0e-4 * i
            push!(I_cat, Iv); push!(A_cat, 2.0 * sqrt(Iv))          # efficient frontier
            push!(I_cat, Iv); push!(A_cat, 3.2 * sqrt(Iv))          # stocky, same I
        end
        law = fit_section_scaling_law(I_cat, A_cat)
        for t in range(1.1e-4, 1.15e-3; length = 40)
            lb_area = catalog_lower_envelope(law, t)
            feasible = [A_cat[j] for j in eachindex(I_cat) if I_cat[j] ≥ t]
            @test !isempty(feasible)
            @test lb_area ≤ minimum(feasible) + 1e-15           # a TRUE lower bound
        end
    end

    @testset "real RC-column catalog smoke test" begin
        cat = rc_column_catalog(:rect, :standard)
        @test length(cat) ≥ 2
        Ivals = [ustrip(u"m^4", moment_of_inertia(s; axis = :x)) for s in cat]
        Avals = [ustrip(u"m^2", section_area(s)) for s in cat]
        law = fit_section_scaling_law(Ivals, Avals)
        # A grows with I ⇒ a positive scaling exponent.
        @test law.logA_fit[2] > 0
        # Project a target just above the median stiffness; the pick must meet it.
        target = sort(Ivals)[cld(length(Ivals), 2)] * 1.1
        idx = project_to_catalog(law, target)
        if idx === nothing
            @test target > maximum(Ivals)                # only if beyond the catalog
        else
            @test law.I[idx] ≥ target
            @test candidate_band(law, idx, 2) ⊆ 1:length(law.I)
        end
    end

    @testset "lower envelope certified on the real W catalog" begin
        # Regression guard for the scatter bug the continuation sweep exposed: on the
        # full W catalog the certified bound must never exceed the lightest feasible.
        cat = steel_column_catalog(:w, :all)
        Ivals = [ustrip(u"m^4", Ix(s)) for s in cat]
        Avals = [ustrip(u"m^2", section_area(s)) for s in cat]
        law = fit_section_scaling_law(Ivals, Avals)
        lo, hi = minimum(Ivals), maximum(Ivals)
        for t in range(lo * 1.001, hi * 0.999; length = 60)
            lb_area = catalog_lower_envelope(law, t)
            feasible = [Avals[j] for j in eachindex(Ivals) if Ivals[j] ≥ t]
            @test lb_area ≤ minimum(feasible) + 1e-12
        end
    end
end

# ==============================================================================
# SAFETY CONTRACT (O1): the relaxation only GUIDES — it can never write a final
# size. Every size the owner returns comes from the checker-certified MIP, so an
# F0 warm-start hint (`mip_start`) or an infeasible section admitted into the
# candidate band (`feasible`) can at most SHORTEN the solve; it can never cause an
# unsafe (under-capacity) section to be selected. This is the invariant that lets
# the whole relaxation-guided pipeline front-run the expensive solver without
# compromising the independent full-fidelity verification.
# ==============================================================================
@testset "relaxation safety: F0 hints never write an unsafe final size" begin
    # Deflection-governed single group, so feasibility ⇔ Ix ≥ I_required and the
    # safe/unsafe boundary is unambiguous (see relaxation_warmstart_benchmark.jl).
    DEFLECTION_LIMIT = 1 / 360
    catalog = steel_column_catalog(:w, :all)
    Ix_cat  = [ustrip(u"m^4", Ix(s)) for s in catalog]
    L = 8.0

    # Target stiffness at the catalog median; encode it through the L/360 check
    # (I_ref = 1 ⇒ feasible ⇔ Ix ≥ I_required). A tiny moment keeps strength live.
    I_required = sort(Ix_cat)[cld(length(Ix_cat), 2)] * 1.0005
    demand = MemberDemand(1; Mux = 5.0e3,
                          δ_max_LL = I_required * DEFLECTION_LIMIT * L, I_ref = 1.0)
    geom = SteelMemberGeometry(L; Lb = L)
    checker = AISCChecker(; deflection_limit = DEFLECTION_LIMIT)
    solve(; kw...) = optimize_discrete(checker, [demand], [geom], catalog, A992_Steel;
                                       objective = MinVolume(), kw...)

    cold = solve()
    cold_idx = cold.section_indices[1]
    @test Ix_cat[cold_idx] ≥ I_required                 # the certified pick is safe

    # A deliberately UNSAFE hint: the stiffness-smallest section (Ix ≪ I_required).
    unsafe_idx = argmin(Ix_cat)
    @test Ix_cat[unsafe_idx] < I_required               # confirm the seed is infeasible

    # (1) An infeasible `mip_start` is a pure hint: the solver discards it and
    #     still returns the checker-certified optimum, never the unsafe seed.
    warm = solve(mip_start = [unsafe_idx])
    @test warm.section_indices == cold.section_indices
    @test Ix_cat[warm.section_indices[1]] ≥ I_required
    @test warm.section_indices[1] != unsafe_idx

    # (2) An infeasible section admitted into the candidate band is screened out by
    #     the internal capacity check (the band only INTERSECTS screening, never
    #     substitutes for it): the result is still safe, never the unsafe section.
    banded = solve(feasible = [[unsafe_idx, cold_idx]])
    @test banded.section_indices == cold.section_indices
    @test Ix_cat[banded.section_indices[1]] ≥ I_required
    @test banded.section_indices[1] != unsafe_idx

    # (3) A band containing ONLY infeasible sections cannot fabricate a feasible
    #     answer — the owner REFUSES (raises) rather than returning an unsafe size.
    @test_throws ArgumentError solve(feasible = [[unsafe_idx]])
end
