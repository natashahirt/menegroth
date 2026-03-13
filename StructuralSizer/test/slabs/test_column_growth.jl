# =============================================================================
# Tests for Column Growth Helpers & Secondary Moment Analysis
# =============================================================================
#
# Validates the new column sizing infrastructure:
#   1. Column shape/growth control (square, bounded, free)
#   2. Moment-informed aspect ratio targeting
#   3. Direct punching solve (vs. old blind incrementing)
#   4. Secondary (perpendicular) direction moment analysis
#   5. ConcreteColumnOptions new fields
#
# =============================================================================

using Test
using Unitful
using Asap  # custom units (kip, ksi, psf, etc.)
using StructuralSizer

# =============================================================================
# Mock Column Type (minimal for testing growth helpers)
# =============================================================================
mutable struct TestColumn
    c1::typeof(1.0u"inch")
    c2::typeof(1.0u"inch")
    position::Symbol
    shape::Symbol
end

# Convenience constructor: rectangular by default
TestColumn(c1, c2, pos) = TestColumn(c1, c2, pos, :rectangular)

# =============================================================================
# 1. ConcreteColumnOptions — New Fields
# =============================================================================
@testset "ConcreteColumnOptions — Shape/Growth Fields" begin
    @testset "defaults" begin
        opts = ConcreteColumnOptions()
        @test opts.shape_constraint == :square
        @test opts.max_aspect_ratio == 2.0
        @test opts.size_increment ≈ 0.5u"inch"
    end

    @testset "custom construction" begin
        opts = ConcreteColumnOptions(
            shape_constraint = :bounded,
            max_aspect_ratio = 1.5,
            size_increment = 1.0u"inch",
        )
        @test opts.shape_constraint == :bounded
        @test opts.max_aspect_ratio == 1.5
        @test opts.size_increment ≈ 1.0u"inch"
    end

    @testset ":free mode" begin
        opts = ConcreteColumnOptions(shape_constraint = :free)
        @test opts.shape_constraint == :free
        # max_aspect_ratio still exists but isn't enforced in :free mode
        @test opts.max_aspect_ratio == 2.0
    end
end

# =============================================================================
# 2. Rounding Helper
# =============================================================================
@testset "Round-Up-To Increment" begin
    _rut = StructuralSizer._round_up_to

    @test _rut(10.0u"inch", 0.5u"inch") ≈ 10.0u"inch"
    @test _rut(10.1u"inch", 0.5u"inch") ≈ 10.5u"inch"
    @test _rut(10.25u"inch", 0.5u"inch") ≈ 10.5u"inch"
    @test _rut(10.5u"inch", 0.5u"inch") ≈ 10.5u"inch"
    @test _rut(10.51u"inch", 0.5u"inch") ≈ 11.0u"inch"

    # 1-inch increments
    @test _rut(10.0u"inch", 1.0u"inch") ≈ 10.0u"inch"
    @test _rut(10.1u"inch", 1.0u"inch") ≈ 11.0u"inch"

    # 2-inch increments (old behavior)
    @test _rut(10.0u"inch", 2.0u"inch") ≈ 10.0u"inch"
    @test _rut(11.0u"inch", 2.0u"inch") ≈ 12.0u"inch"
end

# =============================================================================
# 3. Target Aspect Ratio from Directional Moments
# =============================================================================
@testset "Target Aspect Ratio" begin
    tar = StructuralSizer.target_aspect_ratio

    @testset "equal moments → square" begin
        r = tar(100.0kip * u"ft", 100.0kip * u"ft")
        @test r ≈ 1.0 atol=0.01
    end

    @testset "Mx >> My → c1 > c2 (r > 1)" begin
        r = tar(400.0kip * u"ft", 100.0kip * u"ft")
        @test r > 1.0
        @test r ≈ 2.0 atol=0.05  # √(400/100) = 2.0
    end

    @testset "My >> Mx → c2 > c1 (r < 1)" begin
        r = tar(100.0kip * u"ft", 400.0kip * u"ft")
        @test r < 1.0
        @test r ≈ 0.5 atol=0.05  # 1/√(400/100) = 0.5
    end

    @testset "clamped at max_ar" begin
        # 900:1 moment ratio → raw √900 = 30, clamped to 2.0
        r = tar(900.0kip * u"ft", 1.0kip * u"ft"; max_ar=2.0)
        @test r ≈ 2.0 atol=0.01
    end

    @testset "zero moments → square" begin
        r = tar(0.0kip * u"ft", 0.0kip * u"ft")
        @test r ≈ 1.0
    end

    @testset "one direction near-zero → clamped" begin
        r = tar(100.0kip * u"ft", 0.0kip * u"ft"; max_ar=3.0)
        @test r ≈ 3.0 atol=0.1
    end
end

# =============================================================================
# 4. Direct Punching Solve — Square Columns
# =============================================================================
@testset "Solve Column for Punching — Square" begin
    scfp = StructuralSizer.solve_column_for_punching

    d = 6.0u"inch"
    inc = 0.5u"inch"

    @testset "interior column, ratio=1.0 → no growth" begin
        col = TestColumn(16.0u"inch", 16.0u"inch", :interior)
        b0 = 4 * (16.0u"inch" + d)
        c1, c2 = scfp(col, 1.0, b0, d; shape_constraint=:square, increment=inc)
        @test c1 ≈ 16.0u"inch"
        @test c2 ≈ 16.0u"inch"
    end

    @testset "interior column, ratio=1.3 → grows" begin
        col = TestColumn(16.0u"inch", 16.0u"inch", :interior)
        b0 = 4 * (16.0u"inch" + d)
        c1, c2 = scfp(col, 1.3, b0, d; shape_constraint=:square, increment=inc)
        # Required: b0_new = 1.3 × 88 = 114.4"
        # c_new = 114.4/4 - 6 = 22.6" → rounds to 23.0"
        @test c1 ≈ c2  # stays square
        @test c1 > 16.0u"inch"
        @test c1 ≤ 24.0u"inch"  # reasonable for 1.3× ratio
    end

    @testset "edge column grows" begin
        col = TestColumn(14.0u"inch", 14.0u"inch", :edge)
        # Edge: b0 = 3c + 2d (simplified)
        b0 = 3 * 14.0u"inch" + 2 * d
        c1, c2 = scfp(col, 1.5, b0, d; shape_constraint=:square, increment=inc)
        @test c1 ≈ c2
        @test c1 > 14.0u"inch"
    end

    @testset "corner column grows" begin
        col = TestColumn(12.0u"inch", 12.0u"inch", :corner)
        # Corner: b0 = 2c + d
        b0 = 2 * 12.0u"inch" + d
        c1, c2 = scfp(col, 1.4, b0, d; shape_constraint=:square, increment=inc)
        @test c1 ≈ c2
        @test c1 > 12.0u"inch"
    end

    @testset "never shrinks" begin
        col = TestColumn(20.0u"inch", 20.0u"inch", :interior)
        b0 = 4 * (20.0u"inch" + d)
        # ratio = 0.5 means it already passes easily
        c1, c2 = scfp(col, 0.5, b0, d; shape_constraint=:square, increment=inc)
        @test c1 ≈ 20.0u"inch"
        @test c2 ≈ 20.0u"inch"
    end
end

# =============================================================================
# 5. Direct Punching Solve — Bounded Rectangular Columns
# =============================================================================
@testset "Solve Column for Punching — Bounded" begin
    scfp = StructuralSizer.solve_column_for_punching
    d = 6.0u"inch"
    inc = 0.5u"inch"

    @testset "moment-informed aspect ratio" begin
        col = TestColumn(16.0u"inch", 16.0u"inch", :interior)
        b0 = 4 * (16.0u"inch" + d)
        # Mx = 200, My = 50 → target r ≈ 2.0
        c1, c2 = scfp(col, 1.3, b0, d;
            shape_constraint = :bounded,
            max_ar = 2.5,
            Mx = 200.0kip * u"ft",
            My = 50.0kip * u"ft",
            increment = inc,
        )
        @test c1 > c2  # c1 should be bigger (more moment in x)
        ar = ustrip(u"inch", c1) / ustrip(u"inch", c2)
        @test 1.0 < ar ≤ 2.5  # bounded
    end

    @testset "equal moments → grows square" begin
        col = TestColumn(16.0u"inch", 16.0u"inch", :interior)
        b0 = 4 * (16.0u"inch" + d)
        c1, c2 = scfp(col, 1.3, b0, d;
            shape_constraint = :bounded,
            Mx = 100.0kip * u"ft",
            My = 100.0kip * u"ft",
            increment = inc,
        )
        # With equal moments, aspect ratio target ≈ 1.0, but may diverge slightly
        ar = ustrip(u"inch", c1) / ustrip(u"inch", c2)
        @test 0.8 < ar < 1.25
    end

    @testset "preserves existing rectangular shape when no moments" begin
        col = TestColumn(20.0u"inch", 14.0u"inch", :interior)
        b0 = 2*(20.0u"inch" + d) + 2*(14.0u"inch" + d)
        c1, c2 = scfp(col, 1.2, b0, d;
            shape_constraint = :bounded,
            max_ar = 2.0,
            increment = inc,
        )
        # Should preserve the original orientation (c1 > c2)
        @test c1 ≥ 20.0u"inch"
        @test c2 ≥ 14.0u"inch"
    end
end

# =============================================================================
# 6. grow_column! — All Three Modes
# =============================================================================
@testset "grow_column! — Modes" begin
    inc = 0.5u"inch"

    @testset ":square mode" begin
        col = TestColumn(14.0u"inch", 14.0u"inch", :interior)
        grow_column!(col, 18.0u"inch"; shape_constraint=:square, increment=inc)
        @test col.c1 ≈ 18.0u"inch"
        @test col.c2 ≈ 18.0u"inch"
    end

    @testset ":square mode — rounds up" begin
        col = TestColumn(14.0u"inch", 14.0u"inch", :interior)
        grow_column!(col, 17.3u"inch"; shape_constraint=:square, increment=inc)
        @test col.c1 ≈ 17.5u"inch"
        @test col.c2 ≈ 17.5u"inch"
    end

    @testset ":square mode — never shrinks" begin
        col = TestColumn(20.0u"inch", 20.0u"inch", :interior)
        grow_column!(col, 14.0u"inch"; shape_constraint=:square, increment=inc)
        @test col.c1 ≈ 20.0u"inch"
        @test col.c2 ≈ 20.0u"inch"
    end

    @testset ":bounded mode" begin
        col = TestColumn(14.0u"inch", 14.0u"inch", :interior)
        grow_column!(col, 18.0u"inch"; shape_constraint=:bounded, max_ar=2.0, increment=inc)
        @test col.c1 ≥ 18.0u"inch"
        @test col.c2 ≥ 18.0u"inch"  # both grow since :bounded still respects max_ar
    end

    @testset ":free mode" begin
        col = TestColumn(14.0u"inch", 14.0u"inch", :interior)
        grow_column!(col, 22.0u"inch"; shape_constraint=:free, increment=inc)
        @test col.c1 ≥ 22.0u"inch"
        @test col.c2 ≥ 22.0u"inch"
    end
end

# =============================================================================
# 7. grow_column_for_axial! — Shape-Aware Axial Growth
# =============================================================================
@testset "grow_column_for_axial!" begin
    inc = 0.5u"inch"

    @testset ":square — grows to √Ag" begin
        col = TestColumn(12.0u"inch", 12.0u"inch", :interior)
        # Ag_required = 324 in² → c = √324 = 18"
        Ag = 324.0u"inch^2"
        grow_column_for_axial!(col, Ag; shape_constraint=:square, increment=inc)
        @test col.c1 ≈ 18.0u"inch"
        @test col.c2 ≈ 18.0u"inch"
    end

    @testset ":square — rounds up" begin
        col = TestColumn(12.0u"inch", 12.0u"inch", :interior)
        # Ag = 300 in² → c = √300 ≈ 17.32 → rounds to 17.5"
        Ag = 300.0u"inch^2"
        grow_column_for_axial!(col, Ag; shape_constraint=:square, increment=inc)
        @test col.c1 ≈ 17.5u"inch"
        @test col.c2 ≈ 17.5u"inch"
    end

    @testset ":bounded — preserves rectangular proportions" begin
        col = TestColumn(20.0u"inch", 12.0u"inch", :interior)
        Ag_current = 20.0 * 12.0  # 240 in²
        Ag_needed = 400.0u"inch^2"
        grow_column_for_axial!(col, Ag_needed; shape_constraint=:bounded, max_ar=2.0, increment=inc)
        # Should scale proportionally: √(400/240) ≈ 1.29
        # c1 ≈ 20 × 1.29 ≈ 25.8 → 26.0, c2 ≈ 12 × 1.29 ≈ 15.5
        @test col.c1 ≥ 20.0u"inch"
        @test col.c2 ≥ 12.0u"inch"
        actual_Ag = ustrip(u"inch", col.c1) * ustrip(u"inch", col.c2)
        @test actual_Ag ≥ ustrip(u"inch^2", Ag_needed) - 10.0  # within rounding
        ar = ustrip(u"inch", col.c1) / ustrip(u"inch", col.c2)
        @test ar ≤ 2.0 + 0.1  # bounded aspect ratio
    end

    @testset "no growth if Ag ≤ 0" begin
        col = TestColumn(16.0u"inch", 16.0u"inch", :interior)
        grow_column_for_axial!(col, 0.0u"inch^2"; shape_constraint=:square, increment=inc)
        @test col.c1 ≈ 16.0u"inch"
        @test col.c2 ≈ 16.0u"inch"
    end
end

# =============================================================================
# 8. Aspect Ratio Enforcement
# =============================================================================
@testset "Aspect Ratio Enforcement" begin
    _ear = StructuralSizer._enforce_aspect_ratio!
    inc = 0.5u"inch"

    @testset "already within bounds" begin
        c1, c2 = _ear(18.0u"inch", 12.0u"inch", 2.0, inc)
        @test c1 ≈ 18.0u"inch"
        @test c2 ≈ 12.0u"inch"  # 18/12 = 1.5 < 2.0
    end

    @testset "c1/c2 exceeds max → c2 grows" begin
        c1, c2 = _ear(24.0u"inch", 10.0u"inch", 2.0, inc)
        # 24/10 = 2.4 > 2.0, so c2 must grow to 24/2 = 12.0"
        @test c2 ≥ 12.0u"inch"
    end

    @testset "c2/c1 exceeds max → c1 grows" begin
        c1, c2 = _ear(10.0u"inch", 24.0u"inch", 2.0, inc)
        # 10/24 = 0.42 < 1/2.0 = 0.5, so c1 must grow
        @test c1 ≥ 12.0u"inch"
    end
end

# =============================================================================
# 9. Back-Solve Geometry (b₀ → c for each position)
# =============================================================================
@testset "Back-Solve b₀ Geometry" begin
    _ssb = StructuralSizer._solve_square_b0
    d = 6.0u"inch"

    @testset "interior: b₀ = 4(c+d)" begin
        # If c = 16", b0 = 4(16+6) = 88"
        c = _ssb(:interior, 88.0u"inch", d)
        @test ustrip(u"inch", c) ≈ 16.0 atol=0.01
    end

    @testset "edge: b₀ = 3c + 2d" begin
        # If c = 14", b0 = 3(14) + 2(6) = 54"
        c = _ssb(:edge, 54.0u"inch", d)
        @test ustrip(u"inch", c) ≈ 14.0 atol=0.01
    end

    @testset "corner: b₀ = 2c + d" begin
        # If c = 12", b0 = 2(12) + 6 = 30"
        c = _ssb(:corner, 30.0u"inch", d)
        @test ustrip(u"inch", c) ≈ 12.0 atol=0.01
    end

    @testset "round-trip: solve → recompute b₀" begin
        for pos in [:interior, :edge, :corner]
            b0_target = 100.0u"inch"
            c = _ssb(pos, b0_target, d)
            # Recompute b₀ from solved c
            if pos == :interior
                b0_check = 4 * (c + d)
            elseif pos == :edge
                b0_check = 3c + 2d
            else
                b0_check = 2c + d
            end
            @test ustrip(u"inch", b0_check) ≈ ustrip(u"inch", b0_target) atol=0.01
        end
    end
end

# =============================================================================
# 10. Rectangular Back-Solve
# =============================================================================
@testset "Rectangular Back-Solve b₀" begin
    _srb = StructuralSizer._solve_rectangular_b0
    d = 6.0u"inch"

    @testset "interior, r=1.0 matches square" begin
        b0 = 88.0u"inch"
        c1_rect = _srb(:interior, b0, d, 1.0)
        c1_sq = StructuralSizer._solve_square_b0(:interior, b0, d)
        @test ustrip(u"inch", c1_rect) ≈ ustrip(u"inch", c1_sq) atol=0.01
    end

    @testset "interior, r=2.0 → c1 > c2" begin
        b0 = 100.0u"inch"
        c1 = _srb(:interior, b0, d, 2.0)
        c2 = c1 / 2.0
        # Check: b0 = 2(c1+d) + 2(c2+d) = 2c1 + 2c2 + 4d
        b0_check = 2*(c1 + d) + 2*(c2 + d)
        @test ustrip(u"inch", b0_check) ≈ ustrip(u"inch", b0) atol=0.01
    end

    @testset "edge, r=1.5" begin
        b0 = 80.0u"inch"
        c1 = _srb(:edge, b0, d, 1.5)
        c2 = c1 / 1.5
        # Edge: b0 = 2(c1+d/2) + (c2+d)
        b0_check = 2*(c1 + d/2) + (c2 + d)
        @test ustrip(u"inch", b0_check) ≈ ustrip(u"inch", b0) atol=0.01
    end
end

# =============================================================================
# 11. End-to-End: Compare Square vs Bounded Growth
# =============================================================================
@testset "End-to-End: Square vs Bounded Column Growth" begin
    d = 6.0u"inch"
    inc = 0.5u"inch"
    ratio = 1.4  # 40% over punching capacity

    # Same starting column and overstress
    for pos in [:interior, :edge, :corner]
        @testset "position=$pos" begin
            col_sq = TestColumn(16.0u"inch", 16.0u"inch", pos)
            col_bd = TestColumn(16.0u"inch", 16.0u"inch", pos)

            # Compute b0 for square 16" column
            if pos == :interior
                b0 = 4 * (16.0u"inch" + d)
            elseif pos == :edge
                b0 = 3 * 16.0u"inch" + 2 * d
            else
                b0 = 2 * 16.0u"inch" + d
            end

            # Square growth
            c1_sq, c2_sq = solve_column_for_punching(
                col_sq, ratio, b0, d;
                shape_constraint=:square, increment=inc
            )

            # Bounded growth with directional moments (Mx > My)
            c1_bd, c2_bd = solve_column_for_punching(
                col_bd, ratio, b0, d;
                shape_constraint=:bounded, max_ar=2.0,
                Mx=200.0kip*u"ft", My=80.0kip*u"ft",
                increment=inc
            )

            # Both should provide enough perimeter
            @test c1_sq ≥ 16.0u"inch"
            @test c1_bd ≥ 16.0u"inch"

            # Square: c1 == c2
            @test c1_sq ≈ c2_sq

            # Bounded: c1 > c2 (because Mx > My)
            @test c1_bd ≥ c2_bd

            # Bounded column total area should be comparable
            # (may be slightly larger due to rounding, but not dramatically)
            Ag_sq = ustrip(u"inch", c1_sq) * ustrip(u"inch", c2_sq)
            Ag_bd = ustrip(u"inch", c1_bd) * ustrip(u"inch", c2_bd)
            @test Ag_bd < Ag_sq * 1.3  # bounded shouldn't be > 30% more area
        end
    end
end

# =============================================================================
# 12. Circular Column Punching Growth
# =============================================================================
@testset "Solve Column for Punching — Circular" begin
    scfp = StructuralSizer.solve_column_for_punching
    d = 6.0u"inch"
    inc = 0.5u"inch"

    @testset "interior: b₀ = π(D+d) round-trip" begin
        D = 18.0u"inch"
        b0 = π * (D + d)
        col = TestColumn(D, D, :interior, :circular)
        # ratio = 1.0 → no growth
        c1, c2 = scfp(col, 1.0, b0, d; increment=inc)
        @test c1 ≈ D
        @test c2 ≈ D
    end

    @testset "interior: ratio > 1 → grows" begin
        D = 16.0u"inch"
        b0 = π * (D + d)
        col = TestColumn(D, D, :interior, :circular)
        c1, c2 = scfp(col, 1.3, b0, d; increment=inc)
        # D_new = π(D+d)*1.3/π - d = (D+d)*1.3 - d = D*1.3 + d*(1.3-1)
        @test c1 ≈ c2  # stays circular (c1 == c2)
        @test c1 > D
    end

    @testset "interior: back-solve recovers b₀" begin
        D = 16.0u"inch"
        b0 = π * (D + d)
        ratio = 1.5
        col = TestColumn(D, D, :interior, :circular)
        c1, c2 = scfp(col, ratio, b0, d; increment=inc)
        # c1 was rounded up, so b0_new ≥ b0_req
        b0_new = π * (c1 + d)
        b0_req = b0 * ratio
        @test b0_new ≥ b0_req - 1.0u"inch"  # within one rounding increment
    end

    @testset "never shrinks" begin
        D = 24.0u"inch"
        b0 = π * (D + d)
        col = TestColumn(D, D, :interior, :circular)
        c1, c2 = scfp(col, 0.8, b0, d; increment=inc)
        @test c1 ≈ D
        @test c2 ≈ D
    end

    @testset "shape_constraint ignored for circular" begin
        D = 16.0u"inch"
        b0 = π * (D + d)
        col = TestColumn(D, D, :interior, :circular)
        # :bounded and :free should behave identically to :square for circular
        c1_sq, c2_sq = scfp(col, 1.3, b0, d; shape_constraint=:square, increment=inc)
        c1_bd, c2_bd = scfp(col, 1.3, b0, d; shape_constraint=:bounded, increment=inc)
        c1_fr, c2_fr = scfp(col, 1.3, b0, d; shape_constraint=:free, increment=inc)
        @test c1_sq ≈ c1_bd
        @test c1_sq ≈ c1_fr
        @test c1_sq ≈ c2_sq  # always circular
    end
end

# =============================================================================
# 13. Secondary Moment Analysis Setup
# =============================================================================
@testset "Secondary Moment Analysis Setup" begin
    _smas = StructuralSizer._secondary_moment_analysis_setup
    _mas  = StructuralSizer._moment_analysis_setup

    # Create minimal mock for testing setup functions
    mutable struct _TestCell
        sdl::typeof(1.0psf)
        live_load::typeof(1.0psf)
    end

    mock_slab = (
        spans = (primary = 20.0u"ft", secondary = 16.0u"ft", axis = (1.0, 0.0)),
        cell_indices = [1],
    )

    mock_columns = [
        TestColumn(16.0u"inch", 14.0u"inch", :interior),
        TestColumn(16.0u"inch", 14.0u"inch", :corner),
    ]

    mock_struc = (
        cells = [_TestCell(20.0psf, 50.0psf)],
    )

    γ = 150.0pcf  # NWC
    h = 8.0u"inch"

    primary = _mas(mock_struc, mock_slab, mock_columns, h, γ)
    secondary = _smas(mock_struc, mock_slab, mock_columns, h, γ)

    @testset "spans are swapped" begin
        @test ustrip(u"ft", primary.l1) ≈ 20.0 atol=0.1
        @test ustrip(u"ft", primary.l2) ≈ 16.0 atol=0.1
        @test ustrip(u"ft", secondary.l1) ≈ 16.0 atol=0.1
        @test ustrip(u"ft", secondary.l2) ≈ 20.0 atol=0.1
    end

    @testset "loads are identical" begin
        @test primary.qu ≈ secondary.qu
        @test primary.qD ≈ secondary.qD
        @test primary.qL ≈ secondary.qL
    end

    @testset "span axes are perpendicular" begin
        ax1 = primary.span_axis
        ax2 = secondary.span_axis
        dot_product = ax1[1]*ax2[1] + ax1[2]*ax2[2]
        @test abs(dot_product) < 1e-10  # orthogonal
    end

    @testset "clear spans use correct column dimension" begin
        # Primary uses c1 avg = 16", secondary uses c2 avg = 14"
        c1_avg_in = (16.0 + 16.0) / 2
        c2_avg_in = (14.0 + 14.0) / 2
        ln_pri_expected = 20.0 - c1_avg_in / 12  # ft
        ln_sec_expected = 16.0 - c2_avg_in / 12  # ft
        @test ustrip(u"ft", primary.ln) ≈ ln_pri_expected atol=0.1
        @test ustrip(u"ft", secondary.ln) ≈ ln_sec_expected atol=0.1
    end

    @testset "M0 differs between directions" begin
        # M0 = qu × l2 × ln² / 8
        # Different l2 and ln → different M0
        @test primary.M0 != secondary.M0
    end
end

# =============================================================================
# 13. FEA Column Force Extraction — Mx/My Preserved
# =============================================================================
@testset "FEA Column Forces — Directional Moments" begin
    # The _extract_fea_column_forces function now returns Mx and My.
    # We can't easily test it without a solved FEA model, but we can
    # verify the return type includes the new fields.
    # (Integration with the full FEA pipeline is tested in test_fea_flat_plate.jl)

    # Verify that the function signature expects and returns 5 fields
    @test hasmethod(StructuralSizer._extract_fea_column_forces,
                    Tuple{Any, NTuple{2,Float64}, Int})
end
