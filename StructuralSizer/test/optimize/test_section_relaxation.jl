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
end
