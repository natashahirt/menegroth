# Test spanning behavior trait system
using Test
using StructuralSizer

@testset "Spanning Behavior Traits" begin
    
    @testset "Trait types exist" begin
        @test OneWaySpanning <: SpanningBehavior
        @test TwoWaySpanning <: SpanningBehavior
        @test BeamlessSpanning <: SpanningBehavior
    end
    
    @testset "One-way floor types" begin
        one_way_types = [OneWay(), CompositeDeck(), NonCompositeDeck(), 
                         JoistRoofDeck(), HollowCore(), CLT(), DLT(), NLT(),
                         MassTimberJoist(), Vault()]
        
        for ft in one_way_types
            @test spanning_behavior(ft) isa OneWaySpanning
            @test is_one_way(ft)
            @test !is_two_way(ft)
            @test !is_beamless(ft)
            @test !requires_column_tributaries(ft)
            @test load_distribution(ft) == DISTRIBUTION_ONE_WAY
        end
    end
    
    @testset "Two-way floor types" begin
        two_way_types = [TwoWay(), Waffle(), PTBanded()]
        
        for ft in two_way_types
            @test spanning_behavior(ft) isa TwoWaySpanning
            @test !is_one_way(ft)
            @test is_two_way(ft)
            @test !is_beamless(ft)
            @test !requires_column_tributaries(ft)
            @test load_distribution(ft) == DISTRIBUTION_TWO_WAY
        end
    end
    
    @testset "Beamless floor types" begin
        beamless_types = [FlatPlate(), FlatSlab()]
        
        for ft in beamless_types
            @test spanning_behavior(ft) isa BeamlessSpanning
            @test !is_one_way(ft)
            @test !is_two_way(ft)
            @test is_beamless(ft)
            @test requires_column_tributaries(ft)
            @test load_distribution(ft) == DISTRIBUTION_POINT
        end
    end
    
    @testset "Default tributary axis follows spanning behavior" begin
        # Mock spans object
        mock_spans = (axis = (1.0, 0.0),)
        
        # One-way: uses span axis
        @test default_tributary_axis(OneWay(), mock_spans) == (1.0, 0.0)
        @test default_tributary_axis(CLT(), mock_spans) == (1.0, 0.0)
        
        # Two-way: isotropic (nothing)
        @test default_tributary_axis(TwoWay(), mock_spans) === nothing
        @test default_tributary_axis(Waffle(), mock_spans) === nothing
        
        # Beamless: isotropic for edge tribs
        @test default_tributary_axis(FlatPlate(), mock_spans) === nothing
        @test default_tributary_axis(FlatSlab(), mock_spans) === nothing
    end
    
    @testset "Trait is intrinsic (not affected by symbol lookup)" begin
        # Verify floor_type() returns correct types with correct traits
        @test spanning_behavior(floor_type(:flat_plate)) isa BeamlessSpanning
        @test spanning_behavior(floor_type(:flat_slab)) isa BeamlessSpanning
        @test spanning_behavior(floor_type(:one_way)) isa OneWaySpanning
        @test spanning_behavior(floor_type(:two_way)) isa TwoWaySpanning
        @test spanning_behavior(floor_type(:waffle)) isa TwoWaySpanning
        @test spanning_behavior(floor_type(:clt)) isa OneWaySpanning
    end
    
    @testset "Long-to-short greater than 2 is one-way" begin
        # ACI 318-19 R8.3.1.2 (corpus: aci-318-19, PDF p. 103). At 2, two-way.
        @test infer_floor_type(10.0, 10.0) == :two_way
        @test infer_floor_type(10.0, 20.0) == :two_way
        @test infer_floor_type(10.0, 20.1) == :one_way
        @test infer_floor_type(30.0, 10.0) == :one_way
        @test infer_floor_type(10.0, 10.0; axis=(1.0, 0.0)) == :one_way
        @test_throws ArgumentError infer_floor_type(0.0, 10.0)
    end

    @testset "ShapedSlab defaults to two-way" begin
        shaped = ShapedSlab((x,y,l,m) -> nothing)
        @test spanning_behavior(shaped) isa TwoWaySpanning
        # But load_distribution is CUSTOM (overridden)
        @test load_distribution(shaped) == DISTRIBUTION_CUSTOM
    end
end

println("All spanning behavior tests passed!")
