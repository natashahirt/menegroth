using StructuralSizer
using Unitful
using Test
import JuMP
const MOI = JuMP.MOI

# ParetoScalarization: a dimensionless weighted sum of two objectives used to
# trace a Pareto front by continuation. Correctness is (1) the pure numeric
# contract of its objective_value, and (2) that its w=1 / w=0 anchors reproduce
# the two single-objective optima on a real multi-material MIP, with a genuine
# conflict between them.

@testset "ParetoScalarization objective_value (pure contract)" begin
    s = all_W()[60]
    mat = A992_Steel
    L = 2.0u"m"
    v = objective_value(MinVolume(), s, mat, L)      # m³
    c = objective_value(MinCarbon(), s, mat, L)      # kgCO₂e
    ref1 = 0.1u"m^3"
    ref2 = 50.0u"kgCO2e"

    @testset "weighted combination is exact and dimensionless" begin
        for w in (0.0, 0.25, 0.5, 0.75, 1.0)
            ps = ParetoScalarization(MinVolume(), MinCarbon(), w, ref1, ref2)
            got = objective_value(ps, s, mat, L)
            want = w * ustrip(Unitful.NoUnits, v / ref1) +
                   (1 - w) * ustrip(Unitful.NoUnits, c / ref2)
            @test got isa Real
            @test got ≈ want rtol = 1e-12
        end
    end

    @testset "anchors recover the component objectives (up to scale)" begin
        # w=1 ranks sections exactly by o1; w=0 exactly by o2.
        s2 = all_W()[120]
        p1 = ParetoScalarization(MinVolume(), MinCarbon(), 1.0, ref1, ref2)
        p0 = ParetoScalarization(MinVolume(), MinCarbon(), 0.0, ref1, ref2)
        vol_order = objective_value(MinVolume(), s, mat, L) < objective_value(MinVolume(), s2, mat, L)
        car_order = objective_value(MinCarbon(), s, mat, L) < objective_value(MinCarbon(), s2, mat, L)
        @test (objective_value(p1, s, mat, L) < objective_value(p1, s2, mat, L)) == vol_order
        @test (objective_value(p0, s, mat, L) < objective_value(p0, s2, mat, L)) == car_order
    end

    @testset "construction validation" begin
        @test_throws ArgumentError ParetoScalarization(MinVolume(), MinCarbon(), 1.5, ref1, ref2)
        @test_throws ArgumentError ParetoScalarization(MinVolume(), MinCarbon(), -0.1, ref1, ref2)
        @test_throws ArgumentError ParetoScalarization(MinVolume(), MinCarbon(), 0.5, -1.0u"m^3", ref2)
        @test_throws ArgumentError ParetoScalarization(MinVolume(), MinCarbon(), 0.5, ref1, 0.0u"kgCO2e")
    end
end

@testset "ParetoScalarization drives a multi-material MIP (weight ↔ carbon)" begin
    # Lightweight vs normalweight concrete at the SAME strength is a genuine
    # weight↔carbon conflict: LWC is lighter (ρ 1840 vs 2380) but higher embodied
    # carbon per volume (ecc 0.243 vs 0.127). Neither dominates.
    mats = [NWC_4000, LWC_4000]
    Pu = [600.0, 900.0]          # kip
    Mux = [60.0, 90.0]           # kip·ft
    geometries = [ConcreteMemberGeometry(3.66), ConcreteMemberGeometry(3.66)]

    solve(obj) = size_columns(Pu, Mux, geometries,
                              ConcreteColumnOptions(materials = mats, objective = obj,
                                                    include_biaxial = false))

    pure_w = solve(MinWeight())
    pure_c = solve(MinCarbon())
    @test pure_w.status == MOI.OPTIMAL || pure_w.status == MOI.TIME_LIMIT
    @test pure_c.status == MOI.OPTIMAL || pure_c.status == MOI.TIME_LIMIT

    # The single-objective optima pick opposite materials — the conflict exists.
    @test all(m -> m === LWC_4000, pure_w.materials_chosen)   # min weight → lightweight
    @test all(m -> m === NWC_4000, pure_c.materials_chosen)   # min carbon → normalweight
    @test pure_w.materials_chosen != pure_c.materials_chosen

    # Scalarization anchors reproduce those optima (refs > 0; argmin is ref-invariant
    # at the extremes).
    ref_w = 1.0u"kg"
    ref_c = 1.0u"kgCO2e"
    anchor_w = solve(ParetoScalarization(MinWeight(), MinCarbon(), 1.0, ref_w, ref_c))
    anchor_c = solve(ParetoScalarization(MinWeight(), MinCarbon(), 0.0, ref_w, ref_c))
    @test anchor_w.materials_chosen == pure_w.materials_chosen
    @test anchor_c.materials_chosen == pure_c.materials_chosen

    # An intermediate weight stays within the material menu and feasible.
    mid = solve(ParetoScalarization(MinWeight(), MinCarbon(), 0.5, ref_w, ref_c))
    @test mid.status == MOI.OPTIMAL || mid.status == MOI.TIME_LIMIT
    @test all(m -> m === NWC_4000 || m === LWC_4000, mid.materials_chosen)
end
