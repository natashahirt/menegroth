# =============================================================================
# Tests for FrameLine-Based DDM Analysis
# Validates DDM with explicit multi-span FrameLine input
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using Asap  # For unit registration
using StructuralSizer

# =============================================================================
# Minimal FrameLine Implementation for Standalone Testing
# =============================================================================
# This allows the test to run without StructuralSynthesizer

"""Simple FrameLine struct for testing."""
struct TestFrameLine{T, C}
    direction::NTuple{2, Float64}
    columns::Vector{C}
    tributary_width::T
    span_lengths::Vector{T}
    joint_positions::Vector{Symbol}
    column_projections::Vector{Float64}
end

"""Helper functions for TestFrameLine."""
n_spans(fl::TestFrameLine) = length(fl.span_lengths)
n_joints(fl::TestFrameLine) = length(fl.columns)

"""Construct FrameLine from direction symbol."""
function TestFrameLine(
    direction::Symbol,
    columns::Vector{C},
    tributary_width::T,
    get_position_fn::Function,
    get_width_fn::Function
) where {T, C}
    dir = direction == :x ? (1.0, 0.0) : (0.0, 1.0)
    return TestFrameLine(dir, columns, tributary_width, get_position_fn, get_width_fn)
end

"""Construct FrameLine from direction tuple."""
function TestFrameLine(
    direction::NTuple{2, Float64},
    columns::Vector{C},
    tributary_width::T,
    get_position_fn::Function,
    get_width_fn::Function
) where {T, C}
    n = length(columns)
    dir_norm = sqrt(direction[1]^2 + direction[2]^2)
    dir = (direction[1] / dir_norm, direction[2] / dir_norm)
    
    # Project each column position onto the frame axis
    projections = map(columns) do col
        pos = get_position_fn(col)
        Float64(pos[1] * dir[1] + pos[2] * dir[2])
    end
    
    # Sort by projection
    perm = sortperm(projections)
    sorted_cols = columns[perm]
    sorted_proj = projections[perm]
    
    # Compute clear spans (positions in feet, column widths in inches)
    span_lengths = T[]
    for i in 1:(n-1)
        c_to_c_ft = sorted_proj[i+1] - sorted_proj[i]  # feet
        c_left = get_width_fn(sorted_cols[i], dir)      # unitful (inches)
        c_right = get_width_fn(sorted_cols[i+1], dir)   # unitful (inches)
        
        # Clear span = c-to-c - half widths (convert column widths to feet)
        c_left_ft = ustrip(u"ft", c_left)
        c_right_ft = ustrip(u"ft", c_right)
        ln_ft = c_to_c_ft - c_left_ft/2 - c_right_ft/2
        
        push!(span_lengths, ln_ft * u"ft")
    end
    
    # Joint positions: first and last are exterior
    joint_positions = Symbol[]
    for i in 1:n
        push!(joint_positions, (i == 1 || i == n) ? :exterior : :interior)
    end
    
    return TestFrameLine{T, C}(dir, sorted_cols, tributary_width, span_lengths, 
                               joint_positions, sorted_proj)
end

# =============================================================================
# Tests
# =============================================================================

@testset "FrameLine DDM Analysis" begin
    
    @testset "FrameLine Construction" begin
        # Create mock columns with positions (in feet) and dimensions
        cols = [
            (vertex_idx=1, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(0.0, 0.0)),
            (vertex_idx=2, c1=16u"inch", c2=16u"inch", position=:interior, 
             base=(L=10u"ft",), pos=(18.0, 0.0)),  # 18 ft from first
            (vertex_idx=3, c1=16u"inch", c2=16u"inch", position=:interior, 
             base=(L=10u"ft",), pos=(36.0, 0.0)),  # 18 ft from second
            (vertex_idx=4, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(54.0, 0.0)),  # 18 ft from third
        ]
        
        l2 = 14.0u"ft"  # Use Float64 to avoid InexactError
        
        # Position accessor (returns in feet)
        get_pos = col -> col.pos
        
        # Width accessor (returns column width in frame direction)
        get_width = (col, dir) -> col.c1
        
        # Build frame line
        fl = TestFrameLine(:x, cols, l2, get_pos, get_width)
        
        @test n_joints(fl) == 4
        @test n_spans(fl) == 3
        @test fl.tributary_width == l2
        
        # Joint positions
        @test fl.joint_positions[1] == :exterior
        @test fl.joint_positions[2] == :interior
        @test fl.joint_positions[3] == :interior
        @test fl.joint_positions[4] == :exterior
        
        # Span lengths: 18 ft c-to-c - 16" columns ≈ 16.67 ft clear
        for ln in fl.span_lengths
            @test ustrip(u"ft", ln) ≈ 16.67 rtol=0.05
        end
    end
    
    @testset "DDM with FrameLine - 3-Span Frame" begin
        # Recreate the StructurePoint example but with explicit FrameLine
        cols = [
            (vertex_idx=1, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(0.0, 0.0)),
            (vertex_idx=2, c1=16u"inch", c2=16u"inch", position=:interior, 
             base=(L=10u"ft",), pos=(18.0, 0.0)),
            (vertex_idx=3, c1=16u"inch", c2=16u"inch", position=:interior, 
             base=(L=10u"ft",), pos=(36.0, 0.0)),
            (vertex_idx=4, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(54.0, 0.0)),
        ]
        
        l2 = 14.0u"ft"  # Use Float64 to avoid InexactError
        get_pos = col -> col.pos
        get_width = (col, dir) -> col.c1
        
        fl = TestFrameLine(:x, cols, l2, get_pos, get_width)
        
        # Loads from StructurePoint example
        h = 7u"inch"
        γc = 150.0u"lbf/ft^3"  # Use explicit units for compatibility
        # sw = h * γc = 7in * 150 lb/ft³ = 7/12 ft * 150 lb/ft³ = 87.5 lb/ft²
        sw = uconvert(u"lbf/ft^2", uconvert(u"ft", h) * γc)
        sdl = 20.0u"lbf/ft^2"
        ll = 40.0u"lbf/ft^2"
        
        qD = sw + sdl
        qL = ll
        qu = 1.2 * qD + 1.6 * qL
        
        # Create minimal struc mock for DDM (needed for shear calc fallback)
        struc = (
            tributaries = (vertex = Dict{Int, Dict{Int, Any}}(),),
            skeleton = (vertices = [],),
        )
        
        # Run DDM with TestFrameLine
        result = StructuralSizer.run_moment_analysis(DDM(), fl, struc, qu, qD, qL; verbose=false)
        
        # Check total static moment (first span)
        # M0 = qu × l2 × ln² / 8
        # qu ≈ 193 psf, l2 = 14 ft, ln ≈ 16.67 ft
        # M0 ≈ 0.193 × 14 × 16.67² / 8 ≈ 93.8 kip-ft
        M0_kipft = ustrip(u"kip*ft", result.M0)
        @test M0_kipft ≈ 93.8 rtol=0.05
        
        # End span moments (ACI Table 8.10.4.2)
        # Exterior negative: 0.26 × M0 ≈ 24.4 kip-ft
        # Interior negative: 0.70 × M0 ≈ 65.7 kip-ft
        # Positive: 0.52 × M0 ≈ 48.8 kip-ft
        @test ustrip(u"kip*ft", result.M_neg_ext) ≈ 24.4 rtol=0.05
        @test ustrip(u"kip*ft", result.M_neg_int) ≈ 65.7 rtol=0.05
        @test ustrip(u"kip*ft", result.M_pos) ≈ 48.8 rtol=0.05
        
        # Should have 4 column moments
        @test length(result.column_moments) == 4
    end
    
    @testset "DDM Simplified (MDDM) with FrameLine" begin
        cols = [
            (vertex_idx=1, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(0.0, 0.0)),
            (vertex_idx=2, c1=16u"inch", c2=16u"inch", position=:interior, 
             base=(L=10u"ft",), pos=(18.0, 0.0)),
            (vertex_idx=3, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(36.0, 0.0)),
        ]
        
        l2 = 14.0u"ft"  # Use Float64
        get_pos = col -> col.pos
        get_width = (col, dir) -> col.c1
        
        fl = TestFrameLine(:x, cols, l2, get_pos, get_width)
        
        h = 7u"inch"
        γc = 150.0u"lbf/ft^3"
        sw = uconvert(u"lbf/ft^2", uconvert(u"ft", h) * γc)
        qD = sw + 20.0u"lbf/ft^2"
        qL = 40.0u"lbf/ft^2"
        qu = 1.2 * qD + 1.6 * qL
        
        struc = (tributaries = (vertex = Dict{Int, Dict{Int, Any}}(),), skeleton = (vertices = [],))
        
        # Run MDDM (simplified)
        result = StructuralSizer.run_moment_analysis(DDM(:simplified), fl, struc, qu, qD, qL)
        
        # MDDM uses 0.65/0.35 for all spans
        M0_kipft = ustrip(u"kip*ft", result.M0)
        @test ustrip(u"kip*ft", result.M_neg_ext) ≈ 0.65 * M0_kipft rtol=0.01
        @test ustrip(u"kip*ft", result.M_pos) ≈ 0.35 * M0_kipft rtol=0.01
    end
    
    @testset "FrameLine with Varying Span Lengths" begin
        # Unequal spans: 18 ft, 20 ft, 16 ft
        cols = [
            (vertex_idx=1, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(0.0, 0.0)),
            (vertex_idx=2, c1=18u"inch", c2=18u"inch", position=:interior, 
             base=(L=10u"ft",), pos=(18.0, 0.0)),   # 18 ft from first
            (vertex_idx=3, c1=20u"inch", c2=20u"inch", position=:interior, 
             base=(L=10u"ft",), pos=(38.0, 0.0)),   # 20 ft from second
            (vertex_idx=4, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(54.0, 0.0)),   # 16 ft from third
        ]
        
        l2 = 14.0u"ft"  # Use Float64
        get_pos = col -> col.pos
        get_width = (col, dir) -> col.c1
        
        fl = TestFrameLine(:x, cols, l2, get_pos, get_width)
        
        @test n_spans(fl) == 3
        
        # Verify varying span lengths
        span_lengths_ft = [ustrip(u"ft", ln) for ln in fl.span_lengths]
        @test span_lengths_ft[1] < span_lengths_ft[2]  # First span shorter than middle
        @test span_lengths_ft[3] < span_lengths_ft[2]  # Last span shorter than middle
        
        # Run analysis
        h = 7u"inch"
        γc = 150.0u"lbf/ft^3"
        sw = uconvert(u"lbf/ft^2", uconvert(u"ft", h) * γc)
        qD = sw + 20.0u"lbf/ft^2"
        qL = 40.0u"lbf/ft^2"
        qu = 1.2 * qD + 1.6 * qL
        
        struc = (tributaries = (vertex = Dict{Int, Dict{Int, Any}}(),), skeleton = (vertices = [],))
        result = StructuralSizer.run_moment_analysis(DDM(), fl, struc, qu, qD, qL)
        
        # Should complete without error
        @test !isnothing(result)
        @test length(result.column_moments) == 4
    end
    
    @testset "Single Span FrameLine (Edge Case)" begin
        # Only 2 columns = 1 span
        cols = [
            (vertex_idx=1, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(0.0, 0.0)),
            (vertex_idx=2, c1=16u"inch", c2=16u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(20.0, 0.0)),
        ]
        
        l2 = 14.0u"ft"  # Use Float64
        get_pos = col -> col.pos
        get_width = (col, dir) -> col.c1
        
        fl = TestFrameLine(:x, cols, l2, get_pos, get_width)
        
        @test n_spans(fl) == 1
        @test fl.joint_positions[1] == :exterior
        @test fl.joint_positions[2] == :exterior
        
        # Both supports are exterior = end span with both sides exterior
        h = 7u"inch"
        γc = 150.0u"lbf/ft^3"
        sw = uconvert(u"lbf/ft^2", uconvert(u"ft", h) * γc)
        qD = sw + 20.0u"lbf/ft^2"
        qL = 40.0u"lbf/ft^2"
        qu = 1.2 * qD + 1.6 * qL
        
        struc = (tributaries = (vertex = Dict{Int, Dict{Int, Any}}(),), skeleton = (vertices = [],))
        result = StructuralSizer.run_moment_analysis(DDM(), fl, struc, qu, qD, qL)
        
        @test length(result.column_moments) == 2
    end
    
    @testset "Y-Direction FrameLine" begin
        # Columns aligned in Y direction
        cols = [
            (vertex_idx=1, c1=16u"inch", c2=18u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(0.0, 0.0)),
            (vertex_idx=2, c1=16u"inch", c2=18u"inch", position=:interior, 
             base=(L=10u"ft",), pos=(0.0, 14.0)),
            (vertex_idx=3, c1=16u"inch", c2=18u"inch", position=:exterior, 
             base=(L=10u"ft",), pos=(0.0, 28.0)),
        ]
        
        l2 = 18.0u"ft"  # X-direction is now transverse (Float64)
        get_pos = col -> col.pos
        # For Y-direction frame, c2 is in the frame direction
        get_width = (col, dir) -> abs(dir[2]) > abs(dir[1]) ? col.c2 : col.c1
        
        fl = TestFrameLine(:y, cols, l2, get_pos, get_width)
        
        @test n_spans(fl) == 2
        @test fl.direction == (0.0, 1.0)
        
        # Span in Y: 14 ft - 18"/12 = 12.5 ft clear
        for ln in fl.span_lengths
            @test ustrip(u"ft", ln) ≈ 12.5 rtol=0.05
        end
    end
end

println("FrameLine DDM tests completed!")
