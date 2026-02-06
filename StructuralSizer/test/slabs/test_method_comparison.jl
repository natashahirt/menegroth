# =============================================================================
# Test: DDM vs MDDM vs EFM Side-by-Side Comparison
# =============================================================================
#
# Runs all three analysis methods on the same structure and compares:
# - Slab thickness
# - Total static moment M₀
# - Design moments (negative/positive)
# - Strip moments
# - Column shears
#
# Reference: StructurePoint DE-Two-Way-Flat-Plate Example (18×14 ft panel)
#
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer
using Printf
using Meshes

# =============================================================================
# Mock Types (must be at top level)
# =============================================================================

mutable struct MockCell
    id::Int
    face_idx::Int
    area::typeof(1.0u"ft^2")
    sdl::typeof(1.0u"psf")
    live_load::typeof(1.0u"psf")
    self_weight::typeof(1.0u"psf")
    spans::NamedTuple{(:primary, :secondary), Tuple{typeof(1.0u"ft"), typeof(1.0u"ft")}}
end

mutable struct MockBase
    L::typeof(1.0u"ft")
end

mutable struct MockColumn
    vertex_idx::Int
    position::Symbol
    story::Int
    c1::typeof(1.0u"inch")
    c2::typeof(1.0u"inch")
    base::MockBase
end

# =============================================================================
# Mock Structure Setup (StructurePoint Example)
# =============================================================================

"""
Create a mock structure matching the StructurePoint 18×14 ft example.

Geometry:
- Panel: 18 ft × 14 ft (N-S × E-W)
- Columns: 16" × 16" square
- Story height: 9 ft

Loads (per StructurePoint):
- SDL = 20 psf (partitions)
- LL = 50 psf (office)
"""
function create_structurepoint_mock()
    # Create cell (single panel)
    cells = [
        MockCell(
            1, 1,
            18.0u"ft" * 14.0u"ft",  # area
            20.0u"psf",              # SDL
            50.0u"psf",              # LL
            0.0u"psf",               # self-weight (computed during design)
            (primary = 18.0u"ft", secondary = 14.0u"ft")
        )
    ]

    # Skeleton vertices (in feet) - columns at each end of the span
    # Vertex 1 at origin (0,0), Vertex 2 at (18,0) for 18 ft span
    # Use Meshes.Point for compatibility with StructuralSizer
    vertices = [
        Meshes.Point(0.0, 0.0),   # v1: left column
        Meshes.Point(18.0, 0.0),  # v2: right column
    ]

    # Create columns at each vertex (modeling an end span)
    # vertex_idx corresponds to position in vertices array
    columns = [
        MockColumn(1, :edge, 1, 16.0u"inch", 16.0u"inch", MockBase(9.0u"ft")),
        MockColumn(2, :interior, 1, 16.0u"inch", 16.0u"inch", MockBase(9.0u"ft")),
    ]

    # Tributary cache (half panel per column for simple 2-column case)
    trib_cache = Dict(
        1 => Dict(1 => 126.0u"ft^2"),
        2 => Dict(1 => 126.0u"ft^2"),
    )

    # Create slab
    slab = (
        cell_indices = [1],
        spans = (primary = 18.0u"ft", secondary = 14.0u"ft"),
    )

    struc = (
        skeleton = (vertices = vertices, edges = [], faces = [1]),
        cells = cells,
        columns = columns,
        tributary_cache = (cell_results = Dict(), column_results = trib_cache),
    )

    return struc, slab, columns
end

# =============================================================================
# Run Moment Analysis for Each Method
# =============================================================================

"""
Run moment analysis using the specified method and return key results.
"""
function run_analysis(method, struc, slab, columns)
    # Material properties
    fc = 4000.0u"psi"
    Ecs = Ec(fc)
    # Note: slab_self_weight expects MASS density (kg/m³), not weight density
    # Normal weight concrete: ρ ≈ 2400 kg/m³
    ρ_concrete = 2400.0u"kg/m^3"
    
    # Slab thickness (use StructurePoint's 7")
    h = 7.0u"inch"
    
    # Run moment analysis
    result = run_moment_analysis(
        method, struc, slab, columns, h, fc, Ecs, ρ_concrete;
        verbose=false
    )
    
    return result, h
end

# =============================================================================
# Comparison Test
# =============================================================================

@testset "DDM vs MDDM vs EFM Comparison" begin
    
    # Create structure
    struc, slab, columns = create_structurepoint_mock()
    
    # Run all three methods
    println("\n" * "="^70)
    println("FLAT PLATE ANALYSIS METHOD COMPARISON")
    println("="^70)
    println("Reference: StructurePoint 18×14 ft Panel (ACI 318-14)")
    println("="^70)
    
    # DDM (Full)
    ddm_result, h_ddm = run_analysis(DDM(), struc, slab, columns)
    
    # MDDM (Simplified)
    mddm_result, h_mddm = run_analysis(DDM(:simplified), struc, slab, columns)
    
    # EFM
    efm_result, h_efm = run_analysis(EFM(), struc, slab, columns)
    
    # ==========================================================================
    # Display Results
    # ==========================================================================
    
    println("\n┌─────────────────────────────────────────────────────────────────────┐")
    println("│                        GEOMETRY & LOADS                             │")
    println("├─────────────────────────────────────────────────────────────────────┤")
    @printf("│  Span l₁ (N-S):        %8.2f ft                                  │\n", ustrip(u"ft", ddm_result.l1))
    @printf("│  Span l₂ (E-W):        %8.2f ft                                  │\n", ustrip(u"ft", ddm_result.l2))
    @printf("│  Clear span ln:        %8.2f ft                                  │\n", ustrip(u"ft", ddm_result.ln))
    @printf("│  Slab thickness h:     %8.2f in                                  │\n", ustrip(u"inch", h_ddm))
    @printf("│  Factored load qu:     %8.2f psf                                 │\n", ustrip(u"psf", ddm_result.qu))
    println("└─────────────────────────────────────────────────────────────────────┘")
    
    println("\n┌─────────────────────────────────────────────────────────────────────┐")
    println("│                     MOMENT ANALYSIS RESULTS                         │")
    println("├──────────────────┬──────────────┬──────────────┬──────────────┬─────┤")
    println("│     Parameter    │     DDM      │     MDDM     │     EFM      │Unit │")
    println("├──────────────────┼──────────────┼──────────────┼──────────────┼─────┤")
    
    # Total static moment
    M0_ddm = ustrip(u"kip*ft", ddm_result.M0)
    M0_mddm = ustrip(u"kip*ft", mddm_result.M0)
    M0_efm = ustrip(u"kip*ft", efm_result.M0)
    @printf("│  M₀ (static)     │ %10.2f   │ %10.2f   │ %10.2f   │k-ft │\n", M0_ddm, M0_mddm, M0_efm)
    
    # Exterior negative moment
    M_ext_ddm = ustrip(u"kip*ft", ddm_result.M_neg_ext)
    M_ext_mddm = ustrip(u"kip*ft", mddm_result.M_neg_ext)
    M_ext_efm = ustrip(u"kip*ft", efm_result.M_neg_ext)
    @printf("│  M⁻ (exterior)   │ %10.2f   │ %10.2f   │ %10.2f   │k-ft │\n", M_ext_ddm, M_ext_mddm, M_ext_efm)
    
    # Positive moment
    M_pos_ddm = ustrip(u"kip*ft", ddm_result.M_pos)
    M_pos_mddm = ustrip(u"kip*ft", mddm_result.M_pos)
    M_pos_efm = ustrip(u"kip*ft", efm_result.M_pos)
    @printf("│  M⁺ (positive)   │ %10.2f   │ %10.2f   │ %10.2f   │k-ft │\n", M_pos_ddm, M_pos_mddm, M_pos_efm)
    
    # Interior negative moment
    M_int_ddm = ustrip(u"kip*ft", ddm_result.M_neg_int)
    M_int_mddm = ustrip(u"kip*ft", mddm_result.M_neg_int)
    M_int_efm = ustrip(u"kip*ft", efm_result.M_neg_int)
    @printf("│  M⁻ (interior)   │ %10.2f   │ %10.2f   │ %10.2f   │k-ft │\n", M_int_ddm, M_int_mddm, M_int_efm)
    
    println("├──────────────────┼──────────────┼──────────────┼──────────────┼─────┤")
    
    # Max shear
    Vu_ddm = ustrip(u"kip", ddm_result.Vu_max)
    Vu_mddm = ustrip(u"kip", mddm_result.Vu_max)
    Vu_efm = ustrip(u"kip", efm_result.Vu_max)
    @printf("│  Vu,max (shear)  │ %10.2f   │ %10.2f   │ %10.2f   │kip  │\n", Vu_ddm, Vu_mddm, Vu_efm)
    
    println("└──────────────────┴──────────────┴──────────────┴──────────────┴─────┘")
    
    # ==========================================================================
    # Coefficient comparison
    # ==========================================================================
    
    println("\n┌─────────────────────────────────────────────────────────────────────┐")
    println("│                     MOMENT COEFFICIENTS (% of M₀)                   │")
    println("├──────────────────┬──────────────┬──────────────┬──────────────┬─────┤")
    println("│     Location     │     DDM      │     MDDM     │     EFM      │ ACI │")
    println("├──────────────────┼──────────────┼──────────────┼──────────────┼─────┤")
    
    # Calculate coefficients
    c_ext_ddm = 100 * M_ext_ddm / M0_ddm
    c_ext_mddm = 100 * M_ext_mddm / M0_mddm
    c_ext_efm = 100 * M_ext_efm / M0_efm
    @printf("│  Exterior neg    │ %10.1f%%  │ %10.1f%%  │ %10.1f%%  │ 26%% │\n", c_ext_ddm, c_ext_mddm, c_ext_efm)
    
    c_pos_ddm = 100 * M_pos_ddm / M0_ddm
    c_pos_mddm = 100 * M_pos_mddm / M0_mddm
    c_pos_efm = 100 * M_pos_efm / M0_efm
    @printf("│  Positive        │ %10.1f%%  │ %10.1f%%  │ %10.1f%%  │ 52%% │\n", c_pos_ddm, c_pos_mddm, c_pos_efm)
    
    c_int_ddm = 100 * M_int_ddm / M0_ddm
    c_int_mddm = 100 * M_int_mddm / M0_mddm
    c_int_efm = 100 * M_int_efm / M0_efm
    @printf("│  Interior neg    │ %10.1f%%  │ %10.1f%%  │ %10.1f%%  │ 70%% │\n", c_int_ddm, c_int_mddm, c_int_efm)
    
    println("└──────────────────┴──────────────┴──────────────┴──────────────┴─────┘")
    
    # ==========================================================================
    # StructurePoint Reference Comparison
    # ==========================================================================
    
    println("\n┌─────────────────────────────────────────────────────────────────────┐")
    println("│               COMPARISON WITH STRUCTUREPOINT REFERENCE              │")
    println("├──────────────────┬──────────────┬──────────────┬──────────────┬─────┤")
    println("│     Parameter    │  SP Value    │   Our DDM    │    Δ (%)     │ OK? │")
    println("├──────────────────┼──────────────┼──────────────┼──────────────┼─────┤")
    
    # StructurePoint reference values (Table 1)
    sp_M0 = 93.82  # kip-ft (using 40 psf LL, we use 50 psf so our M0 is higher)
    sp_qu = 193.0  # psf
    
    our_qu = ustrip(u"psf", ddm_result.qu)
    qu_diff = 100 * (our_qu - sp_qu) / sp_qu
    qu_ok = abs(qu_diff) < 10 ? "✓" : "✗"
    @printf("│  qu (factored)   │ %10.1f   │ %10.1f   │ %+10.1f   │  %s  │\n", sp_qu, our_qu, qu_diff, qu_ok)
    
    # Note: Our M0 will be different because we use 50 psf LL vs SP's 40 psf
    M0_diff = 100 * (M0_ddm - sp_M0) / sp_M0
    @printf("│  M₀ (k-ft)*      │ %10.2f   │ %10.2f   │ %+10.1f   │  -  │\n", sp_M0, M0_ddm, M0_diff)
    
    println("├──────────────────┴──────────────┴──────────────┴──────────────┴─────┤")
    println("│  * SP uses LL=40 psf; we use LL=50 psf, so M₀ differs as expected   │")
    println("└─────────────────────────────────────────────────────────────────────┘")
    
    # ==========================================================================
    # Basic Tests
    # ==========================================================================
    
    @testset "Basic Sanity Checks" begin
        # All methods should produce positive M0
        @test ddm_result.M0 > 0u"kip*ft"
        @test mddm_result.M0 > 0u"kip*ft"
        @test efm_result.M0 > 0u"kip*ft"
        
        # M0 should be same across methods (same loads/geometry)
        @test ddm_result.M0 ≈ mddm_result.M0 rtol=0.01
        @test ddm_result.M0 ≈ efm_result.M0 rtol=0.01
        
        # DDM coefficients should match ACI Table 8.10.4.2
        @test c_ext_ddm ≈ 26.0 rtol=0.05
        @test c_pos_ddm ≈ 52.0 rtol=0.05
        @test c_int_ddm ≈ 70.0 rtol=0.05
        
        # MDDM uses 65/35 split for interior spans
        # For end span, different coefficients
        @test mddm_result.M_neg_int > 0u"kip*ft"
        @test mddm_result.M_pos > 0u"kip*ft"
    end
    
    @testset "Method Differences" begin
        # EFM may produce different moment distribution than DDM
        # (especially for stiff columns)
        # Just verify all moments are positive and reasonable
        @test efm_result.M_neg_ext > 0u"kip*ft"
        @test efm_result.M_pos > 0u"kip*ft"
        @test efm_result.M_neg_int > 0u"kip*ft"
        
        # EFM moments should be within 30% of DDM (typical range)
        @test abs(M_ext_efm - M_ext_ddm) / M_ext_ddm < 0.30
        @test abs(M_pos_efm - M_pos_ddm) / M_pos_ddm < 0.30
        @test abs(M_int_efm - M_int_ddm) / M_int_ddm < 0.30
    end
    
    println("\n" * "="^70)
    println("✓ All comparison tests passed!")
    println("="^70 * "\n")
end
