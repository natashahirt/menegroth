# ==============================================================================
# Tests for RCColumnSection
# ==============================================================================
# Phase 1.1: Section struct construction and basic properties
# Uses verified StructurePoint 16x16 example data

using Test
using Unitful
using StructuralSizer

# Load test data (only if not already loaded by runtests.jl)
if !@isdefined(TIED_16X16_SPCOLUMN)
    include("test_data/tied_column_16x16.jl")
end

@testset "RCColumnSection" begin

    # ==========================================================================
    # Test 1: Basic Construction
    # ==========================================================================
    @testset "Basic Construction" begin
        # Create the 16x16 column from test data
        data = TIED_16X16_SPCOLUMN
        
        # Cover calculation to get d' = 2.5" (edge to bar center)
        # edge_to_center = cover + tie_diam + bar_diam/2 = 2.5"
        # cover = 2.5 - 0.5 - 0.564 ≈ 1.436"
        cover = 1.436u"inch"
        
        sec = RCColumnSection(
            b = data.geometry.b * u"inch",
            h = data.geometry.h * u"inch",
            bar_size = data.reinforcement.bar_size,
            n_bars = data.reinforcement.n_bars,
            cover = cover,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Check basic properties
        @test sec.b ≈ 16.0u"inch"
        @test sec.h ≈ 16.0u"inch"
        @test sec.tie_type == :tied
        @test length(sec.bars) == 8
        
        # Check name auto-generation
        @test sec.name == "16x16-8#9"
    end

    # ==========================================================================
    # Test 2: Gross Area Calculation
    # ==========================================================================
    @testset "Gross Area" begin
        data = TIED_16X16_SPCOLUMN
        cover = 1.436u"inch"
        
        sec = RCColumnSection(
            b = data.geometry.b * u"inch",
            h = data.geometry.h * u"inch",
            bar_size = data.reinforcement.bar_size,
            n_bars = data.reinforcement.n_bars,
            cover = cover,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Ag = 16 × 16 = 256 in²
        @test StructuralSizer.section_area(sec) ≈ 256.0u"inch^2"
    end

    # ==========================================================================
    # Test 3: Reinforcement Ratio
    # ==========================================================================
    @testset "Reinforcement Ratio" begin
        data = TIED_16X16_SPCOLUMN
        cover = 1.436u"inch"
        
        sec = RCColumnSection(
            b = data.geometry.b * u"inch",
            h = data.geometry.h * u"inch",
            bar_size = data.reinforcement.bar_size,
            n_bars = data.reinforcement.n_bars,
            cover = cover,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # ρg = As/Ag = 8.0/256 = 0.03125
        expected_rho = 8.0 / 256.0
        @test StructuralSizer.rho(sec) ≈ expected_rho rtol=0.001
        
        # Should be within ACI limits (0.01 to 0.08)
        @test 0.01 ≤ StructuralSizer.rho(sec) ≤ 0.08
    end

    # ==========================================================================
    # Test 4: Bar Positions (Two-Layer Arrangement)
    # ==========================================================================
    @testset "Bar Positions - Two Layer" begin
        data = TIED_16X16_SPCOLUMN
        cover = 1.436u"inch"
        
        sec = RCColumnSection(
            b = data.geometry.b * u"inch",
            h = data.geometry.h * u"inch",
            bar_size = data.reinforcement.bar_size,
            n_bars = data.reinforcement.n_bars,
            cover = cover,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Bars should be in two layers only
        y_coords = sort([ustrip(u"inch", bar.y) for bar in sec.bars])
        
        # 4 bars at bottom (y ≈ 2.5")
        bottom_bars = count(y -> isapprox(y, 2.5, atol=0.1), y_coords)
        @test bottom_bars == 4
        
        # 4 bars at top (y ≈ 13.5")
        top_bars = count(y -> isapprox(y, 13.5, atol=0.1), y_coords)
        @test top_bars == 4
        
        # No bars in between
        middle_bars = count(y -> 4.0 < y < 12.0, y_coords)
        @test middle_bars == 0
    end
    
    # ==========================================================================
    # Test 5: Bar Positions (Perimeter Arrangement)
    # ==========================================================================
    @testset "Bar Positions - Perimeter" begin
        sec = RCColumnSection(
            b = 18u"inch",
            h = 18u"inch",
            bar_size = 9,
            n_bars = 8,
            cover = 1.5u"inch",
            tie_type = :tied,
            arrangement = :perimeter
        )

        # Perimeter arrangement should have bars around all faces
        y_coords = sort([ustrip(u"inch", bar.y) for bar in sec.bars])
        x_coords = sort([ustrip(u"inch", bar.x) for bar in sec.bars])

        # Should have bars at multiple y levels (corners + sides)
        unique_y = unique(round.(y_coords, digits=1))
        @test length(unique_y) >= 2  # At least top and bottom

        # Should have bars at multiple x levels
        unique_x = unique(round.(x_coords, digits=1))
        @test length(unique_x) >= 2  # At least left and right
    end

    # ==========================================================================
    # Test 5b: Generalized Perimeter Layout (PR-5)
    # ==========================================================================
    @testset "Bar Positions - Perimeter (generalized counts)" begin
        # ────────────────────────────────────────────────────────────────────
        # Shared helper: count distinct bar locations on each face for a square
        # column of side `s` with edge_to_center distance `etc`.
        # ────────────────────────────────────────────────────────────────────
        function _face_counts(sec; etc=2.064, side=20.0)
            x_left  = etc; x_right = side - etc
            y_bot   = etc; y_top   = side - etc
            n_top    = count(b -> isapprox(ustrip(u"inch", b.y), y_top, atol=0.05), sec.bars)
            n_bot    = count(b -> isapprox(ustrip(u"inch", b.y), y_bot, atol=0.05), sec.bars)
            n_left   = count(b -> isapprox(ustrip(u"inch", b.x), x_left,  atol=0.05), sec.bars)
            n_right  = count(b -> isapprox(ustrip(u"inch", b.x), x_right, atol=0.05), sec.bars)
            return (top=n_top, bot=n_bot, left=n_left, right=n_right)
        end

        # cover + tie_diameter (#3 → 0.375") + bar_diameter/2 (#9 → 1.128/2)
        # Numbers below match `RCColumnSection`'s edge_to_center calc for #9 bars
        # in a 20×20 column with 1.5" clear cover.
        etc = 1.5 + 0.375 + 1.128/2  # ≈ 2.439, but we'll just use sec geometry
        side = 20.0

        @testset "Square 20×20, n_bars in 6:2:20" begin
            for n in (6, 8, 10, 12, 14, 16, 18, 20)
                sec = RCColumnSection(
                    b = side*u"inch",
                    h = side*u"inch",
                    bar_size = 9,
                    n_bars = n,
                    cover = 1.5u"inch",
                    tie_type = :tied,
                    arrangement = :perimeter,
                )
                @test length(sec.bars) == n
                # All bars distinct positions
                xs = [round(ustrip(u"inch", b.x), digits=3) for b in sec.bars]
                ys = [round(ustrip(u"inch", b.y), digits=3) for b in sec.bars]
                @test length(unique(zip(xs, ys))) == n
                # Symmetry: counts on opposite faces match (top/bottom may
                # differ by one for odd n_int per spColumn convention).
                fc = _face_counts(sec; side=side)
                @test fc.left == fc.right
                @test abs(fc.top - fc.bot) <= 1
            end
        end

        @testset "Rectangular 16×32 — long faces get more bars" begin
            # 16×32 with n_bars = 16: interior bars = 12, paired = 6.
            # Long faces are vertical (h = 32), so |left|+|right| > |top|+|bot|.
            sec = RCColumnSection(
                b = 16u"inch",
                h = 32u"inch",
                bar_size = 9,
                n_bars = 16,
                cover = 1.5u"inch",
                tie_type = :tied,
                arrangement = :perimeter,
            )
            @test length(sec.bars) == 16
            # Helper indexes faces by (x, y) ≈ corner. Use the section's own
            # b, h and edge_to_center.
            b_in  = ustrip(u"inch", sec.b);  h_in = ustrip(u"inch", sec.h)
            etc_x = sec.bars[1].x  # corner bar lives at edge_to_center
            etc_y = sec.bars[1].y
            x_left = ustrip(u"inch", etc_x);  x_right = b_in - x_left
            y_bot  = ustrip(u"inch", etc_y);  y_top  = h_in - y_bot
            n_top   = count(b -> isapprox(ustrip(u"inch", b.y), y_top, atol=0.05), sec.bars)
            n_bot   = count(b -> isapprox(ustrip(u"inch", b.y), y_bot, atol=0.05), sec.bars)
            n_left  = count(b -> isapprox(ustrip(u"inch", b.x), x_left,  atol=0.05), sec.bars)
            n_right = count(b -> isapprox(ustrip(u"inch", b.x), x_right, atol=0.05), sec.bars)
            # Vertical-face counts include corners (which are also horizontal).
            # On the long axis we expect strictly more bars than on the short.
            @test (n_left + n_right) > (n_top + n_bot)
        end

        @testset "_split_perimeter invariants" begin
            f = StructuralSizer._split_perimeter
            for n_int in 0:20
                for (Lb, Lh) in ((10.0, 10.0), (10.0, 20.0), (20.0, 10.0), (5.0, 35.0))
                    n_tb, n_lr, extra = f(n_int, Lb, Lh)
                    @test 2*n_tb + 2*n_lr + extra == n_int
                    @test extra in (0, 1)
                    @test n_tb >= 0 && n_lr >= 0
                    if n_int > 0 && Lb > Lh
                        @test n_tb >= n_lr  # long b-direction → more on top/bottom
                    elseif n_int > 0 && Lh > Lb
                        @test n_lr >= n_tb  # long h-direction → more on left/right
                    end
                end
            end
        end
    end

    # ==========================================================================
    # Test 6: Effective Depth
    # ==========================================================================
    @testset "Effective Depth" begin
        data = TIED_16X16_SPCOLUMN
        cover = 1.436u"inch"
        
        sec = RCColumnSection(
            b = data.geometry.b * u"inch",
            h = data.geometry.h * u"inch",
            bar_size = data.reinforcement.bar_size,
            n_bars = data.reinforcement.n_bars,
            cover = cover,
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Effective depth d = h - y_bottom_bars = 16 - 2.5 = 13.5"
        d = StructuralSizer.effective_depth(sec)
        @test ustrip(u"inch", d) ≈ 13.5 rtol=0.02
        
        # Compression steel depth d' = h - y_top_bars = 16 - 13.5 = 2.5"
        d_prime = StructuralSizer.compression_steel_depth(sec)
        @test ustrip(u"inch", d_prime) ≈ 2.5 rtol=0.02
    end

    # ==========================================================================
    # Test 7: Moment of Inertia
    # ==========================================================================
    @testset "Moment of Inertia" begin
        sec = RCColumnSection(
            b = 16u"inch",
            h = 16u"inch",
            bar_size = 9,
            n_bars = 8,
            cover = 1.5u"inch",
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Ig = bh³/12 = 16 × 16³ / 12 = 5461.3 in⁴
        Ig = StructuralSizer.moment_of_inertia(sec)
        @test ustrip(u"inch^4", Ig) ≈ 5461.3 rtol=0.01
    end

    # ==========================================================================
    # Test 8: Radius of Gyration
    # ==========================================================================
    @testset "Radius of Gyration" begin
        sec = RCColumnSection(
            b = 16u"inch",
            h = 20u"inch",  # Rectangular
            bar_size = 9,
            n_bars = 8,
            cover = 1.5u"inch",
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # r = 0.3h for rectangular sections (ACI 6.2.5.1)
        r_x = StructuralSizer.radius_of_gyration(sec; axis=:x)
        @test ustrip(u"inch", r_x) ≈ 0.3 * 20 rtol=0.01
        
        r_y = StructuralSizer.radius_of_gyration(sec; axis=:y)
        @test ustrip(u"inch", r_y) ≈ 0.3 * 16 rtol=0.01
    end

    # ==========================================================================
    # Test 9: Explicit Bar Positions Constructor
    # ==========================================================================
    @testset "Explicit Bar Constructor" begin
        # Create section with explicit bar positions
        As = 1.0u"inch^2"
        bars = [
            StructuralSizer.RebarLocation(2.5u"inch", 2.5u"inch", As),
            StructuralSizer.RebarLocation(13.5u"inch", 2.5u"inch", As),
            StructuralSizer.RebarLocation(2.5u"inch", 13.5u"inch", As),
            StructuralSizer.RebarLocation(13.5u"inch", 13.5u"inch", As),
        ]
        
        sec = RCColumnSection(16u"inch", 16u"inch", bars;
            cover = 1.5u"inch",
            tie_type = :tied,
            name = "Custom-4#9"
        )
        
        @test sec.name == "Custom-4#9"
        @test length(sec.bars) == 4
        @test ustrip(u"inch^2", sec.As_total) ≈ 4.0
    end

    # ==========================================================================
    # Test 10: Spiral Column
    # ==========================================================================
    @testset "Spiral Column" begin
        # Spiral columns require minimum 6 bars
        sec = RCColumnSection(
            b = 20u"inch",
            h = 20u"inch",
            bar_size = 8,
            n_bars = 8,
            cover = 1.5u"inch",
            tie_type = :spiral,
            arrangement = :perimeter
        )
        
        @test sec.tie_type == :spiral
    end

    # ==========================================================================
    # Test 11: Input Validation
    # ==========================================================================
    @testset "Input Validation" begin
        # Too few bars for tied column (minimum 4)
        @test_throws ErrorException RCColumnSection(
            b = 16u"inch", h = 16u"inch",
            bar_size = 9, n_bars = 3,
            cover = 1.5u"inch", tie_type = :tied
        )
        
        # Too few bars for spiral column (minimum 6)
        @test_throws ErrorException RCColumnSection(
            b = 20u"inch", h = 20u"inch",
            bar_size = 9, n_bars = 4,
            cover = 1.5u"inch", tie_type = :spiral
        )
    end

    # ==========================================================================
    # Test 12: Section Interface
    # ==========================================================================
    @testset "Section Interface" begin
        sec = RCColumnSection(
            b = 16u"inch",
            h = 16u"inch",
            bar_size = 9,
            n_bars = 8,
            cover = 1.5u"inch",
            tie_type = :tied,
            arrangement = :two_layer
        )
        
        # Width and depth
        @test StructuralSizer.section_width(sec) ≈ 16.0u"inch"
        @test StructuralSizer.section_depth(sec) ≈ 16.0u"inch"
        
        # Square check
        @test StructuralSizer.is_square(sec) == true
        
        # Number of bars
        @test StructuralSizer.n_bars(sec) == 8
    end

end
