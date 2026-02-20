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
