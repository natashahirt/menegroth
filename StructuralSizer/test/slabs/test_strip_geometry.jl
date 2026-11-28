using Test
using StructuralSizer
import Meshes

@testset "ACI Strip Geometry" begin
    
    @testset "Rectangular panel strip geometry" begin
        # Create a 10m × 8m rectangular panel
        # ACI column strip WIDTH = l2/4 from each column line
        # Our d/2 split matches this width definition
        #
        # For triangular tributaries, splitting at half-depth gives ~75% column strip area
        # (geometrically: cutting a triangle at half height keeps ~75% of area in lower part)
        
        verts = [
            Meshes.Point(0.0, 0.0, 0.0),
            Meshes.Point(10.0, 0.0, 0.0),
            Meshes.Point(10.0, 8.0, 0.0),
            Meshes.Point(0.0, 8.0, 0.0)
        ]
        
        # Get edge tributaries (straight skeleton)
        tribs = StructuralSizer.get_tributary_polygons_isotropic(verts)
        
        # Compute strip geometry
        strips = compute_panel_strips(tribs)
        
        total_area = 10.0 * 8.0  # 80 m²
        
        @test length(strips.column_strips) == 4
        @test length(strips.middle_strips) == 4
        
        # Total areas should match panel area
        @test strips.total_area ≈ total_area rtol=0.05
        
        # For triangular tributaries, column strip ≈ 70-75% of total
        # (this is correct geometrically - ACI defines by WIDTH, not area)
        col_frac = strips.total_column_strip_area / strips.total_area
        mid_frac = strips.total_middle_strip_area / strips.total_area
        
        @test 0.65 < col_frac < 0.80  # ~70-75%
        @test 0.20 < mid_frac < 0.35  # ~25-30%
        
        # Areas must sum correctly
        @test col_frac + mid_frac ≈ 1.0 atol=0.01
        
        println("Rectangular 10×8 panel:")
        println("  Total area: $(strips.total_area) m²")
        println("  Column strip: $(strips.total_column_strip_area) m² ($(round(col_frac*100, digits=1))%)")
        println("  Middle strip: $(strips.total_middle_strip_area) m² ($(round(mid_frac*100, digits=1))%)")
    end
    
    @testset "Square panel" begin
        # 8m × 8m square
        verts = [
            Meshes.Point(0.0, 0.0, 0.0),
            Meshes.Point(8.0, 0.0, 0.0),
            Meshes.Point(8.0, 8.0, 0.0),
            Meshes.Point(0.0, 8.0, 0.0)
        ]
        
        tribs = StructuralSizer.get_tributary_polygons_isotropic(verts)
        strips = compute_panel_strips(tribs)
        
        total_area = 64.0  # m²
        
        @test strips.total_area ≈ total_area rtol=0.05
        
        # Square with triangular tributaries: ~75% column strip
        col_frac = strips.total_column_strip_area / strips.total_area
        @test 0.70 < col_frac < 0.80
        
        println("Square 8×8 panel:")
        println("  Column strip: $(round(col_frac*100, digits=1))%")
    end
    
    @testset "L-shaped panel" begin
        # L-shaped: 10×2 bottom + 4×4 top = 36 m²
        verts = [
            Meshes.Point(0.0, 0.0, 0.0),
            Meshes.Point(10.0, 0.0, 0.0),
            Meshes.Point(10.0, 6.0, 0.0),
            Meshes.Point(6.0, 6.0, 0.0),
            Meshes.Point(6.0, 2.0, 0.0),
            Meshes.Point(0.0, 2.0, 0.0)
        ]
        
        tribs = StructuralSizer.get_tributary_polygons_isotropic(verts)
        strips = compute_panel_strips(tribs)
        
        @test length(strips.column_strips) == 6  # 6 edges
        
        # Areas should still sum correctly
        @test strips.total_column_strip_area + strips.total_middle_strip_area ≈ strips.total_area rtol=0.01
        
        # Total tributary area should be reasonable (>30 m²)
        @test strips.total_area > 30.0
        
        println("L-shaped panel:")
        println("  Total area: $(strips.total_area) m²")
        println("  Column strips: $(length(strips.column_strips))")
    end
    
    @testset "Individual tributary split" begin
        # Create a simple triangular tributary
        # (s, d) coordinates: triangle from (0,0) to (1,0) to (0.5, 4)
        # Max depth = 4m, half-depth = 2m
        
        trib = StructuralSizer.TributaryPolygon(
            1,  # local_edge_idx
            [0.0, 1.0, 0.5],  # s values
            [0.0, 0.0, 4.0],  # d values (max = 4m)
            8.0,  # area = 0.5 * base * height = 0.5 * 1 * 4 * beam_length
            0.25  # fraction
        )
        
        col, mid = split_tributary_at_half_depth(trib)
        
        # Column strip should have max d = 2m
        @test maximum(col.d; init=0.0) ≈ 2.0 atol=0.01
        
        # Areas should sum to original (approximately)
        @test col.area + mid.area ≈ trib.area rtol=0.1
        
        println("Triangular tributary split:")
        println("  Original area: $(trib.area)")
        println("  Column strip area: $(col.area)")
        println("  Middle strip area: $(mid.area)")
    end
    
    @testset "Strip vertices conversion" begin
        # Test converting strip polygons to absolute coordinates
        verts = [
            Meshes.Point(0.0, 0.0, 0.0),
            Meshes.Point(10.0, 0.0, 0.0),
            Meshes.Point(10.0, 8.0, 0.0),
            Meshes.Point(0.0, 8.0, 0.0)
        ]
        
        tribs = StructuralSizer.get_tributary_polygons_isotropic(verts)
        strips = compute_panel_strips(tribs)
        
        # Get vertices for first column strip
        cs = strips.column_strips[1]
        beam_start = (0.0, 0.0)
        beam_end = (10.0, 0.0)
        
        abs_verts = StructuralSizer.vertices(cs, beam_start, beam_end)
        
        # Should have vertices
        @test length(abs_verts) >= 3
        
        # All vertices should be within panel bounds (with some tolerance)
        for v in abs_verts
            @test -0.1 <= v[1] <= 10.1
            @test -0.1 <= v[2] <= 8.1
        end
        
        println("Column strip 1 vertices: $(length(abs_verts)) points")
    end
end

println("\n✓ Strip geometry tests complete!")
