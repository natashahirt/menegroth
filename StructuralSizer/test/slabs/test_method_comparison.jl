# =============================================================================
# Test: DDM vs MDDM vs EFM Side-by-Side Comparison
# =============================================================================
#
# Runs all three analysis methods on the same 3-span structure and compares:
# - Total static moment M₀
# - Design moments (negative/positive)
# - Moment coefficients as % of M₀
# - Column shears
#
# Reference: StructurePoint DE-Two-Way-Flat-Plate Example (18×14 ft panel)
#
# Uses 3 spans so DDM applicability is satisfied (ACI 318-11 §13.6.1.1
# requires ≥3 spans) and EFM has proper multi-span continuity.
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
    sdl::typeof(1.0psf)
    live_load::typeof(1.0psf)
    self_weight::typeof(1.0psf)
    spans::NamedTuple{(:primary, :secondary), Tuple{typeof(1.0u"ft"), typeof(1.0u"ft")}}
    position::Symbol
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
    column_above::Union{Nothing, MockColumn}
end

# Outer constructor without column_above (convenience)
MockColumn(vi, pos, story, c1, c2, base) =
    MockColumn(vi, pos, story, c1, c2, base, nothing)

# =============================================================================
# Mock Structure Setup (3-Span StructurePoint Example)
# =============================================================================

"""
Create a 3-span mock structure based on the StructurePoint 18×14 ft example.

Geometry:
- 3 panels: 18 ft × 14 ft (N-S × E-W)
- 4 columns: 16" × 16" square
- Story height: 9 ft
- Columns above and below at each joint (typical interior floor)

Loads (per StructurePoint):
- SDL = 20 psf (partitions)
- LL = 50 psf (office)
"""
function create_structurepoint_mock()
    span_ft = 18.0
    trib_ft = 14.0
    n_spans = 3
    n_cols  = n_spans + 1

    # Create cells (3 panels)
    cells = [
        MockCell(
            1, 1,
            span_ft * trib_ft * u"ft^2",
            20.0psf, 50.0psf, 0.0psf,
            (primary = span_ft * u"ft", secondary = trib_ft * u"ft"),
            :edge       # end span
        ),
        MockCell(
            2, 2,
            span_ft * trib_ft * u"ft^2",
            20.0psf, 50.0psf, 0.0psf,
            (primary = span_ft * u"ft", secondary = trib_ft * u"ft"),
            :interior   # interior span
        ),
        MockCell(
            3, 3,
            span_ft * trib_ft * u"ft^2",
            20.0psf, 50.0psf, 0.0psf,
            (primary = span_ft * u"ft", secondary = trib_ft * u"ft"),
            :edge       # end span
        ),
    ]

    # Skeleton vertices — column locations along the span direction
    vertices = [
        Meshes.Point(0.0, 0.0),
        Meshes.Point(span_ft, 0.0),
        Meshes.Point(2 * span_ft, 0.0),
        Meshes.Point(3 * span_ft, 0.0),
    ]

    # Column dimensions
    c_dim = 16.0u"inch"
    H     = 9.0u"ft"

    # Create columns — each has a column_above (typical interior floor)
    columns = MockColumn[]
    for i in 1:n_cols
        pos = (i == 1 || i == n_cols) ? :edge : :interior
        col = MockColumn(i, pos, 1, c_dim, c_dim, MockBase(H))
        # Column above: same size, same height (typical)
        col.column_above = MockColumn(i, pos, 2, c_dim, c_dim, MockBase(H))
        push!(columns, col)
    end

    # Tributary cache (half-panel per column at ends, full panel at interior)
    half_area = span_ft * trib_ft / 2
    trib_cache = Dict(
        1 => Dict(1 => half_area * u"ft^2"),
        2 => Dict(1 => half_area * u"ft^2", 2 => half_area * u"ft^2"),
        3 => Dict(2 => half_area * u"ft^2", 3 => half_area * u"ft^2"),
        4 => Dict(3 => half_area * u"ft^2"),
    )

    # Slab — DDM/EFM only look at spans from cell_indices[1]
    slab = (
        cell_indices = [1, 2, 3],
        spans = (primary = span_ft * u"ft", secondary = trib_ft * u"ft"),
    )

    struc = (
        skeleton = (vertices = vertices, edges = [], faces = [1, 2, 3]),
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
    fc = 4000.0u"psi"
    Ecs = Ec(fc)
    ρ_concrete = 2400.0u"kg/m^3"
    h = 7.0u"inch"

    result = StructuralSizer.run_moment_analysis(
        method, struc, slab, columns, h, fc, Ecs, ρ_concrete;
        verbose=false
    )

    return result, h
end

# =============================================================================
# Comparison Test
# =============================================================================

@testset "DDM vs MDDM vs EFM Comparison (3-span)" begin

    struc, slab, columns = create_structurepoint_mock()

    println("\n" * "="^70)
    println("FLAT PLATE ANALYSIS METHOD COMPARISON (3 spans)")
    println("="^70)
    println("Reference: StructurePoint 18×14 ft Panel (ACI 318-14)")
    println("="^70)

    # DDM (Full)
    ddm_result, h_ddm = run_analysis(DDM(), struc, slab, columns)

    # MDDM (Simplified)
    mddm_result, h_mddm = run_analysis(DDM(:simplified), struc, slab, columns)

    # EFM (pattern_loading=false for clean comparison — same uniform qu)
    efm_result, h_efm = run_analysis(EFM(pattern_loading=false), struc, slab, columns)

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
    @printf("│  Factored load qu:     %8.2f psf                                 │\n", ustrip(psf, ddm_result.qu))
    println("└─────────────────────────────────────────────────────────────────────┘")

    println("\n┌─────────────────────────────────────────────────────────────────────┐")
    println("│                     MOMENT ANALYSIS RESULTS                         │")
    println("├──────────────────┬──────────────┬──────────────┬──────────────┬─────┤")
    println("│     Parameter    │     DDM      │     MDDM     │     EFM      │Unit │")
    println("├──────────────────┼──────────────┼──────────────┼──────────────┼─────┤")

    M0_ddm  = ustrip(kip*u"ft", ddm_result.M0)
    M0_mddm = ustrip(kip*u"ft", mddm_result.M0)
    M0_efm  = ustrip(kip*u"ft", efm_result.M0)
    @printf("│  M₀ (static)     │ %10.2f   │ %10.2f   │ %10.2f   │k-ft │\n", M0_ddm, M0_mddm, M0_efm)

    M_ext_ddm  = ustrip(kip*u"ft", ddm_result.M_neg_ext)
    M_ext_mddm = ustrip(kip*u"ft", mddm_result.M_neg_ext)
    M_ext_efm  = ustrip(kip*u"ft", efm_result.M_neg_ext)
    @printf("│  M⁻ (exterior)   │ %10.2f   │ %10.2f   │ %10.2f   │k-ft │\n", M_ext_ddm, M_ext_mddm, M_ext_efm)

    M_pos_ddm  = ustrip(kip*u"ft", ddm_result.M_pos)
    M_pos_mddm = ustrip(kip*u"ft", mddm_result.M_pos)
    M_pos_efm  = ustrip(kip*u"ft", efm_result.M_pos)
    @printf("│  M⁺ (positive)   │ %10.2f   │ %10.2f   │ %10.2f   │k-ft │\n", M_pos_ddm, M_pos_mddm, M_pos_efm)

    M_int_ddm  = ustrip(kip*u"ft", ddm_result.M_neg_int)
    M_int_mddm = ustrip(kip*u"ft", mddm_result.M_neg_int)
    M_int_efm  = ustrip(kip*u"ft", efm_result.M_neg_int)
    @printf("│  M⁻ (interior)   │ %10.2f   │ %10.2f   │ %10.2f   │k-ft │\n", M_int_ddm, M_int_mddm, M_int_efm)

    println("├──────────────────┼──────────────┼──────────────┼──────────────┼─────┤")

    Vu_ddm  = ustrip(kip, ddm_result.Vu_max)
    Vu_mddm = ustrip(kip, mddm_result.Vu_max)
    Vu_efm  = ustrip(kip, efm_result.Vu_max)
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

    c_ext_ddm  = 100 * M_ext_ddm  / M0_ddm
    c_ext_mddm = 100 * M_ext_mddm / M0_mddm
    c_ext_efm  = 100 * M_ext_efm  / M0_efm
    @printf("│  Exterior neg    │ %10.1f%%  │ %10.1f%%  │ %10.1f%%  │ 26%% │\n", c_ext_ddm, c_ext_mddm, c_ext_efm)

    c_pos_ddm  = 100 * M_pos_ddm  / M0_ddm
    c_pos_mddm = 100 * M_pos_mddm / M0_mddm
    c_pos_efm  = 100 * M_pos_efm  / M0_efm
    @printf("│  Positive        │ %10.1f%%  │ %10.1f%%  │ %10.1f%%  │ 52%% │\n", c_pos_ddm, c_pos_mddm, c_pos_efm)

    c_int_ddm  = 100 * M_int_ddm  / M0_ddm
    c_int_mddm = 100 * M_int_mddm / M0_mddm
    c_int_efm  = 100 * M_int_efm  / M0_efm
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

    sp_M0 = 93.82   # kip-ft (SP uses LL=40 psf; we use 50 psf → higher M0)
    sp_qu = 193.0    # psf

    our_qu = ustrip(psf, ddm_result.qu)
    qu_diff = 100 * (our_qu - sp_qu) / sp_qu
    qu_ok = abs(qu_diff) < 10 ? "✓" : "✗"
    @printf("│  qu (factored)   │ %10.1f   │ %10.1f   │ %+10.1f   │  %s  │\n", sp_qu, our_qu, qu_diff, qu_ok)

    M0_diff = 100 * (M0_ddm - sp_M0) / sp_M0
    @printf("│  M₀ (k-ft)*      │ %10.2f   │ %10.2f   │ %+10.1f   │  -  │\n", sp_M0, M0_ddm, M0_diff)

    println("├──────────────────┴──────────────┴──────────────┴──────────────┴─────┤")
    println("│  * SP uses LL=40 psf; we use LL=50 psf, so M₀ differs as expected   │")
    println("└─────────────────────────────────────────────────────────────────────┘")

    # ==========================================================================
    # Basic Tests
    # ==========================================================================

    @testset "Basic Sanity Checks" begin
        @test ddm_result.M0  > 0kip*u"ft"
        @test mddm_result.M0 > 0kip*u"ft"
        @test efm_result.M0  > 0kip*u"ft"

        # M0 should be same across methods (same loads/geometry)
        @test ddm_result.M0 ≈ mddm_result.M0 rtol=0.01
        @test ddm_result.M0 ≈ efm_result.M0  rtol=0.01

        # DDM coefficients should match ACI Table 8.10.4.2
        @test c_ext_ddm ≈ 26.0 rtol=0.05
        @test c_pos_ddm ≈ 52.0 rtol=0.05
        @test c_int_ddm ≈ 70.0 rtol=0.05

        # MDDM should produce reasonable moments
        @test mddm_result.M_neg_int > 0kip*u"ft"
        @test mddm_result.M_pos     > 0kip*u"ft"
    end

    @testset "Method Differences" begin
        @test efm_result.M_neg_ext > 0kip*u"ft"
        @test efm_result.M_pos     > 0kip*u"ft"
        @test efm_result.M_neg_int > 0kip*u"ft"

        # With Kec torsional reduction, EFM and DDM should agree reasonably.
        # Exterior negative has the most sensitivity (DDM uses 26% fixed coeff,
        # EFM uses actual stiffness with Kec).
        @test abs(M_ext_efm - M_ext_ddm) / M_ext_ddm < 0.50  # Exterior: within 50%
        @test abs(M_pos_efm - M_pos_ddm) / M_pos_ddm < 0.30  # Positive: within 30%
        @test abs(M_int_efm - M_int_ddm) / M_int_ddm < 0.35  # Interior: within 35%
    end

    println("\n" * "="^70)
    println("✓ All comparison tests passed!")
    println("="^70 * "\n")
end
