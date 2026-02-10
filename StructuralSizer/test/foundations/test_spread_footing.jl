# Tests for spread footing design
# Run with: julia --project=. test/runtests.jl

@testset "Spread Footing Design" begin
    
    @testset "Basic sizing (500 kN)" begin
        demand = FoundationDemand(1; Pu=500.0u"kN")
        result = design_spread_footing(demand, medium_sand, NWC_4000, Rebar_60; pier_width=0.3u"m")
        
        # Check dimensions are reasonable
        @test 2.0u"m" < result.B < 2.5u"m"  # Width ~2.24m
        @test 0.25u"m" < result.D < 0.4u"m"  # Depth ~318mm
        @test result.d < result.D  # Effective depth < total depth
        
        # Check utilization is reasonable (SF=1.5 → ~67% utilization)
        @test 0.5 < result.utilization < 0.75
        
        # Check volumes are positive
        @test result.concrete_volume > 0.0u"m^3"
        @test result.steel_volume > 0.0u"m^3"
        
        # Check rebar
        @test result.rebar_count >= 4  # Minimum bars
        @test result.rebar_dia == 16u"mm"  # Default rebar size
    end
    
    @testset "Heavy load (1500 kN)" begin
        demand = FoundationDemand(1; Pu=1500.0u"kN")
        result = design_spread_footing(demand, medium_sand, NWC_4000, Rebar_60; pier_width=0.4u"m")
        
        # Larger load → larger footing
        @test 3.5u"m" < result.B < 4.5u"m"  # Width ~3.87m
        @test 0.45u"m" < result.D < 0.6u"m"  # Depth ~526mm
        @test 0.5 < result.utilization < 0.75
    end
    
    @testset "Soil conditions affect sizing" begin
        demand = FoundationDemand(1; Pu=800.0u"kN")
        
        r_loose = design_spread_footing(demand, loose_sand, NWC_4000, Rebar_60; pier_width=0.35u"m")
        r_medium = design_spread_footing(demand, medium_sand, NWC_4000, Rebar_60; pier_width=0.35u"m")
        r_dense = design_spread_footing(demand, dense_sand, NWC_4000, Rebar_60; pier_width=0.35u"m")
        r_clay = design_spread_footing(demand, stiff_clay, NWC_4000, Rebar_60; pier_width=0.35u"m")
        
        # Weaker soil → larger footing
        @test r_loose.B > r_medium.B > r_dense.B
        
        # Same bearing capacity → same size (medium_sand and stiff_clay both qa=150 kPa)
        @test r_medium.B ≈ r_clay.B rtol=0.01
        
        # Concrete volume scales with footing size
        @test r_loose.concrete_volume > r_dense.concrete_volume
    end
    
    @testset "Soil presets have correct properties" begin
        # Bearing capacities
        @test loose_sand.qa == 75.0u"kPa"
        @test medium_sand.qa == 150.0u"kPa"
        @test dense_sand.qa == 300.0u"kPa"
        @test stiff_clay.qa == 150.0u"kPa"
        
        # All soils have required properties
        for soil in [loose_sand, medium_sand, dense_sand, soft_clay, stiff_clay, hard_clay]
            @test soil.qa > 0.0u"kPa"
            @test soil.γ > 0.0u"kN/m^3"
            @test soil.Es > 0.0u"MPa"
        end
    end
    
    @testset "Result type interface" begin
        demand = FoundationDemand(1; Pu=600.0u"kN")
        result = design_spread_footing(demand, medium_sand, NWC_4000, Rebar_60)
        
        # Interface functions work
        @test StructuralSizer.concrete_volume(result) == result.concrete_volume
        @test StructuralSizer.steel_volume(result) == result.steel_volume
        @test StructuralSizer.footprint_area(result) == result.B * result.L_ftg
        @test StructuralSizer.utilization(result) == result.utilization
        
        # Square footing (B == L)
        @test result.B == result.L_ftg
    end
    
    @testset "Zero/minimal load" begin
        # Minimal load should still produce valid footing (min size governed by pier + projection)
        demand = FoundationDemand(1; Pu=10.0u"kN")
        result = design_spread_footing(demand, medium_sand, NWC_4000, Rebar_60; pier_width=0.3u"m")
        
        # Should be at least pier + 2×0.15m projection
        @test result.B >= 0.6u"m"
        @test result.D >= 0.3u"m"  # Minimum depth
    end
    
end
