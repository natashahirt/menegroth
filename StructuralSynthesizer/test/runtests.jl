using StructuralSynthesizer
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
end
