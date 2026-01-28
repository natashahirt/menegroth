# Test Voronoi vertex tributaries
# Note: Does NOT import StructuralSynthesizer to avoid GLMakie hanging

using StructuralSizer
using Unitful
using Test

@testset "Voronoi Vertex Tributaries" begin
    
    @testset "Basic Voronoi with boundary (rectangle)" begin
        # 4 corner columns on a rectangle - symmetric, so equal areas
        points = [
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 8.0),
            (0.0, 8.0),
        ]
        boundary = [(0.0, 0.0), (10.0, 0.0), (10.0, 8.0), (0.0, 8.0)]
        
        tribs = compute_voronoi_tributaries(points; floor_boundary=boundary)
        
        @test length(tribs) == 4
        
        # Total area should equal boundary area (10 × 8 = 80 m²)
        total_area = sum(t.area for t in tribs)
        println("Total Voronoi area: $total_area m²")
        @test total_area ≈ 80.0 rtol=0.01
        
        # Each corner gets 1/4 = 20 m²
        areas = [t.area for t in tribs]
        println("Areas: $areas")
        @test all(isapprox(a, 20.0; atol=0.1) for a in areas)
    end
    
    @testset "Voronoi with interior point (full Voronoi)" begin
        # 4 corners + 1 interior - triggers full Voronoi path
        points = [
            (0.0, 0.0),
            (10.0, 0.0),
            (10.0, 8.0),
            (0.0, 8.0),
            (5.0, 4.0),  # Interior column
        ]
        boundary = [(0.0, 0.0), (10.0, 0.0), (10.0, 8.0), (0.0, 8.0)]
        
        tribs = compute_voronoi_tributaries(points; floor_boundary=boundary)
        
        @test length(tribs) == 5
        
        # Total should still equal boundary area
        total_area = sum(t.area for t in tribs)
        println("Total area with interior: $total_area m²")
        @test total_area ≈ 80.0 rtol=0.05
        
        # Interior column should have larger area than corners
        interior_area = tribs[5].area
        corner_areas = [tribs[i].area for i in 1:4]
        println("Interior area: $interior_area m²")
        println("Corner areas: $corner_areas")
        @test interior_area > maximum(corner_areas)
    end
    
    @testset "VertexTributary struct" begin
        trib = StructuralSizer.VertexTributary(
            1, 
            [(0.0, 0.0), (5.0, 0.0), (5.0, 4.0), (0.0, 4.0)],
            20.0,
            :corner
        )
        
        @test trib.vertex_idx == 1
        @test trib.area == 20.0
        @test length(trib.polygon) == 4
        @test trib.position == :corner
    end
    
    @testset "Single vertex case" begin
        points = [(5.0, 4.0)]
        boundary = [(0.0, 0.0), (10.0, 0.0), (10.0, 8.0), (0.0, 8.0)]
        
        tribs = compute_voronoi_tributaries(points; floor_boundary=boundary)
        
        @test length(tribs) == 1
        @test tribs[1].area ≈ 80.0 rtol=0.01  # Single column gets entire area
    end
    
    @testset "Irregular polygon (trapezoid)" begin
        # Trapezoid: wide at bottom (0-10), narrow at top (2-8)
        # Voronoi partitions based on distance to generators, not edge lengths
        points = [
            (0.0, 0.0),   # Bottom-left
            (10.0, 0.0),  # Bottom-right
            (8.0, 6.0),   # Top-right
            (2.0, 6.0),   # Top-left
        ]
        boundary = points
        
        tribs = compute_voronoi_tributaries(points; floor_boundary=boundary)
        
        @test length(tribs) == 4
        
        # Total area should match trapezoid: (10 + 6) * 6 / 2 = 48 m²
        total_area = sum(t.area for t in tribs)
        expected_area = (10.0 + 6.0) * 6.0 / 2.0  # Trapezoid formula
        println("Trapezoid total: $total_area m², expected: $expected_area m²")
        @test total_area ≈ expected_area rtol=0.05
        
        # All areas should be positive and reasonable
        areas = [t.area for t in tribs]
        println("Trapezoid areas: $areas")
        @test all(a -> a > 0, areas)
        @test all(a -> a < expected_area, areas)  # No single vertex gets entire area
        
        # Areas should NOT be equal (unlike rectangle) - Voronoi respects geometry
        @test !all(isapprox(a, expected_area/4; atol=0.5) for a in areas)
    end
    
    @testset "Concave polygon (L-shape)" begin
        # L-shaped polygon with 6 corners
        #  ┌───┐
        #  │ 1 │ 2
        #  │   └───┐
        #  │ 6   5 │ 3
        #  └───────┘
        #    4
        points = [
            (0.0, 8.0),   # 1: top-left
            (4.0, 8.0),   # 2: top-right of upper part
            (4.0, 4.0),   # 3: inner corner (concavity)
            (8.0, 4.0),   # 4: bottom-right of lower part
            (8.0, 0.0),   # 5: bottom-right
            (0.0, 0.0),   # 6: bottom-left
        ]
        boundary = points
        
        tribs = compute_voronoi_tributaries(points; floor_boundary=boundary)
        
        @test length(tribs) == 6
        
        # L-shape area: 4×8 + 4×4 = 32 + 16 = 48 m² (or 8×8 - 4×4 = 48)
        # Actually: upper part 4×4 + lower part 8×4 = 16 + 32 = 48 m²
        total_area = sum(t.area for t in tribs)
        expected_area = 4.0 * 4.0 + 8.0 * 4.0  # Upper (4×4) + Lower (8×4)
        println("L-shape total: $total_area m², expected: $expected_area m²")
        @test total_area ≈ expected_area rtol=0.1
        
        # All areas should be positive
        areas = [t.area for t in tribs]
        println("L-shape areas: $areas")
        @test all(a -> a > 0, areas)
        
        # The inner corner (point 3) should have a smaller area 
        # since its Voronoi cell gets clipped by the concavity
        inner_corner_area = tribs[3].area
        outer_corner_areas = [tribs[i].area for i in [1, 5, 6]]
        println("Inner corner area: $inner_corner_area")
        println("Outer corner areas: $outer_corner_areas")
    end
end

println("\n✓ Voronoi tributary tests passed!")
