using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using Meshes

@testset "StructuralSynthesizer.jl" begin
    @testset "BuildingSkeleton" begin
        skel = BuildingSkeleton{Float64}()
        @test length(skel.vertices) == 0
        @test length(skel.edges) == 0
        
        p1 = Point(0.0, 0.0, 0.0)
        p2 = Point(5.0, 0.0, 0.0)
        idx1 = add_vertex!(skel, p1)
        idx2 = add_vertex!(skel, p2)
        @test idx1 == 1
        @test idx2 == 2
        @test length(skel.vertices) == 2
    end

    @testset "BuildingStructure" begin
        skel = BuildingSkeleton{Float64}()
        struc = BuildingStructure(skel)
        @test struc.skeleton === skel
        @test length(struc.slabs) == 0
    end

    # TODO: Re-enable when OneWay floor sizing is implemented
    # This test is currently broken for two reasons:
    # 1. Manually created skeleton has no edges (get_cell_spans fails)
    # 2. OneWay floor type is not implemented yet (stub)
    # @testset "Slab sizing by slab groups" begin
    #     ...
    # end
end
