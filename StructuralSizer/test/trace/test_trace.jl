# Tests for solver decision trace infrastructure and explain_feasibility
#
# Covers:
#   1. TraceCollector / TraceEvent / emit!
#   2. @traced macro and TRACE_REGISTRY
#   3. explain_feasibility for AISC, ACI columns, ACI beams

using Test
using Unitful
using StructuralSizer
using StructuralSizer.Asap: kip, ksi

# ==============================================================================
# 1. TraceCollector / TraceEvent / emit!
# ==============================================================================

@testset "TraceCollector basics" begin
    tc = TraceCollector()
    @test tc.enabled
    @test isempty(tc.events)
    @test tc.start_time > 0

    emit!(tc, :pipeline, "test_stage", "elem_1", :enter; foo="bar", n=42)
    @test length(tc.events) == 1

    ev = tc.events[1]
    @test ev.layer == :pipeline
    @test ev.stage == "test_stage"
    @test ev.element_id == "elem_1"
    @test ev.event_type == :enter
    @test ev.data["foo"] == "bar"
    @test ev.data["n"] == 42
    @test ev.timestamp >= 0.0
end

@testset "TraceCollector disabled" begin
    tc = TraceCollector(; enabled=false)
    emit!(tc, :optimizer, "stage", "elem", :decision; x=1)
    @test isempty(tc.events)
end

@testset "emit! on nothing is no-op" begin
    @test emit!(nothing, :pipeline, "stage", "elem", :enter) === nothing
end

@testset "TraceCollector reset!" begin
    tc = TraceCollector()
    emit!(tc, :slab, "size_flat_plate!", "slab_1", :enter)
    emit!(tc, :slab, "size_flat_plate!", "slab_1", :exit)
    @test length(tc.events) == 2

    reset!(tc)
    @test isempty(tc.events)
end

@testset "Multiple events accumulate in order" begin
    tc = TraceCollector()
    for i in 1:10
        emit!(tc, :workflow, "iteration", "beam_col", :iteration; iter=i)
    end
    @test length(tc.events) == 10
    @test tc.events[1].data["iter"] == 1
    @test tc.events[10].data["iter"] == 10
    @test tc.events[1].timestamp <= tc.events[10].timestamp
end

# ==============================================================================
# 2. @traced macro and TRACE_REGISTRY
# ==============================================================================

@testset "@traced macro registers functions" begin
    # Define a test function with @traced
    @traced layer=:sizing events=[:enter, :exit] function _test_traced_func(x)
        return x + 1
    end

    # Verify it works as a normal function
    @test _test_traced_func(5) == 6

    # Verify it was registered
    key = (:_test_traced_func, :sizing)
    @test haskey(TRACE_REGISTRY, key)

    meta = TRACE_REGISTRY[key]
    @test meta.func_name == :_test_traced_func
    @test meta.layer == :sizing
    @test meta.events == [:enter, :exit]
    @test meta.companion === nothing
end

@testset "@traced with companion" begin
    @traced layer=:checker companion=:_test_explain events=[:enter, :exit] function _test_is_feasible_traced(x)
        return x > 0
    end

    key = (:_test_is_feasible_traced, :checker)
    @test haskey(TRACE_REGISTRY, key)
    meta = TRACE_REGISTRY[key]
    @test meta.companion == :_test_explain
end

@testset "registered_functions returns the registry" begin
    reg = registered_functions()
    @test reg isa Dict
    @test length(reg) >= 2  # at least the two we just defined

    # Verify manual registry entries for docstring-annotated functions
    @test haskey(reg, (:optimize_discrete, :optimizer))
    @test haskey(reg, (:optimize_discrete_multi, :optimizer))
    @test haskey(reg, (:size_flat_plate!, :slab))

    od_meta = reg[(:optimize_discrete, :optimizer)]
    @test :enter in od_meta.events
    @test :exit in od_meta.events
    @test :decision in od_meta.events

    sfp_meta = reg[(:size_flat_plate!, :slab)]
    @test :iteration in sfp_meta.events
    @test :fallback in sfp_meta.events
end

# ==============================================================================
# 3. explain_feasibility — AISC
# ==============================================================================

@testset "explain_feasibility AISC — feasible section" begin
    section = W("W14X22")
    material = A992_Steel
    L = 3.6576  # 12 ft
    geometry = SteelMemberGeometry(L; Lb=L, Cb=1.0, Kx=1.0, Ky=1.0, braced=true)

    checker = AISCChecker()
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinWeight())

    demand = MemberDemand(1;
        Pu_c = 50.0u"kN",
        Mux = 50.0u"kN*m",
        M1x = 0.0u"kN*m",
        M2x = 50.0u"kN*m",
    )

    # Verify is_feasible agrees
    feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand, geometry)

    expl = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, demand, geometry)
    @test expl.passed == feasible
    @test length(expl.checks) >= 4  # depth, shear_strong, shear_weak, pm_interaction_compression, pm_interaction_tension
    @test expl.governing_check isa String
    @test expl.governing_ratio isa Float64

    # All checks should pass for a feasible section
    if feasible
        @test all(c -> c.passed, expl.checks)
        @test expl.governing_ratio <= 1.0
    end

    # Check that known check names appear
    check_names = [c.name for c in expl.checks]
    @test "depth" in check_names
    @test "shear_strong" in check_names
    @test "pm_interaction_compression" in check_names
end

@testset "explain_feasibility AISC — infeasible section (high demand)" begin
    section = W("W14X22")  # small section
    material = A992_Steel
    L = 3.6576
    geometry = SteelMemberGeometry(L; Lb=L, Cb=1.0, Kx=1.0, Ky=1.0, braced=true)

    checker = AISCChecker()
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinWeight())

    demand_heavy = MemberDemand(1;
        Pu_c = 2000.0u"kN",
        Mux = 500.0u"kN*m",
        M1x = -500.0u"kN*m",
        M2x = 500.0u"kN*m",
    )

    feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand_heavy, geometry)
    expl = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, demand_heavy, geometry)

    @test !feasible
    @test !expl.passed
    @test expl.governing_ratio > 1.0

    # At least one check should fail
    @test any(c -> !c.passed, expl.checks)
end

@testset "explain_feasibility AISC — with deflection checks" begin
    section = W("W14X22")
    material = A992_Steel
    L = 9.144  # 30 ft
    geometry = SteelMemberGeometry(L; Lb=L, Cb=1.0, Kx=1.0, Ky=1.0, braced=true)

    checker = AISCChecker(; deflection_limit=1/360, total_deflection_limit=1/240)
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinWeight())

    Ix_ref = StructuralSizer.to_meters_fourth(StructuralSizer.Ix(section))
    demand = MemberDemand(1;
        Mux = 100.0u"kN*m",
        δ_max_LL = 0.03u"m",
        δ_max_total = 0.05u"m",
        I_ref = Ix_ref * u"m^4",
    )

    expl = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, demand, geometry)
    check_names = [c.name for c in expl.checks]
    @test "deflection_ll" in check_names
    @test "deflection_total" in check_names
end

# ==============================================================================
# 4. explain_feasibility — ACI Columns
# ==============================================================================

@testset "explain_feasibility ACI Column — feasible" begin
    sections = standard_rc_columns()
    section = sections[5]  # medium-sized column
    material = NWC_4000

    Lu_m = StructuralSizer.to_meters(10.0u"ft")
    geometry = ConcreteMemberGeometry(Lu_m; k=1.0)

    checker = ACIColumnChecker(; fy_ksi=60.0, Es_ksi=29000.0)
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinVolume())

    demand = RCColumnDemand(1;
        Pu = 100.0 * kip,
        Mux = 50.0 * kip * u"ft",
        M1x = 0.0 * kip * u"ft",
        M1y = 0.0 * kip * u"ft",
    )

    feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand, geometry)
    expl = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, demand, geometry)

    @test expl.passed == feasible
    @test length(expl.checks) >= 2  # depth + pm_interaction_x at minimum

    check_names = [c.name for c in expl.checks]
    @test "depth" in check_names
    @test "pm_interaction_x" in check_names
end

@testset "explain_feasibility ACI Column — infeasible (heavy demand)" begin
    sections = standard_rc_columns()
    section = sections[1]  # smallest column
    material = NWC_4000

    Lu_m = StructuralSizer.to_meters(12.0u"ft")
    geometry = ConcreteMemberGeometry(Lu_m; k=1.0)

    checker = ACIColumnChecker(; fy_ksi=60.0, Es_ksi=29000.0)
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinVolume())

    demand = RCColumnDemand(1;
        Pu = 1500.0 * kip,
        Mux = 800.0 * kip * u"ft",
        M1x = 0.0 * kip * u"ft",
        M1y = 0.0 * kip * u"ft",
    )

    feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand, geometry)
    expl = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, demand, geometry)

    @test !feasible
    @test !expl.passed
    @test expl.governing_ratio > 1.0
end

@testset "explain_feasibility ACI Column — biaxial" begin
    sections = standard_rc_columns()
    section = sections[5]
    material = NWC_4000

    Lu_m = StructuralSizer.to_meters(10.0u"ft")
    geometry = ConcreteMemberGeometry(Lu_m; k=1.0)

    checker = ACIColumnChecker(; fy_ksi=60.0, Es_ksi=29000.0, include_biaxial=true)
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinVolume())

    demand = RCColumnDemand(1;
        Pu = 200.0 * kip,
        Mux = 80.0 * kip * u"ft",
        Muy = 60.0 * kip * u"ft",
        M1x = 0.0 * kip * u"ft",
        M1y = 0.0 * kip * u"ft",
    )

    expl = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, demand, geometry)
    check_names = [c.name for c in expl.checks]
    @test "biaxial_bresler" in check_names
end

# ==============================================================================
# 5. explain_feasibility — ACI Beams
# ==============================================================================

@testset "explain_feasibility ACI Beam — feasible" begin
    sections = StructuralSizer.standard_rc_beams()
    section = sections[5]  # medium beam
    material = NWC_4000

    L_m = StructuralSizer.to_meters(20.0u"ft")
    geometry = ConcreteMemberGeometry(L_m)

    checker = ACIBeamChecker()
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinVolume())

    demand = RCBeamDemand(1;
        Mu = 50.0 * kip * u"ft",
        Vu = 15.0 * kip,
    )

    feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand, geometry)
    expl = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, demand, geometry)

    @test expl.passed == feasible
    @test length(expl.checks) >= 4  # depth, flexure, shear, net_tensile_strain, min_reinforcement

    check_names = [c.name for c in expl.checks]
    @test "depth" in check_names
    @test "flexure" in check_names
    @test "shear" in check_names
    @test "min_reinforcement" in check_names
end

@testset "explain_feasibility ACI Beam — infeasible (heavy moment)" begin
    sections = StructuralSizer.standard_rc_beams()
    section = sections[1]  # smallest beam
    material = NWC_4000

    L_m = StructuralSizer.to_meters(30.0u"ft")
    geometry = ConcreteMemberGeometry(L_m)

    checker = ACIBeamChecker()
    catalog = [section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinVolume())

    demand = RCBeamDemand(1;
        Mu = 500.0 * kip * u"ft",
        Vu = 100.0 * kip,
    )

    feasible = StructuralSizer.is_feasible(checker, cache, 1, section, material, demand, geometry)
    expl = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, demand, geometry)

    @test !feasible
    @test !expl.passed
    @test any(c -> !c.passed, expl.checks)
    @test expl.governing_ratio > 1.0
end

# ==============================================================================
# 6. Consistency: explain_feasibility agrees with is_feasible
# ==============================================================================

@testset "explain_feasibility/is_feasible consistency — AISC sweep" begin
    catalog = [W("W10X12"), W("W14X22"), W("W21X44"), W("W24X68")]
    material = A992_Steel
    L = 4.572  # 15 ft
    geometry = SteelMemberGeometry(L; Lb=L, Cb=1.0)

    checker = AISCChecker(; deflection_limit=1/360)
    cache = StructuralSizer.create_cache(checker, length(catalog))
    StructuralSizer.precompute_capacities!(checker, cache, catalog, material, MinWeight())

    demands = [
        MemberDemand(1; Pu_c=100.0u"kN", Mux=30.0u"kN*m"),
        MemberDemand(1; Pu_c=500.0u"kN", Mux=200.0u"kN*m"),
        MemberDemand(1; Mux=400.0u"kN*m", Vu_strong=200.0u"kN"),
    ]

    for demand in demands
        for (j, sec) in enumerate(catalog)
            feas = StructuralSizer.is_feasible(checker, cache, j, sec, material, demand, geometry)
            expl = StructuralSizer.explain_feasibility(checker, cache, j, sec, material, demand, geometry)
            @test expl.passed == feas
        end
    end
end
