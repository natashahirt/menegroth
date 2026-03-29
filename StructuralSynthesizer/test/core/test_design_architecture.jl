# Test the new design architecture
using StructuralSynthesizer
using StructuralSizer  # For Concrete, StructuralSteel types
using StructuralSizer: ksi  # Units from Asap via StructuralSizer
using Test
using Unitful

println("Testing design architecture types...")

@testset "Design Architecture" begin
    @testset "TributaryCache" begin
        cache = TributaryCache()
        @test isempty(cache.edge)
        @test isempty(cache.vertex)
        
        # Test cache key creation
        key1 = TributaryCacheKey(:one_way, UInt64(0))
        key2 = TributaryCacheKey(:one_way, UInt64(0))
        @test key1 == key2
        @test hash(key1) == hash(key2)
        
        key3 = TributaryCacheKey(:two_way, UInt64(0))
        @test key1 != key3
        
        # Test has_edge_tributaries
        @test !has_edge_tributaries(cache, key1)
    end
    
    @testset "DesignParameters" begin
        params = DesignParameters()
        @test params.name == "default"
        @test params.materials.concrete === nothing  # No default concrete override
        
        # Custom params with concrete from StructuralSizer
        concrete = StructuralSizer.Concrete(
            57000 * sqrt(4000) * u"psi",  # E
            4000.0u"psi",                  # fc'
            150.0u"lbf/ft^3",              # ρ
            0.2,                           # ν
            0.12                           # ecc
        )
        params2 = DesignParameters(
            name = "4ksi Concrete",
            materials = MaterialOptions(concrete = concrete),
        )
        @test params2.name == "4ksi Concrete"
        @test params2.materials.concrete.fc′ == 4000.0u"psi"
    end
    
    @testset "BuildingDesign" begin
        # BuildingDesign requires a BuildingStructure
        skel = gen_medium_office(10.0u"m", 10.0u"m", 3.0u"m", 1, 1, 1)
        struc = BuildingStructure(skel)
        
        params = DesignParameters(name = "Test Design")
        design = BuildingDesign(struc, params)
        
        @test design.params.name == "Test Design"
        @test isempty(design.slabs)
        @test isempty(design.columns)
        @test all_ok(design)  # No failures yet
        @test critical_ratio(design) == 0.0
    end

    @testset "DesignSummary critical element prefers failing slabs over high-ratio passing foundations" begin
        skel = gen_medium_office(10.0u"m", 10.0u"m", 3.0u"m", 1, 1, 1)
        struc = BuildingStructure(skel)
        params = DesignParameters()
        design = BuildingDesign(struc, params)
        design.slabs[1] = SlabDesignResult(;
            thickness = 0.2u"m",
            self_weight = 1.0u"kPa",
            converged = true,
            deflection_ok = true,
            deflection_ratio = 0.1,
            punching_ok = false,
            punching_max_ratio = 1.5,
        )
        design.foundations[1] = FoundationDesignResult(;
            ok = true,
            bearing_ratio = 0.3,
            punching_ratio = 2.21,
            flexure_ratio = 0.2,
        )
        StructuralSynthesizer._compute_design_summary!(design, struc, params)
        @test !design.summary.all_checks_pass
        @test occursin("Slab", design.summary.critical_element)
        @test occursin("punching", design.summary.critical_element)
        @test design.summary.critical_ratio ≈ 1.5
    end

    @testset "slab_diagnostic_governing_check maps section_inadequate to reinforcement_design" begin
        sr = SlabDesignResult(;
            thickness = 0.2u"m",
            self_weight = 1.0u"kPa",
            converged = false,
            failure_reason = "section_inadequate",
            failing_check = "reinforcement_design",
            deflection_ok = true,
            punching_ok = true,
            deflection_ratio = 0.2,
            punching_max_ratio = 0.3,
        )
        @test StructuralSynthesizer.slab_diagnostic_governing_check(sr) == "reinforcement_design"
    end

    @testset "column_diagnostic_governing_check picks failing limit state, not max passing ratio" begin
        pc = PunchingDesignResult(;
            Vu = 100.0u"kN",
            φVc = 100.0u"kN",
            ratio = 1.3,
            ok = false,
            critical_perimeter = 4.0u"m",
            tributary_area = 25.0u"m^2",
        )
        col = ColumnDesignResult(;
            ok = false,
            axial_ratio = 0.2,
            interaction_ratio = 0.4,
            punching = pc,
        )
        @test StructuralSynthesizer.column_diagnostic_governing_check(col) == "punching_shear_col"
    end

    @testset "beam_diagnostic_governing_check picks shear when only shear exceeds 1" begin
        br = BeamDesignResult(;
            ok = false,
            flexure_ratio = 0.5,
            shear_ratio = 1.15,
            Mu = 0.0u"kN*m",
            Vu = 0.0u"kN",
        )
        @test StructuralSynthesizer.beam_diagnostic_governing_check(br) == "shear"
    end

    @testset "foundation_diagnostic_governing_check picks failing check over high passing bearing" begin
        fr = FoundationDesignResult(;
            ok = false,
            bearing_ratio = 0.55,
            punching_ratio = 1.4,
            flexure_ratio = 0.2,
        )
        @test StructuralSynthesizer.foundation_diagnostic_governing_check(fr) == "punching_shear_fdn"
    end
    
    @testset "Existing Material Types (StructuralSizer)" begin
        # Test that we can use existing material types
        concrete = StructuralSizer.Concrete(
            3605.0u"ksi",      # E
            4.0u"ksi",         # fc' (use same units for comparison)
            150.0u"lbf/ft^3",  # ρ
            0.2,               # ν
            0.12               # ecc
        )
        @test concrete.fc′ == 4.0u"ksi"
        
        steel = StructuralSizer.StructuralSteel(
            29000.0u"ksi",     # E
            11200.0u"ksi",     # G
            50.0u"ksi",        # Fy
            65.0u"ksi",        # Fu
            490.0u"lbf/ft^3",  # ρ
            0.3,               # ν
            1.37               # ecc
        )
        @test steel.Fy == 50.0u"ksi"
    end
end

println("All design architecture tests passed!")
