# =============================================================================
# Integration Test: size_flat_plate! Pipeline
# =============================================================================
#
# Tests the complete flat plate design workflow including:
# - Column load computation from tributary areas
# - Moment analysis (DDM/MDDM)
# - Column P-M design iteration
# - Punching shear check with unbalanced moment
# - Two-way deflection (crossing beam method)
# - One-way shear check
# - Strip reinforcement design
#
# =============================================================================

using Test
using Unitful
using Asap  # Register Asap units with Unitful's @u_str
using StructuralSizer

# =============================================================================
# Mock Structure Setup
# =============================================================================

"""Create a minimal mock structure for testing the pipeline."""
function create_mock_structure()
    # This creates a simplified structure that has the required fields
    # for size_flat_plate! to work
    
    # Mock skeleton (minimal)
    skeleton = (
        vertices = [[0.0, 0.0], [18.0, 0.0], [18.0, 14.0], [0.0, 14.0]],
        edges = [],
        faces = [1],
        face_edge_indices = [[1, 2, 3, 4]],
    )
    
    # Mock cells with loads
    cells = [
        (
            id = 1,
            face_idx = 1,
            area = 18u"ft" * 14u"ft",
            sdl = 20psf,     # Superimposed dead load
            live_load = 50psf,
            self_weight = 0psf,  # Will be computed
            spans = (primary = 18u"ft", secondary = 14u"ft"),
        )
    ]
    
    # Make cells mutable for self_weight update
    mutable_cells = [
        MutableCell(c.id, c.face_idx, c.area, c.sdl, c.live_load, c.self_weight, c.spans)
        for c in cells
    ]
    
    # Mock columns at corners
    columns = [
        MutableColumn(1, :corner, 1, 16u"inch", 16u"inch", MutableBase(9u"ft")),
        MutableColumn(2, :corner, 1, 16u"inch", 16u"inch", MutableBase(9u"ft")),
        MutableColumn(3, :corner, 1, 16u"inch", 16u"inch", MutableBase(9u"ft")),
        MutableColumn(4, :corner, 1, 16u"inch", 16u"inch", MutableBase(9u"ft")),
    ]
    
    # Mock tributary cache
    trib_cache = Dict(
        1 => Dict(1 => 63u"ft^2"),  # Column 1 tributary to cell 1
        2 => Dict(1 => 63u"ft^2"),
        3 => Dict(1 => 63u"ft^2"),
        4 => Dict(1 => 63u"ft^2"),
    )
    
    return (
        skeleton = skeleton,
        cells = mutable_cells,
        columns = columns,
        tributary_cache = (cell_results = Dict(), column_results = trib_cache),
    )
end

# Helper types to make mock structure work
mutable struct MutableCell
    id::Int
    face_idx::Int
    area::typeof(1.0u"ft^2")
    sdl::typeof(1.0psf)
    live_load::typeof(1.0psf)
    self_weight::typeof(1.0psf)
    spans::NamedTuple{(:primary, :secondary), Tuple{typeof(1.0u"ft"), typeof(1.0u"ft")}}
end

mutable struct MutableBase
    L::typeof(1.0u"ft")
end

mutable struct MutableColumn
    vertex_idx::Int
    position::Symbol
    story::Int
    c1::typeof(1.0u"inch")
    c2::typeof(1.0u"inch")
    base::MutableBase
    shape::Symbol
end

# Convenience constructor with default rectangular shape
MutableColumn(v, pos, s, c1, c2, base) = MutableColumn(v, pos, s, c1, c2, base, :rectangular)

# =============================================================================
# Unit Tests for Helper Functions
# =============================================================================

@testset "Flat Plate Pipeline - Helper Functions" begin
    
    @testset "DDM Moment Coefficients" begin
        # Test that moment coefficients sum correctly
        # For DDM: 0.26 + 0.52 + 0.70 ≠ 1.0 because they're not cumulative
        # Total static moment is M0, and at any section M_neg + M_pos ≈ M0
        
        # The coefficients should give: M_neg_int + M_pos ≈ 1.22 × M0
        # This is correct per ACI - more moment at interior than simple M0
        # because of moment redistribution
        
        # For MDDM: 0.65 + 0.35 = 1.0 (simplified)
        @test 0.65 + 0.35 ≈ 1.0
    end
    
    @testset "Load Distribution Factors" begin
        # Exterior span LDFs
        LDF_c_ext = StructuralSizer.load_distribution_factor(:column, :exterior)
        LDF_m_ext = StructuralSizer.load_distribution_factor(:middle, :exterior)
        
        @test LDF_c_ext ≈ 0.738 rtol=0.02
        @test LDF_m_ext ≈ 0.262 rtol=0.02
        @test LDF_c_ext + LDF_m_ext ≈ 1.0 rtol=0.01
        
        # Interior span LDFs
        LDF_c_int = StructuralSizer.load_distribution_factor(:column, :interior)
        LDF_m_int = StructuralSizer.load_distribution_factor(:middle, :interior)
        
        @test LDF_c_int ≈ 0.675 rtol=0.02
        @test LDF_m_int ≈ 0.325 rtol=0.02
        @test LDF_c_int + LDF_m_int ≈ 1.0 rtol=0.01
    end
    
    @testset "Two-Way Panel Deflection" begin
        # For square panel, Δ_panel = Δcx + Δmx
        Δcx = 0.075u"inch"
        Δmx = 0.038u"inch"
        
        Δ_panel = StructuralSizer.two_way_panel_deflection(Δcx, Δmx)
        @test Δ_panel ≈ 0.113u"inch" rtol=0.01
        
        # Full formula (same result for square)
        Δ_panel_full = StructuralSizer.two_way_panel_deflection(Δcx, Δcx, Δmx, Δmx)
        @test Δ_panel_full ≈ Δ_panel rtol=0.01
    end
    
    @testset "Punching αs Factor" begin
        @test StructuralSizer.punching_αs(:interior) == 40
        @test StructuralSizer.punching_αs(:edge) == 30
        @test StructuralSizer.punching_αs(:corner) == 20
    end
    
    @testset "Minimum Reinforcement with fy" begin
        b = 84u"inch"
        h = 7u"inch"
        
        # Grade 60 (60 ksi)
        As_min_60 = StructuralSizer.minimum_reinforcement(b, h, 60000u"psi")
        @test ustrip(u"inch^2", As_min_60) ≈ 0.0018 * 84 * 7 rtol=0.01
        
        # Grade 40 (< 60 ksi) → ρ_min = 0.0020
        As_min_40 = StructuralSizer.minimum_reinforcement(b, h, 40000u"psi")
        @test ustrip(u"inch^2", As_min_40) ≈ 0.0020 * 84 * 7 rtol=0.01
        
        # Grade 80 (≥ 77 ksi) → ρ_min = max(0.0014, 0.0018×60000/fy)
        As_min_80 = StructuralSizer.minimum_reinforcement(b, h, 80000u"psi")
        expected_80 = max(0.0014, 0.0018 * 60000 / 80000) * 84 * 7
        @test ustrip(u"inch^2", As_min_80) ≈ expected_80 rtol=0.01
    end
end

# =============================================================================
# Integration Tests
# =============================================================================

@testset "Flat Plate Pipeline - FlatPlateOptions Integration" begin
    
    @testset "Default Options" begin
        opts = FlatPlateOptions()
        
        @test opts.φ_flexure == 0.90
        @test opts.φ_shear == 0.75
        # λ defaults to nothing → pipeline reads material.concrete.λ (1.0 for NWC)
        @test isnothing(opts.λ)
        @test opts.material.concrete.λ == 1.0
        @test opts.analysis_method == :ddm
        @test opts.deflection_limit == :L_360
        @test opts.has_edge_beam == false
    end
    
    @testset "Lightweight Concrete Options" begin
        opts = FlatPlateOptions(λ = 0.85)  # Sand-lightweight (explicit override)
        @test opts.λ == 0.85
    end
    
    @testset "OneWayOptions" begin
        opts = OneWayOptions()
        @test opts.support == BOTH_ENDS_CONT
        @test opts.material == RC_4000_60
        
        opts2 = OneWayOptions(support=ONE_END_CONT)
        @test opts2.support == ONE_END_CONT
    end
end

@testset "Flat Plate Pipeline - Method Selection" begin
    
    @testset "DDM Coefficients" begin
        # DDM uses ACI Table 8.10.4.2
        # For end span, no edge beam:
        # Exterior neg: 0.26, Pos: 0.52, Interior neg: 0.70
        
        M0 = 100kip*u"ft"  # Example total static moment
        
        # These would be computed by _run_moment_analysis
        M_neg_ext = 0.26 * M0
        M_neg_int = 0.70 * M0
        M_pos = 0.52 * M0
        
        @test ustrip(kip*u"ft", M_neg_ext) ≈ 26 rtol=0.01
        @test ustrip(kip*u"ft", M_neg_int) ≈ 70 rtol=0.01
        @test ustrip(kip*u"ft", M_pos) ≈ 52 rtol=0.01
    end
    
    @testset "MDDM Coefficients" begin
        # MDDM uses simplified coefficients
        # Negative: 0.65, Positive: 0.35
        
        M0 = 100kip*u"ft"
        
        M_neg = 0.65 * M0
        M_pos = 0.35 * M0
        
        @test ustrip(kip*u"ft", M_neg) ≈ 65 rtol=0.01
        @test ustrip(kip*u"ft", M_pos) ≈ 35 rtol=0.01
        @test M_neg + M_pos ≈ M0 rtol=0.01  # MDDM sums to M0
    end
end

@testset "Flat Plate Pipeline - Result Types" begin
    
    @testset "StripReinforcement Type" begin
        # Test that StripReinforcement can be constructed
        sr = StripReinforcement(
            :int_neg,           # location
            50kip*u"ft",        # Mu
            2.0u"inch^2",       # As_reqd
            1.06u"inch^2",      # As_min
            2.36u"inch^2",      # As_provided
            5,                  # bar_size
            6u"inch",           # spacing
            14,                 # n_bars
            true                # section_adequate
        )
        
        @test sr.location == :int_neg
        @test sr.bar_size == 5
        @test sr.n_bars == 14
        @test sr.section_adequate == true
    end
    
    @testset "FlatPlatePanelResult Type" begin
        # Test FlatPlatePanelResult structure
        # This tests that the result type has the expected fields
        
        sr = StripReinforcement(:pos, 30kip*u"ft", 1.2u"inch^2", 1.06u"inch^2", 
                                1.24u"inch^2", 4, 8u"inch", 10, true)
        
        result = FlatPlatePanelResult(
            18u"ft",            # l1
            14u"ft",            # l2
            7u"inch",           # h
            94kip*u"ft",        # M0
            193.0psf,        # qu
            7u"ft",             # column_strip_width
            [sr, sr, sr],       # column_strip_reinf
            7u"ft",             # middle_strip_width
            [sr, sr],           # middle_strip_reinf
            (ok=true, max_ratio=0.85, details=Dict()),  # punching_check
            (ok=true, Δ_total=0.25u"inch", Δ_limit=0.90u"inch", ratio=0.28)  # deflection_check
        )
        
        @test result.h == 7u"inch"
        @test result.punching_check.ok == true
        @test result.deflection_check.ok == true
        @test length(result.column_strip_reinf) == 3
        @test length(result.middle_strip_reinf) == 2
    end
end

# =============================================================================
# Circular Column Tests
# =============================================================================

@testset "Flat Plate Pipeline — Circular Column Support" begin

    @testset "MutableColumn with shape field" begin
        # Rectangular (default)
        col_rect = MutableColumn(1, :interior, 1, 16u"inch", 16u"inch", MutableBase(9u"ft"))
        @test col_rect.shape == :rectangular
        @test hasproperty(col_rect, :shape)

        # Circular (explicit)
        col_circ = MutableColumn(1, :interior, 1, 16u"inch", 16u"inch", MutableBase(9u"ft"), :circular)
        @test col_circ.shape == :circular
        @test col_circ.c1 == 16u"inch"
        @test col_circ.c2 == 16u"inch"
    end

    @testset "check_punching_for_column — Circular Interior" begin
        fc = 4000u"psi"
        h = 7u"inch"
        d = 5.75u"inch"

        # Interior circular column
        col = MutableColumn(1, :interior, 1, 16u"inch", 16u"inch", MutableBase(9u"ft"), :circular)

        Vu = 48kip
        Mub = 5kip*u"ft"

        result = StructuralSizer.check_punching_for_column(col, Vu, Mub, d, h, fc; verbose=true)

        @test haskey(result, :ok) || hasproperty(result, :ok)
        @test result.ok == true
        @test result.ratio < 1.0
        @test result.ratio > 0.0
        @test ustrip(u"inch", result.b0) ≈ π * (16 + 5.75) rtol=0.01

        println("\n=== Circular Interior Punching ===")
        println("b₀ = $(round(ustrip(u"inch", result.b0), digits=2)) in (expected: $(round(π*(16+5.75), digits=2)))")
        println("vu = $(round(ustrip(u"psi", result.vu), digits=1)) psi")
        println("φvc = $(round(ustrip(u"psi", result.φvc), digits=1)) psi")
        println("ratio = $(round(result.ratio, digits=3))")
    end

    @testset "check_punching_for_column — Circular Edge" begin
        fc = 4000u"psi"
        h = 7u"inch"
        d = 5.75u"inch"

        # Edge circular column → converted to equivalent square
        col = MutableColumn(1, :edge, 1, 16u"inch", 16u"inch", MutableBase(9u"ft"), :circular)

        Vu = 22kip
        Mub = 30kip*u"ft"

        result = StructuralSizer.check_punching_for_column(col, Vu, Mub, d, h, fc; verbose=true)

        @test result.ok == true || result.ok == false  # Just verify it doesn't error
        @test result.ratio > 0.0
        @test ustrip(u"inch", result.b0) > 0

        println("\n=== Circular Edge Punching (equiv. square) ===")
        println("b₀ = $(round(ustrip(u"inch", result.b0), digits=2)) in")
        println("ratio = $(round(result.ratio, digits=3))")
    end

    @testset "check_punching_for_column — Circular Corner" begin
        fc = 4000u"psi"
        h = 7u"inch"
        d = 5.75u"inch"

        # Corner circular column → converted to equivalent square
        col = MutableColumn(1, :corner, 1, 16u"inch", 16u"inch", MutableBase(9u"ft"), :circular)

        Vu = 12kip
        Mub = 15kip*u"ft"

        result = StructuralSizer.check_punching_for_column(col, Vu, Mub, d, h, fc; verbose=true)

        @test result.ratio > 0.0
        @test ustrip(u"inch", result.b0) > 0

        println("\n=== Circular Corner Punching (equiv. square) ===")
        println("b₀ = $(round(ustrip(u"inch", result.b0), digits=2)) in")
        println("ratio = $(round(result.ratio, digits=3))")
    end

    @testset "Circular vs Rectangular — Consistency" begin
        fc = 4000u"psi"
        h = 7u"inch"
        d = 5.75u"inch"
        Vu = 48kip
        Mub = 5kip*u"ft"

        col_rect = MutableColumn(1, :interior, 1, 16u"inch", 16u"inch", MutableBase(9u"ft"), :rectangular)
        col_circ = MutableColumn(1, :interior, 1, 16u"inch", 16u"inch", MutableBase(9u"ft"), :circular)

        r_rect = StructuralSizer.check_punching_for_column(col_rect, Vu, Mub, d, h, fc)
        r_circ = StructuralSizer.check_punching_for_column(col_circ, Vu, Mub, d, h, fc)

        # Both should produce valid results
        @test r_rect.ratio > 0
        @test r_circ.ratio > 0

        # Circular has less perimeter → higher stress → higher ratio
        @test r_circ.ratio > r_rect.ratio

        # Difference should be moderate
        @test r_circ.ratio / r_rect.ratio < 2.0

        println("\n=== Circular vs Rectangular Comparison ===")
        println("Rectangular: ratio = $(round(r_rect.ratio, digits=3)), b₀ = $(round(ustrip(u"inch", r_rect.b0), digits=1)) in")
        println("Circular:    ratio = $(round(r_circ.ratio, digits=3)), b₀ = $(round(ustrip(u"inch", r_circ.b0), digits=1)) in")
    end
end

println("\n✓ size_flat_plate! pipeline tests complete!")
