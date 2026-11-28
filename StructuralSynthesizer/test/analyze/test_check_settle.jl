# Choosing a section from a cycle is pass/fail, then cost.

using Test
using Unitful
using StructuralSynthesizer

const SS = StructuralSynthesizer

@testset "a cycling beam loop settles by checking" begin
    @test SS._infeasible_group_indices(ArgumentError(
        "No feasible sections for group 3: moment")) == [3]
    @test SS._infeasible_group_indices(ArgumentError(
        "No feasible sections for group(s) [2, 5]: shear")) == [2, 5]
    @test SS._infeasible_group_indices(ArgumentError("catalog is empty")) === nothing

    # Passing sections are eligible. The cheaper one is kept.
    picked = SS._pick_group_section([(:heavy, false, 5.0), (:mid, true, 3.0), (:light, true, 1.0)])
    @test picked.section === :light
    @test picked.passed

    # A group that passed in none keeps the costliest section.
    picked = SS._pick_group_section([(:light, false, 1.0), (:heavy, false, 4.0)])
    @test picked.section === :heavy
    @test !picked.passed

    # Equal cost: the later passing section replaces the earlier one only when cheaper.
    picked = SS._pick_group_section([(:a, true, 2.0), (:b, true, 2.0)])
    @test picked.section === :a

    # A `do` block is the checker. The sizer's group number is a position in
    # the vector it was given, and that position maps back to `pending`.
    failed = SS._pinned_failures([10, 20, 30]) do left
        bad = findfirst(==(20), left)
        bad === nothing && return
        throw(ArgumentError("No feasible sections for group $bad: moment"))
    end
    @test failed == [20]
    @test SS._pinned_failures([1, 2]) do left
        nothing
    end == Int[]

    # Eligible states are 1 and 3. State 3 is the cheaper of those two.
    @test SS._cheapest_index([13620.8, 13574.5, 13612.1], [1, 3]) == 3
    @test SS._cheapest_index([13620.8, 13574.5, 13612.1], [1, 2]) == 2

    # The flexure ratio belongs to the ACI check with the higher ratio.
    # Those checks store moment in kip·ft.
    expl = StructuralSizer.FeasibilityExplanation(true, StructuralSizer.CheckResult[
        StructuralSizer.CheckResult("flexure", true, 0.40, 100.0, 250.0, "ACI 318-11 10.2"),
        StructuralSizer.CheckResult("flexure_neg", true, 0.90, 300.0, 333.0, "ACI 318-11 10.2"),
        StructuralSizer.CheckResult("shear", true, 0.20, 40.0, 200.0, "ACI 318-11 11.2"),
    ], "flexure_neg", 0.90)
    @test SS._aci_flexure_demand(expl) == 300.0
    result = SS.BeamDesignResult()
    SS._apply_beam_check!(result, expl)
    @test result.flexure_ratio == 0.90
    @test ustrip(u"kip*ft", result.check_Mu) ≈ 300.0
end
