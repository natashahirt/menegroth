# ==============================================================================
# Tests: Multi-Material Discrete (MIP) Optimization
# ==============================================================================
# Verifies that the multi-material optimize_discrete overload correctly:
#   1. Expands the catalog across materials
#   2. Returns per-group material assignments
#   3. Produces feasible, optimal solutions
#   4. Respects n_max_sections across (section, material) pairs
#
# Uses both AISC (steel) and ACI (concrete) checkers to validate generality.
# ==============================================================================

using Test
using StructuralSizer
using Unitful
import JuMP
const MOI = JuMP.MOI

@testset "Multi-Material MIP" begin

    # =========================================================================
    # Helper: catalog expansion
    # =========================================================================
    @testset "expand_catalog_with_materials" begin
        # 3 sections × 2 materials → 6 expanded entries
        catalog = all_W()[1:3]
        mats = [A992_Steel, S355_Steel]

        expanded, sec_idx, mat_idx = expand_catalog_with_materials(catalog, mats)

        @test length(expanded) == 6
        @test length(sec_idx) == 6
        @test length(mat_idx) == 6

        # First n_sec entries belong to material 1, next n_sec to material 2
        @test all(mat_idx[1:3] .== 1)
        @test all(mat_idx[4:6] .== 2)
        @test sec_idx[1:3] == [1, 2, 3]
        @test sec_idx[4:6] == [1, 2, 3]

        # Sections should be identical across materials
        @test expanded[1] === expanded[4]
        @test expanded[2] === expanded[5]
        @test expanded[3] === expanded[6]
    end

    @testset "expand_catalog_with_materials — single material degeneracy" begin
        # Edge case: 1 material should be equivalent to the original catalog
        catalog = all_W()[1:5]
        mats = [A992_Steel]

        expanded, sec_idx, mat_idx = expand_catalog_with_materials(catalog, mats)

        @test length(expanded) == 5
        @test all(mat_idx .== 1)
        @test sec_idx == collect(1:5)
    end

    # =========================================================================
    # AISC: multi-material steel columns
    # =========================================================================
    @testset "AISC Steel Columns — two steel grades" begin
        # Two groups with moderate demands; the solver should pick a feasible
        # section-material pair for each.
        Pu = [500e3, 700e3]          # N (compression)
        Mux = [50e3, 70e3]          # N·m
        geometries = [
            SteelMemberGeometry(4.0),  # 4 m columns
            SteelMemberGeometry(4.0),
        ]

        opts = SteelColumnOptions(
            materials = [A992_Steel, S355_Steel],
            catalog = :preferred,
        )
        result = size_columns(Pu, Mux, geometries, opts)

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 2
        @test length(result.materials_chosen) == 2

        # Each chosen material must be one of the input materials
        for mat in result.materials_chosen
            @test mat === A992_Steel || mat === S355_Steel
        end

        # Sections must come from the catalog
        @test all(s -> s isa ISymmSection, result.sections)
        @test result.objective_value > 0
    end

    @testset "AISC Steel Columns — single material in vector matches scalar" begin
        # Single-material vector should give the same result as the scalar overload
        Pu = [400e3, 500e3]
        Mux = [40e3, 50e3]
        geometries = [SteelMemberGeometry(3.5), SteelMemberGeometry(3.5)]

        # Scalar (baseline)
        opts_single = SteelColumnOptions(material = A992_Steel, catalog = :preferred)
        result_single = size_columns(Pu, Mux, geometries, opts_single)

        # Vector with one material
        opts_multi = SteelColumnOptions(
            materials = [A992_Steel],
            catalog = :preferred,
        )
        result_multi = size_columns(Pu, Mux, geometries, opts_multi)

        @test result_multi.status == MOI.OPTIMAL || result_multi.status == MOI.TIME_LIMIT
        @test length(result_multi.materials_chosen) == 2
        @test all(m -> m === A992_Steel, result_multi.materials_chosen)

        # Objective values should be very close (same solver, same problem)
        @test isapprox(result_multi.objective_value, result_single.objective_value; rtol=0.01)
    end

    # =========================================================================
    # ACI: multi-material concrete columns
    # =========================================================================
    @testset "ACI Concrete Columns — two concrete grades" begin
        # Two groups: one moderate, one heavy
        Pu = [600.0, 1000.0]        # kip
        Mux = [60.0, 100.0]         # kip-ft
        geometries = [
            ConcreteMemberGeometry(3.66),   # ~12 ft
            ConcreteMemberGeometry(3.66),
        ]

        opts = ConcreteColumnOptions(
            materials = [NWC_4000, NWC_6000],
            include_biaxial = false,
        )
        result = size_columns(Pu, Mux, geometries, opts)

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 2
        @test length(result.materials_chosen) == 2

        # Each chosen material must be one of the input grades
        for mat in result.materials_chosen
            @test mat === NWC_4000 || mat === NWC_6000
        end

        @test all(s -> s isa RCColumnSection, result.sections)
        @test result.objective_value > 0
    end

    @testset "ACI Concrete Columns — higher grade enables smaller sections" begin
        # With a high-strength concrete, the optimizer should be able to use
        # smaller (or equal) sections compared to low-strength only.
        Pu = [800.0]                # kip
        Mux = [80.0]               # kip-ft
        geometries = [ConcreteMemberGeometry(3.66)]

        # Low-strength only
        opts_low = ConcreteColumnOptions(material = NWC_4000, include_biaxial = false)
        result_low = size_columns(Pu, Mux, geometries, opts_low)

        # Multi-grade (low + high)
        opts_multi = ConcreteColumnOptions(
            materials = [NWC_4000, NWC_6000],
            include_biaxial = false,
        )
        result_multi = size_columns(Pu, Mux, geometries, opts_multi)

        @test result_multi.status == MOI.OPTIMAL || result_multi.status == MOI.TIME_LIMIT

        # Multi-grade should produce ≤ objective (more choices → better or equal)
        @test result_multi.objective_value ≤ result_low.objective_value + 1e-6
    end

    # =========================================================================
    # ACI: multi-material concrete beams
    # =========================================================================
    @testset "ACI Concrete Beams — two concrete grades" begin
        # Two beam groups with moderate demands
        Mu = [200e3, 300e3] .* u"N*m"
        Vu = [100e3, 150e3] .* u"N"
        geometries = [
            ConcreteMemberGeometry(6.0),   # 6 m span
            ConcreteMemberGeometry(8.0),   # 8 m span
        ]

        opts = ConcreteBeamOptions(
            materials = [NWC_4000, NWC_6000],
        )
        result = size_beams(Mu, Vu, geometries, opts)

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.sections) == 2
        @test length(result.materials_chosen) == 2

        for mat in result.materials_chosen
            @test mat === NWC_4000 || mat === NWC_6000
        end

        @test all(s -> s isa RCBeamSection, result.sections)
        @test result.objective_value > 0
    end

    # =========================================================================
    # n_max_sections constraint with multi-material
    # =========================================================================
    @testset "n_max_sections limits unique (section, material) pairs" begin
        # 4 groups, but limit to 2 unique section-material pairs
        Pu = [400e3, 500e3, 600e3, 700e3]
        Mux = [40e3, 50e3, 60e3, 70e3]
        geometries = [SteelMemberGeometry(4.0) for _ in 1:4]

        opts = SteelColumnOptions(
            materials = [A992_Steel, S355_Steel],
            catalog = :preferred,
            n_max_sections = 2,
        )
        result = size_columns(Pu, Mux, geometries, opts)

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT

        # Count unique (section_index, material_index) pairs
        pairs = Set(zip(result.section_indices, result.material_indices))
        @test length(pairs) ≤ 2
    end

    # =========================================================================
    # Edge cases
    # =========================================================================
    @testset "Multi-material with identical materials" begin
        # Passing the same material twice should still work and give the same
        # result as single-material (no benefit, but no error).
        Pu = [500e3]
        Mux = [50e3]
        geometries = [SteelMemberGeometry(4.0)]

        opts = SteelColumnOptions(
            materials = [A992_Steel, A992_Steel],
            catalog = :preferred,
        )
        result = size_columns(Pu, Mux, geometries, opts)

        @test result.status == MOI.OPTIMAL || result.status == MOI.TIME_LIMIT
        @test length(result.materials_chosen) == 1
        @test result.materials_chosen[1] === A992_Steel
    end

end
