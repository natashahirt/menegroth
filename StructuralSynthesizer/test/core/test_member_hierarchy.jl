# Test script for member hierarchy refactor

using StructuralSynthesizer
using StructuralSizer
using Unitful
using Test

@testset "Member Hierarchy" begin
    # Generate a simple building
    skel = gen_medium_office(20.0u"m", 15.0u"m", 4.0u"m", 2, 2, 2)
    struc = BuildingStructure(skel)
    # Use vault as it has a full sizing implementation
    # rise parameter is required for vault sizing
    initialize!(struc; floor_type=:vault, material=NWC_4000, 
                floor_opts=VaultOptions(rise=1.0u"m", thickness=0.05u"m"))
    
    @testset "Member counts" begin
        # 2x2 grid = 3x3 columns per story, 2 stories = 18 column segments
        # But only above-ground columns (story > 0)
        @test length(struc.columns) > 0
        
        # Beams: horizontal edges
        @test length(struc.beams) > 0
        
        # No braces in this building
        @test length(struc.struts) == 0
        
        println("Beams:   ", length(struc.beams))
        println("Columns: ", length(struc.columns))
        println("Struts:  ", length(struc.struts))
    end
    
    @testset "Column positions" begin
        positions = [c.position for c in struc.columns]
        unique_positions = unique(positions)
        println("Column positions: ", unique_positions)
        
        # Should have corner, edge, and interior columns
        @test :corner in unique_positions || :edge in unique_positions || :interior in unique_positions
    end
    
    @testset "Column vertex indices" begin
        # Each column should have a valid vertex_idx
        for col in struc.columns
            @test col.vertex_idx > 0
            @test col.vertex_idx <= length(struc.skeleton.vertices)
        end
    end
    
    @testset "Beam roles" begin
        roles = [b.role for b in struc.beams]
        unique_roles = unique(roles)
        println("Beam roles: ", unique_roles)
        
        # Default role should be :beam
        @test :beam in unique_roles
    end
    
    @testset "Member base fields" begin
        # Check that all members have valid base fields
        for beam in struc.beams
            @test member_length(beam) > 0.0u"m"
            @test !isempty(segment_indices(beam))
        end
        
        for col in struc.columns
            @test member_length(col) > 0.0u"m"
            @test !isempty(segment_indices(col))
        end
    end
    
    @testset "all_members iterator" begin
        all_m = collect(all_members(struc))
        expected = length(struc.beams) + length(struc.columns) + length(struc.struts)
        @test length(all_m) == expected
    end
end

println("\n✓ All member hierarchy tests passed!")
