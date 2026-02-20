# =============================================================================
# Tests for Waffle Slab Isoparametric Geometry
# =============================================================================
#
# Verifies IsoParametricPanel and WaffleRibGrid on a progression of
# geometries from regular rectangles to general quadrilaterals.
#
# =============================================================================

using Test
using StructuralSizer

# Aliases for internal (unexported) waffle geometry functions
const SS = StructuralSizer
const IsoParametricPanel = SS.IsoParametricPanel
const WaffleRibGrid      = SS.WaffleRibGrid
const WachspressPanel    = SS.WachspressPanel
const WachspressGrid     = SS.WachspressGrid
const physical_coords    = SS.physical_coords
const jacobian           = SS.jacobian
const jacobian_det       = SS.jacobian_det
const parametric_coords  = SS.parametric_coords
const min_jacobian_det   = SS.min_jacobian_det
const panel_area         = SS.panel_area
const modules            = SS.modules
const rib_lines_ξ        = SS.rib_lines_ξ
const is_in_solid_head   = SS.is_in_solid_head
const grid_summary       = SS.grid_summary
const wachspress_weights = SS.wachspress_weights
const auto_params        = SS.auto_params
const jacobian_det_parametric = SS.jacobian_det_parametric

@testset "Waffle Geometry" begin

    # =========================================================================
    # Panel 1: Perfect Rectangle (20 × 16 ft)
    # =========================================================================
    @testset "Rectangular panel" begin
        rect = IsoParametricPanel(((0.0, 0.0), (20.0, 0.0), (20.0, 16.0), (0.0, 16.0)))

        # Forward map: center should be (10, 8)
        xy = physical_coords(rect, 0.5, 0.5)
        @test isapprox(xy[1], 10.0, atol=1e-10)
        @test isapprox(xy[2],  8.0, atol=1e-10)

        # Corners map exactly
        @test physical_coords(rect, 0.0, 0.0) == (0.0, 0.0)
        @test physical_coords(rect, 1.0, 0.0) == (20.0, 0.0)
        @test physical_coords(rect, 1.0, 1.0) == (20.0, 16.0)
        @test physical_coords(rect, 0.0, 1.0) == (0.0, 16.0)

        # Jacobian should be constant = diag(20, 16)
        J00 = jacobian(rect, 0.0, 0.0)
        J55 = jacobian(rect, 0.5, 0.5)
        J11 = jacobian(rect, 1.0, 1.0)
        @test isapprox(J00, J55, atol=1e-10)
        @test isapprox(J00, J11, atol=1e-10)
        @test isapprox(J00[1,1], 20.0, atol=1e-10)  # ∂x/∂ξ = Lx
        @test isapprox(J00[2,2], 16.0, atol=1e-10)  # ∂y/∂η = Ly
        @test isapprox(J00[1,2],  0.0, atol=1e-10)  # no cross-term
        @test isapprox(J00[2,1],  0.0, atol=1e-10)

        # Jacobian determinant = Lx * Ly = 320
        @test isapprox(jacobian_det(rect, 0.3, 0.7), 320.0, atol=1e-10)

        # Inverse map: round-trip
        for (ξ, η) in [(0.0, 0.0), (0.25, 0.75), (0.5, 0.5), (1.0, 1.0)]
            xy = physical_coords(rect, ξ, η)
            ξ2, η2 = parametric_coords(rect, xy[1], xy[2])
            @test isapprox(ξ2, ξ, atol=1e-10)
            @test isapprox(η2, η, atol=1e-10)
        end

        # Panel area
        @test isapprox(panel_area(rect), 20.0 * 16.0, atol=0.1)

        # Grid: 4×3 modules, should all be equal area
        grid = WaffleRibGrid(rect, 4, 3)
        mods = modules(grid)
        @test length(mods) == 12
        expected_mod_area = (20.0 / 4) * (16.0 / 3)
        for m in mods
            @test isapprox(m.phys_area, expected_mod_area, atol=0.01)
            @test !m.is_solid
        end

        # Rib lines should be straight (all x-values the same for ξ-ribs)
        lines_ξ = rib_lines_ξ(grid; n_pts=5)
        @test length(lines_ξ) == 5  # nξ + 1
        for line in lines_ξ
            xs = [p[1] for p in line]
            @test all(isapprox.(xs, xs[1], atol=1e-10))  # constant x
        end
    end

    # =========================================================================
    # Panel 2: Parallelogram (skewed in X)
    # =========================================================================
    @testset "Parallelogram panel" begin
        # 20 ft base, 16 ft height, 3 ft X-skew
        skew = 3.0
        para = IsoParametricPanel((
            (0.0, 0.0), (20.0, 0.0),
            (20.0 + skew, 16.0), (skew, 16.0)
        ))

        # Jacobian should be constant (parallelogram = affine map)
        J00 = jacobian(para, 0.0, 0.0)
        J55 = jacobian(para, 0.5, 0.5)
        @test isapprox(J00, J55, atol=1e-10)

        # ∂x/∂η should equal the skew
        @test isapprox(J00[1,2], skew, atol=1e-10)

        # Determinant = Lx * Ly (skew doesn't change area for parallelogram)
        @test isapprox(jacobian_det(para, 0.5, 0.5), 20.0 * 16.0, atol=1e-10)

        # Area = base × height
        @test isapprox(panel_area(para), 20.0 * 16.0, atol=0.1)

        # Round-trip
        for (ξ, η) in [(0.1, 0.2), (0.5, 0.5), (0.9, 0.8)]
            xy = physical_coords(para, ξ, η)
            ξ2, η2 = parametric_coords(para, xy[1], xy[2])
            @test isapprox(ξ2, ξ, atol=1e-10)
            @test isapprox(η2, η, atol=1e-10)
        end

        # Grid: uniform modules (parallelogram → all modules identical)
        grid = WaffleRibGrid(para, 4, 3)
        mods = modules(grid)
        areas = [m.phys_area for m in mods]
        @test isapprox(minimum(areas), maximum(areas), atol=0.01)
    end

    # =========================================================================
    # Panel 3: Trapezoid (wider at top)
    # =========================================================================
    @testset "Trapezoidal panel" begin
        # Bottom edge: 18 ft, top edge: 24 ft (3 ft wider on each side), height: 16 ft
        trap = IsoParametricPanel((
            (0.0, 0.0), (18.0, 0.0),
            (21.0, 16.0), (-3.0, 16.0)
        ))

        # Positive Jacobian determinant everywhere
        @test min_jacobian_det(trap) > 0

        # Area = (18 + 24)/2 × 16 = 336
        @test isapprox(panel_area(trap), 336.0, atol=1.0)

        # Modules near top should be larger than modules near bottom
        grid = WaffleRibGrid(trap, 4, 4)
        mods = modules(grid)
        bottom_row = filter(m -> m.j == 1, mods)
        top_row    = filter(m -> m.j == 4, mods)
        avg_bottom = sum(m.phys_area for m in bottom_row) / length(bottom_row)
        avg_top    = sum(m.phys_area for m in top_row) / length(top_row)
        @test avg_top > avg_bottom

        # Round-trip
        for (ξ, η) in [(0.1, 0.3), (0.5, 0.5), (0.8, 0.9)]
            xy = physical_coords(trap, ξ, η)
            ξ2, η2 = parametric_coords(trap, xy[1], xy[2])
            @test isapprox(ξ2, ξ, atol=1e-10)
            @test isapprox(η2, η, atol=1e-10)
        end
    end

    # =========================================================================
    # Panel 4: General Quad (from Test 10 irregular columns)
    # =========================================================================
    @testset "General quadrilateral (irregular columns)" begin
        # One cell from the Test 10 hand-built layout:
        #   (22, 0)  (40, 0)  (42, 17)  (20, 20)
        # Interior cell with both X and Y shifts.
        quad = IsoParametricPanel([
            (22.0, 0.0), (40.0, 0.0), (42.0, 17.0), (20.0, 20.0)
        ])

        # Mapping should be valid (positive Jacobian everywhere)
        @test min_jacobian_det(quad) > 0

        # Round-trip at multiple points
        for (ξ, η) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (0.3, 0.7), (0.8, 0.2)]
            xy = physical_coords(quad, ξ, η)
            ξ2, η2 = parametric_coords(quad, xy[1], xy[2])
            @test isapprox(ξ2, ξ, atol=1e-10)
            @test isapprox(η2, η, atol=1e-10)
        end

        # Grid with solid heads
        grid = WaffleRibGrid(quad, 5, 4; solid_head=0.15)
        mods = modules(grid)
        @test length(mods) == 20
        n_solid = count(m -> m.is_solid, mods)
        @test n_solid > 0   # corners should be solid

        # Corner modules should be solid; center modules should not
        corners = filter(m -> (m.i == 1 || m.i == 5) && (m.j == 1 || m.j == 4), mods)
        center  = filter(m -> m.i == 3 && m.j == 2, mods)
        @test all(m -> m.is_solid, corners)
        @test all(m -> !m.is_solid, center)

        # Sum of module areas ≈ panel area
        total_mod = sum(m.phys_area for m in mods)
        pa = panel_area(quad)
        @test isapprox(total_mod, pa, rtol=0.02)
    end

    # =========================================================================
    # Panel 5: Multiple cells from irregular grid
    # =========================================================================
    @testset "All six cells from Test 10 irregular layout" begin
        # Full 4×3 column layout from test_fea_flat_plate.jl Test 10
        col_xy = [
            (0.0, 0.0),  (22.0, 0.0),  (40.0, 0.0),  (60.0, 0.0),    # Row 0
            (0.0, 18.0), (20.0, 20.0),  (42.0, 17.0), (60.0, 18.0),   # Row 1
            (0.0, 36.0), (23.0, 34.0),  (41.0, 37.0), (60.0, 36.0),   # Row 2
        ]

        nx, ny = 4, 3
        ci(ix, iy) = (iy - 1) * nx + ix   # 1-based index

        # Build all 6 cells (3 cols × 2 rows of panels)
        panels = IsoParametricPanel[]
        for iy in 1:(ny-1), ix in 1:(nx-1)
            c1 = col_xy[ci(ix,     iy)]
            c2 = col_xy[ci(ix + 1, iy)]
            c3 = col_xy[ci(ix + 1, iy + 1)]
            c4 = col_xy[ci(ix,     iy + 1)]
            push!(panels, IsoParametricPanel([c1, c2, c3, c4]))
        end
        @test length(panels) == 6

        # All panels should have positive Jacobian determinant
        for (k, p) in enumerate(panels)
            jmin = min_jacobian_det(p)
            @test jmin > 0
        end

        # All panels: round-trip works
        for p in panels
            xy = physical_coords(p, 0.5, 0.5)
            ξ2, η2 = parametric_coords(p, xy[1], xy[2])
            @test isapprox(ξ2, 0.5, atol=1e-9)
            @test isapprox(η2, 0.5, atol=1e-9)
        end

        # Grid on each panel: module areas sum to panel area
        for p in panels
            grid = WaffleRibGrid(p, 4, 3)
            mods = modules(grid)
            total = sum(m.phys_area for m in mods)
            pa = panel_area(p)
            @test isapprox(total, pa, rtol=0.03)
        end
    end

    # =========================================================================
    # Solid Head Region
    # =========================================================================
    @testset "Solid head logic" begin
        # Corners → solid, edges → not, center → not
        @test  is_in_solid_head(0.05, 0.05, 0.1)   # near (0,0)
        @test  is_in_solid_head(0.95, 0.05, 0.1)   # near (1,0)
        @test  is_in_solid_head(0.95, 0.95, 0.1)   # near (1,1)
        @test  is_in_solid_head(0.05, 0.95, 0.1)   # near (0,1)
        @test !is_in_solid_head(0.5,  0.5,  0.1)   # center
        @test !is_in_solid_head(0.5,  0.05, 0.1)   # mid-edge (near η=0 but not ξ corner)
        @test !is_in_solid_head(0.05, 0.5,  0.1)   # mid-edge (near ξ=0 but not η corner)
    end

    # =========================================================================
    # Grid Summary
    # =========================================================================
    @testset "Grid summary" begin
        rect = IsoParametricPanel(((0.0, 0.0), (20.0, 0.0), (20.0, 16.0), (0.0, 16.0)))
        # 4×3 grid: corner module centroids at ξ=0.125,η=0.167 and similar.
        # solid_head=0.20 captures all four corner modules.
        grid = WaffleRibGrid(rect, 4, 3; solid_head=0.20)
        s = grid_summary(grid)
        @test s.n_modules == 12
        @test s.n_solid == 4        # four corner modules
        @test s.n_void == 8
        @test isapprox(s.area_ratio, 1.0, atol=0.05)
        @test s.min_jac_det > 0
    end

end  # @testset "Waffle Geometry"


# =============================================================================
# Wachspress Panel — Quad Equivalence & N-gon Tests
# =============================================================================

@testset "Wachspress Panel" begin

    # =========================================================================
    # Wachspress weights: partition of unity and interpolation
    # =========================================================================
    @testset "Weight properties" begin
        quad_v = ((0.0, 0.0), (20.0, 0.0), (20.0, 16.0), (0.0, 16.0))

        # Partition of unity at several interior points
        for (x, y) in [(10.0, 8.0), (5.0, 3.0), (18.0, 14.0), (1.0, 1.0)]
            λ = wachspress_weights(quad_v, x, y)
            @test isapprox(sum(λ), 1.0, atol=1e-12)
            @test all(λᵢ -> λᵢ ≥ -1e-12, λ)     # non-negative (convex)
        end

        # Interpolation at vertices: λᵢ(vⱼ) = δᵢⱼ
        for j in 1:4
            λ = wachspress_weights(quad_v, quad_v[j][1], quad_v[j][2])
            for i in 1:4
                expected = i == j ? 1.0 : 0.0
                @test isapprox(λ[i], expected, atol=1e-10)
            end
        end
    end

    # =========================================================================
    # Quad equivalence: WachspressPanel ≡ IsoParametricPanel for 4 corners
    # =========================================================================
    @testset "Quad equivalence — rectangle" begin
        corners = ((0.0, 0.0), (20.0, 0.0), (20.0, 16.0), (0.0, 16.0))
        iso  = IsoParametricPanel(corners)
        wach = WachspressPanel(corners)

        # physical_coords should match at many (ξ,η) test points
        for ξ in [0.0, 0.25, 0.5, 0.75, 1.0], η in [0.0, 0.25, 0.5, 0.75, 1.0]
            xy_iso  = physical_coords(iso, ξ, η)
            xy_wach = physical_coords(wach, ξ, η)
            @test isapprox(xy_iso[1], xy_wach[1], atol=1e-8)
            @test isapprox(xy_iso[2], xy_wach[2], atol=1e-8)
        end

        # parametric_coords: direct Wachspress vs Newton isoparametric
        for (x, y) in [(10.0, 8.0), (5.0, 3.0), (18.0, 14.0)]
            ξη_iso  = parametric_coords(iso, x, y)
            ξη_wach = parametric_coords(wach, x, y)
            @test isapprox(ξη_iso[1], ξη_wach[1], atol=1e-8)
            @test isapprox(ξη_iso[2], ξη_wach[2], atol=1e-8)
        end

        # panel_area must agree
        @test isapprox(panel_area(iso), panel_area(wach), rtol=0.01)
    end

    @testset "Quad equivalence — general quad" begin
        # Highly skewed irregular quad — bilinear should be EXACT for N=4
        corners = ((0.0, 0.0), (22.0, 3.0), (24.0, 18.0), (2.0, 16.0))
        iso  = IsoParametricPanel(corners)
        wach = WachspressPanel(corners)

        for ξ in [0.0, 0.25, 0.5, 0.75, 1.0], η in [0.0, 0.25, 0.5, 0.75, 1.0]
            xy_iso  = physical_coords(iso, ξ, η)
            xy_wach = physical_coords(wach, ξ, η)
            @test isapprox(xy_iso[1], xy_wach[1], atol=1e-10)
            @test isapprox(xy_iso[2], xy_wach[2], atol=1e-10)
        end

        # Jacobian determinant (forward convention) should match
        for ξ in [0.25, 0.5, 0.75], η in [0.25, 0.5, 0.75]
            jd_iso  = jacobian_det(iso, ξ, η)
            jd_wach = jacobian_det_parametric(wach, ξ, η)
            @test isapprox(jd_iso, jd_wach, rtol=0.001)
        end
    end

    # =========================================================================
    # Pentagon
    # =========================================================================
    @testset "Regular pentagon" begin
        # Vertices of a regular pentagon centered at (10, 10), radius 8
        R = 8.0
        cx, cy = 10.0, 10.0
        pent_verts = ntuple(5) do i
            θ = 2π * (i - 1) / 5 - π/2   # start at top
            (cx + R * cos(θ), cy + R * sin(θ))
        end

        pent_params = ntuple(5) do i
            # distribute evenly around the unit square boundary
            t = 4.0 * (i - 1) / 5
            if t < 1.0
                (t, 0.0)
            elseif t < 2.0
                (1.0, t - 1.0)
            elseif t < 3.0
                (3.0 - t, 1.0)
            else
                (0.0, 4.0 - t)
            end
        end

        panel = WachspressPanel(pent_verts, pent_params)

        # Partition of unity at centroid
        λ = wachspress_weights(pent_verts, cx, cy)
        @test isapprox(sum(λ), 1.0, atol=1e-12)

        # Round-trip: physical → parametric → physical
        xy0 = physical_coords(panel, 0.5, 0.5)
        ξη  = parametric_coords(panel, xy0[1], xy0[2])
        @test isapprox(ξη[1], 0.5, atol=1e-6)
        @test isapprox(ξη[2], 0.5, atol=1e-6)

        # Panel area should be close to regular pentagon area = 5R²sin(2π/5)/2
        expected_area = 0.5 * 5 * R^2 * sin(2π / 5)
        @test isapprox(panel_area(panel), expected_area, rtol=0.05)

        # Positive Jacobian everywhere
        @test min_jacobian_det(panel) > 0
    end

    # =========================================================================
    # Hexagon
    # =========================================================================
    @testset "Regular hexagon" begin
        R = 6.0
        cx, cy = 15.0, 12.0
        hex_verts = ntuple(6) do i
            θ = 2π * (i - 1) / 6
            (cx + R * cos(θ), cy + R * sin(θ))
        end

        hex_params = ntuple(6) do i
            t = 4.0 * (i - 1) / 6
            if t < 1.0
                (t, 0.0)
            elseif t < 2.0
                (1.0, t - 1.0)
            elseif t < 3.0
                (3.0 - t, 1.0)
            else
                (0.0, 4.0 - t)
            end
        end

        panel = WachspressPanel(hex_verts, hex_params)

        # Round-trip
        xy0 = physical_coords(panel, 0.5, 0.5)
        ξη  = parametric_coords(panel, xy0[1], xy0[2])
        @test isapprox(ξη[1], 0.5, atol=1e-6)
        @test isapprox(ξη[2], 0.5, atol=1e-6)

        # Area: regular hexagon = 3√3/2 · R²
        expected_area = 3 * sqrt(3) / 2 * R^2
        @test isapprox(panel_area(panel), expected_area, rtol=0.05)

        # Non-degenerate Jacobian (sign depends on orientation relationship
        # between physical vertices and parametric assignment — auto-distributed
        # params around [0,1]² may reverse orientation for some N-gons)
        @test abs(min_jacobian_det(panel)) > 0
    end

    # =========================================================================
    # Grid on pentagon: modules and rib lines
    # =========================================================================
    @testset "Pentagon grid layout" begin
        R = 8.0
        cx, cy = 10.0, 10.0
        pent_verts = ntuple(5) do i
            θ = 2π * (i - 1) / 5 - π/2
            (cx + R * cos(θ), cy + R * sin(θ))
        end
        pent_params = ntuple(5) do i
            t = 4.0 * (i - 1) / 5
            if t < 1.0;      (t, 0.0)
            elseif t < 2.0;  (1.0, t - 1.0)
            elseif t < 3.0;  (3.0 - t, 1.0)
            else;             (0.0, 4.0 - t)
            end
        end

        panel = WachspressPanel(pent_verts, pent_params)
        grid  = WachspressGrid(panel, 4, 4; solid_head=0.15)

        mods = modules(grid)
        # N-gon: some modules near corners of [0,1]² fall outside the
        # parametric polygon and get skipped, so count ≤ 16
        @test length(mods) ≥ 4
        @test length(mods) ≤ 16

        # All retained module areas positive
        @test all(m -> m.phys_area > 0, mods)

        # Rib lines: correct count (nξ + 1)
        rξ = rib_lines_ξ(grid; n_pts=10)
        @test length(rξ) == 5

        # Summary works
        s = grid_summary(grid)
        @test s.n_modules ≥ 4
        @test s.min_jac_det > 0
    end

    # =========================================================================
    # auto_params: rectangle recovery
    # =========================================================================
    @testset "auto_params" begin
        # Rectangle: returns standard isoparametric assignment
        rect = [(0.0, 0.0), (20.0, 0.0), (20.0, 16.0), (0.0, 16.0)]
        p = auto_params(rect)
        @test p[1] == (0.0, 0.0)
        @test p[2] == (1.0, 0.0)
        @test p[3] == (1.0, 1.0)
        @test p[4] == (0.0, 1.0)

        # Pentagon: 5 params, all on [0,1]² boundary
        pent = [(0.0, 0.0), (10.0, 0.0), (12.0, 8.0), (6.0, 12.0), (-2.0, 8.0)]
        pp = auto_params(pent)
        @test length(pp) == 5
        @test pp[1] == (0.0, 0.0)  # first vertex always at origin
    end

end  # @testset "Wachspress Panel"
