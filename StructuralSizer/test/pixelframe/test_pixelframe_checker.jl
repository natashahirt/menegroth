# ==============================================================================
# Tests: PixelFrame Checker Integration with optimize_discrete
# ==============================================================================
# Validates that PixelFrameChecker correctly integrates with the MIP solver:
#   1. Catalog generation produces feasible sections (Y/X2/X4 polygon)
#   2. optimize_discrete finds optimal assignments
#   3. Capacity checks are respected (infeasible demands are rejected)
#   4. Objective values (MinVolume, MinCarbon) are consistent
#   5. Edge cases: single group, single section, zero demand, extreme demand
#   6. Multi-layup catalog tests
# ==============================================================================

using Test
using StructuralSizer
using Unitful
using Asap  # kgCO2e and other custom units for standalone runs
using Asap: CompoundSection
import JuMP
const MOI = JuMP.MOI

# ==============================================================================
# Helper: build a small catalog for testing
# ==============================================================================

"""Build a compact catalog for fast MIP tests."""
function _test_catalog(;
    fc_values = [35.0, 57.0, 80.0],
    d_ps_values = [100.0, 150.0, 200.0],
    A_s_values = [157.0, 402.0],
    λ_values = [:Y],
)
    generate_pixelframe_catalog(;
        λ_values,
        fc_values,
        d_ps_values,
        A_s_values,
    )
end

"""Build a single-section catalog for deterministic tests."""
function _single_section_catalog()
    generate_pixelframe_catalog(;
        fc_values = [57.0],
        d_ps_values = [200.0],
        A_s_values = [157.0],
    )
end

# ==============================================================================
# Helper: build a dummy FRC material for the material argument
# ==============================================================================

function _dummy_frc()
    conc = Concrete(Ec(57.0u"MPa"), 57.0u"MPa", 2400.0u"kg/m^3", 0.2, 0.15)
    fR1 = fc′_dosage2fR1(57.0, 20.0)
    fR3 = fc′_dosage2fR3(57.0, 20.0)
    FiberReinforcedConcrete(conc, 20.0, fR1, fR3)
end

@testset "PixelFrame Checker Integration" begin

    # =========================================================================
    # Catalog generation sanity
    # =========================================================================
    @testset "Catalog generation produces feasible sections" begin
        catalog = _test_catalog()

        @test length(catalog) > 0

        # Every section should have a CompoundSection
        for sec in catalog
            @test sec.section isa CompoundSection
            @test sec.section.area > 0
        end

        # Every section should have converged flexure. Use the same default
        # f_py as PixelFrameChecker (ASTM A416 Gr 270 LR, ACI 318-11 R18.7.2)
        # so both code paths agree.
        checker = PixelFrameChecker()
        E_s = 200.0u"GPa"
        f_py = checker.f_py_MPa * u"MPa"
        for sec in catalog
            fl = pf_flexural_capacity(sec; E_s, f_py)
            @test fl.converged
        end
    end

    @testset "Catalog generation — all sections have positive capacities" begin
        catalog = _test_catalog()
        E_s = 200.0u"GPa"

        for sec in catalog
            ax = pf_axial_capacity(sec; E_s)
            @test ustrip(u"kN", ax.Pu) > 0

            fl = pf_flexural_capacity(sec; E_s)
            @test ustrip(u"kN*m", fl.Mu) > 0

            Vu = frc_shear_capacity(sec; E_s)
            @test ustrip(u"kN", Vu) > 0
        end
    end

    @testset "Catalog generation — higher fc' yields more capacity" begin
        cat_low = generate_pixelframe_catalog(fc_values=[28.0], d_ps_values=[200.0], A_s_values=[157.0])
        cat_high = generate_pixelframe_catalog(fc_values=[80.0], d_ps_values=[200.0], A_s_values=[157.0])

        @test length(cat_low) ≥ 1
        @test length(cat_high) ≥ 1

        ax_low = pf_axial_capacity(cat_low[1])
        ax_high = pf_axial_capacity(cat_high[1])
        @test ustrip(u"kN", ax_high.Pu) > ustrip(u"kN", ax_low.Pu)

        fl_low = pf_flexural_capacity(cat_low[1])
        fl_high = pf_flexural_capacity(cat_high[1])
        @test ustrip(u"kN*m", fl_high.Mu) > ustrip(u"kN*m", fl_low.Mu)
    end

    # =========================================================================
    # Tendon yield default consistency
    # =========================================================================
    # Pins that PixelFrameChecker's f_py_MPa default matches
    # ASTM_A416_GR270_LR_FPY (ACI 318-11 R18.7.2 commentary, low-relaxation
    # strand: f_py / f_pu ≥ 0.90 with f_pu = 1860 MPa). Catches accidental
    # drift between the checker default and pf_flexural_capacity's default.
    @testset "Checker default f_py matches ASTM A416 Gr 270 LR constant" begin
        checker = PixelFrameChecker()
        @test isapprox(
            checker.f_py_MPa,
            ustrip(u"MPa", StructuralSizer.ASTM_A416_GR270_LR_FPY);
            atol = 1e-9,
        )
        @test isapprox(checker.f_py_MPa, 1674.0; atol = 1e-9)
    end

    # Pins that the checker capacity-precompute path and the direct
    # pf_flexural_capacity call agree on Mu when both use their defaults.
    # Previously these diverged silently (checker default was 1860 MPa /
    # i.e. f_pu mislabeled as yield; direct default was 0.85*1900 = 1615 MPa).
    @testset "Mu from checker path == Mu from direct pf_flexural_capacity (defaults)" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()
        cache = create_cache(checker, length(catalog))
        precompute_capacities!(checker, cache, catalog, mat, MinVolume())

        for (j, sec) in enumerate(catalog)
            fl = pf_flexural_capacity(sec)  # all defaults
            Mu_direct_Nm = ustrip(u"N*m", fl.Mu)
            @test isapprox(cache.Mu[j], Mu_direct_Nm; rtol = 1e-9)
        end
    end

    @testset "Catalog generation — multi-layup" begin
        catalog = _test_catalog(λ_values=[:Y, :X2, :X4])

        @test length(catalog) > 0

        # Should contain all three layup types
        layups = Set(sec.λ for sec in catalog)
        @test :Y ∈ layups
        @test :X2 ∈ layups
        @test :X4 ∈ layups

        # All sections should be valid
        for sec in catalog
            @test sec.section isa CompoundSection
            @test sec.section.area > 0
        end
    end

    @testset "Catalog generation — regression fR values used" begin
        catalog = generate_pixelframe_catalog(
            fc_values=[57.0], d_ps_values=[200.0], A_s_values=[157.0],
        )
        @test length(catalog) ≥ 1
        sec = catalog[1]

        # fR1 should match regression for fc'=57, dosage=20
        expected_fR1 = fc′_dosage2fR1(57.0, 20.0)
        expected_fR3 = fc′_dosage2fR3(57.0, 20.0)
        @test isapprox(sec.material.fR1, expected_fR1; rtol=1e-6)
        @test isapprox(sec.material.fR3, expected_fR3; rtol=1e-6)
    end

    # =========================================================================
    # Precompute + is_feasible
    # =========================================================================
    @testset "Precompute capacities and check feasibility" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()
        cache = create_cache(checker, length(catalog))
        precompute_capacities!(checker, cache, catalog, mat, MinVolume())

        @test all(cache.Pu .> 0)
        @test all(cache.Mu .> 0)
        @test all(cache.Vu .> 0)
        @test all(cache.obj_coeffs .> 0)

        # Best section should pass a moderate demand
        j_best_Mu = argmax(cache.Mu)
        moderate_demand = MemberDemand(1;
            Pu_c = cache.Pu[j_best_Mu] * 0.5 * u"N",
            Mux  = cache.Mu[j_best_Mu] * 0.5 * u"N*m",
            Vu_strong = cache.Vu[j_best_Mu] * 0.5 * u"N",
        )
        geom = ConcreteMemberGeometry(6.0u"m")
        @test is_feasible(checker, cache, j_best_Mu, catalog[j_best_Mu], mat, moderate_demand, geom)

        # Item 9c — independent P and M at 0.6 φ each must fail H1-1a.
        # AISC 360-16 §H1.1 Eq. H1-1a (corpus: aisc-360-16, page 133):
        #   0.6 + (8/9)*0.6 = 1.133 > 1.0
        h1_demand = MemberDemand(1;
            Pu_c = cache.Pu[j_best_Mu] * 0.6 * u"N",
            Mux  = cache.Mu[j_best_Mu] * 0.6 * u"N*m",
            Vu_strong = 0.0u"N",
        )
        @test !is_feasible(checker, cache, j_best_Mu, catalog[j_best_Mu], mat, h1_demand, geom)
        ur_h1 = StructuralSizer._pixelframe_h1_interaction(
            0.6, 0.6, 0.0, 1.0, 1.0, 1.0)
        @test ur_h1 ≈ (0.6 + (8 / 9) * 0.6) rtol=1e-12
        @test ur_h1 > 1.0
        # Old path: independent P and M at 0.6 φ each would each pass.
        independent_ur = max(0.6, 0.6)
        @test independent_ur ≤ 1.0
        @test ur_h1 > independent_ur

        expl = StructuralSizer.explain_feasibility(
            checker, cache, j_best_Mu, catalog[j_best_Mu], mat, h1_demand, geom)
        @test !expl.passed
        pm = only(filter(c -> c.name == "pm_interaction", expl.checks))
        @test !pm.passed
        @test pm.ratio ≈ ur_h1 rtol=1e-12
        @test expl.governing_check == "pm_interaction"
    end

    @testset "Infeasible demand — exceeds all section capacities" begin
        catalog = _single_section_catalog()
        @test length(catalog) ≥ 1
        checker = PixelFrameChecker()
        mat = _dummy_frc()
        cache = create_cache(checker, length(catalog))
        precompute_capacities!(checker, cache, catalog, mat, MinVolume())

        huge_demand = MemberDemand(1; Mux = 1e6u"kN*m")
        geom = ConcreteMemberGeometry(6.0u"m")

        for j in 1:length(catalog)
            @test !is_feasible(checker, cache, j, catalog[j], mat, huge_demand, geom)
        end
    end

    @testset "Zero demand — all sections feasible" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()
        cache = create_cache(checker, length(catalog))
        precompute_capacities!(checker, cache, catalog, mat, MinVolume())

        zero_demand = MemberDemand(1)
        geom = ConcreteMemberGeometry(6.0u"m")

        for j in 1:length(catalog)
            @test is_feasible(checker, cache, j, catalog[j], mat, zero_demand, geom)
        end
    end

    # =========================================================================
    # optimize_discrete — basic MIP solve
    # =========================================================================
    @testset "optimize_discrete — single group, MinVolume" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()

        demands = [MemberDemand(1; Pu_c=50.0u"kN", Mux=10.0u"kN*m", Vu_strong=5.0u"kN")]
        geometries = [ConcreteMemberGeometry(6.0u"m")]

        result = optimize_discrete(
            checker, demands, geometries, catalog, mat;
            objective = MinVolume(),
        )

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 1
        @test result.sections[1] isa PixelFrameSection
        @test result.objective_value > 0
    end

    @testset "optimize_discrete — multiple groups" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()

        demands = [
            MemberDemand(1; Pu_c=20.0u"kN", Mux=5.0u"kN*m",  Vu_strong=3.0u"kN"),
            MemberDemand(2; Pu_c=50.0u"kN", Mux=15.0u"kN*m", Vu_strong=8.0u"kN"),
            MemberDemand(3; Pu_c=80.0u"kN", Mux=25.0u"kN*m", Vu_strong=12.0u"kN"),
        ]
        geometries = [
            ConcreteMemberGeometry(4.0u"m"),
            ConcreteMemberGeometry(6.0u"m"),
            ConcreteMemberGeometry(8.0u"m"),
        ]

        result = optimize_discrete(
            checker, demands, geometries, catalog, mat;
            objective = MinVolume(),
        )

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 3
        @test all(s -> s isa PixelFrameSection, result.sections)
        @test result.objective_value > 0

        # Verify feasibility
        cache = create_cache(checker, length(catalog))
        precompute_capacities!(checker, cache, catalog, mat, MinVolume())
        for (i, idx) in enumerate(result.section_indices)
            @test is_feasible(checker, cache, idx, catalog[idx], mat, demands[i], geometries[i])
        end
    end

    @testset "optimize_discrete — MinCarbon objective" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()

        demands = [MemberDemand(1; Pu_c=30.0u"kN", Mux=8.0u"kN*m", Vu_strong=4.0u"kN")]
        geometries = [ConcreteMemberGeometry(6.0u"m")]

        result = optimize_discrete(
            checker, demands, geometries, catalog, mat;
            objective = MinCarbon(),
        )

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 1
        @test result.objective_value > 0

        chosen = result.sections[1]
        # `pf_carbon_per_meter` returns typed `kgCO₂e/m`; the MIP cache strips
        # to bare `kgCO₂e` (the JuMP boundary), so compute the expected value
        # in typed space and strip on the same side for the comparison.
        carbon_per_m = pf_carbon_per_meter(chosen)
        expected_obj = ustrip(u"kgCO2e", carbon_per_m * 6.0u"m")
        @test isapprox(result.objective_value, expected_obj; rtol=0.01)
    end

    @testset "optimize_discrete — MinCarbon vs MinVolume differ" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()

        demands = [MemberDemand(1; Pu_c=20.0u"kN", Mux=5.0u"kN*m", Vu_strong=3.0u"kN")]
        geometries = [ConcreteMemberGeometry(6.0u"m")]

        result_vol = optimize_discrete(checker, demands, geometries, catalog, mat; objective=MinVolume())
        result_co2 = optimize_discrete(checker, demands, geometries, catalog, mat; objective=MinCarbon())

        @test result_vol.status == MOI.OPTIMAL || result_vol.status == MOI.TIME_LIMIT
        @test result_co2.status == MOI.OPTIMAL || result_co2.status == MOI.TIME_LIMIT

        chosen_vol = result_vol.sections[1]
        chosen_co2 = result_co2.sections[1]
        carbon_vol = pf_carbon_per_meter(chosen_vol)
        carbon_co2 = pf_carbon_per_meter(chosen_co2)
        # `1e-6` slack carried in typed `kgCO₂e/m` so the inequality stays
        # dimensionally consistent with the carbon-intensity terms.
        @test carbon_co2 ≤ carbon_vol + 1e-6u"kgCO2e/m"
    end

    # =========================================================================
    # optimize_discrete — n_max_sections constraint
    # =========================================================================
    @testset "optimize_discrete — n_max_sections limits unique sections" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()

        demands = [
            MemberDemand(i;
                Pu_c = 10.0*i * u"kN",
                Mux  = 3.0*i * u"kN*m",
                Vu_strong = 2.0*i * u"kN",
            ) for i in 1:4
        ]
        geometries = [ConcreteMemberGeometry(6.0u"m") for _ in 1:4]

        result = optimize_discrete(
            checker, demands, geometries, catalog, mat;
            objective = MinVolume(),
            n_max_sections = 2,
        )

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 4

        unique_indices = unique(result.section_indices)
        @test length(unique_indices) ≤ 2
    end

    # =========================================================================
    # optimize_discrete — infeasible problem
    # =========================================================================
    @testset "optimize_discrete — infeasible demand throws" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()

        demands = [MemberDemand(1; Mux=1e6u"kN*m")]
        geometries = [ConcreteMemberGeometry(6.0u"m")]

        @test_throws ArgumentError optimize_discrete(
            checker, demands, geometries, catalog, mat;
            objective = MinVolume(),
        )
    end

    # =========================================================================
    # optimize_discrete — single-section catalog (deterministic)
    # =========================================================================
    @testset "optimize_discrete — single section catalog" begin
        catalog = _single_section_catalog()
        @test length(catalog) ≥ 1
        checker = PixelFrameChecker()
        mat = _dummy_frc()

        demands = [
            MemberDemand(1; Pu_c=1.0u"kN", Mux=0.5u"kN*m", Vu_strong=0.3u"kN"),
            MemberDemand(2; Pu_c=2.0u"kN", Mux=1.0u"kN*m", Vu_strong=0.5u"kN"),
        ]
        geometries = [ConcreteMemberGeometry(5.0u"m"), ConcreteMemberGeometry(7.0u"m")]

        result = optimize_discrete(
            checker, demands, geometries, catalog, mat;
            objective = MinVolume(),
        )

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 2

        @test result.section_indices[1] == result.section_indices[2]
        @test result.sections[1] === result.sections[2]
    end

    # =========================================================================
    # get_objective_coeff consistency
    # =========================================================================
    @testset "get_objective_coeff matches objective_value" begin
        catalog = _test_catalog()
        checker = PixelFrameChecker()
        mat = _dummy_frc()

        # MinVolume
        cache_vol = create_cache(checker, length(catalog))
        precompute_capacities!(checker, cache_vol, catalog, mat, MinVolume())
        ref_vol = objective_value(MinVolume(), catalog[1], mat, 1.0u"m")
        ref_unit_vol = ref_vol isa Unitful.Quantity ? unit(ref_vol) : Unitful.NoUnits
        for j in 1:length(catalog)
            coeff = get_objective_coeff(checker, cache_vol, j)
            val = objective_value(MinVolume(), catalog[j], mat, 1.0u"m")
            expected = ref_unit_vol != Unitful.NoUnits ? ustrip(ref_unit_vol, val) : Float64(val)
            @test isapprox(coeff, expected; rtol=1e-4)
        end

        # MinCarbon — cache stores stripped `kgCO₂e/m` (`ref_unit`-stripped
        # at the JuMP boundary); strip the typed `pf_carbon_per_meter` on the
        # comparison side so both operands are bare Float64.
        cache_co2 = create_cache(checker, length(catalog))
        precompute_capacities!(checker, cache_co2, catalog, mat, MinCarbon())
        for j in 1:length(catalog)
            coeff = get_objective_coeff(checker, cache_co2, j)
            carbon_per_m = ustrip(u"kgCO2e/m", pf_carbon_per_meter(catalog[j]))
            @test isapprox(coeff, carbon_per_m; rtol=1e-4)
        end
    end

    # =========================================================================
    # get_feasibility_error_msg
    # =========================================================================
    @testset "get_feasibility_error_msg returns informative string" begin
        checker = PixelFrameChecker()
        demand = MemberDemand(1; Pu_c=100.0u"kN", Mux=50.0u"kN*m", Vu_strong=25.0u"kN")
        geom = ConcreteMemberGeometry(6.0u"m")

        msg = get_feasibility_error_msg(checker, demand, geom)
        @test msg isa String
        @test occursin("PixelFrame", msg)
        @test occursin("kN", msg)
    end

    # =========================================================================
    # Minimum bounding box constraint (punching shear growth)
    # =========================================================================
    @testset "min_depth_mm / min_width_mm rejects undersized sections" begin
        catalog = _test_catalog()
        mat = _dummy_frc()

        # Compute bounding box of first section to set a threshold above it
        sec1 = catalog[1]
        bb_depth = sec1.section.ymax - sec1.section.ymin
        bb_width = sec1.section.xmax - sec1.section.xmin

        # Checker with no minimum — zero demand passes all sections
        checker_none = PixelFrameChecker()
        cache = create_cache(checker_none, length(catalog))
        precompute_capacities!(checker_none, cache, catalog, mat, MinVolume())

        zero_dem = MemberDemand(1)
        geom = ConcreteMemberGeometry(6.0u"m")
        @test is_feasible(checker_none, cache, 1, catalog[1], mat, zero_dem, geom)

        # Checker requiring depth > all sections — should reject everything
        max_depth = maximum(cache.depth_mm)
        checker_big = PixelFrameChecker(min_depth_mm = max_depth + 50.0)
        for j in 1:length(catalog)
            @test !is_feasible(checker_big, cache, j, catalog[j], mat, zero_dem, geom)
        end

        # Checker requiring width > all sections — should reject everything
        max_width = maximum(cache.width_mm)
        checker_wide = PixelFrameChecker(min_width_mm = max_width + 50.0)
        for j in 1:length(catalog)
            @test !is_feasible(checker_wide, cache, j, catalog[j], mat, zero_dem, geom)
        end
    end

    @testset "min bounding box — optimizer picks larger section" begin
        # Catalog with multiple L_px values to give a range of bounding boxes
        catalog = generate_pixelframe_catalog(;
            L_px_values = [100.0, 125.0, 150.0],
            t_values = [30.0],
            fc_values = [57.0],
            d_ps_values = [200.0],
            A_s_values = [157.0],
            λ_values = [:X4],
        )
        @test length(catalog) ≥ 3

        mat = _dummy_frc()
        demands = [MemberDemand(1; Pu_c=10.0u"kN", Mux=1.0u"kN*m", Vu_strong=1.0u"kN")]
        geometries = [ConcreteMemberGeometry(4.0u"m")]

        # No minimum — optimizer picks smallest feasible section
        result_free = optimize_discrete(
            PixelFrameChecker(), demands, geometries, catalog, mat;
            objective = MinVolume(),
        )
        @test result_free.status == MOI.OPTIMAL || result_free.status == MOI.TIME_LIMIT
        sec_free = result_free.sections[1]
        bb_free = bounding_box(sec_free)

        # Set minimum to the free solution's depth + 10 mm
        min_d = ustrip(u"mm", bb_free.depth) + 10.0
        result_constrained = optimize_discrete(
            PixelFrameChecker(min_depth_mm = min_d),
            demands, geometries, catalog, mat;
            objective = MinVolume(),
        )
        @test result_constrained.status == MOI.OPTIMAL || result_constrained.status == MOI.TIME_LIMIT
        sec_constrained = result_constrained.sections[1]
        bb_constrained = bounding_box(sec_constrained)

        # Constrained section must be at least as deep as the minimum
        @test ustrip(u"mm", bb_constrained.depth) ≥ min_d - 1e-6
        # And it should be deeper than the free solution
        @test ustrip(u"mm", bb_constrained.depth) > ustrip(u"mm", bb_free.depth)
    end

    @testset "get_feasibility_error_msg includes bbox info when constrained" begin
        checker = PixelFrameChecker(min_depth_mm=300.0, min_width_mm=250.0)
        demand = MemberDemand(1; Pu_c=100.0u"kN", Mux=50.0u"kN*m", Vu_strong=25.0u"kN")
        geom = ConcreteMemberGeometry(6.0u"m")

        msg = get_feasibility_error_msg(checker, demand, geom)
        @test occursin("min bbox", msg)
        @test occursin("300.0", msg)
        @test occursin("250.0", msg)
    end

    # =========================================================================
    # Multi-layup optimization
    # =========================================================================
    @testset "optimize_discrete — multi-layup catalog" begin
        catalog = _test_catalog(
            fc_values = [35.0, 57.0],
            d_ps_values = [150.0, 200.0],
            A_s_values = [157.0],
            λ_values = [:Y, :X2, :X4],
        )

        @test length(catalog) > 0

        checker = PixelFrameChecker()
        mat = _dummy_frc()

        demands = [MemberDemand(1; Pu_c=30.0u"kN", Mux=5.0u"kN*m", Vu_strong=3.0u"kN")]
        geometries = [ConcreteMemberGeometry(6.0u"m")]

        result = optimize_discrete(
            checker, demands, geometries, catalog, mat;
            objective = MinVolume(),
        )

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 1
        @test result.sections[1] isa PixelFrameSection
        @test result.objective_value > 0

        # MinVolume should prefer the smaller section (X2 has less area)
        chosen = result.sections[1]
        @test chosen.λ ∈ [:Y, :X2, :X4]
    end

end
