using StructuralSizer
using Unitful
using Test
import JuMP
const MOI = JuMP.MOI

# ε-constraint Pareto front. The headline property a weighted-sum scalarization
# CANNOT match: recovering a NON-SUPPORTED Pareto point — one that lies above the
# lower convex hull of the objective space and is therefore never the unique
# minimum of any weighted sum. We build three steel "materials" with identical
# strength/stiffness (so feasibility is identical and only the objective differs)
# whose (ρ, ecc) place the middle material strictly above the weight↔carbon hull
# line. ε-constraint must find all three; scalarization must find only two.

# Identical E/G/Fy/Fu/ν ⇒ identical AISC capacity; only ρ (weight) and ecc (carbon)
# differ. Per unit (area × length): weight ∝ ρ, carbon ∝ ρ·ecc.
#   mat_light:  (ρ, ecc) = (2000, 5.0)   → (w, c) ∝ (2000, 10000)   — min weight
#   mat_mid:    (ρ, ecc) = (6000, 1.5)   → (w, c) ∝ (6000,  9000)   — NON-supported
#   mat_heavy:  (ρ, ecc) = (10000, 0.2)  → (w, c) ∝ (10000, 2000)   — min carbon
# Hull line light→heavy at w=6000 gives c=6000; mat_mid sits at c=9000 > 6000.
_steel(ρ, ecc) = StructuralSteel(29000.0u"ksi", 11200.0u"ksi", 50.0u"ksi", 65.0u"ksi",
                                 ρ * u"kg/m^3", 0.29, ecc * u"kgCO2e/kg")
const MAT_LIGHT = _steel(2000.0, 5.0)
const MAT_MID   = _steel(6000.0, 1.5)
const MAT_HEAVY = _steel(10000.0, 0.2)

# A single moderately-loaded group — many W sections feasible, so the chosen SHAPE
# is identical across materials and the front is purely the material trade-off.
const _CAT = all_W()
const _DEM = [MemberDemand(1; Mux = 120.0e3)]
const _GEO = [SteelMemberGeometry(5.0; Lb = 5.0)]
const _CHK = AISCChecker()

@testset "ε-constraint budget mechanics (single material)" begin
    cat = all_W()
    checker = AISCChecker()
    dem = [MemberDemand(1; Mux = 120.0e3), MemberDemand(2; Mux = 220.0e3)]
    geo = [SteelMemberGeometry(5.0; Lb = 5.0), SteelMemberGeometry(6.0; Lb = 6.0)]

    base = optimize_discrete(checker, dem, geo, cat, A992_Steel; objective = MinVolume())
    @test base.status == MOI.OPTIMAL

    @testset "budget = nothing reproduces the unconstrained solve byte-for-byte" begin
        b = optimize_discrete(checker, dem, geo, cat, A992_Steel;
                              objective = MinVolume(), budget = nothing)
        @test b.section_indices == base.section_indices
        @test b.objective_value == base.objective_value
    end

    # `budget_value` lives in the SAME unit-stripped scale as the MIP objective
    # (the cache's per-section coefficient × length in metres), so references are
    # taken from a solve's own `objective_value`, never recomputed in canonical
    # units. Volume/weight/carbon are collinear within one material, so the
    # secondary optimum coincides with the primary.
    @testset "same-objective budget (clean volume scale)" begin
        vol_opt = base.objective_value
        loose = optimize_discrete(checker, dem, geo, cat, A992_Steel;
                                  objective = MinVolume(), budget = (MinVolume(), vol_opt * 10))
        @test loose.status == MOI.OPTIMAL
        @test loose.section_indices == base.section_indices           # loose ⇒ unconstrained optimum
        @test loose.objective_value ≈ vol_opt rtol = 1e-9

        tight = optimize_discrete(checker, dem, geo, cat, A992_Steel;
                                  objective = MinVolume(), budget = (MinVolume(), vol_opt * 0.5))
        @test isempty(tight.section_indices)                          # below optimum ⇒ infeasible
        @test tight.objective_value == Inf
        @test tight.status == MOI.INFEASIBLE || tight.status == MOI.INFEASIBLE_OR_UNBOUNDED
    end

    @testset "cross-objective budget (minimize volume, bound carbon)" begin
        # Reference the carbon optimum from its OWN solve so the budget is on the
        # exact scale the constraint uses (a cross-unit recompute would mis-scale).
        carbon_ref = optimize_discrete(checker, dem, geo, cat, A992_Steel;
                                       objective = MinCarbon()).objective_value

        loose = optimize_discrete(checker, dem, geo, cat, A992_Steel;
                                  objective = MinVolume(), budget = (MinCarbon(), carbon_ref * 10))
        @test loose.status == MOI.OPTIMAL
        @test loose.section_indices == base.section_indices           # collinear ⇒ same design

        tight = optimize_discrete(checker, dem, geo, cat, A992_Steel;
                                  objective = MinVolume(), budget = (MinCarbon(), carbon_ref * 0.5))
        @test isempty(tight.section_indices)                          # carbon floor ⇒ infeasible
        @test tight.status == MOI.INFEASIBLE || tight.status == MOI.INFEASIBLE_OR_UNBOUNDED
    end
end

@testset "single-material pareto_front collapses to one point (aligned objectives)" begin
    front = pareto_front(_CHK, _DEM, _GEO, _CAT, A992_Steel;
                         objective1 = MinWeight(), objective2 = MinCarbon(), n_points = 7)
    @test length(front) == 1               # weight & carbon collinear ⇒ single optimum
    @test front[1].material_indices === nothing
end

@testset "ε-constraint recovers a NON-SUPPORTED Pareto point (vs scalarization)" begin
    mats = [MAT_LIGHT, MAT_MID, MAT_HEAVY]
    front = pareto_front(_CHK, _DEM, _GEO, _CAT, mats;
                         objective1 = MinWeight(), objective2 = MinCarbon(), n_points = 11)

    @testset "all three materials appear on the front" begin
        @test length(front) == 3
        @test all(p -> p.status == MOI.OPTIMAL, front)
        chosen = Set(only(p.material_indices) for p in front)   # 1 group ⇒ one index each
        @test chosen == Set([1, 2, 3])
    end

    @testset "front is a valid non-dominated set (sorted, strictly trading off)" begin
        for i in 1:(length(front) - 1)
            @test front[i].objective1 < front[i + 1].objective1       # weight increasing
            @test front[i].objective2 > front[i + 1].objective2       # carbon decreasing
        end
    end

    @testset "the middle point is genuinely non-supported (above the hull line)" begin
        p1, p2, p3 = front                      # sorted by increasing weight
        # Linear interpolation of carbon between the two extreme designs at p2's weight.
        t = (p2.objective1 - p1.objective1) / (p3.objective1 - p1.objective1)
        hull_carbon = p1.objective2 + t * (p3.objective2 - p1.objective2)
        @test p2.objective2 > hull_carbon * (1 + 1e-6)              # strictly above ⇒ non-convex
        @test only(p2.material_indices) == 2                       # it is MAT_MID
    end

    @testset "a weighted-sum scalarization provably MISSES the middle point" begin
        # Sweep the full weight range; collect the distinct materials scalarization
        # ever selects. The non-supported MAT_MID is never a weighted-sum minimum.
        ref_w = 1.0u"kg"
        ref_c = 1.0u"kgCO2e"
        selected = Set{Int}()
        for w in 0.0:0.02:1.0
            ps = ParetoScalarization(MinWeight(), MinCarbon(), w, ref_w, ref_c)
            r = optimize_discrete(_CHK, _DEM, _GEO, _CAT, mats; objective = ps)
            push!(selected, only(r.material_indices))
        end
        @test selected == Set([1, 3])          # only the two supported anchors
        @test 2 ∉ selected                     # MAT_MID invisible to scalarization
    end
end

@testset "multi-material pareto_front forwards n_max_sections" begin
    # Two groups, three materials; cap the number of unique (section, material)
    # pairs. The front must still be non-dominated and every point must respect
    # the cap — exercising the kwarg-forwarding path through optimize_discrete.
    dem = [MemberDemand(1; Mux = 120.0e3), MemberDemand(2; Mux = 260.0e3)]
    geo = [SteelMemberGeometry(5.0; Lb = 5.0), SteelMemberGeometry(6.0; Lb = 6.0)]
    mats = [MAT_LIGHT, MAT_MID, MAT_HEAVY]
    front = pareto_front(_CHK, dem, geo, _CAT, mats;
                         objective1 = MinWeight(), objective2 = MinCarbon(),
                         n_points = 9, n_max_sections = 2, time_limit_sec = 60.0)
    @test !isempty(front)
    for p in front
        @test p.status == MOI.OPTIMAL
        pairs = Set(zip(p.section_indices, p.material_indices))
        @test length(pairs) ≤ 2
    end
    for i in 1:(length(front) - 1)
        @test front[i].objective1 ≤ front[i + 1].objective1 + 1e-9
        @test front[i].objective2 ≥ front[i + 1].objective2 - 1e-9
    end
end
