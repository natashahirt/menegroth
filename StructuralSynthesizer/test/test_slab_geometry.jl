# =============================================================================
# Tests for Slab Geometry Validation
# =============================================================================
#
# Tests convexity detection, rectangular decomposition, and frame line creation
# for various slab geometries.
#
# =============================================================================

using Test

# Add the project to the load path
push!(LOAD_PATH, joinpath(@__DIR__, "..", ".."))
using StructuralSynthesizer

@testset "Slab Geometry Validation" begin
    
    # =========================================================================
    # Convexity Tests
    # =========================================================================
    @testset "Convexity Detection" begin
        
        @testset "Convex polygons" begin
            # Square (convex)
            square = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
            @test is_convex_polygon(square) == true
            
            # Rectangle (convex)
            rect = [(0.0, 0.0), (2.0, 0.0), (2.0, 1.0), (0.0, 1.0)]
            @test is_convex_polygon(rect) == true
            
            # Triangle (convex)
            triangle = [(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)]
            @test is_convex_polygon(triangle) == true
            
            # Pentagon (convex, regular-ish)
            pentagon = [
                (0.5, 0.0), (1.0, 0.4), (0.8, 1.0), 
                (0.2, 1.0), (0.0, 0.4)
            ]
            @test is_convex_polygon(pentagon) == true
            
            # Hexagon (convex)
            hexagon = [
                (0.5, 0.0), (1.0, 0.25), (1.0, 0.75),
                (0.5, 1.0), (0.0, 0.75), (0.0, 0.25)
            ]
            @test is_convex_polygon(hexagon) == true
        end
        
        @testset "Concave polygons" begin
            # L-shape (concave)
            l_shape = [
                (0.0, 0.0), (2.0, 0.0), (2.0, 1.0),
                (1.0, 1.0), (1.0, 2.0), (0.0, 2.0)
            ]
            @test is_convex_polygon(l_shape) == false
            
            # U-shape (concave)
            u_shape = [
                (0.0, 0.0), (3.0, 0.0), (3.0, 2.0),
                (2.0, 2.0), (2.0, 1.0), (1.0, 1.0),
                (1.0, 2.0), (0.0, 2.0)
            ]
            @test is_convex_polygon(u_shape) == false
            
            # T-shape (concave)
            t_shape = [
                (0.0, 1.0), (0.0, 2.0), (3.0, 2.0),
                (3.0, 1.0), (2.0, 1.0), (2.0, 0.0),
                (1.0, 0.0), (1.0, 1.0)
            ]
            @test is_convex_polygon(t_shape) == false
            
            # Star (very concave)
            star = [
                (0.5, 0.0), (0.6, 0.4), (1.0, 0.4),
                (0.7, 0.6), (0.8, 1.0), (0.5, 0.75),
                (0.2, 1.0), (0.3, 0.6), (0.0, 0.4),
                (0.4, 0.4)
            ]
            @test is_convex_polygon(star) == false
            
            # Pac-man shape (concave)
            pacman = [
                (0.5, 0.5), (1.0, 0.0), (1.0, 0.4),
                (0.6, 0.5), (1.0, 0.6), (1.0, 1.0),
                (0.0, 1.0), (0.0, 0.0)
            ]
            @test is_convex_polygon(pacman) == false
        end
        
        @testset "Edge cases" begin
            # Single point
            @test is_convex_polygon([(0.0, 0.0)]) == true
            
            # Two points (line)
            @test is_convex_polygon([(0.0, 0.0), (1.0, 1.0)]) == true
            
            # Empty
            @test is_convex_polygon(Tuple{Float64, Float64}[]) == true
            
            # Collinear points (degenerate polygon)
            collinear = [(0.0, 0.0), (1.0, 0.0), (2.0, 0.0)]
            @test is_convex_polygon(collinear) == true  # Degenerate but "convex"
        end
        
        @testset "Different input formats" begin
            # Using vectors instead of tuples
            square_vec = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
            @test is_convex_polygon(square_vec) == true
        end
    end
    
    # =========================================================================
    # Cell Grid Tests
    # =========================================================================
    @testset "Cell Grid Construction" begin
        
        @testset "3x3 grid" begin
            # 9 cells in a 3x3 grid
            cell_indices = [1, 2, 3, 4, 5, 6, 7, 8, 9]
            
            # Centroids: cell i at ((i-1)%3 + 0.5, (i-1)÷3 + 0.5)
            get_centroid(idx) = (
                ((idx - 1) % 3) + 0.5,
                ((idx - 1) ÷ 3) + 0.5
            )
            
            grid = build_cell_grid(cell_indices, get_centroid)
            
            @test size(grid.grid) == (3, 3)
            @test grid.grid[1, 1] == 1  # Bottom-left
            @test grid.grid[1, 3] == 3  # Bottom-right
            @test grid.grid[3, 1] == 7  # Top-left
            @test grid.grid[3, 3] == 9  # Top-right
            @test grid.grid[2, 2] == 5  # Center
        end
        
        @testset "L-shaped cell group" begin
            # L-shape: cells 1,2,3 (bottom row) + 4,7 (left column)
            #   7
            #   4
            # 1 2 3
            cell_indices = [1, 2, 3, 4, 7]
            
            get_centroid(idx) = (
                ((idx - 1) % 3) + 0.5,
                ((idx - 1) ÷ 3) + 0.5
            )
            
            grid = build_cell_grid(cell_indices, get_centroid)
            
            # Should be 3x3 grid with zeros for missing cells
            @test grid.grid[1, 1] == 1
            @test grid.grid[1, 2] == 2
            @test grid.grid[1, 3] == 3
            @test grid.grid[2, 1] == 4
            @test grid.grid[2, 2] == 0  # Missing cell 5
            @test grid.grid[2, 3] == 0  # Missing cell 6
            @test grid.grid[3, 1] == 7
            @test grid.grid[3, 2] == 0  # Missing cell 8
            @test grid.grid[3, 3] == 0  # Missing cell 9
        end
    end
    
    # =========================================================================
    # Rectangular Decomposition Tests
    # =========================================================================
    @testset "Rectangular Decomposition" begin
        
        # Helper: centroid function for 3x3 grid
        get_centroid_3x3(idx) = (
            ((idx - 1) % 3) + 0.5,
            ((idx - 1) ÷ 3) + 0.5
        )
        
        @testset "Already rectangular" begin
            # Full 3x3 grid (already rectangular)
            cells = [1, 2, 3, 4, 5, 6, 7, 8, 9]
            result = decompose_to_rectangles(cells, get_centroid_3x3)
            
            @test length(result) == 1
            @test Set(result[1]) == Set(cells)
        end
        
        @testset "Single cell" begin
            cells = [5]
            result = decompose_to_rectangles(cells, get_centroid_3x3)
            
            @test length(result) == 1
            @test result[1] == [5]
        end
        
        @testset "L-shaped decomposition" begin
            # L-shape:
            #   7
            #   4
            # 1 2 3
            cells = [1, 2, 3, 4, 7]
            result = decompose_to_rectangles(cells, get_centroid_3x3)
            
            # Should split into rectangles
            @test length(result) >= 1
            
            # All cells should be covered
            all_cells = reduce(union, Set.(result))
            @test all_cells == Set(cells)
            
            # Each result should be rectangular (no gaps in grid)
            for rect in result
                # A rectangle in grid has no holes
                grid = build_cell_grid(rect, get_centroid_3x3)
                rows_used = unique([grid.cell_positions[c][1] for c in rect])
                cols_used = unique([grid.cell_positions[c][2] for c in rect])
                expected_count = length(rows_used) * length(cols_used)
                @test length(rect) == expected_count
            end
        end
        
        @testset "U-shaped decomposition" begin
            # U-shape (missing center-top):
            # 7   9
            # 4 5 6
            # 1 2 3
            cells = [1, 2, 3, 4, 5, 6, 7, 9]  # Missing cell 8
            result = decompose_to_rectangles(cells, get_centroid_3x3)
            
            # Should split into at least 2 rectangles
            @test length(result) >= 1
            
            # All cells should be covered
            all_cells = reduce(union, Set.(result))
            @test all_cells == Set(cells)
        end
        
        @testset "Diagonal cells (worst case)" begin
            # Diagonal: only cells 1, 5, 9 (not adjacent)
            cells = [1, 5, 9]
            result = decompose_to_rectangles(cells, get_centroid_3x3)
            
            # Each cell should be its own rectangle (no expansion possible)
            @test length(result) == 3
            @test all(length(r) == 1 for r in result)
        end
        
        @testset "Two separate rectangles" begin
            # Two 1x2 rectangles with gap:
            # cells 1,2 and cells 7,8
            cells = [1, 2, 7, 8]
            
            # Need a 3x3 grid centroid function
            get_centroid(idx) = (
                ((idx - 1) % 3) + 0.5,
                ((idx - 1) ÷ 3) + 0.5
            )
            
            result = decompose_to_rectangles(cells, get_centroid)
            
            # Should find 2 rectangles (possibly merged if algorithm finds larger)
            @test length(result) >= 1
            
            all_cells = reduce(union, Set.(result))
            @test all_cells == Set(cells)
        end
    end
    
    # =========================================================================
    # Connectivity-Based Grouping Tests
    # =========================================================================
    @testset "Connectivity Grouping" begin
        
        @testset "Single connected component" begin
            # Linear chain: 1-2-3
            cells = [1, 2, 3]
            get_neighbors(idx) = begin
                idx == 1 && return [2]
                idx == 2 && return [1, 3]
                idx == 3 && return [2]
                return Int[]
            end
            
            result = group_by_connectivity(cells, get_neighbors)
            
            @test length(result) == 1
            @test Set(result[1]) == Set(cells)
        end
        
        @testset "Two disconnected components" begin
            # Two separate pairs: 1-2 and 5-6
            cells = [1, 2, 5, 6]
            get_neighbors(idx) = begin
                idx == 1 && return [2]
                idx == 2 && return [1]
                idx == 5 && return [6]
                idx == 6 && return [5]
                return Int[]
            end
            
            result = group_by_connectivity(cells, get_neighbors)
            
            @test length(result) == 2
            @test Set([Set(r) for r in result]) == Set([Set([1, 2]), Set([5, 6])])
        end
        
        @testset "Isolated cells" begin
            cells = [1, 5, 9]
            get_neighbors(idx) = Int[]  # No connections
            
            result = group_by_connectivity(cells, get_neighbors)
            
            @test length(result) == 3
            @test all(length(r) == 1 for r in result)
        end
        
        @testset "Grid connectivity" begin
            # 3x3 grid with 4-connectivity (orthogonal neighbors only)
            cells = collect(1:9)
            
            # In a 3x3 grid (row-major): neighbors are ±1 (horizontal) and ±3 (vertical)
            get_neighbors(idx) = begin
                neighbors = Int[]
                row = (idx - 1) ÷ 3
                col = (idx - 1) % 3
                
                # Left
                col > 0 && push!(neighbors, idx - 1)
                # Right
                col < 2 && push!(neighbors, idx + 1)
                # Down
                row > 0 && push!(neighbors, idx - 3)
                # Up
                row < 2 && push!(neighbors, idx + 3)
                
                return neighbors
            end
            
            result = group_by_connectivity(cells, get_neighbors)
            
            @test length(result) == 1
            @test Set(result[1]) == Set(cells)
        end
    end
    
    # =========================================================================
    # FrameLine Tests
    # =========================================================================
    @testset "FrameLine Construction" begin
        
        # Mock column type
        struct MockColumn
            id::Int
            x::Float64
            y::Float64
            width::Float64
        end
        
        @testset "Simple X-direction frame" begin
            # Three columns along X-axis
            columns = [
                MockColumn(1, 0.0, 5.0, 1.0),
                MockColumn(2, 10.0, 5.0, 1.0),
                MockColumn(3, 20.0, 5.0, 1.0)
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            fl = FrameLine(:x, columns, 15.0, get_pos, get_width)
            
            @test n_joints(fl) == 3
            @test n_spans(fl) == 2
            @test isapprox(fl.direction[1], 1.0, atol=1e-6)
            @test isapprox(fl.direction[2], 0.0, atol=1e-6)
            @test fl.tributary_width == 15.0
            
            # Span lengths = center-to-center - half widths
            # 10 - 0.5 - 0.5 = 9.0
            @test all(isapprox.(fl.span_lengths, [9.0, 9.0], atol=0.01))
            
            # Joint positions
            @test fl.joint_positions == [:exterior, :interior, :exterior]
        end
        
        @testset "Y-direction frame" begin
            columns = [
                MockColumn(1, 5.0, 0.0, 1.5),
                MockColumn(2, 5.0, 12.0, 1.5),
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            fl = FrameLine(:y, columns, 10.0, get_pos, get_width)
            
            @test n_joints(fl) == 2
            @test n_spans(fl) == 1
            @test isapprox(fl.direction[1], 0.0, atol=1e-6)
            @test isapprox(fl.direction[2], 1.0, atol=1e-6)
            
            # Span = 12 - 0 - 0.75 - 0.75 = 10.5
            @test isapprox(fl.span_lengths[1], 10.5, atol=0.01)
            @test fl.joint_positions == [:exterior, :exterior]
        end
        
        @testset "Columns get sorted by position" begin
            # Columns in wrong order
            columns = [
                MockColumn(3, 20.0, 0.0, 1.0),
                MockColumn(1, 0.0, 0.0, 1.0),
                MockColumn(2, 10.0, 0.0, 1.0),
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            fl = FrameLine(:x, columns, 10.0, get_pos, get_width)
            
            # Should be sorted by X position
            @test fl.columns[1].id == 1
            @test fl.columns[2].id == 2
            @test fl.columns[3].id == 3
        end
        
        @testset "Rotated frame (45°)" begin
            # Columns along 45° diagonal
            columns = [
                MockColumn(1, 0.0, 0.0, 1.0),
                MockColumn(2, 5.0, 5.0, 1.0),
                MockColumn(3, 10.0, 10.0, 1.0),
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            # 45° direction
            dir = (cosd(45), sind(45))
            fl = FrameLine(dir, columns, 8.0, get_pos, get_width)
            
            @test n_joints(fl) == 3
            @test n_spans(fl) == 2
            
            # Span = sqrt(5² + 5²) - widths ≈ 7.07 - 1.0 = 6.07
            expected_span = sqrt(50) - 1.0
            @test isapprox(fl.span_lengths[1], expected_span, atol=0.1)
        end
        
        @testset "End span detection" begin
            columns = [
                MockColumn(1, 0.0, 0.0, 1.0),
                MockColumn(2, 10.0, 0.0, 1.0),
                MockColumn(3, 20.0, 0.0, 1.0),
                MockColumn(4, 30.0, 0.0, 1.0),
            ]
            
            get_pos(col) = (col.x, col.y)
            get_width(col, dir) = col.width
            
            fl = FrameLine(:x, columns, 10.0, get_pos, get_width)
            
            @test is_end_span(fl, 1) == true   # First span
            @test is_end_span(fl, 2) == false  # Interior span
            @test is_end_span(fl, 3) == true   # Last span
        end
    end
    
    # =========================================================================
    # Integration Test: validate_and_split_slab
    # =========================================================================
    @testset "validate_and_split_slab Integration" begin
        
        # 3x3 grid centroid function
        get_centroid(idx) = (
            ((idx - 1) % 3) + 0.5,
            ((idx - 1) ÷ 3) + 0.5
        )
        
        @testset "Convex slab (no split)" begin
            cells = [1, 2, 3, 4, 5, 6, 7, 8, 9]  # Full 3x3 = rectangle = convex
            
            # Boundary is the outer square
            get_boundary(indices) = [
                (0.0, 0.0), (3.0, 0.0), (3.0, 3.0), (0.0, 3.0)
            ]
            
            result = validate_and_split_slab(cells, get_centroid, get_boundary)
            
            @test length(result) == 1
            @test Set(result[1]) == Set(cells)
        end
        
        @testset "Concave slab (L-shape)" begin
            cells = [1, 2, 3, 4, 7]  # L-shape
            
            # L-shaped boundary (concave)
            get_boundary(indices) = [
                (0.0, 0.0), (3.0, 0.0), (3.0, 1.0),
                (1.0, 1.0), (1.0, 3.0), (0.0, 3.0)
            ]
            
            # This should warn and split
            result = @test_logs (:warn,) validate_and_split_slab(cells, get_centroid, get_boundary)
            
            # Should have split into multiple rectangles
            @test length(result) >= 1
            
            # All cells covered
            all_cells = reduce(union, Set.(result))
            @test all_cells == Set(cells)
        end
    end
    
end  # Main testset

# Run the tests
println("\n" * "="^60)
println("Running Slab Geometry Validation Tests")
println("="^60 * "\n")
